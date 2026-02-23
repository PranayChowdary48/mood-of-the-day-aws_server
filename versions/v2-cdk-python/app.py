#!/usr/bin/env python3
import os

import aws_cdk as cdk

from mood_aws.advanced_stack import AdvancedStack
from mood_aws.alerts_stack import AlertsStack
from mood_aws.cache_stack import CacheStack
from mood_aws.compute_stack import ComputeStack
from mood_aws.config import load_config
from mood_aws.config_stack import ConfigStack
from mood_aws.database_stack import DatabaseStack
from mood_aws.domain_stack import DomainStack
from mood_aws.efs_stack import EfsStack
from mood_aws.kinesis_stack import KinesisStack
from mood_aws.network_stack import NetworkStack
from mood_aws.observability_stack import ObservabilityStack
from mood_aws.queue_stack import QueueStack
from mood_aws.registry_stack import RegistryStack
from mood_aws.secret_rotation_stack import SecretRotationStack


app = cdk.App()

env_name = app.node.try_get_context("env")
mode = app.node.try_get_context("mode")
ctx = {
    "region": app.node.try_get_context("region"),
    "enableWaf": app.node.try_get_context("enableWaf"),
    "enableBlueGreen": app.node.try_get_context("enableBlueGreen"),
    "enableElastiCache": app.node.try_get_context("enableElastiCache"),
    "enableCloudFront": app.node.try_get_context("enableCloudFront"),
    "enableVpcEndpoints": app.node.try_get_context("enableVpcEndpoints"),
    "taskSubnetType": app.node.try_get_context("taskSubnetType"),
    "secretBackend": app.node.try_get_context("secretBackend"),
    "cacheBackend": app.node.try_get_context("cacheBackend"),
    "loadBalancerType": app.node.try_get_context("loadBalancerType"),
    "deploymentStrategy": app.node.try_get_context("deploymentStrategy"),
    "networkProfile": app.node.try_get_context("networkProfile"),
    "enableSqs": app.node.try_get_context("enableSqs"),
    "enableRds": app.node.try_get_context("enableRds"),
    "enableAlerts": app.node.try_get_context("enableAlerts"),
    "alertEmail": app.node.try_get_context("alertEmail"),
    "enableStaticSite": app.node.try_get_context("enableStaticSite"),
    "enableEfs": app.node.try_get_context("enableEfs"),
    "enableKinesis": app.node.try_get_context("enableKinesis"),
    "enableTlsDomain": app.node.try_get_context("enableTlsDomain"),
    "enableSecretRotation": app.node.try_get_context("enableSecretRotation"),
    "domainName": app.node.try_get_context("domainName"),
    "hostedZoneId": app.node.try_get_context("hostedZoneId"),
    "subdomain": app.node.try_get_context("subdomain"),
}

config = load_config(env_name, mode, ctx)

stack_env = cdk.Environment(
    account=os.getenv("CDK_DEFAULT_ACCOUNT"),
    region=config.region,
)

network = NetworkStack(app, f"MoodNetwork-{config.env_name}", config=config, env=stack_env)
registry = RegistryStack(app, f"MoodRegistry-{config.env_name}", config=config, env=stack_env)
config_stack = ConfigStack(app, f"MoodConfig-{config.env_name}", config=config, env=stack_env)

alerts_stack = None
if config.enable_alerts:
    alerts_stack = AlertsStack(
        app,
        f"MoodAlerts-{config.env_name}",
        config=config,
        env=stack_env,
    )

cache_stack = None
redis_host_override = None
if config.enable_elasticache:
    cache_stack = CacheStack(
        app,
        f"MoodCache-{config.env_name}",
        config=config,
        vpc=network.vpc,
        env=stack_env,
    )
    cache_stack.add_dependency(network)
    redis_host_override = cache_stack.redis_endpoint

queue_stack = None
if config.enable_sqs:
    queue_stack = QueueStack(
        app,
        f"MoodQueue-{config.env_name}",
        config=config,
        alert_topic=(alerts_stack.topic if alerts_stack else None),
        env=stack_env,
    )

database_stack = None
if config.enable_rds:
    database_stack = DatabaseStack(
        app,
        f"MoodDatabase-{config.env_name}",
        config=config,
        vpc=network.vpc,
        private_subnets=network.private_subnets,
        env=stack_env,
    )
    database_stack.add_dependency(network)

efs_stack = None
if config.enable_efs:
    efs_stack = EfsStack(
        app,
        f"MoodEfs-{config.env_name}",
        config=config,
        vpc=network.vpc,
        private_subnets=network.private_subnets,
        env=stack_env,
    )
    efs_stack.add_dependency(network)

kinesis_stack = None
if config.enable_kinesis:
    kinesis_stack = KinesisStack(
        app,
        f"MoodKinesis-{config.env_name}",
        config=config,
        alert_topic=(alerts_stack.topic if alerts_stack else None),
        env=stack_env,
    )
    if alerts_stack is not None:
        kinesis_stack.add_dependency(alerts_stack)

compute = ComputeStack(
    app,
    f"MoodCompute-{config.env_name}",
    config=config,
    vpc=network.vpc,
    repository=registry.repository,
    refresh_user_param=config_stack.refresh_user_param,
    refresh_password_param=config_stack.refresh_password_param,
    refresh_secret=config_stack.refresh_secret,
    redis_host_override=redis_host_override,
    queue_url=(queue_stack.refresh_queue.queue_url if queue_stack else None),
    db_endpoint=(database_stack.instance.db_instance_endpoint_address if database_stack else None),
    db_port=(database_stack.instance.db_instance_endpoint_port if database_stack else None),
    db_name=(database_stack.db_name if database_stack else None),
    db_user=(database_stack.db_user if database_stack else None),
    db_password_secret=(database_stack.db_secret if database_stack else None),
    efs_file_system_id=(efs_stack.file_system.file_system_id if efs_stack else None),
    efs_access_point_id=(efs_stack.access_point.access_point_id if efs_stack else None),
    kinesis_stream_name=(kinesis_stack.stream.stream_name if kinesis_stack else None),
    kinesis_stream_arn=(kinesis_stack.stream.stream_arn if kinesis_stack else None),
    env=stack_env,
)
compute.add_dependency(config_stack)
if cache_stack is not None:
    compute.add_dependency(cache_stack)
if queue_stack is not None:
    compute.add_dependency(queue_stack)
if database_stack is not None:
    compute.add_dependency(database_stack)
if efs_stack is not None:
    compute.add_dependency(efs_stack)
if kinesis_stack is not None:
    compute.add_dependency(kinesis_stack)

secret_rotation_stack = None
if config.enable_secret_rotation:
    if config_stack.refresh_secret is None:
        raise ValueError("enableSecretRotation requires secretBackend=secretsmanager")
    secret_rotation_stack = SecretRotationStack(
        app,
        f"MoodSecretRotation-{config.env_name}",
        config=config,
        refresh_secret=config_stack.refresh_secret,
        env=stack_env,
    )
    secret_rotation_stack.add_dependency(config_stack)

obs = ObservabilityStack(
    app,
    f"MoodObservability-{config.env_name}",
    config=config,
    compute=compute,
    alert_topic=(alerts_stack.topic if alerts_stack else None),
    env=stack_env,
)
obs.add_dependency(compute)
if alerts_stack is not None:
    obs.add_dependency(alerts_stack)

adv = AdvancedStack(
    app,
    f"MoodAdvanced-{config.env_name}",
    config=config,
    compute=compute,
    alert_topic=(alerts_stack.topic if alerts_stack else None),
    env=stack_env,
)
adv.add_dependency(compute)
if alerts_stack is not None:
    adv.add_dependency(alerts_stack)

domain_stack = None
if config.enable_tls_domain:
    domain_stack = DomainStack(
        app,
        f"MoodDomain-{config.env_name}",
        config=config,
        compute=compute,
        env=stack_env,
    )
    domain_stack.add_dependency(compute)

app.synth()
