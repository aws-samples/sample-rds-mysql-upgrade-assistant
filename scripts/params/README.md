# Parameter Group Migration

This directory includes `migrate_param_group.sh` from [awslabs/rds-support-tools](https://github.com/awslabs/rds-support-tools) (Apache 2.0).

## Usage

```bash
# Dry run first
./scripts/params/migrate_param_group.sh \
  -s my-mysql80-params -t my-mysql84-params -f mysql8.4 -n

# Apply
./scripts/params/migrate_param_group.sh \
  -s my-mysql80-params -t my-mysql84-params -f mysql8.4
```

Or use the wrapper `prepare_param_group.sh` which auto-detects the current parameter group:

```bash
./scripts/params/prepare_param_group.sh --instance-id my-db --dry-run --json
```

See the [rds-support-tools repository](https://github.com/awslabs/rds-support-tools/blob/main/rds-general/shell/migrate_param_group.sh) for full documentation.
