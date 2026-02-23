# Architecture Deep Dive

## 1) Core platform

- VPC across 2 AZs
- ECS on EC2 (ASG-backed)
- ALB (default) or NLB (comparison mode)
- App service with Redis cache path
- CloudWatch logs, dashboards, alarms

## 2) Network profiles

### Baseline
- simpler routing, lower cost defaults

### Strict-private
- private task placement pattern
- NAT-backed private egress path
- optional VPC endpoints for AWS service access

## 3) Data and integration layers

- Redis sidecar (baseline cache)
- ElastiCache Redis (managed cache option)
- RDS PostgreSQL (durable store option)
- EFS (shared filesystem option)
- SQS + DLQ (async refresh path)
- Kinesis stream (event streaming path)

## 4) Edge and ingress

- ALB path for API ingress
- optional WAF for L7 protection
- optional CloudFront+S3 for static assets with `/api/*` routed to ALB
- optional Route53+ACM custom-domain TLS on ALB

## 5) Secrets and configuration

- SSM or Secrets Manager backend
- optional Secrets Manager rotation Lambda/schedule

## 6) Observability and SLO

- CloudWatch dashboard with request/error/latency/availability signals
- alarms for 5xx, unhealthy hosts, p95 latency, SLO availability
- optional SNS notification integration
- WAF/SQS/Kinesis module-specific alarm signals

## 7) Resilience and DR

- chaos tests for task kill, instance loss, cache outage
- DR scripts for RDS snapshot copy, pilot-light deploy, and Route53 failover
- region-level recovery is runbook/script-driven (not full active-active)

## 8) Why this shape

This architecture lets you compare production-like AWS patterns in one repo while keeping baseline deployment practical and feature flags explicit.
