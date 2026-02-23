import aws_cdk as cdk
from aws_cdk import aws_certificatemanager as acm
from aws_cdk import aws_elasticloadbalancingv2 as elbv2
from aws_cdk import aws_route53 as route53
from aws_cdk import aws_route53_targets as route53_targets
from constructs import Construct

from .compute_stack import ComputeStack
from .config import EnvConfig


class DomainStack(cdk.Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        config: EnvConfig,
        compute: ComputeStack,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        if config.load_balancer_type != "alb":
            raise ValueError("Custom domain TLS requires ALB mode")

        if not config.hosted_zone_id:
            raise ValueError("hostedZoneId is required when enableTlsDomain=true")

        if config.subdomain:
            fqdn = f"{config.subdomain}.{config.domain_name}"
            record_name = config.subdomain
        else:
            fqdn = config.domain_name
            record_name = ""

        hosted_zone = route53.HostedZone.from_hosted_zone_attributes(
            self,
            "HostedZone",
            hosted_zone_id=config.hosted_zone_id,
            zone_name=config.domain_name,
        )

        certificate = acm.Certificate(
            self,
            "DomainCertificate",
            domain_name=fqdn,
            validation=acm.CertificateValidation.from_dns(hosted_zone),
        )

        alb = compute.service.load_balancer
        target_group = compute.service.target_group
        alb.add_listener(
            "HttpsListener",
            port=443,
            protocol=elbv2.ApplicationProtocol.HTTPS,
            certificates=[elbv2.ListenerCertificate.from_arn(certificate.certificate_arn)],
            default_target_groups=[target_group],
            open=True,
        )

        route53.ARecord(
            self,
            "AliasRecordA",
            zone=hosted_zone,
            record_name=record_name,
            target=route53.RecordTarget.from_alias(route53_targets.LoadBalancerTarget(alb)),
        )

        route53.AaaaRecord(
            self,
            "AliasRecordAAAA",
            zone=hosted_zone,
            record_name=record_name,
            target=route53.RecordTarget.from_alias(route53_targets.LoadBalancerTarget(alb)),
        )

        cdk.CfnOutput(
            self,
            "CertificateArn",
            value=certificate.certificate_arn,
            export_name=f"Mood-{config.env_name}-CertificateArn",
        )
        cdk.CfnOutput(
            self,
            "AppDomainName",
            value=fqdn,
            export_name=f"Mood-{config.env_name}-AppDomainName",
        )
