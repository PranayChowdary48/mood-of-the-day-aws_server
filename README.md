# Mood AWS (Server-Based, CloudFormation)

- [Project overview](#project-overview)
- [System design goals](#system-design-goals)
- [Scope and non-goals](#scope-and-non-goals)
- [Architecture overview](#architecture-overview)
- [Control plane and data plane](#control-plane-and-data-plane)
- [Core component design](#core-component-design)
- [Optional capability modules](#optional-capability-modules)
- [End-to-end request flows](#end-to-end-request-flows)
- [State, consistency, and data contracts](#state-consistency-and-data-contracts)
- [Scalability model](#scalability-model)
- [Reliability and failure-domain design](#reliability-and-failure-domain-design)
- [Security model](#security-model)
- [Observability and SLO model](#observability-and-slo-model)
- [Deployment and release design](#deployment-and-release-design)
- [Environment profiles](#environment-profiles)
- [How to run](#how-to-run)
- [How to access](#how-to-access)
- [Limitations and trade-offs](#limitations-and-trade-offs)
- [Roadmap to next repositories](#roadmap-to-next-repositories)
- [Operational notes](#operational-notes)
- [One-line takeaway](#one-line-takeaway)
- [Documentation index](#documentation-index)

## Project overview

This repository is a server-based AWS platform implementation of the Mood application, built with a single IaC engine: **CloudFormation YAML**.

The design objective is not only to run the app, but to demonstrate system-level engineering decisions that are usually distributed across multiple repos:

- infrastructure modularity
- release strategy selection
- edge and identity integration
- data-path and async-path behavior
- reliability validation
- DR rehearsal mechanics

The repository is intentionally toggle-driven. The same application image can run under different infrastructure postures (baseline vs showcase) without branching the codebase.

## System design goals

This repo is designed around explicit platform goals.

### 1) Demonstrate production-style server-based architecture

- ECS on EC2 as the primary compute substrate
- ALB-first ingress model with optional edge distribution
- explicit network profiles for baseline and strict-private topologies

### 2) Support comparative design discussion

- ALB vs NLB
- rolling vs blue/green deployments
- SSM vs Secrets Manager
- sidecar Redis vs ElastiCache
- synchronous request path vs queue-backed asynchronous path

### 3) Keep one operational surface for multiple deployment profiles

- feature toggles determine which module set is active
- core stacks remain stable
- optional stacks extend behavior without redefining the whole platform

### 4) Preserve runbook clarity

- command execution is centralized in the testing guide
- README focuses on system design and operating model, not command duplication

## Scope and non-goals

### In-scope

- server-based AWS architecture (ECS on EC2)
- CloudFormation-only IaC
- modular infrastructure stacks
- functional + chaos + DR validation runbooks

### Explicitly out of scope in this repo

- serverless-first implementation (Lambda/API Gateway/event-native runtime)
- Terraform-based IaC implementation
- pipeline-driven CI/CD automation and promotions

These are intentionally reserved for your next repositories.

## Architecture overview

The platform is decomposed into core and optional stacks under `cloudformation/templates`.

### Core stacks

- `01-network.yaml`
- `02-ecr.yaml`
- `03-ssm.yaml`
- `04-ecs-ec2-alb.yaml`
- `05-observability.yaml`

### Optional stacks

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

This split reduces change blast radius and allows staged operational adoption.

## Control plane and data plane

A useful system-design lens for this repo is separation between control plane and data plane responsibilities.

### Control plane responsibilities

- stack lifecycle orchestration
- capacity and placement policy configuration
- deployment strategy configuration
- edge/domain/auth integration wiring
- alarm and notification policy definitions

### Data plane responsibilities

- serving user and API traffic
- processing refresh requests (sync/async)
- reading/writing cache and persistent stores
- publishing telemetry and optional stream events

This separation allows you to reason about failures clearly. For example:

- a stack update failure is control-plane scoped
- a cache timeout is data-plane scoped
- both can coexist and require different remediation paths

## Core component design

### Application layer (`app/`)

The app is a Flask service with endpoints used both for product behavior and platform validation:

- UI render endpoint (`/`)
- API payload endpoint (`/api/mood`)
- refresh endpoints (`/refresh`, `/api/refresh`)
- health/liveness/metrics endpoints
- shared-storage verification endpoints

Behavior is environment-driven to match enabled modules (cache backend, async queue, DB path, stream publisher, asset base URL).

### Compute layer (ECS on EC2)

- ECS service is hosted on EC2-backed capacity provider
- task networking is `awsvpc`
- task count and ASG settings are parameterized per environment
- deployment controller varies by strategy mode (rolling or CodeDeploy)

### Ingress layer

Default ingress is ALB. NLB exists for comparison mode but advanced modules (WAF/Cognito/most routing controls) are ALB-centric.

### Config and secret layer

- baseline and lower-cost mode uses SSM path
- showcase mode can use Secrets Manager + scheduled rotation

### Observability layer

CloudWatch dashboards and alarms provide platform-level visibility across request volume, latency, errors, target health, and optional module-specific signals.

## Optional capability modules

Each optional module has a clear design purpose.

### Edge and delivery modules

- **CloudFront**: static offload and edge caching with API/OAuth forwarding
- **Route53 + ACM**: user-facing DNS and TLS lifecycle management
- **WAF**: edge/LB request filtering and rate-limit protection

### Identity module

- **Cognito**: ALB listener-level auth gate so unauthenticated traffic is redirected before reaching app routes

### Data and integration modules

- **ElastiCache**: managed cache option for resilience and service comparison
- **SQS + DLQ**: asynchronous work decoupling with failure isolation
- **RDS PostgreSQL**: durable relational persistence layer
- **EFS**: shared mutable filesystem across tasks
- **Kinesis**: stream-based event path

### Operations modules

- **Secret rotation**: automated secret lifecycle path
- **SNS alerts**: alarm fan-out channel
- **CodeDeploy blue/green template**: deployment strategy framework

## End-to-end request flows

### Flow A: ALB direct request path

1. Client sends request to ALB.
2. ALB routes to ECS task target.
3. App serves response, optionally touching cache/store integrations.
4. Metrics/logs are emitted to CloudWatch.

### Flow B: CloudFront static + API split

1. Client requests root/static assets.
2. CloudFront serves static objects from S3 origin.
3. API/auth callback paths are forwarded to ALB origin.
4. Dynamic traffic still terminates on ECS service path.

### Flow C: Cognito-protected app/API path

1. Client requests protected endpoint.
2. ALB listener checks authentication state.
3. If unauthenticated, request is redirected to Cognito Hosted UI.
4. After successful auth callback, ALB forwards request to target group.

### Flow D: Synchronous refresh path

1. Client calls refresh endpoint.
2. App computes/updates mood in-band.
3. Response returns refreshed payload directly.

### Flow E: Asynchronous refresh path (SQS enabled)

1. Client calls async refresh endpoint.
2. App enqueues job and returns accepted status.
3. Worker loop consumes queue message.
4. Processing result updates state.
5. Failures move to DLQ after retry policy.

### Flow F: Blue/green release path

1. New task definition/image revision is prepared.
2. CodeDeploy creates replacement task set in green target group.
3. Health checks validate green path.
4. Traffic shifts based on deployment policy.
5. Rollback path remains available at deployment-controller level.

## State, consistency, and data contracts

The system has multiple state domains with different consistency semantics.

### Cached state

- sidecar Redis or ElastiCache stores frequently accessed mood data
- optimized for speed and volatility
- not treated as authoritative long-term record

### Durable relational state (optional)

- RDS-backed mode adds system-of-record persistence for history-like data
- health checks include DB readiness in this mode

### Shared filesystem state (optional)

- EFS mode enables cross-task shared file visibility
- useful for demonstrating shared POSIX behavior

### Queue/stream state (optional)

- SQS preserves delivery/retry semantics for async jobs
- Kinesis path demonstrates event stream publication model

Design implication: the platform intentionally uses mixed state mechanisms to show the trade-offs between low-latency cache, durable storage, shared filesystem, and asynchronous/event semantics.

## Scalability model

### Horizontal scaling

- ECS service desired count is tunable
- ASG capacity can be tuned for cluster headroom
- queue-based async path decouples request pressure from processing throughput

### Edge scaling

- CloudFront offloads static traffic and reduces repeated origin fetches
- ALB continues to scale dynamic request distribution across tasks

### Operational scaling constraints

- ECS on EC2 requires balancing task resources vs instance capacity
- blue/green requires temporary duplicate capacity during deployment windows
- strict-private profile adds networking dependencies that must scale with workload

## Reliability and failure-domain design

Reliability is treated as layered behavior rather than a single setting.

### Failure domains

- task-level failures (container crash, health-check failure)
- instance-level failures (node termination)
- cache/data-path failures
- edge/integration misconfiguration failures (domain/callback/cert mismatches)

### Recovery mechanisms

- ECS service replacement behavior
- ASG instance replacement behavior
- deployment controller rollback semantics
- queue DLQ fallback for async failures

### Validation strategy

- functional module tests to confirm expected behavior
- chaos scripts to validate self-healing assumptions
- DR scripts for regional backup/pilot-light workflows

## Security model

### Network security posture

- security-group segmented ingress path
- baseline and strict-private topology choices
- optional endpoint strategy for private service access

### Identity and authentication

- optional Cognito boundary at ALB listener
- auth gate outside app routes reduces app-level auth coupling
- callback/logout URL correctness is required for stable auth flow

### Secret management

- SSM for basic/lower-cost secret path
- Secrets Manager for richer lifecycle and rotation workflows

### Edge protection

- optional WAF with managed protections and rate controls
- CloudWatch visibility on block activity

### TLS and domain posture

- ACM-backed cert management for custom domains
- CloudFront frontdoor mode requires us-east-1 certificate alignment

## Observability and SLO model

The observability design includes both service telemetry and operator-facing alerting.

### Telemetry sources

- app logs
- ALB/access-level metrics
- ECS/service health metrics
- optional module metrics (WAF, queue/dead-letter, stream)

### Dashboard model

- request and error visibility
- latency visibility
- target health visibility
- SLO-style availability perspective

### Alerting model

- CloudWatch alarms as threshold controls
- optional SNS topic/email fan-out
- alarms tied to both availability and security behavior when enabled

## Deployment and release design

### Modular stack deployment order

Core stacks are deployed first; optional stacks are attached based on environment toggles.

### Strategy-aware deployment behavior

- rolling mode: ECS deployment controller updates task set directly
- blue/green mode: CodeDeploy manages task-set replacement and traffic shift

### Operational nuance

When ECS service is under CodeDeploy controller, release updates should follow CodeDeploy flow to avoid controller mismatch errors.

### Why staged bootstrap exists

Some advanced combinations (edge + domain + auth + blue/green) have dependency timing constraints. A staged bootstrap approach minimizes first-deploy convergence failures in complex profiles.

## Environment profiles

### Baseline / lower-cost profile

- ALB + rolling
- minimal optional modules
- straightforward networking
- faster iteration and lower spend

### Showcase / production-pattern profile

- strict-private networking model
- optional edge + domain + auth stack
- managed integrations enabled as needed
- blue/green releases
- full validation path (functional + chaos + DR)

## How to run

All execution commands are intentionally centralized in `docs/testing-guide.md`.

That runbook includes:

- environment setup
- deployment sequences
- blue/green release steps
- functional tests
- chaos and DR drills
- cleanup and destroy

README remains command-free by design so run instructions stay in one source of truth.

## How to access

Access behavior depends on active modules.

- **ALB direct mode**: direct app/API path via ALB DNS.
- **CloudFront static mode**: root/static from S3 through CloudFront, dynamic paths forwarded to ALB.
- **Domain mode**: Route53 aliases with ACM TLS.
- **Cognito mode**: login boundary enforced before protected app paths are forwarded.

Endpoint behavior validation is documented in `docs/testing-guide.md`.

## Limitations and trade-offs

This section intentionally captures system-design limitations so the next repositories can be scoped cleanly.

### 1) Architecture scope limitation

The current repo is server-based ECS on EC2. It does not express serverless operating characteristics such as Lambda concurrency model, event-native fan-out, or API Gateway policy semantics.

### 2) IaC scope limitation

The current repo uses CloudFormation only. It does not demonstrate Terraform state backends, workspace strategy, provider version pinning patterns, or plan-file approval workflows.

### 3) Delivery automation limitation

Deployments are operator-driven through scripts and Make targets. This is explicit and testable, but lacks:

- automated promotion gates
- build/deploy policy enforcement
- automated rollback governance
- pipeline artifact lineage

### 4) Complexity trade-off

The toggle model is flexible but introduces combinatorial behavior. Without strict profile guardrails, invalid combinations can produce convergence failures.

### 5) Cost trade-off

Showcase modules materially increase cost surface (NAT, endpoints, CloudFront, WAF, ElastiCache, RDS, EFS, Kinesis). Baseline mode reduces cost but also reduces production parity.

### 6) DR trade-off

DR here is runbook/script-driven. It demonstrates process capability, but not fully automated active-active failover behavior.

### 7) Operational ownership trade-off

ECS on EC2 provides strong control, but infrastructure responsibility remains high:

- capacity planning
- instance-level availability and replacement concerns
- deployment resource headroom for blue/green

## Roadmap to next repositories

This repo is the foundation layer. Next repos should map to the following system-design expansions.

### Next repo 1: Serverless architecture

Target questions to answer:

- how the same product behavior maps to Lambda/API Gateway/event services
- where cost/scale curves differ from ECS on EC2
- which failure and observability patterns simplify or become more complex

### Next repo 2: Terraform architecture

Target questions to answer:

- how stack decomposition maps to Terraform module boundaries
- how state management and environment promotion are controlled
- how change-review workflows differ from CloudFormation

### Next repo 3: CI/CD and automation

Target questions to answer:

- how deployment approvals and rollbacks are automated
- how test gates and drift checks become mandatory
- how release provenance and audit trails are generated end-to-end

## Operational notes

- Keep `docs/testing-guide.md` as the single command/runbook source.
- Keep `docs/architecture.md` as the component-level design reference.
- Keep `docs/feature-comparisons.md` as the trade-off matrix when selecting deployment profiles.
- Treat `cloudformation/params/*.json` as environment contract files.
- Prefer profile consistency over ad-hoc toggle mixing when doing repeatable deployments.

## One-line takeaway

This repository is a system-design-heavy, server-based AWS platform blueprint that demonstrates broad production patterns on ECS/CloudFormation, while deliberately reserving serverless, Terraform, and CI/CD automation for dedicated follow-up repositories.

- K8s: https://github.com/PranayChowdary48/mode-of-the-day-k8s
- AWS: 

## Documentation index

- `docs/architecture.md` - deep architecture walkthrough for runtime and infrastructure modules
- `docs/feature-comparisons.md` - design trade-offs across all major feature choices
- `docs/testing-guide.md` - deployment, validation, chaos, and DR runbook commands
- `cloudformation/README.md` - CloudFormation module structure and script entry points
