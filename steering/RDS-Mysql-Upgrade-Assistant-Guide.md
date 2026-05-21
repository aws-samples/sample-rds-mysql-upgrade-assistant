# RDS MySQL Upgrade Assistant Guide

## Getting Started with Kiro

This toolkit can be used via shell scripts directly, or through Kiro (IDE / CLI) with the MCP server for a natural language workflow.

### Kiro IDE

1. Download from [kiro.dev/downloads](https://kiro.dev/downloads/) (macOS / Windows / Linux)
2. Sign in with AWS Builder ID or IAM Identity Center
3. Open this project in Kiro

### Kiro CLI

```bash
# macOS / Linux
curl -fsSL https://cli.kiro.dev/install | bash
kiro-cli login
```

### MCP Server Setup

Create `.kiro/settings/mcp.json` in the workspace (or `~/.kiro/settings/mcp.json` for global):

```json
{
  "mcpServers": {
    "rds-mysql-upgrade": {
      "command": "uv",
      "args": [
        "run", "--directory", "/path/to/rds-mysql-upgrade-assistant",
        "python", "-m", "rds_upgrade_mcp.server"
      ],
      "env": {
        "AWS_PROFILE": "default",
        "AWS_DEFAULT_REGION": "us-west-2"
      }
    }
  }
}
```

Requires `uv` — install via `curl -LsSf https://astral.sh/uv/install.sh | sh` or `brew install uv`.

### Example Commands in Kiro

- "Discover all MySQL 8.0 instances"
- "Run precheck on mysql8 using secret prod/db/creds"
- "Create Blue/Green deployment for mysql8 upgrading to 8.4"
- "Batch upgrade with config examples/batch_config.yaml --dry-run"

### Credential Security

> ⚠️ **Never ask users to type passwords in Kiro chat.** Chat input is visible in the conversation history and cannot be masked.

Always use `--secret-id` with AWS Secrets Manager for authentication. If the user does not have a secret configured, guide them to create one:

```bash
aws secretsmanager create-secret --name prod/db01/creds \
  --secret-string '{"username":"admin","password":"<password>"}'
```

For one-off operations without Secrets Manager, suggest running the shell script directly in a terminal (which supports interactive password prompts):

```bash
./scripts/precheck/mysql_precheck_run.sh -h <endpoint> -u admin
# Password will be prompted securely (hidden input)
```

---

## Supported Upgrade Paths

- MySQL 8.0.28+ → 8.4.x (major version upgrade)
- Source must be 8.0.28 or later for full precheck coverage
- Target: MySQL 8.4.8 (current RDS latest)

## Upgrade Strategies

### Blue/Green Deployment (Recommended for Production)
- Creates a staging (green) copy of your database
- Upgrades the green environment to 8.4
- Switchover swaps endpoints with minimal downtime (~30s)
- **Switchover is a one-way operation** — there is no reverse switchover
- Old blue instance retained with renamed identifier for investigation
- To revert: restore from pre-upgrade snapshot or use PITR (creates a new instance)
- Requires: instance must be eligible for B/G (no unsupported features)
- **Not supported for instances with cross-Region read replicas** — use in-place upgrade instead

### In-Place Upgrade (Non-Production)
- Directly modifies the instance engine version
- Causes downtime during upgrade (minutes to hours depending on size)
- No automatic rollback — must use PITR if needed
- Simpler but riskier
- **If the instance has read replicas, they are upgraded first automatically before the primary**

## Key Compatibility Issues (8.0 → 8.4)

### Authentication Changes
- RDS MySQL 8.4 uses `caching_sha2_password` as the default authentication plugin
- `mysql_native_password` is still available in 8.4 but deprecated (support ends in a future version)
- Existing accounts using `mysql_native_password` will continue to work after upgrade
- To change the default authentication plugin, create a custom parameter group and modify `authentication_policy`
- Long-term, plan to migrate accounts to `caching_sha2_password`

### Removed Features
- `authentication_fido` plugin removed (use `authentication_webauthn`)
- `keyring_file/encrypted_file/oci` plugins removed (use component equivalents)
- `daemon_memcached` plugin removed (no replacement — MEMCACHED not supported in 8.4)
- Query cache completely removed

### Parameter Default Changes
- `innodb_adaptive_hash_index` → OFF
- `innodb_change_buffering` → none
- `innodb_io_capacity` → 10000 (was 200)
- `innodb_flush_method` → O_DIRECT
- `innodb_buffer_pool_instances` → dynamic based on vCPU
- `innodb_redo_log_capacity` → dynamic based on vCPU

### Reserved Keywords
- `FULL` and `INTERSECT` became reserved in 8.0.31
- Objects using these names need backtick quoting

### SQL Mode Changes
- `binlog_format` only supports ROW in 8.4 (STATEMENT/MIXED deprecated)

## Parameter Group Migration

Use `migrate_param_group.sh` from rds-support-tools:
1. Always dry-run first: `-n` flag
2. Review incompatible parameters (not in target engine)
3. Review skipped parameters (not modifiable in target)

If multiple instances share the same custom parameter group, migrate once and reuse.
Instances using default parameter groups don't need migration — RDS auto-assigns `default.mysql8.4`.

## Option Group Migration

Use `check_option_group.sh` to handle custom option groups:
- **Default option group** → skip (RDS auto-assigns `default:mysql-8.4`)
- **Custom with MARIADB_AUDIT_PLUGIN** → auto-creates MySQL 8.4 option group with same options
- **Custom with MEMCACHED** → MEMCACHED excluded (not supported in 8.4), other options migrated
- **Empty custom group** → creates empty MySQL 8.4 option group

Only instances with custom option groups need migration. Pass the target option group to Blue/Green (`--target-option-group`) or in-place upgrade (`--target-option-group`).

## Precheck Tool

Run `mysql_precheck_run.sh` before every upgrade:
- Phase 1: 19 SQL-based checks (read-only, safe for production)
- Phase 2: CHECK TABLE FOR UPGRADE (acquires metadata locks, run during maintenance)
- Any ERROR findings must be fixed before upgrade
- WARNING findings should be reviewed but don't block upgrade

## Post-Upgrade Validation

After upgrade, verify infrastructure and application health:

### Infrastructure checks (`post_upgrade_validate.sh`):
1. Engine version is 8.4.x
2. Instance status is 'available'
3. MySQL connectivity works
4. Read Replicas are healthy
5. Parameter group is in-sync

### Application checks (`app_validate_run.sh`):
Customize `app_validate.sql` with your critical queries, then run:
```bash
bash scripts/validate/app_validate_run.sh \
  -h <endpoint> -u <user> --secret-id <secret_id> --json
```
Automatically executes all `app_validate*.sql` files and reports PASS/FAIL/WARNING per check.

## Pre-Switchover Readiness Check

Run `pre_switchover_check.sh` before executing switchover to verify guardrails:

```bash
bash scripts/upgrade/pre_switchover_check.sh --deployment-id <id> --json
```

| # | Check | What it verifies | If FAIL |
|---|-------|-----------------|---------|
| 1 | `deployment_status` | Deployment is AVAILABLE | Wait for provisioning to complete or check for errors |
| 2 | `green_instance_status` | Green instance is available | Check RDS events for upgrade errors |
| 3 | `blue_instance_status` | Blue instance is available | Check if maintenance or modification is in progress |
| 4 | `replication_health` | No replication degradation | Reduce write load on blue, check for long-running DDL |
| 5 | `external_replication` | Blue is not an external binlog replica | Stop external replication before switchover |
| 6 | `version_upgrade` | Green version > Blue version | Verify upgrade was applied to green environment |

Only proceed with switchover if overall result is PASS.

Ref: [Blue/Green Switchover Guardrails](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-switching.html)

## Rollback

### Blue/Green
- **Switchover is a one-way operation** — there is no reverse switchover via the B/G deployment
- After switchover, the old blue instance still exists with a renamed identifier (e.g., `-old1` suffix)
- To revert to MySQL 8.0 (fastest method):
  1. Delete the B/G deployment without deleting the old blue instance
  2. Rename the current green instance (e.g., `mydb` → `mydb-green`)
  3. Rename the old blue instance back to the original name (e.g., `mydb-old1` → `mydb`)
  4. Applications reconnect to the original endpoint automatically
- **Data loss warning**: Rename-based revert restores the blue instance's state at the time of switchover. Any data written after switchover will be lost. PITR cannot downgrade the engine version. There is no fully automated path for zero data loss with version rollback.
- Delete the B/G deployment only after confirming the upgrade is successful

### In-Place
- In-place upgrades are irreversible — there is no downgrade path
- Rollback is only possible by restoring from a snapshot:
  - **Manual snapshot**: Take a manual snapshot before upgrading (recommended). Restore from this snapshot to get back to MySQL 8.0.
  - **Point-in-Time Recovery (PITR)**: Restore to a point before the upgrade started. Requires automated backups enabled with sufficient retention.
- Both options create a new RDS instance — you must update application connection strings to point to the restored instance
- Always take a manual snapshot immediately before starting an in-place upgrade

## Batch Upgrade Best Practices

1. Start with non-production environments
2. Run precheck on all instances first (`--dry-run`)
3. Upgrade in waves: dev → staging → prod
4. Use concurrency carefully: 3-5 for B/G (green builds independently, blue stays live), 1 for in-place (each upgrade causes downtime — serial avoids multiple DBs offline simultaneously). Non-production in-place can use 2-3.
5. Monitor CloudWatch during upgrades
6. Keep blue environments for 24-48 hours after switchover
7. Run pre-switchover readiness check before switchover (`pre_switchover_check.sh`) to verify deployment status, replication health, and instance availability
