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
# Create a shared secret for all instances (Other type of secret)
aws secretsmanager create-secret --name rds/shared/admin \
  --secret-string '{"username":"admin","password":"<password>"}'
```

**Important**: The secret value must be valid JSON with `username` and `password` as top-level keys:
```json
{"username":"admin","password":"your_secure_password"}
```

Common mistake — do NOT use escaped quotes or nested structure:
```json
{"\"username\":\"admin\"":"\"password\":\"xxx\""}   ← WRONG
```

**Secret types in AWS Console:**
- **Credentials for Amazon RDS database** — ties to a specific instance, supports auto-rotation
- **Other type of secret** — flexible, can be shared across all instances with the same credentials (recommended for batch operations with shared admin password)

For one-off operations without Secrets Manager, suggest running the shell script directly in a terminal (which supports interactive password prompts):

```bash
./scripts/precheck/mysql_precheck_run.sh -h <endpoint> -u admin
# Password will be prompted securely (hidden input)
```

---

## Workflow Decision Tree

When guiding a user through an upgrade, follow this sequence and suggest the next step automatically:

```
1. discover_instances → show inventory summary
2. run_precheck (or batch_precheck) → if ERRORs found → reference docs/remediation-playbook.md, help user fix, then re-run precheck
3. check_option_group → report if custom option group needs migration. ⚠️ MUST complete before step 5 — custom option groups require two-step B/G
4. prepare_param_group → confirm target parameter group is ready
5. create_blue_green (or in_place_upgrade) → confirm strategy with user before executing
   - If instance has custom option group → MUST use two-step B/G (no --target-version)
   - If instance is Multi-AZ DB Cluster → MUST use in_place_upgrade
6. monitor_blue_green → poll until AVAILABLE
   → ⚠️ IF create_blue_green returned upgrade_green_required=true:
     MUST run in_place_upgrade on green instance BEFORE proceeding to step 6b
     (green is still on 8.0 at this point — it needs version upgrade)
6b. validate_upgrade (on green) → verify green instance version and status
   → ⚠️ PAUSE HERE and ask user: "Green environment is ready. Do you want to run application validation (app_validate) before proceeding to switchover?"
   - If yes → run app_validate on green endpoint, report results
   - If no → proceed to step 7
7. pre_switchover_check → all checks must PASS before proceeding
   → DO NOT run this step if green version has not been upgraded yet
8. switchover → ⚠️ REQUIRES EXPLICIT USER CONFIRMATION (see Guardrails below)
9. validate_upgrade (connectivity check) → confirm endpoint reachable after switchover
10. cleanup_blue_green → ⚠️ REQUIRES EXPLICIT USER CONFIRMATION
```

After each step completes successfully, suggest the next step with a brief explanation of what it does. If a step fails, diagnose and propose remediation before moving forward.

> ⚠️ **CRITICAL**: Never call `create_blue_green` with `--target-version` if the instance has a custom option group. Always check option group status (step 3) BEFORE creating the B/G deployment. If custom option group exists, omit `--target-version` to create a same-version B/G, then upgrade the green instance separately.

> ⚠️ **GREEN INSTANCES**: If `discover_instances` returns an instance with `blue_green_role: "green"` and `upgrade_strategy: "in_place"`, it is already a Green environment in an existing B/G deployment. NEVER call `create_blue_green` on it. Use `upgrade_green_instance` (or `in_place_upgrade`) to upgrade it directly to the target version. **Always check the green instance's engine version before suggesting switchover — if it's still on 8.0, it needs upgrading first.**

> ⚠️ **CREDENTIALS**: Always ask the user for `secret_id` before calling any tool that requires database credentials (`run_precheck`, `batch_precheck`, `app_validate`). Do NOT guess or auto-discover secrets from Secrets Manager. If the user hasn't provided one, ask them explicitly.

## Guardrails for Destructive Operations

The following operations are **irreversible** — you MUST:
1. Clearly state the risk and impact before execution
2. Ask the user for explicit confirmation (e.g., "Type 'yes' to proceed")
3. Never auto-execute these in batch without per-instance confirmation

| Operation | Risk |
|-----------|------|
| `switchover` | One-way — no reverse switchover. Data written after switchover cannot be rolled back to blue. |
| `cleanup_blue_green --delete-source` | Permanently deletes the old blue instance. No recovery possible. |
| `cleanup_blue_green` (without --delete-source) | Only deletes B/G deployment metadata. Old blue instance is preserved. Safe. |
| `in_place_upgrade` | Causes downtime. Irreversible — rollback requires snapshot restore to a new instance. |
| `in_place_upgrade` (Multi-AZ DB Cluster) | All cluster members go offline simultaneously during upgrade. |

For `cleanup_blue_green` without `--delete-source`, the deployment metadata is deleted but the old instance is preserved — this is safe and does not require extra confirmation.

## Error Handling Guidance

When precheck reports ERROR findings:
1. Reference `docs/remediation-playbook.md` for specific fix instructions
2. Show the user the relevant SQL remediation for each ERROR
3. After user applies fixes, suggest re-running precheck to verify
4. Do NOT proceed to upgrade steps while ERRORs exist

When precheck reports WARNING findings:
- Inform the user but note these do not block upgrade
- Offer to explain the implications if asked

## Session Context Tracking

When working with multiple instances in a session:
- Maintain awareness of which instances have completed each step
- If the user says "next instance" or "continue", proceed with the next pending instance
- Summarize progress when asked (e.g., "3/10 instances upgraded, 1 failed precheck")

---

## Supported Upgrade Paths

- MySQL 8.0.28+ → 8.4.x (major version upgrade, single step)
- MySQL 5.7 → 8.4.x (multi-hop via Blue/Green: 5.7→8.0→8.4 in one deployment)
- Source must be 8.0.28 or later for full precheck coverage (5.7 prechecks are limited)
- Target: MySQL 8.4.9 (current RDS latest)

## Upgrade Strategies

### Blue/Green Deployment (Recommended for Production)
- Creates a staging (green) copy of your database
- Upgrades the green environment to 8.4
- Switchover swaps endpoints with minimal downtime (~30s)
- **Switchover is a one-way operation** — there is no reverse switchover
- Old blue instance retained with renamed identifier for investigation
- To revert: restore from pre-upgrade snapshot or use PITR (creates a new instance)
- Requires: instance must be eligible for B/G (no unsupported features)
- **Not supported for:** Multi-AZ DB Clusters, instances with cross-Region read replicas, cascading read replicas, CloudFormation-managed instances, or instances with custom option groups during major version upgrade (use two-step approach or in-place)
- See [Blue/Green Deployments limitations](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html#blue-green-deployments-limitations) for the full list

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

### Foreign Key Behavior Change
- `restrict_fk_on_non_standard_key` — New parameter in MySQL 8.4 (default ON)
- Blocks CREATE TABLE and ALTER TABLE from creating foreign keys on non-unique or partial keys
- Does NOT affect existing foreign keys or the upgrade itself — only new DDL after upgrade
- If your application creates or modifies foreign keys at runtime, set this parameter to OFF in your MySQL 8.4 parameter group, or adjust DDL statements accordingly

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
- **Custom with MARIADB_AUDIT_PLUGIN** → auto-creates MySQL 8.4 option group with same options. For B/G: uses two-step (create same-version B/G with option group, then upgrade green separately). For in-place: passes option group directly.
- **Custom with MEMCACHED** → MEMCACHED excluded (not supported in 8.4). If only option, skip (use default:mysql-8.4)
- **Empty custom group** → skip (use default:mysql-8.4, avoids B/G eligibility issues)

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
4. Use concurrency carefully: 5-10 for B/G (green builds independently, blue stays live), 3-5 for non-production in-place. For production in-place (e.g., Multi-AZ DB Clusters), use 1 (serial) or schedule during maintenance windows.
5. Monitor CloudWatch during upgrades
6. Keep blue environments for 24-48 hours after switchover
7. Run pre-switchover readiness check before switchover (`pre_switchover_check.sh`) to verify deployment status, replication health, and instance availability
