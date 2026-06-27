# Frequently Asked Questions (FAQ)

## Credentials & Authentication

### Q: Do I need to set up Secrets Manager to use this tool?
**No.** Secrets Manager is optional. The tool supports multiple authentication methods (in priority order):

1. `--secret-id` — AWS Secrets Manager (recommended for production/batch)
2. `--iam` — IAM database authentication
3. `--login-path` — mysql_config_editor (local encrypted store)
4. Interactive prompt — just omit the password parameter

For a step-by-step Secrets Manager setup guide, see [secrets-manager-setup.md](secrets-manager-setup.md) ([中文版](secrets-manager-setup.zh-TW.md)).

### Q: My secret JSON uses a different field name (e.g., `pwd` instead of `password`). Will it work?
**No.** The tool expects a JSON field named exactly `password`. Update your secret to include this field:
```json
{"username": "admin", "password": "your-password"}
```

### Q: Can I use the same secret for all instances in a batch upgrade?
**Yes.** Use `--secret-id` with a shared secret. If your instances have different credentials, use `--secret-prefix` with `generate_config.sh` to auto-generate per-instance secret names.

---

## Parameter Groups & Option Groups

### Q: I get `InvalidParameterCombination` when creating a Blue/Green deployment. What's wrong?
Your instance uses a **custom parameter group** (not `default.mysql8.0`). When creating a cross-version Blue/Green deployment, you must specify `--target-param-group`. Fix:

```bash
# 1. Migrate your parameter group to mysql8.4 family
./scripts/params/migrate_param_group.sh -s <source-group> -t <source-group>-mysql84 -f mysql8.4

# 2. Create B/G with the target param group
./scripts/upgrade/create_blue_green.sh \
  --instance-id <id> --target-version 8.4.9 \
  --target-param-group <source-group>-mysql84
```

### Q: Parameter group migration fails with "already exists". Is that a problem?
**Usually no.** If the target group already exists (from a previous run), the batch orchestrator verifies it via API and continues normally. You only need to worry if the target group doesn't exist at all.

### Q: My instance has a custom option group. Does it need special handling?
**Yes.** Run `check_option_group.sh` first:
```bash
./scripts/params/check_option_group.sh --instance-id <id> --json
```
- Custom option group with MARIADB_AUDIT_PLUGIN → tool auto-creates a MySQL 8.4 option group
- Custom option group with MEMCACHED → MEMCACHED is excluded (not supported in 8.4)
- Blue/Green with custom option group → requires **two-step** process (same-version B/G → upgrade green)

---

## Batch Upgrades

### Q: My SSH connection dropped during a batch upgrade. Do I have to start over?
**No.** The batch orchestrator persists state to disk. To resume:

```bash
# Check where the previous run left off
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --status

# Resume from last checkpoint
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --resume
```

To prevent this in the first place, run inside `tmux`:
```bash
tmux new -s upgrade
./scripts/batch/batch_upgrade.sh --config batch_config.yaml --concurrency 5
# Detach: Ctrl+b, d | Re-attach: tmux attach -t upgrade
```

### Q: When using Kiro and the session is interrupted, does Kiro know where to pick up?
**Yes** (with the `batch_status` tool). When you reconnect and ask about the batch upgrade, Kiro will call `batch_status` to check the current state, then suggest resuming with `resume=True`. You don't need to re-run discovery or regenerate the config.

### Q: What does the `--status` flag show?
A summary of all instances and their current state:
- **COMPLETED** — upgrade finished successfully
- **FAILED** — upgrade failed (with reason)
- **SKIPPED** — precheck found errors, instance was skipped
- **IN_PROGRESS** — was processing when interrupted (will retry on resume)
- **PENDING_SWITCHOVER** — green is ready, waiting for switchover
- **PENDING** — not yet processed

### Q: What concurrency should I use?
- **Blue/Green:** 5–10 concurrent upgrades is safe. Green environments are independent and don't affect production until switchover.
- **In-place (non-production):** 3–5, depending on your downtime tolerance.
- **In-place (production):** Concurrency 1 (serial) or schedule during maintenance windows.

The main constraint is your account's RDS service quotas (e.g., max concurrent Blue/Green deployments per region, currently 25).

---

## Blue/Green Deployments

### Q: Does Kiro automatically choose Blue/Green or in-place?
**No.** Kiro executes what you ask. You choose the strategy:
- Say "Create a Blue/Green deployment for ..." → Blue/Green
- Say "Run in-place upgrade for ..." → in-place

The batch config generator (`generate_config.sh`) auto-assigns strategies based on instance capabilities, but you can override in the config before running.

### Q: Can I roll back after a Blue/Green switchover?
There is **no reverse switchover**. After switchover, the old blue instance is retained with `-old1` suffix. To revert:
1. Delete the B/G deployment (keep old instance)
2. Rename the current (green) instance
3. Rename the old (blue) instance back to the original name

**Important:** This restores the blue instance's state at switchover time. Any data written after switchover will be lost.

### Q: Blue/Green creation fails with "instance not eligible". Why?
Common reasons:
- Multi-AZ DB Cluster (use in-place instead)
- Cross-region read replicas
- Cascading read replicas
- Instance managed by CloudFormation
- Instance already has an active B/G deployment

See [Blue/Green limitations](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html#blue-green-deployments-limitations).

### Q: How long does the switchover take?
Typically **under 1 minute** (usually ~30 seconds). During switchover, both old and new DB instances are briefly unavailable. The actual downtime depends on your application's connection handling.

---

## Precheck

### Q: Is Phase 2 (CHECK TABLE FOR UPGRADE) required?
**Not strictly required**, but recommended. Phase 1 catches most issues via metadata queries. Phase 2 performs `CHECK TABLE FOR UPGRADE` on all user tables, which:
- Acquires metadata locks (avoid during peak traffic)
- Can take a long time for large tables
- Catches corruption and format issues Phase 1 cannot detect

Recommendation: Run Phase 2 on a snapshot-restored instance or during a maintenance window.

### Q: The precheck reports 3 SKIPPED checks. Is that a problem?
**No.** Three checks are intentionally skipped for RDS-managed items:
- `removedSysVars` — RDS handles parameter cleanup
- `deprecatedDefaultAuth` — RDS manages default authentication
- `deprecatedRouterAuthMethod` — RDS doesn't use MySQL Router

These would produce false positives in a managed environment.

### Q: Can I run precheck without affecting production?
**Phase 1: Yes** — all queries are read-only `SELECT` and `SHOW` statements. Safe for production.

**Phase 2: Use caution** — `CHECK TABLE` acquires metadata locks. Consider running on a snapshot restore instead.

---

## Kiro & MCP

### Q: Do I need Kiro to use this tool?
**No.** All scripts work standalone from any terminal with AWS CLI and mysql client. Kiro provides a natural language interface on top, but is entirely optional.

### Q: The MCP server isn't connecting. How do I troubleshoot?
1. Verify `uv` is installed: `uv --version`
2. Check the path in `.kiro/settings/mcp.json` points to the correct directory
3. Try running the server manually:
   ```bash
   cd /path/to/rds-mysql-upgrade-assistant
   uv run python -m rds_upgrade_mcp.server
   ```
4. In Kiro IDE: Command Palette → "MCP: Reconnect Server"

### Q: Can I use Kiro CLI on a remote EC2 instance?
**Yes.** Install Kiro CLI on EC2:
```bash
curl -fsSL https://cli.kiro.dev/install | bash
kiro-cli login
```
Place `mcp.json` at `~/.kiro/settings/mcp.json`. Run `kiro-cli chat` to start a session with the upgrade tools available.

---

## Troubleshooting

### Q: "Cannot find build directory" or "mysql client not found"
Install prerequisites:
```bash
# macOS
brew install mysql-client jq

# Amazon Linux 2023
sudo dnf install mariadb105 jq

# Ubuntu
sudo apt install mysql-client jq
```

### Q: AWS CLI errors about region
Set your region explicitly:
```bash
export AWS_DEFAULT_REGION=us-west-2
# Or pass --region to each script
```

### Q: "Access Denied" when connecting to RDS
- Verify the username and password are correct
- Check the RDS security group allows inbound from your IP on port 3306
- If using IAM auth, verify the IAM policy includes `rds-db:connect`
- If using Secrets Manager, verify IAM has `secretsmanager:GetSecretValue`

---

## Related Documentation

- [Secrets Manager Setup Guide](secrets-manager-setup.md)
- [Remediation Playbook](remediation-playbook.md)
- [IAM Policies Reference](iam-policies.json)
- [Architecture Diagrams](architecture-diagrams.md)
