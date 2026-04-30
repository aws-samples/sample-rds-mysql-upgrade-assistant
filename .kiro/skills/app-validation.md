---
name: Application Validation
description: Run application-level validation queries against MySQL instances after upgrade
inclusion: manual
---

# Application Validation

Run custom application validation SQL against one or more MySQL instances.

## Inputs
- `host` or `instance_id` — Target MySQL endpoint or RDS instance ID
- `user` — MySQL username
- `secret_id` (optional) — Secrets Manager secret for credentials
- `sql_dir` (optional) — Directory containing app_validate*.sql files

## Setup (First Time Only)

### Step 1: Create Validation SQL
Copy the template and customize with your application's critical queries:
```bash
cp scripts/validate/app_validate_template.sql scripts/validate/app_validate.sql
```

Edit `app_validate.sql` to include:
- **Critical read queries** — Key SELECT statements that must work after upgrade
- **Stored procedure tests** — CALL critical procedures and verify results
- **Authentication checks** — Verify app users connect with expected auth plugins
- **Character set validation** — Confirm charset/collation behavior
- **Performance baselines** — Time key queries and compare to pre-upgrade

Each check should output three tab-separated columns: `check_name`, `status` (PASS/FAIL/WARNING/INFO), `detail`.

You can create multiple files (e.g., `app_validate_orders.sql`, `app_validate_auth.sql`) — all `app_validate*.sql` files are executed automatically.

## Run Validation

### Step 2: Run Against Single Instance
```bash
bash scripts/validate/app_validate_run.sh \
  -h <endpoint> -u <user> --secret-id <secret_id> --json
```

### Step 3: Run Against Multiple Instances
For fleet-wide validation after batch upgrade:
```bash
for instance in $(bash scripts/inventory/discover_instances.sh --version-prefix 8.4 --json | jq -r '.[].endpoint'); do
  echo "=== $instance ==="
  bash scripts/validate/app_validate_run.sh \
    -h "$instance" -u admin --secret-id <secret_id> --json
done
```

### Step 4: Review Results
Report summary:
- Total checks run
- PASS / FAIL / WARNING counts
- Any FAIL checks need investigation before confirming upgrade success

### Step 5: Run on Green Environment (Pre-Switchover)
For Blue/Green upgrades, run validation on the green environment BEFORE switchover:
```bash
# Get green endpoint from B/G deployment
bash scripts/validate/app_validate_run.sh \
  -h <green-endpoint> -u <user> --secret-id <secret_id> --json
```
Only proceed with switchover if all checks pass.
