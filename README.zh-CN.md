# RDS MySQL Upgrade Assistant

自动化 Amazon RDS MySQL 至 8.4 的批次 Blue/Green 部署升级。专为拥有 100 个以上即将到期的 RDS MySQL 实例的 AWS 客户设计。

### 支持的升级路径

| 来源 | 目标 | 方式 |
|------|------|------|
| MySQL 8.0.28+ | 8.4.9 | Blue/Green（单步骤）或就地升级 |
| MySQL 8.0 含自定义选项组 | 8.4.9 | Blue/Green（两步骤：同版本 B/G → 升级 green） |
| MySQL 5.7 | 8.4.9 | Blue/Green 多跳（5.7→8.0→8.4 一次部署完成） |
| Multi-AZ DB Cluster (8.0) | 8.4.9 | 就地升级（不支持 Blue/Green） |

## 架构

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

### 升级工作流程（每个实例）

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

## 前提条件

- **AWS CLI v2** — [安装指南](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- **jq** — JSON 处理器
- **mysql client** — 标准 MySQL 命令行客户端
- **Python 3.10+** 搭配 `uv` — 仅 MCP 服务器需要

### 安装 mysql client

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

### 安装 jq

```bash
# macOS
brew install jq

# Amazon Linux / RHEL
sudo yum install jq

# Ubuntu / Debian
sudo apt install jq
```

## 快速开始

### 0. 克隆存储库

```bash
git clone https://github.com/aws-samples/sample-rds-mysql-upgrade-assistant.git
cd sample-rds-mysql-upgrade-assistant
```

### 1. 探索 MySQL 8.0 实例

```bash
./scripts/inventory/discover_instances.sh --region us-east-1 --version-prefix 8.0 --json
```

### 2. 对实例执行 precheck

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

### 3. 迁移参数组和选项组

```bash
# Parameter group (only if custom)
./scripts/params/migrate_param_group.sh \
  -s my-mysql80-params -t my-mysql84-params -f mysql8.4 -n  # dry run first

# Option group (only if custom — e.g., with MARIADB_AUDIT_PLUGIN)
./scripts/params/check_option_group.sh --instance-id my-db --dry-run --json
```

### 4. 创建 Blue/Green 部署

```bash
./scripts/upgrade/create_blue_green.sh \
  --instance-id my-db --target-version 8.4.9 --target-param-group my-mysql84-params
```

### 5. 批次升级（100 个以上实例）

从您当前的实例自动生成批次配置：

```bash
# Generate config with auto-detected strategies
./scripts/batch/generate_config.sh --output batch_config.yaml

# With Secrets Manager prefix and tag filter
./scripts/batch/generate_config.sh \
  --secret-prefix "prod/rds/" \
  --tag "env=production" \
  --output batch_config.yaml
```

生成器自动：
- 检测 Multi-AZ DB Clusters → 分配 `in_place`（不支持 Blue/Green）
- 检测跨区域副本 → 分配 `in_place`
- 只读副本不单独列出（自动包含在主要实例的 Blue/Green 部署中）
- 标准实例 → 分配 `blue_green`

查看并编辑生成的配置，然后执行：

```bash
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --dry-run  # validate first
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --concurrency 3
```

批次编排器也会执行运行时自动检测：如果实例属于 Multi-AZ DB Cluster，会自动覆盖策略为 `in_place`，以集群级别执行升级，并跳过同一集群的其他成员。

独立批次预检（不触发升级）：

```bash
# 使用 Secrets Manager（推荐）
./scripts/batch/batch_precheck.sh -u admin --secret-id prod/rds/creds --region us-west-2

# 使用 IAM 数据库认证
./scripts/batch/batch_precheck.sh -u iam_user --iam --region us-west-2

# 使用 mysql_config_editor
./scripts/batch/batch_precheck.sh -u admin --login-path prod-db --region us-west-2

# 交互式密码（所有实例共用）
./scripts/batch/batch_precheck.sh -u admin --region us-west-2
```


## 使用 Kiro

### 安装 Kiro IDE

从 [kiro.dev/downloads](https://kiro.dev/downloads/) 下载：

- **macOS** — Apple Silicon / Intel `.dmg`
- **Windows** — x64 安装程序
- **Linux** — `.deb`（Ubuntu 24+）或通用 AppImage

启动 Kiro 并使用您的 AWS Builder ID 或 IAM Identity Center 登录。

### 安装 Kiro CLI（可选）

Kiro CLI 将相同的 AI 辅助工作流程带到您的终端——适用于无头环境、SSH 会话或 CI 管道。

```bash
# macOS / Linux
curl -fsSL https://cli.kiro.dev/install | bash

# Windows (PowerShell)
irm 'https://cli.kiro.dev/install.ps1' | iex
```

安装后，进行验证：

```bash
kiro-cli login
```

验证安装：

```bash
kiro-cli doctor
```

完整详情请参阅 [Kiro CLI Installation](https://kiro.dev/docs/cli/installation/)。

### 安装 uv（Python 包管理器）

MCP 服务器通过 `uv` 执行。如果您尚未安装，请安装：

```bash
# macOS / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh

# Or via Homebrew
brew install uv
```

验证：`uv --version`

### 配置 MCP Server

#### 用于 Kiro IDE

在工作区根目录创建或编辑 `.kiro/settings/mcp.json`：

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

> 将 `/absolute/path/to/rds-mysql-upgrade-assistant` 替换为此存储库的实际路径。
> 将 `AWS_DEFAULT_REGION` 设置为您的目标区域。

可直接编辑的示例位于 [`examples/mcp.json`](examples/mcp.json)。

Kiro 自动检测配置变更并启动 MCP 服务器。您也可以通过命令面板 → "MCP: Reconnect Server" 重新连接。

#### 用于 Kiro CLI

Kiro CLI 使用相同的 `mcp.json` 格式。将其放置在 `~/.kiro/settings/mcp.json` 以进行全局访问，或放在工作区的 `.kiro/settings/mcp.json`。

```bash
# Start a chat session with MCP tools available
kiro-cli chat

# Or run a single command in headless mode
kiro-cli chat --headless "Discover all MySQL 8.0 instances in us-west-2"
```

### 验证 MCP 连接

在 Kiro（IDE 或 CLI）中，尝试：

```
Discover all MySQL 8.0 instances
```

如果 MCP 服务器已连接，Kiro 将调用 `discover_instances` 工具并返回结果。

### Kiro 命令示例

连接后，使用自然语言：

- "Discover all MySQL 8.0 instances in us-west-2"
- "Run precheck on prod-db-01 using secret prod/db01/creds"
- "Create Blue/Green deployment for prod-db-01 upgrading to 8.4"
- "Run in-place upgrade for dev-db-01 to 8.4.9"
- "Check the status of Blue/Green deployment bgd-xxx"
- "Run batch upgrade with config examples/batch_config.yaml in dry-run mode"

### Kiro Skills（可重复使用的工作流程）

此项目在 `.kiro/skills/` 中包含预建的 Kiro skills，可自动化多步骤工作流程。在 Kiro 聊天中输入 `#` 并选择 skill 来使用：

| Skill | 说明 |
|-------|-------------|
| **Upgrade Single Instance** | 端到端升级：precheck → 参数迁移 → Blue/Green 或就地升级 → 验证 |
| **Batch Upgrade** | 探索 → 生成配置 → 试运行 → 批次升级 → 验证全部已升级 |
| **Precheck Report** | 对所有实例执行 precheck 并生成集群就绪报告 |
| **Cleanup Deployments** | 查找已完成的 Blue/Green 部署、验证并清理旧环境 |
| **Application Validation** | 升级后对实例执行自定义应用程序级别 SQL 检查 |

## 升级工作流程

对于每个实例，工具遵循 10 个步骤：

1. **探索** — 查找 MySQL 8.0 实例（`discover_instances.sh`）
2. **Precheck** — 执行 19 项兼容性分析检查（`mysql_precheck_run.sh`）
3. **迁移参数和选项** — 从 8.0 创建 8.4 参数组（`migrate_param_group.sh`），迁移自定义选项组（`check_option_group.sh`）
4. **创建 B/G** — 创建 Blue/Green 部署（`create_blue_green.sh`）
   - **注意：** 具有跨区域只读副本的实例不支持 Blue/Green。请对这些实例使用就地升级。
5. **监控** — 等待绿色环境就绪（`monitor_blue_green.sh`）
6. **验证绿色环境** — 对绿色环境执行基础设施和应用验证（`post_upgrade_validate.sh`、`app_validate_run.sh`）
7. **Pre-switchover 检查** — 验证护栏：部署状态、复制健康、实例可用性（`pre_switchover_check.sh`）
8. **Switchover** — 执行 Blue/Green switchover（`switchover_blue_green.sh`）
9. **连接检查** — 验证 switchover 后实例名称和端点连接
10. **清理** — 移除旧的蓝色环境（`cleanup_blue_green.sh`）

## Precheck 参考

19 项检查涵盖 MySQL Shell + RDS PrePatchCompatibility：

| # | 检查 | 严重性 | 说明 |
|---|---|---|---|
| 1 | removedSysVars | SKIP | RDS 处理参数清理 |
| 2 | sysVarsNewDefaults | Warning | 8.4 中已变更的默认值 |
| 3 | checkTableForUpgrade | Error | 损坏的视图、不兼容的类型（第二阶段） |
| 4 | foreignKeyReferences | Warning | 外键引用非唯一/部分索引 |
| 5 | authMethodUsage | Error/Warning | 已弃用的验证插件 |
| 6 | pluginUsage | Error/Warning | 已移除/已弃用的插件 |
| 7 | deprecatedDefaultAuth | SKIP | RDS 管理默认验证 |
| 8 | deprecatedRouterAuthMethod | SKIP | RDS 不使用 Router |
| 9 | columnDefinition | Error | FLOAT/DOUBLE 搭配 AUTO_INCREMENT |
| 10 | sysVarsAllowedValues | Warning | 8.4 中受限的值 |
| 11 | invalidPrivileges | Notice | 已移除的权限 |
| 12 | partitionsWithPrefixKeys | Error | 前缀键分区 |
| 13 | nonInclusiveLanguage | Warning | 非包容性用语 |
| 14 | memcachedPlugin | Error | 已安装 daemon_memcached |
| 15 | sysSchemaObjects | Error | sys 架构中的用户表 |
| 16 | dollarSignName | Warning | 以 $ 开头的名称 |
| 17 | reservedKeywords | Warning | FULL、INTERSECT 冲突 |
| 18 | deprecatedTemporalDelimiter | Error | 已弃用的时间分隔符 |
| 19 | spatialIndex | Warning | InnoDB 空间索引错误范围 |

## 参考资料

- [MySQL 8.4 Upgrade Prerequisites](https://dev.mysql.com/doc/refman/8.4/en/upgrade-prerequisites.html)
- [Amazon RDS MySQL 8.0 to 8.4 Prechecks](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.MySQL.Major.html)
- [RDS Blue/Green Deployments](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html)
- [Parameter Group Migration Tool](https://github.com/awslabs/rds-support-tools/blob/main/rds-general/shell/migrate_param_group.sh)
- [Secrets Manager 设置指南](docs/secrets-manager-setup.md) — 安全存储数据库密码的完整步骤（[中文版](docs/secrets-manager-setup.zh-TW.md)）
- [修复手册](docs/remediation-playbook.md) — 每项 precheck 发现的修复步骤
- [应用程序验证模板](scripts/validate/app_validate_template.sql) — 使用您的关键查询进行自定义

## 许可证

Apache 2.0 — 请参阅 [LICENSE](LICENSE)
