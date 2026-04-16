#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/helpers/fixtures"
CREATE_BG="$SCRIPT_DIR/../../scripts/upgrade/create_blue_green.sh"

setup() {
  source "$SCRIPT_DIR/helpers/mock_aws_cli.sh"
  export FIXTURES_DIR
}

@test "create_blue_green requires instance-id" {
  run bash "$CREATE_BG" --target-version 8.4.0 --target-param-group test
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "create_blue_green requires target-version" {
  run bash "$CREATE_BG" --instance-id test --target-param-group test
  [ "$status" -eq 1 ]
}

@test "create_blue_green returns deployment JSON" {
  run bash "$CREATE_BG" --instance-id prod-db-01 --target-version 8.4.0 --target-param-group test-pg
  [ "$status" -eq 0 ]
  deployment_id=$(echo "$output" | jq -r '.deployment_id')
  [ "$deployment_id" = "bgd-test123456" ]
}

@test "create_blue_green includes source instance in output" {
  run bash "$CREATE_BG" --instance-id prod-db-01 --target-version 8.4.0 --target-param-group test-pg
  [ "$status" -eq 0 ]
  source=$(echo "$output" | jq -r '.source_instance')
  [ "$source" = "prod-db-01" ]
}
