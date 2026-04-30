-- ============================================================
-- Application Validation Template for Post-Upgrade Testing
-- ============================================================
--
-- Customize this file with your application-specific queries.
-- Run after upgrade to verify application compatibility.
--
-- Usage:
--   mysql -h <endpoint> -u <user> -p --batch < app_validate_template.sql
--
-- Instructions:
--   1. Copy this file to app_validate.sql
--   2. Replace the example queries with your critical application queries
--   3. Run against the green environment BEFORE switchover
--   4. Run again after switchover to confirm production behavior
-- ============================================================

SELECT '=== Application Validation ===' AS '';

-- ============================================================
-- Section 1: Critical Read Queries
-- Add your most important SELECT queries here.
-- These should return expected results after upgrade.
-- ============================================================

SELECT '--- Section 1: Critical Read Queries ---' AS '';

-- Example: Verify a key table is accessible and has expected row count
-- SELECT 'orders_table_count' AS check_name,
--        CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL' END AS status,
--        COUNT(*) AS detail
-- FROM mydb.orders;

-- Example: Verify a view still works
-- SELECT 'monthly_report_view' AS check_name,
--        CASE WHEN COUNT(*) >= 0 THEN 'PASS' ELSE 'FAIL' END AS status,
--        COUNT(*) AS detail
-- FROM mydb.v_monthly_report LIMIT 1;

-- ============================================================
-- Section 2: Stored Procedure / Function Tests
-- Verify stored procedures and functions execute correctly.
-- ============================================================

SELECT '--- Section 2: Stored Procedures ---' AS '';

-- Example: Call a stored procedure and verify it doesn't error
-- CALL mydb.sp_daily_summary(@result);
-- SELECT 'sp_daily_summary' AS check_name,
--        CASE WHEN @result IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS status,
--        @result AS detail;

-- ============================================================
-- Section 3: Authentication & Connectivity
-- Verify application users can connect with expected auth plugins.
-- ============================================================

SELECT '--- Section 3: Authentication ---' AS '';

SELECT 'current_auth_plugin' AS check_name,
       'INFO' AS status,
       CONCAT(CURRENT_USER(), ' via ', (
         SELECT plugin FROM mysql.user
         WHERE CONCAT(User, '@', Host) = CURRENT_USER()
       )) AS detail;

-- ============================================================
-- Section 4: Character Set & Collation
-- Verify character set behavior hasn't changed.
-- ============================================================

SELECT '--- Section 4: Character Set ---' AS '';

SELECT 'default_charset' AS check_name,
       CASE WHEN @@character_set_server = 'utf8mb4' THEN 'PASS' ELSE 'WARNING' END AS status,
       @@character_set_server AS detail;

SELECT 'default_collation' AS check_name,
       'INFO' AS status,
       @@collation_server AS detail;

-- ============================================================
-- Section 5: Performance Baseline Queries
-- Run key queries and record execution time for comparison.
-- ============================================================

SELECT '--- Section 5: Performance Baseline ---' AS '';

-- Example: Time a critical query
-- SET @start = NOW(6);
-- SELECT COUNT(*) INTO @cnt FROM mydb.large_table WHERE status = 'active';
-- SET @elapsed = TIMESTAMPDIFF(MICROSECOND, @start, NOW(6)) / 1000000;
-- SELECT 'large_table_query' AS check_name,
--        CASE WHEN @elapsed < 5.0 THEN 'PASS' ELSE 'WARNING' END AS status,
--        CONCAT(@cnt, ' rows in ', @elapsed, 's') AS detail;

SELECT '=== Application Validation Complete ===' AS '';
