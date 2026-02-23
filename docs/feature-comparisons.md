# Feature Comparisons

## 1) IaC style

| Area | CloudFormation (v1) | CDK Python (v2) |
|---|---|---|
| Authoring | Direct YAML | Python constructs -> CloudFormation |
| Review model | Template-centric | Code-centric |
| Best fit | AWS-native infra teams | Platform-engineering style teams |

## 2) ALB vs NLB

| Area | ALB | NLB |
|---|---|---|
| Layer | L7 HTTP | L4 TCP |
| WAF support | Yes | No |
| Blue/Green path | Yes | Not used |
| App-aware metrics | Richer | More network-centric |

Toggle: `LOAD_BALANCER_TYPE=alb|nlb`

## 3) Rolling vs Blue/Green

| Area | Rolling | Blue/Green |
|---|---|---|
| Complexity | Lower | Higher |
| Blast radius | Moderate | Lower with traffic control |
| Rollback style | ECS circuit breaker | CodeDeploy traffic rollback |

Toggle: `DEPLOYMENT_STRATEGY=rolling|bluegreen`

## 4) SSM vs Secrets Manager (+ rotation)

| Area | SSM | Secrets Manager |
|---|---|---|
| Cost | Lower | Higher |
| Rotation lifecycle | Manual/custom | Native rotation support |
| Fit | Config/light secret use | Strong secret lifecycle control |

Toggles:
- `SECRET_BACKEND=ssm|secretsmanager`
- `ENABLE_SECRET_ROTATION=true`

## 5) Cache/data path choices

| Area | Sidecar Redis | ElastiCache | RDS |
|---|---|---|---|
| Role | Local cache | Managed cache | Durable relational store |
| Ops overhead | App-owned | AWS-managed | AWS-managed DB operations |
| Durability | Low | Medium | High |

Toggles:
- `CACHE_BACKEND=sidecar|elasticache`
- `ENABLE_RDS=true`

## 6) Sync vs async refresh

| Area | Sync | Async (SQS+DLQ) |
|---|---|---|
| API behavior | Immediate response payload | `202 Accepted` + queued work |
| Burst handling | Limited | Better backpressure handling |
| Failure model | Direct request-path failures | Retries + DLQ |

Toggle: `ENABLE_SQS=true`

## 7) Filesystem choices

| Area | S3 | EFS |
|---|---|---|
| Storage model | Object | Shared POSIX filesystem |
| Typical use | Static assets, artifacts | Shared mutable files between tasks |
| Cost profile | Lower baseline | Higher |

Toggle: `ENABLE_EFS=true`

## 8) Queue vs stream

| Area | SQS | Kinesis |
|---|---|---|
| Pattern | Work queue | Event stream |
| Ordering/throughput model | Queue semantics | Ordered shard semantics |
| Consumer model | Pull worker | Stream consumers/analytics |

Toggle: `ENABLE_KINESIS=true`

## 9) Direct LB vs CloudFront edge

| Area | ALB direct | CloudFront + S3 + ALB API |
|---|---|---|
| Static delivery | App/LB path | Edge cached from S3 |
| API path | direct `/api/*` | `/api/*` forwarded to ALB |
| Global latency profile | Regional | Better edge distribution |

Toggle: `ENABLE_CLOUDFRONT=true`

## 10) No custom domain vs Route53+ACM TLS

| Area | AWS-generated DNS | Custom domain TLS |
|---|---|---|
| URL | ALB/CloudFront generated host | `*.moodoftheday.fun` style host |
| Cert lifecycle | Implicit/default endpoint certs | ACM-managed custom cert |
| DNS control | None | Route53 alias control |

Toggles:
- `ENABLE_TLS_DOMAIN=true`
- `DOMAIN_NAME`, `SUBDOMAIN`, `HOSTED_ZONE_ID`

## 11) Single-region vs DR automation scripts

| Area | Single-region focus | Scripted DR drill |
|---|---|---|
| Recovery | Manual ad-hoc | Snapshot copy + pilot-light + DNS failover scripts |
| Complexity | Lower | Higher |
| Cost | Lower | Higher when exercised |

Targets:
- `dr-copy-rds`
- `dr-pilot-light`
- `dr-failover`
- `dr-drill`
