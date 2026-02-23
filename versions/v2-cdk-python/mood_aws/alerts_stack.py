import aws_cdk as cdk
from aws_cdk import aws_sns as sns
from aws_cdk import aws_sns_subscriptions as subscriptions
from constructs import Construct

from .config import EnvConfig


class AlertsStack(cdk.Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        config: EnvConfig,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.topic = sns.Topic(
            self,
            "AlarmTopic",
            topic_name=f"mood-{config.env_name}-alarms",
            display_name=f"mood-{config.env_name}-alarms",
        )

        if config.alert_email:
            self.topic.add_subscription(subscriptions.EmailSubscription(config.alert_email))

        cdk.CfnOutput(
            self,
            "AlertTopicArn",
            value=self.topic.topic_arn,
            export_name=f"Mood-{config.env_name}-AlertTopicArn",
        )
