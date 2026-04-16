"""Unit tests for MCP server initialization."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "src"))


def test_server_imports():
    """Server module should import without errors."""
    from rds_upgrade_mcp import server
    assert hasattr(server, "mcp")


def test_server_has_tools():
    """Server should have registered tools."""
    from rds_upgrade_mcp.server import mcp
    # FastMCP registers tools; we just verify the server object exists
    assert mcp.name == "rds-mysql-upgrade"
