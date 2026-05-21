#!/bin/bash
# ============================================================
# Batch Precheck — Run prechecks on all MySQL 8.0 instances
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Usage:
#   ./batch_precheck.sh -u <user> [--secret-id <id>] [--iam]
#                       [--region <region>] [--version-prefix <prefix>]
#                       [--phase2] [--json]
#
# Credential priority: --secret-id > --iam > interactive password prompt
# Interactive password is prompted once and reused for all instances.
# ============================================================

set -uo pipefail
umask 077

USER=""
SECRET_ID=""
USE_IAM=false
REGION=""
VERSION_PREFIX="8.0"
RUN_PHASE2=false
JSON_OUTPUT=false
PASSWORD=""

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) USER="$2"; shift 2 ;;
    --secret-id) SECRET_ID="$2"; shift 2 ;;
    --iam) USE_IAM=true; shift ;;
    --region) REGION="$2"; shift 2 ;;
    --version-prefix) VERSION_PREFIX="$2"; shift 2 ;;
    --phase2) RUN_PHASE2=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$USER" ]]; then
  echo "Usage: $0 -u <user> [--secret-id <id>] [--iam] [--region <region>] [--version-prefix <prefix>] [--phase2] [--json]"
  exit 1
fi

# --- Credential resolution ---
if [[ -z "$SECRET_ID" && "$USE_IAM" == "false" ]]; then
  echo -n "Enter password (shared for all instances): "
  read -rs PASSWORD
  echo
fi

# --- Discover instances ---
DISCOVER_ARGS=(--version-prefix "$VERSION_PREFIX" --json)
[[ -n "$REGION" ]] && DISCOVER_ARGS+=(--region "$REGION")

INSTANCES=$("$SCRIPT_DIR/inventory/discover_instances.sh" "${DISCOVER_ARGS[@]}")
COUNT=$(echo "$INSTANCES" | jq 'length')

if [[ "$COUNT" -eq 0 ]]; then
  echo "No MySQL instances matching version prefix '$VERSION_PREFIX' found."
  exit 0
fi

echo "============================================================"
echo "Batch Precheck: $COUNT instances"
echo "============================================================"

# --- Run precheck on each instance ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
RESULTS='[]'
CHECKED_CLUSTERS=""

while IFS= read -r instance; do
  id=$(echo "$instance" | jq -r '.instance_id')
  endpoint=$(echo "$instance" | jq -r '.endpoint')
  version=$(echo "$instance" | jq -r '.engine_version')
  source=$(echo "$instance" | jq -r '.source_instance // empty')
  cluster_id=$(echo "$instance" | jq -r '.cluster_id // empty')

  # Skip read replicas (handled with primary)
  if [[ -n "$source" ]]; then
    echo "  [$id] Skipping (read replica of $source)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # Skip duplicate cluster members (only precheck one member per cluster)
  if [[ -n "$cluster_id" ]]; then
    if echo "$CHECKED_CLUSTERS" | grep -q "^${cluster_id}$" 2>/dev/null; then
      echo "  [$id] Skipping (cluster '$cluster_id' already checked)"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi
    CHECKED_CLUSTERS="${CHECKED_CLUSTERS}${cluster_id}
"
  fi

  # Skip instances without endpoint
  if [[ -z "$endpoint" || "$endpoint" == "null" ]]; then
    echo "  [$id] Skipping (no endpoint)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  echo -n "  [$id] ($version) $endpoint ... "

  # Build precheck args
  PRECHECK_ARGS=(-h "$endpoint" -u "$USER" --json)
  if [[ -n "$SECRET_ID" ]]; then
    PRECHECK_ARGS+=(--secret-id "$SECRET_ID")
  elif [[ "$USE_IAM" == "true" ]]; then
    PRECHECK_ARGS+=(--iam)
  elif [[ -n "$PASSWORD" ]]; then
    PRECHECK_ARGS+=(-p "$PASSWORD")
  fi
  [[ "$RUN_PHASE2" == "true" ]] && PRECHECK_ARGS+=(--phase2)

  # Run precheck — extract only the JSON block from output
  RAW_OUTPUT=$("$SCRIPT_DIR/precheck/mysql_precheck_run.sh" "${PRECHECK_ARGS[@]}" 2>/dev/null)
  PRECHECK_EXIT=$?

  if [[ "$PRECHECK_EXIT" -ne 0 && -z "$RAW_OUTPUT" ]]; then
    echo "FAIL (connection error — check credentials)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    RESULTS=$(echo "$RESULTS" | jq --arg id "$id" \
      '. + [{"instance_id": $id, "status": "FAIL", "errors": 999, "warnings": 0}]' 2>/dev/null || echo "$RESULTS")
    continue
  fi

  # The JSON block starts with { on its own line and ends with }
  RESULT=$(echo "$RAW_OUTPUT" | awk '/^\{/{found=1} found{print} /^\}/{if(found) exit}')
  if ! echo "$RESULT" | jq . > /dev/null 2>&1; then
    RESULT='{"summary":{"errors":0,"warnings":0,"notices":0}}'
  fi

  ERRORS=$(echo "$RESULT" | jq -r '.summary.errors // 0' 2>/dev/null || echo "0")
  WARNINGS=$(echo "$RESULT" | jq -r '.summary.warnings // 0' 2>/dev/null || echo "0")

  if [[ "$ERRORS" -eq 0 ]]; then
    echo "PASS (warnings: ${WARNINGS:-0})"
    PASS_COUNT=$((PASS_COUNT + 1))
    STATUS="PASS"
  else
    echo "FAIL ($ERRORS errors, $WARNINGS warnings)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    STATUS="FAIL"
  fi

  RESULTS=$(echo "$RESULTS" | jq --arg id "$id" --arg status "$STATUS" \
    --arg errors "${ERRORS:-0}" --arg warnings "${WARNINGS:-0}" \
    '. + [{"instance_id": $id, "status": $status, "errors": ($errors|tonumber), "warnings": ($warnings|tonumber)}]' 2>/dev/null || echo "$RESULTS")

done < <(echo "$INSTANCES" | jq -c '.[]')

# --- Summary ---
echo ""
echo "============================================================"
echo "Batch Precheck Summary"
echo "============================================================"
echo "Total:    $COUNT"
echo "Pass:     $PASS_COUNT"
echo "Fail:     $FAIL_COUNT"
echo "Skipped:  $SKIP_COUNT"
echo "============================================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo ""
  echo "Failed instances (must fix before upgrade):"
  echo "$RESULTS" | jq -r '.[] | select(.status == "FAIL") | "  \(.instance_id): \(.errors) error(s)"'
fi

if [[ "$JSON_OUTPUT" == "true" ]]; then
  echo ""
  jq -n --argjson results "$RESULTS" \
    --arg total "$COUNT" --arg pass "$PASS_COUNT" --arg fail "$FAIL_COUNT" --arg skip "$SKIP_COUNT" \
    '{summary: {total: ($total|tonumber), pass: ($pass|tonumber), fail: ($fail|tonumber), skipped: ($skip|tonumber)}, instances: $results}'
fi
