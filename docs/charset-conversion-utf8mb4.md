# Character Set Conversion to utf8mb4 (Optional)

> **This is NOT required for the MySQL 8.0→8.4 upgrade.** The `utf8mb3` character set still works in MySQL 8.4 (though deprecated). This guide is for teams that want to convert to `utf8mb4` during the upgrade maintenance window.

## When to Convert

| Scenario | Recommendation |
|----------|---------------|
| Application needs emoji / full Unicode support | Convert |
| Regulatory or compliance requirement for utf8mb4 | Convert |
| Planning to stay on 8.4 long-term (utf8mb3 removal in future) | Convert now to avoid future migration |
| No immediate need, just upgrading engine version | Skip — do it separately when ready |

## Key Considerations

### Row Size Impact
- `utf8mb3` uses max 3 bytes per character; `utf8mb4` uses max 4 bytes
- A `VARCHAR(255)` column goes from 765 bytes → 1020 bytes
- Tables with many VARCHAR columns may hit the InnoDB row size limit (8126 bytes)
- **Always check row sizes before converting**

### Index Length Impact
- InnoDB index key prefix limit: 3072 bytes
- A `VARCHAR(768)` with utf8mb3 = 2304 bytes (OK) → utf8mb4 = 3072 bytes (at limit)
- Indexes on `VARCHAR(769+)` columns will fail after conversion

### Replication Compatibility (Blue/Green)
- If converting charset on the green environment during a B/G deployment:
  - Set `binlog_format = ROW` on source (blue) parameter group
  - Set `replica_type_conversions = ALL_LOSSY,ALL_NON_LOSSY` on target (green) parameter group
  - Without this, replication fails with `Column N cannot be converted from type 'varchar(X bytes)' to type 'varchar(Y bytes) utf8mb4'`

## Conversion Steps

### Step 1: Identify Non-utf8mb4 Objects

```sql
-- Databases
SELECT SCHEMA_NAME, default_character_set_name, DEFAULT_COLLATION_NAME
FROM information_schema.SCHEMATA
WHERE default_character_set_name != 'utf8mb4'
  AND SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');

-- Tables/Columns
SELECT DISTINCT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, character_set_name
FROM information_schema.COLUMNS
WHERE character_set_name IS NOT NULL
  AND character_set_name != 'utf8mb4'
  AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');

-- Stored objects (triggers, views, events, routines)
SELECT 'TRIGGER' AS object_type, TRIGGER_SCHEMA, TRIGGER_NAME, character_set_client
FROM information_schema.TRIGGERS
WHERE character_set_client != 'utf8mb4'
  AND TRIGGER_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
UNION ALL
SELECT 'VIEW', TABLE_SCHEMA, TABLE_NAME, character_set_client
FROM information_schema.VIEWS
WHERE character_set_client != 'utf8mb4'
  AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
UNION ALL
SELECT 'ROUTINE', ROUTINE_SCHEMA, ROUTINE_NAME, character_set_client
FROM information_schema.ROUTINES
WHERE character_set_client != 'utf8mb4'
  AND ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
UNION ALL
SELECT 'EVENT', EVENT_SCHEMA, EVENT_NAME, character_set_client
FROM information_schema.EVENTS
WHERE character_set_client != 'utf8mb4'
  AND EVENT_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');
```

### Step 2: Check for Row Size Issues

```sql
-- Find tables that may exceed row size after conversion
-- (approximate: counts total max byte length of all VARCHAR/CHAR columns)
SELECT TABLE_SCHEMA, TABLE_NAME,
       SUM(
         CASE
           WHEN DATA_TYPE IN ('varchar', 'char')
           THEN CHARACTER_MAXIMUM_LENGTH * 4  -- utf8mb4 worst case
           ELSE 0
         END
       ) AS estimated_row_bytes
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
GROUP BY TABLE_SCHEMA, TABLE_NAME
HAVING estimated_row_bytes > 8126
ORDER BY estimated_row_bytes DESC;
```

### Step 3: Generate Conversion DDL

```sql
-- Generate ALTER DATABASE statements
SELECT CONCAT('ALTER DATABASE `', SCHEMA_NAME, '` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;')
FROM information_schema.SCHEMATA
WHERE default_character_set_name != 'utf8mb4'
  AND SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');

-- Generate ALTER TABLE statements
SELECT DISTINCT CONCAT('ALTER TABLE `', TABLE_SCHEMA, '`.`', TABLE_NAME,
       '` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;')
FROM information_schema.COLUMNS
WHERE character_set_name IS NOT NULL
  AND character_set_name != 'utf8mb4'
  AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');
```

### Step 4: Execute on Green Environment

If using Blue/Green deployment for the upgrade, run the conversion on the green environment **after** the version upgrade completes but **before** switchover:

```bash
# Generate DDL files
mysql -h <green-endpoint> -u admin --secret-id <id> -sN < convert_db_ddl.sql > convert_db.sql
mysql -h <green-endpoint> -u admin --secret-id <id> -sN < convert_table_ddl.sql > convert_table.sql

# Execute (review first!)
mysql -h <green-endpoint> -u admin --secret-id <id> -s < convert_db.sql
mysql -h <green-endpoint> -u admin --secret-id <id> -s < convert_table.sql
```

### Step 5: Update Parameter Group

Set these parameters in the green environment's parameter group:

```
character_set_server = utf8mb4
collation_server = utf8mb4_0900_ai_ci
```

> **Note:** MySQL 8.4 default collation is `utf8mb4_0900_ai_ci`. If you need backward compatibility with 5.7/8.0 applications, use `utf8mb4_general_ci` instead.

## Troubleshooting

### Row size too large (ERROR 1118)

```
ERROR 1118 (42000): Row size too large (> 8126)
```

Options (in order of preference):
1. Convert large VARCHAR columns to TEXT/MEDIUMTEXT
2. Reduce VARCHAR column sizes where possible
3. Split the table into multiple tables
4. As last resort: set `innodb_strict_mode = 0` (unsafe — may cause data truncation)

### Replication error during Blue/Green (ERROR 13146)

```
Column N cannot be converted from type 'varchar(X bytes)' to type 'varchar(Y bytes) utf8mb4'
```

Fix: Set `replica_type_conversions = ALL_LOSSY,ALL_NON_LOSSY` on the green parameter group, then restart replication.

## References

- [How to convert Database Character Sets to utf8mb4 in AWS RDS/Aurora MySQL](https://repost.aws/articles/ARFx4npxdtT4-B-Wdeu_UNuw/how-to-convert-database-character-sets-to-utf8mb4-in-aws-rds-aurora-mysql)
- [MySQL 8.4 Character Sets and Collations](https://dev.mysql.com/doc/refman/8.4/en/charset.html)
- [InnoDB Row Format and Row Size Limits](https://dev.mysql.com/doc/refman/8.4/en/innodb-row-format.html)
