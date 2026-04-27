#!/bin/bash
# ============================================================
# Prepare Parameter Group for MySQL 8.4 Upgrade
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#
# Logic:
#   - If instance uses default parameter group → skip (RDS auto-assigns default.mysql8.4)
#   - If instance uses custom parameter group → run migrate_param_group.sh
#
# Usage:
#   ./prepare_param_group.sh --instance-id <id> [--target-group <name>]
#                            [--target-family <family>] [--region <region>]
#                            [--dry-run] [--json]
# ============================================================

set -euo pipefail

INSTANCE_ID=""
TARGET_GROUP=""
TARGET_FAMILY="mysql8.4"
REGION=""
DRY_RUN=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --target-group) TARGET_GROUP="$2"; shift 2 ;;
    --target-family) TARGET_FAMILY="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Usage: $0 --instance-id <id> [--target-group <name>] [--target-family <family>] [--region <region>] [--dry-run] [--json]"
  exit 1
fi

REGION_ARGS=()
if [[ -n "$REGION" ]]; then
  REGION_ARGS=(--region "$REGION")
fi

# --- Get current parameter group ---
PG_INFO=$(aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$INSTANCE_ID" \
  --query 'DBInstances[0].DBParameterGroups[0]' \
  --output json 2>&1)

if [[ $? -ne 0 ]]; then
  echo "ERROR: Failed to describe instance '$INSTANCE_ID'. Verify instance ID and permissions." >&2
  exit 1
fi

CURRENT_PG=$(echo "$PG_INFO" | jq -r '.DBParameterGroupName')

# --- Check if default parameter group ---
IS_DEFAULT=false
if [[ "$CURRENT_PG" == default.* ]]; then
  IS_DEFAULT=true
fi

if [[ "$IS_DEFAULT" == "true" ]]; then
  # Default parameter group — no migration needed
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    cat <<ENDJSON
{
  "instance_id": "$INSTANCE_ID",
  "current_param_group": "$CURRENT_PG",
  "action": "skip",
  "reason": "Instance uses default parameter group. RDS will auto-assign default.mysql8.4 during upgrade.",
  "target_param_group": null
}
ENDJSON
  else
    echo "============================================================"
    echo "Parameter Group: $CURRENT_PG (DEFAULT)"
    echo "Action: SKIP — RDS auto-assigns default.$TARGET_FAMILY during upgrade."
    echo "============================================================"
  fi
  exit 0
fi

# --- Custom parameter group — need migration ---
if [[ -z "$TARGET_GROUP" ]]; then
  TARGET_GROUP="${CURRENT_PG}-mysql84"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE_SCRIPT="$SCRIPT_DIR/migrate_param_group.sh"

if [[ ! -f "$MIGRATE_SCRIPT" ]]; then
  echo "ERROR: migrate_param_group.sh not found at $SCRIPT_DIR"
  echo "Please place migrate_param_group.sh from awslabs/rds-support-tools into $SCRIPT_DIR"
  echo "See scripts/params/README.md for setup instructions."
  exit 1
fi

MIGRATE_ARGS=(-s "$CURRENT_PG" -t "$TARGET_GROUP" -f "$TARGET_FAMILY")
if [[ -n "$REGION" ]]; then
  MIGRATE_ARGS+=(-S "$REGION" -T "$REGION")
fi
if [[ "$DRY_RUN" == "true" ]]; then
  MIGRATE_ARGS+=(-n)
fi

if [[ "$JSON_OUTPUT" == "true" ]]; then
  # Run migration, capture output
  MIGRATE_OUTPUT=$("$MIGRATE_SCRIPT" "${MIGRATE_ARGS[@]}" 2>&1) || true
  cat <<ENDJSON
{
  "instance_id": "$INSTANCE_ID",
  "current_param_group": "$CURRENT_PG",
  "action": "migrate",
  "target_param_group": "$TARGET_GROUP",
  "target_family": "$TARGET_FAMILY",
  "dry_run": $DRY_RUN
}
ENDJSON
else
  echo "============================================================"
  echo "Parameter Group: $CURRENT_PG (CUSTOM)"
  echo "Action: Migrate to $TARGET_GROUP ($TARGET_FAMILY)"
  echo "============================================================"
  "$MIGRATE_SCRIPT" "${MIGRATE_ARGS[@]}"
fi
