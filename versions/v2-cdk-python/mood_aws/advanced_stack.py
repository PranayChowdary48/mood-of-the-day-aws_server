import aws_cdk as cdk
from aws_cdk import aws_cloudfront as cloudfront
from aws_cdk import aws_cloudfront_origins as origins
from aws_cdk import aws_cloudwatch as cloudwatch
from aws_cdk import aws_cloudwatch_actions as cloudwatch_actions
from aws_cdk import aws_s3 as s3
from aws_cdk import aws_sns as sns
from aws_cdk import aws_wafv2 as wafv2
from constructs import Construct

from .compute_stack import ComputeStack
from .config import EnvConfig


class AdvancedStack(cdk.Stack):
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

        if config.enable_waf and config.load_balancer_type == "alb" and compute.alb_arn:
            web_acl_name = f"mood-{config.env_name}-webacl"

            web_acl = wafv2.CfnWebACL(
                self,
                "WebAcl",
                name=web_acl_name,
                scope="REGIONAL",
                default_action=wafv2.CfnWebACL.DefaultActionProperty(allow={}),
                visibility_config=wafv2.CfnWebACL.VisibilityConfigProperty(
                    cloud_watch_metrics_enabled=True,
                    metric_name=f"{config.project_name}-{config.env_name}-waf",
                    sampled_requests_enabled=True,
                ),
                rules=[
                    wafv2.CfnWebACL.RuleProperty(
                        name="AwsManagedCommonRules",
                        priority=1,
                        override_action=wafv2.CfnWebACL.OverrideActionProperty(none={}),
                        statement=wafv2.CfnWebACL.StatementProperty(
                            managed_rule_group_statement=wafv2.CfnWebACL.ManagedRuleGroupStatementProperty(
                                vendor_name="AWS",
                                name="AWSManagedRulesCommonRuleSet",
                            )
                        ),
                        visibility_config=wafv2.CfnWebACL.VisibilityConfigProperty(
                            cloud_watch_metrics_enabled=True,
                            metric_name="managed-common",
                            sampled_requests_enabled=True,
                        ),
                    ),
                    wafv2.CfnWebACL.RuleProperty(
                        name="RateLimitPerIp",
                        priority=2,
                        action=wafv2.CfnWebACL.RuleActionProperty(block={}),
                        statement=wafv2.CfnWebACL.StatementProperty(
                            rate_based_statement=wafv2.CfnWebACL.RateBasedStatementProperty(
                                aggregate_key_type="IP",
                                limit=2000,
                            )
                        ),
                        visibility_config=wafv2.CfnWebACL.VisibilityConfigProperty(
                            cloud_watch_metrics_enabled=True,
                            metric_name="rate-limit",
                            sampled_requests_enabled=True,
                        ),
                    ),
                ],
            )

            wafv2.CfnWebACLAssociation(
                self,
                "WebAclAssociation",
                resource_arn=compute.alb_arn,
                web_acl_arn=web_acl.attr_arn,
            )

            waf_dims_all = {"WebACL": web_acl_name, "Rule": "ALL", "Region": cdk.Aws.REGION}
            waf_dims_rate = {"WebACL": web_acl_name, "Rule": "RateLimitPerIp", "Region": cdk.Aws.REGION}

            blocked_all = cloudwatch.Metric(
                namespace="AWS/WAFV2",
                metric_name="BlockedRequests",
                dimensions_map=waf_dims_all,
                statistic="sum",
                period=cdk.Duration.minutes(1),
            )
            blocked_rate_rule = cloudwatch.Metric(
                namespace="AWS/WAFV2",
                metric_name="BlockedRequests",
                dimensions_map=waf_dims_rate,
                statistic="sum",
                period=cdk.Duration.minutes(1),
            )

            blocked_alarm = cloudwatch.Alarm(
                self,
                "WafBlockedRequestsAlarm",
                metric=blocked_all,
                threshold=50,
                evaluation_periods=1,
                datapoints_to_alarm=1,
                comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
                treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
                alarm_description="Total WAF blocked requests exceeded threshold",
            )

            rate_alarm = cloudwatch.Alarm(
                self,
                "WafRateLimitRuleAlarm",
                metric=blocked_rate_rule,
                threshold=20,
                evaluation_periods=1,
                datapoints_to_alarm=1,
                comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
                treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
                alarm_description="WAF rate-limit rule is blocking traffic",
            )

            if alert_topic is not None:
                blocked_alarm.add_alarm_action(cloudwatch_actions.SnsAction(alert_topic))
                rate_alarm.add_alarm_action(cloudwatch_actions.SnsAction(alert_topic))

            cdk.CfnOutput(self, "WafWebAclArn", value=web_acl.attr_arn)

        if config.enable_cloudfront and config.load_balancer_type == "alb":
            static_bucket = s3.Bucket(
                self,
                "StaticBucket",
                block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
                encryption=s3.BucketEncryption.S3_MANAGED,
                enforce_ssl=True,
                auto_delete_objects=(config.env_name != "prod"),
                removal_policy=(
                    cdk.RemovalPolicy.RETAIN if config.env_name == "prod" else cdk.RemovalPolicy.DESTROY
                ),
            )

            distribution = cloudfront.Distribution(
                self,
                "StaticDistribution",
                default_root_object="index.html",
                default_behavior=cloudfront.BehaviorOptions(
                    origin=origins.S3Origin(static_bucket),
                    viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                    allowed_methods=cloudfront.AllowedMethods.ALLOW_GET_HEAD_OPTIONS,
                    cache_policy=cloudfront.CachePolicy.CACHING_OPTIMIZED,
                    compress=True,
                ),
                additional_behaviors={
                    "api/*": cloudfront.BehaviorOptions(
                        origin=origins.HttpOrigin(
                            compute.load_balancer_dns_name,
                            protocol_policy=cloudfront.OriginProtocolPolicy.HTTP_ONLY,
                        ),
                        viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                        allowed_methods=cloudfront.AllowedMethods.ALLOW_ALL,
                        cache_policy=cloudfront.CachePolicy.CACHING_DISABLED,
                        origin_request_policy=cloudfront.OriginRequestPolicy.ALL_VIEWER,
                        compress=True,
                    )
                },
                error_responses=[
                    cloudfront.ErrorResponse(
                        http_status=403,
                        response_http_status=200,
                        response_page_path="/index.html",
                    ),
                    cloudfront.ErrorResponse(
                        http_status=404,
                        response_http_status=200,
                        response_page_path="/index.html",
                    ),
                ],
            )

            cdk.CfnOutput(
                self,
                "StaticBucketName",
                value=static_bucket.bucket_name,
                export_name=f"Mood-{config.env_name}-StaticBucketName",
            )
            cdk.CfnOutput(
                self,
                "CloudFrontDomainName",
                value=distribution.distribution_domain_name,
                export_name=f"Mood-{config.env_name}-CloudFrontDomainName",
            )
            cdk.CfnOutput(
                self,
                "CloudFrontDistributionId",
                value=distribution.distribution_id,
                export_name=f"Mood-{config.env_name}-CloudFrontDistributionId",
            )

        if config.enable_blue_green and config.load_balancer_type != "alb":
            cdk.CfnOutput(
                self,
                "BlueGreenConstraint",
                value="Blue/Green is only available with ALB mode.",
            )
