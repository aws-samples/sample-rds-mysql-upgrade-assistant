#!/bin/bash
# ============================================================
# Pre-Switchover Readiness Check for Blue/Green Deployment
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Checks switchover guardrails before executing switchover:
#   - Deployment status is AVAILABLE
#   - Green environment instance is available
#   - Blue environment instance is available
#   - No replication issues reported
#   - Blue is not an external binlog replica
#   - Engine version upgrade confirmed
#
# Ref: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-switching.html
#
# Usage:
#   ./pre_switchover_check.sh --deployment-id <id> [--region <region>] [--json]
# ============================================================

set -euo pipefail

DEPLOYMENT_ID=""
REGION_ARGS=()
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
    --region) REGION_ARGS=(--region "$2"); shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$DEPLOYMENT_ID" ]]; then
  echo "Usage: $0 --deployment-id <id> [--region <region>] [--json]"
  exit 1
fi

CHECKS='[]'
OVERALL="PASS"

add_check() {
  local name="$1" status="$2" detail="$3"
  CHECKS=$(echo "$CHECKS" | jq --arg n "$name" --arg s "$status" --arg d "$detail" \
    '. + [{"name": $n, "status": $s, "detail": $d}]')
  if [[ "$status" == "FAIL" ]]; then OVERALL="FAIL"; fi
}

# --- Get deployment details ---
BG_JSON=$(aws rds describe-blue-green-deployments \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
  --output json 2>&1)

if [[ $? -ne 0 ]]; then
  echo "ERROR: Cannot describe deployment. Verify deployment ID." >&2
  exit 1
fi

BG_STATUS=$(echo "$BG_JSON" | jq -r '.BlueGreenDeployments[0].Status')

# --- Check 1: Deployment status must be AVAILABLE ---
if [[ "$BG_STATUS" == "AVAILABLE" ]]; then
  add_check "deployment_status" "PASS" "$BG_STATUS"
else
  add_check "deployment_status" "FAIL" "Expected AVAILABLE, got $BG_STATUS. Cannot switchover."
fi

# --- Get blue and green instance identifiers ---
BLUE_SOURCE=$(echo "$BG_JSON" | jq -r '.BlueGreenDeployments[0].Source')
GREEN_TARGET=$(echo "$BG_JSON" | jq -r '.BlueGreenDeployments[0].Target')

BLUE_ID=$(echo "$BLUE_SOURCE" | grep -oE '[^:]+$')
GREEN_ID=$(echo "$GREEN_TARGET" | grep -oE '[^:]+$')

# --- Check 2: Green instance status ---
GREEN_STATUS=$(aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$GREEN_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "unknown")

if [[ "$GREEN_STATUS" == "available" ]]; then
  add_check "green_instance_status" "PASS" "$GREEN_ID is available"
else
  add_check "green_instance_status" "FAIL" "$GREEN_ID status: $GREEN_STATUS"
fi

# --- Check 3: Blue instance status ---
BLUE_STATUS=$(aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$BLUE_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "unknown")

if [[ "$BLUE_STATUS" == "available" ]]; then
  add_check "blue_instance_status" "PASS" "$BLUE_ID is available"
else
  add_check "blue_instance_status" "FAIL" "$BLUE_ID status: $BLUE_STATUS"
fi

# --- Check 4: Replication health ---
STATUS_DETAILS=$(echo "$BG_JSON" | jq -r '.BlueGreenDeployments[0].StatusDetails // empty')
if [[ -n "$STATUS_DETAILS" && "$STATUS_DETAILS" != "null" ]]; then
  if echo "$STATUS_DETAILS" | grep -qi "replication\|lag\|degraded"; then
    add_check "replication_health" "FAIL" "$STATUS_DETAILS"
  else
    add_check "replication_health" "PASS" "No replication issues reported"
  fi
else
  add_check "replication_health" "PASS" "No replication issues reported"
fi

# --- Check 5: Blue is not external binlog replica ---
BLUE_REPLICA_SOURCE=$(aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$BLUE_ID" \
  --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' --output text 2>/dev/null || echo "None")

if [[ "$BLUE_REPLICA_SOURCE" == "None" || -z "$BLUE_REPLICA_SOURCE" ]]; then
  add_check "external_replication" "PASS" "Blue is not an external replica"
else
  add_check "external_replication" "WARNING" "Blue has source: $BLUE_REPLICA_SOURCE"
fi

# --- Check 6: Engine version upgrade confirmed ---
GREEN_VERSION=$(aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$GREEN_ID" \
  --query 'DBInstances[0].EngineVersion' --output text 2>/dev/null || echo "unknown")

BLUE_VERSION=$(aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$BLUE_ID" \
  --query 'DBInstances[0].EngineVersion' --output text 2>/dev/null || echo "unknown")

if [[ "$GREEN_VERSION" != "$BLUE_VERSION" ]]; then
  add_check "version_upgrade" "PASS" "Blue: $BLUE_VERSION -> Green: $GREEN_VERSION"
else
  add_check "version_upgrade" "WARNING" "Same version: $GREEN_VERSION (no upgrade?)"
fi

# --- Output ---
if [[ "$JSON_OUTPUT" == "true" ]]; then
  jq -n --arg id "$DEPLOYMENT_ID" --arg overall "$OVERALL" \
    --arg blue "$BLUE_ID" --arg green "$GREEN_ID" \
    --argjson checks "$CHECKS" \
    '{deployment_id: $id, overall: $overall, blue_instance: $blue, green_instance: $green, checks: $checks, timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}'
else
  echo "============================================================"
  echo "Pre-Switchover Readiness Check: $DEPLOYMENT_ID"
  echo "============================================================"
  echo "Blue:    $BLUE_ID ($BLUE_VERSION)"
  echo "Green:   $GREEN_ID ($GREEN_VERSION)"
  echo "Overall: $OVERALL"
  echo "------------------------------------------------------------"
  echo "$CHECKS" | jq -r '.[] | "  \(.name): \(.status) — \(.detail)"'
  echo "============================================================"
  if [[ "$OVERALL" == "FAIL" ]]; then
    echo "WARNING: One or more checks failed. Switchover may fail." >&2
    echo "Ref: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-switching.html" >&2
  fi
fi
