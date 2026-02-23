# Mood AWS (Server-Based): CloudFormation + CDK Python

This repo implements the same server-based AWS platform in two IaC paths:

1. `versions/v1-cloudformation/` (pure CloudFormation YAML)
2. `versions/v2-cdk-python/` (CDK in Python)

The app is reused from your k8s repo and now supports additional AWS integrations (SQS, RDS, Kinesis, EFS, domain TLS).

---

## 1) Deployment dimensions

### IaC style
- **v1 CloudFormation**: template-first AWS-native flow
- **v2 CDK Python**: code-first constructs synthesized to CloudFormation

### Environment
- `dev`: low-cost validation
- `prod`: higher baseline sizing

### Mode
- `free-tier`: baseline cost profile
- `showcase`: deeper architecture profile

---

## 2) Feature matrix

| Feature | Baseline | Optional toggle |
|---|---|---|
| ECS on EC2 + ALB | Yes | `LOAD_BALANCER_TYPE=alb` |
| NLB variant | No | `LOAD_BALANCER_TYPE=nlb` |
| Rolling deployments | Yes | `DEPLOYMENT_STRATEGY=rolling` |
| Blue/Green (CodeDeploy) | No | `DEPLOYMENT_STRATEGY=bluegreen` |
| SSM secret backend | Yes | `SECRET_BACKEND=ssm` |
| Secrets Manager backend | No | `SECRET_BACKEND=secretsmanager` |
| Secret rotation Lambda/schedule | No | `ENABLE_SECRET_ROTATION=true` |
| Redis sidecar | Yes | `CACHE_BACKEND=sidecar` |
| ElastiCache Redis | No | `CACHE_BACKEND=elasticache` |
| SQS + DLQ async refresh | No | `ENABLE_SQS=true` |
| RDS PostgreSQL | No | `ENABLE_RDS=true` |
| EFS shared filesystem | No | `ENABLE_EFS=true` |
| Kinesis event stream | No | `ENABLE_KINESIS=true` |
| WAF | No | `ENABLE_WAF=true` |
| CloudFront + S3 static + `/api/*` to ALB | No | `ENABLE_CLOUDFRONT=true` |
| Route53 + ACM custom-domain TLS | No | `ENABLE_TLS_DOMAIN=true` |
| SNS alarm notifications | No | `ENABLE_ALERTS=true` + `ALERT_EMAIL=` |
| Strict-private network profile | No | `NETWORK_PROFILE=strict-private` |
| VPC endpoints | Mode-dependent | `ENABLE_VPC_ENDPOINTS=true` |
| DR scripts (snapshot/pilot-light/failover) | No | `dr-*` Make targets |

---

## 3) Quick setup

```bash
cd /Users/pranaychowd.pinapaka/Desktop/Projects/mood-AWS
make help
```

### v1 CloudFormation

```bash
make v1-validate
make v1-deploy ENV=dev MODE=free-tier
make v1-outputs ENV=dev
```

### v2 CDK Python

```bash
make v2-bootstrap
make v2-synth ENV=dev MODE=free-tier
make v2-diff ENV=dev MODE=free-tier
make v2-deploy ENV=dev MODE=free-tier
```

---

## 4) Full showcase example (with your domain)

```bash
make v1-deploy \
  ENV=prod MODE=showcase \
  NETWORK_PROFILE=strict-private ENABLE_NAT_GATEWAY=true ENABLE_VPC_ENDPOINTS=true TASK_SUBNET_TYPE=private \
  LOAD_BALANCER_TYPE=alb DEPLOYMENT_STRATEGY=bluegreen \
  SECRET_BACKEND=secretsmanager ENABLE_SECRET_ROTATION=true \
  CACHE_BACKEND=elasticache ENABLE_ELASTICACHE=true \
  ENABLE_SQS=true ENABLE_RDS=true ENABLE_EFS=true ENABLE_KINESIS=true \
  ENABLE_WAF=true ENABLE_CLOUDFRONT=true \
  ENABLE_ALERTS=true ALERT_EMAIL=you@example.com \
  ENABLE_TLS_DOMAIN=true DOMAIN_NAME=moodoftheday.fun SUBDOMAIN=prod HOSTED_ZONE_ID=<your-zone-id>
```

CDK equivalent:

```bash
make v2-deploy \
  ENV=prod MODE=showcase \
  NETWORK_PROFILE=strict-private ENABLE_VPC_ENDPOINTS=true TASK_SUBNET_TYPE=private \
  LOAD_BALANCER_TYPE=alb DEPLOYMENT_STRATEGY=bluegreen ENABLE_BLUEGREEN=true \
  SECRET_BACKEND=secretsmanager ENABLE_SECRET_ROTATION=true \
  CACHE_BACKEND=elasticache ENABLE_ELASTICACHE=true \
  ENABLE_SQS=true ENABLE_RDS=true ENABLE_EFS=true ENABLE_KINESIS=true \
  ENABLE_WAF=true ENABLE_CLOUDFRONT=true ENABLE_STATIC_SITE=true \
  ENABLE_ALERTS=true ALERT_EMAIL=you@example.com \
  ENABLE_TLS_DOMAIN=true DOMAIN_NAME=moodoftheday.fun SUBDOMAIN=prod HOSTED_ZONE_ID=<your-zone-id>
```

---

## 5) Build + static upload

```bash
AWS_ACCOUNT_ID=<account-id> AWS_REGION=us-east-1 ENV_NAME=dev IMAGE_TAG=latest make image-push
make upload-static ENV=dev
```

---

## 6) Test targets

```bash
make smoke ALB_DNS=<lb-dns>
make test-vpc-endpoints ENV=dev
make test-bluegreen ENV=dev
make test-waf ENV=dev ALB_DNS=<lb-dns>
make test-elasticache ENV=dev
make test-sqs ENV=dev ALB_DNS=<lb-dns>
make test-rds ENV=dev
make test-efs ENV=dev ALB_DNS=<lb-dns>
make test-kinesis ENV=dev ALB_DNS=<lb-dns>
make test-cloudfront ENV=dev
make test-tls-domain ENV=dev
make test-secret-rotation ENV=dev ALB_DNS=<lb-dns>
make chaos-suite ENV=dev ALB_DNS=<lb-dns>
```

Detailed evidence-oriented runbook: `docs/testing-guide.md`

---

## 7) DR automation targets

```bash
make dr-copy-rds ENV=prod DR_REGION=us-west-2
make dr-pilot-light ENV=prod DR_REGION=us-west-2 MODE=free-tier
make dr-failover ENV=prod DR_REGION=us-west-2 HOSTED_ZONE_ID=<zone-id> DOMAIN_NAME=moodoftheday.fun SUBDOMAIN=prod
make dr-drill ENV=prod DR_REGION=us-west-2 MODE=free-tier
```

---

## 8) Cleanup

```bash
make v1-destroy ENV=dev
make v2-destroy ENV=dev MODE=free-tier
```

---

## 9) Docs map

- `docs/architecture.md`
- `docs/feature-comparisons.md`
- `docs/testing-guide.md`
- `versions/v1-cloudformation/README.md`
- `versions/v2-cdk-python/README.md`
