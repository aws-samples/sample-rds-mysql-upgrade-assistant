#!/bin/bash
# ============================================================
# Post-Upgrade Validation for RDS MySQL
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Usage:
#   ./post_upgrade_validate.sh --instance-id <id> [--host <host>]
#       [--user <user>] [--secret-id <id>] [--region <region>]
#       [--expected-version <ver>] [--json]
# ============================================================

set -euo pipefail
umask 077

INSTANCE_ID=""
HOST=""
USER=""
SECRET_ID=""
EXPECTED_VERSION="8.4"
JSON_OUTPUT=false
REGION_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --secret-id) SECRET_ID="$2"; shift 2 ;;
    --region) REGION_ARGS=(--region "$2"); shift 2 ;;
    --expected-version) EXPECTED_VERSION="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Usage: $0 --instance-id <id> [--host <host>] [--user <user>] [--secret-id <id>] [--expected-version <ver>] [--json]"
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

# --- Check 1: Engine version ---
INST_INFO=$(aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$INSTANCE_ID" \
  --output json 2>&1)

if [[ $? -ne 0 ]]; then
  add_check "engine_version" "FAIL" "Cannot describe instance. Verify instance ID and permissions."
else
  ACTUAL_VERSION=$(echo "$INST_INFO" | jq -r '.DBInstances[0].EngineVersion')
  if [[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION"* ]]; then
    add_check "engine_version" "PASS" "$ACTUAL_VERSION"
  else
    add_check "engine_version" "FAIL" "Expected $EXPECTED_VERSION*, got $ACTUAL_VERSION"
  fi

  # --- Check 2: Instance status ---
  INST_STATUS=$(echo "$INST_INFO" | jq -r '.DBInstances[0].DBInstanceStatus')
  if [[ "$INST_STATUS" == "available" ]]; then
    add_check "instance_status" "PASS" "$INST_STATUS"
  else
    add_check "instance_status" "FAIL" "Expected available, got $INST_STATUS"
  fi

  # --- Check 5: Parameter group ---
  PARAM_STATUS=$(echo "$INST_INFO" | jq -r '.DBInstances[0].DBParameterGroups[0].ParameterApplyStatus')
  PARAM_NAME=$(echo "$INST_INFO" | jq -r '.DBInstances[0].DBParameterGroups[0].DBParameterGroupName')
  if [[ "$PARAM_STATUS" == "in-sync" ]]; then
    add_check "parameter_group" "PASS" "$PARAM_NAME (in-sync)"
  else
    add_check "parameter_group" "WARNING" "$PARAM_NAME ($PARAM_STATUS) — may need reboot"
  fi

  # --- Check 4: Read Replica status ---
  REPLICA_COUNT=$(echo "$INST_INFO" | jq '.DBInstances[0].ReadReplicaDBInstanceIdentifiers | length')
  if [[ "$REPLICA_COUNT" -gt 0 ]]; then
    REPLICAS=$(echo "$INST_INFO" | jq -r '.DBInstances[0].ReadReplicaDBInstanceIdentifiers[]')
    ALL_HEALTHY=true
    for REPLICA in $REPLICAS; do
      REP_STATUS=$(aws rds describe-db-instances \
        ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
        --db-instance-identifier "$REPLICA" \
        --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "unknown")
      if [[ "$REP_STATUS" != "available" ]]; then ALL_HEALTHY=false; fi
    done
    if [[ "$ALL_HEALTHY" == "true" ]]; then
      add_check "replication_status" "PASS" "$REPLICA_COUNT replica(s) healthy"
    else
      add_check "replication_status" "FAIL" "One or more replicas not available"
    fi
  else
    add_check "replication_status" "PASS" "No replicas (N/A)"
  fi

  # --- Check 3: MySQL connectivity ---
  if [[ -z "$HOST" ]]; then
    HOST=$(echo "$INST_INFO" | jq -r '.DBInstances[0].Endpoint.Address // empty')
  fi

  if [[ -n "$HOST" && -n "$SECRET_ID" ]]; then
    PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
      --query SecretString --output text 2>/dev/null | jq -r '.password // empty')
    if [[ -z "$USER" ]]; then
      USER=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
        --query SecretString --output text 2>/dev/null | jq -r '.username // empty')
    fi

    if [[ -n "$PASSWORD" && -n "$USER" ]]; then
      DEFAULTS_FILE=$(mktemp /tmp/validate_cnf_XXXXXX)
      echo -e "[client]\npassword=$PASSWORD" > "$DEFAULTS_FILE"
      trap 'rm -f '"$DEFAULTS_FILE"'' EXIT

      MYSQL_VER=$(mysql --defaults-extra-file="$DEFAULTS_FILE" --connect-timeout=10 \
        --ssl-mode=REQUIRED -h "$HOST" -u "$USER" -N -e "SELECT VERSION();" 2>/dev/null || echo "")

      if [[ -n "$MYSQL_VER" ]]; then
        add_check "mysql_connectivity" "PASS" "Connected, version: $MYSQL_VER"
      else
        add_check "mysql_connectivity" "FAIL" "Cannot connect to $HOST"
      fi
    else
      add_check "mysql_connectivity" "FAIL" "Cannot retrieve credentials from $SECRET_ID"
    fi
  elif [[ -n "$HOST" ]]; then
    add_check "mysql_connectivity" "PASS" "Skipped (no --secret-id provided)"
  else
    add_check "mysql_connectivity" "PASS" "Skipped (no endpoint available)"
  fi
fi

# --- Output ---
RESULT=$(jq -n --arg id "$INSTANCE_ID" --arg overall "$OVERALL" \
  --argjson checks "$CHECKS" \
  '{instance_id: $id, overall: $overall, checks: $checks, timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}')

if [[ "$JSON_OUTPUT" == "true" ]]; then
  echo "$RESULT"
else
  echo "============================================================"
  echo "Post-Upgrade Validation: $INSTANCE_ID"
  echo "============================================================"
  echo "Overall: $OVERALL"
  echo "------------------------------------------------------------"
  echo "$CHECKS" | jq -r '.[] | "  \(.name): \(.status) — \(.detail)"'
  echo "============================================================"
fi
