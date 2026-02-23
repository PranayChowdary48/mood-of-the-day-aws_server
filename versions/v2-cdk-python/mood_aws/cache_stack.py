import aws_cdk as cdk
from aws_cdk import aws_ec2 as ec2
from aws_cdk import aws_elasticache as elasticache
from constructs import Construct

from .config import EnvConfig


class CacheStack(cdk.Stack):
    def __init__(self, scope: Construct, construct_id: str, *, config: EnvConfig, vpc: ec2.IVpc, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        redis_sg = ec2.SecurityGroup(
            self,
            "RedisSecurityGroup",
            vpc=vpc,
            description="Allow Redis from VPC CIDR",
            allow_all_outbound=True,
        )
        redis_sg.add_ingress_rule(
            ec2.Peer.ipv4(vpc.vpc_cidr_block),
            ec2.Port.tcp(6379),
            "Redis from VPC",
        )

        subnet_group = elasticache.CfnSubnetGroup(
            self,
            "RedisSubnetGroup",
            description=f"mood-{config.env_name} redis subnet group",
            subnet_ids=[s.subnet_id for s in vpc.private_subnets],
            cache_subnet_group_name=f"mood-{config.env_name}-redis-subnet-group",
        )

        replication_group = elasticache.CfnReplicationGroup(
            self,
            "RedisReplicationGroup",
            replication_group_description=f"mood-{config.env_name}-redis",
            engine="redis",
            engine_version="7.1",
            cache_node_type="cache.t4g.micro",
            num_cache_clusters=2 if config.mode == "showcase" else 1,
            cache_subnet_group_name=subnet_group.ref,
            security_group_ids=[redis_sg.security_group_id],
            auto_minor_version_upgrade=True,
            automatic_failover_enabled=False,
            transit_encryption_enabled=False,
            at_rest_encryption_enabled=False,
        )

        self.redis_endpoint = replication_group.attr_primary_end_point_address

        cdk.CfnOutput(
            self,
            "RedisPrimaryEndpoint",
            value=self.redis_endpoint,
            export_name=f"Mood-{config.env_name}-RedisPrimaryEndpoint",
        )
