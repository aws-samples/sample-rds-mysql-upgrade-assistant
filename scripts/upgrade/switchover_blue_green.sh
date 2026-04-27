#!/bin/bash
# ============================================================
# Execute Blue/Green Switchover
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Usage:
#   ./switchover_blue_green.sh --deployment-id <id> [--region <region>]
#                              [--timeout <sec>]
# ============================================================

set -euo pipefail

DEPLOYMENT_ID=""
TIMEOUT=300
REGION_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
    --region) REGION_ARGS=(--region "$2"); shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$DEPLOYMENT_ID" ]]; then
  echo "Usage: $0 --deployment-id <id> [--region <region>] [--timeout <sec>]"
  exit 1
fi

echo "Initiating switchover for deployment: $DEPLOYMENT_ID" >&2

RESULT=$(aws rds switchover-blue-green-deployment \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
  --switchover-timeout "$TIMEOUT" \
  --output json 2>&1)

if [[ $? -ne 0 ]]; then
  echo "ERROR: Switchover failed. Check deployment status and IAM permissions." >&2
  exit 1
fi

echo "Switchover initiated. Waiting for completion..." >&2

# Poll until switchover completes
START_TIME=$(date +%s)
MAX_WAIT=600

while true; do
  STATUS_RESULT=$(aws rds describe-blue-green-deployments \
    ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
    --blue-green-deployment-identifier "$DEPLOYMENT_ID" \
    --output json 2>&1)

  STATUS=$(echo "$STATUS_RESULT" | jq -r '.BlueGreenDeployments[0].Status')
  ELAPSED=$(( $(date +%s) - START_TIME ))

  echo "[$(date +%H:%M:%S)] Switchover status: $STATUS (elapsed: ${ELAPSED}s)" >&2

  case "$STATUS" in
    SWITCHOVER_COMPLETED)
      echo "$STATUS_RESULT" | jq '{
        deployment_id: .BlueGreenDeployments[0].BlueGreenDeploymentIdentifier,
        status: "SWITCHOVER_COMPLETED",
        elapsed_seconds: '"$ELAPSED"'
      }'
      exit 0
      ;;
    INVALID|FAILED)
      echo "ERROR: Switchover failed. Status: $STATUS" >&2
      echo "$STATUS_RESULT" | jq '{
        deployment_id: .BlueGreenDeployments[0].BlueGreenDeploymentIdentifier,
        status: .BlueGreenDeployments[0].Status,
        status_details: .BlueGreenDeployments[0].StatusDetails
      }'
      exit 1
      ;;
  esac

  if [[ "$ELAPSED" -ge "$MAX_WAIT" ]]; then
    echo "ERROR: Switchover timeout after ${MAX_WAIT}s. Status: $STATUS" >&2
    exit 1
  fi

  sleep 15
done
