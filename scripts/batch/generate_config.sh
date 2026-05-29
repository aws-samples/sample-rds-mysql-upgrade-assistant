#!/bin/bash
# ============================================================
# Generate Batch Upgrade Config from Instance Discovery
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  Licensed under the Apache License, Version 2.0
#
# Usage:
#   ./generate_config.sh [--region <region>] [--version-prefix <prefix>]
#                        [--target-version <ver>] [--tag <key=value>]
#                        [--secret-prefix <prefix>] [--output <file>]
#
# Logic:
#   - Discovers all MySQL instances matching version prefix
#   - Detects Multi-AZ DB Clusters (auto-assigns in_place strategy)
#   - Instances with cross-region replicas → in_place
#   - Instances with default param group → blue_green (no param migration)
#   - Instances with custom param group → blue_green (param migration needed)
# ============================================================

set -euo pipefail

REGION=""
VERSION_PREFIX="8.0"
TARGET_VERSION="8.4.9"
TARGET_PARAM_FAMILY="mysql8.4"
CONCURRENCY=5
SECRET_PREFIX=""
OUTPUT_FILE=""
TAGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --version-prefix) VERSION_PREFIX="$2"; shift 2 ;;
    --target-version) TARGET_VERSION="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --secret-prefix) SECRET_PREFIX="$2"; shift 2 ;;
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --tag) TAGS+=("$2"); shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Validate inputs ---
if [[ ! "$CONCURRENCY" =~ ^[0-9]+$ ]] || [[ "$CONCURRENCY" -lt 1 ]]; then
  echo "ERROR: --concurrency must be a positive integer" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGION_ARGS=()
[[ -n "$REGION" ]] && REGION_ARGS=(--region "$REGION")

# --- Discover instances ---
DISCOVER_ARGS=(--version-prefix "$VERSION_PREFIX" --json)
[[ -n "$REGION" ]] && DISCOVER_ARGS+=(--region "$REGION")
for tag in ${TAGS[@]+"${TAGS[@]}"}; do
  DISCOVER_ARGS+=(--tag "$tag")
done

INSTANCES=$("$SCRIPT_DIR/inventory/discover_instances.sh" "${DISCOVER_ARGS[@]}")
COUNT=$(echo "$INSTANCES" | jq 'length')

if [[ "$COUNT" -eq 0 ]]; then
  echo "No MySQL instances matching version prefix '$VERSION_PREFIX' found." >&2
  exit 0
fi

# --- Discover clusters ---
CLUSTERS=$(aws rds describe-db-clusters \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --query 'DBClusters[?Engine==`mysql`].[DBClusterIdentifier,EngineVersion]' \
  --output json 2>/dev/null || echo "[]")

# Build a set of cluster member instance IDs
CLUSTER_MEMBERS=$(aws rds describe-db-clusters \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --query 'DBClusters[?Engine==`mysql`].DBClusterMembers[].DBInstanceIdentifier' \
  --output json 2>/dev/null || echo "[]")

# --- Generate YAML ---
generate() {
  echo "target_version: \"$TARGET_VERSION\""
  echo "target_param_family: \"$TARGET_PARAM_FAMILY\""
  echo "concurrency: $CONCURRENCY"
  echo "precheck_phase2: false"
  echo "cleanup_blue_after_switchover: true"
  echo ""
  echo "instances:"

  # Track which clusters we've already added
  declare -A SEEN_CLUSTERS

  while IFS= read -r inst; do
    id=$(echo "$inst" | jq -r '.instance_id')
    pg=$(echo "$inst" | jq -r '.parameter_group')
    replicas=$(echo "$inst" | jq -r '.read_replicas[]?' 2>/dev/null)
    source=$(echo "$inst" | jq -r '.source_instance // empty')

    # Skip if this instance is a read replica (will be handled with primary)
    if [[ -n "$source" ]]; then
      continue
    fi

    # Check if instance belongs to a Multi-AZ DB Cluster
    is_cluster_member=$(echo "$CLUSTER_MEMBERS" | jq -r --arg id "$id" 'map(select(. == $id)) | length')
    if [[ "$is_cluster_member" -gt 0 ]]; then
      # Find the cluster this instance belongs to
      cluster_id=$(aws rds describe-db-instances \
        ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
        --db-instance-identifier "$id" \
        --query 'DBInstances[0].DBClusterIdentifier' \
        --output text 2>/dev/null || echo "")

      if [[ -n "$cluster_id" && -z "${SEEN_CLUSTERS[$cluster_id]:-}" ]]; then
        SEEN_CLUSTERS[$cluster_id]=1
        echo "  - instance_id: \"$cluster_id\""
        echo "    strategy: \"in_place\"  # Multi-AZ DB Cluster (B/G not supported)"
        if [[ -n "$SECRET_PREFIX" ]]; then
          echo "    secret_id: \"${SECRET_PREFIX}${cluster_id}\""
        fi
      fi
      continue
    fi

    # Determine strategy
    strategy="blue_green"
    comment=""

    # Check for cross-region replicas
    has_cross_region=false
    for rep in $replicas; do
      if [[ "$rep" == arn:* ]]; then
        has_cross_region=true
        break
      fi
    done

    if [[ "$has_cross_region" == "true" ]]; then
      strategy="in_place"
      comment=" # cross-region replica (B/G not supported)"
    fi

    echo "  - instance_id: \"$id\""

    if [[ -n "$SECRET_PREFIX" ]]; then
      echo "    secret_id: \"${SECRET_PREFIX}${id}\""
    fi

    if [[ "$pg" != default.* ]]; then
      echo "    source_param_group: \"$pg\""
    fi

    echo "    strategy: \"${strategy}\"${comment}"
  done < <(echo "$INSTANCES" | jq -c '.[]')
}

if [[ -n "$OUTPUT_FILE" ]]; then
  generate > "$OUTPUT_FILE"
  echo "Config written to: $OUTPUT_FILE" >&2
  echo "Instances: $COUNT" >&2
else
  generate
fi
