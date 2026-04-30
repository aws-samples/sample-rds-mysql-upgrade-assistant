---
name: Batch Upgrade All MySQL 8.0 Instances
description: Discover, generate config, and batch upgrade all MySQL 8.0 instances in a region
inclusion: manual
---

# Batch Upgrade All MySQL 8.0 Instances

Automate the full batch upgrade workflow from discovery to completion.

## Inputs
- `region` (optional) — AWS region (default: AWS CLI configured region)
- `target_version` — Target MySQL version (default: 8.4.8)
- `secret_prefix` (optional) — Secrets Manager prefix for credentials
- `concurrency` — Number of parallel upgrades (default: 3)

## Steps

### Step 1: Discover Instances
```bash
bash scripts/inventory/discover_instances.sh --version-prefix 8.0 --json
```
Report the number of instances found and their details.

### Step 2: Generate Batch Config
```bash
bash scripts/batch/generate_config.sh \
  --target-version <target_version> \
  --secret-prefix <secret_prefix> \
  --output batch_config.yaml
```
The generator auto-detects:
- Multi-AZ DB Clusters → `in_place` strategy
- Cross-region replicas → `in_place` strategy
- Standard instances → `blue_green` strategy

Show the generated config to the user for review before proceeding.

### Step 3: Dry Run
```bash
bash scripts/batch/batch_upgrade.sh --config batch_config.yaml --dry-run
```
Report the dry run results. Confirm with user before proceeding.

### Step 4: Execute Batch Upgrade
```bash
bash scripts/batch/batch_upgrade.sh \
  --config batch_config.yaml --concurrency <concurrency>
```
Monitor progress and report the summary (completed, failed, skipped).

### Step 5: Verify All Upgraded
```bash
bash scripts/inventory/discover_instances.sh --version-prefix 8.0 --json
```
This should return an empty list. If instances remain, report them.

### Step 6: Final Validation
```bash
bash scripts/inventory/discover_instances.sh --version-prefix 8.4 --json
```
Confirm all instances are now on 8.4.x and available.
