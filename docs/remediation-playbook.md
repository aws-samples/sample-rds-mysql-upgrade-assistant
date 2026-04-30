# Precheck Remediation Playbook

This playbook provides specific remediation steps for each precheck finding. After running `mysql_precheck_run.sh`, use this guide to fix issues before upgrading.

## ERROR-Level Findings (Must Fix Before Upgrade)

### Check #5: authMethodUsage — `authentication_fido`

**Finding:** Account uses removed plugin `authentication_fido`.

**Remediation:**
```sql
-- Identify affected accounts
SELECT User, Host, plugin FROM mysql.user WHERE plugin = 'authentication_fido';

-- Migrate each account to caching_sha2_password
ALTER USER 'username'@'host' IDENTIFIED WITH caching_sha2_password BY 'new_password';
```

### Check #6: pluginUsage — Removed plugins

**Finding:** Active plugins that are removed in 8.4: `keyring_file`, `keyring_encrypted_file`, `keyring_oci`.

**Remediation:** These are managed by RDS. If you see this finding, contact AWS Support — RDS should handle plugin migration during upgrade.

### Check #9: columnDefinition — FLOAT/DOUBLE with AUTO_INCREMENT

**Finding:** Column uses FLOAT or DOUBLE data type with AUTO_INCREMENT.

**Remediation:**
```sql
-- Identify affected columns
SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, COLUMN_TYPE
FROM information_schema.COLUMNS
WHERE COLUMN_TYPE IN ('float', 'double') AND EXTRA = 'auto_increment'
  AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');

-- Fix: change to INT or BIGINT
ALTER TABLE `schema`.`table` MODIFY COLUMN `col` BIGINT AUTO_INCREMENT;
```

### Check #12: partitionsWithPrefixKeys

**Finding:** Partitioned table uses prefix key columns.

**Remediation:**
```sql
-- Identify affected tables
-- Review partition definitions and consider:
-- 1. Remove prefix from the index
-- 2. Change partition method from KEY to RANGE/LIST
-- 3. Rebuild the table: ALTER TABLE t REMOVE PARTITIONING; then re-partition
```

### Check #14: memcachedPlugin

**Finding:** `daemon_memcached` plugin is active.

**Remediation:**
```sql
-- Uninstall the plugin before upgrade
UNINSTALL PLUGIN daemon_memcached;
```

### Check #15: sysSchemaObjects

**Finding:** User-created base tables found in `sys` schema.

**Remediation:**
```sql
-- Identify tables
SELECT TABLE_NAME FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'sys' AND TABLE_TYPE = 'BASE TABLE' AND TABLE_NAME != 'sys_config';

-- Move tables to a user schema
RENAME TABLE sys.my_table TO my_schema.my_table;
```

### Check #18: deprecatedTemporalDelimiter (source < 8.0.29)

**Finding:** Partition uses deprecated temporal delimiters.

**Remediation:**
```sql
-- Rebuild partitions with standard date format (YYYY-MM-DD)
ALTER TABLE t REORGANIZE PARTITION p0 INTO (
  PARTITION p0 VALUES LESS THAN ('2024-01-01')
);
```

---

## WARNING-Level Findings (Review Before Upgrade)

### Check #2: sysVarsNewDefaults

**Finding:** System variables with changed defaults in 8.4.

**Impact and Recommendations:**

| Variable | Old Default | New Default (8.4) | Action |
|----------|-------------|-------------------|--------|
| `innodb_adaptive_hash_index` | ON | OFF | Test workload performance. If hash index is critical, set explicitly in param group. |
| `innodb_change_buffering` | all | none | Generally safe. Change buffering was already deprecated. |
| `innodb_io_capacity` | 200 | 10000 | Review I/O patterns. Higher default benefits most workloads on modern storage. |
| `innodb_io_capacity_max` | 2000 | 2x io_capacity | Follows io_capacity. Usually no action needed. |
| `innodb_flush_method` | fsync | O_DIRECT | O_DIRECT is recommended for RDS. No action needed. |
| `innodb_buffer_pool_instances` | 8 | dynamic (vCPU/4) | Review if you've tuned this. Dynamic is usually better. |
| `innodb_log_buffer_size` | 16MB | 64MB | Higher default improves write performance. No action needed. |
| `innodb_redo_log_capacity` | 100MB | dynamic | Dynamic sizing is generally better. Review if you've tuned this. |

**Batch remediation:** If you want to preserve 8.0 behavior, set these explicitly in your MySQL 8.4 parameter group before upgrade:
```bash
# During parameter group migration, these values are automatically carried over
# if they were explicitly set in the source parameter group.
# Only variables using the OLD default will trigger this warning.
```

### Check #4: foreignKeyReferences

**Finding:** Foreign keys referencing non-unique or partial indexes.

**Remediation:**
```sql
-- Add a unique index on the referenced columns
ALTER TABLE parent_table ADD UNIQUE INDEX idx_name (referenced_col1, referenced_col2);

-- Or if using prefix keys, create a full-length index
ALTER TABLE parent_table ADD INDEX idx_name (referenced_col(full_length));
```

### Check #5: authMethodUsage — `mysql_native_password`

**Finding:** Accounts using deprecated `mysql_native_password` plugin.

**Impact:** RDS MySQL 8.4 still supports `mysql_native_password` (it's enabled by default), so this is not a blocker. However, plan to migrate long-term.

**Remediation (when ready):**
```sql
-- List affected accounts
SELECT User, Host FROM mysql.user WHERE plugin = 'mysql_native_password';

-- Migrate accounts (coordinate with application teams)
ALTER USER 'app_user'@'%' IDENTIFIED WITH caching_sha2_password BY 'password';

-- Verify application connectivity after each change
-- caching_sha2_password requires:
--   - MySQL client 8.0+ or
--   - MySQL Connector with SHA-256 support or
--   - SSL/TLS connection
```

### Check #10: sysVarsAllowedValues — `binlog_format`

**Finding:** `binlog_format` is set to STATEMENT or MIXED.

**Remediation:** MySQL 8.4 only supports ROW format. Change before upgrade:
```sql
-- Check current value
SHOW VARIABLES LIKE 'binlog_format';

-- Set in parameter group (not via SET GLOBAL — it won't persist)
-- In your MySQL 8.4 parameter group, ensure binlog_format = ROW
```

### Check #13: nonInclusiveLanguage

**Finding:** Stored procedures or system variables use deprecated terminology (MASTER/SLAVE).

**Remediation:**
```sql
-- Update stored procedures to use inclusive terms:
-- SHOW MASTER STATUS → SHOW BINARY LOG STATUS
-- SHOW SLAVE STATUS → SHOW REPLICA STATUS
-- CHANGE MASTER TO → CHANGE REPLICATION SOURCE TO
-- START SLAVE → START REPLICA
-- STOP SLAVE → STOP REPLICA

-- For system variables:
-- init_slave → init_replica
-- log_slave_updates → log_replica_updates
```

### Check #16/17: dollarSignName / reservedKeywords

**Finding:** Object names starting with `$` or conflicting with reserved keywords (FULL, INTERSECT).

**Remediation:**
```sql
-- Always use backtick quoting for these identifiers
SELECT * FROM `$my_table`;
SELECT * FROM `full`;

-- Or rename the objects
RENAME TABLE `$old_name` TO `new_name`;
```

---

## Scaling Remediation Across 100+ Instances

### Strategy 1: Categorize by Finding Type

After running prechecks on all instances, group findings:

```bash
# Run precheck on all instances and collect results
for instance in $(bash scripts/inventory/discover_instances.sh --json | jq -r '.[].instance_id'); do
  echo "=== $instance ==="
  bash scripts/precheck/mysql_precheck_run.sh -h <endpoint> -u admin --secret-id "prefix/$instance" --json 2>/dev/null
done > fleet_precheck_results.json
```

### Strategy 2: Fix Common Issues First

Most fleets share common findings:
1. **sysVarsNewDefaults** (Warning) — Usually no action needed, just awareness
2. **authMethodUsage** (Warning) — Plan migration but not blocking
3. **nonInclusiveLanguage** (Warning) — Update stored procedures

### Strategy 3: Prioritize by Severity

1. Fix all ERROR findings first (blockers)
2. Review HIGH-impact warnings (foreignKeyReferences, binlog_format)
3. Document accepted warnings (sysVarsNewDefaults)
