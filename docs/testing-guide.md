# Testing guide (deployment + validation runbook)

This document is the command source for deploying, validating, and cleaning up this repository.

## 1) Preconditions

- AWS CLI is authenticated to the correct account.
- Target region is set (examples use `ap-northeast-1`).
- You are in repo root: `/Users/pranaychowd.pinapaka/Desktop/Projects/mood-AWS`.
- For custom domain/TLS/frontdoor/Cognito flows, Route53 hosted zone + ACM certs are available.

## 2) Shared environment setup

```bash
cd /Users/pranaychowd.pinapaka/Desktop/Projects/mood-AWS
aws sts get-caller-identity

# Core environment selection
export AWS_REGION=ap-northeast-1
export ENV_NAME=dev
export MODE=showcase

# Domain context
export DOMAIN_NAME=moodoftheday.fun
export SUBDOMAIN=dev
export ALERT_EMAIL="you@example.com"
```

Resolve hosted zone:

```bash
export HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${DOMAIN_NAME}." \
  --query "HostedZones[0].Id" --output text | sed 's#/hostedzone/##')

echo "HOSTED_ZONE_ID=$HOSTED_ZONE_ID"
```

Resolve CloudFront certificate in `us-east-1`:

```bash
export CLOUDFRONT_CERT_ARN=$(aws acm list-certificates --region us-east-1 \
  --query "CertificateSummaryList[?DomainName=='${SUBDOMAIN}.${DOMAIN_NAME}'].CertificateArn | [0]" \
  --output text)

echo "CLOUDFRONT_CERT_ARN=$CLOUDFRONT_CERT_ARN"
```

If the CloudFront cert is missing, request one (DNS validation required):

```bash
export CLOUDFRONT_CERT_ARN=$(aws acm request-certificate --region us-east-1 \
   --domain-name "${SUBDOMAIN}.${DOMAIN_NAME}" \
   --validation-method DNS \
   --query CertificateArn --output text)
```

## 3) Template and script validation

```bash
# Validate all CloudFormation templates
make cf-validate

# List available orchestration targets
make help
```

## 4) Optional registry bootstrap + image push

If ECR stack is not yet created for your target env:

```bash
aws cloudformation deploy \
  --stack-name mood-${ENV_NAME}-registry \
  --template-file cloudformation/templates/02-ecr.yaml \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --parameter-overrides EnvName=${ENV_NAME}
```

Build and push app image:

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export IMAGE_TAG=latest

AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID AWS_REGION=$AWS_REGION ENV_NAME=$ENV_NAME IMAGE_TAG=$IMAGE_TAG make image-push
```

## 5) Deployment paths

## 5.1 Full rolling deployment (single-phase)

Use this when you want all major modules with rolling strategy:

```bash
make cf-deploy ENV=$ENV_NAME MODE=$MODE \
  LOAD_BALANCER_TYPE=alb DEPLOYMENT_STRATEGY=rolling \
  SECRET_BACKEND=secretsmanager ENABLE_SECRET_ROTATION=true ROTATION_DAYS=7 \
  NETWORK_PROFILE=strict-private ENABLE_VPC_ENDPOINTS=true ENABLE_NAT_GATEWAY=true TASK_SUBNET_TYPE=private \
  ENABLE_WAF=true ENABLE_CLOUDFRONT=true ENABLE_CLOUDFRONT_FRONTDOOR=true \
  ENABLE_TLS_DOMAIN=true ENABLE_COGNITO=true \
  DOMAIN_NAME=$DOMAIN_NAME SUBDOMAIN=$SUBDOMAIN HOSTED_ZONE_ID=$HOSTED_ZONE_ID \
  CLOUDFRONT_CERT_ARN=$CLOUDFRONT_CERT_ARN \
  COGNITO_CALLBACK_URL="https://${SUBDOMAIN}.${DOMAIN_NAME}/oauth2/idpresponse" \
  COGNITO_LOGOUT_URL="https://${SUBDOMAIN}.${DOMAIN_NAME}/" API_SUBDOMAIN_LABEL=api \
  CACHE_BACKEND=elasticache ENABLE_ELASTICACHE=true \
  ENABLE_SQS=true ENABLE_RDS=true ENABLE_EFS=true ENABLE_KINESIS=false \
  ENABLE_ALERTS=true ALERT_EMAIL=$ALERT_EMAIL
```

## 5.2 Safe bootstrap for advanced mode (two-phase)

Use this when first-time advanced deploy has integration instability.

Phase 1 (Cognito off, rolling):

```bash
make cf-deploy ENV=$ENV_NAME MODE=$MODE \
  LOAD_BALANCER_TYPE=alb DEPLOYMENT_STRATEGY=rolling \
  SECRET_BACKEND=secretsmanager ENABLE_SECRET_ROTATION=true ROTATION_DAYS=7 \
  NETWORK_PROFILE=strict-private ENABLE_VPC_ENDPOINTS=true ENABLE_NAT_GATEWAY=true TASK_SUBNET_TYPE=private \
  ENABLE_WAF=true ENABLE_CLOUDFRONT=true ENABLE_CLOUDFRONT_FRONTDOOR=true \
  ENABLE_TLS_DOMAIN=true ENABLE_COGNITO=false \
  DOMAIN_NAME=$DOMAIN_NAME SUBDOMAIN=$SUBDOMAIN HOSTED_ZONE_ID=$HOSTED_ZONE_ID \
  CLOUDFRONT_CERT_ARN=$CLOUDFRONT_CERT_ARN API_SUBDOMAIN_LABEL=api \
  CACHE_BACKEND=elasticache ENABLE_ELASTICACHE=true \
  ENABLE_SQS=true ENABLE_RDS=true ENABLE_EFS=true ENABLE_KINESIS=false \
  ENABLE_ALERTS=true ALERT_EMAIL=$ALERT_EMAIL
```

Phase 2 (Cognito on + blue/green):

```bash
make cf-deploy ENV=$ENV_NAME MODE=$MODE \
  LOAD_BALANCER_TYPE=alb DEPLOYMENT_STRATEGY=bluegreen \
  SECRET_BACKEND=secretsmanager ENABLE_SECRET_ROTATION=true ROTATION_DAYS=7 \
  NETWORK_PROFILE=strict-private ENABLE_VPC_ENDPOINTS=true ENABLE_NAT_GATEWAY=true TASK_SUBNET_TYPE=private \
  ENABLE_WAF=true ENABLE_CLOUDFRONT=true ENABLE_CLOUDFRONT_FRONTDOOR=true \
  ENABLE_TLS_DOMAIN=true ENABLE_COGNITO=true \
  DOMAIN_NAME=$DOMAIN_NAME SUBDOMAIN=$SUBDOMAIN HOSTED_ZONE_ID=$HOSTED_ZONE_ID \
  CLOUDFRONT_CERT_ARN=$CLOUDFRONT_CERT_ARN \
  COGNITO_CALLBACK_URL="https://${SUBDOMAIN}.${DOMAIN_NAME}/oauth2/idpresponse" \
  COGNITO_LOGOUT_URL="https://${SUBDOMAIN}.${DOMAIN_NAME}/" API_SUBDOMAIN_LABEL=api \
  CACHE_BACKEND=elasticache ENABLE_ELASTICACHE=true \
  ENABLE_SQS=true ENABLE_RDS=true ENABLE_EFS=true ENABLE_KINESIS=false \
  ENABLE_ALERTS=true ALERT_EMAIL=$ALERT_EMAIL
```

## 6) Stack and endpoint discovery

```bash
# Review stack statuses for current env
aws cloudformation describe-stacks \
  --query "Stacks[?starts_with(StackName,'mood-${ENV_NAME}-')].[StackName,StackStatus]" \
  --output table

# Resolve exported endpoints
export ALB_DNS=$(aws cloudformation list-exports \
  --query "Exports[?Name=='Mood-${ENV_NAME}-LoadBalancerDnsName'].Value | [0]" --output text)

export CF_DOMAIN=$(aws cloudformation list-exports \
  --query "Exports[?Name=='Mood-${ENV_NAME}-CloudFrontDomainName'].Value | [0]" --output text)

export APP_DOMAIN=${SUBDOMAIN}.${DOMAIN_NAME}
export API_FQDN=api.${SUBDOMAIN}.${DOMAIN_NAME}

echo "ALB_DNS=$ALB_DNS"
echo "CF_DOMAIN=$CF_DOMAIN"
echo "APP_DOMAIN=$APP_DOMAIN"
echo "API_FQDN=$API_FQDN"
```

Sync static assets to S3/CloudFront path:

```bash
make upload-static ENV=$ENV_NAME
```

Basic access checks:

```bash
curl -i "http://${ALB_DNS}/health"
curl -I "https://${APP_DOMAIN}/"
curl -I "https://${APP_DOMAIN}/api/mood"
curl -I "https://${CF_DOMAIN}/"
curl -I "https://${CF_DOMAIN}/api/mood"
```

## 7) Cognito checks

Validate callback/logout settings from deployed Cognito client:

```bash
POOL_ID=$(aws cloudformation list-exports --query "Exports[?Name=='Mood-${ENV_NAME}-CognitoUserPoolId'].Value | [0]" --output text)
CLIENT_ID=$(aws cloudformation list-exports --query "Exports[?Name=='Mood-${ENV_NAME}-CognitoAppClientId'].Value | [0]" --output text)

aws cognito-idp describe-user-pool-client \
  --user-pool-id "$POOL_ID" \
  --client-id "$CLIENT_ID" \
  --query "UserPoolClient.[CallbackURLs,LogoutURLs]" \
  --output json
```

List user records:

```bash
aws cognito-idp list-users --user-pool-id "$POOL_ID" \
  --query "Users[].[Username,UserStatus]" --output table
```

Authenticated API test using ALB auth session cookies:

```bash
# After browser login, copy AWSELBAuthSessionCookie-* values
export AUTH_COOKIE='AWSELBAuthSessionCookie-0=<value0>; AWSELBAuthSessionCookie-1=<value1>'

curl -i -H "Cookie: $AUTH_COOKIE" "https://${APP_DOMAIN}/api/mood"
```

## 8) Blue/green release workflow

Use this only when `DEPLOYMENT_STRATEGY=bluegreen` and CodeDeploy resources exist.

Optional capacity tuning for stable blue/green runs:

```bash
python3 - <<'PY'
import json
path = "cloudformation/params/dev.json"
data = json.load(open(path, "r", encoding="utf-8"))
data["InstanceType"] = "t3.small"
data["AsgMinSize"] = 2
data["AsgDesiredCapacity"] = 2
data["AsgMaxSize"] = 3
data["ServiceDesiredCount"] = 1
data["ServiceMinCount"] = 1
data["ServiceMaxCount"] = 2
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
print("updated", path)
PY
```

Push a new image tag and trigger blue/green deployment:

```bash
export IMAGE_TAG=bg-$(date +%Y%m%d%H%M%S)
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID AWS_REGION=$AWS_REGION ENV_NAME=$ENV_NAME IMAGE_TAG=$IMAGE_TAG make image-push

make bluegreen-release ENV=$ENV_NAME IMAGE_TAG=$IMAGE_TAG WAIT_FOR_SUCCESS=true
make test-bluegreen ENV=$ENV_NAME
```

Rollback to a previous image tag if required:

```bash
make bluegreen-release ENV=$ENV_NAME IMAGE_TAG=<previous-good-tag> WAIT_FOR_SUCCESS=true
```

## 9) Functional test suite

Run in this sequence:

```bash
make smoke ALB_DNS=$ALB_DNS
make test-cloudfront ENV=$ENV_NAME
make test-tls-domain ENV=$ENV_NAME
make test-vpc-endpoints ENV=$ENV_NAME
make test-waf ENV=$ENV_NAME ALB_DNS=$ALB_DNS REQUESTS=400 CONCURRENCY=40
make test-elasticache ENV=$ENV_NAME
make test-sqs ENV=$ENV_NAME ALB_DNS=$ALB_DNS
make test-rds ENV=$ENV_NAME
make test-efs ENV=$ENV_NAME ALB_DNS=$ALB_DNS
make test-kinesis ENV=$ENV_NAME ALB_DNS=$ALB_DNS
make test-secret-rotation ENV=$ENV_NAME ALB_DNS=$ALB_DNS
```

For auth-protected endpoints, pass browser auth cookie:

```bash
AUTH_COOKIE="$AUTH_COOKIE" make test-sqs ENV=$ENV_NAME ALB_DNS=$ALB_DNS
AUTH_COOKIE="$AUTH_COOKIE" make test-secret-rotation ENV=$ENV_NAME ALB_DNS=$ALB_DNS
```

## 10) Chaos tests

Individual scenarios:

```bash
BASE_URL="https://${APP_DOMAIN}" make chaos-kill-task ENV=$ENV_NAME
BASE_URL="https://${APP_DOMAIN}" make chaos-terminate-instance ENV=$ENV_NAME
BASE_URL="https://${APP_DOMAIN}" make chaos-cache-outage ENV=$ENV_NAME ALB_DNS=$ALB_DNS
```

Combined chaos suite:

```bash
BASE_URL="https://${APP_DOMAIN}" make chaos-suite ENV=$ENV_NAME ALB_DNS=$ALB_DNS
```

## 11) DR drills

```bash
export DR_REGION=us-west-2

make dr-copy-rds ENV=$ENV_NAME DR_REGION=$DR_REGION
make dr-pilot-light ENV=$ENV_NAME DR_REGION=$DR_REGION MODE=$MODE
make dr-drill ENV=$ENV_NAME DR_REGION=$DR_REGION MODE=$MODE
```

Optional Route53 failover:

```bash
make dr-failover ENV=$ENV_NAME DR_REGION=$DR_REGION \
  HOSTED_ZONE_ID=$HOSTED_ZONE_ID DOMAIN_NAME=$DOMAIN_NAME SUBDOMAIN=$SUBDOMAIN
```

## 12) Cleanup and destroy

If CloudFront stack exists, empty static bucket first:

```bash
BUCKET=$(aws cloudformation describe-stack-resource \
  --stack-name mood-${ENV_NAME}-cloudfront \
  --logical-resource-id StaticBucket \
  --query 'StackResourceDetail.PhysicalResourceId' \
  --output text)

if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  aws s3 rm "s3://${BUCKET}" --recursive
fi
```

Optional ECR cleanup:

```bash
REPO=$(aws ecr describe-repositories \
  --query "repositories[?repositoryName=='mood-app-${ENV_NAME}'].repositoryName | [0]" \
  --output text)

if [ -n "$REPO" ] && [ "$REPO" != "None" ]; then
  DIGESTS=$(aws ecr list-images --repository-name "$REPO" --query 'imageIds[*]' --output json)
  aws ecr batch-delete-image --repository-name "$REPO" --image-ids "$DIGESTS" || true
fi
```

Destroy stacks:

```bash
make cf-destroy ENV=$ENV_NAME
```

Confirm no stacks remain:

```bash
aws cloudformation describe-stacks \
  --query "Stacks[?starts_with(StackName,'mood-${ENV_NAME}-')].[StackName,StackStatus]" \
  --output table
```

## 13) Troubleshooting command pack

Show failed resources from compute stack:

```bash
aws cloudformation describe-stack-events \
  --stack-name mood-${ENV_NAME}-compute \
  --query "StackEvents[?contains(ResourceStatus,'FAILED')].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]" \
  --output table
```

Show recent ECS service events:

```bash
aws ecs describe-services \
  --cluster mood-${ENV_NAME} \
  --services mood-app-${ENV_NAME} \
  --query "services[0].events[0:20].[createdAt,message]" \
  --output table
```

Show stack outputs for quick debugging:

```bash
make cf-outputs ENV=$ENV_NAME
```

Manual compute delete retry (if destroy gets blocked):

```bash
s=mood-${ENV_NAME}-compute
aws cloudformation delete-stack --stack-name "$s"
aws cloudformation wait stack-delete-complete --stack-name "$s"
```
