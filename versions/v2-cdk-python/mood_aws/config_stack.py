import aws_cdk as cdk
from aws_cdk import aws_secretsmanager as secretsmanager
from aws_cdk import aws_ssm as ssm
from constructs import Construct

from .config import EnvConfig


class ConfigStack(cdk.Stack):
    def __init__(self, scope: Construct, construct_id: str, *, config: EnvConfig, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.refresh_user_param: ssm.IStringParameter | None = None
        self.refresh_password_param: ssm.IStringParameter | None = None
        self.refresh_secret: secretsmanager.ISecret | None = None

        if config.secret_backend == "ssm":
            self.refresh_user_param = ssm.StringParameter(
                self,
                "RefreshUser",
                parameter_name=f"/mood/{config.env_name}/refresh_user",
                string_value="mood",
            )

            self.refresh_password_param = ssm.StringParameter(
                self,
                "RefreshPassword",
                parameter_name=f"/mood/{config.env_name}/refresh_password",
                string_value="mood",
            )

            cdk.CfnOutput(
                self,
                "RefreshUserParameterName",
                value=self.refresh_user_param.parameter_name,
                export_name=f"Mood-{config.env_name}-RefreshUserParameterName",
            )
            cdk.CfnOutput(
                self,
                "RefreshPasswordParameterName",
                value=self.refresh_password_param.parameter_name,
                export_name=f"Mood-{config.env_name}-RefreshPasswordParameterName",
            )

        else:
            self.refresh_secret = secretsmanager.Secret(
                self,
                "RefreshAuthSecret",
                secret_name=f"mood/{config.env_name}/refresh-auth",
                secret_object_value={
                    "refresh_user": cdk.SecretValue.unsafe_plain_text("mood"),
                    "refresh_password": cdk.SecretValue.unsafe_plain_text("mood"),
                },
            )

            cdk.CfnOutput(
                self,
                "RefreshAuthSecretArn",
                value=self.refresh_secret.secret_arn,
                export_name=f"Mood-{config.env_name}-RefreshAuthSecretArn",
            )

        cdk.CfnOutput(self, "SecretBackend", value=config.secret_backend)
