---
name: Precheck All Instances
description: Run prechecks on all MySQL 8.0 instances and generate a summary report
inclusion: manual
---

# Precheck All MySQL 8.0 Instances

Discover all instances and run prechecks to assess upgrade readiness.

## Inputs
- `region` (optional) — AWS region
- `secret_prefix` (optional) — Secrets Manager prefix for credentials

## Steps

### Step 1: Discover Instances
```bash
bash scripts/inventory/discover_instances.sh --version-prefix 8.0 --json
```

### Step 2: Run Precheck on Each Instance
For each discovered instance with an endpoint and available credentials:
```bash
bash scripts/precheck/mysql_precheck_run.sh \
  -h <endpoint> -u <user> --secret-id <secret_prefix><instance_id> \
  --phase2 --json
```

### Step 3: Generate Summary Report
Create a table summarizing all precheck results:

| Instance | Version | Errors | Warnings | Notices | Status |
|----------|---------|--------|----------|---------|--------|
| ... | ... | ... | ... | ... | PASS/FAIL |

### Step 4: Identify Blockers
List instances with errors > 0 that need remediation before upgrade.
Group errors by check type to identify common issues across the fleet.

### Step 5: Recommendations
- Instances with 0 errors → Ready for upgrade
- Instances with warnings only → Review warnings, proceed with caution
- Instances with errors → Fix errors before upgrading, provide specific remediation steps
