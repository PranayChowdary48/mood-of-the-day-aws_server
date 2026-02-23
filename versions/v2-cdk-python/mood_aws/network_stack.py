import aws_cdk as cdk
from aws_cdk import aws_ec2 as ec2
from constructs import Construct

from .config import EnvConfig


class NetworkStack(cdk.Stack):
    def __init__(self, scope: Construct, construct_id: str, *, config: EnvConfig, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        use_nat = config.network_profile == "strict-private"
        private_subnet_type = ec2.SubnetType.PRIVATE_WITH_EGRESS if use_nat else ec2.SubnetType.PRIVATE_ISOLATED

        self.vpc = ec2.Vpc(
            self,
            "Vpc",
            max_azs=2,
            nat_gateways=1 if use_nat else 0,
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="Public",
                    subnet_type=ec2.SubnetType.PUBLIC,
                    cidr_mask=24,
                ),
                ec2.SubnetConfiguration(
                    name="Private",
                    subnet_type=private_subnet_type,
                    cidr_mask=24,
                ),
            ],
        )

        if use_nat:
            self.private_subnets = self.vpc.private_subnets
        else:
            self.private_subnets = self.vpc.isolated_subnets

        if config.enable_vpc_endpoints:
            endpoint_sg = ec2.SecurityGroup(
                self,
                "VpcEndpointSg",
                vpc=self.vpc,
                description="Allow VPC internal HTTPS to interface endpoints",
                allow_all_outbound=True,
            )
            endpoint_sg.add_ingress_rule(
                ec2.Peer.ipv4(self.vpc.vpc_cidr_block),
                ec2.Port.tcp(443),
                "HTTPS from VPC",
            )

            self.vpc.add_gateway_endpoint(
                "S3Endpoint",
                service=ec2.GatewayVpcEndpointAwsService.S3,
                subnets=[
                    ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
                    ec2.SubnetSelection(subnets=self.private_subnets),
                ],
            )

            for name, service in [
                ("EcrApiEndpoint", ec2.InterfaceVpcEndpointAwsService.ECR),
                ("EcrDkrEndpoint", ec2.InterfaceVpcEndpointAwsService.ECR_DOCKER),
                ("LogsEndpoint", ec2.InterfaceVpcEndpointAwsService.CLOUDWATCH_LOGS),
                ("SecretsManagerEndpoint", ec2.InterfaceVpcEndpointAwsService.SECRETS_MANAGER),
                ("SsmEndpoint", ec2.InterfaceVpcEndpointAwsService.SSM),
                ("SsmMessagesEndpoint", ec2.InterfaceVpcEndpointAwsService.SSM_MESSAGES),
                ("Ec2MessagesEndpoint", ec2.InterfaceVpcEndpointAwsService.EC2_MESSAGES),
                ("EcsEndpoint", ec2.InterfaceVpcEndpointAwsService.ECS),
                ("EcsAgentEndpoint", ec2.InterfaceVpcEndpointAwsService.ECS_AGENT),
                ("EcsTelemetryEndpoint", ec2.InterfaceVpcEndpointAwsService.ECS_TELEMETRY),
            ]:
                self.vpc.add_interface_endpoint(
                    name,
                    service=service,
                    private_dns_enabled=True,
                    security_groups=[endpoint_sg],
                    subnets=ec2.SubnetSelection(subnets=self.private_subnets),
                )

        cdk.CfnOutput(self, "VpcId", value=self.vpc.vpc_id, export_name=f"Mood-{config.env_name}-VpcId")
        cdk.CfnOutput(self, "VpcCidr", value=self.vpc.vpc_cidr_block, export_name=f"Mood-{config.env_name}-VpcCidr")
        cdk.CfnOutput(self, "PublicSubnetAz1Id", value=self.vpc.public_subnets[0].subnet_id, export_name=f"Mood-{config.env_name}-PublicSubnetAz1Id")
        cdk.CfnOutput(self, "PublicSubnetAz2Id", value=self.vpc.public_subnets[1].subnet_id, export_name=f"Mood-{config.env_name}-PublicSubnetAz2Id")
        cdk.CfnOutput(self, "PrivateSubnetAz1Id", value=self.private_subnets[0].subnet_id, export_name=f"Mood-{config.env_name}-PrivateSubnetAz1Id")
        cdk.CfnOutput(self, "PrivateSubnetAz2Id", value=self.private_subnets[1].subnet_id, export_name=f"Mood-{config.env_name}-PrivateSubnetAz2Id")
