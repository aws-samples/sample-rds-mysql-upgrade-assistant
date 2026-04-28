# Automate large-scale RDS MySQL 8.0 to 8.4 upgrades with Kiro and MCP

MySQL 8.0 is approaching end of standard support. For AWS customers running hundreds of Amazon RDS for MySQL 8.0 instances, upgrading to MySQL 8.4 is a critical but time-consuming task. Each instance requires compatibility assessment, parameter group migration, Blue/Green deployment creation, switchover execution, and post-upgrade validation — a process that can take hours per instance when done manually.

In this post, we introduce the RDS MySQL Upgrade Assistant, an open-source tool that automates the full upgrade lifecycle using Kiro and Model Context Protocol (MCP) servers. The tool combines a pure SQL precheck engine, shell-based automation scripts, and a natural language interface through Kiro to transform what was previously a multi-day manual effort into a streamlined, repeatable workflow.

## The challenge: upgrading MySQL at scale

When a customer has 100+ RDS MySQL 8.0 instances that need to upgrade to 8.4, they face several challenges:

- **Compatibility assessment**: Each instance may have different schemas, stored procedures, authentication configurations, and parameter settings that could conflict with MySQL 8.4 changes.
- **Parameter group migration**: Custom parameter groups need to be recreated for the MySQL 8.4 engine family, accounting for removed, renamed, and changed-default parameters.
- **Upgrade execution**: Blue/Green deployments are the recommended approach for production instances, but creating and managing them for hundreds of instances is operationally intensive.
- **Validation**: After each upgrade, the database engine version, connectivity, replication health, and parameter group status must be verified.
- **Rollback planning**: If issues arise post-upgrade, a clear rollback path must be available.

Existing tools address parts of this problem. MySQL Shell's `util.checkForServerUpgrade()` performs compatibility checks but requires MySQL Shell installation and connectivity. The RDS built-in PrePatchCompatibility check only runs when you actually initiate the upgrade — if it fails, you've already committed to a maintenance window. Neither tool addresses the end-to-end orchestration needed for batch upgrades.

## Solution overview

The RDS MySQL Upgrade Assistant takes a shell-first approach: bash scripts handle all operations using AWS CLI and the standard `mysql` client. A thin MCP server wraps these scripts so Kiro can orchestrate them through natural language. Every script is independently runnable without Kiro, making the tool accessible to teams that prefer direct CLI usage.

The solution consists of four components:

1. **Shell scripts** — Ten bash scripts covering instance discovery, compatibility precheck, parameter migration, Blue/Green deployment lifecycle, in-place upgrade, post-upgrade validation, and batch orchestration. All scripts use AWS CLI for RDS operations and the `mysql` client for database connectivity.

2. **SQL precheck engine** — A pure SQL script that runs 19 compatibility checks against a MySQL 8.0 instance, detecting issues that would cause the upgrade to fail. The checks cover MySQL Shell's upgrade checker logic plus additional RDS-specific checks, all executable from any standard MySQL client.

3. **MCP server** — A lightweight Python server built with FastMCP that exposes eight tools, each wrapping a shell script. This enables Kiro to call the scripts through natural language commands.

4. **Kiro steering file** — A knowledge document containing MySQL 8.0→8.4 upgrade best practices, known issues, and remediation patterns that Kiro references during interactive sessions.

The following diagram illustrates the solution architecture.

*[Architecture diagram placeholder — create using AWS Architecture Icons showing: DBA → Kiro IDE → MCP Server → Shell Scripts → AWS Cloud (RDS, Blue/Green Deployments, Secrets Manager)]*

## How it works

### Upgrade workflow

For each instance, the tool follows a nine-step workflow:

*[Workflow diagram placeholder — create using AWS Architecture Icons showing the 9-step sequence]*

1. **Discover** — Find all MySQL 8.0 instances using AWS CLI with optional tag-based filtering
2. **Precheck** — Run 19 SQL-based compatibility checks against the source instance
3. **Migrate parameters** — Create a MySQL 8.4 parameter group from the existing 8.0 custom parameters
4. **Create Blue/Green deployment** — Set up a staging environment with the target version
5. **Monitor** — Poll deployment status until the green environment is ready
6. **Precheck green** — Verify the green environment passes all compatibility checks
7. **Switchover** — Execute the Blue/Green switchover with guardrail monitoring
8. **Validate** — Run five post-upgrade health checks
9. **Cleanup** — Remove the old blue environment

### The precheck engine

The precheck engine is the core differentiator. It runs 19 checks as pure SQL, requiring only a standard `mysql` client — no MySQL Shell installation needed. The checks are organized in two phases:

**Phase 1** (read-only, safe for production) runs 19 checks including:

| Check | Severity | What it detects |
|---|---|---|
| sysVarsNewDefaults | Warning | System variables with changed defaults in 8.4 (e.g., `innodb_adaptive_hash_index` → OFF) |
| foreignKeyReferences | Warning | Foreign keys referencing non-unique or partial indexes |
| authMethodUsage | Error/Warning | Deprecated authentication plugins (`mysql_native_password`, `authentication_fido`) |
| pluginUsage | Error/Warning | Removed plugins (`keyring_file`, `keyring_oci`) |
| columnDefinition | Error | FLOAT/DOUBLE columns with AUTO_INCREMENT |
| partitionsWithPrefixKeys | Error | Partitions using prefix key columns |
| reservedKeywords | Warning | Object names conflicting with new reserved words (FULL, INTERSECT) |

Three checks are automatically skipped for RDS-managed items (`removedSysVars`, `deprecatedDefaultAuth`, `deprecatedRouterAuthMethod`) to avoid false positives in managed environments.

**Phase 2** (opt-in) runs `CHECK TABLE FOR UPGRADE` on all user tables. This acquires metadata locks and is recommended for maintenance windows or snapshot-restored instances.

### Parameter group migration

When upgrading from MySQL 8.0 to 8.4, custom parameter groups must be recreated for the new engine family. The tool integrates [`migrate_param_group.sh`](https://github.com/awslabs/rds-support-tools/blob/main/rds-general/shell/migrate_param_group.sh) from the AWS RDS Support Tools repository to automate this process. It copies user-modified parameters from the source 8.0 group to a new 8.4 group, handling version differences automatically.

When multiple instances share the same custom parameter group, the batch orchestrator creates the target group only once and reuses it — avoiding redundant API calls and ensuring consistency.

### Batch orchestration

The batch orchestrator manages upgrades across hundreds of instances with:

- **Configurable concurrency** — Process N instances in parallel (recommended: 3–5 for Blue/Green, 1 for in-place)
- **Strategy selection** — Choose Blue/Green (recommended for production) or in-place (for non-production) per instance
- **Automatic precheck gating** — Instances with ERROR-level findings are automatically skipped
- **State file persistence** — Resume interrupted batches without re-processing completed instances
- **Failure isolation** — A failed instance doesn't block remaining upgrades

## Prerequisites

To use this solution, you need:

- AWS CLI v2 installed and configured with appropriate IAM permissions
- `mysql` client (standard MySQL command-line client)
- `jq` (JSON processor)
- Python 3.10+ with [`uv`](https://docs.astral.sh/uv/getting-started/installation/) (for MCP server only — not required for standalone script usage)
- AWS Secrets Manager secrets containing database credentials for each instance
- Kiro IDE or Kiro CLI (for natural language interface — not required for standalone script usage)

## Getting started

Clone the project repository:

```bash
git clone ssh://git.amazon.com/pkg/Rds-Mysql-Upgrade-Assistant
cd Rds-Mysql-Upgrade-Assistant
```

### Install Kiro

You can interact with the upgrade assistant through Kiro IDE (graphical) or Kiro CLI (terminal). Install one or both:

**Kiro IDE** — Download from [kiro.dev/downloads](https://kiro.dev/downloads/) for macOS, Windows, or Linux. Launch and sign in with your AWS Builder ID or IAM Identity Center.

**Kiro CLI** — Install from your terminal:

```bash
# macOS / Linux
curl -fsSL https://cli.kiro.dev/install | bash

# Windows (PowerShell)
irm 'https://cli.kiro.dev/install.ps1' | iex
```

Then authenticate:

```bash
kiro-cli login
```

For full installation details, see [Kiro CLI Installation](https://kiro.dev/docs/cli/installation/).

### Install uv

The MCP server runs via `uv`, a fast Python package manager:

```bash
# macOS / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh

# Or via Homebrew
brew install uv
```

### Option 1: Interactive upgrade with Kiro

Add the MCP server to your Kiro configuration. For Kiro IDE, create `.kiro/settings/mcp.json` in the workspace root. For Kiro CLI, place it at `~/.kiro/settings/mcp.json` for global access:

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

> Replace `/path/to/rds-mysql-upgrade-assistant` with the actual absolute path to the cloned repository. Set `AWS_DEFAULT_REGION` to your target region.

Kiro IDE auto-detects config changes and starts the MCP server. You can also reconnect via Command Palette → "MCP: Reconnect Server". For Kiro CLI, start a chat session:

```bash
kiro-cli chat
```

Start a conversation using natural language:

```
"Discover all MySQL 8.0 instances in us-east-1 tagged with env=production"
```

Kiro calls the `discover_instances` MCP tool, which runs `discover_instances.sh` and returns the instance inventory:

```
Found 47 MySQL 8.0 instances in us-east-1:
- prod-db-01: 8.0.35, db.r6g.xlarge, Multi-AZ, prod-mysql80 param group
- prod-db-02: 8.0.35, db.r6g.xlarge, Multi-AZ, prod-mysql80 param group
...
```

Run a precheck on a specific instance:

```
"Run precheck on prod-db-01 using secret prod/db01/credentials"
```

The precheck returns a structured report:

```
Precheck Results for prod-db-01 (MySQL 8.0.35 → 8.4.8):
  Errors:   0
  Warnings: 3 (sysVarsNewDefaults: innodb_adaptive_hash_index,
                innodb_io_capacity, innodb_change_buffering)
  Notices:  0
  Skipped:  3 (RDS-managed)

No errors found. Instance is eligible for upgrade.
```

Proceed with the upgrade:

```
"Create a Blue/Green deployment for prod-db-01 upgrading to 8.4.0
 with parameter group prod-mysql84"
```

### Option 2: Batch upgrade with shell scripts

For large-scale upgrades, use the batch orchestrator directly:

1. Auto-generate a batch configuration from your current instances:

```bash
./scripts/batch/generate_config.sh \
  --secret-prefix "prod/rds/" \
  --tag "env=production" \
  --output batch_config.yaml
```

The generator discovers all MySQL 8.0 instances and automatically assigns the correct upgrade strategy:
- **Multi-AZ DB Clusters** → `in_place` (Blue/Green not supported)
- **Instances with cross-region replicas** → `in_place` (Blue/Green not supported)
- **Standard instances** → `blue_green` (recommended)
- **Read replicas** → skipped (upgraded with their primary)

Review and adjust the generated config. A typical output looks like:

```yaml
target_version: "8.4.0"
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

2. Validate with a dry run:

```bash
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --dry-run
```

3. Execute the batch upgrade:

```bash
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --concurrency 3
```

The orchestrator processes instances respecting the concurrency limit, automatically skipping any instance that fails precheck, and generating a summary report:

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

4. Resume if interrupted:

```bash
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --resume
```

## Best practices

When using this solution, keep the following best practices in mind:

- **Start with non-production environments.** Upgrade dev and staging instances first to identify issues before touching production.
- **Always run precheck first.** Use `--dry-run` mode to validate all instances before committing to upgrades. Fix all ERROR-level findings before proceeding.
- **Use Blue/Green for production.** Blue/Green deployments provide minimal downtime (~30 seconds) and a safe rollback path. Reserve in-place upgrades for non-production instances where downtime is acceptable. Note: Blue/Green deployments are not supported for instances with cross-Region read replicas — use in-place upgrade for those instances.
- **Read replicas are upgraded first.** When performing an in-place upgrade on an instance with read replicas, the tool automatically upgrades all replicas before the primary to maintain replication compatibility.
- **Run precheck on the green environment.** After the Blue/Green deployment is created, run the precheck again on the green environment to verify the upgrade succeeded cleanly.
- **Keep blue environments temporarily.** After switchover, retain the blue environment for 24–48 hours as a rollback safety net before cleanup.
- **Monitor parameter group changes.** Review the `migrate_param_group.sh` report carefully. Some parameters have changed defaults in MySQL 8.4 (e.g., `innodb_adaptive_hash_index` defaults to OFF) that may affect workload performance.
- **Plan for `mysql_native_password`.** MySQL 8.4 disables `mysql_native_password` by default. On RDS MySQL, this parameter is not modifiable in the parameter group. Before upgrading, migrate all application accounts from `mysql_native_password` to `caching_sha2_password` using `ALTER USER ... IDENTIFIED WITH caching_sha2_password BY '...'`. Run precheck (Check #5: authMethodUsage) to identify affected accounts.
- **Manage concurrency carefully.** For Blue/Green deployments, 3–5 concurrent upgrades is a reasonable starting point. Monitor your account's RDS service quotas and CloudWatch metrics during batch execution.

## Clean up

After completing all upgrades:

1. Delete old blue environments if not already cleaned up:
```bash
./scripts/upgrade/cleanup_blue_green.sh --deployment-id <id> --delete-source
```

2. Remove any snapshot-restored instances used for precheck testing.

3. Verify all instances are running MySQL 8.4 and parameter groups are in-sync:
```bash
./scripts/inventory/discover_instances.sh --version-prefix 8.4 --json
```

## Conclusion

In this post, we demonstrated how to automate large-scale RDS MySQL 8.0 to 8.4 upgrades using the RDS MySQL Upgrade Assistant. The tool combines a 19-check SQL precheck engine, proven parameter migration tooling, and batch orchestration with Blue/Green deployment support — all accessible through direct shell scripts, Kiro IDE's graphical interface, or Kiro CLI's terminal-based workflow.

By automating the upgrade lifecycle, teams can reduce the time and risk associated with major MySQL version upgrades, transforming a multi-week manual effort into a repeatable, auditable process. The shell-first architecture ensures the tool works in any environment with AWS CLI and a MySQL client, with no additional infrastructure required.

The solution is available as an open-source project. We welcome contributions and feedback from the community.

## About the authors

*[Author bio placeholder]*
