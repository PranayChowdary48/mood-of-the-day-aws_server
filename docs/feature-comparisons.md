# Feature comparisons (repo-specific)

This document compares the implementation options available in this repository and explains which mode fits which objective.

## 1) Ingress mode: ALB vs NLB

| Area | ALB | NLB |
|---|---|---|
| OSI layer | L7 HTTP/HTTPS | L4 TCP |
| Path-based routing | Yes | No |
| Cognito listener auth | Supported (HTTPS) | Not supported |
| WAF association model in this repo | Primary | Not supported in this repo path |
| Blue/green release integration | Primary pattern | Not used |
| Observability emphasis | HTTP-aware | Connection/network-oriented |

**Guidance**

- Use ALB for normal deployments and all advanced modules.
- Use NLB only when showing L4 trade-offs.

## 2) Deployment strategy: rolling vs blue/green

| Area | Rolling | Blue/Green |
|---|---|---|
| Deployment controller | ECS | CodeDeploy |
| Update path | Service task replacement | Traffic shift between task sets |
| Rollback model | Circuit-breaker rollback | CodeDeploy traffic rollback |
| Complexity | Lower | Higher |
| Operational fit | Fast iteration | Safer release boundaries |

**Guidance**

- Rolling for baseline and early integration.
- Blue/green for showcase/prod demonstrations.

## 3) Secret backend: SSM vs Secrets Manager

| Area | SSM Parameter Store | Secrets Manager |
|---|---|---|
| Cost profile | Lower | Higher |
| Secret lifecycle features | Basic | Advanced |
| Native rotation workflows | No | Yes |
| Recommended use in repo | baseline | showcase/prod-like |

## 4) Secret rotation: disabled vs enabled

| Area | Disabled | Enabled |
|---|---|---|
| Simplicity | Higher | Lower |
| Credential aging risk | Higher | Lower |
| Extra resources | None | Rotation Lambda + schedule + permissions |
| Validation needed | basic secret use | secret version transition + app continuity |

## 5) Cache backend: sidecar Redis vs ElastiCache

| Area | Sidecar Redis | ElastiCache Redis |
|---|---|---|
| Ownership | Task-local | Managed service |
| Failure domain | Task lifecycle | Replication-group lifecycle |
| Setup overhead | Low | Medium/High |
| Cost | Lower | Higher |
| Demo value | simple baseline | managed cache pattern |

## 6) Request processing: sync refresh vs async queue

| Area | Sync (`/refresh`) | Async (`/api/refresh` + SQS) |
|---|---|---|
| Client behavior | immediate processing | `202 Accepted` |
| Burst handling | limited | stronger decoupling |
| Retry semantics | request-level only | queue retries + DLQ |
| Operational complexity | lower | higher |

## 7) Persistence tier: no RDS vs RDS enabled

| Area | Without RDS | With RDS |
|---|---|---|
| Durable relational state | No | Yes |
| Data model depth | limited | stronger persistence |
| Health dependency | cache only | cache + DB readiness |
| Cost/ops overhead | lower | higher |

## 8) Shared storage: no EFS vs EFS enabled

| Area | Without EFS | With EFS |
|---|---|---|
| Shared writable filesystem | No | Yes |
| Cross-task file visibility | No | Yes |
| Runtime dependencies | fewer | more |
| Cost/ops overhead | lower | higher |

## 9) Streaming: no Kinesis vs Kinesis enabled

| Area | Without Kinesis | With Kinesis |
|---|---|---|
| Event stream path | absent | present |
| Queue-vs-stream comparison value | low | high |
| Operational footprint | lower | higher |
| Cost profile | lower | higher |

## 10) Network profile: baseline vs strict-private

| Area | Baseline | Strict-private |
|---|---|---|
| Task isolation posture | moderate | stronger |
| NAT dependency | optional | typical |
| Endpoint alignment | optional | common |
| Cost profile | lower | higher |
| Operational depth | lower | higher |

## 11) VPC endpoints: disabled vs enabled

| Area | Disabled | Enabled |
|---|---|---|
| Endpoint hourly cost | none | present |
| Service access path | internet/NAT route | private endpoint route |
| Private traffic posture | moderate | stronger |
| Cost efficiency | higher | lower |

## 12) Edge delivery: ALB direct vs CloudFront + S3 + ALB API

| Area | ALB direct | CloudFront+S3 |
|---|---|---|
| Static delivery | app/LB path | edge cached objects |
| API delivery | direct ALB | `/api/*` forwarded to ALB |
| OAuth callback routing | direct ALB | `/oauth2/*` forwarded to ALB |
| Latency posture | regional | edge-enhanced |
| Complexity/cost | lower | higher |

## 13) Domain/TLS mode: generated endpoints vs Route53+ACM

| Area | AWS-generated endpoint | Custom domain + ACM |
|---|---|---|
| DNS control | minimal | full alias control |
| Certificate lifecycle | default endpoint behavior | explicit certificate control |
| User-facing endpoint quality | lower | higher |
| Dependency surface | lower | higher |

## 14) Auth boundary: no Cognito vs Cognito at ALB

| Area | No Cognito | Cognito enabled |
|---|---|---|
| Auth boundary | app/public path | enforced before app forwarding |
| Unauthenticated behavior | app-defined | hosted login redirect |
| Listener requirements | standard | HTTPS ALB listener required |
| Configuration coupling | lower | higher (domain/callback alignment) |

## 15) Observability: basic checks vs dashboard+alarms+SNS

| Area | Basic checks only | CloudWatch + SNS path |
|---|---|---|
| Operator signal | limited | stronger |
| SLO visibility | limited | explicit SLO-focused metrics |
| Alert fan-out | none | topic/email-capable |
| Cost/ops overhead | lower | higher |

## 16) Validation depth: functional only vs functional+chaos+DR

| Area | Functional only | Functional + chaos + DR |
|---|---|---|
| Confidence in recovery behavior | moderate | higher |
| Failure-mode coverage | narrower | broader |
| Time and resource usage | lower | higher |

## 17) Recommended profiles in this repo

### 17.1 Cost-focused dev profile

- ALB + rolling
- baseline network
- SSM backend
- sidecar cache
- optional CloudFront static only if needed
- no RDS/EFS/Kinesis/ElastiCache unless specifically testing

### 17.2 Full showcase profile

- ALB + blue/green
- strict-private network
- Secrets Manager + rotation
- CloudFront (+ optional custom domain frontdoor)
- Cognito at ALB boundary
- managed integrations (ElastiCache, SQS, RDS, EFS, optional Kinesis)
- full observability + chaos + DR drills

## 18) Current repo boundaries vs next repos

### 18.1 Current repo vs serverless repo

| Area | Current repo (server-based) | Next repo (serverless target) |
|---|---|---|
| Compute model | ECS on EC2 | Lambda/event-driven |
| Scaling primitive | service/ASG scaling | concurrency-driven scaling |
| Entry pattern | ALB/CloudFront | API Gateway/edge-to-function |
| Runtime management | container + host capacity | function-level runtime lifecycle |

### 18.2 Current repo vs Terraform repo

| Area | Current repo | Next repo |
|---|---|---|
| IaC language | CloudFormation YAML | Terraform HCL |
| State handling | stack state in AWS | Terraform state backend |
| Change workflow | stack update/rollback | plan/apply workflow |

### 18.3 Current repo vs CI/CD repo

| Area | Current repo | Next repo |
|---|---|---|
| Deployment trigger | operator-driven scripts | pipeline-driven automation |
| Promotion flow | manual environment progression | gated automated promotion |
| Rollback initiation | operator-driven | policy/pipeline-driven |
| Release metadata | command/script output | pipeline artifacts and audit trail |

This repo is the server-based CloudFormation foundation; serverless architecture, Terraform IaC, and CI/CD automation are intentionally separated into the next repositories.
