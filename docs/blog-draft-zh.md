# 使用 Kiro 和 MCP 自動化大規模 RDS MySQL 8.0 至 8.4 升級

> **摘要：** 當客戶擁有 100 個以上需要從 8.0 升級至 8.4 的 RDS MySQL 執行個體時，他們面臨諸多挑戰。RDS MySQL Upgrade Assistant 是一個開源工具，提供 19 項 SQL precheck 引擎搭配修復手冊、自動化參數和選項群組遷移、Blue/Green 和就地升級協調（含 pre-switchover 護欄檢查），以及應用程式驗證框架——全部可透過 shell 腳本或 Kiro IDE/CLI 的自然語言存取。

MySQL 8.0 即將結束標準支援。對於運行數百個 Amazon RDS for MySQL 8.0 執行個體的 AWS 客戶而言，升級至 MySQL 8.4 是一項關鍵但耗時的任務。每個執行個體都需要相容性評估、參數群組遷移、Blue/Green 部署建立、switchover 執行以及升級後驗證——手動操作時，每個執行個體可能需要數小時。

在本文中，我們介紹 RDS MySQL Upgrade Assistant，這是一個開源工具，使用 Kiro 和 Model Context Protocol (MCP) 伺服器自動化完整的升級生命週期。該工具結合了純 SQL precheck 引擎、基於 shell 的自動化腳本，以及透過 Kiro 提供的自然語言介面，將原本需要多天的手動工作轉變為精簡、可重複的工作流程。

## 挑戰：大規模升級 MySQL

當客戶擁有 100 個以上需要從 8.0 升級至 8.4 的 RDS MySQL 執行個體時，他們面臨以下挑戰：

- **相容性評估**：每個執行個體可能有不同的結構描述、預存程序、驗證設定和參數設定，這些都可能與 MySQL 8.4 的變更產生衝突。
- **參數群組遷移**：自訂參數群組需要為 MySQL 8.4 引擎系列重新建立，並處理已移除、重新命名和預設值變更的參數。
- **選項群組遷移**：自訂選項群組（例如包含 MARIADB_AUDIT_PLUGIN 的群組）必須為 MySQL 8.4 重新建立。不支援 8.4 的選項（如 MEMCACHED）需要排除。
- **升級執行**：Blue/Green 部署是生產環境執行個體的建議方法，但為數百個執行個體建立和管理這些部署在操作上非常密集。
- **驗證**：每次升級後，必須驗證資料庫引擎版本、連線能力、複寫健康狀態和參數群組狀態。
- **回復計畫**：如果升級後出現問題，回復需要從快照或 PITR 還原——兩者都會建立新的執行個體。沒有就地降級或反向 switchover。

現有工具解決了部分問題。MySQL Shell 的 `util.checkForServerUpgrade()` 執行相容性檢查，但需要安裝 MySQL Shell 並建立連線。RDS 內建的 PrePatchCompatibility 檢查只在您實際啟動升級時才會執行——如果失敗，您已經承諾了維護時段。這兩個工具都無法解決批次升級所需的端對端協調。

## 解決方案概述

RDS MySQL Upgrade Assistant 採用 shell 優先的方法：bash 腳本使用 AWS CLI 和標準 `mysql` 用戶端處理所有操作。一個輕量的 MCP 伺服器包裝這些腳本，讓 Kiro 可以透過自然語言進行協調。每個腳本都可以在不使用 Kiro 的情況下獨立執行，使偏好直接使用 CLI 的團隊也能使用此工具。

解決方案由四個元件組成：

1. **Shell 腳本** — 十五個 bash 腳本加上兩個安全庫涵蓋執行個體探索、相容性 precheck、參數遷移、Blue/Green 部署生命週期、就地升級、升級後驗證和批次協調。所有腳本使用 AWS CLI 進行 RDS 操作，使用 `mysql` 用戶端進行資料庫連線。

2. **SQL precheck 引擎** — 一個純 SQL 腳本，對 MySQL 8.0 執行個體執行 19 項相容性檢查，偵測可能導致升級失敗的問題。這些檢查涵蓋 MySQL Shell 的升級檢查器邏輯以及額外的 RDS 特定檢查，全部可從任何標準 MySQL 用戶端執行。

3. **MCP 伺服器** — 使用 FastMCP 建構的輕量 Python 伺服器，公開十五個工具，每個工具包裝一個 shell 腳本。這使 Kiro 能夠透過自然語言命令呼叫這些腳本。

4. **Kiro steering 檔案** — 包含 MySQL 8.0→8.4 升級最佳實務、已知問題和修復模式的知識文件，Kiro 在互動式工作階段中參考此文件。

以下圖表說明解決方案架構。

![RDS MySQL Upgrade Assistant Architecture](docs/rds_mysql_upgrade_architecture.png)

## 運作方式

### 升級工作流程

對於每個執行個體，工具遵循十步驟工作流程：


1. **探索** — 使用 AWS CLI 搭配可選的標籤篩選找到所有 MySQL 8.0 執行個體
2. **Precheck** — 對來源執行個體執行 19 項基於 SQL 的相容性檢查
3. **遷移參數** — 從現有 8.0 自訂參數建立 MySQL 8.4 參數群組
4. **建立 Blue/Green 部署** — 使用目標版本設定暫存環境
5. **監控** — 輪詢部署狀態直到綠色環境就緒
6. **驗證綠色環境** — 對綠色環境執行基礎設施和應用程式驗證（`post_upgrade_validate.sh`、`app_validate_run.sh`）
7. **Pre-switchover 檢查** — 驗證 switchover 護欄：部署狀態、複寫健康、執行個體可用性（`pre_switchover_check.sh`）
8. **Switchover** — 執行 Blue/Green switchover
9. **連線檢查** — 驗證 switchover 後執行個體名稱和端點連線
10. **清理** — 移除舊的藍色環境


### Precheck 引擎

precheck 引擎幫助在承諾升級*之前*識別相容性問題。它以純 SQL 執行 19 項檢查，只需要標準 `mysql` 用戶端——不需要安裝 MySQL Shell。

**重要定位**：此 precheck 基於 MySQL Shell 的 `util.checkForServerUpgrade()` 邏輯，適配為標準 MySQL 用戶端執行。它作為*預篩選工具*，用於及早發現常見問題——而非取代您啟動升級時自動執行的 RDS 內部 PrePatchCompatibility 檢查。RDS 內部檢查可能涵蓋此處未包含的額外引擎特定驗證。我們建議：

1. 先執行此 precheck 以主動識別和修復已知問題
2. 在啟動升級前修復所有 ERROR 級別的發現
3. 如果 RDS 升級仍因 PrePatchCompatibility 錯誤而失敗，請檢閱 RDS 事件日誌以了解此工具未涵蓋的詳細資訊

檢查分為兩個階段：

**第一階段**（唯讀，可安全用於生產環境）執行 19 項檢查，包括：

| 檢查 | 嚴重性 | 偵測內容 |
|---|---|---|
| sysVarsNewDefaults | Warning | 在 8.4 中預設值已變更的系統變數（例如 `innodb_adaptive_hash_index` → OFF） |
| foreignKeyReferences | Warning | 參考非唯一或部分索引的外鍵 |
| authMethodUsage | Error/Warning | 已棄用的驗證外掛程式（`mysql_native_password`、`authentication_fido`） |
| pluginUsage | Error/Warning | 已移除的外掛程式（`keyring_file`、`keyring_oci`） |
| columnDefinition | Error | 具有 AUTO_INCREMENT 的 FLOAT/DOUBLE 欄位 |
| partitionsWithPrefixKeys | Error | 使用前綴鍵欄位的分割區 |
| reservedKeywords | Warning | 與新保留字衝突的物件名稱（FULL、INTERSECT） |

三項檢查會自動跳過 RDS 管理的項目（`removedSysVars`、`deprecatedDefaultAuth`、`deprecatedRouterAuthMethod`），以避免在受管環境中產生誤報。

**第二階段**（選擇性加入）對所有使用者資料表執行 `CHECK TABLE FOR UPGRADE`。這會取得中繼資料鎖定，建議在維護時段或從快照還原的執行個體上執行。

### 參數群組遷移

從 MySQL 8.0 升級至 8.4 時，自訂參數群組必須為新的引擎系列重新建立。此工具整合了 AWS RDS Support Tools 儲存庫中的 [`migrate_param_group.sh`](https://github.com/awslabs/rds-support-tools/blob/main/rds-general/shell/migrate_param_group.sh) 來自動化此程序。它將使用者修改的參數從來源 8.0 群組複製到新的 8.4 群組，自動處理版本差異。

當多個執行個體共用相同的自訂參數群組時，批次協調器只建立一次目標群組並重複使用——避免冗餘的 API 呼叫並確保一致性。

### 選項群組遷移

除了參數群組外，使用自訂選項群組的執行個體也需要遷移。RDS 不會自動將自訂選項群組升級至新的引擎版本。工具的 `check_option_group.sh` 處理此問題：

- **預設選項群組** — 無需操作。RDS 在升級期間自動指派 `default:mysql-8.4`。
- **包含 MARIADB_AUDIT_PLUGIN 的自訂選項群組** — 建立新的 MySQL 8.4 選項群組並新增相同的稽核外掛程式。目標選項群組隨後傳遞給 Blue/Green 部署（`--target-db-instance-option-group-name`）或就地升級（`--option-group-name`）。
- **包含 MEMCACHED 的自訂選項群組** — MEMCACHED 選項在 MySQL 8.4 中不受支援，會自動從目標選項群組中排除。這不會阻擋升級。
- **空的自訂選項群組** — 仍會建立新的空 MySQL 8.4 選項群組，因為 RDS 對自訂設定需要明確的選項群組關聯。

### 批次協調

批次協調器管理數百個執行個體的升級，具備：

- **可設定的並行度** — 平行處理 N 個執行個體（建議：Blue/Green 為 3–5 個，就地升級為 1 個）
- **策略選擇** — 每個執行個體選擇 Blue/Green（建議用於生產環境）或就地升級（用於非生產環境）
- **Multi-AZ DB Cluster 自動偵測** — 自動偵測叢集成員，強制使用就地升級策略（Blue/Green 不支援），以叢集層級執行升級，並跳過重複成員
- **自動 precheck 閘控** — 具有 ERROR 級別發現的執行個體會自動跳過
- **狀態檔案持久化** — 恢復中斷的批次而不重新處理已完成的執行個體
- **故障隔離** — 失敗的執行個體不會阻擋其餘升級

## 先決條件

要使用此解決方案，您需要：

- 已安裝並設定適當 IAM 權限的 AWS CLI v2
- `mysql` 用戶端（標準 MySQL 命令列用戶端）
- `jq`（JSON 處理器）
- Python 3.10+ 搭配 [`uv`](https://docs.astral.sh/uv/getting-started/installation/)（僅 MCP 伺服器需要——獨立腳本使用不需要）
- 包含每個執行個體資料庫憑證的 AWS Secrets Manager 密鑰
- Kiro IDE 或 Kiro CLI（用於自然語言介面——獨立腳本使用不需要）

## 開始使用

複製專案儲存庫：

```bash
git clone https://github.com/aws-samples/sample-rds-mysql-upgrade-assistant.git
cd sample-rds-mysql-upgrade-assistant
```

### 安裝 Kiro

您可以透過 Kiro IDE（圖形介面）或 Kiro CLI（終端機）與升級助手互動。安裝其中一個或兩者：

**Kiro IDE** — 從 [kiro.dev/downloads](https://kiro.dev/downloads/) 下載，支援 macOS、Windows 或 Linux。啟動並使用您的 AWS Builder ID 或 IAM Identity Center 登入。

**Kiro CLI** — 從終端機安裝：

```bash
# macOS / Linux
curl -fsSL https://cli.kiro.dev/install | bash

# Windows (PowerShell)
irm 'https://cli.kiro.dev/install.ps1' | iex
```

然後進行驗證：

```bash
kiro-cli login
```

完整安裝詳情請參閱 [Kiro CLI Installation](https://kiro.dev/docs/cli/installation/)。

### 安裝 uv

MCP 伺服器透過 `uv` 執行，這是一個快速的 Python 套件管理器：

```bash
# macOS / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh

# 或透過 Homebrew
brew install uv
```

### 選項 1：使用 Kiro 進行互動式升級

將 MCP 伺服器新增至您的 Kiro 設定。對於 Kiro IDE，在工作區根目錄建立 `.kiro/settings/mcp.json`。對於 Kiro CLI，將其放置在 `~/.kiro/settings/mcp.json` 以進行全域存取：

```json
{
  "mcpServers": {
    "rds-mysql-upgrade": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/rds-mysql-upgrade-assistant",
               "python", "-m", "rds_upgrade_mcp.server"],
      "env": {
        "AWS_PROFILE": "default",
        "AWS_DEFAULT_REGION": "us-west-2"
      }
    }
  }
}
```

> 將 `/path/to/rds-mysql-upgrade-assistant` 替換為複製儲存庫的實際絕對路徑。將 `AWS_DEFAULT_REGION` 設定為您的目標區域。

Kiro IDE 自動偵測設定變更並啟動 MCP 伺服器。您也可以透過命令面板 → "MCP: Reconnect Server" 重新連線。對於 Kiro CLI，啟動聊天工作階段：

```bash
kiro-cli chat
```

使用自然語言開始對話：

```
"Discover all MySQL 8.0 instances in us-east-1 tagged with env=production"
```

Kiro 呼叫 `discover_instances` MCP 工具，該工具執行 `discover_instances.sh` 並回傳執行個體清單：

```
Found 47 MySQL 8.0 instances in us-east-1:
- prod-db-01: 8.0.35, db.r6g.xlarge, Multi-AZ, prod-mysql80 param group
- prod-db-02: 8.0.35, db.r6g.xlarge, Multi-AZ, prod-mysql80 param group
...
```

對特定執行個體執行 precheck：

```
"Run precheck on prod-db-01 using secret prod/db01/credentials"
```

precheck 回傳結構化報告：

```
Precheck Results for prod-db-01 (MySQL 8.0.35 → 8.4.8):
  Errors:   0
  Warnings: 3 (sysVarsNewDefaults: innodb_adaptive_hash_index,
                innodb_io_capacity, innodb_change_buffering)
  Notices:  0
  Skipped:  3 (RDS-managed)

No errors found. Instance is eligible for upgrade.
```

繼續進行升級：

```
"Create a Blue/Green deployment for prod-db-01 upgrading to 8.4.8
 with parameter group prod-mysql84"
```

### 選項 2：使用 shell 腳本進行批次升級

對於大規模升級，直接使用批次協調器：

1. 從您目前的執行個體自動產生批次設定：

```bash
./scripts/batch/generate_config.sh \
  --secret-prefix "prod/rds/" \
  --tag "env=production" \
  --output batch_config.yaml
```

產生器探索所有 MySQL 8.0 執行個體並自動指派正確的升級策略：
- **Multi-AZ DB Clusters** → `in_place`（不支援 Blue/Green）
- **具有跨區域複本的執行個體** → `in_place`（不支援 Blue/Green）
- **標準執行個體** → `blue_green`（建議）
- **唯讀複本** → 不單獨列出（自動包含在主要執行個體的 Blue/Green 部署中）

檢閱並調整產生的設定。典型輸出如下：

```yaml
target_version: "8.4.8"
target_param_family: "mysql8.4"
concurrency: 3
precheck_phase2: false
cleanup_blue_after_switchover: true

instances:
  - instance_id: "prod-db-01"
    secret_id: "prod/db01/credentials"
    source_param_group: "prod-mysql80-custom"
    strategy: "blue_green"
  - instance_id: "prod-db-02"
    secret_id: "prod/db02/credentials"
    source_param_group: "prod-mysql80-custom"  # Same group — migrated once
    strategy: "blue_green"
  - instance_id: "dev-db-01"
    secret_id: "dev/db01/credentials"
    source_param_group: "dev-mysql80"
    strategy: "in_place"
```

2. 使用試執行進行驗證：

```bash
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --dry-run
```

3. 執行批次升級：

```bash
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --concurrency 3
```

協調器在遵守並行度限制的情況下處理執行個體，自動跳過任何 precheck 失敗的執行個體，並產生摘要報告：

```
============================================================
Batch Upgrade Summary
============================================================
Total:     50
Completed: 47
Failed:    2
Skipped:   1
Duration:  14400s
============================================================
Failed instances:
  prod-db-12: Precheck found 3 ERROR findings
  prod-db-37: Blue/Green creation failed: instance not eligible
```

4. 如果中斷，可恢復執行：

```bash
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --resume
```


## 最佳實務

使用此解決方案時，請牢記以下最佳實務：

- **從非生產環境開始。** 先升級開發和暫存執行個體，在觸及生產環境之前識別問題。
- **務必先執行 precheck。** 使用 `--dry-run` 模式在承諾升級前驗證所有執行個體。在繼續之前修復所有 ERROR 級別的發現。
- **生產環境使用 Blue/Green。** Blue/Green 部署在 switchover 期間提供最小停機時間（約 30 秒）。請注意 switchover 是單向操作——沒有反向 switchover。switchover 後，舊的藍色執行個體會以重新命名的識別碼保留（例如 `-old1`）。要回復，請刪除 B/G 部署（保留舊執行個體），重新命名目前的綠色執行個體，然後將舊的藍色執行個體重新命名回原始名稱。或者，從快照還原或使用 PITR。將就地升級保留給可接受停機的非生產執行個體。注意：具有跨區域唯讀複本的執行個體不支援 Blue/Green 部署——請對這些執行個體使用就地升級。
- **唯讀複本會先升級。** 對具有唯讀複本的執行個體執行就地升級時，工具會自動在主要執行個體之前升級所有複本，以維持複寫相容性。
- **對綠色環境執行 precheck。** Blue/Green 部署建立後，對綠色環境再次執行 precheck，以驗證升級是否順利完成。
- **暫時保留藍色環境。** switchover 後，保留舊的藍色執行個體 24–48 小時。要回復至 MySQL 8.0：刪除 B/G 部署（保留舊執行個體），重新命名綠色執行個體，然後將藍色執行個體重新命名回原始名稱。**重要：rename 回退會還原至 switchover 時的藍色執行個體狀態——switchover 後寫入的任何資料都會遺失。PITR 無法降級引擎版本。目前沒有零資料遺失且同時回退版本的全自動化路徑。** 回退前請仔細評估取捨。
- **監控參數群組變更。** 仔細檢閱 `migrate_param_group.sh` 報告。某些參數在 MySQL 8.4 中的預設值已變更（例如 `innodb_adaptive_hash_index` 預設為 OFF），可能影響工作負載效能。
- **關於 `mysql_native_password` 的說明。** RDS MySQL 8.4 使用 `caching_sha2_password` 作為預設驗證外掛程式。`mysql_native_password` 外掛程式在 8.4 中仍然可用，但已棄用且將在未來版本中移除。升級後，使用 `mysql_native_password` 的現有帳戶將繼續運作。要變更預設驗證外掛程式，請建立自訂參數群組並修改 `authentication_policy` 參數。長期而言，計畫將帳戶遷移至 `caching_sha2_password`。
- **謹慎管理並行度。** 對於 Blue/Green 部署，3–5 個並行升級是合理的起點——綠色環境獨立建構，生產環境（藍色）在 switchover 前不受影響。對於就地升級，建議使用並行度 1（串行），因為每次升級都會造成目標執行個體停機；同時執行多個就地升級意味著多個資料庫同時不可用。對於可接受停機的非生產環境就地升級，並行度 2–3 是可以的。

## 解決困難部分：修復和應用程式驗證

上述自動化處理了操作工作流程，但主要版本升級中真正困難的部分是 (1) 修復 precheck 發現和 (2) 升級後驗證應用程式。本節解決這兩個問題。

### 大規模處理 precheck 發現

在整個機群執行 precheck 後，您可能會看到常見模式。隨附的[修復手冊](https://github.com/aws-samples/sample-rds-mysql-upgrade-assistant/blob/main/docs/remediation-playbook.md)為每種發現類型提供具體的修復步驟。以下是建議的方法：

1. **跨機群分類發現。** 大多數執行個體共享相同的發現（例如 `sysVarsNewDefaults` 警告幾乎出現在每個執行個體上）。按發現類型而非按執行個體分組。

2. **先修復 ERROR 發現——它們會阻擋升級。** 最常見的阻擋因素及其修復方式：

   **`authentication_fido` 帳戶（檢查 #5）** — 必須在升級前遷移：
   ```sql
   -- Identify affected accounts
   SELECT User, Host, plugin FROM mysql.user WHERE plugin = 'authentication_fido';
   -- Migrate each account
   ALTER USER 'username'@'host' IDENTIFIED WITH caching_sha2_password BY 'new_password';
   ```

   **FLOAT/DOUBLE 搭配 AUTO_INCREMENT（檢查 #9）** — 變更欄位類型：
   ```sql
   -- Find affected columns
   SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, COLUMN_TYPE
   FROM information_schema.COLUMNS
   WHERE COLUMN_TYPE IN ('float', 'double') AND EXTRA = 'auto_increment'
     AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');
   -- Fix
   ALTER TABLE `schema`.`table` MODIFY COLUMN `col` BIGINT AUTO_INCREMENT;
   ```

   **`daemon_memcached` 外掛程式（檢查 #14）** — 從選項群組中移除（MySQL 8.4 不支援 MEMCACHED）。請參閱 [MySQL Options for RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.MySQL.Options.html)。

   **`sys` 結構描述中的使用者資料表（檢查 #15）** — 移至使用者結構描述：
   ```sql
   RENAME TABLE sys.my_table TO my_schema.my_table;
   ```

3. **按影響評估 WARNING 發現。** 並非所有警告都需要採取行動：

   | 發現 | 是否需要行動？ | 建議 |
   |---------|-----------------|----------------|
   | `sysVarsNewDefaults` | 通常不需要 | 檢閱[預設值變更表](https://github.com/aws-samples/sample-rds-mysql-upgrade-assistant/blob/main/docs/remediation-playbook.md)。大多數新預設值是改進。 |
   | `mysql_native_password` | 否（在 RDS 上） | 在 RDS MySQL 8.4 中仍然啟用。計畫長期遷移至 `caching_sha2_password`。 |
   | `binlog_format` STATEMENT/MIXED | 是 | 必須變更為 ROW。在參數群組中設定。 |
   | `foreignKeyReferences` | 檢閱 | 如需要，在參考欄位上新增唯一索引。 |
   | `nonInclusiveLanguage` | 建議 | 更新預存程序以使用包容性用語（REPLICA 取代 SLAVE）。 |

4. **批量套用修復。** 對於影響多個共享相同結構描述的執行個體的結構描述變更，修復一次並在測試執行個體上驗證後再推廣。

有關所有 19 項檢查的完整修復步驟，請參閱[完整修復手冊](https://github.com/aws-samples/sample-rds-mysql-upgrade-assistant/blob/main/docs/remediation-playbook.md)。

### 升級後的應用程式驗證

工具的內建驗證（`post_upgrade_validate.sh`）檢查基礎設施健康狀態——引擎版本、執行個體狀態、複寫、參數群組和 MySQL 連線能力。然而，**應用程式層級的驗證才是真正的瓶頸**，且因工作負載而異。

為解決此問題，工具包含應用程式驗證執行器（`scripts/validate/app_validate_run.sh`）和範本（`scripts/validate/app_validate_template.sql`），您可以使用關鍵查詢進行自訂：

1. **複製並自訂範本：**
```bash
cp scripts/validate/app_validate_template.sql scripts/validate/app_validate.sql
# Edit app_validate.sql with your application's critical queries
```

2. **在五個類別中定義驗證查詢：**
   - **關鍵讀取查詢** — 您最重要的 SELECT 陳述式
   - **預存程序測試** — CALL 每個關鍵程序並驗證結果
   - **驗證檢查** — 驗證應用程式使用者可以使用預期的驗證外掛程式連線
   - **字元集驗證** — 確認字元集/定序行為
   - **效能基準** — 計時關鍵查詢並與升級前基準比較

3. **對任何執行個體自動執行：**
```bash
# 使用互動式密碼提示
bash scripts/validate/app_validate_run.sh \
  -h <endpoint> -u <user> --json

# 或使用 Secrets Manager
bash scripts/validate/app_validate_run.sh \
  -h <endpoint> -u <user> --secret-id <secret_id> --json
```
執行器自動執行所有 `app_validate*.sql` 檔案並報告結構化的 PASS/FAIL/WARNING 結果。您可以為不同的驗證領域建立多個檔案（例如 `app_validate_orders.sql`、`app_validate_auth.sql`）。

4. **在 switchover 之前對綠色環境執行**，以在生產流量受影響之前發現問題。

5. **批次升級後在整個機群執行：**
```bash
for endpoint in $(bash scripts/inventory/discover_instances.sh --version-prefix 8.4 --json | jq -r '.[].endpoint'); do
  bash scripts/validate/app_validate_run.sh -h "$endpoint" -u admin --secret-id <secret_id> --json
done
```

## 清理

完成所有升級後：

1. 刪除尚未清理的舊藍色環境：
```bash
./scripts/upgrade/cleanup_blue_green.sh --deployment-id <id> --delete-source
```

2. 移除用於 precheck 測試的任何快照還原執行個體。

3. 驗證所有執行個體都在執行 MySQL 8.4 且參數群組已同步：
```bash
./scripts/inventory/discover_instances.sh --version-prefix 8.4 --json
```

## 結論

在本文中，我們展示了如何使用 RDS MySQL Upgrade Assistant 自動化大規模 RDS MySQL 8.0 至 8.4 升級。該工具結合了 19 項檢查的 SQL precheck 引擎、經過驗證的參數遷移工具，以及支援 Blue/Green 部署的批次協調——全部可透過直接 shell 腳本、Kiro IDE 的圖形介面或 Kiro CLI 的終端機工作流程存取。

透過自動化升級作業，團隊可以減少與主要 MySQL 版本升級相關的時間和風險，將繁雜的手動工作轉變為可重複、可稽核的程序。shell 優先的架構確保工具可在任何具有 AWS CLI 和 MySQL 用戶端的環境中運作，無需額外基礎設施。

此解決方案以開源專案形式提供。我們歡迎社群的貢獻和回饋。

## 關於作者

*[作者簡介預留位置]*