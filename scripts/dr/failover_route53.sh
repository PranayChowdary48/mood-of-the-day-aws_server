#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-dev}"
TARGET_REGION="${2:-}"
DOMAIN_NAME="${DOMAIN_NAME:-moodoftheday.fun}"
SUBDOMAIN="${SUBDOMAIN:-${ENV_NAME}}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"

if [[ -z "${TARGET_REGION}" ]]; then
  echo "Usage: bash scripts/dr/failover_route53.sh <env> <target-region>"
  exit 1
fi

if [[ -z "${HOSTED_ZONE_ID}" ]]; then
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "${DOMAIN_NAME}." \
    --query "HostedZones[?Name=='${DOMAIN_NAME}.']|[0].Id" \
    --output text | sed 's|/hostedzone/||')
fi

if [[ -z "${HOSTED_ZONE_ID}" || "${HOSTED_ZONE_ID}" == "None" ]]; then
  echo "Could not resolve hosted zone id for ${DOMAIN_NAME}"
  exit 1
fi

FQDN="${DOMAIN_NAME}"
if [[ -n "${SUBDOMAIN}" ]]; then
  FQDN="${SUBDOMAIN}.${DOMAIN_NAME}"
fi

LB_DNS=$(AWS_REGION="${TARGET_REGION}" aws cloudformation list-exports \
  --query "Exports[?Name=='Mood-${ENV_NAME}-LoadBalancerDnsName'].Value | [0]" \
  --output text)
LB_ZONE_ID=$(AWS_REGION="${TARGET_REGION}" aws cloudformation list-exports \
  --query "Exports[?Name=='Mood-${ENV_NAME}-AlbCanonicalHostedZoneId'].Value | [0]" \
  --output text)

if [[ -z "${LB_DNS}" || "${LB_DNS}" == "None" || -z "${LB_ZONE_ID}" || "${LB_ZONE_ID}" == "None" ]]; then
  echo "Could not resolve ALB DNS/zone exports in target region ${TARGET_REGION}"
  exit 1
fi

CHANGE_BATCH=$(cat <<JSON
{
  "Comment": "DR failover update to ${TARGET_REGION}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${FQDN}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${LB_ZONE_ID}",
          "DNSName": "${LB_DNS}",
          "EvaluateTargetHealth": true
        }
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${FQDN}",
        "Type": "AAAA",
        "AliasTarget": {
          "HostedZoneId": "${LB_ZONE_ID}",
          "DNSName": "${LB_DNS}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
JSON
)

aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "${CHANGE_BATCH}" >/tmp/mood_dr_failover.json

echo "Route53 updated for ${FQDN} -> ${LB_DNS} (${TARGET_REGION})"
cat /tmp/mood_dr_failover.json
