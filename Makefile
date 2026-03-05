ENV ?= dev
MODE ?= free-tier
ALB_DNS ?=
REQUESTS ?= 300
CONCURRENCY ?= 20
IMAGE_TAG ?= latest
WAIT_FOR_SUCCESS ?= true

# Shared feature toggles for CloudFormation deploy/test flows
ENABLE_VPC_ENDPOINTS ?=
TASK_SUBNET_TYPE ?=
LOAD_BALANCER_TYPE ?=
SECRET_BACKEND ?=
CACHE_BACKEND ?=
DEPLOYMENT_STRATEGY ?=
ENABLE_WAF ?=
ENABLE_CLOUDFRONT ?=
ENABLE_CLOUDFRONT_FRONTDOOR ?=
ENABLE_ELASTICACHE ?=
REGION ?=

NETWORK_PROFILE ?=
ENABLE_NAT_GATEWAY ?=
ENABLE_SQS ?=
ENABLE_RDS ?=
ENABLE_ALERTS ?=
ALERT_EMAIL ?=
ENABLE_EFS ?=
ENABLE_KINESIS ?=
ENABLE_TLS_DOMAIN ?=
DOMAIN_NAME ?= moodoftheday.fun
SUBDOMAIN ?= $(ENV)
HOSTED_ZONE_ID ?=
ENABLE_SECRET_ROTATION ?=
ROTATION_DAYS ?= 7
ENABLE_COGNITO ?=
COGNITO_DOMAIN_PREFIX ?=
COGNITO_CALLBACK_URL ?=
COGNITO_LOGOUT_URL ?=
ASSET_BASE_URL ?=
CLOUDFRONT_CERT_ARN ?=
ALB_CERT_ARN ?=
API_SUBDOMAIN_LABEL ?= api

PRIMARY_REGION ?=
DR_REGION ?=

.PHONY: \
  help \
  cf-validate cf-deploy cf-destroy cf-outputs \
  image-push bluegreen-release upload-static smoke \
  test-bluegreen test-waf test-elasticache test-vpc-endpoints test-sqs test-rds test-cloudfront \
  test-efs test-kinesis test-tls-domain test-secret-rotation \
  chaos-kill-task chaos-terminate-instance chaos-cache-outage chaos-suite \
  dr-copy-rds dr-pilot-light dr-failover dr-drill

help:
	@echo "Mood AWS Make targets"
	@echo "  cf-*                  CloudFormation workflow"
	@echo "  image-push            Build and push app image to ECR"
	@echo "  bluegreen-release     Trigger ECS blue/green deployment via CodeDeploy"
	@echo "  upload-static         Sync static-site/ to S3 and invalidate CloudFront"
	@echo "  smoke                 Basic endpoint smoke test"
	@echo "  test-*                Feature validation scripts"
	@echo "  chaos-*               Chaos testing scripts"
	@echo "  dr-*                  Multi-region DR automation scripts"
	@echo ""
	@echo "Common vars: ENV=dev|prod MODE=free-tier|showcase ALB_DNS=<dns>"
	@echo "Infra vars: ENABLE_VPC_ENDPOINTS TASK_SUBNET_TYPE LOAD_BALANCER_TYPE"
	@echo "            SECRET_BACKEND CACHE_BACKEND DEPLOYMENT_STRATEGY"
	@echo "            ENABLE_WAF ENABLE_CLOUDFRONT ENABLE_CLOUDFRONT_FRONTDOOR ENABLE_ELASTICACHE"
	@echo "            NETWORK_PROFILE ENABLE_NAT_GATEWAY ENABLE_SQS ENABLE_RDS"
	@echo "            ENABLE_ALERTS ALERT_EMAIL ENABLE_EFS ENABLE_KINESIS"
	@echo "            ENABLE_TLS_DOMAIN DOMAIN_NAME SUBDOMAIN HOSTED_ZONE_ID"
	@echo "            ENABLE_SECRET_ROTATION ROTATION_DAYS ENABLE_COGNITO"
	@echo "            COGNITO_DOMAIN_PREFIX COGNITO_CALLBACK_URL COGNITO_LOGOUT_URL ASSET_BASE_URL CLOUDFRONT_CERT_ARN ALB_CERT_ARN API_SUBDOMAIN_LABEL REGION"

# CloudFormation workflow
cf-validate:
	bash cloudformation/scripts/validate.sh

cf-deploy:
	ENABLE_VPC_ENDPOINTS="$(ENABLE_VPC_ENDPOINTS)" \
	TASK_SUBNET_TYPE="$(TASK_SUBNET_TYPE)" \
	LOAD_BALANCER_TYPE="$(LOAD_BALANCER_TYPE)" \
	SECRET_BACKEND="$(SECRET_BACKEND)" \
	CACHE_BACKEND="$(CACHE_BACKEND)" \
	DEPLOYMENT_STRATEGY="$(DEPLOYMENT_STRATEGY)" \
	ENABLE_WAF="$(ENABLE_WAF)" \
	ENABLE_CLOUDFRONT="$(ENABLE_CLOUDFRONT)" \
	ENABLE_CLOUDFRONT_FRONTDOOR="$(ENABLE_CLOUDFRONT_FRONTDOOR)" \
	ENABLE_ELASTICACHE="$(ENABLE_ELASTICACHE)" \
	NETWORK_PROFILE="$(NETWORK_PROFILE)" \
	ENABLE_NAT_GATEWAY="$(ENABLE_NAT_GATEWAY)" \
	ENABLE_SQS="$(ENABLE_SQS)" \
	ENABLE_RDS="$(ENABLE_RDS)" \
	ENABLE_ALERTS="$(ENABLE_ALERTS)" \
	ALERT_EMAIL="$(ALERT_EMAIL)" \
	ENABLE_EFS="$(ENABLE_EFS)" \
	ENABLE_KINESIS="$(ENABLE_KINESIS)" \
	ENABLE_TLS_DOMAIN="$(ENABLE_TLS_DOMAIN)" \
	DOMAIN_NAME="$(DOMAIN_NAME)" \
	SUBDOMAIN="$(SUBDOMAIN)" \
	HOSTED_ZONE_ID="$(HOSTED_ZONE_ID)" \
	ENABLE_SECRET_ROTATION="$(ENABLE_SECRET_ROTATION)" \
	ROTATION_DAYS="$(ROTATION_DAYS)" \
	ENABLE_COGNITO="$(ENABLE_COGNITO)" \
	COGNITO_DOMAIN_PREFIX="$(COGNITO_DOMAIN_PREFIX)" \
	COGNITO_CALLBACK_URL="$(COGNITO_CALLBACK_URL)" \
	COGNITO_LOGOUT_URL="$(COGNITO_LOGOUT_URL)" \
	ASSET_BASE_URL="$(ASSET_BASE_URL)" \
	CLOUDFRONT_CERT_ARN="$(CLOUDFRONT_CERT_ARN)" \
	ALB_CERT_ARN="$(ALB_CERT_ARN)" \
	API_SUBDOMAIN_LABEL="$(API_SUBDOMAIN_LABEL)" \
	bash cloudformation/scripts/deploy.sh $(ENV) $(MODE)

cf-destroy:
	bash cloudformation/scripts/destroy.sh $(ENV)

cf-outputs:
	bash cloudformation/scripts/outputs.sh $(ENV)

# Shared helpers
image-push:
	bash scripts/build_push_image.sh

bluegreen-release:
	WAIT_FOR_SUCCESS="$(WAIT_FOR_SUCCESS)" \
	bash scripts/deploy/bluegreen_codedeploy.sh $(ENV) "$(IMAGE_TAG)"

upload-static:
	bash scripts/upload_static_assets.sh $(ENV)

smoke:
	bash scripts/smoke_test.sh "$(ALB_DNS)"

# Feature tests
test-bluegreen:
	bash scripts/tests/bluegreen_status.sh $(ENV)

test-waf:
	REQUESTS="$(REQUESTS)" CONCURRENCY="$(CONCURRENCY)" \
	bash scripts/tests/waf_rate_limit.sh "$(ALB_DNS)" "$(ENV)"

test-elasticache:
	bash scripts/tests/elasticache_replication.sh $(ENV)

test-vpc-endpoints:
	bash scripts/tests/vpc_endpoints_status.sh $(ENV)

test-sqs:
	bash scripts/tests/sqs_async.sh "$(ALB_DNS)" "$(ENV)"

test-rds:
	bash scripts/tests/rds_status.sh $(ENV)

test-cloudfront:
	bash scripts/tests/cloudfront_static.sh $(ENV)

test-efs:
	bash scripts/tests/efs_shared.sh "$(ALB_DNS)"

test-kinesis:
	bash scripts/tests/kinesis_flow.sh "$(ALB_DNS)" "$(ENV)"

test-tls-domain:
	bash scripts/tests/tls_domain.sh "$(ENV)"

test-secret-rotation:
	bash scripts/tests/secret_rotation.sh "$(ALB_DNS)" "$(ENV)"

# Chaos tests
chaos-kill-task:
	bash scripts/chaos/kill_task.sh $(ENV)

chaos-terminate-instance:
	bash scripts/chaos/terminate_instance.sh $(ENV)

chaos-cache-outage:
	bash scripts/chaos/cache_outage.sh $(ENV) "$(ALB_DNS)"

chaos-suite:
	bash scripts/chaos/run_suite.sh $(ENV) "$(ALB_DNS)"

# DR automation
dr-copy-rds:
	bash scripts/dr/copy_rds_snapshot.sh $(ENV) "$(DR_REGION)"

dr-pilot-light:
	bash scripts/dr/deploy_pilot_light.sh $(ENV) "$(DR_REGION)" $(MODE)

dr-failover:
	HOSTED_ZONE_ID="$(HOSTED_ZONE_ID)" DOMAIN_NAME="$(DOMAIN_NAME)" SUBDOMAIN="$(SUBDOMAIN)" \
	bash scripts/dr/failover_route53.sh $(ENV) "$(DR_REGION)"

dr-drill:
	bash scripts/dr/run_dr_drill.sh $(ENV) "$(DR_REGION)" $(MODE)
