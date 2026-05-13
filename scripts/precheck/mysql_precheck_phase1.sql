-- ============================================================
-- RDS MySQL 8.0.28+ → 8.4 Upgrade Precheck — Phase 1
-- ============================================================
--
--  Copyright 2024 Amazon.com, Inc. or its affiliates.
--  All Rights Reserved.
--
--  Licensed under the Apache License, Version 2.0 (the "License").
--  You may not use this file except in compliance with the License.
--  A copy of the License is located at
--
--      http://aws.amazon.com/apache2.0/
--
-- Description: Pure SQL script to detect compatibility issues
--              before upgrading from MySQL 8.0.28+ to MySQL 8.4.
--              Based on MySQL Shell util.checkForServerUpgrade()
--              checks, adapted for standard mysql client execution.
--
-- Scope:       Source 8.0.28 – 8.0.x → Target 8.4.8
--
-- Usage:       See README.md for two-phase execution
--
-- Privileges:  Requires SELECT on information_schema,
--              performance_schema, and mysql databases.
--
-- Note:        This script is READ-ONLY. It executes only
--              SELECT and SET statements. No DDL or DML.
-- ============================================================

-- ------------------------------------------------------------
-- Section: Version Detection and Report Initialization
-- ------------------------------------------------------------

SET @source_version = @@version;
SET @target_version = '8.4.8';

SET @source_major = CAST(SUBSTRING_INDEX(@source_version, '.', 1) AS UNSIGNED);
SET @source_minor = CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(@source_version, '.', 2), '.', -1) AS UNSIGNED);
SET @source_patch_str = SUBSTRING_INDEX(@source_version, '.', -1);
SET @source_patch = CAST(
  CASE
    WHEN @source_patch_str REGEXP '^[0-9]+'
    THEN REGEXP_SUBSTR(@source_patch_str, '^[0-9]+')
    ELSE '0'
  END AS UNSIGNED
);

SET @error_count = 0;
SET @warning_count = 0;
SET @notice_count = 0;

SELECT CONCAT(
  '============================================================\n',
  'MySQL 8.0 to 8.4 Upgrade Precheck Report\n',
  '============================================================\n',
  'Source version: ', @source_version, '\n',
  'Target version: ', @target_version, '\n',
  'Check date:     ', NOW(), '\n',
  '============================================================') AS '';

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

-- ============================================================
-- Section: Privilege Pre-Checks
-- ============================================================

SET @has_perfschema = 0;
SET @has_mysql_db = 0;

SET @has_perfschema = (
  SELECT CASE WHEN
    EXISTS (
      SELECT 1 FROM information_schema.USER_PRIVILEGES
      WHERE GRANTEE = CONCAT('''', REPLACE(CURRENT_USER(), '@', '''@'''), '''')
        AND PRIVILEGE_TYPE = 'SELECT'
    )
    OR EXISTS (
      SELECT 1 FROM information_schema.SCHEMA_PRIVILEGES
      WHERE GRANTEE = CONCAT('''', REPLACE(CURRENT_USER(), '@', '''@'''), '''')
        AND TABLE_SCHEMA = 'performance_schema'
        AND PRIVILEGE_TYPE = 'SELECT'
    )
  THEN 1 ELSE 0 END
);

SELECT 'privilegeCheck' AS check_name,
       'Notice' AS severity,
       'performance_schema' AS object,
       CONCAT('Current user ', CURRENT_USER(),
              ' may not have SELECT access on performance_schema. ',
              'Checks #2, #10, #13 (system variable checks) may fail.') AS description
FROM DUAL
WHERE @has_perfschema = 0;

SET @notice_count = @notice_count +
  CASE WHEN @has_perfschema = 0 THEN 1 ELSE 0 END;

SET @has_mysql_db = (
  SELECT CASE WHEN
    EXISTS (
      SELECT 1 FROM information_schema.USER_PRIVILEGES
      WHERE GRANTEE = CONCAT('''', REPLACE(CURRENT_USER(), '@', '''@'''), '''')
        AND PRIVILEGE_TYPE = 'SELECT'
    )
    OR EXISTS (
      SELECT 1 FROM information_schema.SCHEMA_PRIVILEGES
      WHERE GRANTEE = CONCAT('''', REPLACE(CURRENT_USER(), '@', '''@'''), '''')
        AND TABLE_SCHEMA = 'mysql'
        AND PRIVILEGE_TYPE = 'SELECT'
    )
  THEN 1 ELSE 0 END
);

SELECT 'privilegeCheck' AS check_name,
       'Notice' AS severity,
       'mysql' AS object,
       CONCAT('Current user ', CURRENT_USER(),
              ' may not have SELECT access on mysql database. ',
              'Checks #5, #11 (user account checks) may fail.') AS description
FROM DUAL
WHERE @has_mysql_db = 0;

SET @notice_count = @notice_count +
  CASE WHEN @has_mysql_db = 0 THEN 1 ELSE 0 END;


-- ============================================================
-- Check #1: removedSysVars [SKIP - managed by RDS]
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #1: Removed system variables [SKIP - managed by RDS]', '\n------------------------------------------------------------') AS '';

-- ============================================================
-- Check #2: sysVarsNewDefaults
-- Severity: Warning
-- Description: System variables with new default values in 8.4
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #2: System variables with new default values', '\n------------------------------------------------------------') AS '';

SET @sysvar_new_defaults_count = 0;

SELECT 'sysVarsNewDefaults' AS check_name,
       'Warning' AS severity,
       gv.VARIABLE_NAME AS object,
       CONCAT('System variable ', gv.VARIABLE_NAME, ' has value ''', gv.VARIABLE_VALUE,
              ''' which matches the old default. The default changes in 8.4 to: ',
              CASE gv.VARIABLE_NAME
                WHEN 'binlog_transaction_dependency_tracking' THEN 'WRITESET'
                WHEN 'group_replication_consistency' THEN 'BEFORE_ON_PRIMARY_FAILOVER'
                WHEN 'group_replication_exit_state_action' THEN 'OFFLINE_MODE'
                WHEN 'innodb_adaptive_hash_index' THEN 'OFF'
                WHEN 'innodb_buffer_pool_in_core_file' THEN 'OFF'
                WHEN 'innodb_buffer_pool_instances' THEN 'MAX(1, #vcpu/4)'
                WHEN 'innodb_change_buffering' THEN 'none'
                WHEN 'innodb_doublewrite_files' THEN '2'
                WHEN 'innodb_flush_method' THEN 'O_DIRECT'
                WHEN 'innodb_io_capacity' THEN '10000'
                WHEN 'innodb_io_capacity_max' THEN '2 x innodb_io_capacity'
                WHEN 'innodb_log_buffer_size' THEN '67108864 (64MB)'
                WHEN 'innodb_log_writer_threads' THEN 'OFF (if #vcpu <= 32)'
                WHEN 'innodb_numa_interleave' THEN 'ON'
                WHEN 'innodb_page_cleaners' THEN 'innodb_buffer_pool_instances'
                WHEN 'innodb_parallel_read_threads' THEN 'MAX(#vcpu/8, 4)'
                WHEN 'innodb_read_io_threads' THEN 'MAX(#vcpu/2, 4)'
                WHEN 'innodb_redo_log_capacity' THEN 'MIN(#vcpu/2, 16)GB'
                ELSE 'see MySQL 8.4 documentation'
              END) AS description
FROM performance_schema.global_variables gv
WHERE (
  (gv.VARIABLE_NAME = 'binlog_transaction_dependency_tracking' AND gv.VARIABLE_VALUE = 'COMMIT_ORDER')
  OR (gv.VARIABLE_NAME = 'group_replication_consistency' AND gv.VARIABLE_VALUE = 'EVENTUAL')
  OR (gv.VARIABLE_NAME = 'group_replication_exit_state_action' AND gv.VARIABLE_VALUE = 'READ_ONLY')
  OR (gv.VARIABLE_NAME = 'innodb_adaptive_hash_index' AND UPPER(gv.VARIABLE_VALUE) = 'ON')
  OR (gv.VARIABLE_NAME = 'innodb_buffer_pool_in_core_file' AND UPPER(gv.VARIABLE_VALUE) = 'ON')
  OR (gv.VARIABLE_NAME = 'innodb_buffer_pool_instances' AND gv.VARIABLE_VALUE = '8')
  OR (gv.VARIABLE_NAME = 'innodb_change_buffering' AND gv.VARIABLE_VALUE = 'all')
  OR (gv.VARIABLE_NAME = 'innodb_doublewrite_files' AND gv.VARIABLE_VALUE != '2')
  OR (gv.VARIABLE_NAME = 'innodb_flush_method' AND gv.VARIABLE_VALUE != 'O_DIRECT')
  OR (gv.VARIABLE_NAME = 'innodb_io_capacity' AND gv.VARIABLE_VALUE = '200')
  OR (gv.VARIABLE_NAME = 'innodb_io_capacity_max' AND gv.VARIABLE_VALUE = '2000')
  OR (gv.VARIABLE_NAME = 'innodb_log_buffer_size' AND gv.VARIABLE_VALUE = '16777216')
  OR (gv.VARIABLE_NAME = 'innodb_log_writer_threads' AND UPPER(gv.VARIABLE_VALUE) = 'ON')
  OR (gv.VARIABLE_NAME = 'innodb_numa_interleave' AND UPPER(gv.VARIABLE_VALUE) = 'OFF')
  OR (gv.VARIABLE_NAME = 'innodb_page_cleaners' AND gv.VARIABLE_VALUE = '4')
  OR (gv.VARIABLE_NAME = 'innodb_parallel_read_threads' AND gv.VARIABLE_VALUE = '4')
  OR (gv.VARIABLE_NAME = 'innodb_read_io_threads' AND gv.VARIABLE_VALUE = '4')
  OR (gv.VARIABLE_NAME = 'innodb_redo_log_capacity' AND gv.VARIABLE_VALUE = '104857600')
);

SET @sysvar_new_defaults_count = (
  SELECT COUNT(*)
  FROM performance_schema.global_variables gv
  WHERE (
    (gv.VARIABLE_NAME = 'binlog_transaction_dependency_tracking' AND gv.VARIABLE_VALUE = 'COMMIT_ORDER')
    OR (gv.VARIABLE_NAME = 'group_replication_consistency' AND gv.VARIABLE_VALUE = 'EVENTUAL')
    OR (gv.VARIABLE_NAME = 'group_replication_exit_state_action' AND gv.VARIABLE_VALUE = 'READ_ONLY')
    OR (gv.VARIABLE_NAME = 'innodb_adaptive_hash_index' AND UPPER(gv.VARIABLE_VALUE) = 'ON')
    OR (gv.VARIABLE_NAME = 'innodb_buffer_pool_in_core_file' AND UPPER(gv.VARIABLE_VALUE) = 'ON')
    OR (gv.VARIABLE_NAME = 'innodb_buffer_pool_instances' AND gv.VARIABLE_VALUE = '8')
    OR (gv.VARIABLE_NAME = 'innodb_change_buffering' AND gv.VARIABLE_VALUE = 'all')
    OR (gv.VARIABLE_NAME = 'innodb_doublewrite_files' AND gv.VARIABLE_VALUE != '2')
    OR (gv.VARIABLE_NAME = 'innodb_flush_method' AND gv.VARIABLE_VALUE != 'O_DIRECT')
    OR (gv.VARIABLE_NAME = 'innodb_io_capacity' AND gv.VARIABLE_VALUE = '200')
    OR (gv.VARIABLE_NAME = 'innodb_io_capacity_max' AND gv.VARIABLE_VALUE = '2000')
    OR (gv.VARIABLE_NAME = 'innodb_log_buffer_size' AND gv.VARIABLE_VALUE = '16777216')
    OR (gv.VARIABLE_NAME = 'innodb_log_writer_threads' AND UPPER(gv.VARIABLE_VALUE) = 'ON')
    OR (gv.VARIABLE_NAME = 'innodb_numa_interleave' AND UPPER(gv.VARIABLE_VALUE) = 'OFF')
    OR (gv.VARIABLE_NAME = 'innodb_page_cleaners' AND gv.VARIABLE_VALUE = '4')
    OR (gv.VARIABLE_NAME = 'innodb_parallel_read_threads' AND gv.VARIABLE_VALUE = '4')
    OR (gv.VARIABLE_NAME = 'innodb_read_io_threads' AND gv.VARIABLE_VALUE = '4')
    OR (gv.VARIABLE_NAME = 'innodb_redo_log_capacity' AND gv.VARIABLE_VALUE = '104857600')
  )
);

SELECT 'sysVarsNewDefaults' AS check_name,
       'PASS' AS severity, '' AS object,
       'No system variables using old defaults that change in 8.4 detected' AS description
FROM DUAL WHERE @sysvar_new_defaults_count = 0;

SET @warning_count = @warning_count + @sysvar_new_defaults_count;

-- ============================================================
-- Check #3: checkTableForUpgrade (Phase 2 deferred)
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n',
'Check #3: Issues reported by CHECK TABLE FOR UPGRADE command\n',
'------------------------------------------------------------\n',
'[Phase 2 Required] Copy the SQL below into mysql_precheck_phase2.sql and run it.\n',
'------------------------------------------------------------') AS '';

SELECT CONCAT('CHECK TABLE `', TABLE_SCHEMA, '`.`', TABLE_NAME, '` FOR UPGRADE;')
       AS `-- phase2_check_table_statements`
FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY TABLE_SCHEMA, TABLE_TYPE DESC, TABLE_NAME;


-- ============================================================
-- Check #4: foreignKeyReferences
-- Severity: Warning
-- Description: Foreign keys not referencing a full unique index
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #4: Checks for foreign keys not referencing a full unique index', '\n------------------------------------------------------------') AS '';

SET @fk_ref_count = 0;

SELECT 'foreignKeyReferences' AS check_name, 'Warning' AS severity,
       CONCAT(fk.constraint_schema, '.', fk.table_name, '.', fk.constraint_name) AS object,
       CONCAT('Foreign key ', fk.parent_fk_def, ' references non-unique index on ', fk.REFERENCED_TABLE_NAME) AS description
FROM (
  SELECT rc.constraint_schema, rc.constraint_name, rc.table_name, rc.REFERENCED_TABLE_NAME,
    CONCAT(rc.table_name, '(', GROUP_CONCAT(kc.COLUMN_NAME ORDER BY kc.ORDINAL_POSITION), ')') AS parent_fk_def,
    CONCAT(kc.REFERENCED_TABLE_SCHEMA, '.', kc.REFERENCED_TABLE_NAME, '(',
           GROUP_CONCAT(kc.REFERENCED_COLUMN_NAME ORDER BY kc.POSITION_IN_UNIQUE_CONSTRAINT), ')') AS target_fk_def
  FROM information_schema.REFERENTIAL_CONSTRAINTS rc
  JOIN information_schema.KEY_COLUMN_USAGE kc
    ON rc.constraint_schema = kc.constraint_schema AND rc.constraint_name = kc.constraint_name
   AND rc.constraint_schema = kc.REFERENCED_TABLE_SCHEMA AND rc.REFERENCED_TABLE_NAME = kc.REFERENCED_TABLE_NAME
   AND kc.REFERENCED_TABLE_NAME IS NOT NULL AND kc.REFERENCED_COLUMN_NAME IS NOT NULL
  WHERE rc.constraint_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  GROUP BY rc.constraint_schema, rc.constraint_name, rc.table_name, rc.REFERENCED_TABLE_NAME
) fk
JOIN (
  SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME, '(', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX), ')') AS fk_def,
         SUM(NON_UNIQUE) AS non_unique_count
  FROM information_schema.STATISTICS
  WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys') AND SUB_PART IS NULL
  GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
) idx ON fk.target_fk_def = idx.fk_def
GROUP BY fk.constraint_schema, fk.constraint_name, fk.parent_fk_def, fk.REFERENCED_TABLE_NAME, fk.table_name
HAVING SUM(idx.non_unique_count = 0) = 0;

SET @fk_ref_count = @fk_ref_count + (SELECT COUNT(*) FROM (
  SELECT fk.constraint_name FROM (
    SELECT rc.constraint_schema, rc.constraint_name, rc.table_name, rc.REFERENCED_TABLE_NAME,
      CONCAT(rc.table_name, '(', GROUP_CONCAT(kc.COLUMN_NAME ORDER BY kc.ORDINAL_POSITION), ')') AS parent_fk_def,
      CONCAT(kc.REFERENCED_TABLE_SCHEMA, '.', kc.REFERENCED_TABLE_NAME, '(',
             GROUP_CONCAT(kc.REFERENCED_COLUMN_NAME ORDER BY kc.POSITION_IN_UNIQUE_CONSTRAINT), ')') AS target_fk_def
    FROM information_schema.REFERENTIAL_CONSTRAINTS rc
    JOIN information_schema.KEY_COLUMN_USAGE kc
      ON rc.constraint_schema = kc.constraint_schema AND rc.constraint_name = kc.constraint_name
     AND rc.constraint_schema = kc.REFERENCED_TABLE_SCHEMA AND rc.REFERENCED_TABLE_NAME = kc.REFERENCED_TABLE_NAME
     AND kc.REFERENCED_TABLE_NAME IS NOT NULL AND kc.REFERENCED_COLUMN_NAME IS NOT NULL
    WHERE rc.constraint_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    GROUP BY rc.constraint_schema, rc.constraint_name, rc.table_name, rc.REFERENCED_TABLE_NAME
  ) fk
  JOIN (
    SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME, '(', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX), ')') AS fk_def,
           SUM(NON_UNIQUE) AS non_unique_count
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys') AND SUB_PART IS NULL
    GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
  ) idx ON fk.target_fk_def = idx.fk_def
  GROUP BY fk.constraint_schema, fk.constraint_name, fk.parent_fk_def, fk.REFERENCED_TABLE_NAME, fk.table_name
  HAVING SUM(idx.non_unique_count = 0) = 0
) cnt_a);

-- 4b. Foreign keys referencing partial (prefix) keys
SELECT 'foreignKeyReferences' AS check_name, 'Warning' AS severity,
       CONCAT(fk.constraint_schema, '.', fk.table_name, '.', fk.constraint_name) AS object,
       CONCAT('Foreign key ', fk.fk_definition, ' references partial (prefix) key on ', fk.target_table) AS description
FROM (
  SELECT rc.constraint_schema, rc.constraint_name, rc.referenced_table_name AS target_table,
    CONCAT(kc.table_schema, '.', rc.table_name, '(', GROUP_CONCAT(kc.column_name ORDER BY kc.ORDINAL_POSITION), ')') AS fk_definition,
    CONCAT(kc.referenced_table_schema, '.', kc.referenced_table_name, '(',
           GROUP_CONCAT(kc.referenced_column_name ORDER BY kc.ORDINAL_POSITION), ')') AS col_list,
    rc.table_name
  FROM information_schema.REFERENTIAL_CONSTRAINTS rc
  JOIN information_schema.KEY_COLUMN_USAGE kc
    ON rc.constraint_schema = kc.constraint_schema AND rc.constraint_name = kc.constraint_name
   AND rc.table_name = kc.table_name AND rc.referenced_table_name = kc.referenced_table_name
  WHERE rc.constraint_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  GROUP BY rc.constraint_name, rc.constraint_schema, kc.table_schema, kc.table_name, kc.referenced_table_schema, kc.referenced_table_name
) fk
WHERE fk.col_list NOT IN (
  SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME, '(', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX), ')')
  FROM information_schema.STATISTICS
  WHERE SUB_PART IS NULL AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
);

SET @fk_ref_count = @fk_ref_count + (SELECT COUNT(*) FROM (
  SELECT fk.constraint_name FROM (
    SELECT rc.constraint_schema, rc.constraint_name, rc.referenced_table_name AS target_table,
      CONCAT(kc.referenced_table_schema, '.', kc.referenced_table_name, '(',
             GROUP_CONCAT(kc.referenced_column_name ORDER BY kc.ORDINAL_POSITION), ')') AS col_list, rc.table_name
    FROM information_schema.REFERENTIAL_CONSTRAINTS rc
    JOIN information_schema.KEY_COLUMN_USAGE kc
      ON rc.constraint_schema = kc.constraint_schema AND rc.constraint_name = kc.constraint_name
     AND rc.table_name = kc.table_name AND rc.referenced_table_name = kc.referenced_table_name
    WHERE rc.constraint_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    GROUP BY rc.constraint_name, rc.constraint_schema, kc.table_schema, kc.table_name, kc.referenced_table_schema, kc.referenced_table_name
  ) fk
  WHERE fk.col_list NOT IN (
    SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME, '(', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX), ')')
    FROM information_schema.STATISTICS WHERE SUB_PART IS NULL
      AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
  )
) cnt_b);

SELECT 'foreignKeyReferences' AS check_name, 'PASS' AS severity, '' AS object,
       'No foreign keys referencing non-unique or partial indexes detected' AS description
FROM DUAL WHERE @fk_ref_count = 0;

SET @warning_count = @warning_count + @fk_ref_count;

-- ============================================================
-- Check #5: authMethodUsage
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #5: Check for deprecated or invalid user authentication methods', '\n------------------------------------------------------------') AS '';

SET @auth_method_count = 0;

SELECT 'authMethodUsage' AS check_name,
       CASE u.plugin WHEN 'mysql_native_password' THEN 'Warning' WHEN 'sha256_password' THEN 'Warning' WHEN 'authentication_fido' THEN 'Error' END AS severity,
       CONCAT('''', u.User, '''@''', u.Host, '''') AS object,
       CASE u.plugin
         WHEN 'mysql_native_password' THEN CONCAT('User is using ''mysql_native_password'' which is deprecated as of 8.0.34 and disabled by default in 8.4. Consider switching to caching_sha2_password.')
         WHEN 'sha256_password' THEN CONCAT('Account uses deprecated plugin: ', u.plugin, '. Consider migrating to caching_sha2_password.')
         WHEN 'authentication_fido' THEN CONCAT('Account uses removed plugin: ', u.plugin, '. Must migrate to caching_sha2_password before upgrade.')
       END AS description
FROM mysql.user u WHERE u.plugin IN ('mysql_native_password', 'sha256_password', 'authentication_fido');

SET @auth_method_errors = (SELECT COUNT(*) FROM mysql.user WHERE plugin = 'authentication_fido');
SET @auth_method_warnings = (SELECT COUNT(*) FROM mysql.user WHERE plugin IN ('mysql_native_password', 'sha256_password'));
SET @auth_method_count = @auth_method_errors + @auth_method_warnings;

SELECT 'authMethodUsage' AS check_name, 'PASS' AS severity, '' AS object,
       'No accounts using deprecated or removed authentication plugins detected' AS description
FROM DUAL WHERE @auth_method_count = 0;

SET @error_count = @error_count + @auth_method_errors;
SET @warning_count = @warning_count + @auth_method_warnings;

-- ============================================================
-- Check #6: pluginUsage
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #6: Check for deprecated or removed plugin usage', '\n------------------------------------------------------------') AS '';

SET @plugin_usage_count = 0;

SELECT 'pluginUsage' AS check_name,
       CASE p.PLUGIN_NAME
         WHEN 'authentication_fido' THEN 'Error' WHEN 'keyring_file' THEN 'Error'
         WHEN 'keyring_encrypted_file' THEN 'Error' WHEN 'keyring_oci' THEN 'Error'
         WHEN 'rpl_semi_sync_master' THEN 'Warning' WHEN 'rpl_semi_sync_slave' THEN 'Warning'
       END AS severity,
       p.PLUGIN_NAME AS object,
       CONCAT('Plugin ''', p.PLUGIN_NAME, ''' is ',
              CASE p.PLUGIN_NAME
                WHEN 'authentication_fido' THEN 'removed in 8.4. Use authentication_webauthn instead.'
                WHEN 'keyring_file' THEN 'removed in 8.4. Use component_keyring_file instead.'
                WHEN 'keyring_encrypted_file' THEN 'removed in 8.4. Use component_encrypted_keyring_file instead.'
                WHEN 'keyring_oci' THEN 'removed in 8.4. Use component_keyring_oci instead.'
                WHEN 'rpl_semi_sync_master' THEN 'deprecated. Use rpl_semi_sync_source instead.'
                WHEN 'rpl_semi_sync_slave' THEN 'deprecated. Use rpl_semi_sync_replica instead.'
              END) AS description
FROM information_schema.PLUGINS p
WHERE p.PLUGIN_STATUS = 'ACTIVE'
  AND p.PLUGIN_NAME IN ('authentication_fido','keyring_file','keyring_encrypted_file','keyring_oci','rpl_semi_sync_master','rpl_semi_sync_slave');

SET @plugin_usage_errors = (SELECT COUNT(*) FROM information_schema.PLUGINS WHERE PLUGIN_STATUS='ACTIVE' AND PLUGIN_NAME IN ('authentication_fido','keyring_file','keyring_encrypted_file','keyring_oci'));
SET @plugin_usage_warnings = (SELECT COUNT(*) FROM information_schema.PLUGINS WHERE PLUGIN_STATUS='ACTIVE' AND PLUGIN_NAME IN ('rpl_semi_sync_master','rpl_semi_sync_slave'));
SET @plugin_usage_count = @plugin_usage_errors + @plugin_usage_warnings;

SELECT 'pluginUsage' AS check_name, 'PASS' AS severity, '' AS object,
       'No deprecated or removed active plugins detected' AS description
FROM DUAL WHERE @plugin_usage_count = 0;

SET @error_count = @error_count + @plugin_usage_errors;
SET @warning_count = @warning_count + @plugin_usage_warnings;

-- ============================================================
-- Check #7: deprecatedDefaultAuth [SKIP - managed by RDS]
-- ============================================================
SELECT CONCAT('------------------------------------------------------------\n', 'Check #7: Deprecated default authentication methods [SKIP - managed by RDS]', '\n------------------------------------------------------------') AS '';

-- ============================================================
-- Check #8: deprecatedRouterAuthMethod [SKIP - RDS does not use Router]
-- ============================================================
SELECT CONCAT('------------------------------------------------------------\n', 'Check #8: Deprecated Router authentication methods [SKIP - managed by RDS]', '\n------------------------------------------------------------') AS '';


-- ============================================================
-- Check #9: columnDefinition — FLOAT/DOUBLE with AUTO_INCREMENT
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #9: Checks for errors in column definitions', '\n------------------------------------------------------------') AS '';

SET @col_def_count = 0;

SELECT 'columnDefinition' AS check_name, 'Error' AS severity,
       CONCAT(c.TABLE_SCHEMA, '.', c.TABLE_NAME, '.', c.COLUMN_NAME) AS object,
       CONCAT(UPPER(c.COLUMN_TYPE), ' column with AUTO_INCREMENT') AS description
FROM information_schema.COLUMNS c
WHERE c.DATA_TYPE IN ('float', 'double') AND c.EXTRA LIKE '%auto_increment%'
  AND c.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');

SET @col_def_count = (SELECT COUNT(*) FROM information_schema.COLUMNS c
  WHERE c.DATA_TYPE IN ('float', 'double') AND c.EXTRA LIKE '%auto_increment%'
    AND c.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys'));

SELECT 'columnDefinition' AS check_name, 'PASS' AS severity, '' AS object,
       'No FLOAT/DOUBLE columns with AUTO_INCREMENT detected' AS description
FROM DUAL WHERE @col_def_count = 0;

SET @error_count = @error_count + @col_def_count;

-- ============================================================
-- Check #10: sysVarsAllowedValues
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #10: Check for allowed values in system variables', '\n------------------------------------------------------------') AS '';

SET @sysvar_allowed_count = 0;

SELECT 'sysVarsAllowedValues' AS check_name, 'Warning' AS severity, gv.VARIABLE_NAME AS object,
       CONCAT('System variable ', gv.VARIABLE_NAME, ' has value ''', gv.VARIABLE_VALUE,
              ''' which is no longer valid in MySQL 8.4. Only ROW format is supported.') AS description
FROM performance_schema.global_variables gv
WHERE gv.VARIABLE_NAME = 'binlog_format' AND gv.VARIABLE_VALUE IN ('STATEMENT', 'MIXED');

SET @sysvar_allowed_count = @sysvar_allowed_count + (
  SELECT COUNT(*) FROM performance_schema.global_variables gv
  WHERE gv.VARIABLE_NAME = 'binlog_format' AND gv.VARIABLE_VALUE IN ('STATEMENT', 'MIXED'));

SELECT 'sysVarsAllowedValues' AS check_name, 'PASS' AS severity, '' AS object,
       'No system variables with disallowed values for 8.4 detected' AS description
FROM DUAL WHERE @sysvar_allowed_count = 0;

SET @warning_count = @warning_count + @sysvar_allowed_count;

-- ============================================================
-- Check #11: invalidPrivileges
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #11: Checks for user privileges that will be removed', '\n------------------------------------------------------------') AS '';

SET @invalid_priv_count = 0;

SELECT 'invalidPrivileges' AS check_name, 'Notice' AS severity,
       CONCAT('''', gp.USER, '''@''', gp.HOST, '''') AS object,
       CONCAT('Account holds privilege that will be removed during upgrade: ', gp.PRIV) AS description
FROM mysql.global_grants gp WHERE gp.PRIV IN ('SET_USER_ID');

SET @invalid_priv_count = (SELECT COUNT(*) FROM mysql.global_grants gp WHERE gp.PRIV IN ('SET_USER_ID'));

SELECT 'invalidPrivileges' AS check_name, 'PASS' AS severity, '' AS object,
       'No accounts holding removed privileges detected' AS description
FROM DUAL WHERE @invalid_priv_count = 0;

SET @notice_count = @notice_count + @invalid_priv_count;

-- ============================================================
-- Check #12: partitionsWithPrefixKeys
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #12: Checks for partitions by key using columns with prefix key indexes', '\n------------------------------------------------------------') AS '';

SET @prefix_key_part_count = 0;

SELECT 'partitionsWithPrefixKeys' AS check_name, 'Error' AS severity,
       CONCAT(s.TABLE_SCHEMA, '.', s.TABLE_NAME) AS object,
       CONCAT('Partitioned table uses prefix key column(s): ', GROUP_CONCAT(DISTINCT s.COLUMN_NAME)) AS description
FROM information_schema.STATISTICS s
INNER JOIN information_schema.PARTITIONS p ON s.TABLE_SCHEMA = p.TABLE_SCHEMA AND s.TABLE_NAME = p.TABLE_NAME
WHERE s.SUB_PART IS NOT NULL AND p.PARTITION_METHOD = 'KEY'
  AND (INSTR(p.PARTITION_EXPRESSION, CONCAT('`', s.COLUMN_NAME, '`')) > 0 OR p.PARTITION_EXPRESSION IS NULL)
  AND s.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
GROUP BY s.TABLE_SCHEMA, s.TABLE_NAME;

SET @prefix_key_part_count = (SELECT COUNT(*) FROM (
  SELECT s.TABLE_SCHEMA, s.TABLE_NAME
  FROM information_schema.STATISTICS s
  INNER JOIN information_schema.PARTITIONS p ON s.TABLE_SCHEMA = p.TABLE_SCHEMA AND s.TABLE_NAME = p.TABLE_NAME
  WHERE s.SUB_PART IS NOT NULL AND p.PARTITION_METHOD = 'KEY'
    AND (INSTR(p.PARTITION_EXPRESSION, CONCAT('`', s.COLUMN_NAME, '`')) > 0 OR p.PARTITION_EXPRESSION IS NULL)
    AND s.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  GROUP BY s.TABLE_SCHEMA, s.TABLE_NAME
) AS prefix_key_sub);

SELECT 'partitionsWithPrefixKeys' AS check_name, 'PASS' AS severity, '' AS object,
       'No partitions using prefix key columns detected' AS description
FROM DUAL WHERE @prefix_key_part_count = 0;

SET @error_count = @error_count + @prefix_key_part_count;

-- ============================================================
-- Check #13: nonInclusiveLanguage
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #13: RDS checked for the use of non-inclusive language in SQL statements', '\n------------------------------------------------------------') AS '';

SET @non_inclusive_count = 0;

SELECT 'nonInclusiveLanguage' AS check_name, 'Warning' AS severity, gv.VARIABLE_NAME AS object,
       CONCAT('System variable ', gv.VARIABLE_NAME, ' uses non-inclusive terminology. ',
              CASE gv.VARIABLE_NAME
                WHEN 'init_slave' THEN 'Use init_replica instead.'
                WHEN 'log_slave_updates' THEN 'Use log_replica_updates instead.'
                WHEN 'log_slow_slave_statements' THEN 'Use log_slow_replica_statements instead.'
                ELSE 'Consider using inclusive alternatives.'
              END, ' Current value: ', gv.VARIABLE_VALUE) AS description
FROM performance_schema.global_variables gv
WHERE gv.VARIABLE_NAME IN ('init_slave', 'log_slave_updates', 'log_slow_slave_statements', 'slave_rows_search_algorithms')
  AND gv.VARIABLE_VALUE != '';

SET @non_inclusive_count = @non_inclusive_count + (
  SELECT COUNT(*) FROM performance_schema.global_variables gv
  WHERE gv.VARIABLE_NAME IN ('init_slave', 'log_slave_updates', 'log_slow_slave_statements', 'slave_rows_search_algorithms')
    AND gv.VARIABLE_VALUE != '');

SELECT 'nonInclusiveLanguage' AS check_name, 'Warning' AS severity,
       CONCAT(r.ROUTINE_SCHEMA, '.', r.ROUTINE_NAME) AS object,
       CONCAT(r.ROUTINE_TYPE, ' contains deprecated replication command syntax (MASTER/SLAVE). ',
              'Replace with inclusive equivalents.') AS description
FROM information_schema.ROUTINES r
WHERE r.ROUTINE_SCHEMA NOT IN ('mysql', 'sys')
  AND LOWER(r.ROUTINE_DEFINITION) REGEXP
    '(show[[:space:]]+(master|slave)[[:space:]]+status|reset[[:space:]]+(master|slave)|change[[:space:]]+master[[:space:]]+to|(start|stop)[[:space:]]+slave|show[[:space:]]+slave[[:space:]]+hosts)[[:space:]]*;'
LIMIT 50;

SET @non_inclusive_count = @non_inclusive_count + (
  SELECT COUNT(*) FROM information_schema.ROUTINES r
  WHERE r.ROUTINE_SCHEMA NOT IN ('mysql', 'sys')
    AND LOWER(r.ROUTINE_DEFINITION) REGEXP
      '(show[[:space:]]+(master|slave)[[:space:]]+status|reset[[:space:]]+(master|slave)|change[[:space:]]+master[[:space:]]+to|(start|stop)[[:space:]]+slave|show[[:space:]]+slave[[:space:]]+hosts)[[:space:]]*;');

SELECT 'nonInclusiveLanguage' AS check_name, 'PASS' AS severity, '' AS object,
       'No non-inclusive language usage detected' AS description
FROM DUAL WHERE @non_inclusive_count = 0;

SET @warning_count = @warning_count + @non_inclusive_count;

-- ============================================================
-- Check #14: memcachedPlugin
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #14: memcached plugin needs to be uninstalled before upgrade', '\n------------------------------------------------------------') AS '';

SET @memcached_count = 0;

SELECT 'memcachedPlugin' AS check_name, 'Error' AS severity, p.PLUGIN_NAME AS object,
       CONCAT('daemon_memcached plugin is active and must be uninstalled before upgrading. Status: ', p.PLUGIN_STATUS) AS description
FROM information_schema.PLUGINS p WHERE p.PLUGIN_NAME = 'daemon_memcached' AND p.PLUGIN_STATUS = 'ACTIVE';

SET @memcached_count = (SELECT COUNT(*) FROM information_schema.PLUGINS p WHERE p.PLUGIN_NAME = 'daemon_memcached' AND p.PLUGIN_STATUS = 'ACTIVE');

SELECT 'memcachedPlugin' AS check_name, 'PASS' AS severity, '' AS object,
       'No active daemon_memcached plugin detected' AS description
FROM DUAL WHERE @memcached_count = 0;

SET @error_count = @error_count + @memcached_count;

-- ============================================================
-- Check #15: sysSchemaObjects
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #15: Detect system objects created as tables in sys schema', '\n------------------------------------------------------------') AS '';

SET @sys_schema_objects_count = 0;

SELECT 'sysSchemaObjects' AS check_name, 'Error' AS severity,
       CONCAT('sys.', t.TABLE_NAME) AS object,
       CONCAT('User-created base table ''', t.TABLE_NAME, ''' found in sys schema.') AS description
FROM information_schema.TABLES t
WHERE t.TABLE_SCHEMA = 'sys' AND t.TABLE_TYPE = 'BASE TABLE' AND t.TABLE_NAME != 'sys_config';

SET @sys_schema_objects_count = (SELECT COUNT(*) FROM information_schema.TABLES t
  WHERE t.TABLE_SCHEMA = 'sys' AND t.TABLE_TYPE = 'BASE TABLE' AND t.TABLE_NAME != 'sys_config');

SELECT 'sysSchemaObjects' AS check_name, 'PASS' AS severity, '' AS object,
       'No user-created base tables in sys schema detected' AS description
FROM DUAL WHERE @sys_schema_objects_count = 0;

SET @error_count = @error_count + @sys_schema_objects_count;


-- ============================================================
-- Check #16: dollarSignName (source_patch < 31 only)
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', CASE WHEN @source_patch < 31 THEN 'Check #16: Dollar sign object names' ELSE 'Check #16: Dollar sign object names [SKIP - source >= 8.0.31]' END, '\n------------------------------------------------------------') AS '';

SET @dollar_sign_count = 0;

SELECT check_name, severity, object, description FROM (
  SELECT 'dollarSignName' AS check_name, 'Warning' AS severity, s.SCHEMA_NAME AS object, 'Schema name starts with $ sign' AS description
  FROM information_schema.SCHEMATA s WHERE @source_patch < 31 AND s.SCHEMA_NAME LIKE '$%'
    AND s.SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  UNION ALL
  SELECT 'dollarSignName', 'Warning', CONCAT(t.TABLE_SCHEMA, '.', t.TABLE_NAME), 'Table name starts with $ sign'
  FROM information_schema.TABLES t WHERE @source_patch < 31 AND t.TABLE_NAME LIKE '$%'
    AND t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  UNION ALL
  SELECT 'dollarSignName', 'Warning', CONCAT(c.TABLE_SCHEMA, '.', c.TABLE_NAME, '.', c.COLUMN_NAME), 'Column name starts with $ sign'
  FROM information_schema.COLUMNS c WHERE @source_patch < 31 AND c.COLUMN_NAME LIKE '$%'
    AND c.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  UNION ALL
  SELECT 'dollarSignName', 'Warning', CONCAT(r.ROUTINE_SCHEMA, '.', r.ROUTINE_NAME), CONCAT(r.ROUTINE_TYPE, ' name starts with $ sign')
  FROM information_schema.ROUTINES r WHERE @source_patch < 31 AND r.ROUTINE_NAME LIKE '$%'
    AND r.ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
) AS dollar_sign_results;

SET @dollar_sign_count = (SELECT COUNT(*) FROM (
  SELECT 1 FROM information_schema.SCHEMATA s WHERE @source_patch < 31 AND s.SCHEMA_NAME LIKE '$%' AND s.SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL SELECT 1 FROM information_schema.TABLES t WHERE @source_patch < 31 AND t.TABLE_NAME LIKE '$%' AND t.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL SELECT 1 FROM information_schema.COLUMNS c WHERE @source_patch < 31 AND c.COLUMN_NAME LIKE '$%' AND c.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL SELECT 1 FROM information_schema.ROUTINES r WHERE @source_patch < 31 AND r.ROUTINE_NAME LIKE '$%' AND r.ROUTINE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
) AS d);

SELECT 'dollarSignName' AS check_name, 'PASS' AS severity, '' AS object,
       CASE WHEN @source_patch >= 31 THEN CONCAT('SKIP: Source 8.0.', @source_patch, ' >= 8.0.31')
            ELSE 'No object names starting with $ sign detected' END AS description
FROM DUAL WHERE @dollar_sign_count = 0;

SET @warning_count = @warning_count + @dollar_sign_count;

-- ============================================================
-- Check #17: reservedKeywords (source_patch < 31 only)
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', 'Check #17: Reserved keywords', '\n------------------------------------------------------------') AS '';

SET @reserved_kw_count = 0;

SELECT check_name, severity, object, description FROM (
  SELECT 'reservedKeywords' AS check_name, 'Warning' AS severity, s.SCHEMA_NAME AS object,
         CONCAT('Schema name `', s.SCHEMA_NAME, '` conflicts with reserved keyword in 8.0.31') AS description
  FROM information_schema.SCHEMATA s WHERE UPPER(s.SCHEMA_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31
    AND s.SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL
  SELECT 'reservedKeywords', 'Warning', CONCAT(t.TABLE_SCHEMA, '.', t.TABLE_NAME),
         CONCAT('Table name `', t.TABLE_NAME, '` conflicts with reserved keyword in 8.0.31')
  FROM information_schema.TABLES t WHERE UPPER(t.TABLE_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31
    AND t.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL
  SELECT 'reservedKeywords', 'Warning', CONCAT(c.TABLE_SCHEMA, '.', c.TABLE_NAME, '.', c.COLUMN_NAME),
         CONCAT('Column name `', c.COLUMN_NAME, '` conflicts with reserved keyword in 8.0.31')
  FROM information_schema.COLUMNS c WHERE UPPER(c.COLUMN_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31
    AND c.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL
  SELECT 'reservedKeywords', 'Warning', CONCAT(r.ROUTINE_SCHEMA, '.', r.ROUTINE_NAME),
         CONCAT(r.ROUTINE_TYPE, ' name `', r.ROUTINE_NAME, '` conflicts with reserved keyword in 8.0.31')
  FROM information_schema.ROUTINES r WHERE UPPER(r.ROUTINE_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31
    AND r.ROUTINE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL
  SELECT 'reservedKeywords', 'Warning', CONCAT(tr.TRIGGER_SCHEMA, '.', tr.TRIGGER_NAME),
         CONCAT('Trigger name `', tr.TRIGGER_NAME, '` conflicts with reserved keyword in 8.0.31')
  FROM information_schema.TRIGGERS tr WHERE UPPER(tr.TRIGGER_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31
    AND tr.TRIGGER_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL
  SELECT 'reservedKeywords', 'Warning', CONCAT(v.TABLE_SCHEMA, '.', v.TABLE_NAME),
         CONCAT('View name `', v.TABLE_NAME, '` conflicts with reserved keyword in 8.0.31')
  FROM information_schema.VIEWS v WHERE UPPER(v.TABLE_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31
    AND v.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL
  SELECT 'reservedKeywords', 'Warning', CONCAT(e.EVENT_SCHEMA, '.', e.EVENT_NAME),
         CONCAT('Event name `', e.EVENT_NAME, '` conflicts with reserved keyword in 8.0.31')
  FROM information_schema.EVENTS e WHERE UPPER(e.EVENT_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31
    AND e.EVENT_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
) AS reserved_kw_results;

SET @reserved_kw_count = (SELECT COUNT(*) FROM (
  SELECT 1 FROM information_schema.SCHEMATA s WHERE UPPER(s.SCHEMA_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31 AND s.SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL SELECT 1 FROM information_schema.TABLES t WHERE UPPER(t.TABLE_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31 AND t.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL SELECT 1 FROM information_schema.COLUMNS c WHERE UPPER(c.COLUMN_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31 AND c.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL SELECT 1 FROM information_schema.ROUTINES r WHERE UPPER(r.ROUTINE_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31 AND r.ROUTINE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL SELECT 1 FROM information_schema.TRIGGERS tr WHERE UPPER(tr.TRIGGER_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31 AND tr.TRIGGER_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL SELECT 1 FROM information_schema.VIEWS v WHERE UPPER(v.TABLE_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31 AND v.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  UNION ALL SELECT 1 FROM information_schema.EVENTS e WHERE UPPER(e.EVENT_NAME) IN ('FULL','INTERSECT') AND @source_patch < 31 AND e.EVENT_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
) AS k);

SELECT 'reservedKeywords' AS check_name, 'PASS' AS severity, '' AS object,
       CASE WHEN @source_patch >= 31 THEN CONCAT('SKIP: Source 8.0.', @source_patch, ' >= 8.0.31')
            ELSE 'No object names conflicting with reserved keywords detected' END AS description
FROM DUAL WHERE @reserved_kw_count = 0;

SET @warning_count = @warning_count + @reserved_kw_count;

-- ============================================================
-- Check #18: deprecatedTemporalDelimiter (source_patch < 29)
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', CASE WHEN @source_patch < 29 THEN 'Check #18: Deprecated temporal delimiter' ELSE 'Check #18: Deprecated temporal delimiter [SKIP - source >= 8.0.29]' END, '\n------------------------------------------------------------') AS '';

SET @deprecated_temporal_delim_count = 0;

SELECT 'deprecatedTemporalDelimiter' AS check_name, 'Error' AS severity,
       CONCAT(p.TABLE_SCHEMA, '.', p.TABLE_NAME, '#', p.PARTITION_NAME) AS object,
       CONCAT('Partition ', p.PARTITION_NAME, ' on column `', c.COLUMN_NAME, '` (', c.COLUMN_TYPE, ') uses deprecated temporal delimiters: ', p.PARTITION_DESCRIPTION) AS description
FROM information_schema.PARTITIONS p
LEFT JOIN information_schema.COLUMNS c ON p.TABLE_SCHEMA = c.TABLE_SCHEMA AND p.TABLE_NAME = c.TABLE_NAME
  AND p.PARTITION_EXPRESSION LIKE CONCAT('%`', c.COLUMN_NAME, '`%')
WHERE @source_patch < 29 AND p.PARTITION_METHOD IN ('RANGE', 'RANGE COLUMNS')
  AND p.PARTITION_DESCRIPTION IS NOT NULL AND p.PARTITION_DESCRIPTION != 'MAXVALUE'
  AND p.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND ((c.COLUMN_TYPE = 'date' AND NOT p.PARTITION_DESCRIPTION REGEXP '^(\'[0-9]{4}-[0-9]{2}-[0-9]{2}\')(,\'[0-9]{4}-[0-9]{2}-[0-9]{2}\')*$')
    OR ((c.COLUMN_TYPE = 'datetime' OR c.COLUMN_TYPE = 'timestamp')
        AND NOT p.PARTITION_DESCRIPTION REGEXP '^(\'[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]*)?\')(,\'[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]*)?\')*$'));

SET @deprecated_temporal_delim_count = (SELECT COUNT(*) FROM (
  SELECT p.TABLE_SCHEMA, p.TABLE_NAME, p.PARTITION_NAME
  FROM information_schema.PARTITIONS p
  LEFT JOIN information_schema.COLUMNS c ON p.TABLE_SCHEMA = c.TABLE_SCHEMA AND p.TABLE_NAME = c.TABLE_NAME
    AND p.PARTITION_EXPRESSION LIKE CONCAT('%`', c.COLUMN_NAME, '`%')
  WHERE @source_patch < 29 AND p.PARTITION_METHOD IN ('RANGE', 'RANGE COLUMNS')
    AND p.PARTITION_DESCRIPTION IS NOT NULL AND p.PARTITION_DESCRIPTION != 'MAXVALUE'
    AND p.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    AND ((c.COLUMN_TYPE = 'date' AND NOT p.PARTITION_DESCRIPTION REGEXP '^(\'[0-9]{4}-[0-9]{2}-[0-9]{2}\')(,\'[0-9]{4}-[0-9]{2}-[0-9]{2}\')*$')
      OR ((c.COLUMN_TYPE = 'datetime' OR c.COLUMN_TYPE = 'timestamp')
          AND NOT p.PARTITION_DESCRIPTION REGEXP '^(\'[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]*)?\')(,\'[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]*)?\')*$'))
) AS t);

SELECT 'deprecatedTemporalDelimiter' AS check_name, 'PASS' AS severity, '' AS object,
       CASE WHEN @source_patch >= 29 THEN CONCAT('SKIP: Source 8.0.', @source_patch, ' >= 8.0.29')
            ELSE 'No partitions using deprecated temporal delimiters detected' END AS description
FROM DUAL WHERE @deprecated_temporal_delim_count = 0;

SET @error_count = @error_count + @deprecated_temporal_delim_count;

-- ============================================================
-- Check #19: spatialIndex (source_patch 3–40)
-- ============================================================

SELECT CONCAT('------------------------------------------------------------\n', CASE WHEN @source_patch >= 3 AND @source_patch <= 40 THEN 'Check #19: Spatial index' ELSE CONCAT('Check #19: Spatial index [SKIP - source 8.0.', @source_patch, ' outside 8.0.3-8.0.40]') END, '\n------------------------------------------------------------') AS '';

SET @spatial_index_count = 0;

SELECT 'spatialIndex' AS check_name, 'Warning' AS severity,
       CONCAT(t.TABLE_SCHEMA, '.', t.TABLE_NAME, '.', s.INDEX_NAME) AS object,
       'InnoDB table has spatial index that must be rebuilt before upgrading to 8.4 (affected: 8.0.3-8.0.40)' AS description
FROM information_schema.STATISTICS s
JOIN information_schema.TABLES t ON s.TABLE_SCHEMA = t.TABLE_SCHEMA AND s.TABLE_NAME = t.TABLE_NAME
WHERE s.INDEX_TYPE = 'SPATIAL' AND t.ENGINE = 'InnoDB'
  AND s.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND @source_patch >= 3 AND @source_patch <= 40
GROUP BY t.TABLE_SCHEMA, t.TABLE_NAME, s.INDEX_NAME;

SET @spatial_index_count = (SELECT CASE
  WHEN @source_patch >= 3 AND @source_patch <= 40 THEN (
    SELECT COUNT(DISTINCT CONCAT(s.TABLE_SCHEMA, '.', s.TABLE_NAME, '.', s.INDEX_NAME))
    FROM information_schema.STATISTICS s
    JOIN information_schema.TABLES t ON s.TABLE_SCHEMA = t.TABLE_SCHEMA AND s.TABLE_NAME = t.TABLE_NAME
    WHERE s.INDEX_TYPE = 'SPATIAL' AND t.ENGINE = 'InnoDB'
      AND s.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys'))
  ELSE 0 END);

SELECT 'spatialIndex' AS check_name, 'PASS' AS severity, '' AS object,
       CONCAT('No InnoDB spatial index issues detected',
              CASE WHEN @source_patch < 3 OR @source_patch > 40
                THEN CONCAT(' (source 8.0.', @source_patch, ' outside affected range)')
                ELSE '' END) AS description
FROM DUAL WHERE @spatial_index_count = 0;

SET @warning_count = @warning_count + @spatial_index_count;

-- ============================================================
-- Phase 1 Summary
-- ============================================================

SELECT CONCAT(
  '============================================================\n',
  'Phase 1 Summary\n',
  '============================================================') AS '';

SELECT @error_count AS errors, @warning_count AS warnings, @notice_count AS notices, 'pending' AS check_table_status;

SELECT CASE
  WHEN @error_count > 0
  THEN CONCAT(@error_count, ' error(s) found (excluding Check #3). Fix before upgrading to MySQL ', @target_version, '.')
  ELSE CONCAT('No errors found (excluding Check #3). Proceed to Phase 2 to complete the assessment.')
END AS recommendation;

SELECT CONCAT(
  '------------------------------------------------------------\n',
  'Next Step: Run Phase 2\n',
  '------------------------------------------------------------\n',
  '1. Copy the CHECK TABLE statements from Check #3 output above\n',
  '2. Save them as mysql_precheck_phase2.sql\n',
  '   Or use: mysql ... < mysql_precheck_phase1.sql | grep "^CHECK TABLE" > mysql_precheck_phase2.sql\n',
  '3. Run Phase 2:\n',
  '   mysql -h HOST -u USER -p --batch --raw < mysql_precheck_phase2.sql\n',
  '4. Review: Rows with Msg_type = error/warning are issues to fix.\n',
  '============================================================') AS '';
