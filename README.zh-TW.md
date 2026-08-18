# RDS MySQL Upgrade Assistant

自動化 Amazon RDS MySQL 至 8.4 的批次 Blue/Green 部署升級。專為擁有 100 個以上即將到期的 RDS MySQL 執行個體的 AWS 客戶設計。

### 支援的升級路徑

| 來源 | 目標 | 方式 |
|------|------|------|
| MySQL 8.0.28+ | 8.4.9 | Blue/Green（一步驟）或就地升級 |
| MySQL 8.0 含自訂選項群組 | 8.4.9 | Blue/Green（兩步驟：同版本 B/G → 升級 green） |
| MySQL 5.7 | 8.4.9 | Blue/Green 多跳（5.7→8.0→8.4 一次部署完成） |
| Multi-AZ DB Cluster (8.0) | 8.4.9 | 就地升級（不支援 Blue/Green） |

## 架構

```
┌─────────────────────────────────────────────────────────────┐
│                     Database Administrator                  │
│                                                             │
│         Kiro IDE (Natural Language)    Shell (Direct)       │
└──────────────┬──────────────────────────────────────────────┘
               │                          │
               ▼                          │
┌──────────────────────────┐              │
│   MCP Server (FastMCP)   │              │
│   16 tools / stdio       │              │
│   thin subprocess wrapper│              │
└──────────┬───────────────┘              │
           │                              │
           ▼                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Shell Scripts                          │
│                                                             │
│  ┌───────────────┐  ┌───────────────┐  ┌────────────────┐   │
│  │ discover_     │  │ precheck_     │  │ generate_      │   │
│  │ instances.sh  │  │ run.sh        │  │ config.sh      │   │
│  │ (inventory)   │  │ + phase1.sql  │  │ (batch config) │   │
│  └───────┬───────┘  └───────┬───────┘  └───────┬────────┘   │
│          │                  │                  │            │
│  ┌───────────────┐  ┌───────────────┐  ┌────────────────┐   │
│  │ prepare_      │  │ check_option_ │  │ migrate_param_ │   │
│  │ param_group.sh│  │ group.sh      │  │ group.sh       │   │
│  │ (auto-detect) │  │ (option grp)  │  │ (rds-support)  │   │
│  └───────┬───────┘  └───────┬───────┘  └───────┬────────┘   │
│          │                  │                  │            │
│  ┌───────────────┐  ┌───────────────┐  ┌────────────────┐   │
│  │ create_       │  │ monitor_      │  │ pre_switchover_│   │
│  │ blue_green.sh │  │ blue_green.sh │  │ check.sh       │   │
│  └───────┬───────┘  └───────┬───────┘  └───────┬────────┘   │
│          │                  │                  │            │
│  ┌───────────────┐  ┌───────────────┐  ┌────────────────┐   │
│  │ switchover_   │  │ in_place_     │  │ cleanup_       │   │
│  │ blue_green.sh │  │ upgrade.sh    │  │ blue_green.sh  │   │
│  └───────┬───────┘  └───────┬───────┘  └───────┬────────┘   │
│          │                  │                  │            │
│  ┌───────────────┐  ┌───────────────┐  ┌────────────────┐   │
│  │ post_upgrade_ │  │ app_validate_ │  │ batch_         │   │
│  │ validate.sh   │  │ run.sh        │  │ upgrade.sh     │   │
│  │ (infra check) │  │ (app check)   │  │ (orchestrator) │   │
│  └───────────────┘  └───────────────┘  └────────────────┘   │
│                                                             │
│  ┌───────────────┐                                          │
│  │ batch_        │                                          │
│  │ precheck.sh   │                                          │
│  │ (fleet check) │                                          │
│  └───────────────┘                                          │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  lib/audit_log.sh    lib/integrity_check.sh         │    │
│  │  (security: logging, checksums, dependency verify)  │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                       AWS Cloud                             │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │  Amazon RDS  │  │  Blue/Green  │  │  Secrets Manager  │  │
│  │  MySQL 8.0   │  │  Deployments │  │  (credentials)    │  │
│  │  → 8.4       │  │              │  │                   │  │
│  └──────────────┘  └──────────────┘  └───────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 升級工作流程（每個執行個體）

```
  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
  │ 1.Disco- │───▶│2.Precheck│───▶│3.Migrate │───▶│4.Create  │
  │  ver     │    │ (19 SQL  │    │ Params & │    │  B/G or  │
  │          │    │  checks) │    │ Options  │    │  In-place│
  └──────────┘    └──────────┘    └──────────┘    └────┬─────┘
                                                       │
  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌────▼─────┐
  │8.Switch- │◀───│7.Pre-SW  │◀───│6.Validate│◀───│5.Monitor │
  │  over    │    │  Check   │    │  Green   │    │  Status  │
  │          │    │          │    │(infra+app│    │          │
  └────┬─────┘    └──────────┘    └──────────┘    └──────────┘
       │
  ┌────▼─────┐    ┌──────────┐
  │9.Connect │───▶│10.Cleanup│
  │  Check   │    │  (B/G)   │
  │          │    │          │
  └──────────┘    └──────────┘
```

## 先決條件

- **AWS CLI v2** — [安裝指南](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- **jq** — JSON 處理器
- **mysql client** — 標準 MySQL 命令列用戶端
- **Python 3.10+** 搭配 `uv` — 僅 MCP 伺服器需要

### 安裝 mysql client

```bash
# macOS
brew install mysql-client
# Add to PATH: export PATH="/opt/homebrew/opt/mysql-client/bin:$PATH"

# Amazon Linux 2023
sudo dnf install mariadb105

# Amazon Linux 2
sudo yum install mysql

# Ubuntu / Debian
sudo apt install mysql-client

# RHEL / CentOS
sudo yum install mysql
```

### 安裝 jq

```bash
# macOS
brew install jq

# Amazon Linux / RHEL
sudo yum install jq

# Ubuntu / Debian
sudo apt install jq
```

## 快速開始

### 0. 複製儲存庫

```bash
git clone https://github.com/aws-samples/sample-rds-mysql-upgrade-assistant.git
cd sample-rds-mysql-upgrade-assistant
```

### 1. 探索 MySQL 8.0 執行個體

```bash
./scripts/inventory/discover_instances.sh --region us-east-1 --version-prefix 8.0 --json
```

### 2. 對執行個體執行 precheck

```bash
# Using Secrets Manager (recommended)
./scripts/precheck/mysql_precheck_run.sh -h <endpoint> -u <user> --secret-id prod/db01/creds

# Using IAM database authentication
./scripts/precheck/mysql_precheck_run.sh -h <endpoint> -u <iam_user> --iam

# Using mysql_config_editor (local encrypted credential store)
./scripts/precheck/mysql_precheck_run.sh -h <endpoint> -u <user> --login-path prod-db

# Interactive password prompt (fallback)
./scripts/precheck/mysql_precheck_run.sh -h <endpoint> -u <user>

# Note: Avoid using MYSQL_PWD — it is deprecated in MySQL 8.0 and considered insecure.
```

### 3. 遷移參數群組和選項群組

```bash
# Parameter group (only if custom)
./scripts/params/migrate_param_group.sh \
  -s my-mysql80-params -t my-mysql84-params -f mysql8.4 -n  # dry run first

# Option group (only if custom — e.g., with MARIADB_AUDIT_PLUGIN)
./scripts/params/check_option_group.sh --instance-id my-db --dry-run --json
```

### 4. 建立 Blue/Green 部署

```bash
./scripts/upgrade/create_blue_green.sh \
  --instance-id my-db --target-version 8.4.9 --target-param-group my-mysql84-params
```

### 5. 批次升級（100 個以上執行個體）

從您目前的執行個體自動產生批次設定：

```bash
# Generate config with auto-detected strategies
./scripts/batch/generate_config.sh --output batch_config.yaml

# With Secrets Manager prefix and tag filter
./scripts/batch/generate_config.sh \
  --secret-prefix "prod/rds/" \
  --tag "env=production" \
  --output batch_config.yaml
```

產生器自動：
- 偵測 Multi-AZ DB Clusters → 指派 `in_place`（不支援 Blue/Green）
- 偵測跨區域複本 → 指派 `in_place`
- 唯讀複本不單獨列出（自動包含在主要執行個體的 Blue/Green 部署中）
- 標準執行個體 → 指派 `blue_green`

檢閱並編輯產生的設定，然後執行：

```bash
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --dry-run  # validate first
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --concurrency 3
```

> **長時間執行提示：** 批次升級可能耗時數小時。建議使用 `tmux` 或 `nohup` 避免 SSH 斷線導致任務中斷：
> ```bash
> # 方法 1：tmux（建議 — 可重新連接）
> tmux new -s upgrade
> ./scripts/batch/batch_upgrade.sh --config batch_config.yaml --concurrency 5
> # 斷開：Ctrl+b, d ｜ 重新連接：tmux attach -t upgrade
>
> # 方法 2：nohup（背景執行）
> nohup ./scripts/batch/batch_upgrade.sh --config batch_config.yaml --concurrency 5 \
>   > upgrade.log 2>&1 &
>
> # 如果中斷，從上次進度恢復：
> ./scripts/batch/batch_upgrade.sh --config batch_config.yaml --resume
> ```

批次協調器也會執行執行時期自動偵測：如果執行個體屬於 Multi-AZ DB Cluster，會自動覆寫策略為 `in_place`，以叢集層級執行升級，並跳過同一叢集的其他成員。

獨立批次預檢（不觸發升級）：

```bash
# 使用 Secrets Manager（建議）
./scripts/batch/batch_precheck.sh -u admin --secret-id prod/rds/creds --region us-west-2

# 使用 IAM 資料庫驗證
./scripts/batch/batch_precheck.sh -u iam_user --iam --region us-west-2

# 使用 mysql_config_editor
./scripts/batch/batch_precheck.sh -u admin --login-path prod-db --region us-west-2

# 互動式密碼（所有執行個體共用）
./scripts/batch/batch_precheck.sh -u admin --region us-west-2
```


## 使用 Kiro

### 安裝 Kiro IDE

從 [kiro.dev/downloads](https://kiro.dev/downloads/) 下載：

- **macOS** — Apple Silicon / Intel `.dmg`
- **Windows** — x64 安裝程式
- **Linux** — `.deb`（Ubuntu 24+）或通用 AppImage

啟動 Kiro 並使用您的 AWS Builder ID 或 IAM Identity Center 登入。

### 安裝 Kiro CLI（選用）

Kiro CLI 將相同的 AI 輔助工作流程帶到您的終端機——適用於無頭環境、SSH 工作階段或 CI 管線。

```bash
# macOS / Linux
curl -fsSL https://cli.kiro.dev/install | bash

# Windows (PowerShell)
irm 'https://cli.kiro.dev/install.ps1' | iex
```

安裝後，進行驗證：

```bash
kiro-cli login
```

驗證安裝：

```bash
kiro-cli doctor
```

完整詳情請參閱 [Kiro CLI Installation](https://kiro.dev/docs/cli/installation/)。

### 安裝 uv（Python 套件管理器）

MCP 伺服器透過 `uv` 執行。如果您尚未安裝，請安裝：

```bash
# macOS / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh

# Or via Homebrew
brew install uv
```

驗證：`uv --version`

### 設定 MCP Server

#### 用於 Kiro IDE

在工作區根目錄建立或編輯 `.kiro/settings/mcp.json`：

```json
{
  "mcpServers": {
    "rds-mysql-upgrade": {
      "command": "uv",
      "args": [
        "run", "--directory", "/absolute/path/to/rds-mysql-upgrade-assistant",
        "python", "-m", "rds_upgrade_mcp.server"
      ],
      "env": {
        "AWS_PROFILE": "default",
        "AWS_DEFAULT_REGION": "us-west-2"
      },
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

> 將 `/absolute/path/to/rds-mysql-upgrade-assistant` 替換為此儲存庫的實際路徑。
> 將 `AWS_DEFAULT_REGION` 設定為您的目標區域。

可直接編輯的範例位於 [`examples/mcp.json`](examples/mcp.json)。

Kiro 自動偵測設定變更並啟動 MCP 伺服器。您也可以透過命令面板 → "MCP: Reconnect Server" 重新連線。

#### 用於 Kiro CLI

Kiro CLI 使用相同的 `mcp.json` 格式。將其放置在 `~/.kiro/settings/mcp.json` 以進行全域存取，或放在工作區的 `.kiro/settings/mcp.json`。

```bash
# Start a chat session with MCP tools available
kiro-cli chat

# Or run a single command in headless mode
kiro-cli chat --headless "Discover all MySQL 8.0 instances in us-west-2"
```

### 驗證 MCP 連線

在 Kiro（IDE 或 CLI）中，嘗試：

```
Discover all MySQL 8.0 instances
```

如果 MCP 伺服器已連線，Kiro 將呼叫 `discover_instances` 工具並回傳結果。

### Kiro 命令範例

連線後，使用自然語言：

- "Discover all MySQL 8.0 instances in us-west-2"
- "Run precheck on prod-db-01 using secret prod/db01/creds"
- "Create Blue/Green deployment for prod-db-01 upgrading to 8.4"
- "Run in-place upgrade for dev-db-01 to 8.4.9"
- "Check the status of Blue/Green deployment bgd-xxx"
- "Run batch upgrade with config examples/batch_config.yaml in dry-run mode"

### Kiro Skills（可重複使用的工作流程）

此專案在 `.kiro/skills/` 中包含預建的 Kiro skills，可自動化多步驟工作流程。在 Kiro 聊天中輸入 `#` 並選擇 skill 來使用：

| Skill | 說明 |
|-------|-------------|
| **Upgrade Single Instance** | 端對端升級：precheck → 參數遷移 → Blue/Green 或就地升級 → 驗證 |
| **Batch Upgrade** | 探索 → 產生設定 → 試執行 → 批次升級 → 驗證全部已升級 |
| **Precheck Report** | 對所有執行個體執行 precheck 並產生機群就緒報告 |
| **Cleanup Deployments** | 尋找已完成的 Blue/Green 部署、驗證並清理舊環境 |
| **Application Validation** | 升級後對執行個體執行自訂應用程式層級 SQL 檢查 |

## 升級工作流程

對於每個執行個體，工具遵循 10 個步驟：

1. **探索** — 尋找 MySQL 8.0 執行個體（`discover_instances.sh`）
2. **Precheck** — 執行 19 項相容性分析檢查（`mysql_precheck_run.sh`）
3. **遷移參數和選項** — 從 8.0 建立 8.4 參數群組（`migrate_param_group.sh`），遷移自訂選項群組（`check_option_group.sh`）
4. **建立 B/G** — 建立 Blue/Green 部署（`create_blue_green.sh`）
   - **注意：** 具有跨區域唯讀複本的執行個體不支援 Blue/Green。請對這些執行個體使用就地升級。
5. **監控** — 等待綠色環境就緒（`monitor_blue_green.sh`）
6. **驗證綠色環境** — 對綠色環境執行基礎設施和應用程式驗證（`post_upgrade_validate.sh`、`app_validate_run.sh`）
7. **Pre-switchover 檢查** — 驗證護欄：部署狀態、複寫健康、執行個體可用性（`pre_switchover_check.sh`）
8. **Switchover** — 執行 Blue/Green switchover（`switchover_blue_green.sh`）
9. **連線檢查** — 驗證 switchover 後執行個體名稱和端點連線
10. **清理** — 移除舊的藍色環境（`cleanup_blue_green.sh`）

## Precheck 參考

23 項檢查涵蓋 MySQL Shell + RDS PrePatchCompatibility + Aurora upgrade-prechecks。

> **相容性：** 預檢邏輯對齊 MySQL Shell 9.7 `util.checkForServerUpgrade()`，以純 SQL 實作（不需安裝 MySQL Shell）。另外涵蓋 MySQL Shell 沒有的 RDS 專屬檢查（PrePatchCompatibility）和 Aurora 專屬檢查（upgrade-prechecks.log）。

| # | 檢查 | 嚴重性 | 說明 |
|---|---|---|---|
| 1 | removedSysVars | SKIP | RDS 處理參數清理 |
| 2 | sysVarsNewDefaults | Warning | 8.4 中已變更的預設值（14 個變數） |
| 3 | checkTableForUpgrade | Error | 損壞的檢視、不相容的類型（第二階段） |
| 4 | foreignKeyReferences | Warning | 外鍵參考非唯一/部分索引（含跨 schema） |
| 5 | authMethodUsage | Error/Warning | 已棄用的驗證外掛程式（主要 + MFA 因素） |
| 6 | pluginUsage | Error/Warning | 已移除/已棄用的外掛程式 |
| 7 | deprecatedDefaultAuth | SKIP/Warning | RDS: SKIP；Aurora: Warning（若使用 mysql_native_password） |
| 8 | deprecatedRouterAuthMethod | SKIP | RDS 不使用 Router |
| 9 | columnDefinition | Error | FLOAT/DOUBLE 搭配 AUTO_INCREMENT |
| 10 | sysVarsAllowedValues | SKIP | RDS 參數群組已強制允許的值 |
| 11 | invalidPrivileges | Notice | 已移除的權限（直接 + 透過角色繼承） |
| 12 | partitionsWithPrefixKeys | Error | 前綴鍵分割區 |
| 13 | nonInclusiveLanguage | Error | 已移除的複寫關鍵字（MASTER/SLAVE）在儲存物件中 |
| 14 | memcachedPlugin | Error | 已安裝 daemon_memcached |
| 15 | sysSchemaObjects | Error | sys schema 中的使用者資料表/檢視、類型不符 |
| 16 | dollarSignName | Warning | 以 $ 開頭的名稱（source < 8.0.31） |
| 17 | reservedKeywords | Warning | FULL、INTERSECT、MANUAL、PARALLEL、QUALIFY、TABLESAMPLE |
| 18 | deprecatedTemporalDelimiter | Error | 已棄用的時間分隔符號（source < 8.0.29） |
| 19 | spatialIndex | Warning | InnoDB 空間索引錯誤範圍（8.0.3–8.0.40） |
| 20 | auroraUnsupportedPlugins | Error | Aurora 專用：不在 8.4 允許清單的外掛程式 |
| 21 | auroraUnsupportedComponents | Error | Aurora 專用：不在 8.4 允許清單的元件 |
| 22 | auroraValidatePasswordPlugin | Warning | Aurora 專用：舊版 plugin 形式的 validate_password |
| 23 | auroraDuplicatedEnumValues | Error | Aurora 專用：ENUM 中大小寫不敏感的重複值 |

> 檢查 #20–#23 僅在 Aurora MySQL v3 上執行。在 RDS for MySQL 上會自動跳過（零行、零計數）。

## 參考資料

- [MySQL 8.4 Upgrade Prerequisites](https://dev.mysql.com/doc/refman/8.4/en/upgrade-prerequisites.html)
- [Amazon RDS MySQL 8.0 to 8.4 Prechecks](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.MySQL.Major.html)
- [RDS Blue/Green Deployments](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html)
- [Parameter Group Migration Tool](https://github.com/awslabs/rds-support-tools/blob/main/rds-general/shell/migrate_param_group.sh)
- [Secrets Manager 設定指南](docs/secrets-manager-setup.zh-TW.md) — 安全儲存資料庫密碼的完整步驟
- [常見問題 FAQ](docs/faq.md) — 認證、批次升級、Blue/Green、故障排除常見問答
- [Character Set 轉換至 utf8mb4](docs/charset-conversion-utf8mb4.md) — 升級時順便轉換字元集的選用指南
- [修復手冊](docs/remediation-playbook.md) — 每項 precheck 發現的修復步驟
- [應用程式驗證範本](scripts/validate/app_validate_template.sql) — 使用您的關鍵查詢進行自訂

## 授權條款

Apache 2.0 — 請參閱 [LICENSE](LICENSE)