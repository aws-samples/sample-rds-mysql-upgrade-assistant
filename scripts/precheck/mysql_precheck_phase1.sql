-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
--
-- Licensed under the Apache License, Version 2.0 (the "License").
-- You may not use this file except in compliance with the License.
-- A copy of the License is located at
--
--     http://aws.amazon.com/apache2.0/
--
-- or in the "license" file accompanying this file.
-- This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
-- OR CONDITIONS OF ANY KIND, either express or implied. See the
-- License for the specific language governing permissions and
-- limitations under the License.

-- ============================================================
-- MySQL 8.0.28+ / Aurora MySQL v3 → 8.4 Upgrade Precheck — Phase 1
-- ============================================================
-- *** Aurora-enhanced — EXPERIMENTAL ***
-- This is the Aurora-enhanced Phase 1 SQL. It is a strict SUPERSET of the
-- RDS-only checks:
--
--   * On RDS for MySQL / community MySQL (@is_aurora = 0) it behaves
--     IDENTICALLY to the RDS-only script — every Aurora-specific block is
--     gated on the @is_aurora flag and contributes nothing (zero rows,
--     zero counts).
--   * On Aurora MySQL v3 (@is_aurora = 1) it additionally runs the
--     Aurora-only checks #20 – #23 and turns #7 (deprecatedDefaultAuth)
--     from a SKIP into a Warning, matching Aurora's upgrade-prechecks.log.
--
-- Design rule: DO NOT alter RDS behaviour. The original RDS code
-- paths are untouched; Aurora logic is purely additive and gated.
--
-- Description: Pure SQL script to detect compatibility issues
--              before upgrading from MySQL 8.0.28+ (RDS for MySQL) or
--              Aurora MySQL v3 to MySQL 8.4.
--              Based on MySQL Shell util.checkForServerUpgrade()
--              checks, the RDS PrePatchCompatibility.log, and the
--              Aurora upgrade-prechecks.log.
--
-- Scope:       Source 8.0.28 – 8.0.x (RDS) / Aurora MySQL v3 → Target 8.4.9
--
-- Usage:       See Readme.md for two-phase execution
--
-- Target:      MySQL 8.4.9 (default; override via
--              mysql-precheck-run.sh -t <version>)
--
-- Privileges:  Requires SELECT on information_schema,
--              performance_schema, and mysql databases.
--
-- Note:        This script is READ-ONLY. It executes only
--              SELECT and SET statements. No DDL or DML.
-- ============================================================

-- ------------------------------------------------------------
-- Section: Session sql_mode pin
-- ------------------------------------------------------------
-- Pin sql_mode to the MySQL 8.0/8.4 documented default so an inherited
-- ANSI_QUOTES or NO_BACKSLASH_ESCAPES can't change how this script's quoting and REGEXP patterns parse.
-- Ref: https://dev.mysql.com/doc/refman/8.4/en/sql-mode.html
SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

-- ------------------------------------------------------------
-- Section: Version Detection and Report Initialization
-- ------------------------------------------------------------

-- Detect source version
SET @source_version = @@version;
SET @target_version = '8.4.9';

-- Extract major.minor.patch from source version
SET @source_major = CAST(SUBSTRING_INDEX(@source_version, '.', 1) AS UNSIGNED);
SET @source_minor = CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(@source_version, '.', 2), '.', -1) AS UNSIGNED);
SET @source_patch_str = SUBSTRING_INDEX(@source_version, '.', -1);
-- Handle patch versions like '39-log' by extracting leading digits
SET @source_patch = CAST(
  CASE
    WHEN @source_patch_str REGEXP '^[0-9]+'
    THEN REGEXP_SUBSTR(@source_patch_str, '^[0-9]+')
    ELSE '0'
  END AS UNSIGNED
);

-- ------------------------------------------------------------
-- Phase 0: Platform detection (Aurora vs RDS for MySQL / community)
-- ------------------------------------------------------------
-- Aurora MySQL exposes the read-only system variable `aurora_version`
-- (e.g. '3.10.3'); RDS for MySQL and community MySQL do not have it.
--
-- IMPORTANT: a pure-SQL script cannot reference @@aurora_version directly
-- — on a non-Aurora server that raises "ERROR 1193 Unknown system
-- variable 'aurora_version'" and aborts the whole script. Instead we probe
-- the variable *by name string* via performance_schema.global_variables,
-- which simply returns 0 rows on non-Aurora and never errors. The
-- aurora_version value (when present) is also captured for the report
-- header. This was verified on RDS for MySQL 8.0.42 (0 rows) and Aurora
-- MySQL v3.10.3 (1 row, value '3.10.3').
SET @is_aurora = 0;
SET @aurora_version = NULL;

SELECT MAX(VARIABLE_VALUE)
INTO @aurora_version
FROM performance_schema.global_variables
WHERE VARIABLE_NAME = 'aurora_version';

SET @is_aurora = CASE WHEN @aurora_version IS NOT NULL THEN 1 ELSE 0 END;

-- Human-readable platform label for the report header.
SET @platform_label = CASE
  WHEN @is_aurora = 1 THEN CONCAT('Aurora MySQL v', @aurora_version)
  ELSE 'RDS for MySQL / community MySQL'
END;

-- Initialize severity counters
SET @error_count = 0;
SET @warning_count = 0;
SET @notice_count = 0;

-- Output report header
SELECT CONCAT(
  '============================================================\n',
  'RDS for MySQL 8.0 to 8.4 Upgrade Precheck Report\n',
  '============================================================\n',
  'Source version: ', @source_version, '\n',
  'Platform:       ', @platform_label, '\n',
  'Target version: ', @target_version, '\n',
  'Check date:     ', NOW(), '\n',
  '============================================================') AS '';

-- Validate source version is 8.0.28+
SELECT
  CASE
    WHEN @source_major != 8 OR @source_minor != 0
    THEN CONCAT('ERROR: This script is designed for MySQL 8.0.x only. ',
                'Detected version: ', @source_version)
    WHEN @source_patch < 28
    THEN CONCAT('WARNING: This script is optimized for MySQL 8.0.28+. ',
                'Detected version: ', @source_version, '. ',
                'Earlier versions may need additional checks not covered here.')
    ELSE CONCAT('OK: Source version ', @source_version, ' is MySQL 8.0.28+')
  END AS 'Version Check';

SET @error_count = @error_count +
  CASE WHEN @source_major != 8 OR @source_minor != 0 THEN 1 ELSE 0 END;

-- Validate target version is in the supported 8.4.0 - 8.4.9 range.
-- The check rules in this script are calibrated for the 8.4.x series only;
-- a target outside that range (e.g. 8.5.0, 9.0.0, or a typo) would silently
-- misreport. Pure SQL has no abort primitive, so we surface a clear ERROR
-- row in the header and increment @error_count. The runner has the same
-- check earlier in its argument parser; this guard catches the manual
-- two-phase workflow when a user edits the SET @target_version line above
-- by hand.
SELECT
  CASE
    WHEN @target_version REGEXP '^8\\.4\\.[0-9]$'
    THEN CONCAT('OK: Target version ', @target_version, ' is in the supported 8.4.0 - 8.4.9 range')
    ELSE CONCAT('ERROR: Unsupported target version ''', @target_version,
                '''. This tool supports MySQL 8.4.0 through 8.4.9 only. ',
                'Edit @target_version above (or pass -t <version> to mysql-precheck-run.sh).')
  END AS 'Target Version Check';

SET @error_count = @error_count +
  CASE WHEN @target_version REGEXP '^8\\.4\\.[0-9]$' THEN 0 ELSE 1 END;

-- ============================================================
-- Section: Privilege Pre-Checks
-- ============================================================
-- Checks are split into independent grants so we only scan each privilege
-- source once. Two composite flags (@has_perfschema, @has_mysql_db) are
-- derived from them for the rest of the script to consume unchanged.
--
--   @has_global_select       SELECT on *.* (global)
--   @has_schema_select_perf  SELECT on performance_schema.*
--   @has_schema_select_mysql SELECT on mysql.*
--
-- A user with global SELECT satisfies both schema dependencies, so the
-- composite flags evaluate to 1 as soon as either source is present.
-- ============================================================

SET @has_global_select = 0;
SET @has_schema_select_perf = 0;
SET @has_schema_select_mysql = 0;

-- Single pass: read both privilege views once via UNION ALL and aggregate
-- the three SELECT-grant flags with conditional SUM. Replaces three
-- separate SET = (SELECT ...) statements that each scanned a privilege
-- view independently.
SELECT
  MAX(CASE WHEN p.SOURCE = 'USER'   AND p.HAS_SELECT THEN 1 ELSE 0 END),
  MAX(CASE WHEN p.SOURCE = 'SCHEMA' AND p.TABLE_SCHEMA = 'performance_schema' AND p.HAS_SELECT THEN 1 ELSE 0 END),
  MAX(CASE WHEN p.SOURCE = 'SCHEMA' AND p.TABLE_SCHEMA = 'mysql'              AND p.HAS_SELECT THEN 1 ELSE 0 END)
INTO @has_global_select, @has_schema_select_perf, @has_schema_select_mysql
FROM (
  SELECT 'USER' AS SOURCE, NULL AS TABLE_SCHEMA, GRANTEE,
         (PRIVILEGE_TYPE = 'SELECT') AS HAS_SELECT
  FROM information_schema.USER_PRIVILEGES
  UNION ALL
  SELECT 'SCHEMA' AS SOURCE, TABLE_SCHEMA, GRANTEE,
         (PRIVILEGE_TYPE = 'SELECT') AS HAS_SELECT
  FROM information_schema.SCHEMA_PRIVILEGES
) p
WHERE p.GRANTEE = CONCAT('''', REPLACE(CURRENT_USER(), '@', '''@'''), '''');

-- Compose downstream flags. NULL guards: if the user has no rows at all
-- in either privilege view, MAX returns NULL — coalesce to 0 so the
-- composite gates evaluate cleanly.
SET @has_global_select       = COALESCE(@has_global_select, 0);
SET @has_schema_select_perf  = COALESCE(@has_schema_select_perf, 0);
SET @has_schema_select_mysql = COALESCE(@has_schema_select_mysql, 0);

-- Composite flags used by downstream checks (unchanged semantics).
SET @has_perfschema = CASE WHEN @has_global_select = 1
                             OR @has_schema_select_perf = 1
                           THEN 1 ELSE 0 END;
SET @has_mysql_db   = CASE WHEN @has_global_select = 1
                             OR @has_schema_select_mysql = 1
                           THEN 1 ELSE 0 END;

SELECT 'privilegeCheck' AS check_name,
       'Notice' AS severity,
       'performance_schema' AS object,
       CONCAT('Current user ', CURRENT_USER(),
              ' may not have SELECT access on performance_schema ',
              '(no global SELECT and no schema-level SELECT). ',
              'Check #2 (system variable detection) may be incomplete.') AS description
FROM DUAL
WHERE @has_perfschema = 0;

SET @notice_count = @notice_count +
  CASE WHEN @has_perfschema = 0 THEN 1 ELSE 0 END;

SELECT 'privilegeCheck' AS check_name,
       'Notice' AS severity,
       'mysql' AS object,
       CONCAT('Current user ', CURRENT_USER(),
              ' may not have SELECT access on mysql database ',
              '(no global SELECT and no schema-level SELECT). ',
              'Checks #5, #11 (user account checks) may fail.') AS description
FROM DUAL
WHERE @has_mysql_db = 0;

SET @notice_count = @notice_count +
  CASE WHEN @has_mysql_db = 0 THEN 1 ELSE 0 END;


-- ============================================================
-- Check #1: removedSysVars [SKIP]
-- Origin: MySQL Shell Group 4 (sysVars - always active)
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #1: Removed system variables [SKIP]', '\n------------------------------------------------------------') AS '';

-- ============================================================
-- Check #2: sysVarsNewDefaults
-- Severity: Warning
-- Origin: MySQL Shell Group 4 (sysVars - always active)
-- Description: System variables whose DEFAULT value changes in MySQL 8.4.
--
-- Matching logic: flag every variable on the curated list that exists on the
-- running server AND whose variable_source indicates the operator has NOT
-- explicitly set it (sources NULL, COMPILED, or GLOBAL). Explicit sources
-- (EXPLICIT, PERSISTED, PERSISTED_GLOBAL, COMMAND_LINE, DYNAMIC) are
-- suppressed because the operator has already taken a stance. Variables not
-- present on this server (e.g., group_replication_* when the plugin is not
-- loaded) are silently skipped.
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #2: System variables with new default values', '\n------------------------------------------------------------') AS '';

SET @sysvar_new_defaults_count := 0;

-- Curated list of variables whose default value changes in MySQL 8.4. The
-- list has 14 entries; innodb_redo_log_capacity only fires on early
-- 8.0.28 – 8.0.32 instances (default has converged at 8.0.33+) and is
-- gated below with a @source_patch check. All other 13 entries appear
-- unconditionally — including variables that are not currently loaded on
-- the server (e.g., group_replication_exit_state_action when group
-- replication is not enabled), so the operator gets a complete picture
-- of what will change at upgrade time.
SELECT 'sysVarsNewDefaults' AS check_name,
       'Warning' AS severity,
       nd.variable_name AS object,
       CONCAT('Default value will change in MySQL 8.4 to ', nd.new_default_84,
              '. Current value on this instance: ''',
              COALESCE(gv.VARIABLE_VALUE, '<variable not present on this server>'),
              ''' (source=', COALESCE(vi.VARIABLE_SOURCE, 'NOT_APPLICABLE'),
              '). Not explicitly set, so the 8.4 upgrade will apply the new',
              ' default. Set it explicitly in your configuration if you',
              ' rely on the current value.') AS description
FROM (
  SELECT 'binlog_transaction_dependency_tracking' AS variable_name, 'WRITESET'                             AS new_default_84, 0  AS min_patch UNION ALL
  SELECT 'group_replication_consistency',                            'BEFORE_ON_PRIMARY_FAILOVER',                             0                UNION ALL
  SELECT 'group_replication_exit_state_action',                      'OFFLINE_MODE',                                           0                UNION ALL
  SELECT 'innodb_adaptive_hash_index',                               'OFF',                                                    0                UNION ALL
  SELECT 'innodb_buffer_pool_instances',                             'MAX(1, #vcpu/4)',                                        0                UNION ALL
  SELECT 'innodb_change_buffering',                                  'none',                                                   0                UNION ALL
  SELECT 'innodb_io_capacity',                                       '10000',                                                  0                UNION ALL
  SELECT 'innodb_io_capacity_max',                                   '2 x innodb_io_capacity',                                 0                UNION ALL
  SELECT 'innodb_log_writer_threads',                                'OFF (if #vcpu <= 32)',                                    0                UNION ALL
  SELECT 'innodb_numa_interleave',                                   'ON',                                                     0                UNION ALL
  SELECT 'innodb_page_cleaners',                                     'innodb_buffer_pool_instances',                           0                UNION ALL
  SELECT 'innodb_parallel_read_threads',                             'MAX(#vcpu/8, 4)',                                        0                UNION ALL
  SELECT 'innodb_read_io_threads',                                   'MAX(#vcpu/2, 4)',                                        0                UNION ALL
  -- 14th item: only fires on 8.0.28 – 8.0.32. The default has already
  -- converged to the 8.4 value starting at 8.0.33, so flagging it on
  -- newer minors would just produce noise.
  SELECT 'innodb_redo_log_capacity',                                 'MIN(#vcpu/2, 16) GB',                                    33
) nd
LEFT JOIN performance_schema.global_variables gv
  ON gv.VARIABLE_NAME = nd.variable_name
LEFT JOIN performance_schema.variables_info vi
  ON vi.VARIABLE_NAME = nd.variable_name
WHERE (nd.min_patch = 0 OR @source_patch < nd.min_patch)
  -- Skip rows that are explicitly set by the operator. A variable absent from
  -- the server (gv.VARIABLE_VALUE IS NULL) is still surfaced — the operator
  -- should know the default will change after the upgrade even if the
  -- variable is not currently present on this build.
  AND (gv.VARIABLE_VALUE IS NULL
       OR COALESCE(vi.VARIABLE_SOURCE, 'COMPILED') NOT IN
          ('EXPLICIT', 'PERSISTED', 'PERSISTED_GLOBAL', 'COMMAND_LINE', 'DYNAMIC'))
  -- Inline counter replaces the duplicated COUNT subquery.
  AND (@sysvar_new_defaults_count := @sysvar_new_defaults_count + 1) IS NOT NULL;

SELECT 'sysVarsNewDefaults' AS check_name,
       CASE WHEN @has_perfschema = 0 THEN 'PASS (unverified)' ELSE 'PASS' END AS severity,
       '' AS object,
       CASE WHEN @has_perfschema = 0
         THEN 'No issues detected, but result may be incomplete — current user lacks SELECT on performance_schema'
         ELSE 'All variables on the 8.4 new-default list are explicitly set or absent from this server'
       END AS description
FROM DUAL
WHERE @sysvar_new_defaults_count = 0;

SET @warning_count = @warning_count + @sysvar_new_defaults_count;

-- ============================================================
-- Check #3: checkTableForUpgrade
-- Severity: Error/Warning
-- Origin: MySQL Shell Group 4 (always active)
-- Description: Generates CHECK TABLE statements for Phase 2.
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n',
'Check #3: Issues reported by CHECK TABLE FOR UPGRADE command\n',
'------------------------------------------------------------\n',
'Tables/views to check (auto-executed by mysql-precheck-run.sh):\n',
'------------------------------------------------------------') AS '';

-- Replace every literal backtick inside an identifier with two backticks,
-- which is MySQL's standard way to embed a backtick inside a backtick-
-- quoted identifier (e.g. a table called `a`b` is written `a``b`). Without
-- this escape, schema/table names containing a backtick produce syntactically
-- invalid CHECK TABLE statements in Phase 2.
SELECT CONCAT(
         '##PHASE2## CHECK TABLE `',
         REPLACE(TABLE_SCHEMA, '`', '``'),
         '`.`',
         REPLACE(TABLE_NAME,   '`', '``'),
         '` FOR UPGRADE;'
       ) AS `-- phase2_check_table_statements`
FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY TABLE_SCHEMA, TABLE_TYPE DESC, TABLE_NAME;


-- ============================================================
-- Check #4: foreignKeyReferences
-- Severity: Warning
-- Origin: MySQL Shell Group 2 (target >= 8.4.0)
-- Description: Foreign keys not referencing a full unique index.
--
-- Cross-schema fix (per MySQL Bug#120043 / mysql-shell PR #27):
--   The 4a JOIN condition "rc.constraint_schema = kc.REFERENCED_TABLE_SCHEMA"
--   wrongly assumed the constraint and the referenced table live in the same
--   schema, which caused cross-schema foreign keys to be silently filtered
--   out. We follow Oracle's upstream fix and join on
--   rc.UNIQUE_CONSTRAINT_SCHEMA instead — that is the column that actually
--   identifies the referenced table's schema in REFERENTIAL_CONSTRAINTS.
--   We also expose the referenced schema in the output so operators can see
--   exactly which table is being referenced (format schema.table).
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #4: Checks for foreign keys not referencing a full unique index', '\n------------------------------------------------------------') AS '';

SET @fk_ref_count := 0;

-- 4a. Foreign keys referencing non-unique indexes.
-- Wrapped in an outer SELECT so the user-variable counter can run after the
-- GROUP BY / HAVING, avoiding the duplicate COUNT subquery.
SELECT result.check_name, result.severity, result.object, result.description
FROM (
  SELECT 'foreignKeyReferences' AS check_name,
         'Warning' AS severity,
         CONCAT(fk.constraint_schema, '.', fk.table_name, '.', fk.constraint_name) AS object,
         CONCAT('Foreign key ', fk.parent_fk_def, ' references non-unique index on ', fk.target_table) AS description
  FROM (
    SELECT
      rc.constraint_schema,
      rc.constraint_name,
      rc.table_name,
      rc.REFERENCED_TABLE_NAME,
      CONCAT(kc.REFERENCED_TABLE_SCHEMA, '.', kc.REFERENCED_TABLE_NAME) AS target_table,
      CONCAT(rc.table_name, '(', GROUP_CONCAT(kc.COLUMN_NAME ORDER BY kc.ORDINAL_POSITION), ')') AS parent_fk_def,
      CONCAT(kc.REFERENCED_TABLE_SCHEMA, '.', kc.REFERENCED_TABLE_NAME, '(',
             GROUP_CONCAT(kc.REFERENCED_COLUMN_NAME ORDER BY kc.POSITION_IN_UNIQUE_CONSTRAINT), ')') AS target_fk_def
    FROM information_schema.REFERENTIAL_CONSTRAINTS rc
    JOIN information_schema.KEY_COLUMN_USAGE kc
      ON rc.constraint_schema = kc.constraint_schema
     AND rc.constraint_name = kc.constraint_name
     -- Use UNIQUE_CONSTRAINT_SCHEMA (schema of the referenced table) rather
     -- than constraint_schema; otherwise cross-schema FKs are dropped.
     -- Reported upstream as MySQL Bug#120043; see mysql-shell PR #27.
     AND rc.UNIQUE_CONSTRAINT_SCHEMA = kc.REFERENCED_TABLE_SCHEMA
     AND rc.REFERENCED_TABLE_NAME = kc.REFERENCED_TABLE_NAME
     AND kc.REFERENCED_TABLE_NAME IS NOT NULL
     AND kc.REFERENCED_COLUMN_NAME IS NOT NULL
    WHERE rc.constraint_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    GROUP BY rc.constraint_schema, rc.constraint_name, rc.table_name,
             rc.REFERENCED_TABLE_NAME, kc.REFERENCED_TABLE_SCHEMA
  ) fk
  JOIN (
    SELECT
      CONCAT(TABLE_SCHEMA, '.', TABLE_NAME, '(',
             GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX), ')') AS fk_def,
      SUM(NON_UNIQUE) AS non_unique_count
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
      AND SUB_PART IS NULL
    GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
  ) idx ON fk.target_fk_def = idx.fk_def
  GROUP BY fk.constraint_schema, fk.constraint_name, fk.parent_fk_def,
           fk.target_table, fk.table_name
  HAVING SUM(idx.non_unique_count = 0) = 0
) result
WHERE (@fk_ref_count := @fk_ref_count + 1) IS NOT NULL;

-- 4b. Foreign keys referencing partial (prefix) keys.
-- Same wrap-and-count pattern as 4a.
SELECT result.check_name, result.severity, result.object, result.description
FROM (
  SELECT 'foreignKeyReferences' AS check_name,
         'Warning' AS severity,
         CONCAT(fk.constraint_schema, '.', fk.table_name, '.', fk.constraint_name) AS object,
         CONCAT('Foreign key ', fk.fk_definition, ' references partial (prefix) key on ', fk.target_table) AS description
  FROM (
    SELECT
      rc.constraint_schema,
      rc.constraint_name,
      CONCAT(kc.referenced_table_schema, '.', kc.referenced_table_name) AS target_table,
      CONCAT(kc.table_schema, '.', rc.table_name, '(',
             GROUP_CONCAT(kc.column_name ORDER BY kc.ORDINAL_POSITION), ')') AS fk_definition,
      CONCAT(kc.referenced_table_schema, '.', kc.referenced_table_name, '(',
             GROUP_CONCAT(kc.referenced_column_name ORDER BY kc.ORDINAL_POSITION), ')') AS col_list,
      rc.table_name
    FROM information_schema.REFERENTIAL_CONSTRAINTS rc
    JOIN information_schema.KEY_COLUMN_USAGE kc
      ON rc.constraint_schema = kc.constraint_schema
     AND rc.constraint_name = kc.constraint_name
     AND rc.table_name = kc.table_name
     AND rc.referenced_table_name = kc.referenced_table_name
    WHERE rc.constraint_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    GROUP BY rc.constraint_name, rc.constraint_schema,
             kc.table_schema, kc.table_name,
             kc.referenced_table_schema, kc.referenced_table_name
  ) fk
  WHERE fk.col_list NOT IN (
    SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME, '(',
                  GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX), ')') AS col_list
    FROM information_schema.STATISTICS
    WHERE SUB_PART IS NULL
      AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
  )
) result
WHERE (@fk_ref_count := @fk_ref_count + 1) IS NOT NULL;

SELECT 'foreignKeyReferences' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'No foreign keys referencing non-unique or partial indexes detected' AS description
FROM DUAL
WHERE @fk_ref_count = 0;

SET @warning_count = @warning_count + @fk_ref_count;


-- ============================================================
-- Check #5: authMethodUsage
-- Severity: Error/Warning
-- Origin: MySQL Shell Group 4 (always active)
-- Description: Deprecated/invalid user auth methods.
--
-- Covers both the primary authentication plugin (mysql.user.plugin) and the
-- Multi-Factor Authentication (MFA) factor plugins stored in
-- mysql.user.user_attributes JSON
-- ($.multi_factor_authentication[*].plugin). This matches MySQL Shell's
-- behaviour (verified from the server audit log of mysqlsh 9.7
-- util.checkForServerUpgrade against 8.0.42).
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #5: Check for deprecated or invalid user authentication methods', '\n------------------------------------------------------------') AS '';

SET @auth_method_count = 0;

-- 5a. Primary authentication plugin (direct column)
SELECT 'authMethodUsage' AS check_name,
       CASE u.plugin
         WHEN 'mysql_native_password' THEN 'Warning'
         WHEN 'sha256_password' THEN 'Warning'
         WHEN 'authentication_fido' THEN 'Error'
       END AS severity,
       CONCAT('''', u.User, '''@''', u.Host, '''') AS object,
       CASE u.plugin
         WHEN 'mysql_native_password' THEN
           CONCAT('User is using the ''mysql_native_password'' authentication method which is deprecated as of MySQL 8.0.34 and will be removed in a future release. ',
                  'Consider switching to caching_sha2_password. ',
                  'The ''mysql_native_password'' authentication type is disabled by default in MySQL 8.4, but can still be enabled by setting loose_mysql_native_password=ON.')
         WHEN 'sha256_password' THEN
           CONCAT('Account uses deprecated authentication plugin: ', u.plugin,
                  '. Consider migrating to caching_sha2_password.')
         WHEN 'authentication_fido' THEN
           CONCAT('Account uses removed authentication plugin: ', u.plugin,
                  '. Consider migrating to authentication_webauthn.')
       END AS description
FROM mysql.user u
WHERE u.plugin IN ('mysql_native_password', 'sha256_password', 'authentication_fido');

-- 5b. Multi-Factor Authentication (MFA) factor plugins
-- user_attributes is a JSON column present on 8.0.27+. JSON_SEARCH returns
-- non-NULL when any entry under $.multi_factor_authentication[*].plugin
-- equals the searched string. We surface a single row per account per
-- deprecated plugin hit in any MFA slot (primary accounts already covered
-- by 5a are still flagged separately here when MFA uses a different plugin).
SELECT 'authMethodUsage' AS check_name,
       CASE mfa.plugin
         WHEN 'authentication_fido' THEN 'Error'
         ELSE 'Warning'
       END AS severity,
       CONCAT('''', u.User, '''@''', u.Host, ''' [MFA:', mfa.plugin, ']') AS object,
       CONCAT('Account has an MFA factor using deprecated/removed authentication plugin: ',
              mfa.plugin,
              '. Replace the MFA factor before upgrading to MySQL 8.4.') AS description
FROM mysql.user u
JOIN (
  SELECT 'authentication_fido' AS plugin
  UNION ALL SELECT 'mysql_native_password'
  UNION ALL SELECT 'sha256_password'
) mfa ON JSON_SEARCH(u.user_attributes, 'one', mfa.plugin, NULL, '$.multi_factor_authentication[*].plugin') IS NOT NULL;

-- Severity aggregation
-- - Errors: primary plugin = authentication_fido, OR any MFA factor = authentication_fido
-- - Warnings: primary plugin in (mysql_native_password, sha256_password), OR
--   any MFA factor in those same two plugins
SET @auth_method_errors = (
  SELECT COUNT(*)
  FROM mysql.user u
  WHERE u.plugin = 'authentication_fido'
     OR JSON_SEARCH(u.user_attributes, 'one', 'authentication_fido', NULL,
                    '$.multi_factor_authentication[*].plugin') IS NOT NULL
);

SET @auth_method_warnings = (
  SELECT COUNT(*)
  FROM mysql.user u
  WHERE u.plugin IN ('mysql_native_password', 'sha256_password')
     OR JSON_SEARCH(u.user_attributes, 'one', 'mysql_native_password', NULL,
                    '$.multi_factor_authentication[*].plugin') IS NOT NULL
     OR JSON_SEARCH(u.user_attributes, 'one', 'sha256_password', NULL,
                    '$.multi_factor_authentication[*].plugin') IS NOT NULL
);

SET @auth_method_count = @auth_method_errors + @auth_method_warnings;

SELECT 'authMethodUsage' AS check_name,
       CASE WHEN @has_mysql_db = 0 THEN 'PASS (unverified)' ELSE 'PASS' END AS severity,
       '' AS object,
       CASE WHEN @has_mysql_db = 0
         THEN 'No issues detected, but result may be incomplete — current user lacks SELECT on mysql database'
         ELSE 'No accounts using deprecated or removed authentication plugins detected (primary or MFA)'
       END AS description
FROM DUAL
WHERE @auth_method_count = 0;

SET @error_count = @error_count + @auth_method_errors;
SET @warning_count = @warning_count + @auth_method_warnings;

-- ============================================================
-- Check #6: pluginUsage
-- Severity: Error/Warning (depends on feature lifecycle vs target version)
-- Origin: MySQL Shell Group 4 (always active)
-- Description: Deprecated/removed plugin usage
--   authentication_fido:       start=8.0.27, deprecated=8.2.0, removed=8.4.0 → Error (target 8.4.9 >= removed)
--   keyring_file:              deprecated=8.0.34, removed=8.4.0              → Error
--   keyring_encrypted_file:    deprecated=8.0.34, removed=8.4.0              → Error
--   keyring_oci:               deprecated=8.0.31, removed=8.4.0              → Error
--   rpl_semi_sync_master:      deprecated=8.0.26, removed=9.5.0             → Warning (target 8.4.9 < removed)
--   rpl_semi_sync_slave:       deprecated=8.0.26, removed=9.5.0             → Warning (target 8.4.9 < removed)
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #6: Check for deprecated or removed plugin usage', '\n------------------------------------------------------------') AS '';

SET @plugin_usage_errors := 0;
SET @plugin_usage_warnings := 0;

SELECT 'pluginUsage' AS check_name,
       CASE p.PLUGIN_NAME
         WHEN 'authentication_fido'      THEN 'Error'
         WHEN 'keyring_file'             THEN 'Error'
         WHEN 'keyring_encrypted_file'   THEN 'Error'
         WHEN 'keyring_oci'              THEN 'Error'
         WHEN 'rpl_semi_sync_master'     THEN 'Warning'
         WHEN 'rpl_semi_sync_slave'      THEN 'Warning'
       END AS severity,
       p.PLUGIN_NAME AS object,
       CONCAT('Plugin ''', p.PLUGIN_NAME, ''' is ',
              CASE p.PLUGIN_NAME
                WHEN 'authentication_fido'    THEN 'removed in MySQL 8.4. Consider using ''authentication_webauthn'' plugin instead.'
                WHEN 'keyring_file'           THEN 'removed in MySQL 8.4. Consider using the ''component_keyring_file'' component instead.'
                WHEN 'keyring_encrypted_file' THEN 'removed in MySQL 8.4. Consider using the ''component_encrypted_keyring_file'' component instead.'
                WHEN 'keyring_oci'            THEN 'removed in MySQL 8.4. Consider using the ''component_keyring_oci'' component instead.'
                WHEN 'rpl_semi_sync_master'   THEN 'deprecated. Consider using ''rpl_semi_sync_source'' plugin instead.'
                WHEN 'rpl_semi_sync_slave'    THEN 'deprecated. Consider using ''rpl_semi_sync_replica'' plugin instead.'
              END) AS description
FROM information_schema.PLUGINS p
WHERE p.PLUGIN_STATUS = 'ACTIVE'
  AND p.PLUGIN_NAME IN (
    'authentication_fido',
    'keyring_file',
    'keyring_encrypted_file',
    'keyring_oci',
    'rpl_semi_sync_master',
    'rpl_semi_sync_slave'
  )
  -- Accumulate per-severity counts inline. The expression is always true.
  AND (@plugin_usage_errors := @plugin_usage_errors
        + (p.PLUGIN_NAME IN ('authentication_fido', 'keyring_file',
                             'keyring_encrypted_file', 'keyring_oci'))) IS NOT NULL
  AND (@plugin_usage_warnings := @plugin_usage_warnings
        + (p.PLUGIN_NAME IN ('rpl_semi_sync_master', 'rpl_semi_sync_slave'))) IS NOT NULL;

SET @plugin_usage_count := @plugin_usage_errors + @plugin_usage_warnings;

SELECT 'pluginUsage' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'No deprecated or removed active plugins detected' AS description
FROM DUAL
WHERE @plugin_usage_count = 0;

SET @error_count = @error_count + @plugin_usage_errors;
SET @warning_count = @warning_count + @plugin_usage_warnings;

-- ============================================================
-- Check #7: deprecatedDefaultAuth
-- Origin: MySQL Shell Group 5 (8.1.0 > any 8.0.x)
--
-- v1/RDS behaviour: SKIP. RDS for MySQL's PrePatchCompatibility.log does
-- not report this — RDS manages default_authentication_plugin via the
-- parameter group during the upgrade.
--
-- Aurora behaviour: Aurora's upgrade-prechecks.log DOES report this as a
-- *Warning* (verified across 17 Aurora v3 clusters: every one warns that
-- default_authentication_plugin = mysql_native_password is deprecated). So
-- on Aurora we surface a Warning; on RDS we keep the SKIP banner unchanged.
-- The level is Warning (not Error) to match Aurora's own precheck verdict.
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n',
  CASE WHEN @is_aurora = 1
    THEN 'Check #7: Deprecated default authentication methods in system variables'
    ELSE 'Check #7: Deprecated default authentication methods in system variables [SKIP]'
  END,
  '\n------------------------------------------------------------') AS '';

-- Aurora-only: warn when default_authentication_plugin is still
-- mysql_native_password. Probed by name string (the variable exists on both
-- platforms, but we only evaluate it on Aurora to preserve RDS SKIP). Gated
-- on @is_aurora so this block produces zero rows / zero counts on RDS.
SET @deprecated_default_auth_count := 0;

SELECT 'deprecatedDefaultAuth' AS check_name,
       'Warning' AS severity,
       gv.VARIABLE_NAME AS object,
       CONCAT('System variable ', gv.VARIABLE_NAME, ' = ''', gv.VARIABLE_VALUE,
              '''. The mysql_native_password authentication method is deprecated ',
              'and should be migrated to caching_sha2_password before/at the 8.4 upgrade. ',
              'On Aurora this is handled by the managed upgrade, but it is reported as a ',
              'Warning to match Aurora upgrade-prechecks.log.') AS description
FROM performance_schema.global_variables gv
WHERE @is_aurora = 1
  AND gv.VARIABLE_NAME = 'default_authentication_plugin'
  AND gv.VARIABLE_VALUE = 'mysql_native_password'
  AND (@deprecated_default_auth_count := @deprecated_default_auth_count + 1) IS NOT NULL;

SELECT 'deprecatedDefaultAuth' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'default_authentication_plugin is not mysql_native_password' AS description
FROM DUAL
WHERE @is_aurora = 1
  AND @deprecated_default_auth_count = 0;

SET @warning_count = @warning_count + @deprecated_default_auth_count;

-- ============================================================
-- Check #8: deprecatedRouterAuthMethod [SKIP]
-- Origin: MySQL Shell Group 5 (8.1.0 > any 8.0.x)
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #8: Deprecated Router authentication methods in use by MySQL Router internal accounts [SKIP]', '\n------------------------------------------------------------') AS '';


-- ============================================================
-- Check #9: columnDefinition
-- Severity: Error
-- Origin: MySQL Shell Group 3 (trigger 8.4.0, always for 8.0→8.4)
-- Description: FLOAT/DOUBLE with AUTO_INCREMENT
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #9: Checks for errors in column definitions', '\n------------------------------------------------------------') AS '';

SET @col_def_count := 0;

SELECT 'columnDefinition' AS check_name,
       'Error' AS severity,
       CONCAT(c.TABLE_SCHEMA, '.', c.TABLE_NAME, '.', c.COLUMN_NAME) AS object,
       CONCAT(UPPER(c.COLUMN_TYPE), ' column with AUTO_INCREMENT') AS description
FROM information_schema.COLUMNS c
WHERE c.DATA_TYPE IN ('float', 'double')
  AND c.EXTRA = 'auto_increment'
  AND c.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  -- Inline counter replaces the duplicated COUNT subquery.
  AND (@col_def_count := @col_def_count + 1) IS NOT NULL;

SELECT 'columnDefinition' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'No FLOAT/DOUBLE columns with AUTO_INCREMENT detected' AS description
FROM DUAL
WHERE @col_def_count = 0;

SET @error_count = @error_count + @col_def_count;

-- ============================================================
-- Check #10: sysVarsAllowedValues [SKIP]
-- Origin: MySQL Shell Group 4 (sysVars - always active)
-- Rationale: This tool targets a managed-service deployment where the
--   parameter-group surface enforces allowed values for variables such as
--   binlog_format, ssl_cipher, innodb_flush_method, and tls_ciphersuites
--   — out-of-allow-list values cannot be persisted, so re-checking them
--   here would be noise. The original active query is preserved below as
--   a comment for reference if you adapt this script to a self-managed
--   environment.
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #10: Check for allowed values in system variables [SKIP]', '\n------------------------------------------------------------') AS '';

-- ------------------------------------------------------------
-- Original active implementation (disabled — kept for reference)
-- ------------------------------------------------------------
-- Description: System variables with values outside the allowed set in 8.4
--   binlog_format:       only ROW is supported in 8.4 (deprecated)
--   ssl_cipher:          8.4 restricts to a specific set of strong ciphers
--   innodb_flush_method: 8.4 (unix) allows fsync,O_DSYNC,littlesync,nosync,O_DIRECT,O_DIRECT_NO_FSYNC
--   tls_ciphersuites:    8.4 restricts to TLS_AES_128_GCM_SHA256,TLS_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256,TLS_AES_128_CCM_SHA256
--
-- SET @sysvar_allowed_count = 0;
--
-- -- 10a. binlog_format: only ROW is valid in 8.4
-- SELECT 'sysVarsAllowedValues' AS check_name,
--        'Warning' AS severity,
--        gv.VARIABLE_NAME AS object,
--        CONCAT('System variable ', gv.VARIABLE_NAME, ' has value ''', gv.VARIABLE_VALUE,
--               ''' which is no longer valid in MySQL 8.4. ',
--               'Only ROW format is supported in 8.4. Variable is deprecated.') AS description
-- FROM performance_schema.global_variables gv
-- WHERE gv.VARIABLE_NAME = 'binlog_format' AND gv.VARIABLE_VALUE IN ('STATEMENT', 'MIXED');
--
-- SET @sysvar_allowed_count = @sysvar_allowed_count + (
--   SELECT COUNT(*)
--   FROM performance_schema.global_variables gv
--   WHERE gv.VARIABLE_NAME = 'binlog_format' AND gv.VARIABLE_VALUE IN ('STATEMENT', 'MIXED')
-- );
--
-- -- 10b. ssl_cipher: 8.4 restricts to specific strong ciphers only
-- SELECT 'sysVarsAllowedValues' AS check_name,
--        'Warning' AS severity,
--        gv.VARIABLE_NAME AS object,
--        CONCAT('System variable ', gv.VARIABLE_NAME, ' has value ''', gv.VARIABLE_VALUE,
--               ''' which is not in the allowed cipher list for MySQL 8.4. ',
--               'Allowed ciphers: ECDHE-ECDSA-AES128-GCM-SHA256, ECDHE-ECDSA-AES256-GCM-SHA384, ',
--               'ECDHE-RSA-AES128-GCM-SHA256, ECDHE-RSA-AES256-GCM-SHA384, ',
--               'ECDHE-ECDSA-CHACHA20-POLY1305, ECDHE-RSA-CHACHA20-POLY1305, ',
--               'ECDHE-ECDSA-AES256-CCM, ECDHE-ECDSA-AES128-CCM, ',
--               'DHE-RSA-AES128-GCM-SHA256, DHE-RSA-AES256-GCM-SHA384, ',
--               'DHE-RSA-AES256-CCM, DHE-RSA-AES128-CCM, DHE-RSA-CHACHA20-POLY1305') AS description
-- FROM performance_schema.global_variables gv
-- WHERE gv.VARIABLE_NAME = 'ssl_cipher'
--   AND gv.VARIABLE_VALUE != ''
--   AND gv.VARIABLE_VALUE NOT IN (
--     'ECDHE-ECDSA-AES128-GCM-SHA256', 'ECDHE-ECDSA-AES256-GCM-SHA384',
--     'ECDHE-RSA-AES128-GCM-SHA256', 'ECDHE-RSA-AES256-GCM-SHA384',
--     'ECDHE-ECDSA-CHACHA20-POLY1305', 'ECDHE-RSA-CHACHA20-POLY1305',
--     'ECDHE-ECDSA-AES256-CCM', 'ECDHE-ECDSA-AES128-CCM',
--     'DHE-RSA-AES128-GCM-SHA256', 'DHE-RSA-AES256-GCM-SHA384',
--     'DHE-RSA-AES256-CCM', 'DHE-RSA-AES128-CCM',
--     'DHE-RSA-CHACHA20-POLY1305'
--   );
--
-- SET @sysvar_allowed_count = @sysvar_allowed_count + (
--   SELECT COUNT(*)
--   FROM performance_schema.global_variables gv
--   WHERE gv.VARIABLE_NAME = 'ssl_cipher'
--     AND gv.VARIABLE_VALUE != ''
--     AND gv.VARIABLE_VALUE NOT IN (
--       'ECDHE-ECDSA-AES128-GCM-SHA256', 'ECDHE-ECDSA-AES256-GCM-SHA384',
--       'ECDHE-RSA-AES128-GCM-SHA256', 'ECDHE-RSA-AES256-GCM-SHA384',
--       'ECDHE-ECDSA-CHACHA20-POLY1305', 'ECDHE-RSA-CHACHA20-POLY1305',
--       'ECDHE-ECDSA-AES256-CCM', 'ECDHE-ECDSA-AES128-CCM',
--       'DHE-RSA-AES128-GCM-SHA256', 'DHE-RSA-AES256-GCM-SHA384',
--       'DHE-RSA-AES256-CCM', 'DHE-RSA-AES128-CCM',
--       'DHE-RSA-CHACHA20-POLY1305'
--     )
-- );
--
-- -- 10c. innodb_flush_method: 8.4 (unix) only allows specific values
-- SELECT 'sysVarsAllowedValues' AS check_name,
--        'Warning' AS severity,
--        gv.VARIABLE_NAME AS object,
--        CONCAT('System variable ', gv.VARIABLE_NAME, ' has value ''', gv.VARIABLE_VALUE,
--               ''' which is not in the allowed values for MySQL 8.4. ',
--               'Allowed values (Linux/Unix): fsync, O_DSYNC, littlesync, nosync, O_DIRECT, O_DIRECT_NO_FSYNC') AS description
-- FROM performance_schema.global_variables gv
-- WHERE gv.VARIABLE_NAME = 'innodb_flush_method'
--   AND gv.VARIABLE_VALUE NOT IN (
--     'fsync', 'O_DSYNC', 'littlesync', 'nosync', 'O_DIRECT', 'O_DIRECT_NO_FSYNC'
--   );
--
-- SET @sysvar_allowed_count = @sysvar_allowed_count + (
--   SELECT COUNT(*)
--   FROM performance_schema.global_variables gv
--   WHERE gv.VARIABLE_NAME = 'innodb_flush_method'
--     AND gv.VARIABLE_VALUE NOT IN (
--       'fsync', 'O_DSYNC', 'littlesync', 'nosync', 'O_DIRECT', 'O_DIRECT_NO_FSYNC'
--     )
-- );
--
-- -- 10d. tls_ciphersuites: 8.4 restricts to specific TLS 1.3 ciphersuites only
-- SELECT 'sysVarsAllowedValues' AS check_name,
--        'Warning' AS severity,
--        gv.VARIABLE_NAME AS object,
--        CONCAT('System variable ', gv.VARIABLE_NAME, ' has value ''', gv.VARIABLE_VALUE,
--               ''' which is not in the allowed ciphersuite list for MySQL 8.4. ',
--               'Allowed values: TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384, ',
--               'TLS_CHACHA20_POLY1305_SHA256, TLS_AES_128_CCM_SHA256') AS description
-- FROM performance_schema.global_variables gv
-- WHERE gv.VARIABLE_NAME = 'tls_ciphersuites'
--   AND gv.VARIABLE_VALUE != ''
--   AND gv.VARIABLE_VALUE NOT IN (
--     'TLS_AES_128_GCM_SHA256', 'TLS_AES_256_GCM_SHA384',
--     'TLS_CHACHA20_POLY1305_SHA256', 'TLS_AES_128_CCM_SHA256'
--   );
--
-- SET @sysvar_allowed_count = @sysvar_allowed_count + (
--   SELECT COUNT(*)
--   FROM performance_schema.global_variables gv
--   WHERE gv.VARIABLE_NAME = 'tls_ciphersuites'
--     AND gv.VARIABLE_VALUE != ''
--     AND gv.VARIABLE_VALUE NOT IN (
--       'TLS_AES_128_GCM_SHA256', 'TLS_AES_256_GCM_SHA384',
--       'TLS_CHACHA20_POLY1305_SHA256', 'TLS_AES_128_CCM_SHA256'
--     )
-- );
--
-- SELECT 'sysVarsAllowedValues' AS check_name,
--        CASE WHEN @has_perfschema = 0 THEN 'PASS (unverified)' ELSE 'PASS' END AS severity,
--        '' AS object,
--        CASE WHEN @has_perfschema = 0
--          THEN 'No issues detected, but result may be incomplete — current user lacks SELECT on performance_schema'
--          ELSE 'No system variables with disallowed values for 8.4 detected'
--        END AS description
-- FROM DUAL
-- WHERE @sysvar_allowed_count = 0;
--
-- SET @warning_count = @warning_count + @sysvar_allowed_count;


-- ============================================================
-- Check #11: invalidPrivileges
-- Severity: Notice
-- Origin: MySQL Shell Group 3 (trigger 8.4.0, always for 8.0→8.4)
-- Description: User privileges that will be removed during upgrade.
--
-- Reports direct grants (mysql.global_grants) AND privileges inherited through
-- roles (mysql.role_edges + mysql.global_grants). This matches MySQL Shell's
-- behaviour, which iterates users and expands roles via
-- `SHOW GRANTS FOR x USING role`.
--
-- Without role expansion, a user that only holds SET_USER_ID through a granted
-- role would be missed.
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #11: Checks for user privileges that will be removed', '\n------------------------------------------------------------') AS '';

SET @invalid_priv_count := 0;

-- Both branches share the same target privilege list (`SET_USER_ID` for now)
-- and the same output schema. We combine direct grants (mysql.global_grants)
-- and role-inherited grants (mysql.role_edges JOIN mysql.global_grants) into
-- a single UNION ALL driver so each source table is scanned once.
--
-- Direct grants drive the "(direct grant)" description.
-- Role-inherited grants are surfaced for the holding user (TO_USER/TO_HOST)
-- and the LEFT JOIN against direct grants suppresses any role-path that the
-- user already holds directly (so we never double-count the same privilege
-- for the same account).
SELECT result.check_name, result.severity, result.object, result.description
FROM (
  -- 11a. Direct grants
  SELECT 'invalidPrivileges' AS check_name,
         'Notice'             AS severity,
         CONCAT('''', gp.USER, '''@''', gp.HOST, '''') AS object,
         CONCAT('Account holds privilege that will be removed during upgrade: ',
                gp.PRIV, ' (direct grant)') AS description
  FROM mysql.global_grants gp
  WHERE gp.PRIV IN ('SET_USER_ID')

  UNION ALL

  -- 11b. Privileges inherited through roles.
  -- mysql.role_edges: FROM_USER/FROM_HOST identifies a role that has been
  -- granted TO_USER/TO_HOST (the user holding the role). A row
  -- (FROM='some_role'@'%', TO='alice'@'%') means alice@% holds some_role@%;
  -- if some_role has SET_USER_ID, alice transitively does too.
  -- The LEFT JOIN ... WHERE dg.PRIV IS NULL eliminates rows already
  -- surfaced by 11a so each (account, privilege) pair is reported once.
  SELECT 'invalidPrivileges' AS check_name,
         'Notice'             AS severity,
         CONCAT('''', re.TO_USER, '''@''', re.TO_HOST, '''') AS object,
         CONCAT('Account inherits privilege ', rg.PRIV,
                ' via role ''', re.FROM_USER, '''@''', re.FROM_HOST,
                '''. Privilege will be removed during upgrade.') AS description
  FROM mysql.role_edges re
  JOIN mysql.global_grants rg
    ON rg.USER = re.FROM_USER AND rg.HOST = re.FROM_HOST
  LEFT JOIN mysql.global_grants dg
    ON dg.USER = re.TO_USER AND dg.HOST = re.TO_HOST AND dg.PRIV = rg.PRIV
  WHERE rg.PRIV IN ('SET_USER_ID')
    AND dg.PRIV IS NULL
) result
WHERE (@invalid_priv_count := @invalid_priv_count + 1) IS NOT NULL;

SELECT 'invalidPrivileges' AS check_name,
       CASE WHEN @has_mysql_db = 0 THEN 'PASS (unverified)' ELSE 'PASS' END AS severity,
       '' AS object,
       CASE WHEN @has_mysql_db = 0
         THEN 'No issues detected, but result may be incomplete — current user lacks SELECT on mysql database'
         ELSE 'No accounts holding removed privileges detected (direct or via role)'
       END AS description
FROM DUAL
WHERE @invalid_priv_count = 0;

SET @notice_count = @notice_count + @invalid_priv_count;

-- ============================================================
-- Check #12: partitionsWithPrefixKeys
-- Severity: Error
-- Origin: MySQL Shell Group 3 (trigger 8.4.0, always for 8.0→8.4)
-- Description: Partitions by key using prefix key indexes
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #12: Checks for partitions by key using columns with prefix key indexes', '\n------------------------------------------------------------') AS '';

SET @prefix_key_part_count := 0;

SELECT 'partitionsWithPrefixKeys' AS check_name,
       'Error' AS severity,
       CONCAT(s.TABLE_SCHEMA, '.', s.TABLE_NAME) AS object,
       CONCAT('Partitioned table uses prefix key column(s): ', GROUP_CONCAT(DISTINCT s.COLUMN_NAME)) AS description
FROM information_schema.STATISTICS s
INNER JOIN information_schema.PARTITIONS p
  ON s.TABLE_SCHEMA = p.TABLE_SCHEMA
 AND s.TABLE_NAME = p.TABLE_NAME
WHERE s.SUB_PART IS NOT NULL
  AND p.PARTITION_METHOD = 'KEY'
  AND (INSTR(p.PARTITION_EXPRESSION, CONCAT('`', s.COLUMN_NAME, '`')) > 0
       OR p.PARTITION_EXPRESSION IS NULL)
  AND s.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
GROUP BY s.TABLE_SCHEMA, s.TABLE_NAME
-- Inline counter on the aggregated rows (one increment per offending table).
HAVING (@prefix_key_part_count := @prefix_key_part_count + 1) IS NOT NULL;

SELECT 'partitionsWithPrefixKeys' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'No partitions using prefix key columns detected' AS description
FROM DUAL
WHERE @prefix_key_part_count = 0;

SET @error_count = @error_count + @prefix_key_part_count;


-- ============================================================
-- Check #13: nonInclusiveLanguage
-- Severity: Error
-- Origin: RDS PrePatchCompatibility (not in MySQL Shell)
-- Description: Stored objects (routines / views / triggers / events) whose
--   body still contains a removed-in-8.4 replication keyword. The 8.4
--   parser rejects: SHOW (MASTER|SLAVE) STATUS|HOSTS, RESET MASTER|SLAVE,
--   CHANGE MASTER TO ..., START|STOP SLAVE. Each offending object would
--   fail to re-parse during the upgrade.
--   See: https://dev.mysql.com/doc/relnotes/mysql/8.4/en/news-8-4-0.html
--
-- False-positive mitigation: a layered REGEXP_REPLACE scrubber removes
-- block / line comments, single-quoted strings, and backtick / double-
-- quoted identifiers from each body before matching, and the regex uses
-- identifier-aware boundaries on both sides. Residual edge cases
-- (backslash-escaped quotes, nested comments inside strings) are listed
-- in Readme "Limitations".
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #13: Non-inclusive language in stored objects', '\n------------------------------------------------------------') AS '';

SET @non_inclusive_count = 0;

-- Regex matches the removed keywords with identifier-aware boundaries on
-- both sides so that names like `show_master_status_helper` are not
-- treated as starting a SHOW MASTER STATUS clause.
SET @non_inclusive_regex :=
  '(^|[^a-z_0-9])(show[[:space:]]+(master|slave)[[:space:]]+(status|hosts)|reset[[:space:]]+(master|slave)|change[[:space:]]+master[[:space:]]+to|(start|stop)[[:space:]]+slave)([^a-z_]|$)';

-- Layered scrubber. Each REGEXP_REPLACE replaces the matched construct
-- with a space before the keyword regex runs.
SET @noninc_scrub_block_comment  := '(?s)/\\*.*?\\*/';
SET @noninc_scrub_line_dashdash  := '--[^\n]*';
SET @noninc_scrub_line_hash      := '#[^\n]*';
SET @noninc_scrub_single_quoted  := '''[^'']*''';
SET @noninc_scrub_backtick_id    := '`[^`]*`';
SET @noninc_scrub_dquote_id      := '"[^"]*"';

-- Counter is incremented by the inline WHERE side-effect pattern below
-- so the same scan does both the display SELECT and the totalling.
SET @non_inclusive_count := 0;

SELECT check_name, severity, object, description FROM (
  -- Routines (PROCEDURE / FUNCTION)
  SELECT 'nonInclusiveLanguage' AS check_name,
         'Error' AS severity,
         CONCAT(r.ROUTINE_SCHEMA, '.', r.ROUTINE_NAME) AS object,
         CONCAT(r.ROUTINE_TYPE, ' contains deprecated replication command syntax (MASTER/SLAVE). ',
                'Replace with inclusive equivalents: SHOW REPLICA STATUS, SHOW BINARY LOG STATUS, ',
                'CHANGE REPLICATION SOURCE TO, START/STOP REPLICA, etc.') AS description
  FROM information_schema.ROUTINES r
  WHERE r.ROUTINE_SCHEMA NOT IN ('mysql', 'sys')
    AND LOWER(REGEXP_REPLACE(
           REGEXP_REPLACE(
             REGEXP_REPLACE(
               REGEXP_REPLACE(
                 REGEXP_REPLACE(
                   REGEXP_REPLACE(r.ROUTINE_DEFINITION, @noninc_scrub_block_comment, ' '),
                   @noninc_scrub_line_dashdash, ' '),
                 @noninc_scrub_line_hash, ' '),
               @noninc_scrub_single_quoted, ' '),
             @noninc_scrub_backtick_id, ' '),
           @noninc_scrub_dquote_id, ' ')
         ) REGEXP @non_inclusive_regex

  UNION ALL

  -- Views
  SELECT 'nonInclusiveLanguage' AS check_name,
         'Error' AS severity,
         CONCAT(v.TABLE_SCHEMA, '.', v.TABLE_NAME) AS object,
         CONCAT('VIEW contains deprecated replication command syntax (MASTER/SLAVE). ',
                'Replace with inclusive equivalents: SHOW REPLICA STATUS, SHOW BINARY LOG STATUS, ',
                'CHANGE REPLICATION SOURCE TO, START/STOP REPLICA, etc.') AS description
  FROM information_schema.VIEWS v
  WHERE v.TABLE_SCHEMA NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema')
    AND LOWER(REGEXP_REPLACE(
           REGEXP_REPLACE(
             REGEXP_REPLACE(
               REGEXP_REPLACE(
                 REGEXP_REPLACE(
                   REGEXP_REPLACE(v.VIEW_DEFINITION, @noninc_scrub_block_comment, ' '),
                   @noninc_scrub_line_dashdash, ' '),
                 @noninc_scrub_line_hash, ' '),
               @noninc_scrub_single_quoted, ' '),
             @noninc_scrub_backtick_id, ' '),
           @noninc_scrub_dquote_id, ' ')
         ) REGEXP @non_inclusive_regex

  UNION ALL

  -- Triggers
  SELECT 'nonInclusiveLanguage' AS check_name,
         'Error' AS severity,
         CONCAT(t.TRIGGER_SCHEMA, '.', t.TRIGGER_NAME) AS object,
         CONCAT('TRIGGER contains deprecated replication command syntax (MASTER/SLAVE). ',
                'Replace with inclusive equivalents: SHOW REPLICA STATUS, SHOW BINARY LOG STATUS, ',
                'CHANGE REPLICATION SOURCE TO, START/STOP REPLICA, etc.') AS description
  FROM information_schema.TRIGGERS t
  WHERE t.TRIGGER_SCHEMA NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema')
    AND LOWER(REGEXP_REPLACE(
           REGEXP_REPLACE(
             REGEXP_REPLACE(
               REGEXP_REPLACE(
                 REGEXP_REPLACE(
                   REGEXP_REPLACE(t.ACTION_STATEMENT, @noninc_scrub_block_comment, ' '),
                   @noninc_scrub_line_dashdash, ' '),
                 @noninc_scrub_line_hash, ' '),
               @noninc_scrub_single_quoted, ' '),
             @noninc_scrub_backtick_id, ' '),
           @noninc_scrub_dquote_id, ' ')
         ) REGEXP @non_inclusive_regex

  UNION ALL

  -- Events
  SELECT 'nonInclusiveLanguage' AS check_name,
         'Error' AS severity,
         CONCAT(e.EVENT_SCHEMA, '.', e.EVENT_NAME) AS object,
         CONCAT('EVENT contains deprecated replication command syntax (MASTER/SLAVE). ',
                'Replace with inclusive equivalents: SHOW REPLICA STATUS, SHOW BINARY LOG STATUS, ',
                'CHANGE REPLICATION SOURCE TO, START/STOP REPLICA, etc.') AS description
  FROM information_schema.EVENTS e
  WHERE e.EVENT_SCHEMA NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema')
    AND LOWER(REGEXP_REPLACE(
           REGEXP_REPLACE(
             REGEXP_REPLACE(
               REGEXP_REPLACE(
                 REGEXP_REPLACE(
                   REGEXP_REPLACE(e.EVENT_DEFINITION, @noninc_scrub_block_comment, ' '),
                   @noninc_scrub_line_dashdash, ' '),
                 @noninc_scrub_line_hash, ' '),
               @noninc_scrub_single_quoted, ' '),
             @noninc_scrub_backtick_id, ' '),
           @noninc_scrub_dquote_id, ' ')
         ) REGEXP @non_inclusive_regex
) non_inclusive_objects
WHERE (@non_inclusive_count := @non_inclusive_count + 1) IS NOT NULL;

SELECT 'nonInclusiveLanguage' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'No non-inclusive language usage detected' AS description
FROM DUAL
WHERE @non_inclusive_count = 0;

SET @error_count = @error_count + @non_inclusive_count;

-- ============================================================
-- Check #14: memcachedPlugin
-- Severity: Error
-- Origin: RDS PrePatchCompatibility (not in MySQL Shell)
-- Description: memcached plugin needs to be uninstalled
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #14: memcached plugin needs to be uninstalled before upgrade', '\n------------------------------------------------------------') AS '';

SET @memcached_count := 0;

SELECT 'memcachedPlugin' AS check_name,
       'Error' AS severity,
       p.PLUGIN_NAME AS object,
       CONCAT('The daemon_memcached plugin is active and must be uninstalled before upgrading to MySQL 8.4. ',
              'Plugin status: ', p.PLUGIN_STATUS) AS description
FROM information_schema.PLUGINS p
WHERE p.PLUGIN_NAME = 'daemon_memcached'
  AND p.PLUGIN_STATUS = 'ACTIVE'
  AND (@memcached_count := @memcached_count + 1) IS NOT NULL;

SELECT 'memcachedPlugin' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'No active daemon_memcached plugin detected' AS description
FROM DUAL
WHERE @memcached_count = 0;

SET @error_count = @error_count + @memcached_count;

-- ============================================================
-- Check #15: sysSchemaObjects
-- Severity: Error
-- Origin: RDS PrePatchCompatibility (not in MySQL Shell)
-- Description: Detect user-created objects or type mismatches in the sys schema.
--
-- The sys schema ships with:
--   * exactly one BASE TABLE called sys_config
--   * a fixed set of VIEWs whose DEFINER is 'mysql.sys'@'localhost'
-- Anything that departs from that layout can block or corrupt the upgrade,
-- because the 8.4 data-dictionary rebuild re-creates the sys schema from
-- scratch and cannot merge with foreign objects. This check now covers
-- four failure modes instead of the original one:
--
--   15a. A BASE TABLE other than sys_config           (user-created table)
--   15b. sys.sys_config is not a BASE TABLE           (system table replaced by view)
--   15c. sys.sys_config is missing
--   15d. A VIEW with DEFINER != 'mysql.sys'@'localhost' (user-created/altered view)
--   15e. Aurora-only: official sys-view name present as a BASE TABLE (type mismatch)
--
-- 15d is deliberately DEFINER-based rather than name-based: the set of
-- system view names grows every point release, so whitelisting them here
-- would drift. DEFINER is the one attribute Oracle never changes.
-- 15e mirrors Aurora's auroraUpgradeCheckForSysSchemaObjectTypeMismatch and
-- is gated on @is_aurora; it uses an allowlist of the 100 stock sys VIEWs.
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #15: Detect system objects created as tables in sys schema', '\n------------------------------------------------------------') AS '';

SET @sys_schema_objects_count := 0;

-- Allowlist of the 100 stock sys VIEW names (MySQL 8.0 sys schema). Used by
-- the Aurora-gated 15e type-mismatch branch and to keep 15a from
-- double-reporting those names on Aurora. Source: information_schema on a
-- stock RDS MySQL 8.0 sys schema (100 VIEWs + sys_config BASE TABLE).
SET @sys_view_allowlist :=
  'host_summary,host_summary_by_file_io,host_summary_by_file_io_type,host_summary_by_stages,host_summary_by_statement_latency,host_summary_by_statement_type,innodb_buffer_stats_by_schema,innodb_buffer_stats_by_table,innodb_lock_waits,io_by_thread_by_latency,io_global_by_file_by_bytes,io_global_by_file_by_latency,io_global_by_wait_by_bytes,io_global_by_wait_by_latency,latest_file_io,memory_by_host_by_current_bytes,memory_by_thread_by_current_bytes,memory_by_user_by_current_bytes,memory_global_by_current_bytes,memory_global_total,metrics,processlist,ps_check_lost_instrumentation,schema_auto_increment_columns,schema_index_statistics,schema_object_overview,schema_redundant_indexes,schema_table_lock_waits,schema_table_statistics,schema_table_statistics_with_buffer,schema_tables_with_full_table_scans,schema_unused_indexes,session,session_ssl_status,statement_analysis,statements_with_errors_or_warnings,statements_with_full_table_scans,statements_with_runtimes_in_95th_percentile,statements_with_sorting,statements_with_temp_tables,user_summary,user_summary_by_file_io,user_summary_by_file_io_type,user_summary_by_stages,user_summary_by_statement_latency,user_summary_by_statement_type,version,wait_classes_global_by_avg_latency,wait_classes_global_by_latency,waits_by_host_by_latency,waits_by_user_by_latency,waits_global_by_latency,x$host_summary,x$host_summary_by_file_io,x$host_summary_by_file_io_type,x$host_summary_by_stages,x$host_summary_by_statement_latency,x$host_summary_by_statement_type,x$innodb_buffer_stats_by_schema,x$innodb_buffer_stats_by_table,x$innodb_lock_waits,x$io_by_thread_by_latency,x$io_global_by_file_by_bytes,x$io_global_by_file_by_latency,x$io_global_by_wait_by_bytes,x$io_global_by_wait_by_latency,x$latest_file_io,x$memory_by_host_by_current_bytes,x$memory_by_thread_by_current_bytes,x$memory_by_user_by_current_bytes,x$memory_global_by_current_bytes,x$memory_global_total,x$processlist,x$ps_digest_95th_percentile_by_avg_us,x$ps_digest_avg_latency_distribution,x$ps_schema_table_statistics_io,x$schema_flattened_keys,x$schema_index_statistics,x$schema_table_lock_waits,x$schema_table_statistics,x$schema_table_statistics_with_buffer,x$schema_tables_with_full_table_scans,x$session,x$statement_analysis,x$statements_with_errors_or_warnings,x$statements_with_full_table_scans,x$statements_with_runtimes_in_95th_percentile,x$statements_with_sorting,x$statements_with_temp_tables,x$user_summary,x$user_summary_by_file_io,x$user_summary_by_file_io_type,x$user_summary_by_stages,x$user_summary_by_statement_latency,x$user_summary_by_statement_type,x$wait_classes_global_by_avg_latency,x$wait_classes_global_by_latency,x$waits_by_host_by_latency,x$waits_by_user_by_latency,x$waits_global_by_latency';

-- 15a + 15b: single scan of information_schema.TABLES restricted to sys
-- schema. Branches differ only in matching predicate and description text;
-- a CASE produces the right description per row.
--   15a: BASE TABLE other than sys_config (user-created table)
--   15b: sys_config object that is not a BASE TABLE
-- On Aurora, official sys-view names appearing as BASE TABLEs are excluded
-- here and handled by 15e (type mismatch) instead.
SELECT 'sysSchemaObjects' AS check_name,
       'Error' AS severity,
       CONCAT('sys.', t.TABLE_NAME) AS object,
       CASE
         WHEN t.TABLE_TYPE = 'BASE TABLE' AND t.TABLE_NAME <> 'sys_config' THEN
           CONCAT('User-created BASE TABLE ''', t.TABLE_NAME, ''' in sys schema. ',
                  'The sys schema must only contain sys_config (the single system BASE TABLE) ',
                  'and system VIEWs owned by ''mysql.sys''@''localhost''. ',
                  'User-created base tables may conflict with system objects during upgrade.')
         WHEN t.TABLE_NAME = 'sys_config' AND t.TABLE_TYPE <> 'BASE TABLE' THEN
           CONCAT('sys.sys_config is of type ''', t.TABLE_TYPE,
                  ''' but must be BASE TABLE. ',
                  'This is the only expected BASE TABLE in the sys schema; ',
                  'replacing it with a different object type will break the 8.4 upgrade.')
       END AS description
FROM information_schema.TABLES t
WHERE t.TABLE_SCHEMA = 'sys'
  AND (
    -- 15a (on Aurora, skip official sys-view names; 15e handles them)
    (t.TABLE_TYPE = 'BASE TABLE' AND t.TABLE_NAME <> 'sys_config'
       AND (@is_aurora = 0 OR FIND_IN_SET(t.TABLE_NAME, @sys_view_allowlist) = 0))
    OR
    -- 15b
    (t.TABLE_NAME = 'sys_config' AND t.TABLE_TYPE <> 'BASE TABLE')
  )
  AND (@sys_schema_objects_count := @sys_schema_objects_count + 1) IS NOT NULL;

-- 15c. sys.sys_config is missing altogether
SELECT 'sysSchemaObjects' AS check_name,
       'Error' AS severity,
       'sys.sys_config' AS object,
       'sys.sys_config is missing. The 8.4 upgrade expects a system BASE TABLE named sys_config.' AS description
FROM DUAL
WHERE NOT EXISTS (
  SELECT 1 FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = 'sys' AND TABLE_NAME = 'sys_config'
)
  AND EXISTS (SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'sys')
  AND (@sys_schema_objects_count := @sys_schema_objects_count + 1) IS NOT NULL;

-- 15d. User-created / user-modified VIEW in sys schema.
-- System sys views are created with DEFINER='mysql.sys'@'localhost'. Anything
-- else indicates either a user-created view, or a system view whose DEFINER
-- was rewritten — both are handled the same way (user must drop/recreate).
SELECT 'sysSchemaObjects' AS check_name,
       'Error' AS severity,
       CONCAT('sys.', v.TABLE_NAME) AS object,
       CONCAT('VIEW ''', v.TABLE_NAME, ''' in sys schema has DEFINER=',
              QUOTE(v.DEFINER),
              ' instead of ''mysql.sys''@''localhost''. ',
              'Either a user-created view or a system view whose DEFINER was altered. ',
              'Drop or migrate it before upgrading; the 8.4 upgrade rebuilds sys views from scratch.') AS description
FROM information_schema.VIEWS v
WHERE v.TABLE_SCHEMA = 'sys'
  AND v.DEFINER      <> 'mysql.sys@localhost'
  AND (@sys_schema_objects_count := @sys_schema_objects_count + 1) IS NOT NULL;

-- 15e. Aurora-only: official sys-view name present as a BASE TABLE
-- (type mismatch). Mirrors Aurora's auroraUpgradeCheckForSysSchemaObjectTypeMismatch.
SELECT 'sysSchemaObjects' AS check_name,
       'Error' AS severity,
       CONCAT('sys.', t.TABLE_NAME) AS object,
       CONCAT('System sys object ''', t.TABLE_NAME, ''' must be a VIEW but is ',
              t.TABLE_TYPE, '. The 8.4 sys-schema rebuild cannot reconcile this type mismatch.') AS description
FROM information_schema.TABLES t
WHERE @is_aurora = 1
  AND t.TABLE_SCHEMA = 'sys'
  AND t.TABLE_TYPE = 'BASE TABLE'
  AND t.TABLE_NAME <> 'sys_config'
  AND FIND_IN_SET(t.TABLE_NAME, @sys_view_allowlist) > 0
  AND (@sys_schema_objects_count := @sys_schema_objects_count + 1) IS NOT NULL;

SELECT 'sysSchemaObjects' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'No user-created objects or type mismatches detected in sys schema' AS description
FROM DUAL
WHERE @sys_schema_objects_count = 0;

SET @error_count = @error_count + @sys_schema_objects_count;


-- ============================================================
-- Check #16: dollarSignName
-- Severity: Warning
-- Origin: MySQL Shell Group 1 (trigger 8.0.31)
-- Condition: Only activates when source_patch < 31
-- Description: Object names starting with $ sign. Covers schemas, base
--              tables, views (reported separately from base tables),
--              columns, indexes, routines (procedures/functions),
--              triggers, and events.
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', CASE WHEN @source_patch < 31 THEN 'Check #16: Dollar sign object names' ELSE 'Check #16: Dollar sign object names [SKIP - source >= 8.0.31]' END, '\n------------------------------------------------------------') AS '';

SET @dollar_sign_count := 0;

SELECT check_name, severity, object, description FROM (
  SELECT 'dollarSignName' AS check_name,
         'Warning' AS severity,
         s.SCHEMA_NAME AS object,
         'Schema name starts with $ sign' AS description
  FROM information_schema.SCHEMATA s
  WHERE @source_patch < 31
    AND s.SCHEMA_NAME LIKE '$%'
    AND s.SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')

  UNION ALL

  -- TABLES: base tables only (TABLE_TYPE = 'BASE TABLE'); views are scanned
  -- separately by the VIEWS branch below so the description text is accurate.
  SELECT 'dollarSignName' AS check_name,
         'Warning' AS severity,
         CONCAT(t.TABLE_SCHEMA, '.', t.TABLE_NAME) AS object,
         'Table name starts with $ sign' AS description
  FROM information_schema.TABLES t
  WHERE @source_patch < 31
    AND t.TABLE_NAME LIKE '$%'
    AND t.TABLE_TYPE = 'BASE TABLE'
    AND t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')

  UNION ALL

  -- VIEWS: reported separately from base tables. information_schema.VIEWS
  -- lists only views, so no TABLE_TYPE filter is needed here.
  SELECT 'dollarSignName' AS check_name,
         'Warning' AS severity,
         CONCAT(v.TABLE_SCHEMA, '.', v.TABLE_NAME) AS object,
         'View name starts with $ sign' AS description
  FROM information_schema.VIEWS v
  WHERE @source_patch < 31
    AND v.TABLE_NAME LIKE '$%'
    AND v.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')

  UNION ALL

  SELECT 'dollarSignName' AS check_name,
         'Warning' AS severity,
         CONCAT(c.TABLE_SCHEMA, '.', c.TABLE_NAME, '.', c.COLUMN_NAME) AS object,
         'Column name starts with $ sign' AS description
  FROM information_schema.COLUMNS c
  WHERE @source_patch < 31
    AND c.COLUMN_NAME LIKE '$%'
    AND c.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')

  UNION ALL

  SELECT 'dollarSignName' AS check_name,
         'Warning' AS severity,
         CONCAT(st.TABLE_SCHEMA, '.', st.TABLE_NAME, '.', st.INDEX_NAME) AS object,
         'Index name starts with $ sign' AS description
  FROM information_schema.STATISTICS st
  WHERE @source_patch < 31
    AND st.INDEX_NAME LIKE '$%'
    AND st.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  GROUP BY st.TABLE_SCHEMA, st.TABLE_NAME, st.INDEX_NAME

  UNION ALL

  SELECT 'dollarSignName' AS check_name,
         'Warning' AS severity,
         CONCAT(r.ROUTINE_SCHEMA, '.', r.ROUTINE_NAME) AS object,
         CONCAT(r.ROUTINE_TYPE, ' name starts with $ sign') AS description
  FROM information_schema.ROUTINES r
  WHERE @source_patch < 31
    AND r.ROUTINE_NAME LIKE '$%'
    AND r.ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')

  UNION ALL

  -- TRIGGERS: information_schema.TRIGGERS.TRIGGER_NAME
  SELECT 'dollarSignName' AS check_name,
         'Warning' AS severity,
         CONCAT(tr.TRIGGER_SCHEMA, '.', tr.TRIGGER_NAME) AS object,
         'Trigger name starts with $ sign' AS description
  FROM information_schema.TRIGGERS tr
  WHERE @source_patch < 31
    AND tr.TRIGGER_NAME LIKE '$%'
    AND tr.TRIGGER_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')

  UNION ALL

  -- EVENTS: information_schema.EVENTS.EVENT_NAME
  SELECT 'dollarSignName' AS check_name,
         'Warning' AS severity,
         CONCAT(e.EVENT_SCHEMA, '.', e.EVENT_NAME) AS object,
         'Event name starts with $ sign' AS description
  FROM information_schema.EVENTS e
  WHERE @source_patch < 31
    AND e.EVENT_NAME LIKE '$%'
    AND e.EVENT_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
) AS dollar_sign_results
WHERE (@dollar_sign_count := @dollar_sign_count + 1) IS NOT NULL;

SELECT 'dollarSignName' AS check_name,
       'PASS' AS severity,
       '' AS object,
       CASE WHEN @source_patch >= 31
         THEN CONCAT('SKIP: Source version 8.0.', @source_patch, ' >= 8.0.31, check not applicable')
         ELSE 'No object names starting with $ sign detected'
       END AS description
FROM DUAL
WHERE @dollar_sign_count = 0;

SET @warning_count = @warning_count + @dollar_sign_count;


-- ============================================================
-- Check #17: reservedKeywords
-- Severity: Warning
-- Origin: MySQL Shell Group 1 (trigger 8.0.14, 8.0.17, 8.0.31) +
--         MySQL 8.4.0 New Keywords (https://dev.mysql.com/doc/refman/8.4/en/keywords.html)
-- Condition: Two keyword groups with independent gating
-- Description: Object names conflicting with reserved keywords.
--
-- Coverage (one branch per information_schema source, no overlap):
--   - SCHEMATA                     schema names
--   - TABLES (TABLE_TYPE='BASE TABLE')  real table names
--   - VIEWS                        view names (separated from TABLES to
--                                  avoid double-counting: info_schema.TABLES
--                                  lists views too and previously both
--                                  branches fired for the same object)
--   - COLUMNS                      column names (on both tables and views)
--   - ROUTINES                     PROCEDURE / FUNCTION names
--   - TRIGGERS                     trigger names
--   - EVENTS                       event names
--
-- Keyword groups (target is always 8.4.x in this tool):
--   Group A (8.0.31): FULL, INTERSECT
--                     -> only checked when @source_patch < 31, since
--                        anything from 8.0.31+ has already crossed this
--                        boundary at install time.
--   Group B (8.4.0):  MANUAL, PARALLEL, QUALIFY, TABLESAMPLE
--                     -> always checked, because the target is 8.4.x and
--                        any 8.0.x source crosses this boundary.
--
-- mysql-shell's own reservedKeywords check only covers Group A. It relies
-- on a separate "syntax" check (using the 8.4 yacc parser) to catch
-- Group B usage inside routine/view/trigger/event bodies. This SQL tool
-- has no parser, so Group B must be enumerated explicitly here to detect
-- conflicts on object names.
--
-- LATERAL (8.0.14) and ARRAY/MEMBER (8.0.17) are not listed because any
-- supported 8.0.x source has already crossed those boundaries.
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #17: Reserved keywords', CASE WHEN @source_patch >= 31 THEN ' [Group A skipped - source >= 8.0.31]' ELSE '' END, '\n------------------------------------------------------------') AS '';

SET @reserved_kw_count := 0;

-- Group A keywords (FULL, INTERSECT) only apply when source < 8.0.31.
-- Group B keywords (MANUAL, PARALLEL, QUALIFY, TABLESAMPLE) are 8.4.0
-- additions and must always be checked when targeting 8.4.x.

SELECT check_name, severity, object, description FROM (
  SELECT 'reservedKeywords' AS check_name,
         'Warning' AS severity,
         s.SCHEMA_NAME AS object,
         CONCAT('Schema name `', s.SCHEMA_NAME, '` conflicts with reserved keyword introduced in ',
           CASE UPPER(s.SCHEMA_NAME)
             WHEN 'FULL'        THEN '8.0.31'
             WHEN 'INTERSECT'   THEN '8.0.31'
             WHEN 'MANUAL'      THEN '8.4.0'
             WHEN 'PARALLEL'    THEN '8.4.0'
             WHEN 'QUALIFY'     THEN '8.4.0'
             WHEN 'TABLESAMPLE' THEN '8.4.0'
           END) AS description
  FROM information_schema.SCHEMATA s
  WHERE s.SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    AND (
      (UPPER(s.SCHEMA_NAME) IN ('FULL', 'INTERSECT') AND @source_patch < 31)
      OR UPPER(s.SCHEMA_NAME) IN ('MANUAL', 'PARALLEL', 'QUALIFY', 'TABLESAMPLE')
    )

  UNION ALL

  -- Base tables only. Views are handled below in a separate branch so that a
  -- view is never reported twice (information_schema.TABLES rows include
  -- views, which is why we constrain to TABLE_TYPE='BASE TABLE' here).
  SELECT 'reservedKeywords' AS check_name,
         'Warning' AS severity,
         CONCAT(t.TABLE_SCHEMA, '.', t.TABLE_NAME) AS object,
         CONCAT('Table name `', t.TABLE_NAME, '` conflicts with reserved keyword introduced in ',
           CASE UPPER(t.TABLE_NAME)
             WHEN 'FULL'        THEN '8.0.31'
             WHEN 'INTERSECT'   THEN '8.0.31'
             WHEN 'MANUAL'      THEN '8.4.0'
             WHEN 'PARALLEL'    THEN '8.4.0'
             WHEN 'QUALIFY'     THEN '8.4.0'
             WHEN 'TABLESAMPLE' THEN '8.4.0'
           END) AS description
  FROM information_schema.TABLES t
  WHERE t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    AND t.TABLE_TYPE  = 'BASE TABLE'
    AND (
      (UPPER(t.TABLE_NAME) IN ('FULL', 'INTERSECT') AND @source_patch < 31)
      OR UPPER(t.TABLE_NAME) IN ('MANUAL', 'PARALLEL', 'QUALIFY', 'TABLESAMPLE')
    )

  UNION ALL

  SELECT 'reservedKeywords' AS check_name,
         'Warning' AS severity,
         CONCAT(c.TABLE_SCHEMA, '.', c.TABLE_NAME, '.', c.COLUMN_NAME) AS object,
         CONCAT('Column name `', c.COLUMN_NAME, '` conflicts with reserved keyword introduced in ',
           CASE UPPER(c.COLUMN_NAME)
             WHEN 'FULL'        THEN '8.0.31'
             WHEN 'INTERSECT'   THEN '8.0.31'
             WHEN 'MANUAL'      THEN '8.4.0'
             WHEN 'PARALLEL'    THEN '8.4.0'
             WHEN 'QUALIFY'     THEN '8.4.0'
             WHEN 'TABLESAMPLE' THEN '8.4.0'
           END) AS description
  FROM information_schema.COLUMNS c
  WHERE c.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    AND (
      (UPPER(c.COLUMN_NAME) IN ('FULL', 'INTERSECT') AND @source_patch < 31)
      OR UPPER(c.COLUMN_NAME) IN ('MANUAL', 'PARALLEL', 'QUALIFY', 'TABLESAMPLE')
    )

  UNION ALL

  SELECT 'reservedKeywords' AS check_name,
         'Warning' AS severity,
         CONCAT(r.ROUTINE_SCHEMA, '.', r.ROUTINE_NAME) AS object,
         CONCAT(r.ROUTINE_TYPE, ' name `', r.ROUTINE_NAME, '` conflicts with reserved keyword introduced in ',
           CASE UPPER(r.ROUTINE_NAME)
             WHEN 'FULL'        THEN '8.0.31'
             WHEN 'INTERSECT'   THEN '8.0.31'
             WHEN 'MANUAL'      THEN '8.4.0'
             WHEN 'PARALLEL'    THEN '8.4.0'
             WHEN 'QUALIFY'     THEN '8.4.0'
             WHEN 'TABLESAMPLE' THEN '8.4.0'
           END) AS description
  FROM information_schema.ROUTINES r
  WHERE r.ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    AND (
      (UPPER(r.ROUTINE_NAME) IN ('FULL', 'INTERSECT') AND @source_patch < 31)
      OR UPPER(r.ROUTINE_NAME) IN ('MANUAL', 'PARALLEL', 'QUALIFY', 'TABLESAMPLE')
    )

  UNION ALL

  SELECT 'reservedKeywords' AS check_name,
         'Warning' AS severity,
         CONCAT(tr.TRIGGER_SCHEMA, '.', tr.TRIGGER_NAME) AS object,
         CONCAT('Trigger name `', tr.TRIGGER_NAME, '` conflicts with reserved keyword introduced in ',
           CASE UPPER(tr.TRIGGER_NAME)
             WHEN 'FULL'        THEN '8.0.31'
             WHEN 'INTERSECT'   THEN '8.0.31'
             WHEN 'MANUAL'      THEN '8.4.0'
             WHEN 'PARALLEL'    THEN '8.4.0'
             WHEN 'QUALIFY'     THEN '8.4.0'
             WHEN 'TABLESAMPLE' THEN '8.4.0'
           END) AS description
  FROM information_schema.TRIGGERS tr
  WHERE tr.TRIGGER_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    AND (
      (UPPER(tr.TRIGGER_NAME) IN ('FULL', 'INTERSECT') AND @source_patch < 31)
      OR UPPER(tr.TRIGGER_NAME) IN ('MANUAL', 'PARALLEL', 'QUALIFY', 'TABLESAMPLE')
    )

  UNION ALL

  SELECT 'reservedKeywords' AS check_name,
         'Warning' AS severity,
         CONCAT(v.TABLE_SCHEMA, '.', v.TABLE_NAME) AS object,
         CONCAT('View name `', v.TABLE_NAME, '` conflicts with reserved keyword introduced in ',
           CASE UPPER(v.TABLE_NAME)
             WHEN 'FULL'        THEN '8.0.31'
             WHEN 'INTERSECT'   THEN '8.0.31'
             WHEN 'MANUAL'      THEN '8.4.0'
             WHEN 'PARALLEL'    THEN '8.4.0'
             WHEN 'QUALIFY'     THEN '8.4.0'
             WHEN 'TABLESAMPLE' THEN '8.4.0'
           END) AS description
  FROM information_schema.VIEWS v
  WHERE v.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    AND (
      (UPPER(v.TABLE_NAME) IN ('FULL', 'INTERSECT') AND @source_patch < 31)
      OR UPPER(v.TABLE_NAME) IN ('MANUAL', 'PARALLEL', 'QUALIFY', 'TABLESAMPLE')
    )

  UNION ALL

  SELECT 'reservedKeywords' AS check_name,
         'Warning' AS severity,
         CONCAT(e.EVENT_SCHEMA, '.', e.EVENT_NAME) AS object,
         CONCAT('Event name `', e.EVENT_NAME, '` conflicts with reserved keyword introduced in ',
           CASE UPPER(e.EVENT_NAME)
             WHEN 'FULL'        THEN '8.0.31'
             WHEN 'INTERSECT'   THEN '8.0.31'
             WHEN 'MANUAL'      THEN '8.4.0'
             WHEN 'PARALLEL'    THEN '8.4.0'
             WHEN 'QUALIFY'     THEN '8.4.0'
             WHEN 'TABLESAMPLE' THEN '8.4.0'
           END) AS description
  FROM information_schema.EVENTS e
  WHERE e.EVENT_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    AND (
      (UPPER(e.EVENT_NAME) IN ('FULL', 'INTERSECT') AND @source_patch < 31)
      OR UPPER(e.EVENT_NAME) IN ('MANUAL', 'PARALLEL', 'QUALIFY', 'TABLESAMPLE')
    )
) AS reserved_kw_results
WHERE (@reserved_kw_count := @reserved_kw_count + 1) IS NOT NULL;

SELECT 'reservedKeywords' AS check_name,
       'PASS' AS severity,
       '' AS object,
       CASE
         WHEN @source_patch >= 31
         THEN 'No object names conflicting with reserved keywords (MANUAL, PARALLEL, QUALIFY, TABLESAMPLE) detected; FULL/INTERSECT skipped (source >= 8.0.31)'
         ELSE 'No object names conflicting with reserved keywords (FULL, INTERSECT, MANUAL, PARALLEL, QUALIFY, TABLESAMPLE) detected'
       END AS description
FROM DUAL
WHERE @reserved_kw_count = 0;

SET @warning_count = @warning_count + @reserved_kw_count;


-- ============================================================
-- Check #18: deprecatedTemporalDelimiter
-- Severity: Error
-- Origin: MySQL Shell Group 1 (trigger 8.0.29)
-- Condition: Only activates when source_patch < 29
-- Description: Deprecated temporal delimiters in partitions
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', CASE WHEN @source_patch < 29 THEN 'Check #18: Deprecated temporal delimiter' ELSE 'Check #18: Deprecated temporal delimiter [SKIP - source >= 8.0.29]' END, '\n------------------------------------------------------------') AS '';

SET @deprecated_temporal_delim_count := 0;

SELECT 'deprecatedTemporalDelimiter' AS check_name,
       'Error' AS severity,
       CONCAT(p.TABLE_SCHEMA, '.', p.TABLE_NAME, '#', p.PARTITION_NAME) AS object,
       CONCAT('Partition ', p.PARTITION_NAME,
              ' on column `', c.COLUMN_NAME,
              '` (', c.COLUMN_TYPE, ') uses deprecated temporal delimiters: ',
              p.PARTITION_DESCRIPTION) AS description
FROM information_schema.PARTITIONS p
LEFT JOIN information_schema.COLUMNS c
  ON p.TABLE_SCHEMA = c.TABLE_SCHEMA
 AND p.TABLE_NAME = c.TABLE_NAME
 AND p.PARTITION_EXPRESSION LIKE CONCAT('%`', c.COLUMN_NAME, '`%')
WHERE @source_patch < 29
  AND p.PARTITION_METHOD IN ('RANGE', 'RANGE COLUMNS')
  AND p.PARTITION_DESCRIPTION IS NOT NULL
  AND p.PARTITION_DESCRIPTION != 'MAXVALUE'
  AND p.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND (
    (c.COLUMN_TYPE = 'date'
     AND NOT p.PARTITION_DESCRIPTION REGEXP '^(\'[0-9]{4}-[0-9]{2}-[0-9]{2}\')(,\'[0-9]{4}-[0-9]{2}-[0-9]{2}\')*$')
    OR
    ((c.COLUMN_TYPE = 'datetime' OR c.COLUMN_TYPE = 'timestamp')
     AND NOT p.PARTITION_DESCRIPTION REGEXP '^(\'[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]*)?\')(,\'[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]*)?\')*$')
  )
  -- Inline counter: side-effect evaluates once per retained row, always true.
  AND (@deprecated_temporal_delim_count := @deprecated_temporal_delim_count + 1) IS NOT NULL;

SELECT 'deprecatedTemporalDelimiter' AS check_name,
       'PASS' AS severity,
       '' AS object,
       CASE WHEN @source_patch >= 29
         THEN CONCAT('SKIP: Source version 8.0.', @source_patch, ' >= 8.0.29, check not applicable')
         ELSE 'No partitions using deprecated temporal delimiters detected'
       END AS description
FROM DUAL
WHERE @deprecated_temporal_delim_count = 0;

SET @error_count = @error_count + @deprecated_temporal_delim_count;

-- ============================================================
-- Check #19: spatialIndex
-- Severity: Warning
-- Origin: MySQL Shell Group 2 (source in 8.0.3–8.0.40)
-- Condition: Only activates when source_patch >= 3 AND <= 40
-- Description: InnoDB spatial indexes with corruption risk
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', CASE WHEN @source_patch >= 3 AND @source_patch <= 40 THEN 'Check #19: Spatial index' ELSE CONCAT('Check #19: Spatial index [SKIP - source 8.0.', @source_patch, ' outside 8.0.3-8.0.40]') END, '\n------------------------------------------------------------') AS '';

SET @spatial_index_count := 0;

SELECT 'spatialIndex' AS check_name,
       'Warning' AS severity,
       CONCAT(t.TABLE_SCHEMA, '.', t.TABLE_NAME, '.', s.INDEX_NAME) AS object,
       CONCAT('InnoDB table has spatial index that must be rebuilt before upgrading to 8.4 ',
              '(affected versions: 8.0.3 - 8.0.40)') AS description
FROM information_schema.STATISTICS s
JOIN information_schema.TABLES t
  ON s.TABLE_SCHEMA = t.TABLE_SCHEMA
 AND s.TABLE_NAME = t.TABLE_NAME
WHERE s.INDEX_TYPE = 'SPATIAL'
  AND t.ENGINE = 'InnoDB'
  AND s.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND @source_patch >= 3
  AND @source_patch <= 40
GROUP BY t.TABLE_SCHEMA, t.TABLE_NAME, s.INDEX_NAME
-- Inline counter on the aggregated rows (one increment per distinct index).
HAVING (@spatial_index_count := @spatial_index_count + 1) IS NOT NULL;

SELECT 'spatialIndex' AS check_name,
       'PASS' AS severity,
       '' AS object,
       CONCAT('No InnoDB spatial index issues detected',
              CASE
                WHEN @source_patch < 3 OR @source_patch > 40
                THEN CONCAT(' (source version 8.0.', @source_patch, ' is outside affected range 8.0.3-8.0.40)')
                ELSE ''
              END) AS description
FROM DUAL
WHERE @spatial_index_count = 0;

SET @warning_count = @warning_count + @spatial_index_count;


-- ============================================================
-- ============================================================
-- AURORA-ONLY CHECKS (#20 - #23)
-- ============================================================
-- All four checks below are gated on @is_aurora = 1. On RDS for MySQL /
-- community MySQL they print a one-line "[SKIP - not Aurora]" banner and
-- contribute ZERO rows and ZERO to the severity counters, so output on
-- RDS is identical to the RDS-only script. These mirror the Aurora-only checks in Aurora's
-- upgrade-prechecks.log (auroraUnsupportedPluginsCheck,
-- auroraUnsupportedComponentsCheck, auroraValidatePasswordPluginCheck,
-- auroraUpgradeCheckForDuplicatedColumnValuesInEnum).
-- ============================================================

-- ============================================================
-- Check #20: auroraUnsupportedPlugins  (Aurora-only)
-- Severity: Error
-- Origin: Aurora upgrade-prechecks.log (auroraUnsupportedPluginsCheck)
-- Model:  ALLOWLIST. Scans mysql.plugin for dynamically-loaded plugins
--   (dl IS NOT NULL/'') and flags any whose .so is NOT on the Aurora 8.4
--   allowlist. This is the opposite polarity of #6 (which is a denylist of
--   known-removed plugins); the two coexist.
-- Allowlist (Aurora MySQL 8.4): authentication_kerberos.so, auth_socket.so,
--   aws_auth.so, validate_password.so
-- Ref: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.upgrade-prechecks-v3-to-v84.descriptions.html
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n',
  CASE WHEN @is_aurora = 1
    THEN 'Check #20: Aurora unsupported plugins'
    ELSE 'Check #20: Aurora unsupported plugins [SKIP - not Aurora]'
  END,
  '\n------------------------------------------------------------') AS '';

SET @aurora_unsupported_plugin_count := 0;

SELECT 'auroraUnsupportedPlugins' AS check_name,
       'Error' AS severity,
       p.name AS object,
       CONCAT('Dynamically-loaded plugin ''', p.name, ''' (library ''', p.dl,
              ''') is not on the Aurora MySQL 8.4 supported-plugin allowlist ',
              '(authentication_kerberos.so, auth_socket.so, aws_auth.so, validate_password.so). ',
              'Uninstall it before upgrading: UNINSTALL PLUGIN ', p.name, ';') AS description
FROM mysql.plugin p
WHERE @is_aurora = 1
  AND p.dl IS NOT NULL
  AND p.dl <> ''
  AND p.dl NOT IN (
    'authentication_kerberos.so',
    'auth_socket.so',
    'aws_auth.so',
    'validate_password.so'
  )
  AND (@aurora_unsupported_plugin_count := @aurora_unsupported_plugin_count + 1) IS NOT NULL;

SELECT 'auroraUnsupportedPlugins' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'All dynamically-loaded plugins are on the Aurora 8.4 allowlist' AS description
FROM DUAL
WHERE @is_aurora = 1
  AND @aurora_unsupported_plugin_count = 0;

SET @error_count = @error_count + @aurora_unsupported_plugin_count;

-- ============================================================
-- Check #21: auroraUnsupportedComponents  (Aurora-only)
-- Severity: Error
-- Origin: Aurora upgrade-prechecks.log (auroraUnsupportedComponentsCheck)
-- Model:  ALLOWLIST over mysql.component.component_urn. MySQL 8.0 components
--   (INSTALL COMPONENT) are a separate extension system from plugins;
--   mysql.plugin does not see them. v1 has no component-dimension check at
--   all — this closes that gap on Aurora.
-- Allowlist (Aurora MySQL 8.4): file://component_query_attributes,
--   file://component_reference_cache, file://component_validate_password
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n',
  CASE WHEN @is_aurora = 1
    THEN 'Check #21: Aurora unsupported components'
    ELSE 'Check #21: Aurora unsupported components [SKIP - not Aurora]'
  END,
  '\n------------------------------------------------------------') AS '';

SET @aurora_unsupported_component_count := 0;

SELECT 'auroraUnsupportedComponents' AS check_name,
       'Error' AS severity,
       c.component_urn AS object,
       CONCAT('Installed component ''', c.component_urn,
              ''' is not on the Aurora MySQL 8.4 supported-component allowlist ',
              '(component_query_attributes, component_reference_cache, component_validate_password). ',
              'Uninstall it before upgrading: UNINSTALL COMPONENT ''', c.component_urn, ''';') AS description
FROM mysql.component c
WHERE @is_aurora = 1
  AND c.component_urn NOT IN (
    'file://component_query_attributes',
    'file://component_reference_cache',
    'file://component_validate_password'
  )
  AND (@aurora_unsupported_component_count := @aurora_unsupported_component_count + 1) IS NOT NULL;

SELECT 'auroraUnsupportedComponents' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'All installed components are on the Aurora 8.4 allowlist (or none installed)' AS description
FROM DUAL
WHERE @is_aurora = 1
  AND @aurora_unsupported_component_count = 0;

SET @error_count = @error_count + @aurora_unsupported_component_count;

-- ============================================================
-- Check #22: auroraValidatePasswordPlugin  (Aurora-only)
-- Severity: Warning
-- Origin: Aurora upgrade-prechecks.log (auroraValidatePasswordPluginCheck)
-- Description: 8.4 LTS expects validate_password in *component* form
--   (component_validate_password). If the legacy *plugin* form is still
--   registered in mysql.plugin, Aurora warns. Note this queries the
--   registration table mysql.plugin (not the active state in
--   information_schema.PLUGINS): even a DISABLED registration warns.
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n',
  CASE WHEN @is_aurora = 1
    THEN 'Check #22: Aurora validate_password plugin form'
    ELSE 'Check #22: Aurora validate_password plugin form [SKIP - not Aurora]'
  END,
  '\n------------------------------------------------------------') AS '';

SET @aurora_validate_password_count := 0;

SELECT 'auroraValidatePasswordPlugin' AS check_name,
       'Warning' AS severity,
       p.name AS object,
       CONCAT('The legacy plugin-form ''validate_password'' (library ''', p.dl,
              ''') is registered. MySQL/Aurora 8.4 LTS uses the component form ',
              '''component_validate_password''. Migrate before upgrading: ',
              'UNINSTALL PLUGIN validate_password; then INSTALL COMPONENT ''file://component_validate_password'';') AS description
FROM mysql.plugin p
WHERE @is_aurora = 1
  AND p.name = 'validate_password'
  AND (@aurora_validate_password_count := @aurora_validate_password_count + 1) IS NOT NULL;

SELECT 'auroraValidatePasswordPlugin' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'No legacy plugin-form validate_password registered' AS description
FROM DUAL
WHERE @is_aurora = 1
  AND @aurora_validate_password_count = 0;

SET @warning_count = @warning_count + @aurora_validate_password_count;

-- ============================================================
-- Check #23: auroraDuplicatedEnumValues  (Aurora-only)
-- Severity: Error
-- Origin: Aurora upgrade-prechecks.log
--         (auroraUpgradeCheckForDuplicatedColumnValuesInEnum)
-- Condition: Aurora AND source < 8.0.39 (i.e. Aurora v3.04 – v3.07). From
--   8.0.39 the server itself rejects duplicate ENUM values, so Aurora only
--   runs this on older source engines. Gated by @source_patch < 39.
-- Description: Flags ENUM columns whose definition contains case-insensitive
--   duplicate values (e.g. enum('a','A')); 8.4 rejects these. Pure-SQL
--   approach: split COLUMN_TYPE's enum(...) value list and compare the
--   distinct (lower-cased) count against the total count.
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n',
  CASE
    WHEN @is_aurora = 1 AND @source_patch < 39
      THEN 'Check #23: Aurora duplicated ENUM column values'
    WHEN @is_aurora = 1 AND @source_patch >= 39
      THEN CONCAT('Check #23: Aurora duplicated ENUM column values [SKIP - source 8.0.', @source_patch, ' >= 8.0.39]')
    ELSE 'Check #23: Aurora duplicated ENUM column values [SKIP - not Aurora]'
  END,
  '\n------------------------------------------------------------') AS '';

SET @aurora_dup_enum_count := 0;

-- For each ENUM column, extract the parenthesised value list from
-- COLUMN_TYPE (e.g. "enum('a','b','A')" -> "'a','b','A'"), then:
--   total_vals    = number of comma-separated values
--   distinct_vals = COUNT(DISTINCT lower-cased value)
-- A mismatch (distinct < total) means at least one case-insensitive
-- duplicate. The value list is normalised (lower-cased, single quotes
-- stripped) and turned into a JSON array so JSON_TABLE can split it.
-- Limitation: ENUM values that themselves contain a comma are not split
-- correctly by this pure-SQL approach (documented in the Readme).
SELECT 'auroraDuplicatedEnumValues' AS check_name,
       'Error' AS severity,
       CONCAT(d.TABLE_SCHEMA, '.', d.TABLE_NAME, '.', d.COLUMN_NAME) AS object,
       CONCAT('ENUM column has case-insensitive duplicate values in its definition: ',
              d.COLUMN_TYPE,
              '. MySQL 8.4 rejects duplicate ENUM values. Redefine the column with a ',
              'de-duplicated value list before upgrading.') AS description
FROM (
  SELECT vl.TABLE_SCHEMA, vl.TABLE_NAME, vl.COLUMN_NAME, vl.COLUMN_TYPE,
         -- total number of values = number of comma separators + 1
         (LENGTH(vl.val_list) - LENGTH(REPLACE(vl.val_list, ',', '')) + 1) AS total_vals,
         -- number of DISTINCT lower-cased values
         (
           SELECT COUNT(DISTINCT jt.v)
           FROM JSON_TABLE(
             CONCAT('["', REPLACE(REPLACE(LOWER(vl.val_list), '''', ''), ',', '","'), '"]'),
             '$[*]' COLUMNS (v VARCHAR(512) PATH '$')
           ) AS jt
         ) AS distinct_vals
  FROM (
    SELECT c2.TABLE_SCHEMA, c2.TABLE_NAME, c2.COLUMN_NAME, c2.COLUMN_TYPE,
           -- strip leading "enum(" (5 chars) and trailing ")"
           SUBSTRING(c2.COLUMN_TYPE, 6, CHAR_LENGTH(c2.COLUMN_TYPE) - 6) AS val_list
    FROM information_schema.COLUMNS c2
    WHERE c2.DATA_TYPE = 'enum'
      AND c2.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  ) vl
) d
WHERE @is_aurora = 1
  AND @source_patch < 39
  AND d.distinct_vals < d.total_vals
  AND (@aurora_dup_enum_count := @aurora_dup_enum_count + 1) IS NOT NULL;

SELECT 'auroraDuplicatedEnumValues' AS check_name,
       'PASS' AS severity,
       '' AS object,
       'No ENUM columns with duplicate values detected' AS description
FROM DUAL
WHERE @is_aurora = 1
  AND @source_patch < 39
  AND @aurora_dup_enum_count = 0;

SET @error_count = @error_count + @aurora_dup_enum_count;


-- ============================================================
-- Phase 1 Summary
-- ============================================================

-- Machine-readable markers for the automated runner (mysql-precheck-run.sh).
-- These lines are used to reliably extract summary data without fragile text matching.
SELECT '##PHASE1_SUMMARY_BEGIN##' AS '';

SELECT CONCAT('##PHASE1_COUNTS## ', @error_count, '\t', @warning_count, '\t', @notice_count) AS '';

SELECT CONCAT(
  '============================================================\n',
  'Phase 1 Summary\n',
  '============================================================') AS '';

SELECT @error_count   AS errors,
       @warning_count  AS warnings,
       @notice_count   AS notices,
       'pending'       AS check_table_status;

SELECT CASE
  WHEN @error_count > 0
  THEN CONCAT(@error_count, ' error(s) found (excluding Check #3). Fix before upgrading to MySQL ', @target_version, '.')
  ELSE CONCAT('No errors found (excluding Check #3). Proceed to Phase 2 to complete the assessment.')
END AS recommendation;

-- The instructions below are visible when running Phase 1 SQL standalone.
-- When run via mysql-precheck-run.sh, everything after ##PHASE1_SUMMARY_BEGIN##
-- is stripped from the report, so these instructions do not appear.
SELECT CONCAT(
  '------------------------------------------------------------\n',
  'Next Step: Run Phase 2\n',
  '------------------------------------------------------------\n',
  '1. Extract the CHECK TABLE statements from Check #3 output above\n',
  '   grep ''^##PHASE2## '' phase1-output.log | sed ''s/^##PHASE2## //'' > mysql-precheck-phase2.sql\n',
  '2. Run Phase 2:\n',
  '   mysql -h HOST -u USER -p --batch --raw < mysql-precheck-phase2.sql | awk ''NR == 1 || $0 != "Table\tOp\tMsg_type\tMsg_text"''\n',
  '3. Review: Rows with Msg_type = error/warning are issues to fix.\n',
  '============================================================') AS '';
