"""RDS MySQL Upgrade Assistant — MCP Server."""

from mcp.server.fastmcp import FastMCP
from rds_upgrade_mcp.tools import register_tools

mcp = FastMCP("rds-mysql-upgrade")
register_tools(mcp)

if __name__ == "__main__":
    mcp.run(transport="stdio")
