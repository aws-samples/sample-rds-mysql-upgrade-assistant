"""MCP tools — thin wrappers around shell scripts.

Note on async: These tools use synchronous subprocess.run() which blocks the
event loop. This is acceptable for stdio-based MCP transport with a single
caller (Kiro). If migrating to SSE/HTTP transport, replace with
asyncio.create_subprocess_exec for proper concurrency.
"""

import json
import subprocess
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent.parent / "scripts"


def _run(script: str, args: list[str], timeout: int = 300) -> dict | list:
    cmd = ["bash", str(SCRIPTS_DIR / script)] + args
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(f"{script} failed: {result.stderr.strip() or result.stdout.strip()}")
    # Extract JSON from output (scripts may print non-JSON text before the JSON block)
    stdout = result.stdout.strip()
    # Try parsing the full output first
    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        pass
    # Find the last JSON object or array in the output
    for i in range(len(stdout) - 1, -1, -1):
        if stdout[i] in ('}', ']'):
            # Find matching opening brace/bracket
            target = '{' if stdout[i] == '}' else '['
            depth = 0
            for j in range(i, -1, -1):
                if stdout[j] == stdout[i]:
                    depth += 1
                elif stdout[j] == target:
                    depth -= 1
                if depth == 0:
                    try:
                        return json.loads(stdout[j:i+1])
                    except json.JSONDecodeError:
                        break
            break
    raise RuntimeError(f"{script}: could not parse JSON from output:\n{stdout[-500:]}")


def register_tools(mcp):
    @mcp.tool()
    async def discover_instances(
        region: str = "",
        version_prefix: str = "8.0",
        tags: dict[str, str] | None = None,
    ) -> list[dict]:
        """Discover RDS MySQL instances. Returns instance metadata as JSON."""
        args = ["--json", "--version-prefix", version_prefix]
        if region:
            args += ["--region", region]
        for k, v in (tags or {}).items():
            args += ["--tag", f"{k}={v}"]
        return _run("inventory/discover_instances.sh", args)

    @mcp.tool()
    async def run_precheck(
        host: str,
        user: str,
        secret_id: str = "",
        password: str = "",
        phase2: bool = False,
    ) -> dict:
        """Run MySQL 8.0→8.4 precheck. Returns findings summary as JSON.
        Credential priority: secret_id > password.
        IMPORTANT: At least one credential method must be provided (secret_id or password).
        Without credentials, the script will hang waiting for interactive input.
        Prefer secret_id for security."""
        args = ["-h", host, "-u", user, "--json"]
        if secret_id:
            args += ["--secret-id", secret_id]
        elif password:
            args += ["-p", password]
        if phase2:
            args.append("--phase2")
        return _run("precheck/mysql_precheck_run.sh", args, timeout=600)

    @mcp.tool()
    async def migrate_params(
        source_group: str,
        target_group: str,
        target_family: str = "mysql8.4",
        dry_run: bool = False,
        region: str = "",
    ) -> str:
        """Migrate parameter group from source to target engine family."""
        args = ["-s", source_group, "-t", target_group, "-f", target_family]
        if dry_run:
            args.append("-n")
        if region:
            args += ["-S", region, "-T", region]
        result = subprocess.run(
            ["bash", str(SCRIPTS_DIR / "params/migrate_param_group.sh")] + args,
            capture_output=True, text=True, timeout=300,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Parameter migration failed: {result.stderr.strip()}")
        return result.stdout

    @mcp.tool()
    async def create_blue_green(
        instance_id: str,
        target_version: str = "8.4.9",
        target_param_group: str = "",
        region: str = "",
    ) -> dict:
        """Create Blue/Green deployment for MySQL upgrade."""
        args = ["--instance-id", instance_id, "--target-version", target_version]
        if target_param_group:
            args += ["--target-param-group", target_param_group]
        if region:
            args += ["--region", region]
        return _run("upgrade/create_blue_green.sh", args, timeout=120)

    @mcp.tool()
    async def monitor_blue_green(
        deployment_id: str,
        poll_interval: int = 60,
        timeout: int = 3600,
        region: str = "",
    ) -> dict:
        """Monitor Blue/Green deployment until ready or failed."""
        args = ["--deployment-id", deployment_id,
                "--poll-interval", str(poll_interval),
                "--timeout", str(timeout)]
        if region:
            args += ["--region", region]
        return _run("upgrade/monitor_blue_green.sh", args, timeout=timeout + 60)

    @mcp.tool()
    async def switchover(
        deployment_id: str,
        timeout: int = 300,
        region: str = "",
    ) -> dict:
        """Execute Blue/Green switchover."""
        args = ["--deployment-id", deployment_id, "--timeout", str(timeout)]
        if region:
            args += ["--region", region]
        return _run("upgrade/switchover_blue_green.sh", args, timeout=900)

    @mcp.tool()
    async def validate_upgrade(
        instance_id: str,
        host: str = "",
        user: str = "",
        secret_id: str = "",
        expected_version: str = "8.4",
        region: str = "",
    ) -> dict:
        """Run post-upgrade validation checks."""
        args = ["--instance-id", instance_id, "--json",
                "--expected-version", expected_version]
        if host:
            args += ["--host", host]
        if user:
            args += ["--user", user]
        if secret_id:
            args += ["--secret-id", secret_id]
        if region:
            args += ["--region", region]
        return _run("validate/post_upgrade_validate.sh", args)

    @mcp.tool()
    async def batch_upgrade(
        config_path: str,
        dry_run: bool = False,
        resume: bool = False,
        concurrency: int = 0,
        region: str = "",
    ) -> str:
        """Run batch upgrade for multiple instances.
        Note: In-place upgrades may take 30-60 minutes per instance.
        Use dry_run=True first to validate the plan.
        Set concurrency=0 (default) to use the value from config file."""
        args = ["--config", config_path]
        if dry_run:
            args.append("--dry-run")
        if resume:
            args.append("--resume")
        if concurrency > 0:
            args += ["--concurrency", str(concurrency)]
        if region:
            args += ["--region", region]
        result = subprocess.run(
            ["bash", str(SCRIPTS_DIR / "batch/batch_upgrade.sh")] + args,
            capture_output=True, text=True, timeout=86400,
        )
        if result.returncode != 0:
            raise RuntimeError(f"batch_upgrade.sh failed (exit {result.returncode}):\n{result.stdout}\n{result.stderr}")
        return result.stdout

    @mcp.tool()
    async def generate_config(
        region: str = "",
        version_prefix: str = "8.0",
        secret_prefix: str = "",
        output: str = "",
    ) -> str:
        """Generate batch upgrade config from discovered instances."""
        args = ["--version-prefix", version_prefix]
        if region:
            args += ["--region", region]
        if secret_prefix:
            args += ["--secret-prefix", secret_prefix]
        if output:
            args += ["--output", output]
        result = subprocess.run(
            ["bash", str(SCRIPTS_DIR / "batch/generate_config.sh")] + args,
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Config generation failed: {result.stderr.strip()}")
        return result.stdout

    @mcp.tool()
    async def check_option_group(
        instance_id: str,
        region: str = "",
        target_group: str = "",
        dry_run: bool = False,
    ) -> dict:
        """Check and migrate option group for MySQL 8.4 upgrade."""
        args = ["--instance-id", instance_id, "--json"]
        if region:
            args += ["--region", region]
        if target_group:
            args += ["--target-group", target_group]
        if dry_run:
            args.append("--dry-run")
        return _run("params/check_option_group.sh", args)

    @mcp.tool()
    async def pre_switchover_check(
        deployment_id: str,
        region: str = "",
    ) -> dict:
        """Run pre-switchover readiness check for Blue/Green deployment."""
        args = ["--deployment-id", deployment_id, "--json"]
        if region:
            args += ["--region", region]
        return _run("upgrade/pre_switchover_check.sh", args)

    @mcp.tool()
    async def app_validate(
        host: str,
        user: str,
        secret_id: str = "",
        sql_dir: str = "",
    ) -> dict:
        """Run application validation SQL against a MySQL instance."""
        args = ["-h", host, "-u", user, "--json"]
        if secret_id:
            args += ["--secret-id", secret_id]
        if sql_dir:
            args += ["--sql-dir", sql_dir]
        return _run("validate/app_validate_run.sh", args, timeout=300)

    @mcp.tool()
    async def prepare_param_group(
        instance_id: str,
        target_family: str = "mysql8.4",
        target_group: str = "",
        region: str = "",
        dry_run: bool = False,
    ) -> dict:
        """Prepare parameter group for upgrade (auto-detects default vs custom)."""
        args = ["--instance-id", instance_id, "--target-family", target_family, "--json"]
        if target_group:
            args += ["--target-group", target_group]
        if region:
            args += ["--region", region]
        if dry_run:
            args.append("--dry-run")
        return _run("params/prepare_param_group.sh", args)

    @mcp.tool()
    async def in_place_upgrade(
        instance_id: str,
        target_version: str = "8.4.9",
        target_param_group: str = "",
        target_option_group: str = "",
        apply_immediately: bool = True,
        region: str = "",
    ) -> dict:
        """Run in-place upgrade for an RDS MySQL instance or cluster."""
        args = ["--instance-id", instance_id, "--target-version", target_version]
        if target_param_group:
            args += ["--target-param-group", target_param_group]
        if target_option_group:
            args += ["--target-option-group", target_option_group]
        if apply_immediately:
            args.append("--apply-immediately")
        if region:
            args += ["--region", region]
        return _run("upgrade/in_place_upgrade.sh", args, timeout=7200)

    @mcp.tool()
    async def cleanup_blue_green(
        deployment_id: str,
        delete_source: bool = False,
        region: str = "",
    ) -> dict:
        """Delete a Blue/Green deployment after successful switchover."""
        args = ["--deployment-id", deployment_id]
        if delete_source:
            args.append("--delete-source")
        if region:
            args += ["--region", region]
        return _run("upgrade/cleanup_blue_green.sh", args)

    @mcp.tool()
    async def batch_precheck(
        user: str,
        secret_id: str = "",
        password: str = "",
        region: str = "",
        version_prefix: str = "8.0",
        phase2: bool = False,
    ) -> str:
        """Run prechecks on all MySQL 8.0 instances in batch.
        Credential priority: secret_id > password.
        IMPORTANT: At least one credential method must be provided (secret_id or password).
        Without credentials, the script will hang waiting for interactive input.
        Returns summary with pass/fail counts per instance."""
        args = ["-u", user]
        if secret_id:
            args += ["--secret-id", secret_id]
        elif password:
            args += ["-p", password]
        if region:
            args += ["--region", region]
        args += ["--version-prefix", version_prefix]
        if phase2:
            args.append("--phase2")
        args.append("--json")
        result = subprocess.run(
            ["bash", str(SCRIPTS_DIR / "batch/batch_precheck.sh")] + args,
            capture_output=True, text=True, timeout=1800,
        )
        return result.stdout + (f"\nSTDERR: {result.stderr}" if result.returncode != 0 else "")
