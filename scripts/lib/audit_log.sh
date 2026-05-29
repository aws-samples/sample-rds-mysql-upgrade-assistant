#!/bin/bash
# ============================================================
# Audit Logging Library
# ============================================================
# Source this file in scripts to enable audit logging.
#
# Usage:
#   source "$(dirname "$0")/../lib/audit_log.sh"
#   audit_init "create_blue_green"
#   audit_log "INFO" "Creating deployment for instance: $INSTANCE_ID"
#   audit_log "ACTION" "aws rds create-blue-green-deployment"
#   audit_finish 0
# ============================================================

AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd || pwd)/logs}"
AUDIT_LOG_FILE=""
AUDIT_SCRIPT_NAME=""
AUDIT_START_TIME=""

audit_init() {
  local script_name="${1:-$(basename "$0" .sh)}"
  AUDIT_SCRIPT_NAME="$script_name"
  AUDIT_START_TIME=$(date +%s)

  mkdir -p "$AUDIT_LOG_DIR"
  chmod 700 "$AUDIT_LOG_DIR"

  AUDIT_LOG_FILE="$AUDIT_LOG_DIR/${script_name}_$(date +%Y%m%d_%H%M%S).log"

  {
    echo "============================================================"
    echo "AUDIT LOG: $script_name"
    echo "============================================================"
    echo "Timestamp : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "User      : $(whoami)"
    echo "Host      : $(hostname -s 2>/dev/null || echo unknown)"
    echo "Script    : $(cd "$(dirname "${0:-.}")" 2>/dev/null && pwd || pwd)/$(basename "${0:-.}")"
    echo "Arguments : $*"
    echo "PID       : $$"
    echo "AWS Caller: $(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo 'unknown')"
    echo "============================================================"
  } >> "$AUDIT_LOG_FILE"
}

audit_log() {
  # Skip if audit_init was not called (e.g., MCP subprocess path issues)
  [[ -z "$AUDIT_LOG_FILE" ]] && return 0

  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "[$timestamp] [$level] $message" >> "$AUDIT_LOG_FILE"

  # Also output to stderr for real-time visibility
  case "$level" in
    ERROR) echo "[$timestamp] [ERROR] $message" >&2 ;;
    WARN)  echo "[$timestamp] [WARN]  $message" >&2 ;;
  esac
}

audit_finish() {
  # Skip if audit_init was not called
  [[ -z "$AUDIT_LOG_FILE" ]] && return 0

  local exit_code="${1:-$?}"
  local elapsed=$(( $(date +%s) - ${AUDIT_START_TIME:-$(date +%s)} ))

  {
    echo "============================================================"
    echo "COMPLETED"
    echo "Exit Code : $exit_code"
    echo "Duration  : ${elapsed}s"
    echo "Timestamp : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "============================================================"
  } >> "$AUDIT_LOG_FILE"

  if [[ "$exit_code" -eq 0 ]]; then
    echo "Audit log: $AUDIT_LOG_FILE" >&2
  fi
}

# Auto-finish on exit if initialized
trap 'audit_finish $?' EXIT 2>/dev/null || true
