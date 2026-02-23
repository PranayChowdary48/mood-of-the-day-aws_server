# Testing Guide (Runbook + Evidence Slots)

Use this runbook to prove each capability with command output and screenshots.

## Shared setup

```bash
aws sts get-caller-identity
export ENV_NAME=dev
export LB_DNS=$(aws cloudformation list-exports --query "Exports[?Name=='Mood-${ENV_NAME}-LoadBalancerDnsName'].Value | [0]" --output text)
echo "$LB_DNS"
```

---

## 1) Baseline health

```bash
make smoke ALB_DNS=${LB_DNS}
```

Expected: `/health` and `/` succeed.

Evidence:
- [ ] Smoke output

---

## 2) Blue/Green resources

```bash
make test-bluegreen ENV=${ENV_NAME}
```

Expected: CodeDeploy deployment group present and blue/green style active.

Evidence:
- [ ] Blue/Green output

---

## 3) Strict-private + endpoints

```bash
make test-vpc-endpoints ENV=${ENV_NAME}
```

Expected: endpoints exist and are available.

Evidence:
- [ ] Endpoint table

---

## 4) WAF proof

```bash
make test-waf ENV=${ENV_NAME} ALB_DNS=${LB_DNS} REQUESTS=800 CONCURRENCY=40
```

Expected: blocked requests > 0.

Evidence:
- [ ] WAF test output
- [ ] CloudWatch WAF metric screenshot

---

## 5) ElastiCache proof

```bash
make test-elasticache ENV=${ENV_NAME}
```

Expected: replication group available.

Evidence:
- [ ] ElastiCache output

---

## 6) SQS async refresh + DLQ path

```bash
make test-sqs ENV=${ENV_NAME} ALB_DNS=${LB_DNS}
```

Expected: `/api/refresh` returns `202`; queue attributes visible.

Evidence:
- [ ] Async response output
- [ ] Queue attributes output

---

## 7) RDS proof

```bash
make test-rds ENV=${ENV_NAME}
curl -i http://${LB_DNS}/health
```

Expected: DB `available`; app health ready.

Evidence:
- [ ] RDS status output
- [ ] Health output

---

## 8) EFS shared storage proof

```bash
make test-efs ENV=${ENV_NAME} ALB_DNS=${LB_DNS}
```

Expected: write/read succeeds through `/api/shared/*`.

Evidence:
- [ ] EFS test output

---

## 9) Kinesis event flow proof

```bash
make test-kinesis ENV=${ENV_NAME} ALB_DNS=${LB_DNS}
```

Expected: IncomingRecords metric > 0 after app traffic.

Evidence:
- [ ] Kinesis test output

---

## 10) CloudFront static + API routing proof

```bash
make upload-static ENV=${ENV_NAME}
make test-cloudfront ENV=${ENV_NAME}
```

Expected: static root responds; `/api/health` through CloudFront returns `200`.

Evidence:
- [ ] Static upload output
- [ ] CloudFront test output

---

## 11) Custom domain TLS proof

```bash
make test-tls-domain ENV=${ENV_NAME}
```

Expected: HTTPS `/health` returns `200`; SSL verify result is `0`.

Evidence:
- [ ] TLS test output

---

## 12) Secret rotation proof

```bash
make test-secret-rotation ENV=${ENV_NAME} ALB_DNS=${LB_DNS}
```

Expected: AWSCURRENT version changes; `/refresh` works with rotated credentials.

Evidence:
- [ ] Rotation output
- [ ] Post-rotation refresh output

---

## 13) Chaos suite

```bash
make chaos-suite ENV=${ENV_NAME} ALB_DNS=${LB_DNS}
```

Expected: service recovers after task, instance, and cache disruptions.

Evidence:
- [ ] Chaos suite output

---

## 14) DR drill

```bash
make dr-copy-rds ENV=${ENV_NAME} DR_REGION=us-west-2
make dr-pilot-light ENV=${ENV_NAME} DR_REGION=us-west-2 MODE=free-tier
make dr-drill ENV=${ENV_NAME} DR_REGION=us-west-2 MODE=free-tier
```

Optional failover:

```bash
make dr-failover ENV=${ENV_NAME} DR_REGION=us-west-2 HOSTED_ZONE_ID=<zone-id> DOMAIN_NAME=moodoftheday.fun SUBDOMAIN=${ENV_NAME}
```

Expected: snapshot copy completes; pilot-light deploys in DR region; optional DNS flip succeeds.

Evidence:
- [ ] Snapshot copy output
- [ ] Pilot-light deploy output
- [ ] Route53 failover output
