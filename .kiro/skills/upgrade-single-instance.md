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
- `target_version` — Target MySQL version (default: 8.4.8)

## Steps

### Step 1: Precheck
Run the 19-check compatibility assessment:
```bash
bash scripts/precheck/mysql_precheck_run.sh \
  -h <endpoint> -u <user> --secret-id <secret_id> --phase2 --json
```
If errors > 0, STOP and report findings. Do not proceed with upgrade.

### Step 2: Prepare Parameter Group
Check if the instance uses a custom parameter group and migrate if needed:
```bash
bash scripts/params/prepare_param_group.sh \
  --instance-id <instance_id> --target-family mysql8.4 --json
```

### Step 3: Detect Strategy
- If instance is a Multi-AZ DB Cluster → use **in-place** (Blue/Green not supported)
- If instance has cross-region read replicas → use **in-place** (Blue/Green not supported)
- Otherwise → use **Blue/Green** (recommended)

### Step 4a: Blue/Green Path
```bash
# Create deployment
bash scripts/upgrade/create_blue_green.sh \
  --instance-id <instance_id> --target-version <target_version> \
  --target-param-group <param_group>

# Monitor until AVAILABLE
bash scripts/upgrade/monitor_blue_green.sh \
  --deployment-id <deployment_id> --poll-interval 60

# Execute switchover
bash scripts/upgrade/switchover_blue_green.sh \
  --deployment-id <deployment_id>
```

### Step 4b: In-Place Path
```bash
bash scripts/upgrade/in_place_upgrade.sh \
  --instance-id <instance_id> --target-version <target_version> \
  --target-param-group <param_group> --apply-immediately
```

### Step 5: Validate
```bash
bash scripts/validate/post_upgrade_validate.sh \
  --instance-id <instance_id> --expected-version <target_version> --json
```
Report the validation results. All checks should be PASS.

### Step 6: Cleanup (Blue/Green only)
After confirming upgrade is successful (recommend waiting 24-48 hours):
```bash
bash scripts/upgrade/cleanup_blue_green.sh \
  --deployment-id <deployment_id> --delete-source
```
