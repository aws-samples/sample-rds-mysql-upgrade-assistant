---
name: Batch Upgrade All MySQL 8.0 Instances
description: Discover, generate config, and batch upgrade all MySQL 8.0 instances in a region
inclusion: manual
---

# Batch Upgrade All MySQL 8.0 Instances

Automate the full batch upgrade workflow from discovery to completion.

## Inputs
- `region` (optional) — AWS region (default: AWS CLI configured region)
- `target_version` — Target MySQL version (default: 8.4.9)
- `secret_prefix` (optional) — Secrets Manager prefix for credentials
- `concurrency` — Number of parallel upgrades (default: 5, recommended: 5–10 for Blue/Green)

## Supported Upgrade Paths
- **MySQL 8.0 → 8.4** — Standard B/G or in-place
- **MySQL 5.7 → 8.4** — Multi-hop B/G (5.7→8.0→8.4 automated in one deployment)
- Use `--version-prefix 5.7` in Step 1 to discover 5.7 instances

## Steps

### Step 0: Check for Previous Run (Resume Detection)
Always check if a previous batch run exists before starting a new one:
```bash
bash scripts/batch/batch_upgrade.sh --config batch_config.yaml --status
```
- If a state file exists with remaining instances → ask user: "A previous batch run was found with N instances remaining. Resume from where it left off?"
  - If yes → skip to **Step 5b (Resume)**
  - If no → continue with Step 1
- If no state file → this is a fresh run, continue with Step 1

### Step 1: Discover Instances
```bash
bash scripts/inventory/discover_instances.sh --version-prefix 8.0 --json
```
Report the number of instances found and their details.

### Step 2: Generate Batch Config
```bash
# With shared secret (all instances use same credentials)
bash scripts/batch/generate_config.sh \
  --target-version <target_version> \
  --secret-id <secret_id> \
  --concurrency <concurrency> \
  --output batch_config.yaml

# Or with per-instance secrets (prefix + instance_id)
bash scripts/batch/generate_config.sh \
  --target-version <target_version> \
  --secret-prefix <secret_prefix> \
  --concurrency <concurrency> \
  --output batch_config.yaml
```
The generator auto-detects:
- Multi-AZ DB Clusters → `in_place` strategy
- Cross-region replicas → `in_place` strategy
- Standard instances → `blue_green` strategy

Show the generated config to the user for review before proceeding.

### Step 2b: Check Option Groups
For each instance with a custom option group, check and migrate:
```bash
# For each instance in the config
bash scripts/params/check_option_group.sh --instance-id <instance_id> --dry-run --json
```
- Default option group → skip (RDS auto-assigns `default:mysql-8.4`)
- Custom with MARIADB_AUDIT_PLUGIN → auto-creates MySQL 8.4 option group with same options
- Custom with MEMCACHED → excluded (warning only, not a blocker)

Add `--target-option-group` to the batch config for instances that need it.

### Step 3: Batch Precheck (Optional)
Run prechecks on all instances before committing to upgrades:
```bash
bash scripts/batch/batch_precheck.sh -u <user> --secret-id <secret_id> --json
```
Instances with errors will be automatically skipped during batch upgrade, but running precheck first helps identify and fix issues proactively.

### Step 4: Dry Run
```bash
bash scripts/batch/batch_upgrade.sh --config batch_config.yaml --dry-run
```
Report the dry run results. Confirm with user before proceeding.

### Step 5: Execute Batch Upgrade

> **重要：** 批次升級可能耗時數小時。建議在 `tmux` 中執行，避免連線中斷：
> ```bash
> tmux new -s upgrade
> ```

```bash
bash scripts/batch/batch_upgrade.sh \
  --config batch_config.yaml --concurrency <concurrency>
```
Monitor progress and report the summary (completed, failed, skipped).

### Step 5b: Resume (After Interruption or Warm-Up)
If the batch was interrupted (SSH disconnection, manual stop) or paused for warm-up:
```bash
# Check current status first
bash scripts/batch/batch_upgrade.sh --config batch_config.yaml --status

# Resume from last checkpoint
bash scripts/batch/batch_upgrade.sh --config batch_config.yaml --resume
```
The resume mechanism:
- Skips COMPLETED and SKIPPED instances
- Retries IN_PROGRESS instances (detects existing B/G deployments to avoid duplicates)
- Continues PENDING_SWITCHOVER instances (executes switchover)
- Processes remaining PENDING instances normally

### Step 5c: Warm-Up Mode (Optional)
For EBS lazy loading mitigation, set `auto_switchover: false` in the config. The batch will stop after green environments are ready (PENDING_SWITCHOVER state):
```yaml
# In batch_config.yaml
auto_switchover: false
```
After warm-up period (hours/days), change to `auto_switchover: true` and resume:
```bash
bash scripts/batch/batch_upgrade.sh --config batch_config.yaml --resume
```
This picks up from where it stopped and executes switchover for all PENDING_SWITCHOVER instances.

### Step 6: Verify All Upgraded
```bash
bash scripts/inventory/discover_instances.sh --version-prefix 8.0 --json
```
This should return an empty list. If instances remain, report them.

### Step 7: Final Validation
```bash
bash scripts/inventory/discover_instances.sh --version-prefix 8.4 --json
```
Confirm all instances are now on 8.4.x and available.
