#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/helpers/fixtures"
DISCOVER="$SCRIPT_DIR/../../scripts/inventory/discover_instances.sh"

setup() {
  source "$SCRIPT_DIR/helpers/mock_aws_cli.sh"
  export FIXTURES_DIR
}

@test "discover_instances returns MySQL instances only" {
  run bash "$DISCOVER" --json
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq 'length')
  [ "$count" -eq 2 ]  # 2 MySQL, 1 PostgreSQL filtered out
}

@test "discover_instances filters by version prefix" {
  run bash "$DISCOVER" --json --version-prefix "8.0"
  [ "$status" -eq 0 ]
  versions=$(echo "$output" | jq -r '.[].engine_version')
  echo "$versions" | while read v; do
    [[ "$v" == 8.0* ]]
  done
}

@test "discover_instances filters by tag" {
  run bash "$DISCOVER" --json --tag "env=production"
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq 'length')
  [ "$count" -eq 1 ]
  id=$(echo "$output" | jq -r '.[0].instance_id')
  [ "$id" = "prod-db-01" ]
}

@test "discover_instances includes required fields" {
  run bash "$DISCOVER" --json
  [ "$status" -eq 0 ]
  first=$(echo "$output" | jq '.[0]')
  [ "$(echo "$first" | jq -r '.instance_id')" != "null" ]
  [ "$(echo "$first" | jq -r '.engine_version')" != "null" ]
  [ "$(echo "$first" | jq -r '.instance_class')" != "null" ]
  [ "$(echo "$first" | jq -r '.endpoint')" != "null" ]
  [ "$(echo "$first" | jq -r '.status')" != "null" ]
  [ "$(echo "$first" | jq -r '.parameter_group')" != "null" ]
}

@test "discover_instances table output works" {
  run bash "$DISCOVER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RDS MySQL Instance Discovery"* ]]
  [[ "$output" == *"prod-db-01"* ]]
}
