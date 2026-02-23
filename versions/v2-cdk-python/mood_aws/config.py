from dataclasses import dataclass
from typing import Any, Mapping


@dataclass(frozen=True)
class EnvConfig:
    env_name: str
    project_name: str
    region: str
    mode: str
    ecs_instance_type: str
    ecs_desired_capacity: int
    app_desired_count: int

    network_profile: str
    enable_vpc_endpoints: bool
    task_subnet_type: str

    load_balancer_type: str
    deployment_strategy: str

    secret_backend: str
    cache_backend: str

    enable_waf: bool
    enable_cloudfront: bool
    enable_static_site: bool
    enable_blue_green: bool
    enable_elasticache: bool

    enable_sqs: bool
    enable_rds: bool
    enable_alerts: bool
    alert_email: str

    enable_efs: bool
    enable_kinesis: bool
    enable_tls_domain: bool
    enable_secret_rotation: bool
    domain_name: str
    hosted_zone_id: str
    subdomain: str


def _is_true(value: Any) -> bool:
    return str(value).lower() == "true"


def _string_ctx(ctx: Mapping[str, Any], key: str, default: str) -> str:
    value = ctx.get(key)
    if value is None:
        return default
    return str(value)


def load_config(raw_env: str | None, raw_mode: str | None, ctx: Mapping[str, Any]) -> EnvConfig:
    env_name = "prod" if raw_env == "prod" else "dev"
    mode = "showcase" if raw_mode == "showcase" else "free-tier"

    default_network_profile = "strict-private" if mode == "showcase" else "baseline"
    network_profile = _string_ctx(ctx, "networkProfile", default_network_profile)
    if network_profile not in {"baseline", "strict-private"}:
        raise ValueError("networkProfile must be baseline or strict-private")

    default_task_subnet = (
        "private"
        if network_profile == "strict-private"
        else ("private" if mode == "showcase" else "public")
    )
    default_enable_endpoints = network_profile == "strict-private" or mode == "showcase"

    load_balancer_type = _string_ctx(ctx, "loadBalancerType", "alb")
    deployment_strategy = _string_ctx(ctx, "deploymentStrategy", "rolling")
    secret_backend = _string_ctx(ctx, "secretBackend", "ssm")
    cache_backend = _string_ctx(ctx, "cacheBackend", "sidecar")
    task_subnet_type = _string_ctx(ctx, "taskSubnetType", default_task_subnet)

    if load_balancer_type not in {"alb", "nlb"}:
        raise ValueError("loadBalancerType must be alb or nlb")

    if deployment_strategy not in {"rolling", "bluegreen"}:
        raise ValueError("deploymentStrategy must be rolling or bluegreen")

    if deployment_strategy == "bluegreen" and load_balancer_type != "alb":
        raise ValueError("bluegreen deployment requires loadBalancerType=alb")

    if secret_backend not in {"ssm", "secretsmanager"}:
        raise ValueError("secretBackend must be ssm or secretsmanager")

    if cache_backend not in {"sidecar", "elasticache"}:
        raise ValueError("cacheBackend must be sidecar or elasticache")

    if task_subnet_type not in {"public", "private"}:
        raise ValueError("taskSubnetType must be public or private")

    enable_elasticache = _is_true(ctx.get("enableElastiCache")) or cache_backend == "elasticache"
    enable_cloudfront = _is_true(ctx.get("enableCloudFront"))
    enable_static_site = _is_true(ctx.get("enableStaticSite")) or enable_cloudfront
    enable_tls_domain = _is_true(ctx.get("enableTlsDomain"))

    if enable_tls_domain and load_balancer_type != "alb":
        raise ValueError("enableTlsDomain requires loadBalancerType=alb")

    enable_secret_rotation = _is_true(ctx.get("enableSecretRotation"))
    if enable_secret_rotation and secret_backend != "secretsmanager":
        raise ValueError("enableSecretRotation requires secretBackend=secretsmanager")

    domain_name = _string_ctx(ctx, "domainName", "moodoftheday.fun")
    hosted_zone_id = _string_ctx(ctx, "hostedZoneId", "")
    subdomain = _string_ctx(ctx, "subdomain", env_name)

    return EnvConfig(
        env_name=env_name,
        project_name="mood",
        region=str(ctx.get("region") or "us-east-1"),
        mode=mode,
        ecs_instance_type="t3.small" if env_name == "prod" and mode == "showcase" else "t3.micro",
        ecs_desired_capacity=2 if env_name == "prod" and mode == "showcase" else 1,
        app_desired_count=2 if env_name == "prod" and mode == "showcase" else 1,
        network_profile=network_profile,
        enable_vpc_endpoints=(
            _is_true(ctx.get("enableVpcEndpoints"))
            if ctx.get("enableVpcEndpoints") is not None
            else default_enable_endpoints
        ),
        task_subnet_type=task_subnet_type,
        load_balancer_type=load_balancer_type,
        deployment_strategy=deployment_strategy,
        secret_backend=secret_backend,
        cache_backend=cache_backend,
        enable_waf=_is_true(ctx.get("enableWaf")),
        enable_cloudfront=enable_cloudfront,
        enable_static_site=enable_static_site,
        enable_blue_green=_is_true(ctx.get("enableBlueGreen")) or deployment_strategy == "bluegreen",
        enable_elasticache=enable_elasticache,
        enable_sqs=_is_true(ctx.get("enableSqs")),
        enable_rds=_is_true(ctx.get("enableRds")),
        enable_alerts=_is_true(ctx.get("enableAlerts")),
        alert_email=_string_ctx(ctx, "alertEmail", ""),
        enable_efs=_is_true(ctx.get("enableEfs")),
        enable_kinesis=_is_true(ctx.get("enableKinesis")),
        enable_tls_domain=enable_tls_domain,
        enable_secret_rotation=enable_secret_rotation,
        domain_name=domain_name,
        hosted_zone_id=hosted_zone_id,
        subdomain=subdomain,
    )
