#!/bin/bash
# ============================================================
# Cleanup Blue/Green Deployment
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Usage:
#   ./cleanup_blue_green.sh --deployment-id <id> [--region <region>]
#                           [--delete-source]
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

DEPLOYMENT_ID=""
DELETE_SOURCE=false
REGION_ARGS=()

ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
    --region) REGION_ARGS=(--region "$2"); shift 2 ;;
    --delete-source) DELETE_SOURCE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$DEPLOYMENT_ID" ]]; then
  echo "Usage: $0 --deployment-id <id> [--region <region>] [--delete-source]"
  exit 1
fi

# --- Audit init ---
if type audit_init &>/dev/null; then
  audit_init "cleanup_blue_green" "${ORIG_ARGS[@]}"
  audit_log "ACTION" "Cleanup deployment: $DEPLOYMENT_ID, delete_source: $DELETE_SOURCE"
fi

DELETE_ARGS=()

if ! RESULT=$(aws rds delete-blue-green-deployment \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
  --no-delete-target \
  --output json 2>&1); then
  echo "ERROR: Cleanup failed: $RESULT" >&2
  echo "Check deployment status (must be SWITCHOVER_COMPLETED) and IAM permissions." >&2
  exit 1
fi

# Optionally delete the old blue instance (-old1 suffix) after deployment cleanup
if [[ "$DELETE_SOURCE" == "true" ]]; then
  # Find the old source instance from the deployment details
  OLD_SOURCE=$(echo "$RESULT" | jq -r '.BlueGreenDeployment.SwitchoverDetails[]? | select(.SourceMember != null) | .SourceMember' 2>/dev/null | head -1)
  OLD_INSTANCE_ID=$(echo "$OLD_SOURCE" | grep -o '[^:]*$')

  if [[ -n "$OLD_INSTANCE_ID" && "$OLD_INSTANCE_ID" != "None" ]]; then
    echo "Deleting old blue instance: $OLD_INSTANCE_ID ..." >&2
    aws rds delete-db-instance \
      ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
      --db-instance-identifier "$OLD_INSTANCE_ID" \
      --skip-final-snapshot \
      --output json > /dev/null 2>&1 || {
      echo "WARNING: Failed to delete old instance '$OLD_INSTANCE_ID'. May need manual cleanup." >&2
    }
  else
    echo "WARNING: Could not determine old blue instance. Manual cleanup may be needed." >&2
  fi
fi

echo "$RESULT" | jq '{
  deployment_id: .BlueGreenDeployment.BlueGreenDeploymentIdentifier,
  status: .BlueGreenDeployment.Status,
  delete_source: '"$DELETE_SOURCE"'
}'
