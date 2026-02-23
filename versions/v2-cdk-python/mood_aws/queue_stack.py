import aws_cdk as cdk
from aws_cdk import aws_cloudwatch as cloudwatch
from aws_cdk import aws_cloudwatch_actions as cloudwatch_actions
from aws_cdk import aws_sns as sns
from aws_cdk import aws_sqs as sqs
from constructs import Construct

from .config import EnvConfig


class QueueStack(cdk.Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        config: EnvConfig,
        alert_topic: sns.ITopic | None,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.refresh_dlq = sqs.Queue(
            self,
            "RefreshDlq",
            queue_name=f"mood-{config.env_name}-refresh-dlq",
            retention_period=cdk.Duration.days(14),
        )

        self.refresh_queue = sqs.Queue(
            self,
            "RefreshQueue",
            queue_name=f"mood-{config.env_name}-refresh",
            visibility_timeout=cdk.Duration.seconds(30),
            receive_message_wait_time=cdk.Duration.seconds(20),
            dead_letter_queue=sqs.DeadLetterQueue(
                queue=self.refresh_dlq,
                max_receive_count=3,
            ),
        )

        dlq_visible = self.refresh_dlq.metric_approximate_number_of_messages_visible(
            period=cdk.Duration.minutes(1)
        )

        dlq_alarm = cloudwatch.Alarm(
            self,
            "DlqDepthAlarm",
            alarm_name=f"mood-{config.env_name}-refresh-dlq-depth",
            alarm_description="Messages are accumulating in refresh DLQ",
            metric=dlq_visible,
            threshold=1,
            evaluation_periods=1,
            datapoints_to_alarm=1,
            comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
            treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
        )

        if alert_topic is not None:
            dlq_alarm.add_alarm_action(cloudwatch_actions.SnsAction(alert_topic))

        cdk.CfnOutput(
            self,
            "QueueUrl",
            value=self.refresh_queue.queue_url,
            export_name=f"Mood-{config.env_name}-QueueUrl",
        )
        cdk.CfnOutput(
            self,
            "QueueArn",
            value=self.refresh_queue.queue_arn,
            export_name=f"Mood-{config.env_name}-QueueArn",
        )
        cdk.CfnOutput(
            self,
            "DlqUrl",
            value=self.refresh_dlq.queue_url,
            export_name=f"Mood-{config.env_name}-DlqUrl",
        )
