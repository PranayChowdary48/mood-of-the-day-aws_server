import aws_cdk as cdk
from aws_cdk import aws_cloudwatch as cloudwatch
from aws_cdk import aws_cloudwatch_actions as cloudwatch_actions
from aws_cdk import aws_sns as sns
from constructs import Construct

from .compute_stack import ComputeStack
from .config import EnvConfig


class ObservabilityStack(cdk.Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        config: EnvConfig,
        compute: ComputeStack,
        alert_topic: sns.ITopic | None,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        dashboard_name = (
            f"{config.project_name}-{config.env_name}-alb-dashboard"
            if config.load_balancer_type == "alb"
            else f"{config.project_name}-{config.env_name}-nlb-dashboard"
        )

        dashboard = cloudwatch.Dashboard(
            self,
            "Dashboard",
            dashboard_name=dashboard_name,
        )

        if config.load_balancer_type == "alb":
            if not compute.alb_full_name or not compute.target_group_full_name:
                raise ValueError("ALB mode requires ALB and target group full names")

            alb_dims = {"LoadBalancer": compute.alb_full_name}
            alb_tg_dims = {"LoadBalancer": compute.alb_full_name, "TargetGroup": compute.target_group_full_name}

            req_metric = cloudwatch.Metric(
                namespace="AWS/ApplicationELB",
                metric_name="RequestCount",
                dimensions_map=alb_dims,
                statistic="sum",
                period=cdk.Duration.minutes(1),
            )
            err_metric = cloudwatch.Metric(
                namespace="AWS/ApplicationELB",
                metric_name="HTTPCode_Target_5XX_Count",
                dimensions_map=alb_tg_dims,
                statistic="sum",
                period=cdk.Duration.minutes(1),
            )
            p95_latency = cloudwatch.Metric(
                namespace="AWS/ApplicationELB",
                metric_name="TargetResponseTime",
                dimensions_map=alb_tg_dims,
                statistic="p95",
                period=cdk.Duration.minutes(1),
            )
            unhealthy = cloudwatch.Metric(
                namespace="AWS/ApplicationELB",
                metric_name="UnHealthyHostCount",
                dimensions_map=alb_tg_dims,
                statistic="max",
                period=cdk.Duration.minutes(1),
            )

            success_rate = cloudwatch.MathExpression(
                expression="IF(req>0,100*(1-err/req),100)",
                using_metrics={"req": req_metric, "err": err_metric},
                label="SLO Availability %",
            )

            dashboard.add_widgets(
                cloudwatch.GraphWidget(title="ALB Request Count", left=[req_metric]),
                cloudwatch.GraphWidget(title="Target 5XX", left=[err_metric]),
                cloudwatch.GraphWidget(title="SLO Availability %", left=[success_rate]),
                cloudwatch.GraphWidget(title="Latency p95", left=[p95_latency]),
                cloudwatch.GraphWidget(title="Unhealthy Targets", left=[unhealthy]),
            )

            target_5xx_alarm = cloudwatch.Alarm(
                self,
                "Target5xxAlarm",
                metric=err_metric,
                threshold=5,
                evaluation_periods=1,
                datapoints_to_alarm=1,
                alarm_description="Target 5xx errors are above threshold",
            )

            unhealthy_alarm = cloudwatch.Alarm(
                self,
                "UnhealthyHostAlarm",
                metric=unhealthy,
                threshold=1,
                evaluation_periods=1,
                datapoints_to_alarm=1,
                comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
                alarm_description="At least one target is unhealthy",
            )

            slo_alarm = cloudwatch.Alarm(
                self,
                "SloAvailabilityAlarm",
                metric=success_rate,
                threshold=99,
                evaluation_periods=3,
                datapoints_to_alarm=2,
                comparison_operator=cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
                alarm_description="SLO availability dropped below 99%",
            )

            latency_alarm = cloudwatch.Alarm(
                self,
                "LatencyP95Alarm",
                metric=p95_latency,
                threshold=0.75,
                evaluation_periods=3,
                datapoints_to_alarm=2,
                comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
                alarm_description="p95 response time above 0.75s",
            )

            if alert_topic is not None:
                for alarm in [target_5xx_alarm, unhealthy_alarm, slo_alarm, latency_alarm]:
                    alarm.add_alarm_action(cloudwatch_actions.SnsAction(alert_topic))

        else:
            nlb_dims = {"LoadBalancer": compute.nlb_full_name or "unknown"}

            active_flows = cloudwatch.Metric(
                namespace="AWS/NetworkELB",
                metric_name="ActiveFlowCount",
                dimensions_map=nlb_dims,
                statistic="sum",
                period=cdk.Duration.minutes(1),
            )
            processed_bytes = cloudwatch.Metric(
                namespace="AWS/NetworkELB",
                metric_name="ProcessedBytes",
                dimensions_map=nlb_dims,
                statistic="sum",
                period=cdk.Duration.minutes(1),
            )

            dashboard.add_widgets(
                cloudwatch.GraphWidget(title="NLB Active Flow Count", left=[active_flows]),
                cloudwatch.GraphWidget(title="NLB Processed Bytes", left=[processed_bytes]),
            )

            nlb_alarm = cloudwatch.Alarm(
                self,
                "NlbActiveFlowAlarm",
                metric=active_flows,
                threshold=1,
                evaluation_periods=1,
                datapoints_to_alarm=1,
                comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
                treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
                alarm_description="NLB is receiving traffic",
            )

            if alert_topic is not None:
                nlb_alarm.add_alarm_action(cloudwatch_actions.SnsAction(alert_topic))

        cdk.CfnOutput(self, "DashboardName", value=dashboard_name)
