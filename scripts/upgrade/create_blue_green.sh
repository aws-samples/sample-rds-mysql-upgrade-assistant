#!/bin/bash
# ============================================================
# Create Blue/Green Deployment for RDS MySQL Upgrade
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Usage:
#   ./create_blue_green.sh --instance-id <id> --target-version <ver>
#                          --target-param-group <group> [--region <region>]
# ============================================================

set -euo pipefail

INSTANCE_ID=""
TARGET_VERSION=""
TARGET_PARAM_GROUP=""
REGION_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --target-version) TARGET_VERSION="$2"; shift 2 ;;
    --target-param-group) TARGET_PARAM_GROUP="$2"; shift 2 ;;
    --region) REGION_ARGS=(--region "$2"); shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$INSTANCE_ID" || -z "$TARGET_VERSION" || -z "$TARGET_PARAM_GROUP" ]]; then
  echo "Usage: $0 --instance-id <id> --target-version <ver> --target-param-group <group> [--region <region>]"
  exit 1
fi

# Get source ARN and check eligibility
INST_JSON=$(aws rds describe-db-instances \
  "${REGION_ARGS[@]}" \
  --db-instance-identifier "$INSTANCE_ID" \
  --output json 2>&1)

if [[ $? -ne 0 ]]; then
  echo "ERROR: Instance '$INSTANCE_ID' not found. Verify instance ID and region." >&2
  exit 1
fi

SOURCE_ARN=$(echo "$INST_JSON" | jq -r '.DBInstances[0].DBInstanceArn')

# Check for cross-Region read replicas (Blue/Green not supported)
CROSS_REGION_REPLICAS=$(echo "$INST_JSON" | jq -r '
  [.DBInstances[0].ReadReplicaDBInstanceIdentifiers[]?
   | select(contains(":"))] | length')

if [[ "$CROSS_REGION_REPLICAS" -gt 0 ]]; then
  echo "ERROR: Instance '$INSTANCE_ID' has cross-Region read replicas." >&2
  echo "Blue/Green deployments are not supported for instances with cross-Region replicas." >&2
  echo "Use in-place upgrade instead: ./in_place_upgrade.sh --instance-id $INSTANCE_ID --target-version $TARGET_VERSION" >&2
  exit 1
fi

DEPLOYMENT_NAME="bgd-${INSTANCE_ID}-$(date +%Y%m%d%H%M%S)"

RESULT=$(aws rds create-blue-green-deployment \
  "${REGION_ARGS[@]}" \
  --blue-green-deployment-name "$DEPLOYMENT_NAME" \
  --source "$SOURCE_ARN" \
  --target-engine-version "$TARGET_VERSION" \
  --target-db-parameter-group-name "$TARGET_PARAM_GROUP" \
  --output json 2>&1)

if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to create Blue/Green deployment. Check instance eligibility and IAM permissions." >&2
  exit 1
fi

echo "$RESULT" | jq '{
  deployment_id: .BlueGreenDeployment.BlueGreenDeploymentIdentifier,
  deployment_name: .BlueGreenDeployment.BlueGreenDeploymentName,
  status: .BlueGreenDeployment.Status,
  source_instance: "'"$INSTANCE_ID"'",
  target_version: "'"$TARGET_VERSION"'",
  target_param_group: "'"$TARGET_PARAM_GROUP"'",
  created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
}'
