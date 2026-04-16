# MySQL 8.0 → 8.4 Upgrade Guide

## Supported Upgrade Paths

- MySQL 8.0.28+ → 8.4.x (major version upgrade)
- Source must be 8.0.28 or later for full precheck coverage
- Target: MySQL 8.4.8 (current RDS latest)

## Upgrade Strategies

### Blue/Green Deployment (Recommended for Production)
- Creates a staging (green) copy of your database
- Upgrades the green environment to 8.4
- Switchover swaps endpoints with minimal downtime (~30s)
- Blue environment retained for rollback
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
- `mysql_native_password` disabled by default in 8.4
- Set `loose_mysql_native_password=ON` in parameter group if apps still need it
- Recommend migrating to `caching_sha2_password`

### Removed Features
- `authentication_fido` plugin removed (use `authentication_webauthn`)
- `keyring_file/encrypted_file/oci` plugins removed (use component equivalents)
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
4. Check for prerequisite parameters (e.g., `innodb_trx_commit_allow_data_loss`)

If multiple instances share the same custom parameter group, migrate once and reuse.

## Precheck Tool

Run `mysql_precheck_run.sh` before every upgrade:
- Phase 1: 19 SQL-based checks (read-only, safe for production)
- Phase 2: CHECK TABLE FOR UPGRADE (acquires metadata locks, run during maintenance)
- Any ERROR findings must be fixed before upgrade
- WARNING findings should be reviewed but don't block upgrade

## Post-Upgrade Validation

After upgrade, verify:
1. Engine version is 8.4.x
2. Instance status is 'available'
3. MySQL connectivity works
4. Read Replicas are healthy
5. Parameter group is in-sync
6. Application queries work correctly

## Rollback

### Blue/Green
- If blue environment still exists: switch back via AWS Console or CLI
- If deleted: use Point-in-Time Recovery (PITR)

### In-Place
- No automatic rollback
- Use PITR to restore to pre-upgrade point
- Requires automated backups enabled with sufficient retention

## Batch Upgrade Best Practices

1. Start with non-production environments
2. Run precheck on all instances first (`--dry-run`)
3. Upgrade in waves: dev → staging → prod
4. Use concurrency carefully (3-5 for B/G, 1 for in-place)
5. Monitor CloudWatch during upgrades
6. Keep blue environments for 24-48 hours after switchover
