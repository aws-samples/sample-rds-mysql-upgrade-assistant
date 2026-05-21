---
name: Upgrade Single RDS MySQL Instance
description: End-to-end upgrade of a single RDS MySQL 8.0 instance to 8.4 using Blue/Green or in-place strategy
inclusion: manual
---

# Upgrade Single RDS MySQL Instance

Execute the full upgrade workflow for a single RDS MySQL instance.

## Inputs
- `instance_id` — The RDS instance or cluster identifier
- `secret_id` (optional) — Secrets Manager secret for MySQL credentials
- `target_version` — Target MySQL version (default: 8.4.9)

## Steps

### Step 1: Precheck
Run the 19-check compatibility assessment:
```bash
bash scripts/precheck/mysql_precheck_run.sh \
  -h <endpoint> -u <user> --secret-id <secret_id> --phase2 --json
```
If errors > 0, STOP and report findings. Do not proceed with upgrade.

### Step 2: Prepare Parameter Group (only if custom)
If the instance uses a custom parameter group, migrate it to MySQL 8.4. If it uses a default parameter group, skip — RDS auto-assigns `default.mysql8.4`.
```bash
bash scripts/params/prepare_param_group.sh \
  --instance-id <instance_id> --target-family mysql8.4 --json
```

### Step 2b: Check Option Group (only if custom)
If the instance uses a custom option group (e.g., with MARIADB_AUDIT_PLUGIN), create a MySQL 8.4 option group with the same options. If it uses a default option group, skip — RDS auto-assigns `default:mysql-8.4`.
```bash
bash scripts/params/check_option_group.sh \
  --instance-id <instance_id> --json
```
- If MEMCACHED is found → warning only, excluded from target option group (not a blocker)
- If MARIADB_AUDIT_PLUGIN or other options found → auto-creates a MySQL 8.4 option group with the same options
- If default option group → skip

### Step 3: Detect Strategy
- If instance is a Multi-AZ DB Cluster → use **in-place** (Blue/Green not supported)
- If instance has cross-region read replicas → use **in-place** (Blue/Green not supported)
- Otherwise → use **Blue/Green** (recommended)

### Step 4a: Blue/Green Path
```bash
# Create deployment (add --target-option-group only if custom option group was migrated)
bash scripts/upgrade/create_blue_green.sh \
  --instance-id <instance_id> --target-version <target_version> \
  --target-param-group <param_group> \
  [--target-option-group <option_group>]

# Monitor until AVAILABLE
bash scripts/upgrade/monitor_blue_green.sh \
  --deployment-id <deployment_id> --poll-interval 60

# Validate green environment (infra + app)
bash scripts/validate/post_upgrade_validate.sh \
  --instance-id <green_instance_id> --expected-version <target_version> --json
bash scripts/validate/app_validate_run.sh \
  -h <green_endpoint> -u <user> --secret-id <secret_id> --json

# Pre-switchover readiness check
bash scripts/upgrade/pre_switchover_check.sh \
  --deployment-id <deployment_id> --json
```
Only proceed with switchover if both validation and pre-switchover check pass.

```bash
# Execute switchover
bash scripts/upgrade/switchover_blue_green.sh \
  --deployment-id <deployment_id>

# Connectivity check after switchover
bash scripts/validate/post_upgrade_validate.sh \
  --instance-id <instance_id> --expected-version <target_version> --json
```

### Step 4b: In-Place Path
```bash
# Add --target-option-group only if custom option group was migrated
bash scripts/upgrade/in_place_upgrade.sh \
  --instance-id <instance_id> --target-version <target_version> \
  --target-param-group <param_group> \
  [--target-option-group <option_group>] \
  --apply-immediately
```

### Step 5: Post-Upgrade Validation (In-Place Path)
```bash
bash scripts/validate/post_upgrade_validate.sh \
  --instance-id <instance_id> --expected-version <target_version> --json
bash scripts/validate/app_validate_run.sh \
  -h <endpoint> -u <user> --secret-id <secret_id> --json
```
Report the validation results. All checks should be PASS.
If no custom SQL files exist, remind the user to copy and customize the template:
```bash
cp scripts/validate/app_validate_template.sql scripts/validate/app_validate.sql
# Edit app_validate.sql with application-specific queries
```

### Step 6: Cleanup (Blue/Green only)
After confirming upgrade is successful (recommend waiting 24-48 hours):
```bash
bash scripts/upgrade/cleanup_blue_green.sh \
  --deployment-id <deployment_id> --delete-source
```
