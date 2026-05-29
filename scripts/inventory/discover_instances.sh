#!/bin/bash
# ============================================================
# RDS MySQL Instance Discovery
# ============================================================
#
#  Copyright 2024 Amazon.com, Inc. or its affiliates.
#  All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#
# Usage:
#   ./discover_instances.sh [--region <region>] [--version-prefix <prefix>]
#                           [--tag <key=value>] [--json]
# ============================================================

set -euo pipefail

REGION=""
VERSION_PREFIX="8.0"
TAGS=()
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --version-prefix) VERSION_PREFIX="$2"; shift 2 ;;
    --tag) TAGS+=("$2"); shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Check prerequisites ---
if ! command -v aws &>/dev/null; then
  echo "ERROR: AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found. Install: brew install jq (macOS) | sudo yum install jq (AL) | sudo apt install jq (Ubuntu)"
  exit 1
fi

REGION_ARGS=()
if [[ -n "$REGION" ]]; then
  REGION_ARGS=(--region "$REGION")
fi

# --- Discover instances ---
RAW=$(aws rds describe-db-instances \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --filters "Name=engine,Values=mysql" \
  --output json 2>&1)

if [[ $? -ne 0 ]]; then
  echo "ERROR: AWS API call failed. Check credentials and region."; exit 1
fi

# --- Filter and format ---
EFFECTIVE_REGION="${REGION:-$(aws configure get region 2>/dev/null || echo 'us-east-1')}"

RESULT=$(echo "$RAW" | jq --arg prefix "$VERSION_PREFIX" --arg region "$EFFECTIVE_REGION" '
  [.DBInstances[]
   | select(.EngineVersion | startswith($prefix))
   | select(.DBInstanceIdentifier | test("-old[0-9]*$") | not)
   | {
       instance_id: .DBInstanceIdentifier,
       engine_version: .EngineVersion,
       instance_class: .DBInstanceClass,
       multi_az: .MultiAZ,
       cluster_id: (.DBClusterIdentifier // null),
       parameter_group: (.DBParameterGroups[0].DBParameterGroupName // ""),
       endpoint: (.Endpoint.Address // ""),
       port: (.Endpoint.Port // 3306),
       status: .DBInstanceStatus,
       read_replicas: [.ReadReplicaDBInstanceIdentifiers[]?],
       source_instance: (.ReadReplicaSourceDBInstanceIdentifier // null),
       tags: ([.TagList[]? | {(.Key): .Value}] | add // {})
     }
  ]')

# --- Check for active Blue/Green deployments ---
# Get both source (blue) and target (green) ARNs from active deployments
BG_INFO=$(aws rds describe-blue-green-deployments \
  ${REGION_ARGS[@]+"${REGION_ARGS[@]}"} \
  --query 'BlueGreenDeployments[?Status!=`DELETED` && Status!=`DELETING`].{Source:Source,Targets:SwitchoverDetails[].TargetMember}' \
  --output json 2>/dev/null || echo "[]")

# Build lists of source ARNs (to skip) and target ARNs (to mark as green)
BG_SOURCES=$(echo "$BG_INFO" | jq '[.[].Source // empty]')
BG_TARGETS=$(echo "$BG_INFO" | jq '[.[].Targets[]? // empty]')

# Filter out blue (source) instances that already have an active B/G deployment
# Mark green (target) instances with blue_green_role=green
RESULT=$(echo "$RESULT" | jq --argjson sources "$BG_SOURCES" --argjson targets "$BG_TARGETS" '
  [.[] |
    if (. as $inst | $sources | map(contains($inst.instance_id)) | any) then
      empty
    elif (. as $inst | $targets | map(contains($inst.instance_id)) | any) then
      . + {blue_green_role: "green", upgrade_strategy: "in_place"}
    else
      . + {blue_green_role: null, upgrade_strategy: null}
    end
  ]')

# --- Apply tag filters ---
for tag_filter in ${TAGS[@]+"${TAGS[@]}"}; do
  KEY="${tag_filter%%=*}"
  VALUE="${tag_filter#*=}"
  RESULT=$(echo "$RESULT" | jq --arg k "$KEY" --arg v "$VALUE" '
    [.[] | select(.tags[$k] == $v)]')
done

COUNT=$(echo "$RESULT" | jq 'length')

if [[ "$JSON_OUTPUT" == "true" ]]; then
  echo "$RESULT"
else
  echo "============================================================"
  echo "RDS MySQL Instance Discovery"
  echo "============================================================"
  echo "Region:         $EFFECTIVE_REGION"
  echo "Version filter: $VERSION_PREFIX*"
  echo "Instances found: $COUNT"
  echo "------------------------------------------------------------"

  if [[ "$COUNT" -gt 0 ]]; then
    echo "$RESULT" | jq -r '
      ["INSTANCE_ID", "VERSION", "CLASS", "MULTI_AZ", "CLUSTER", "STATUS", "PARAM_GROUP"],
      (.[] | [.instance_id, .engine_version, .instance_class, (.multi_az|tostring), (.cluster_id // "-"), .status, .parameter_group])
      | @tsv' | column -t
  else
    echo "No MySQL instances matching version prefix '$VERSION_PREFIX' found."
  fi
  echo "============================================================"
fi
