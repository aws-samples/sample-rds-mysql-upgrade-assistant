#!/bin/bash
# ============================================================
# Check and Migrate Option Group for MySQL 8.4 Upgrade
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Logic:
#   - If instance uses default option group → skip (RDS auto-assigns default:mysql-8.4)
#   - If custom option group is empty → skip (use default:mysql-8.4, avoids B/G issues)
#   - If custom option group has only unsupported options (MEMCACHED) → skip
#   - If custom option group has supported options → create MySQL 8.4 option group
#     - MEMCACHED excluded (not supported in 8.4)
#     - MARIADB_AUDIT_PLUGIN and other supported options are migrated
#
# Usage:
#   ./check_option_group.sh --instance-id <id> [--region <region>]
#                           [--target-group <name>] [--dry-run] [--json]
#
# Ref: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.MySQL.Options.html
# ============================================================

set -euo pipefail

INSTANCE_ID=""
REGION=""
TARGET_OG=""
DRY_RUN=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --target-group) TARGET_OG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Usage: $0 --instance-id <id> [--region <region>] [--target-group <name>] [--dry-run] [--json]"
  exit 1
fi

REGION_ARGS=()
if [[ -n "$REGION" ]]; then
  REGION_ARGS=(--region "$REGION")
fi

# Options not supported in MySQL 8.4 — excluded from target option group
UNSUPPORTED_OPTIONS=("MEMCACHED")

# --- Get instance option group ---
INST_JSON=$(aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --db-instance-identifier "$INSTANCE_ID" \
  --output json 2>/dev/null)

OG_NAME=$(echo "$INST_JSON" | jq -r '.DBInstances[0].OptionGroupMemberships[0].OptionGroupName // empty')

if [[ -z "$OG_NAME" ]]; then
  echo "ERROR: Cannot determine option group for $INSTANCE_ID" >&2
  exit 1
fi

# --- Check if default option group ---
if [[ "$OG_NAME" == default:* ]]; then
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    jq -n --arg id "$INSTANCE_ID" --arg og "$OG_NAME" \
      '{instance_id: $id, option_group: $og, action: "skip", reason: "Default option group. RDS auto-assigns default:mysql-8.4 during upgrade.", target_option_group: null}'
  else
    echo "Option Group: $OG_NAME (DEFAULT)"
    echo "Action: SKIP — RDS auto-assigns default:mysql-8.4 during upgrade."
  fi
  exit 0
fi

# --- Custom option group — inspect options ---
OG_JSON=$(aws rds describe-option-groups \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --option-group-name "$OG_NAME" \
  --output json 2>/dev/null)

OPTIONS=$(echo "$OG_JSON" | jq '[.OptionGroupsList[0].Options[]]')
MIGRATE_OPTIONS='[]'
SKIPPED_OPTIONS='[]'

for opt_name in $(echo "$OPTIONS" | jq -r '.[].OptionName'); do
  is_unsupported=false
  for unsupported in "${UNSUPPORTED_OPTIONS[@]}"; do
    if [[ "$opt_name" == "$unsupported" ]]; then
      is_unsupported=true
      SKIPPED_OPTIONS=$(echo "$SKIPPED_OPTIONS" | jq --arg opt "$opt_name" \
        '. + [$opt]')
      echo "WARNING: Option '$opt_name' not supported in MySQL 8.4 — excluding from target option group." >&2
      break
    fi
  done
  if [[ "$is_unsupported" == "false" ]]; then
    OPT_SETTINGS=$(echo "$OPTIONS" | jq --arg name "$opt_name" '[.[] | select(.OptionName == $name)][0]')
    MIGRATE_OPTIONS=$(echo "$MIGRATE_OPTIONS" | jq --argjson opt "$OPT_SETTINGS" '. + [$opt]')
  fi
done

MIGRATE_COUNT=$(echo "$MIGRATE_OPTIONS" | jq 'length')

# --- Empty custom option group → skip (use default:mysql-8.4 instead) ---
if [[ "$MIGRATE_COUNT" -eq 0 && $(echo "$SKIPPED_OPTIONS" | jq 'length') -eq 0 ]]; then
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    jq -n --arg id "$INSTANCE_ID" --arg og "$OG_NAME" \
      '{instance_id: $id, option_group: $og, action: "skip", reason: "Empty custom option group. No target option group needed — RDS will use default:mysql-8.4.", target_option_group: null}'
  else
    echo "Option Group: $OG_NAME (CUSTOM — empty)"
    echo "Action: SKIP — No options configured. RDS will use default:mysql-8.4 during upgrade."
  fi
  exit 0
fi

# If only unsupported options (e.g., MEMCACHED only) → also skip
if [[ "$MIGRATE_COUNT" -eq 0 && $(echo "$SKIPPED_OPTIONS" | jq 'length') -gt 0 ]]; then
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    jq -n --arg id "$INSTANCE_ID" --arg og "$OG_NAME" --argjson skipped "$SKIPPED_OPTIONS" \
      '{instance_id: $id, option_group: $og, action: "skip", reason: "All options unsupported in 8.4 (excluded). No target option group needed.", target_option_group: null, options_skipped: $skipped}'
  else
    echo "Option Group: $OG_NAME (CUSTOM)"
    echo "All options unsupported in MySQL 8.4 (excluded): $(echo "$SKIPPED_OPTIONS" | jq -r 'join(", ")')"
    echo "Action: SKIP — No target option group needed. RDS will use default:mysql-8.4."
  fi
  exit 0
fi

# --- Create target option group for MySQL 8.4 ---
if [[ -z "$TARGET_OG" ]]; then
  TARGET_OG="${OG_NAME}-mysql84"
fi

echo "Option Group: $OG_NAME (CUSTOM)" >&2
if [[ "$MIGRATE_COUNT" -gt 0 ]]; then
  echo "Options to migrate: $(echo "$MIGRATE_OPTIONS" | jq -r '[.[].OptionName] | join(", ")')" >&2
else
  echo "No options to migrate (creating empty 8.4 option group)" >&2
fi
echo "Target: $TARGET_OG (mysql 8.4)" >&2

if [[ "$DRY_RUN" == "true" ]]; then
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    MIGRATE_NAMES=$(echo "$MIGRATE_OPTIONS" | jq '[.[].OptionName]')
    jq -n --arg id "$INSTANCE_ID" --arg og "$OG_NAME" --arg target "$TARGET_OG" \
      --argjson migrate "$MIGRATE_NAMES" --argjson skipped "$SKIPPED_OPTIONS" \
      '{instance_id: $id, option_group: $og, action: "migrate", target_option_group: $target, options_to_migrate: $migrate, options_skipped: $skipped, dry_run: true}'
  else
    if [[ "$MIGRATE_COUNT" -gt 0 ]]; then
      echo "[DRY RUN] Would create option group '$TARGET_OG' (mysql 8.4) with options: $(echo "$MIGRATE_OPTIONS" | jq -r '[.[].OptionName] | join(", ")')"
    else
      echo "[DRY RUN] Would create empty option group '$TARGET_OG' (mysql 8.4)"
    fi
  fi
  exit 0
fi

# --- Check if target already exists ---
if aws rds describe-option-groups \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --option-group-name "$TARGET_OG" > /dev/null 2>&1; then
  echo "Target option group '$TARGET_OG' already exists. Skipping creation." >&2
else
  aws rds create-option-group \
    ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
    --option-group-name "$TARGET_OG" \
    --engine-name mysql \
    --major-engine-version "8.4" \
    --option-group-description "Migrated from $OG_NAME for MySQL 8.4 upgrade" \
    --output json > /dev/null 2>&1 || {
    echo "ERROR: Failed to create option group '$TARGET_OG'" >&2
    exit 1
  }
  echo "Created option group: $TARGET_OG" >&2
fi

# --- Add options to target group (if any) ---
if [[ "$MIGRATE_COUNT" -gt 0 ]]; then
  for opt_json in $(echo "$MIGRATE_OPTIONS" | jq -c '.[]'); do
    opt_name=$(echo "$opt_json" | jq -r '.OptionName')

    # Reconstruct option settings from source
    OPTIONS_SPEC=$(echo "$opt_json" | jq -c \
      '[{OptionName: .OptionName, OptionSettings: [(.OptionSettings // [])[] | {Name: .Name, Value: .Value}]}]')

    aws rds modify-option-group \
      ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
      --option-group-name "$TARGET_OG" \
      --options-to-include "$OPTIONS_SPEC" \
      --apply-immediately \
      --output json > /dev/null 2>&1 || {
      echo "WARNING: Failed to add option '$opt_name' to '$TARGET_OG'. May need manual configuration." >&2
      continue
    }
    echo "  Added option: $opt_name (with settings)" >&2
  done
fi

if [[ "$JSON_OUTPUT" == "true" ]]; then
  MIGRATE_NAMES=$(echo "$MIGRATE_OPTIONS" | jq '[.[].OptionName]')
  jq -n --arg id "$INSTANCE_ID" --arg og "$OG_NAME" --arg target "$TARGET_OG" \
    --argjson migrate "$MIGRATE_NAMES" --argjson skipped "$SKIPPED_OPTIONS" \
    '{instance_id: $id, option_group: $og, action: "migrate", target_option_group: $target, options_migrated: $migrate, options_skipped: $skipped, dry_run: false}'
else
  echo "============================================================"
  echo "Option group migrated: $OG_NAME → $TARGET_OG"
  echo "============================================================"
fi
