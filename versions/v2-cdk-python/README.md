# Version 2: CDK Python

Code-first infrastructure path compiled to CloudFormation.

## Stack composition

- `NetworkStack`
- `RegistryStack`
- `ConfigStack`
- `AlertsStack` (optional)
- `SecretRotationStack` (optional)
- `QueueStack` (optional)
- `DatabaseStack` (optional)
- `EfsStack` (optional)
- `KinesisStack` (optional)
- `CacheStack` (optional)
- `ComputeStack`
- `ObservabilityStack`
- `AdvancedStack`
- `DomainStack` (optional)

## Contexts

Core:
- `env=dev|prod`
- `mode=free-tier|showcase`

Feature contexts:
- `region`
- `networkProfile`
- `enableVpcEndpoints`
- `taskSubnetType`
- `loadBalancerType`
- `deploymentStrategy`
- `secretBackend`
- `enableSecretRotation`
- `cacheBackend`
- `enableElastiCache`
- `enableSqs`
- `enableRds`
- `enableEfs`
- `enableKinesis`
- `enableAlerts`
- `alertEmail`
- `enableWaf`
- `enableCloudFront`
- `enableStaticSite`
- `enableTlsDomain`
- `domainName`
- `hostedZoneId`
- `subdomain`

## Typical workflow

```bash
bash versions/v2-cdk-python/scripts/bootstrap.sh
bash versions/v2-cdk-python/scripts/synth.sh dev free-tier
bash versions/v2-cdk-python/scripts/diff.sh dev free-tier
bash versions/v2-cdk-python/scripts/deploy.sh dev free-tier
```

## Showcase deploy example

```bash
NETWORK_PROFILE=strict-private \
ENABLE_VPC_ENDPOINTS=true \
TASK_SUBNET_TYPE=private \
LOAD_BALANCER_TYPE=alb \
DEPLOYMENT_STRATEGY=bluegreen \
ENABLE_BLUEGREEN=true \
SECRET_BACKEND=secretsmanager \
ENABLE_SECRET_ROTATION=true \
CACHE_BACKEND=elasticache \
ENABLE_ELASTICACHE=true \
ENABLE_SQS=true \
ENABLE_RDS=true \
ENABLE_EFS=true \
ENABLE_KINESIS=true \
ENABLE_WAF=true \
ENABLE_CLOUDFRONT=true \
ENABLE_STATIC_SITE=true \
ENABLE_ALERTS=true \
ALERT_EMAIL=you@example.com \
ENABLE_TLS_DOMAIN=true \
DOMAIN_NAME=moodoftheday.fun \
SUBDOMAIN=prod \
HOSTED_ZONE_ID=<zone-id> \
bash versions/v2-cdk-python/scripts/deploy.sh prod showcase
```

## Shared tests

```bash
make smoke ALB_DNS=<lb-dns>
make test-sqs ENV=dev ALB_DNS=<lb-dns>
make test-rds ENV=dev
make test-efs ENV=dev ALB_DNS=<lb-dns>
make test-kinesis ENV=dev ALB_DNS=<lb-dns>
make test-tls-domain ENV=dev
make test-secret-rotation ENV=dev ALB_DNS=<lb-dns>
```

## Destroy

```bash
bash versions/v2-cdk-python/scripts/destroy.sh dev free-tier
```
