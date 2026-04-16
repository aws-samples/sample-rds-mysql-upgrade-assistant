# Parameter Group Migration

This directory uses `migrate_param_group.sh` from awslabs/rds-support-tools (Apache 2.0).

## Setup

Place `migrate_param_group.sh` into this directory and make it executable:

```bash
chmod +x scripts/params/migrate_param_group.sh
```

The script is available from the [awslabs/rds-support-tools](https://github.com/awslabs/rds-support-tools) repository under `rds-general/shell/`.

## Usage

```bash
# Dry run first
./scripts/params/migrate_param_group.sh \
  -s my-mysql80-params -t my-mysql84-params -f mysql8.4 -n

# Apply
./scripts/params/migrate_param_group.sh \
  -s my-mysql80-params -t my-mysql84-params -f mysql8.4
```

See the rds-support-tools repository for full documentation.
