import aws_cdk as cdk
from aws_cdk import aws_autoscaling as autoscaling
from aws_cdk import aws_codedeploy as codedeploy
from aws_cdk import aws_ec2 as ec2
from aws_cdk import aws_ecr as ecr
from aws_cdk import aws_ecs as ecs
from aws_cdk import aws_ecs_patterns as ecs_patterns
from aws_cdk import aws_elasticloadbalancingv2 as elbv2
from aws_cdk import aws_iam as iam
from aws_cdk import aws_logs as logs
from aws_cdk import aws_secretsmanager as secretsmanager
from aws_cdk import aws_ssm as ssm
from constructs import Construct

from .config import EnvConfig


class ComputeStack(cdk.Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        config: EnvConfig,
        vpc: ec2.IVpc,
        repository: ecr.IRepository,
        refresh_user_param: ssm.IStringParameter | None,
        refresh_password_param: ssm.IStringParameter | None,
        refresh_secret: secretsmanager.ISecret | None,
        redis_host_override: str | None,
        queue_url: str | None,
        db_endpoint: str | None,
        db_port: str | None,
        db_name: str | None,
        db_user: str | None,
        db_password_secret: secretsmanager.ISecret | None,
        efs_file_system_id: str | None,
        efs_access_point_id: str | None,
        kinesis_stream_name: str | None,
        kinesis_stream_arn: str | None,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.load_balancer_type = config.load_balancer_type
        self.alb_full_name: str | None = None
        self.target_group_full_name: str | None = None
        self.nlb_full_name: str | None = None
        self.alb_arn: str | None = None
        self.alb_canonical_hosted_zone_id: str | None = None
        self.alb_target_group_arn: str | None = None

        cluster = ecs.Cluster(
            self,
            "Cluster",
            vpc=vpc,
            cluster_name=f"{config.project_name}-{config.env_name}",
        )

        asg = autoscaling.AutoScalingGroup(
            self,
            "Asg",
            vpc=vpc,
            instance_type=ec2.InstanceType(config.ecs_instance_type),
            machine_image=ecs.EcsOptimizedImage.amazon_linux2(),
            desired_capacity=config.ecs_desired_capacity,
            min_capacity=1,
            max_capacity=4 if config.mode == "showcase" else 2,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
        )

        capacity_provider = ecs.AsgCapacityProvider(
            self,
            "AsgCapacityProvider",
            auto_scaling_group=asg,
            enable_managed_termination_protection=False,
            enable_managed_scaling=True,
        )
        cluster.add_asg_capacity_provider(capacity_provider)

        log_group = logs.LogGroup(
            self,
            "AppLogGroup",
            log_group_name=f"/ecs/{config.project_name}-{config.env_name}",
            retention=logs.RetentionDays.ONE_WEEK,
            removal_policy=cdk.RemovalPolicy.DESTROY,
        )

        task_role = iam.Role(
            self,
            "TaskRole",
            assumed_by=iam.ServicePrincipal("ecs-tasks.amazonaws.com"),
        )
        task_role.add_to_policy(
            iam.PolicyStatement(
                actions=["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"],
                resources=[f"arn:aws:ssm:{self.region}:{self.account}:parameter/mood/{config.env_name}/*"],
            )
        )
        task_role.add_to_policy(
            iam.PolicyStatement(
                actions=["secretsmanager:GetSecretValue"],
                resources=[
                    f"arn:aws:secretsmanager:{self.region}:{self.account}:secret:mood/{config.env_name}/*"
                ],
            )
        )

        if queue_url:
            task_role.add_to_policy(
                iam.PolicyStatement(
                    actions=[
                        "sqs:SendMessage",
                        "sqs:ReceiveMessage",
                        "sqs:DeleteMessage",
                        "sqs:GetQueueAttributes",
                    ],
                    resources=[f"arn:aws:sqs:{self.region}:{self.account}:mood-{config.env_name}-*"],
                )
            )

        if kinesis_stream_arn:
            task_role.add_to_policy(
                iam.PolicyStatement(
                    actions=[
                        "kinesis:DescribeStream",
                        "kinesis:DescribeStreamSummary",
                        "kinesis:PutRecord",
                        "kinesis:PutRecords",
                    ],
                    resources=[kinesis_stream_arn],
                )
            )

        if config.secret_backend == "ssm":
            if refresh_user_param is None or refresh_password_param is None:
                raise ValueError("SSM backend selected but SSM parameters are missing")
            app_secrets: dict[str, ecs.Secret] = {
                "REFRESH_USER": ecs.Secret.from_ssm_parameter(refresh_user_param),
                "REFRESH_PASSWORD": ecs.Secret.from_ssm_parameter(refresh_password_param),
            }
        else:
            if refresh_secret is None:
                raise ValueError("Secrets Manager backend selected but secret is missing")
            app_secrets = {
                "REFRESH_USER": ecs.Secret.from_secrets_manager(refresh_secret, field="refresh_user"),
                "REFRESH_PASSWORD": ecs.Secret.from_secrets_manager(refresh_secret, field="refresh_password"),
            }

        if db_endpoint and db_password_secret:
            app_secrets["DB_PASSWORD"] = ecs.Secret.from_secrets_manager(db_password_secret, field="password")

        if config.cache_backend == "elasticache":
            if not redis_host_override:
                raise ValueError("cacheBackend=elasticache requires redis host endpoint")
            redis_host = redis_host_override
        else:
            redis_host = "127.0.0.1"

        if config.task_subnet_type == "private":
            private_type = (
                ec2.SubnetType.PRIVATE_WITH_EGRESS
                if config.network_profile == "strict-private"
                else ec2.SubnetType.PRIVATE_ISOLATED
            )
            task_subnet_selection = ec2.SubnetSelection(subnet_type=private_type)
        else:
            task_subnet_selection = ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC)

        app_env = {
            "SERVICE_NAME": f"{config.project_name}-{config.env_name}",
            "REDIS_HOST": redis_host,
            "REDIS_PORT": "6379",
            "AWS_REGION": self.region,
            "SQS_ASYNC_REFRESH": "true" if queue_url else "false",
            "SQS_WORKER_ENABLED": "true" if queue_url else "false",
            "KINESIS_ENABLED": "true" if kinesis_stream_name else "false",
        }
        if queue_url:
            app_env["QUEUE_URL"] = queue_url
        if kinesis_stream_name:
            app_env["KINESIS_STREAM_NAME"] = kinesis_stream_name
        if db_endpoint and db_name and db_user:
            app_env["DB_HOST"] = db_endpoint
            app_env["DB_PORT"] = db_port or "5432"
            app_env["DB_NAME"] = db_name
            app_env["DB_USER"] = db_user

        image_options = ecs_patterns.ApplicationLoadBalancedTaskImageOptions(
            image=ecs.ContainerImage.from_ecr_repository(repository, "latest"),
            container_port=5000,
            container_name="app",
            environment=app_env,
            secrets=app_secrets,
            task_role=task_role,
            log_driver=ecs.LogDrivers.aws_logs(stream_prefix="app", log_group=log_group),
        )

        if config.load_balancer_type == "alb":
            self.service = ecs_patterns.ApplicationLoadBalancedEc2Service(
                self,
                "AppService",
                cluster=cluster,
                desired_count=config.app_desired_count,
                public_load_balancer=True,
                listener_port=80,
                task_subnets=task_subnet_selection,
                assign_public_ip=(config.task_subnet_type == "public"),
                task_image_options=image_options,
                health_check_grace_period=cdk.Duration.seconds(90),
                deployment_controller=ecs.DeploymentController(
                    type=(
                        ecs.DeploymentControllerType.CODE_DEPLOY
                        if config.deployment_strategy == "bluegreen"
                        else ecs.DeploymentControllerType.ECS
                    )
                ),
                min_healthy_percent=0,
                max_healthy_percent=100,
                circuit_breaker=ecs.DeploymentCircuitBreaker(
                    rollback=(config.deployment_strategy == "rolling")
                ),
            )

            self.service.target_group.configure_health_check(
                path="/health",
                healthy_http_codes="200",
                interval=cdk.Duration.seconds(30),
            )

            self.alb_arn = self.service.load_balancer.load_balancer_arn
            self.alb_full_name = self.service.load_balancer.load_balancer_full_name
            self.target_group_full_name = self.service.target_group.target_group_full_name
            self.alb_target_group_arn = self.service.target_group.target_group_arn
            self.alb_canonical_hosted_zone_id = self.service.load_balancer.load_balancer_canonical_hosted_zone_id
            self.load_balancer_dns_name = self.service.load_balancer.load_balancer_dns_name

            if config.deployment_strategy == "bluegreen":
                green_target_group = elbv2.ApplicationTargetGroup(
                    self,
                    "GreenTargetGroup",
                    vpc=vpc,
                    protocol=elbv2.ApplicationProtocol.HTTP,
                    port=5000,
                    target_type=elbv2.TargetType.IP,
                    health_check=elbv2.HealthCheck(path="/health", healthy_http_codes="200"),
                )

                test_listener = self.service.load_balancer.add_listener(
                    "BlueGreenTestListener",
                    port=9002,
                    protocol=elbv2.ApplicationProtocol.HTTP,
                    default_target_groups=[green_target_group],
                    open=True,
                )

                code_deploy_role = iam.Role(
                    self,
                    "CodeDeployRole",
                    assumed_by=iam.ServicePrincipal("codedeploy.amazonaws.com"),
                    managed_policies=[
                        iam.ManagedPolicy.from_aws_managed_policy_name(
                            "service-role/AWSCodeDeployRoleForECS"
                        )
                    ],
                )

                code_deploy_app = codedeploy.CfnApplication(
                    self,
                    "CodeDeployApplication",
                    application_name=f"mood-{config.env_name}-codedeploy",
                    compute_platform="ECS",
                )

                codedeploy.CfnDeploymentGroup(
                    self,
                    "CodeDeployDeploymentGroup",
                    application_name=code_deploy_app.ref,
                    deployment_group_name=f"mood-{config.env_name}-bluegreen",
                    service_role_arn=code_deploy_role.role_arn,
                    deployment_config_name="CodeDeployDefault.ECSAllAtOnce",
                    deployment_style={
                        "deploymentType": "BLUE_GREEN",
                        "deploymentOption": "WITH_TRAFFIC_CONTROL",
                    },
                    blue_green_deployment_configuration={
                        "deploymentReadyOption": {
                            "actionOnTimeout": "CONTINUE_DEPLOYMENT",
                            "waitTimeInMinutes": 0,
                        },
                        "terminateBlueInstancesOnDeploymentSuccess": {
                            "action": "TERMINATE",
                            "terminationWaitTimeInMinutes": 5,
                        },
                    },
                    auto_rollback_configuration={
                        "enabled": True,
                        "events": ["DEPLOYMENT_FAILURE"],
                    },
                    load_balancer_info={
                        "targetGroupPairInfoList": [
                            {
                                "targetGroups": [
                                    {"name": self.service.target_group.target_group_name},
                                    {"name": green_target_group.target_group_name},
                                ],
                                "prodTrafficRoute": {
                                    "listenerArns": [self.service.listener.listener_arn],
                                },
                                "testTrafficRoute": {
                                    "listenerArns": [test_listener.listener_arn],
                                },
                            }
                        ]
                    },
                    ecs_services=[
                        {
                            "clusterName": cluster.cluster_name,
                            "serviceName": self.service.service.service_name,
                        }
                    ],
                )

        else:
            # NLB variant for ALB-vs-NLB comparison.
            self.service = ecs_patterns.NetworkLoadBalancedEc2Service(
                self,
                "AppService",
                cluster=cluster,
                desired_count=config.app_desired_count,
                public_load_balancer=True,
                listener_port=80,
                task_subnets=task_subnet_selection,
                assign_public_ip=(config.task_subnet_type == "public"),
                task_image_options=ecs_patterns.NetworkLoadBalancedTaskImageOptions(
                    image=image_options.image,
                    container_port=5000,
                    container_name="app",
                    environment=image_options.environment,
                    secrets=image_options.secrets,
                    task_role=image_options.task_role,
                    log_driver=image_options.log_driver,
                ),
            )

            self.nlb_full_name = self.service.load_balancer.load_balancer_full_name
            self.load_balancer_dns_name = self.service.load_balancer.load_balancer_dns_name

        execution_role = self.service.task_definition.execution_role
        if execution_role is not None:
            execution_role.add_to_principal_policy(
                iam.PolicyStatement(
                    actions=["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"],
                    resources=[
                        f"arn:aws:ssm:{self.region}:{self.account}:parameter/mood/{config.env_name}/*"
                    ],
                )
            )
            execution_role.add_to_principal_policy(
                iam.PolicyStatement(
                    actions=["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
                    resources=[
                        f"arn:aws:secretsmanager:{self.region}:{self.account}:secret:mood/{config.env_name}/*"
                    ],
                )
            )
            execution_role.add_to_principal_policy(
                iam.PolicyStatement(
                    actions=["kms:Decrypt"],
                    resources=["*"],
                )
            )

        if efs_file_system_id and efs_access_point_id:
            self.service.task_definition.add_volume(
                name="shared-efs",
                efs_volume_configuration=ecs.EfsVolumeConfiguration(
                    file_system_id=efs_file_system_id,
                    transit_encryption=ecs.TransitEncryption.ENABLED,
                    authorization_config=ecs.AuthorizationConfig(
                        access_point_id=efs_access_point_id,
                        iam="DISABLED",
                    ),
                ),
            )
            if self.service.task_definition.default_container is not None:
                self.service.task_definition.default_container.add_mount_points(
                    ecs.MountPoint(
                        container_path="/mnt/shared",
                        source_volume="shared-efs",
                        read_only=False,
                    )
                )

        if config.cache_backend == "sidecar":
            redis_container = self.service.task_definition.add_container(
                "redis",
                image=ecs.ContainerImage.from_registry("public.ecr.aws/docker/library/redis:7-alpine"),
                container_name="redis",
                memory_reservation_mib=128,
                cpu=64,
                essential=True,
                logging=ecs.LogDrivers.aws_logs(stream_prefix="redis", log_group=log_group),
            )
            redis_container.add_port_mappings(
                ecs.PortMapping(container_port=6379, protocol=ecs.Protocol.TCP)
            )

            if self.service.task_definition.default_container is not None:
                self.service.task_definition.default_container.add_container_dependencies(
                    ecs.ContainerDependency(
                        container=redis_container,
                        condition=ecs.ContainerDependencyCondition.START,
                    )
                )

        scalable_target = self.service.service.auto_scale_task_count(
            min_capacity=2 if config.mode == "showcase" else 1,
            max_capacity=5 if config.mode == "showcase" else 2,
        )

        scalable_target.scale_on_cpu_utilization(
            "CpuScaling",
            target_utilization_percent=70,
            scale_in_cooldown=cdk.Duration.seconds(120),
            scale_out_cooldown=cdk.Duration.seconds(60),
        )

        if config.load_balancer_type == "alb":
            scalable_target.scale_on_request_count(
                "RequestScaling",
                requests_per_target=200,
                target_group=self.service.target_group,
            )

        self.cluster_name = cluster.cluster_name
        self.service_name = self.service.service.service_name

        cdk.CfnOutput(
            self,
            "LoadBalancerDnsName",
            value=self.load_balancer_dns_name,
            export_name=f"Mood-{config.env_name}-LoadBalancerDnsName",
        )
        cdk.CfnOutput(
            self,
            "ClusterName",
            value=self.cluster_name,
            export_name=f"Mood-{config.env_name}-ClusterName",
        )
        cdk.CfnOutput(
            self,
            "AsgName",
            value=asg.auto_scaling_group_name,
            export_name=f"Mood-{config.env_name}-AsgName",
        )

        cdk.CfnOutput(
            self,
            "ServiceName",
            value=self.service_name,
            export_name=f"Mood-{config.env_name}-ServiceName",
        )

        if self.alb_full_name:
            cdk.CfnOutput(
                self,
                "AlbFullName",
                value=self.alb_full_name,
                export_name=f"Mood-{config.env_name}-LoadBalancerFullName",
            )
        if self.target_group_full_name:
            cdk.CfnOutput(
                self,
                "AlbTargetGroupFullName",
                value=self.target_group_full_name,
                export_name=f"Mood-{config.env_name}-TargetGroupFullName",
            )
        if self.alb_arn:
            cdk.CfnOutput(
                self,
                "AlbArn",
                value=self.alb_arn,
                export_name=f"Mood-{config.env_name}-AlbArn",
            )
        if self.alb_target_group_arn:
            cdk.CfnOutput(
                self,
                "AlbTargetGroupArn",
                value=self.alb_target_group_arn,
                export_name=f"Mood-{config.env_name}-AlbTargetGroupArn",
            )
        if self.alb_canonical_hosted_zone_id:
            cdk.CfnOutput(
                self,
                "AlbCanonicalHostedZoneId",
                value=self.alb_canonical_hosted_zone_id,
                export_name=f"Mood-{config.env_name}-AlbCanonicalHostedZoneId",
            )
        if self.nlb_full_name:
            cdk.CfnOutput(
                self,
                "NlbFullName",
                value=self.nlb_full_name,
                export_name=f"Mood-{config.env_name}-NlbFullName",
            )
