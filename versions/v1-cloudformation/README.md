# Version 1: CloudFormation (Direct YAML)

Pure CloudFormation implementation with optional modules.

## Core stack order

1. `01-network.yaml`
2. `02-ecr.yaml`
3. `03-ssm.yaml`
4. `04-ecs-ec2-alb.yaml`
5. `05-observability.yaml`

## Optional modules

- `optional/alerts-sns.yaml`
- `optional/secret-rotation.yaml`
- `optional/sqs-async.yaml`
- `optional/rds-postgres.yaml`
- `optional/efs.yaml`
- `optional/kinesis.yaml`
- `optional/elasticache.yaml`
- `optional/waf.yaml`
- `optional/cloudfront.yaml`
- `optional/route53-acm.yaml`

## Deploy

```bash
bash versions/v1-cloudformation/scripts/validate.sh
bash versions/v1-cloudformation/scripts/deploy.sh dev free-tier
bash versions/v1-cloudformation/scripts/outputs.sh dev
```

## Showcase deploy with domain + advanced modules

```bash
NETWORK_PROFILE=strict-private \
ENABLE_NAT_GATEWAY=true \
ENABLE_VPC_ENDPOINTS=true \
TASK_SUBNET_TYPE=private \
LOAD_BALANCER_TYPE=alb \
DEPLOYMENT_STRATEGY=bluegreen \
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
ENABLE_ALERTS=true \
ALERT_EMAIL=you@example.com \
ENABLE_TLS_DOMAIN=true \
DOMAIN_NAME=moodoftheday.fun \
SUBDOMAIN=prod \
HOSTED_ZONE_ID=<zone-id> \
bash versions/v1-cloudformation/scripts/deploy.sh prod showcase
```

## Key environment variables

- `ENABLE_VPC_ENDPOINTS`
- `NETWORK_PROFILE`
- `ENABLE_NAT_GATEWAY`
- `TASK_SUBNET_TYPE`
- `LOAD_BALANCER_TYPE`
- `DEPLOYMENT_STRATEGY`
- `SECRET_BACKEND`
- `ENABLE_SECRET_ROTATION`
- `CACHE_BACKEND`
- `ENABLE_ELASTICACHE`
- `ENABLE_SQS`
- `ENABLE_RDS`
- `ENABLE_EFS`
- `ENABLE_KINESIS`
- `ENABLE_WAF`
- `ENABLE_CLOUDFRONT`
- `ENABLE_ALERTS`
- `ALERT_EMAIL`
- `ENABLE_TLS_DOMAIN`
- `DOMAIN_NAME`
- `SUBDOMAIN`
- `HOSTED_ZONE_ID`

## Testing

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
bash versions/v1-cloudformation/scripts/destroy.sh dev
```
