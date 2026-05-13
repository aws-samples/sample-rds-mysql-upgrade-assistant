#!/bin/bash
# ============================================================
# Application Validation Runner for Post-Upgrade Testing
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Runs custom application validation SQL against a MySQL instance
# and reports results in structured format.
#
# Usage:
#   ./app_validate_run.sh -h <host> -u <user> [-P <port>]
#       [--secret-id <id>] [--iam] [--sql-dir <dir>] [--json]
#
# SQL files are loaded from --sql-dir (default: same directory as this script).
# Any file matching app_validate*.sql will be executed.
# ============================================================

set -uo pipefail
umask 077

HOST=""
USER=""
PORT="3306"
PASSWORD=""
SECRET_ID=""
USE_IAM=false
SQL_DIR=""
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h) HOST="$2"; shift 2 ;;
    -u) USER="$2"; shift 2 ;;
    -P) PORT="$2"; shift 2 ;;
    --secret-id) SECRET_ID="$2"; shift 2 ;;
    --iam) USE_IAM=true; shift ;;
    --sql-dir) SQL_DIR="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$HOST" || -z "$USER" ]]; then
  echo "Usage: $0 -h <host> -u <user> [-P <port>] [--secret-id <id>] [--iam] [--sql-dir <dir>] [--json]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -z "$SQL_DIR" ]]; then
  SQL_DIR="$SCRIPT_DIR"
fi

# --- Credential resolution ---
if [[ -n "$SECRET_ID" ]]; then
  SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to retrieve secret." >&2; exit 1
  fi
  PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password // empty')
  if [[ -z "$PASSWORD" ]]; then
    echo "ERROR: Secret does not contain 'password' field." >&2; exit 1
  fi
elif [[ "$USE_IAM" == "true" ]]; then
  TOKEN_OUTPUT=$(aws rds generate-db-auth-token --hostname "$HOST" --port "$PORT" --username "$USER" 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to generate IAM auth token." >&2; exit 1
  fi
  PASSWORD="$TOKEN_OUTPUT"
elif [[ -z "$PASSWORD" && -n "${MYSQL_PWD:-}" ]]; then
  PASSWORD="$MYSQL_PWD"
fi

if [[ -z "$PASSWORD" ]]; then
  echo -n "Enter password: "
  read -rs PASSWORD
  echo
fi

# --- Setup MySQL connection ---
DEFAULTS_FILE=$(mktemp /tmp/app_validate_cnf_XXXXXX)
cat > "$DEFAULTS_FILE" <<EOF
[client]
password=$PASSWORD
EOF
unset PASSWORD
trap 'rm -f '"$DEFAULTS_FILE"'' EXIT

CONN_ARGS=(--defaults-extra-file="$DEFAULTS_FILE" --connect-timeout=10 --ssl-mode=REQUIRED --host="$HOST" --port="$PORT" --user="$USER")

# --- Connection test ---
if ! mysql "${CONN_ARGS[@]}" -e "SELECT 1" > /dev/null 2>&1; then
  echo "ERROR: Unable to connect to $HOST:$PORT. Verify credentials and connectivity." >&2
  exit 1
fi

# --- Find SQL files ---
if ! find "$SQL_DIR" -name 'app_validate*.sql' -type f 2>/dev/null | grep -q .; then
  echo "No app_validate*.sql files found in $SQL_DIR" >&2
  echo "Copy app_validate_template.sql to app_validate.sql and customize it." >&2
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo '{"host":"'"$HOST"'","status":"SKIPPED","reason":"No validation SQL files found","checks":[]}'
  fi
  exit 0
fi

# --- Run each SQL file and collect results ---
ALL_RESULTS='[]'
OVERALL="PASS"
TOTAL_CHECKS=0
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

while IFS= read -r sql_file; do
  sql_name=$(basename "$sql_file")
  echo "Running: $sql_name ..." >&2

  # Execute SQL and capture tab-separated output (check_name, status, detail)
  OUTPUT=$(mysql "${CONN_ARGS[@]}" --batch --raw < "$sql_file" 2>/dev/null || echo "")

  # Parse results — expect rows with: check_name\tstatus\tdetail
  while IFS=$'\t' read -r check_name status detail; do
    # Skip headers, empty lines, and separator lines
    [[ -z "$check_name" ]] && continue
    [[ "$check_name" == "check_name" ]] && continue
    [[ "$check_name" == "---"* ]] && continue
    [[ "$check_name" == "==="* ]] && continue

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    case "$status" in
      PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
      FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); OVERALL="FAIL" ;;
      WARNING) WARN_COUNT=$((WARN_COUNT + 1)) ;;
      INFO) ;; # informational, no count
    esac

    ALL_RESULTS=$(echo "$ALL_RESULTS" | jq \
      --arg name "$check_name" --arg status "$status" --arg detail "$detail" --arg file "$sql_name" \
      '. + [{"check": $name, "status": $status, "detail": $detail, "file": $file}]')
  done <<< "$OUTPUT"
done < <(find "$SQL_DIR" -name 'app_validate*.sql' -type f 2>/dev/null | sort)

# --- Output ---
if [[ "$JSON_OUTPUT" == "true" ]]; then
  jq -n --arg host "$HOST" --arg overall "$OVERALL" \
    --argjson checks "$ALL_RESULTS" \
    --arg total "$TOTAL_CHECKS" --arg pass "$PASS_COUNT" --arg fail "$FAIL_COUNT" --arg warn "$WARN_COUNT" \
    '{
      host: $host,
      overall: $overall,
      summary: {total: ($total|tonumber), pass: ($pass|tonumber), fail: ($fail|tonumber), warning: ($warn|tonumber)},
      checks: $checks,
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }'
else
  echo "============================================================"
  echo "Application Validation: $HOST"
  echo "============================================================"
  echo "Overall: $OVERALL"
  echo "Total: $TOTAL_CHECKS | Pass: $PASS_COUNT | Fail: $FAIL_COUNT | Warning: $WARN_COUNT"
  echo "------------------------------------------------------------"
  echo "$ALL_RESULTS" | jq -r '.[] | "  \(.check): \(.status) — \(.detail)"'
  echo "============================================================"
fi
