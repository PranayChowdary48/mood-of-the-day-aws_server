# Architecture overview

## 1) Scope and intent

This repository implements a **server-based** AWS platform for the Mood app using CloudFormation stack modules. It is intentionally built as a toggle-driven architecture so the same codebase can run in:

- a lower-cost baseline profile for day-to-day development
- a full showcase profile for production-style demonstrations

The architecture is centered on ECS on EC2 and expands through optional modules rather than separate forks.

## 2) Stack model and dependency order

### 2.1 Core stacks (always present)

1. `01-network.yaml`
2. `02-ecr.yaml`
3. `03-ssm.yaml`
4. `04-ecs-ec2-alb.yaml`
5. `05-observability.yaml`

### 2.2 Optional stacks (feature-gated)

- `optional/alerts-sns.yaml`
- `optional/secret-rotation.yaml`
- `optional/sqs-async.yaml`
- `optional/rds-postgres.yaml`
- `optional/efs.yaml`
- `optional/kinesis.yaml`
- `optional/elasticache.yaml`
- `optional/cognito.yaml`
- `optional/route53-acm.yaml`
- `optional/waf.yaml`
- `optional/cloudfront.yaml`
- `optional/codedeploy-bluegreen.yaml`

This decomposition limits blast radius during updates and lets you enable advanced features only when needed.

## 3) Runtime architecture

### 3.1 Core runtime path

- ECS cluster uses EC2 capacity provider backed by ASG.
- App tasks run in `awsvpc` mode.
- ALB is default ingress; NLB is available for L4 comparison scenarios.
- CloudWatch Logs captures service logs.

### 3.2 Request flow variants

#### Mode A: ALB direct

Client -> ALB -> ECS service -> app container -> cache/storage/integration services.

#### Mode B: CloudFront static + API forwarding

Client -> CloudFront

- `/` and static assets -> S3 origin
- `/api/*` and `/oauth2/*` -> ALB origin

This reduces static load on ECS while preserving dynamic API/auth routing.

#### Mode C: CloudFront frontdoor with custom domain

Client -> `https://<subdomain>.<domain>` (CloudFront alias)

- static paths stay at edge/S3
- API and OAuth callback paths go to ALB
- certificate is managed in ACM us-east-1 for CloudFront distribution

### 3.3 Authentication boundary

When Cognito is enabled, authentication happens at the ALB listener (`authenticate-cognito`) before app traffic is forwarded.

Key implications in this repo:

- app layer remains auth-light (no app-level identity provider flow)
- ALB HTTPS listener is mandatory for Cognito action
- callback/logout URLs must match domain/frontdoor routing

Health paths can be bypassed from auth where configured so infrastructure checks remain operational.

## 4) Deployment architecture

### 4.1 Rolling strategy

- ECS deployment controller handles task replacement.
- Circuit breaker can rollback failed rollouts.
- Lower operational complexity and good for iterative changes.

### 4.2 Blue/green strategy

- ECS service uses CodeDeploy deployment controller.
- Blue/green target groups plus listener/test-listener pattern are used for cutover.
- Releases are triggered via `scripts/deploy/bluegreen_codedeploy.sh`.
- Safer production-style rollout, but stricter lifecycle constraints.

Notable operational rule: when a service is already under `CODE_DEPLOY`, task-definition updates must be driven by CodeDeploy release flow rather than direct ECS update behavior.

## 5) Network architecture

### 5.1 Profiles

- **Baseline profile**: simpler subnet/egress behavior for lower cost and faster iteration.
- **Strict-private profile**: private task placement plus NAT and optional endpoints for stronger isolation.

### 5.2 Security boundaries

- ALB SG accepts external ingress on listener ports.
- Task SG accepts traffic only from ALB SG (for ALB mode).
- Managed service access is restricted to required ports and SG relationships.

### 5.3 VPC endpoint mode

Optional endpoint deployment supports private access patterns for AWS services from private workloads. This improves private traffic posture at additional hourly cost.

## 6) Data and integration architecture

### 6.1 Cache layer

- `CACHE_BACKEND=sidecar`: Redis sidecar per task (simple, low-cost baseline).
- `CACHE_BACKEND=elasticache`: managed Redis replication group (showcase managed-cache path).

### 6.2 Async work path

- `ENABLE_SQS=true` enables queue-based refresh processing.
- API can return `202 Accepted` while background worker processes jobs.
- DLQ path captures repeated failures.

### 6.3 Relational persistence

- `ENABLE_RDS=true` adds PostgreSQL persistence for mood history.
- App health path includes DB readiness checks when DB mode is active.

### 6.4 Shared filesystem

- `ENABLE_EFS=true` mounts shared storage to tasks.
- `/api/shared/write` and `/api/shared/read` endpoints validate cross-task shared-file behavior.

### 6.5 Event streaming

- `ENABLE_KINESIS=true` enables event publishing path from app runtime.

## 7) Config and secret architecture

### 7.1 Config/secret backend choice

- SSM Parameter Store for simpler/cheaper secret handling.
- Secrets Manager for richer lifecycle and integration patterns.

### 7.2 Rotation path

- `ENABLE_SECRET_ROTATION=true` adds scheduled Secrets Manager rotation infrastructure.
- Rotation is validated through app behavior after version transition.

## 8) Edge, domain, and security modules

### 8.1 WAF

- Optional WAF web ACL with managed protections and rate-limit rule.
- CloudWatch metrics/alarms surface blocked request behavior.

### 8.2 Route53 + ACM

- Optional custom-domain aliases for app/API endpoints.
- Supports ALB direct domain mode and CloudFront-frontdoor domain mode.

### 8.3 CloudFront

- Static-origin distribution with API/OAuth forwarding rules.
- Optional alias + ACM cert binding for frontdoor usage.
- `scripts/upload_static_assets.sh` syncs static content and invalidates cache.

## 9) Observability architecture

- CloudWatch dashboard includes request, latency, error, and target health perspectives.
- SLO-style availability metrics and alarms are included.
- Optional SNS alarm fan-out via alerts stack.
- Optional module-specific checks (WAF, queue/dead-letter, streaming) are available through test scripts.

## 10) Resilience and DR architecture

### 10.1 Chaos validation

Chaos scripts cover:

- task termination recovery
- EC2 instance termination recovery
- cache disruption behavior

### 10.2 DR runbook automation

DR scripts support:

- RDS snapshot copy to DR region
- pilot-light deployment
- Route53 failover operations
- combined drill execution

This is runbook/script-driven DR, not active-active multi-region runtime.

## 11) Application feature surface used by infrastructure tests

The app exposes endpoints that map directly to infrastructure feature checks:

- `/` - UI render path
- `/api/mood` - API mood payload
- `/api/login` - login entry redirect path
- `/refresh` and `/api/refresh` - sync/async refresh behavior
- `/api/shared/read` and `/api/shared/write` - EFS validation
- `/metrics` - Prometheus-style metrics output
- `/health` and `/live` - readiness/liveness probes
- `/whoami` - task identity check during scaling/chaos

## 12) Cost-shaping controls

The architecture is intentionally parameterized for cost governance:

- baseline profile for lower-cost iteration
- showcase profile for production-style feature breadth
- explicit opt-in for cost-heavy modules (NAT, endpoints, CloudFront, WAF, ElastiCache, RDS, EFS, Kinesis)

## 13) Why this architecture fits this repo

This repo is designed to maximize server-based AWS architecture coverage with explicit, testable module boundaries. It is a practical foundation for demonstrating infrastructure depth before moving to the next repos.

## 14) Boundaries for next repos

This repo intentionally does **not** cover these as primary implementations:

- serverless runtime architecture (next repo)
- Terraform IaC path (next repo)
- CI/CD-driven deployment automation and promotions (next repo)
