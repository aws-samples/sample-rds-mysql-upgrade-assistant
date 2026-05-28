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
#                          [--target-param-group <group>] [--target-option-group <group>]
#                          [--region <region>]
# ============================================================

set -euo pipefail

# --- Load libraries ---
SCRIPT_DIR_LIB="$(cd "$(dirname "$0")/.." && pwd)/lib"
if [[ -f "$SCRIPT_DIR_LIB/audit_log.sh" ]]; then
  source "$SCRIPT_DIR_LIB/audit_log.sh"
fi
if [[ -f "$SCRIPT_DIR_LIB/integrity_check.sh" ]]; then
  source "$SCRIPT_DIR_LIB/integrity_check.sh"
  verify_dependencies "aws:2.0" "jq:1.5"
fi

INSTANCE_ID=""
TARGET_VERSION=""
TARGET_PARAM_GROUP=""
TARGET_OPTION_GROUP=""
REGION_ARGS=()

ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --target-version) TARGET_VERSION="$2"; shift 2 ;;
    --target-param-group) TARGET_PARAM_GROUP="$2"; shift 2 ;;
    --target-option-group) TARGET_OPTION_GROUP="$2"; shift 2 ;;
    --region) REGION_ARGS=(--region "$2"); shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Usage: $0 --instance-id <id> [--target-version <ver>] [--target-param-group <group>] [--target-option-group <group>] [--region <region>]"
  exit 1
fi

# --- Audit init ---
if type audit_init &>/dev/null; then
  audit_init "create_blue_green" "${ORIG_ARGS[@]}"
  audit_log "INFO" "Instance: $INSTANCE_ID, Target: $TARGET_VERSION, ParamGroup: $TARGET_PARAM_GROUP, OptionGroup: ${TARGET_OPTION_GROUP:-none}"
fi

# Get source ARN — try instance first, then cluster (Multi-AZ DB Cluster)
SOURCE_ARN=""
IS_CLUSTER=false

if aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$INSTANCE_ID" \
  --query 'DBInstances[0].DBInstanceIdentifier' \
  --output text > /dev/null 2>&1; then

  INST_JSON=$(aws rds describe-db-instances \
    ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
    --db-instance-identifier "$INSTANCE_ID" \
    --output json)
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

elif aws rds describe-db-clusters \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-cluster-identifier "$INSTANCE_ID" \
  --query 'DBClusters[0].DBClusterIdentifier' \
  --output text > /dev/null 2>&1; then

  SOURCE_ARN=$(aws rds describe-db-clusters \
    ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
    --db-cluster-identifier "$INSTANCE_ID" \
    --query 'DBClusters[0].DBClusterArn' --output text)
  IS_CLUSTER=true
  echo "Detected Multi-AZ DB Cluster: $INSTANCE_ID" >&2
  echo "WARNING: Blue/Green is not supported for Multi-AZ DB Clusters. Use in_place_upgrade.sh instead." >&2
  exit 1

else
  echo "ERROR: '$INSTANCE_ID' not found as instance or cluster." >&2
  exit 1
fi

DEPLOYMENT_NAME="bgd-${INSTANCE_ID}-$(date +%Y%m%d%H%M%S)"

# Detect if we need two-step upgrade:
# - Custom option group specified, OR
# - No target version specified (caller wants same-version B/G)
# RDS doesn't support custom option groups with major version upgrade in a single B/G creation
TWO_STEP=false
if [[ -n "$TARGET_OPTION_GROUP" || -z "$TARGET_VERSION" ]]; then
  TWO_STEP=true
  echo "Two-step B/G mode: create same-version deployment, then upgrade green separately." >&2
fi

BG_ARGS=(
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"}
  --blue-green-deployment-name "$DEPLOYMENT_NAME"
  --source "$SOURCE_ARN"
)

# Only include target engine version if NOT two-step (no custom option group)
if [[ "$TWO_STEP" == "false" ]]; then
  BG_ARGS+=(--target-engine-version "$TARGET_VERSION")
fi

if [[ "$IS_CLUSTER" == "true" ]]; then
  [[ -n "$TARGET_PARAM_GROUP" && "$TWO_STEP" == "false" ]] && BG_ARGS+=(--target-db-cluster-parameter-group-name "$TARGET_PARAM_GROUP")
else
  if [[ "$TWO_STEP" == "false" ]]; then
    # One-step: use the 8.4 target param group
    [[ -n "$TARGET_PARAM_GROUP" ]] && BG_ARGS+=(--target-db-parameter-group-name "$TARGET_PARAM_GROUP")
  else
    # Two-step: use the source (8.0) param group for same-version B/G
    # RDS requires target param group if source uses a custom one
    local source_pg
    source_pg=$(echo "$INST_JSON" | jq -r '.DBInstances[0].DBParameterGroups[0].DBParameterGroupName // empty')
    if [[ -n "$source_pg" && "$source_pg" != default.* ]]; then
      BG_ARGS+=(--target-db-parameter-group-name "$source_pg")
    fi
  fi
  if [[ -n "$TARGET_OPTION_GROUP" && "$TWO_STEP" == "false" ]]; then
    BG_ARGS+=(--target-db-instance-option-group-name "$TARGET_OPTION_GROUP")
  fi
fi

if ! RESULT=$(aws rds create-blue-green-deployment \
  "${BG_ARGS[@]}" \
  --output json 2>&1); then
  echo "ERROR: Failed to create Blue/Green deployment. Check instance eligibility and IAM permissions." >&2
  echo "$RESULT" >&2
  exit 1
fi

DEPLOYMENT_ID=$(echo "$RESULT" | jq -r '.BlueGreenDeployment.BlueGreenDeploymentIdentifier')

# Two-step: output includes upgrade_green_required flag
echo "$RESULT" | jq --arg two_step "$TWO_STEP" '{
  deployment_id: .BlueGreenDeployment.BlueGreenDeploymentIdentifier,
  deployment_name: .BlueGreenDeployment.BlueGreenDeploymentName,
  status: .BlueGreenDeployment.Status,
  source_instance: "'"$INSTANCE_ID"'",
  target_version: "'"$TARGET_VERSION"'",
  target_param_group: "'"$TARGET_PARAM_GROUP"'",
  target_option_group: "'"${TARGET_OPTION_GROUP:-none}"'",
  upgrade_green_required: ($two_step == "true"),
  created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
}'
