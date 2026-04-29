#!/bin/bash
# ============================================================
# Script Integrity Verification Library
# ============================================================
# Source this file to verify script checksums before execution.
#
# Usage:
#   source "$(dirname "$0")/../lib/integrity_check.sh"
#   verify_dependencies "aws:2.0" "jq:1.5" "mysql:8.0"
# ============================================================

CHECKSUMS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/CHECKSUMS.sha256"

# Verify a script's SHA-256 checksum against the checksums file
verify_script_integrity() {
  local script_path="$1"

  if [[ ! -f "$CHECKSUMS_FILE" ]]; then
    echo "WARNING: No CHECKSUMS.sha256 file found. Skipping integrity check." >&2
    return 0
  fi

  local script_basename
  script_basename=$(basename "$script_path")
  local expected_hash
  expected_hash=$(grep "$script_basename" "$CHECKSUMS_FILE" 2>/dev/null | awk '{print $1}')

  if [[ -z "$expected_hash" ]]; then
    echo "WARNING: No checksum found for $script_basename. Skipping verification." >&2
    return 0
  fi

  local actual_hash
  if command -v shasum &>/dev/null; then
    actual_hash=$(shasum -a 256 "$script_path" | awk '{print $1}')
  elif command -v sha256sum &>/dev/null; then
    actual_hash=$(sha256sum "$script_path" | awk '{print $1}')
  else
    echo "WARNING: No SHA-256 tool available. Skipping integrity check." >&2
    return 0
  fi

  if [[ "$actual_hash" != "$expected_hash" ]]; then
    echo "ERROR: Integrity check FAILED for $script_basename" >&2
    echo "  Expected: $expected_hash" >&2
    echo "  Actual:   $actual_hash" >&2
    return 1
  fi

  return 0
}

# Verify minimum versions of required dependencies
verify_dependencies() {
  local errors=0

  for dep_spec in "$@"; do
    local dep="${dep_spec%%:*}"
    local min_version="${dep_spec#*:}"

    if ! command -v "$dep" &>/dev/null; then
      echo "ERROR: Required dependency '$dep' not found." >&2
      errors=$((errors + 1))
      continue
    fi

    if [[ "$min_version" == "$dep_spec" ]]; then
      # No version specified, just check existence
      continue
    fi

    local actual_version=""
    case "$dep" in
      aws)
        actual_version=$(aws --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        ;;
      jq)
        actual_version=$(jq --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
        ;;
      mysql)
        actual_version=$(mysql --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        ;;
    esac

    if [[ -n "$actual_version" ]]; then
      # Simple major.minor comparison
      local actual_major actual_minor min_major min_minor
      actual_major=$(echo "$actual_version" | cut -d. -f1)
      actual_minor=$(echo "$actual_version" | cut -d. -f2)
      min_major=$(echo "$min_version" | cut -d. -f1)
      min_minor=$(echo "$min_version" | cut -d. -f2)

      if [[ "$actual_major" -lt "$min_major" ]] || \
         [[ "$actual_major" -eq "$min_major" && "$actual_minor" -lt "$min_minor" ]]; then
        echo "ERROR: $dep version $actual_version < required $min_version" >&2
        errors=$((errors + 1))
      fi
    fi
  done

  return $errors
}
