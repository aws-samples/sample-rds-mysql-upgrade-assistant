#!/bin/bash
# ============================================================
# Monitor Blue/Green Deployment Status
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Usage:
#   ./monitor_blue_green.sh --deployment-id <id> [--region <region>]
#                           [--poll-interval <sec>] [--timeout <sec>]
# ============================================================

set -euo pipefail

DEPLOYMENT_ID=""
POLL_INTERVAL=60
TIMEOUT=3600
REGION_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
    --region) REGION_ARGS=(--region "$2"); shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$DEPLOYMENT_ID" ]]; then
  echo "Usage: $0 --deployment-id <id> [--region <region>] [--poll-interval <sec>] [--timeout <sec>]"
  exit 1
fi

START_TIME=$(date +%s)

while true; do
  RESULT=$(aws rds describe-blue-green-deployments \
    "${REGION_ARGS[@]}" \
    --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
    --output json 2>&1)

  if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to describe deployment: $RESULT" >&2
    exit 1
  fi

  STATUS=$(echo "$RESULT" | jq -r '.BlueGreenDeployments[0].Status')
  ELAPSED=$(( $(date +%s) - START_TIME ))

  echo "[$(date +%H:%M:%S)] Status: $STATUS (elapsed: ${ELAPSED}s)" >&2

  case "$STATUS" in
    AVAILABLE|SWITCHOVER_COMPLETED)
      echo "$RESULT" | jq '{
        deployment_id: .BlueGreenDeployments[0].BlueGreenDeploymentIdentifier,
        status: .BlueGreenDeployments[0].Status,
        elapsed_seconds: '"$ELAPSED"'
      }'
      exit 0
      ;;
    INVALID|FAILED|DELETING|DELETED)
      echo "ERROR: Deployment reached terminal state: $STATUS" >&2
      echo "$RESULT" | jq '{
        deployment_id: .BlueGreenDeployments[0].BlueGreenDeploymentIdentifier,
        status: .BlueGreenDeployments[0].Status,
        status_details: .BlueGreenDeployments[0].StatusDetails,
        elapsed_seconds: '"$ELAPSED"'
      }'
      exit 1
      ;;
  esac

  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timeout after ${TIMEOUT}s. Current status: $STATUS" >&2
    exit 1
  fi

  sleep "$POLL_INTERVAL"
done
