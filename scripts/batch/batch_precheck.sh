#!/bin/bash
# ============================================================
# Batch Precheck — Run precheck on all MySQL 8.0 instances
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Usage:
#   ./batch_precheck.sh -u <user> [--region <region>] [--version-prefix <prefix>]
#                       [--secret-id <id>] [--phase2] [--json]
#
# If --secret-id is not provided, prompts for password once (used for all instances).
# ============================================================

set -uo pipefail
umask 077

USER=""
REGION=""
VERSION_PREFIX="8.0"
SECRET_ID=""
PASSWORD=""
RUN_PHASE2=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) USER="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --version-prefix) VERSION_PREFIX="$2"; shift 2 ;;
    --secret-id) SECRET_ID="$2"; shift 2 ;;
    --phase2) RUN_PHASE2=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$USER" ]]; then
  echo "Usage: $0 -u <user> [--region <region>] [--version-prefix <prefix>] [--secret-id <id>] [--phase2] [--json]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Credential resolution ---
if [[ -z "$SECRET_ID" ]]; then
  echo -n "Enter password (used for all instances): "
  read -rs PASSWORD
  echo
fi

# --- Discover instances ---
DISCOVER_ARGS=(--version-prefix "$VERSION_PREFIX" --json)
[[ -n "$REGION" ]] && DISCOVER_ARGS+=(--region "$REGION")

INSTANCES=$("$SCRIPT_DIR/inventory/discover_instances.sh" "${DISCOVER_ARGS[@]}")
TOTAL=$(echo "$INSTANCES" | jq 'length')

if [[ "$TOTAL" -eq 0 ]]; then
  echo "No MySQL $VERSION_PREFIX instances found."
  exit 0
fi

echo "Found $TOTAL MySQL $VERSION_PREFIX instance(s). Running precheck..." >&2
echo "============================================================" >&2

# --- Run precheck on each instance ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
RESULTS='[]'

echo "$INSTANCES" | jq -c '.[]' | while IFS= read -r inst; do
  id=$(echo "$inst" | jq -r '.instance_id')
  endpoint=$(echo "$inst" | jq -r '.endpoint')
  status=$(echo "$inst" | jq -r '.status')
  source=$(echo "$inst" | jq -r '.source_instance // empty')

  # Skip read replicas
  if [[ -n "$source" ]]; then
    echo "  [$id] SKIP — read replica of $source" >&2
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # Skip non-available instances
  if [[ "$status" != "available" ]]; then
    echo "  [$id] SKIP — status: $status" >&2
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # Skip if no endpoint
  if [[ -z "$endpoint" || "$endpoint" == "null" ]]; then
    echo "  [$id] SKIP — no endpoint" >&2
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # Build precheck args
  PRECHECK_ARGS=(-h "$endpoint" -u "$USER" --json)
  if [[ -n "$SECRET_ID" ]]; then
    PRECHECK_ARGS+=(--secret-id "$SECRET_ID")
  elif [[ -n "$PASSWORD" ]]; then
    PRECHECK_ARGS+=(-p "$PASSWORD")
  fi
  [[ "$RUN_PHASE2" == "true" ]] && PRECHECK_ARGS+=(--phase2)

  # Run precheck
  RESULT=$("$SCRIPT_DIR/precheck/mysql_precheck_run.sh" "${PRECHECK_ARGS[@]}" 2>/dev/null || echo '{"summary":{"errors":999,"warnings":0,"notices":0}}')
  ERRORS=$(echo "$RESULT" | jq -r '.summary.errors // 999')
  WARNINGS=$(echo "$RESULT" | jq -r '.summary.warnings // 0')

  if [[ "$ERRORS" -eq 0 ]]; then
    echo "  [$id] PASS — 0 errors, $WARNINGS warnings" >&2
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [$id] FAIL — $ERRORS errors, $WARNINGS warnings" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  RESULTS=$(echo "$RESULTS" | jq --arg id "$id" --arg errors "$ERRORS" --arg warnings "$WARNINGS" \
    '. + [{"instance_id": $id, "errors": ($errors|tonumber), "warnings": ($warnings|tonumber)}]')
done

# Note: variables inside pipe subshell are lost, re-calculate from RESULTS
PASS_COUNT=$(echo "$RESULTS" | jq '[.[] | select(.errors == 0)] | length')
FAIL_COUNT=$(echo "$RESULTS" | jq '[.[] | select(.errors > 0)] | length')
CHECKED=$(echo "$RESULTS" | jq 'length')

echo "============================================================" >&2
echo "Batch Precheck Summary" >&2
echo "============================================================" >&2
echo "Total discovered: $TOTAL" >&2
echo "Checked:          $CHECKED" >&2
echo "Passed:           $PASS_COUNT" >&2
echo "Failed:           $FAIL_COUNT" >&2
echo "Skipped:          $((TOTAL - CHECKED))" >&2
echo "============================================================" >&2

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "Failed instances:" >&2
  echo "$RESULTS" | jq -r '.[] | select(.errors > 0) | "  \(.instance_id): \(.errors) error(s)"' >&2
fi

if [[ "$JSON_OUTPUT" == "true" ]]; then
  jq -n --argjson results "$RESULTS" --arg total "$TOTAL" \
    '{total_discovered: ($total|tonumber), results: $results, timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}'
fi
