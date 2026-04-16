"""MCP tools — thin wrappers around shell scripts."""

import json
import subprocess
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent.parent / "scripts"


def _run(script: str, args: list[str], timeout: int = 300) -> dict | list:
    cmd = ["bash", str(SCRIPTS_DIR / script)] + args
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(f"{script} failed: {result.stderr.strip() or result.stdout.strip()}")
    return json.loads(result.stdout)


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
        phase2: bool = False,
    ) -> dict:
        """Run MySQL 8.0→8.4 precheck. Returns findings summary as JSON."""
        args = ["-h", host, "-u", user, "--json"]
        if secret_id:
            args += ["--secret-id", secret_id]
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
        target_version: str = "8.4.0",
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
        concurrency: int = 1,
        region: str = "",
    ) -> str:
        """Run batch upgrade for multiple instances."""
        args = ["--config", config_path]
        if dry_run:
            args.append("--dry-run")
        if resume:
            args.append("--resume")
        args += ["--concurrency", str(concurrency)]
        if region:
            args += ["--region", region]
        result = subprocess.run(
            ["bash", str(SCRIPTS_DIR / "batch/batch_upgrade.sh")] + args,
            capture_output=True, text=True, timeout=86400,
        )
        return result.stdout + (f"\nSTDERR: {result.stderr}" if result.returncode != 0 else "")
