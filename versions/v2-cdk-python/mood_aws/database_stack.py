import aws_cdk as cdk
from aws_cdk import aws_ec2 as ec2
from aws_cdk import aws_rds as rds
from constructs import Construct

from .config import EnvConfig


class DatabaseStack(cdk.Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        config: EnvConfig,
        vpc: ec2.IVpc,
        private_subnets: list[ec2.ISubnet],
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.db_name = "mood"
        self.db_user = "moodapp"

        db_sg = ec2.SecurityGroup(
            self,
            "RdsSecurityGroup",
            vpc=vpc,
            description="Allow PostgreSQL from VPC CIDR",
            allow_all_outbound=True,
        )
        db_sg.add_ingress_rule(
            ec2.Peer.ipv4(vpc.vpc_cidr_block),
            ec2.Port.tcp(5432),
            "PostgreSQL from VPC",
        )

        self.instance = rds.DatabaseInstance(
            self,
            "Database",
            instance_identifier=f"mood-{config.env_name}-postgres",
            engine=rds.DatabaseInstanceEngine.postgres(
                version=rds.PostgresEngineVersion.VER_15_8
            ),
            credentials=rds.Credentials.from_generated_secret(
                username=self.db_user,
                secret_name=f"mood/{config.env_name}/db",
            ),
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(subnets=private_subnets),
            security_groups=[db_sg],
            publicly_accessible=False,
            multi_az=False,
            allocated_storage=20,
            max_allocated_storage=100,
            instance_type=ec2.InstanceType.of(
                ec2.InstanceClass.BURSTABLE3,
                ec2.InstanceSize.MICRO,
            ),
            database_name=self.db_name,
            auto_minor_version_upgrade=True,
            backup_retention=cdk.Duration.days(1),
            deletion_protection=(config.env_name == "prod" and config.mode == "showcase"),
            removal_policy=(
                cdk.RemovalPolicy.SNAPSHOT
                if config.env_name == "prod"
                else cdk.RemovalPolicy.DESTROY
            ),
            delete_automated_backups=(config.env_name != "prod"),
        )

        if self.instance.secret is None:
            raise ValueError("RDS secret was not created")

        self.db_secret = self.instance.secret

        cdk.CfnOutput(
            self,
            "DbHost",
            value=self.instance.db_instance_endpoint_address,
            export_name=f"Mood-{config.env_name}-DbHost",
        )
        cdk.CfnOutput(
            self,
            "DbPort",
            value=self.instance.db_instance_endpoint_port,
            export_name=f"Mood-{config.env_name}-DbPort",
        )
        cdk.CfnOutput(
            self,
            "DbName",
            value=self.db_name,
            export_name=f"Mood-{config.env_name}-DbName",
        )
        cdk.CfnOutput(
            self,
            "DbUser",
            value=self.db_user,
            export_name=f"Mood-{config.env_name}-DbUser",
        )
        cdk.CfnOutput(
            self,
            "DbSecretArn",
            value=self.db_secret.secret_arn,
            export_name=f"Mood-{config.env_name}-DbSecretArn",
        )
