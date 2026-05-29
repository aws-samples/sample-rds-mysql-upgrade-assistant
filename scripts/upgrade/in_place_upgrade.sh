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
APPLY_IMMEDIATELY=false
POLL_INTERVAL=60
TIMEOUT=7200
REGION_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --target-version) TARGET_VERSION="$2"; shift 2 ;;
    --target-param-group) TARGET_PARAM_GROUP="$2"; shift 2 ;;
    --target-option-group) TARGET_OPTION_GROUP="$2"; shift 2 ;;
    --region) REGION_ARGS=(--region "$2"); shift 2 ;;
    --apply-immediately) APPLY_IMMEDIATELY=true; shift ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$INSTANCE_ID" || -z "$TARGET_VERSION" ]]; then
  echo "Usage: $0 --instance-id <id> --target-version <ver> [--target-param-group <group>] [--target-option-group <group>] [--apply-immediately] [--region <region>]"
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

# --- Audit init ---
if type audit_init &>/dev/null; then
  audit_init "in_place_upgrade" "$@"
  audit_log "INFO" "Instance: $INSTANCE_ID, Target: $TARGET_VERSION, ApplyImmediately: $APPLY_IMMEDIATELY"
fi

# --- Detect instance vs cluster ---
IS_CLUSTER=false

if aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$INSTANCE_ID" \
  --query 'DBInstances[0].DBInstanceIdentifier' \
  --output text > /dev/null 2>&1; then
  IS_CLUSTER=false
  INST_JSON=$(aws rds describe-db-instances \
    ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
    --db-instance-identifier "$INSTANCE_ID" \
    --output json)
elif aws rds describe-db-clusters \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-cluster-identifier "$INSTANCE_ID" \
  --query 'DBClusters[0].DBClusterIdentifier' \
  --output text > /dev/null 2>&1; then
  IS_CLUSTER=true
  echo "Detected Multi-AZ DB Cluster: $INSTANCE_ID" >&2
else
  echo "ERROR: '$INSTANCE_ID' not found as instance or cluster." >&2
  exit 1
fi

# ============================================================
# Cluster upgrade path
# ============================================================
if [[ "$IS_CLUSTER" == "true" ]]; then

  # --- RDS automatically creates a snapshot before major version upgrade ---
  # No manual snapshot needed. Proceed directly to upgrade.

  # --- Modify cluster ---
  MODIFY_ARGS=(
    --db-cluster-identifier "$INSTANCE_ID"
    --engine-version "$TARGET_VERSION"
    --allow-major-version-upgrade
    ${REGION_ARGS[@]+"${REGION_ARGS[@]}"}
  )

  if [[ -n "$TARGET_PARAM_GROUP" ]]; then
    MODIFY_ARGS+=(--db-cluster-parameter-group-name "$TARGET_PARAM_GROUP")
  fi

  if [[ "$APPLY_IMMEDIATELY" == "true" ]]; then
    MODIFY_ARGS+=(--apply-immediately)
  else
    echo "WARNING: Upgrade will apply during next maintenance window. Use --apply-immediately to upgrade now." >&2
  fi

  echo "Initiating in-place upgrade for cluster $INSTANCE_ID to $TARGET_VERSION..." >&2

  if ! RESULT=$(aws rds modify-db-cluster "${MODIFY_ARGS[@]}" --output json 2>&1); then
    echo "ERROR: Cluster upgrade failed. Check status and IAM permissions." >&2
    exit 1
  fi

  if [[ "$APPLY_IMMEDIATELY" != "true" ]]; then
    echo "$RESULT" | jq '{
      cluster_id: .DBCluster.DBClusterIdentifier,
      status: "PENDING_MAINTENANCE_WINDOW",
      target_version: "'"$TARGET_VERSION"'"
    }'
    exit 0
  fi

  # --- Poll cluster until upgrade completes ---
  echo "Waiting for cluster upgrade to complete..." >&2
  START_TIME=$(date +%s)

  while true; do
    STATUS=$(aws rds describe-db-clusters \
      ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
      --db-cluster-identifier "$INSTANCE_ID" \
      --query 'DBClusters[0].[Status,EngineVersion]' \
      --output text 2>&1)

    CLUSTER_STATUS=$(echo "$STATUS" | awk '{print $1}')
    CLUSTER_VERSION=$(echo "$STATUS" | awk '{print $2}')
    ELAPSED=$(( $(date +%s) - START_TIME ))

    echo "[$(date +%H:%M:%S)] Cluster status: $CLUSTER_STATUS, Version: $CLUSTER_VERSION (elapsed: ${ELAPSED}s)" >&2

    if [[ "$CLUSTER_STATUS" == "available" && "$CLUSTER_VERSION" == "$TARGET_VERSION"* ]]; then
      echo '{"cluster_id":"'"$INSTANCE_ID"'","status":"COMPLETED","engine_version":"'"$CLUSTER_VERSION"'","elapsed_seconds":'"$ELAPSED"'}'
      exit 0
    fi

    if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
      echo "ERROR: Timeout after ${TIMEOUT}s. Status: $CLUSTER_STATUS, Version: $CLUSTER_VERSION" >&2
      exit 1
    fi

    sleep "$POLL_INTERVAL"
  done
fi

# ============================================================
# Instance upgrade path (original logic)
# ============================================================

# --- Check for read replicas and upgrade them first ---

REPLICAS=$(echo "$INST_JSON" | jq -r '.DBInstances[0].ReadReplicaDBInstanceIdentifiers[]?' 2>/dev/null)

if [[ -n "$REPLICAS" ]]; then
  echo "Instance $INSTANCE_ID has read replicas. Upgrading replicas first..." >&2
  for REPLICA in $REPLICAS; do
    # Handle cross-region replicas (ARN format: arn:aws:rds:<region>:<account>:db:<id>)
    REPLICA_REGION_ARGS=(${REGION_ARGS[@]+"${REGION_ARGS[@]}"})
    REPLICA_ID="$REPLICA"
    if [[ "$REPLICA" == arn:* ]]; then
      REPLICA_REGION=$(echo "$REPLICA" | cut -d: -f4)
      REPLICA_ID=$(echo "$REPLICA" | cut -d: -f7)
      REPLICA_REGION_ARGS=(--region "$REPLICA_REGION")
      echo "  Cross-region replica detected: $REPLICA_ID in $REPLICA_REGION" >&2
    fi

    REPLICA_VERSION=$(aws rds describe-db-instances \
      "${REPLICA_REGION_ARGS[@]}" \
      --db-instance-identifier "$REPLICA_ID" \
      --query 'DBInstances[0].EngineVersion' --output text 2>/dev/null || echo "unknown")

    if [[ "$REPLICA_VERSION" == "$TARGET_VERSION"* ]]; then
      echo "  Replica $REPLICA_ID already at $REPLICA_VERSION, skipping." >&2
      continue
    fi

    echo "  Upgrading replica $REPLICA_ID ($REPLICA_VERSION → $TARGET_VERSION)..." >&2

    REPLICA_MODIFY_ARGS=(
      --db-instance-identifier "$REPLICA_ID"
      --engine-version "$TARGET_VERSION"
      --allow-major-version-upgrade
      "${REPLICA_REGION_ARGS[@]}"
    )
    [[ "$APPLY_IMMEDIATELY" == "true" ]] && REPLICA_MODIFY_ARGS+=(--apply-immediately)

    aws rds modify-db-instance "${REPLICA_MODIFY_ARGS[@]}" --output json > /dev/null 2>&1 || {
      echo "  ERROR: Failed to upgrade replica $REPLICA_ID" >&2
      exit 1
    }

    if [[ "$APPLY_IMMEDIATELY" == "true" ]]; then
      echo "  Waiting for replica $REPLICA_ID upgrade..." >&2
      local_start=$(date +%s)
      while true; do
        REP_STATUS=$(aws rds describe-db-instances \
          "${REPLICA_REGION_ARGS[@]}" \
          --db-instance-identifier "$REPLICA_ID" \
          --query 'DBInstances[0].[DBInstanceStatus,EngineVersion]' \
          --output text 2>&1)
        REP_INST_STATUS=$(echo "$REP_STATUS" | awk '{print $1}')
        REP_VERSION=$(echo "$REP_STATUS" | awk '{print $2}')
        local_elapsed=$(( $(date +%s) - local_start ))

        echo "  [$REPLICA_ID] Status: $REP_INST_STATUS, Version: $REP_VERSION (${local_elapsed}s)" >&2

        if [[ "$REP_INST_STATUS" == "available" && "$REP_VERSION" == "$TARGET_VERSION"* ]]; then
          echo "  Replica $REPLICA_ID upgraded successfully." >&2
          break
        fi
        if [[ "$local_elapsed" -ge "$TIMEOUT" ]]; then
          echo "  ERROR: Replica $REPLICA_ID upgrade timeout after ${TIMEOUT}s" >&2
          exit 1
        fi
        sleep "$POLL_INTERVAL"
      done
    fi
  done
  echo "All replicas upgraded. Proceeding with primary $INSTANCE_ID..." >&2
fi

# --- RDS automatically creates a snapshot before major version upgrade ---
# No manual snapshot needed. Proceed directly to upgrade.

MODIFY_ARGS=(
  --db-instance-identifier "$INSTANCE_ID"
  --engine-version "$TARGET_VERSION"
  --allow-major-version-upgrade
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"}
)

if [[ -n "$TARGET_PARAM_GROUP" ]]; then
  MODIFY_ARGS+=(--db-parameter-group-name "$TARGET_PARAM_GROUP")
else
  # Auto-detect: if instance uses a custom param group, RDS requires specifying a target
  CURRENT_PG=$(echo "$INST_JSON" | jq -r '.DBInstances[0].DBParameterGroups[0].DBParameterGroupName // empty')
  if [[ -n "$CURRENT_PG" && "$CURRENT_PG" != default.* ]]; then
    echo "WARNING: Instance uses custom parameter group '$CURRENT_PG' but no --target-param-group specified." >&2
    echo "  Using default.mysql8.4 as target. To use a custom 8.4 group, specify --target-param-group." >&2
    MODIFY_ARGS+=(--db-parameter-group-name "default.mysql8.4")
  fi
fi

if [[ -n "$TARGET_OPTION_GROUP" ]]; then
  MODIFY_ARGS+=(--option-group-name "$TARGET_OPTION_GROUP")
else
  # Auto-detect: if instance uses a custom option group, RDS requires specifying a target
  CURRENT_OG=$(echo "$INST_JSON" | jq -r '.DBInstances[0].OptionGroupMemberships[0].OptionGroupName // empty')
  if [[ -n "$CURRENT_OG" && "$CURRENT_OG" != default:* && "$CURRENT_OG" != "None" ]]; then
    # Check if a migrated 8.4 option group exists (convention: <name>-mysql84)
    og_84="${CURRENT_OG}-mysql84"
    if aws rds describe-option-groups ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
      --option-group-name "$og_84" > /dev/null 2>&1; then
      echo "Auto-detected migrated option group: $og_84" >&2
      MODIFY_ARGS+=(--option-group-name "$og_84")
    else
      echo "WARNING: Instance uses custom option group '$CURRENT_OG' but no migrated 8.4 group found." >&2
      echo "  Falling back to default:mysql-8.4. Run check_option_group.sh first to migrate." >&2
      MODIFY_ARGS+=(--option-group-name "default:mysql-8.4")
    fi
  fi
fi

if [[ "$APPLY_IMMEDIATELY" == "true" ]]; then
  MODIFY_ARGS+=(--apply-immediately)
else
  echo "WARNING: Upgrade will apply during next maintenance window. Use --apply-immediately to upgrade now." >&2
fi

echo "Initiating in-place upgrade for $INSTANCE_ID to $TARGET_VERSION..." >&2

if ! RESULT=$(aws rds modify-db-instance "${MODIFY_ARGS[@]}" --output json 2>&1); then
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
    echo '{"instance_id":"'"$INSTANCE_ID"'","status":"COMPLETED","engine_version":"'"$INST_VERSION"'","elapsed_seconds":'"$ELAPSED"'}'
    exit 0
  fi

  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timeout after ${TIMEOUT}s. Status: $INST_STATUS, Version: $INST_VERSION" >&2
    exit 1
  fi

  sleep "$POLL_INTERVAL"
done
