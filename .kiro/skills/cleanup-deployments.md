---
name: Cleanup Blue/Green Deployments
description: Find and clean up completed Blue/Green deployments after successful upgrades
inclusion: manual
---

# Cleanup Blue/Green Deployments

Find all completed Blue/Green deployments and clean them up.

## Inputs
- `region` (optional) — AWS region

## Steps

### Step 1: List Blue/Green Deployments
```bash
aws rds describe-blue-green-deployments \
  --query 'BlueGreenDeployments[?Status==`SWITCHOVER_COMPLETED`].[BlueGreenDeploymentIdentifier,BlueGreenDeploymentName,Status]' \
  --output table
```

### Step 2: Validate Upgraded Instances
For each completed deployment, run post-upgrade validation:
```bash
bash scripts/validate/post_upgrade_validate.sh \
  --instance-id <instance_id> --expected-version 8.4 --json
```
Only proceed with cleanup if validation passes.

### Step 3: Cleanup Each Deployment
For each validated deployment, confirm with user then clean up.
⚠️ **Recommend waiting 24-48 hours after switchover before deleting old instances.**
```bash
# Delete deployment metadata only (keeps old instance):
bash scripts/upgrade/cleanup_blue_green.sh \
  --deployment-id <deployment_id>

# Delete deployment AND old blue instance (irreversible):
bash scripts/upgrade/cleanup_blue_green.sh \
  --deployment-id <deployment_id> --delete-source
```

### Step 4: Verify No Remaining 8.0 Instances
```bash
bash scripts/inventory/discover_instances.sh --version-prefix 8.0 --json
```
Should return empty list if all upgrades and cleanups are complete.

### Step 5: Summary
Report:
- Number of deployments cleaned up
- Any deployments skipped (failed validation)
- Remaining MySQL 8.0 instances (if any)
