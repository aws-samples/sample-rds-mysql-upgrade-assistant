# RDS MySQL Upgrade Assistant

Automates batch Blue/Green deployment upgrades for Amazon RDS MySQL 8.0 → 8.4. Designed for AWS customers with 100+ RDS MySQL 8.0 instances approaching end-of-life.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Database Administrator                    │
│                                                              │
│         Kiro IDE (Natural Language)    Shell (Direct)         │
└──────────────┬──────────────────────────┬───────────────────┘
               │                          │
               ▼                          │
┌──────────────────────────┐              │
│   MCP Server (FastMCP)   │              │
│   8 tools / stdio        │              │
│   thin subprocess wrapper│              │
└──────────┬───────────────┘              │
           │                              │
           ▼                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Shell Scripts                            │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │  discover_    │  │  precheck_   │  │  migrate_param_   │  │
│  │  instances.sh │  │  run.sh      │  │  group.sh         │  │
│  │  (AWS CLI)    │  │  + phase1.sql│  │  (rds-support-    │  │
│  │              │  │  (mysql cli) │  │   tools)          │  │
│  └──────┬───────┘  └──────┬───────┘  └────────┬──────────┘  │
│         │                 │                    │             │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │  create_     │  │  monitor_    │  │  switchover_      │  │
│  │  blue_green  │  │  blue_green  │  │  blue_green.sh    │  │
│  │  .sh         │  │  .sh         │  │                   │  │
│  └──────┬───────┘  └──────┬───────┘  └────────┬──────────┘  │
│         │                 │                    │             │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │  in_place_   │  │  post_upgrade│  │  cleanup_         │  │
│  │  upgrade.sh  │  │  _validate.sh│  │  blue_green.sh    │  │
│  └──────┬───────┘  └──────┬───────┘  └────────┬──────────┘  │
│         │                 │                    │             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              batch_upgrade.sh                        │    │
│  │   Orchestrates all scripts with concurrency control  │    │
│  │   Supports: blue_green | in_place strategies         │    │
│  │   Parameter group dedup for shared groups            │    │
│  └──────────────────────┬──────────────────────────────┘    │
└─────────────────────────┼───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                       AWS Cloud                              │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │  Amazon RDS   │  │  Blue/Green  │  │  Secrets Manager  │  │
│  │  MySQL 8.0    │  │  Deployments │  │  (credentials)    │  │
│  │  → 8.4        │  │              │  │                   │  │
│  └──────────────┘  └──────────────┘  └───────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Upgrade Workflow (per instance)

```
  ┌─────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
  │ 1.Disco-│───▶│2.Precheck│───▶│3.Migrate │───▶│4.Create  │
  │  ver    │    │ (19 SQL  │    │  Params  │    │  B/G or  │
  │         │    │  checks) │    │  (dedup) │    │  In-place│
  └─────────┘    └──────────┘    └──────────┘    └────┬─────┘
                                                      │
  ┌─────────┐    ┌──────────┐    ┌──────────┐    ┌────▼─────┐
  │9.Cleanup│◀───│8.Validate│◀───│7.Switch- │◀───│5.Monitor │
  │  (B/G)  │    │ (5 checks│    │  over    │    │  Status  │
  │         │    │  + MySQL) │    │          │    │          │
  └─────────┘    └──────────┘    └──────────┘    └──────────┘
                                                      │
                                                 ┌────▼─────┐
                                                 │6.Precheck│
                                                 │  Green   │
                                                 └──────────┘
```

## Prerequisites

- **AWS CLI v2** — [Install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- **jq** — JSON processor
- **mysql client** — Standard MySQL command-line client
- **Python 3.10+** with `uv` — For MCP server only

### Install mysql client

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

### Install jq

```bash
# macOS
brew install jq

# Amazon Linux / RHEL
sudo yum install jq

# Ubuntu / Debian
sudo apt install jq
```

## Quick Start

### 0. Clone the repository

```bash
git clone ssh://git.amazon.com/pkg/Rds-Mysql-Upgrade-Assistant
cd Rds-Mysql-Upgrade-Assistant
```

### 1. Discover MySQL 8.0 instances

```bash
./scripts/inventory/discover_instances.sh --region us-east-1 --version-prefix 8.0 --json
```

### 2. Run precheck on an instance

```bash
# Interactive password prompt
./scripts/precheck/mysql_precheck_run.sh -h <endpoint> -u <user>

# Using Secrets Manager (recommended)
./scripts/precheck/mysql_precheck_run.sh -h <endpoint> -u <user> --secret-id prod/db01/creds

# Using IAM database authentication
./scripts/precheck/mysql_precheck_run.sh -h <endpoint> -u <iam_user> --iam

# Interactive password prompt (fallback)
./scripts/precheck/mysql_precheck_run.sh -h <endpoint> -u <user>

# Note: Avoid using MYSQL_PWD — it is deprecated in MySQL 8.0 and considered insecure.
```

### 3. Migrate parameter group

```bash
./scripts/params/migrate_param_group.sh \
  -s my-mysql80-params -t my-mysql84-params -f mysql8.4 -n  # dry run first
```

### 4. Create Blue/Green deployment

```bash
./scripts/upgrade/create_blue_green.sh \
  --instance-id my-db --target-version 8.4.0 --target-param-group my-mysql84-params
```

### 5. Batch upgrade (100+ instances)

Auto-generate a batch config from your current instances:

```bash
# Generate config with auto-detected strategies
./scripts/batch/generate_config.sh --output batch_config.yaml

# With Secrets Manager prefix and tag filter
./scripts/batch/generate_config.sh \
  --secret-prefix "prod/rds/" \
  --tag "env=production" \
  --output batch_config.yaml
```

The generator automatically:
- Detects Multi-AZ DB Clusters → assigns `in_place` (Blue/Green not supported)
- Detects cross-region replicas → assigns `in_place`
- Skips read replicas (handled with their primary)
- Standard instances → assigns `blue_green`

Review and edit the generated config, then run:

```bash
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --dry-run  # validate first
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --concurrency 3
```

## Using with Kiro

### Install Kiro IDE

Download from [kiro.dev/downloads](https://kiro.dev/downloads/):

- **macOS** — Apple Silicon / Intel `.dmg`
- **Windows** — x64 installer
- **Linux** — `.deb` (Ubuntu 24+) or Universal AppImage

Launch Kiro and sign in with your AWS Builder ID or IAM Identity Center.

### Install Kiro CLI (Optional)

Kiro CLI brings the same AI-assisted workflow to your terminal — useful for headless environments, SSH sessions, or CI pipelines.

```bash
# macOS / Linux
curl -fsSL https://cli.kiro.dev/install | bash

# Windows (PowerShell)
irm 'https://cli.kiro.dev/install.ps1' | iex
```

After install, authenticate:

```bash
kiro-cli login
```

Verify installation:

```bash
kiro-cli doctor
```

For full details see [Kiro CLI Installation](https://kiro.dev/docs/cli/installation/).

### Install uv (Python package manager)

The MCP server runs via `uv`. Install it if you don't have it:

```bash
# macOS / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh

# Or via Homebrew
brew install uv
```

Verify: `uv --version`

### Configure MCP Server

#### For Kiro IDE

Create or edit `.kiro/settings/mcp.json` in the workspace root:

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

> Replace `/absolute/path/to/rds-mysql-upgrade-assistant` with the actual path to this repo.
> Set `AWS_DEFAULT_REGION` to your target region.

A ready-to-edit example is available at [`examples/mcp.json`](examples/mcp.json).

Kiro auto-detects config changes and starts the MCP server. You can also reconnect via Command Palette → "MCP: Reconnect Server".

#### For Kiro CLI

Kiro CLI uses the same `mcp.json` format. Place it at `~/.kiro/settings/mcp.json` for global access, or in the workspace `.kiro/settings/mcp.json`.

```bash
# Start a chat session with MCP tools available
kiro-cli chat

# Or run a single command in headless mode
kiro-cli chat --headless "Discover all MySQL 8.0 instances in us-west-2"
```

### Verify MCP Connection

In Kiro (IDE or CLI), try:

```
Discover all MySQL 8.0 instances
```

If the MCP server is connected, Kiro will call the `discover_instances` tool and return results.

### Example Kiro Commands

Once connected, use natural language:

- "Discover all MySQL 8.0 instances in us-west-2"
- "Run precheck on prod-db-01 using secret prod/db01/creds"
- "Create Blue/Green deployment for prod-db-01 upgrading to 8.4"
- "Check the status of Blue/Green deployment bgd-xxx"
- "Run batch upgrade with config examples/batch_config.yaml in dry-run mode"

### Kiro Skills (Reusable Workflows)

This project includes pre-built Kiro skills in `.kiro/skills/` that automate multi-step workflows. Use them by typing `#` in Kiro chat and selecting the skill:

| Skill | Description |
|-------|-------------|
| **Upgrade Single Instance** | End-to-end upgrade: precheck → param migration → Blue/Green or in-place → validate |
| **Batch Upgrade** | Discover → generate config → dry-run → batch upgrade → verify all upgraded |
| **Precheck Report** | Run prechecks on all instances and generate a fleet-wide readiness report |

## Upgrade Workflow

For each instance, the tool follows 9 steps:

1. **Discover** — Find MySQL 8.0 instances (`discover_instances.sh`)
2. **Precheck** — Run 19-check compatibility analysis (`mysql_precheck_run.sh`)
3. **Migrate params** — Create 8.4 parameter group from 8.0 (`migrate_param_group.sh`)
4. **Create B/G** — Create Blue/Green deployment (`create_blue_green.sh`)
   - **Note:** Blue/Green is not supported for instances with cross-Region read replicas. Use in-place upgrade for those instances.
5. **Monitor** — Wait for green environment ready (`monitor_blue_green.sh`)
6. **Precheck green** — Verify green environment passes precheck
7. **Switchover** — Execute Blue/Green switchover (`switchover_blue_green.sh`)
8. **Validate** — Post-upgrade health checks (`post_upgrade_validate.sh`)
9. **Cleanup** — Remove old blue environment (`cleanup_blue_green.sh`)

## Precheck Reference

19 checks covering MySQL Shell + RDS PrePatchCompatibility:

| # | Check | Severity | Description |
|---|---|---|---|
| 1 | removedSysVars | SKIP | RDS handles parameter cleanup |
| 2 | sysVarsNewDefaults | Warning | Changed defaults in 8.4 |
| 3 | checkTableForUpgrade | Error | Corrupt views, incompatible types (Phase 2) |
| 4 | foreignKeyReferences | Warning | FK referencing non-unique/partial indexes |
| 5 | authMethodUsage | Error/Warning | Deprecated auth plugins |
| 6 | pluginUsage | Error/Warning | Removed/deprecated plugins |
| 7 | deprecatedDefaultAuth | SKIP | RDS manages default auth |
| 8 | deprecatedRouterAuthMethod | SKIP | RDS doesn't use Router |
| 9 | columnDefinition | Error | FLOAT/DOUBLE with AUTO_INCREMENT |
| 10 | sysVarsAllowedValues | Warning | Restricted values in 8.4 |
| 11 | invalidPrivileges | Notice | Removed privileges |
| 12 | partitionsWithPrefixKeys | Error | Prefix key partitions |
| 13 | nonInclusiveLanguage | Warning | Non-inclusive terms |
| 14 | memcachedPlugin | Error | daemon_memcached installed |
| 15 | sysSchemaObjects | Error | User tables in sys schema |
| 16 | dollarSignName | Warning | Names starting with $ |
| 17 | reservedKeywords | Warning | FULL, INTERSECT conflicts |
| 18 | deprecatedTemporalDelimiter | Error | Deprecated temporal delimiters |
| 19 | spatialIndex | Warning | InnoDB spatial index bug range |

## References

- [MySQL 8.4 Upgrade Prerequisites](https://dev.mysql.com/doc/refman/8.4/en/upgrade-prerequisites.html)
- [Amazon RDS MySQL 8.0 to 8.4 Prechecks](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.MySQL.Major.html)
- [RDS Blue/Green Deployments](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html)
- [Parameter Group Migration Tool](https://github.com/awslabs/rds-support-tools/blob/main/rds-general/shell/migrate_param_group.sh)

## License

Apache 2.0 — See [LICENSE](LICENSE)
