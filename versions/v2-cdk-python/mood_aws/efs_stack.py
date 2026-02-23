import aws_cdk as cdk
from aws_cdk import aws_ec2 as ec2
from aws_cdk import aws_efs as efs
from constructs import Construct

from .config import EnvConfig


class EfsStack(cdk.Stack):
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

        efs_sg = ec2.SecurityGroup(
            self,
            "EfsSecurityGroup",
            vpc=vpc,
            description="Allow NFS from VPC",
            allow_all_outbound=True,
        )
        efs_sg.add_ingress_rule(
            ec2.Peer.ipv4(vpc.vpc_cidr_block),
            ec2.Port.tcp(2049),
            "NFS from VPC",
        )

        self.file_system = efs.FileSystem(
            self,
            "SharedFileSystem",
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(subnets=private_subnets),
            encrypted=True,
            performance_mode=efs.PerformanceMode.GENERAL_PURPOSE,
            lifecycle_policy=efs.LifecyclePolicy.AFTER_30_DAYS,
            security_group=efs_sg,
            removal_policy=(
                cdk.RemovalPolicy.RETAIN if config.env_name == "prod" else cdk.RemovalPolicy.DESTROY
            ),
        )

        self.access_point = self.file_system.add_access_point(
            "AppAccessPoint",
            path="/shared",
            create_acl=efs.Acl(owner_uid="1000", owner_gid="1000", permissions="0775"),
            posix_user=efs.PosixUser(uid="1000", gid="1000"),
        )

        cdk.CfnOutput(
            self,
            "EfsFileSystemId",
            value=self.file_system.file_system_id,
            export_name=f"Mood-{config.env_name}-EfsFileSystemId",
        )
        cdk.CfnOutput(
            self,
            "EfsAccessPointId",
            value=self.access_point.access_point_id,
            export_name=f"Mood-{config.env_name}-EfsAccessPointId",
        )
