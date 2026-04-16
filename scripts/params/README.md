# Parameter Group Migration

This directory uses `migrate_param_group.sh` from [awslabs/rds-support-tools](https://github.com/awslabs/rds-support-tools/blob/main/rds-general/shell/migrate_param_group.sh).

## Setup

Download the script:

```bash
curl -o scripts/params/migrate_param_group.sh \
  https://raw.githubusercontent.com/awslabs/rds-support-tools/main/rds-general/shell/migrate_param_group.sh
chmod +x scripts/params/migrate_param_group.sh
```

## Usage

```bash
# Dry run first
./scripts/params/migrate_param_group.sh \
  -s my-mysql80-params -t my-mysql84-params -f mysql8.4 -n

# Apply
./scripts/params/migrate_param_group.sh \
  -s my-mysql80-params -t my-mysql84-params -f mysql8.4
```

See the [rds-support-tools README](https://github.com/awslabs/rds-support-tools/blob/main/rds-general/rds-general.README) for full documentation.
