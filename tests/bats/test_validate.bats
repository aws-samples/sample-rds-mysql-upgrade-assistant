#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/helpers/fixtures"
VALIDATE="$SCRIPT_DIR/../../scripts/validate/post_upgrade_validate.sh"

setup() {
  source "$SCRIPT_DIR/helpers/mock_aws_cli.sh"
  export FIXTURES_DIR

  # Override describe-db-instances to return 8.4 version for validation
  aws() {
    local service="$1"; shift; local action="$1"; shift
    case "$service $action" in
      "rds describe-db-instances")
        cat <<'EOF'
{"DBInstances":[{"DBInstanceIdentifier":"test-db","EngineVersion":"8.4.0","DBInstanceStatus":"available","DBParameterGroups":[{"DBParameterGroupName":"test-mysql84","ParameterApplyStatus":"in-sync"}],"ReadReplicaDBInstanceIdentifiers":[],"Endpoint":{"Address":"test-db.xxx.rds.amazonaws.com","Port":3306}}]}
EOF
        ;;
      "secretsmanager get-secret-value")
        echo '{"SecretString":"{\"username\":\"admin\",\"password\":\"testpass\"}"}'
        ;;
      *) echo "MOCK: $service $action" >&2; return 1 ;;
    esac
  }
  export -f aws
}

@test "validate requires instance-id" {
  run bash "$VALIDATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "validate returns JSON with --json" {
  run bash "$VALIDATE" --instance-id test-db --json --expected-version 8.4
  [ "$status" -eq 0 ]
  overall=$(echo "$output" | jq -r '.overall')
  [ "$overall" = "PASS" ]
}

@test "validate checks engine version" {
  run bash "$VALIDATE" --instance-id test-db --json --expected-version 8.4
  [ "$status" -eq 0 ]
  ver_check=$(echo "$output" | jq -r '.checks[] | select(.name=="engine_version") | .status')
  [ "$ver_check" = "PASS" ]
}

@test "validate checks instance status" {
  run bash "$VALIDATE" --instance-id test-db --json
  [ "$status" -eq 0 ]
  status_check=$(echo "$output" | jq -r '.checks[] | select(.name=="instance_status") | .status')
  [ "$status_check" = "PASS" ]
}

@test "validate table output works" {
  run bash "$VALIDATE" --instance-id test-db
  [ "$status" -eq 0 ]
  [[ "$output" == *"Post-Upgrade Validation"* ]]
  [[ "$output" == *"PASS"* ]]
}
