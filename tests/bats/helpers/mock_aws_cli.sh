#!/bin/bash
# Mock AWS CLI for testing
# Source this file to override `aws` command in tests

aws() {
  local service="$1"; shift
  local action="$1"; shift

  case "$service $action" in
    "rds describe-db-instances")
      cat "$FIXTURES_DIR/describe_db_instances.json"
      ;;
    "rds create-blue-green-deployment")
      cat "$FIXTURES_DIR/create_blue_green.json"
      ;;
    "rds describe-blue-green-deployments")
      cat "$FIXTURES_DIR/describe_blue_green_available.json"
      ;;
    "rds switchover-blue-green-deployment")
      cat "$FIXTURES_DIR/switchover_result.json"
      ;;
    "rds delete-blue-green-deployment")
      echo '{"BlueGreenDeployment":{"BlueGreenDeploymentIdentifier":"bgd-test","Status":"DELETING"}}'
      ;;
    "rds modify-db-instance")
      echo '{"DBInstance":{"DBInstanceIdentifier":"test-db","DBInstanceStatus":"modifying"}}'
      ;;
    "secretsmanager get-secret-value")
      echo '{"SecretString":"{\"username\":\"admin\",\"password\":\"testpass\"}"}'
      ;;
    "configure get")
      echo "us-east-1"
      ;;
    *)
      echo "MOCK: unhandled aws $service $action $*" >&2
      return 1
      ;;
  esac
}
export -f aws
