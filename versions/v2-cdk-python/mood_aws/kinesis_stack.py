import aws_cdk as cdk
from aws_cdk import aws_cloudwatch as cloudwatch
from aws_cdk import aws_cloudwatch_actions as cloudwatch_actions
from aws_cdk import aws_kinesis as kinesis
from aws_cdk import aws_sns as sns
from constructs import Construct

from .config import EnvConfig


class KinesisStack(cdk.Stack):
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

        self.stream = kinesis.Stream(
            self,
            "MoodEventStream",
            stream_mode=kinesis.StreamMode.ON_DEMAND,
            retention_period=cdk.Duration.hours(24),
        )

        incoming_records = self.stream.metric_incoming_records(period=cdk.Duration.minutes(1), statistic="sum")
        alarm = cloudwatch.Alarm(
            self,
            "IncomingRecordsAlarm",
            alarm_name=f"mood-{config.env_name}-kinesis-incoming-records",
            alarm_description="Kinesis stream has incoming records (sanity indicator)",
            metric=incoming_records,
            threshold=1,
            evaluation_periods=1,
            datapoints_to_alarm=1,
            comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
            treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
        )

        if alert_topic is not None:
            alarm.add_alarm_action(cloudwatch_actions.SnsAction(alert_topic))

        cdk.CfnOutput(
            self,
            "KinesisStreamName",
            value=self.stream.stream_name,
            export_name=f"Mood-{config.env_name}-KinesisStreamName",
        )
        cdk.CfnOutput(
            self,
            "KinesisStreamArn",
            value=self.stream.stream_arn,
            export_name=f"Mood-{config.env_name}-KinesisStreamArn",
        )
