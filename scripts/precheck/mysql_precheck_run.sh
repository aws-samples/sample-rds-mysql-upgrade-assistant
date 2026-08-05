#!/bin/bash
# ============================================================
# MySQL 8.0.28+ / Aurora MySQL v3 → 8.4 Upgrade Precheck — Two-Phase Runner
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
#                           [--secret-id <id>] [--iam] [--login-path <name>]
#                           [-t <target_version>] [--phase2] [--json]
#
# Credential priority: --secret-id > --iam > --login-path > -p > MYSQL_PWD env var > interactive prompt
# If -p is omitted and no other method is specified, you will be prompted.
#
# Upstream source: https://code.amazon.com/packages/RDSMySQL-MajorVersionUpgradePrecheckTool
# This runner adds: --secret-id, --iam, -p (with warning), and --json output
# for MCP/automation integration. The Phase 1 SQL is the upstream file directly.
# ============================================================

set -uo pipefail
umask 077

HOST=""
USER=""
PORT="3306"
PASSWORD=""
SECRET_ID=""
USE_IAM=false
LOGIN_PATH=""
TARGET_VERSION="8.4.9"
RUN_PHASE2=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h) HOST="$2"; shift 2 ;;
    -u) USER="$2"; shift 2 ;;
    -P) PORT="$2"; shift 2 ;;
    -t) TARGET_VERSION="$2"; shift 2 ;;
    -p) echo "WARNING: -p passes password via command line (visible in ps). Prefer --secret-id, --iam, or --login-path." >&2
        PASSWORD="$2"; shift 2 ;;
    --secret-id) SECRET_ID="$2"; shift 2 ;;
    --iam) USE_IAM=true; shift ;;
    --login-path) LOGIN_PATH="$2"; shift 2 ;;
    --phase2) RUN_PHASE2=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$HOST" || -z "$USER" ]]; then
  echo "Usage: $0 -h <host> -u <user> [-P <port>] [-p <password>] [--secret-id <id>] [--iam] [--login-path <name>] [-t <version>] [--phase2] [--json]"
  exit 1
fi

# --- Input validation (CWE-78, CWE-20) ---
if [[ ! "$HOST" =~ ^[a-zA-Z0-9._-]+$ ]] || [ ${#HOST} -gt 253 ]; then
  echo "ERROR: Invalid hostname format"; exit 1
fi
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "ERROR: Invalid port number"; exit 1
fi
if [[ ! "$USER" =~ ^[a-zA-Z0-9._-]+$ ]] || [ ${#USER} -gt 63 ]; then
  echo "ERROR: Invalid username format"; exit 1
fi
# Target version validation: 8.4.x series supported
if [[ ! "$TARGET_VERSION" =~ ^8\.4\.[0-9]+$ ]]; then
  echo "ERROR: Unsupported target version '$TARGET_VERSION'. This tool supports MySQL 8.4.x only." >&2
  exit 1
fi

# --- Credential resolution (priority: --secret-id > --iam > --login-path > -p > MYSQL_PWD env > prompt) ---
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
elif [[ -n "$LOGIN_PATH" ]]; then
  # mysql_config_editor stores credentials in ~/.mylogin.cnf (encrypted)
  # No password resolution needed — mysql client reads it via --login-path
  :
elif [[ -z "$PASSWORD" && -n "${MYSQL_PWD:-}" ]]; then
  PASSWORD="$MYSQL_PWD"
fi

if [[ -z "$PASSWORD" && -z "$LOGIN_PATH" ]]; then
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

TMPDIR_PRECHECK=$(mktemp -d "${TMPDIR:-/tmp}/mysql_precheck_XXXXXX")
PHASE1_SQL_EFFECTIVE="$TMPDIR_PRECHECK/phase1_effective.sql"
PHASE2_SQL="$TMPDIR_PRECHECK/phase2.sql"
PHASE1_OUT="$TMPDIR_PRECHECK/phase1.out"
PHASE2_OUT="$TMPDIR_PRECHECK/phase2.out"
MYSQL_ERR="$TMPDIR_PRECHECK/mysql_err.txt"
DEFAULTS_FILE="$TMPDIR_PRECHECK/my.cnf"
chmod 700 "$TMPDIR_PRECHECK"

mkdir -p "$SCRIPT_DIR/precheck_reports"
REPORT_OUT="$SCRIPT_DIR/precheck_reports/precheck_$(echo "$HOST" | tr '.' '_')_$(date +%Y%m%d_%H%M%S).log"

# Build connection args based on credential method
if [[ -n "$LOGIN_PATH" ]]; then
  CONN_ARGS=(--login-path="$LOGIN_PATH" --connect-timeout=10 --ssl-mode=REQUIRED --host="$HOST" --port="$PORT" --user="$USER")
else
  cat > "$DEFAULTS_FILE" <<EOF
[client]
password=$PASSWORD
EOF
  unset PASSWORD
  CONN_ARGS=(--defaults-extra-file="$DEFAULTS_FILE" --connect-timeout=10 --ssl-mode=REQUIRED --host="$HOST" --port="$PORT" --user="$USER")
fi

cleanup() { rm -rf "$TMPDIR_PRECHECK"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- Connection test (CWE-209: suppress detailed error to terminal) ---
if ! mysql "${CONN_ARGS[@]}" -e "SELECT 1" > /dev/null 2>"$MYSQL_ERR"; then
  echo "ERROR: Unable to connect to database. Verify credentials and connectivity." >&2
  [[ -s "$MYSQL_ERR" ]] && sed 's/^/  /' "$MYSQL_ERR" >&2
  exit 1
fi

# --- Inject @target_version into Phase 1 SQL ---
sed -E "s/^SET @target_version = '[0-9]+\\.[0-9]+\\.[0-9]+';/SET @target_version = '$TARGET_VERSION'; -- injected by mysql_precheck_run.sh/" \
    "$PHASE1_SQL" > "$PHASE1_SQL_EFFECTIVE"

# Sanity check: confirm substitution
if ! grep -q "^SET @target_version = '$TARGET_VERSION'; -- injected" "$PHASE1_SQL_EFFECTIVE"; then
  echo "ERROR: Failed to inject -t '$TARGET_VERSION' into Phase 1 SQL." >&2
  exit 1
fi

# --- Helper: extract Phase 1 counts from ##PHASE1_COUNTS## marker ---
extract_phase1_counts() {
  local src="$1"
  P1_LINE=$(grep '^##PHASE1_COUNTS## ' "$src" | head -1)
  P1_ERRORS=$(echo "$P1_LINE" | awk '{print $2}'); P1_ERRORS=${P1_ERRORS:-0}
  P1_WARNINGS=$(echo "$P1_LINE" | awk '{print $3}'); P1_WARNINGS=${P1_WARNINGS:-0}
  P1_NOTICES=$(echo "$P1_LINE" | awk '{print $4}'); P1_NOTICES=${P1_NOTICES:-0}
}

# ============================================================
# Phase 1
# ============================================================
echo "============================================================"
echo "Phase 1: Running compatibility checks (target $TARGET_VERSION)..."
echo "============================================================"

mysql "${CONN_ARGS[@]}" --batch --raw < "$PHASE1_SQL_EFFECTIVE" 2>"$MYSQL_ERR" > "$PHASE1_OUT"
PHASE1_EXIT=$?

# Display Phase 1 output (strip machine-readable markers, stop at summary)
sed '/^##PHASE1_SUMMARY_BEGIN##$/,$ d' "$PHASE1_OUT" \
  | grep -v '^##PHASE2## \|^##PHASE1_COUNTS## ' || true

if [[ "$PHASE1_EXIT" -ne 0 ]]; then
  echo "ERROR: Phase 1 SQL execution failed (exit code: $PHASE1_EXIT)." >&2
  if [[ -s "$MYSQL_ERR" ]]; then
    echo "MySQL client error:" >&2
    sed 's/^/  /' "$MYSQL_ERR" >&2
  fi
  exit 1
fi

# Extract CHECK TABLE statements from Phase 1 output (strip ##PHASE2## prefix)
grep '^##PHASE2## ' "$PHASE1_OUT" | sed 's/^##PHASE2## //' > "$PHASE2_SQL" || true

# Validate Phase 2 SQL contains only CHECK TABLE ... FOR UPGRADE (CWE-89)
if [[ -s "$PHASE2_SQL" ]]; then
  INVALID_LINES=$(grep -cvE '^CHECK TABLE `([^`]|``)+`\.`([^`]|``)+` FOR UPGRADE;$' "$PHASE2_SQL" || true)
  if [[ "$INVALID_LINES" -gt 0 ]]; then
    echo "ERROR: Phase 2 SQL contains $INVALID_LINES unexpected statement(s)." >&2
    echo "Expected only: CHECK TABLE \`schema\`.\`table\` FOR UPGRADE;" >&2
    exit 1
  fi
fi

PHASE2_COUNT=$(wc -l < "$PHASE2_SQL" | tr -d ' ')

P2_ERRORS=0
P2_WARNINGS=0

if [[ "$PHASE2_COUNT" -eq 0 ]]; then
  echo ""
  echo "No user tables/views found. Skipping Phase 2."

  extract_phase1_counts "$PHASE1_OUT"

  {
    sed '/^##PHASE1_SUMMARY_BEGIN##$/,$ d' "$PHASE1_OUT" \
      | grep -v '^##PHASE2## \|^##PHASE1_COUNTS## '
    echo "------------------------------------------------------------"
    echo "Check #3: CHECK TABLE FOR UPGRADE — Results"
    echo "------------------------------------------------------------"
    echo "SKIP: No user tables or views found."
    echo ""
    echo "============================================================"
    echo "Complete Summary (Phase 1 only — no user tables)"
    echo "============================================================"
    printf "  %-24s %s\n" "Phase 1 errors:" "$P1_ERRORS"
    printf "  %-24s %s\n" "Phase 1 warnings:" "$P1_WARNINGS"
    printf "  %-24s %s\n" "Phase 1 notices:" "$P1_NOTICES"
    printf "  %-24s %s\n" "Phase 2 (CHECK TABLE):" "SKIP (no user tables)"
    echo "============================================================"
    if [[ "$P1_ERRORS" -gt 0 ]]; then
      echo "$P1_ERRORS error(s) found. Please fix them before upgrading to MySQL $TARGET_VERSION."
    else
      echo "No errors found. You may proceed with the upgrade to MySQL $TARGET_VERSION."
    fi
    echo "============================================================"
  } > "$REPORT_OUT"

elif [[ "$RUN_PHASE2" == "true" ]]; then
  # ============================================================
  # Phase 2
  # ============================================================
  echo ""
  echo "============================================================"
  echo "Phase 2: Running CHECK TABLE FOR UPGRADE ($PHASE2_COUNT objects)..."
  echo "============================================================"

  mysql "${CONN_ARGS[@]}" --batch --raw < "$PHASE2_SQL" 2>"$MYSQL_ERR" > "$PHASE2_OUT"
  # Print Phase 2 output with deduplicated header
  awk 'NR == 1 || $0 != "Table\tOp\tMsg_type\tMsg_text"' "$PHASE2_OUT"

  P2_ERRORS=$(awk -F'\t' 'tolower($3)=="error"{n++} END{print n+0}' "$PHASE2_OUT")
  P2_WARNINGS=$(awk -F'\t' 'tolower($3)=="warning"{n++} END{print n+0}' "$PHASE2_OUT")

  extract_phase1_counts "$PHASE1_OUT"

  TOTAL_ERRORS=$((P1_ERRORS + P2_ERRORS))
  TOTAL_WARNINGS=$((P1_WARNINGS + P2_WARNINGS))
  TOTAL_NOTICES=$P1_NOTICES

  {
    sed '/^##PHASE1_SUMMARY_BEGIN##$/,$ d' "$PHASE1_OUT" \
      | grep -v '^##PHASE2## \|^##PHASE1_COUNTS## '
    echo "------------------------------------------------------------"
    echo "Check #3: CHECK TABLE FOR UPGRADE — Results"
    echo "------------------------------------------------------------"
    P2_ISSUES=$(awk -F'\t' 'tolower($3)=="error" || tolower($3)=="warning"' "$PHASE2_OUT")
    if [[ -n "$P2_ISSUES" ]]; then echo "$P2_ISSUES"; else echo "PASS: All tables passed CHECK TABLE FOR UPGRADE."; fi
    echo ""
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
      echo "$TOTAL_ERRORS error(s) found. Please fix them before upgrading to MySQL $TARGET_VERSION."
    else
      echo "No errors found. You may proceed with the upgrade to MySQL $TARGET_VERSION."
    fi
    echo "============================================================"
  } > "$REPORT_OUT"
else
  echo ""
  echo "Phase 2 skipped (use --phase2 to run CHECK TABLE FOR UPGRADE)."

  extract_phase1_counts "$PHASE1_OUT"

  {
    sed '/^##PHASE1_SUMMARY_BEGIN##$/,$ d' "$PHASE1_OUT" \
      | grep -v '^##PHASE2## \|^##PHASE1_COUNTS## '
  } > "$REPORT_OUT"
fi

# --- Final count extraction ---
extract_phase1_counts "$PHASE1_OUT"
TOTAL_ERRORS=$((P1_ERRORS + P2_ERRORS))
TOTAL_WARNINGS=$((P1_WARNINGS + P2_WARNINGS))

# Print summary to terminal
echo ""
if [[ -f "$REPORT_OUT" ]] && grep -q 'Complete Summary' "$REPORT_OUT"; then
  awk '/Complete Summary/{found=1} found' "$REPORT_OUT"
  echo ""
fi
echo "Report saved to: $REPORT_OUT"

# --- JSON output for MCP consumption ---
if [[ "$JSON_OUTPUT" == "true" ]]; then
  SOURCE_VER=$(grep 'Source version:' "$PHASE1_OUT" | head -1 | awk '{print $NF}')
  # Detect platform (Aurora vs RDS)
  PLATFORM=$(grep 'Platform:' "$PHASE1_OUT" | head -1 | sed 's/.*Platform:[[:space:]]*//')
  cat <<ENDJSON
{
  "instance": "$HOST",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_version": "${SOURCE_VER:-unknown}",
  "target_version": "$TARGET_VERSION",
  "platform": "${PLATFORM:-unknown}",
  "phase1_complete": true,
  "phase2_complete": $RUN_PHASE2,
  "summary": {
    "errors": $TOTAL_ERRORS,
    "warnings": $TOTAL_WARNINGS,
    "notices": ${P1_NOTICES:-0}
  },
  "report_path": "$REPORT_OUT"
}
ENDJSON
fi

# Structured exit code for CI/CD: 0=clean, 1=warnings only, 2=errors
if [[ "$TOTAL_ERRORS" -gt 0 ]]; then
  exit 2
elif [[ "$TOTAL_WARNINGS" -gt 0 ]]; then
  exit 1
fi
exit 0
