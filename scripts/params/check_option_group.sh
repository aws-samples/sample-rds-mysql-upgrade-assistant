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
#   - If option group contains MEMCACHED → ERROR (not supported in 8.4, must remove)
#   - If option group contains MARIADB_AUDIT_PLUGIN or other options →
#     create a new mysql8.4 option group with the same options
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

# Options not supported in MySQL 8.4 — must remove before upgrade
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

OG_ENGINE=$(echo "$OG_JSON" | jq -r '.OptionGroupsList[0].MajorEngineVersion')
OPTIONS=$(echo "$OG_JSON" | jq '[.OptionGroupsList[0].Options[]]')
OPTION_NAMES=$(echo "$OPTIONS" | jq -r '[.[].OptionName] | join(",")')

# --- Check for unsupported options ---
BLOCKERS='[]'
MIGRATE_OPTIONS='[]'

for opt_name in $(echo "$OPTIONS" | jq -r '.[].OptionName'); do
  is_unsupported=false
  for unsupported in "${UNSUPPORTED_OPTIONS[@]}"; do
    if [[ "$opt_name" == "$unsupported" ]]; then
      is_unsupported=true
      BLOCKERS=$(echo "$BLOCKERS" | jq --arg opt "$opt_name" \
        '. + [{"option": $opt, "severity": "ERROR", "message": "Not supported in MySQL 8.4. Remove from option group before upgrading."}]')
      break
    fi
  done
  if [[ "$is_unsupported" == "false" ]]; then
    # This option needs to be migrated to the 8.4 option group
    OPT_SETTINGS=$(echo "$OPTIONS" | jq --arg name "$opt_name" '[.[] | select(.OptionName == $name)][0]')
    MIGRATE_OPTIONS=$(echo "$MIGRATE_OPTIONS" | jq --argjson opt "$OPT_SETTINGS" '. + [$opt]')
  fi
done

BLOCKER_COUNT=$(echo "$BLOCKERS" | jq 'length')
MIGRATE_COUNT=$(echo "$MIGRATE_OPTIONS" | jq 'length')

# --- If blockers exist, report and exit ---
if [[ "$BLOCKER_COUNT" -gt 0 ]]; then
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    jq -n --arg id "$INSTANCE_ID" --arg og "$OG_NAME" --argjson blockers "$BLOCKERS" \
      '{instance_id: $id, option_group: $og, action: "blocked", issues: $blockers}'
  else
    echo "ERROR: Option group '$OG_NAME' contains unsupported options for MySQL 8.4:" >&2
    echo "$BLOCKERS" | jq -r '.[] | "  \(.option): \(.message)"' >&2
    echo "Remove these options before upgrading." >&2
  fi
  exit 1
fi

# --- No options to migrate → still need empty 8.4 option group for custom groups ---
if [[ "$MIGRATE_COUNT" -eq 0 ]]; then
  echo "Custom option group with no migratable options. Creating empty MySQL 8.4 option group." >&2
fi

# --- Create target option group for MySQL 8.4 ---
if [[ -z "$TARGET_OG" ]]; then
  TARGET_OG="${OG_NAME}-mysql84"
fi

echo "Option Group: $OG_NAME (CUSTOM)" >&2
echo "Options to migrate: $OPTION_NAMES" >&2
echo "Target: $TARGET_OG (mysql 8.4)" >&2

if [[ "$DRY_RUN" == "true" ]]; then
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    MIGRATE_NAMES=$(echo "$MIGRATE_OPTIONS" | jq '[.[].OptionName]')
    jq -n --arg id "$INSTANCE_ID" --arg og "$OG_NAME" --arg target "$TARGET_OG" \
      --argjson names "$MIGRATE_NAMES" \
      '{instance_id: $id, option_group: $og, action: "migrate", target_option_group: $target, options_to_migrate: $names, dry_run: true}'
  else
    if [[ "$MIGRATE_COUNT" -gt 0 ]]; then
      echo "[DRY RUN] Would create option group '$TARGET_OG' (mysql 8.4) with options: $OPTION_NAMES"
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
  # Create the target option group
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
  for opt_name in $(echo "$MIGRATE_OPTIONS" | jq -r '.[].OptionName'); do
    ADD_ARGS=(
      ${REGION_ARGS[@]+"${REGION_ARGS[@]}"}
      --option-group-name "$TARGET_OG"
      --options-to-include "OptionName=$opt_name"
      --apply-immediately
    )

    aws rds modify-option-group "${ADD_ARGS[@]}" --output json > /dev/null 2>&1 || {
      echo "WARNING: Failed to add option '$opt_name' to '$TARGET_OG'. May need manual configuration." >&2
      continue
    }
    echo "  Added option: $opt_name" >&2
  done
fi

if [[ "$JSON_OUTPUT" == "true" ]]; then
  jq -n --arg id "$INSTANCE_ID" --arg og "$OG_NAME" --arg target "$TARGET_OG" \
    --argjson opts "$MIGRATE_OPTIONS" \
    '{instance_id: $id, option_group: $og, action: "migrate", target_option_group: $target, options_migrated: [$opts[].OptionName], dry_run: false}'
else
  echo "============================================================"
  echo "Option group migrated: $OG_NAME → $TARGET_OG"
  echo "============================================================"
fi
