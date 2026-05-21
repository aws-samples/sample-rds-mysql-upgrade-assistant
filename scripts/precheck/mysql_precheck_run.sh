#!/bin/bash
# ============================================================
# MySQL 8.0.28+ → 8.4 Upgrade Precheck — Two-Phase Runner
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#  You may not use this file except in compliance with the License.
#  A copy of the License is located at
#
#      http://aws.amazon.com/apache2.0/
#
# Usage:
#   ./mysql_precheck_run.sh -h <host> -u <user> [-P <port>] [-p <password>]
#                           [--secret-id <id>] [--iam] [--phase2] [--json]
#
# Credential priority: --secret-id > --iam > -p > MYSQL_PWD env var > interactive prompt
# If -p is omitted and no other method is specified, you will be prompted.
# ============================================================

set -uo pipefail
umask 077

HOST=""
USER=""
PORT="3306"
PASSWORD=""
SECRET_ID=""
USE_IAM=false
RUN_PHASE2=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h) HOST="$2"; shift 2 ;;
    -u) USER="$2"; shift 2 ;;
    -P) PORT="$2"; shift 2 ;;
    -p) echo "WARNING: -p passes password via command line (visible in ps). Prefer --secret-id or --iam." >&2
        PASSWORD="$2"; shift 2 ;;
    --secret-id) SECRET_ID="$2"; shift 2 ;;
    --iam) USE_IAM=true; shift ;;
    --phase2) RUN_PHASE2=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$HOST" || -z "$USER" ]]; then
  echo "Usage: $0 -h <host> -u <user> [-P <port>] [-p <password>] [--secret-id <id>] [--phase2] [--json]"
  exit 1
fi

# --- Input validation ---
if [[ ! "$HOST" =~ ^[a-zA-Z0-9._-]+$ ]] || [ ${#HOST} -gt 253 ]; then
  echo "ERROR: Invalid hostname format"; exit 1
fi
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "ERROR: Invalid port number"; exit 1
fi
if [[ ! "$USER" =~ ^[a-zA-Z0-9._-]+$ ]] || [ ${#USER} -gt 63 ]; then
  echo "ERROR: Invalid username format"; exit 1
fi

# --- Credential resolution (priority: --secret-id > --iam > -p > MYSQL_PWD env > prompt) ---
if [[ -n "$SECRET_ID" ]]; then
  if ! command -v aws &>/dev/null; then
    echo "ERROR: AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
  fi
  SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to retrieve secret (check secret ID, IAM permissions, and region)." >&2; exit 1
  fi
  PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password // empty')
  if [[ -z "$PASSWORD" ]]; then
    echo "ERROR: Secret '$SECRET_ID' does not contain 'password' field"; exit 1
  fi
elif [[ "$USE_IAM" == "true" ]]; then
  if ! command -v aws &>/dev/null; then
    echo "ERROR: AWS CLI not found (required for IAM auth)"; exit 1
  fi
  echo "Generating IAM auth token for $HOST:$PORT..." >&2
  TOKEN_OUTPUT=$(aws rds generate-db-auth-token --hostname "$HOST" --port "$PORT" --username "$USER" 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to generate IAM auth token (check IAM policy and network connectivity)." >&2; exit 1
  fi
  PASSWORD="$TOKEN_OUTPUT"
  unset TOKEN_OUTPUT
elif [[ -z "$PASSWORD" && -n "${MYSQL_PWD:-}" ]]; then
  PASSWORD="$MYSQL_PWD"
fi

if [[ -z "$PASSWORD" ]]; then
  echo -n "Enter password: "
  read -rs PASSWORD
  echo
fi

# --- Check prerequisites ---
if ! command -v mysql &>/dev/null; then
  echo "ERROR: mysql client not found."
  echo "Install: brew install mysql-client (macOS) | sudo dnf install mariadb105 (AL2023) | sudo apt install mysql-client (Ubuntu)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHASE1_SQL="$SCRIPT_DIR/mysql_precheck_phase1.sql"

if [[ ! -f "$PHASE1_SQL" ]]; then
  echo "ERROR: mysql_precheck_phase1.sql not found at $SCRIPT_DIR"; exit 1
fi

PHASE2_SQL=$(mktemp /tmp/mysql_precheck_phase2_XXXXXX)
PHASE1_OUT=$(mktemp /tmp/mysql_precheck_phase1_XXXXXX)
PHASE2_OUT=$(mktemp /tmp/mysql_precheck_phase2_out_XXXXXX)
DEFAULTS_FILE=$(mktemp /tmp/mysql_precheck_cnf_XXXXXX)

mkdir -p "$SCRIPT_DIR/precheck_reports"
REPORT_OUT="$SCRIPT_DIR/precheck_reports/precheck_$(echo "$HOST" | tr '.' '_')_$(date +%Y%m%d_%H%M%S).log"

cat > "$DEFAULTS_FILE" <<EOF
[client]
password=$PASSWORD
EOF
unset PASSWORD

cleanup() { rm -f "$PHASE2_SQL" "$PHASE1_OUT" "$PHASE2_OUT" "$DEFAULTS_FILE"; }
trap cleanup EXIT

CONN_ARGS=(--defaults-extra-file="$DEFAULTS_FILE" --connect-timeout=10 --ssl-mode=REQUIRED --host="$HOST" --port="$PORT" --user="$USER")

# --- Connection test ---
if ! mysql "${CONN_ARGS[@]}" -e "SELECT 1" > /dev/null 2>&1; then
  echo "ERROR: Unable to connect to database. Verify credentials and connectivity."
  exit 1
fi

# ============================================================
# Phase 1
# ============================================================
echo "============================================================"
echo "Phase 1: Running compatibility checks..."
echo "============================================================"

mysql "${CONN_ARGS[@]}" --batch --raw < "$PHASE1_SQL" 2>/dev/null | tee "$PHASE1_OUT"

grep '^CHECK TABLE ' "$PHASE1_OUT" > "$PHASE2_SQL" || true
PHASE2_COUNT=$(wc -l < "$PHASE2_SQL" | tr -d ' ')

P2_ERRORS=0
P2_WARNINGS=0

if [[ "$PHASE2_COUNT" -eq 0 ]]; then
  echo ""
  echo "No user tables/views found. Skipping Phase 2."
  cp "$PHASE1_OUT" "$REPORT_OUT"
elif [[ "$RUN_PHASE2" == "true" ]]; then
  # ============================================================
  # Phase 2
  # ============================================================
  echo ""
  echo "============================================================"
  echo "Phase 2: Running CHECK TABLE FOR UPGRADE ($PHASE2_COUNT objects)..."
  echo "============================================================"

  mysql "${CONN_ARGS[@]}" --batch --raw < "$PHASE2_SQL" 2>/dev/null | tee "$PHASE2_OUT"

  P2_ERRORS=$(awk -F'\t' 'tolower($3)=="error"{n++} END{print n+0}' "$PHASE2_OUT")
  P2_WARNINGS=$(awk -F'\t' 'tolower($3)=="warning"{n++} END{print n+0}' "$PHASE2_OUT")

  {
    sed '/^Phase 1 Summary$/,$ d' "$PHASE1_OUT"
    echo "------------------------------------------------------------"
    echo "Check #3: CHECK TABLE FOR UPGRADE — Results"
    echo "------------------------------------------------------------"
    P2_ISSUES=$(awk -F'\t' 'tolower($3)=="error" || tolower($3)=="warning"' "$PHASE2_OUT")
    if [[ -n "$P2_ISSUES" ]]; then echo "$P2_ISSUES"; else echo "PASS: All tables passed CHECK TABLE FOR UPGRADE."; fi
    echo ""

    P1_LINE=$(grep -E '^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+' "$PHASE1_OUT" | head -1)
    P1_ERRORS=$(echo "$P1_LINE" | awk '{print $1}'); P1_ERRORS=${P1_ERRORS:-0}
    P1_WARNINGS=$(echo "$P1_LINE" | awk '{print $2}'); P1_WARNINGS=${P1_WARNINGS:-0}
    P1_NOTICES=$(echo "$P1_LINE" | awk '{print $3}'); P1_NOTICES=${P1_NOTICES:-0}

    TOTAL_ERRORS=$((P1_ERRORS + P2_ERRORS))
    TOTAL_WARNINGS=$((P1_WARNINGS + P2_WARNINGS))
    TOTAL_NOTICES=$P1_NOTICES

    echo "============================================================"
    echo "Complete Summary (Phase 1 + Phase 2)"
    echo "============================================================"
    printf "  %-24s %s\n" "Phase 1 errors:" "$P1_ERRORS"
    printf "  %-24s %s\n" "Phase 1 warnings:" "$P1_WARNINGS"
    printf "  %-24s %s\n" "Phase 1 notices:" "$P1_NOTICES"
    printf "  %-24s %s\n" "Phase 2 (CHECK TABLE):" "$P2_ERRORS error(s), $P2_WARNINGS warning(s)"
    echo "------------------------------------------------------------"
    printf "  %-24s %s\n" "TOTAL errors:" "$TOTAL_ERRORS"
    printf "  %-24s %s\n" "TOTAL warnings:" "$TOTAL_WARNINGS"
    printf "  %-24s %s\n" "TOTAL notices:" "$TOTAL_NOTICES"
    echo "============================================================"
    if [[ "$TOTAL_ERRORS" -gt 0 ]]; then
      echo "$TOTAL_ERRORS error(s) found. Please fix them before upgrading to MySQL 8.4.9."
    else
      echo "No errors found. You may proceed with the upgrade to MySQL 8.4.9."
    fi
    echo "============================================================"
  } > "$REPORT_OUT"
else
  echo ""
  echo "Phase 2 skipped (use --phase2 to run CHECK TABLE FOR UPGRADE)."
  cp "$PHASE1_OUT" "$REPORT_OUT"
fi

# --- Extract counts for JSON output ---
P1_LINE=$(grep -E '^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+' "$PHASE1_OUT" | head -1)
P1_ERRORS=$(echo "$P1_LINE" | awk '{print $1}'); P1_ERRORS=${P1_ERRORS:-0}
P1_WARNINGS=$(echo "$P1_LINE" | awk '{print $2}'); P1_WARNINGS=${P1_WARNINGS:-0}
P1_NOTICES=$(echo "$P1_LINE" | awk '{print $3}'); P1_NOTICES=${P1_NOTICES:-0}

TOTAL_ERRORS=$((P1_ERRORS + P2_ERRORS))
TOTAL_WARNINGS=$((P1_WARNINGS + P2_WARNINGS))

echo ""
echo "Report saved to: $REPORT_OUT"

# --- JSON output for MCP consumption ---
if [[ "$JSON_OUTPUT" == "true" ]]; then
  SOURCE_VER=$(grep 'Source version:' "$PHASE1_OUT" | head -1 | awk '{print $NF}')
  cat <<ENDJSON
{
  "instance": "$HOST",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_version": "${SOURCE_VER:-unknown}",
  "target_version": "8.4.9",
  "phase1_complete": true,
  "phase2_complete": $RUN_PHASE2,
  "summary": {
    "errors": $TOTAL_ERRORS,
    "warnings": $TOTAL_WARNINGS,
    "notices": $P1_NOTICES,
    "skipped": 3
  },
  "report_path": "$REPORT_OUT"
}
ENDJSON
fi
