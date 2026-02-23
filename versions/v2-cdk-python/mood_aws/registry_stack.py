import aws_cdk as cdk
from aws_cdk import aws_ecr as ecr
from constructs import Construct

from .config import EnvConfig


class RegistryStack(cdk.Stack):
    def __init__(self, scope: Construct, construct_id: str, *, config: EnvConfig, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.repository = ecr.Repository(
            self,
            "AppRepository",
            repository_name=f"{config.project_name}-app-{config.env_name}",
            image_scan_on_push=True,
            lifecycle_rules=[ecr.LifecycleRule(max_image_count=10)],
        )

        cdk.CfnOutput(self, "RepositoryUri", value=self.repository.repository_uri)
