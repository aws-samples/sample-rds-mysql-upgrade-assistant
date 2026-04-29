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
  audit_init "cleanup_blue_green" "$@"
  audit_log "ACTION" "Cleanup deployment: $DEPLOYMENT_ID, delete_source: $DELETE_SOURCE"
fi

DELETE_ARGS=()
if [[ "$DELETE_SOURCE" == "true" ]]; then
  DELETE_ARGS=(--delete-target)
fi

RESULT=$(aws rds delete-blue-green-deployment \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
  ${DELETE_ARGS[@]+"${DELETE_ARGS[@]}"} \
  --output json 2>&1)

if [[ $? -ne 0 ]]; then
  echo "ERROR: Cleanup failed. Check deployment status and IAM permissions." >&2
  exit 1
fi

echo "$RESULT" | jq '{
  deployment_id: .BlueGreenDeployment.BlueGreenDeploymentIdentifier,
  status: .BlueGreenDeployment.Status,
  delete_source: '"$DELETE_SOURCE"'
}'
