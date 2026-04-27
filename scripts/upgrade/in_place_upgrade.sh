#!/bin/bash
# ============================================================
# In-Place RDS MySQL Version Upgrade
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Usage:
#   ./in_place_upgrade.sh --instance-id <id> --target-version <ver>
#                         [--target-param-group <group>] [--region <region>]
#                         [--apply-immediately] [--poll-interval <sec>]
#                         [--timeout <sec>]
#
# WARNING: In-place upgrade causes downtime. Use Blue/Green for production.
# ============================================================

set -euo pipefail

INSTANCE_ID=""
TARGET_VERSION=""
TARGET_PARAM_GROUP=""
APPLY_IMMEDIATELY=false
POLL_INTERVAL=60
TIMEOUT=7200
REGION_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --target-version) TARGET_VERSION="$2"; shift 2 ;;
    --target-param-group) TARGET_PARAM_GROUP="$2"; shift 2 ;;
    --region) REGION_ARGS=(--region "$2"); shift 2 ;;
    --apply-immediately) APPLY_IMMEDIATELY=true; shift ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$INSTANCE_ID" || -z "$TARGET_VERSION" ]]; then
  echo "Usage: $0 --instance-id <id> --target-version <ver> [--target-param-group <group>] [--apply-immediately] [--region <region>]"
  exit 1
fi

# --- Input validation ---
if [[ ! "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$POLL_INTERVAL" -lt 1 ]]; then
  echo "ERROR: --poll-interval must be a positive integer" >&2; exit 1
fi
if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT" -lt 1 ]]; then
  echo "ERROR: --timeout must be a positive integer" >&2; exit 1
fi
if [[ ! "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "ERROR: Invalid --target-version format (expected X.Y or X.Y.Z)" >&2; exit 1
fi

# --- Check for read replicas and upgrade them first ---
INST_JSON=$(aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$INSTANCE_ID" \
  --output json 2>&1)

if [[ $? -ne 0 ]]; then
  echo "ERROR: Instance '$INSTANCE_ID' not found. Verify instance ID and region." >&2
  exit 1
fi

REPLICAS=$(echo "$INST_JSON" | jq -r '.DBInstances[0].ReadReplicaDBInstanceIdentifiers[]?' 2>/dev/null)

if [[ -n "$REPLICAS" ]]; then
  echo "Instance $INSTANCE_ID has read replicas. Upgrading replicas first..." >&2
  for REPLICA in $REPLICAS; do
    REPLICA_VERSION=$(aws rds describe-db-instances \
      ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
      --db-instance-identifier "$REPLICA" \
      --query 'DBInstances[0].EngineVersion' --output text 2>/dev/null || echo "unknown")

    if [[ "$REPLICA_VERSION" == "$TARGET_VERSION"* ]]; then
      echo "  Replica $REPLICA already at $REPLICA_VERSION, skipping." >&2
      continue
    fi

    echo "  Upgrading replica $REPLICA ($REPLICA_VERSION → $TARGET_VERSION)..." >&2

    REPLICA_MODIFY_ARGS=(
      --db-instance-identifier "$REPLICA"
      --engine-version "$TARGET_VERSION"
      --allow-major-version-upgrade
      ${REGION_ARGS[@]+"${REGION_ARGS[@]}"}
    )
    [[ -n "$TARGET_PARAM_GROUP" ]] && REPLICA_MODIFY_ARGS+=(--db-parameter-group-name "$TARGET_PARAM_GROUP")
    [[ "$APPLY_IMMEDIATELY" == "true" ]] && REPLICA_MODIFY_ARGS+=(--apply-immediately)

    aws rds modify-db-instance "${REPLICA_MODIFY_ARGS[@]}" --output json > /dev/null 2>&1 || {
      echo "  ERROR: Failed to upgrade replica $REPLICA" >&2
      exit 1
    }

    if [[ "$APPLY_IMMEDIATELY" == "true" ]]; then
      echo "  Waiting for replica $REPLICA upgrade..." >&2
      local_start=$(date +%s)
      while true; do
        REP_STATUS=$(aws rds describe-db-instances \
          ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
          --db-instance-identifier "$REPLICA" \
          --query 'DBInstances[0].[DBInstanceStatus,EngineVersion]' \
          --output text 2>&1)
        REP_INST_STATUS=$(echo "$REP_STATUS" | awk '{print $1}')
        REP_VERSION=$(echo "$REP_STATUS" | awk '{print $2}')
        local_elapsed=$(( $(date +%s) - local_start ))

        echo "  [$REPLICA] Status: $REP_INST_STATUS, Version: $REP_VERSION (${local_elapsed}s)" >&2

        if [[ "$REP_INST_STATUS" == "available" && "$REP_VERSION" == "$TARGET_VERSION"* ]]; then
          echo "  Replica $REPLICA upgraded successfully." >&2
          break
        fi
        if [[ "$local_elapsed" -ge "$TIMEOUT" ]]; then
          echo "  ERROR: Replica $REPLICA upgrade timeout after ${TIMEOUT}s" >&2
          exit 1
        fi
        sleep "$POLL_INTERVAL"
      done
    fi
  done
  echo "All replicas upgraded. Proceeding with primary $INSTANCE_ID..." >&2
fi

# --- Create manual snapshot before upgrade (rollback safety net) ---
SNAPSHOT_ID="${INSTANCE_ID}-pre-upgrade-$(date +%Y%m%d%H%M%S)"
echo "Creating pre-upgrade snapshot: $SNAPSHOT_ID ..." >&2

aws rds create-db-snapshot \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$INSTANCE_ID" \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --output json > /dev/null 2>&1 || {
  echo "ERROR: Failed to create pre-upgrade snapshot" >&2
  exit 1
}

echo "Waiting for snapshot $SNAPSHOT_ID to complete..." >&2
aws rds wait db-snapshot-available \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-snapshot-identifier "$SNAPSHOT_ID" 2>&1 || {
  echo "ERROR: Snapshot $SNAPSHOT_ID did not become available" >&2
  exit 1
}
echo "Snapshot $SNAPSHOT_ID ready. Proceeding with upgrade..." >&2

MODIFY_ARGS=(
  --db-instance-identifier "$INSTANCE_ID"
  --engine-version "$TARGET_VERSION"
  --allow-major-version-upgrade
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"}
)

if [[ -n "$TARGET_PARAM_GROUP" ]]; then
  MODIFY_ARGS+=(--db-parameter-group-name "$TARGET_PARAM_GROUP")
fi

if [[ "$APPLY_IMMEDIATELY" == "true" ]]; then
  MODIFY_ARGS+=(--apply-immediately)
else
  echo "WARNING: Upgrade will apply during next maintenance window. Use --apply-immediately to upgrade now." >&2
fi

echo "Initiating in-place upgrade for $INSTANCE_ID to $TARGET_VERSION..." >&2

RESULT=$(aws rds modify-db-instance "${MODIFY_ARGS[@]}" --output json 2>&1)

if [[ $? -ne 0 ]]; then
  echo "ERROR: Upgrade failed. Check instance status and IAM permissions." >&2
  exit 1
fi

if [[ "$APPLY_IMMEDIATELY" != "true" ]]; then
  echo "$RESULT" | jq '{
    instance_id: .DBInstance.DBInstanceIdentifier,
    status: "PENDING_MAINTENANCE_WINDOW",
    target_version: "'"$TARGET_VERSION"'"
  }'
  exit 0
fi

# Poll until upgrade completes
echo "Waiting for upgrade to complete..." >&2
START_TIME=$(date +%s)

while true; do
  STATUS=$(aws rds describe-db-instances \
    ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
    --db-instance-identifier "$INSTANCE_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,EngineVersion]' \
    --output text 2>&1)

  INST_STATUS=$(echo "$STATUS" | awk '{print $1}')
  INST_VERSION=$(echo "$STATUS" | awk '{print $2}')
  ELAPSED=$(( $(date +%s) - START_TIME ))

  echo "[$(date +%H:%M:%S)] Status: $INST_STATUS, Version: $INST_VERSION (elapsed: ${ELAPSED}s)" >&2

  if [[ "$INST_STATUS" == "available" && "$INST_VERSION" == "$TARGET_VERSION"* ]]; then
    echo '{"instance_id":"'"$INSTANCE_ID"'","status":"COMPLETED","engine_version":"'"$INST_VERSION"'","elapsed_seconds":'"$ELAPSED"',"pre_upgrade_snapshot":"'"$SNAPSHOT_ID"'"}'
    exit 0
  fi

  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timeout after ${TIMEOUT}s. Status: $INST_STATUS, Version: $INST_VERSION" >&2
    exit 1
  fi

  sleep "$POLL_INTERVAL"
done
