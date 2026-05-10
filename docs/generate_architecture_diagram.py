#!/usr/bin/env python3
"""
Generate architecture diagram for RDS MySQL Upgrade Assistant.

Requirements:
    pip install diagrams
    brew install graphviz  (macOS)

Usage:
    uvx --from diagrams python docs/generate_architecture_diagram.py

Output:
    docs/rds_mysql_upgrade_architecture.png
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.database import RDS
from diagrams.aws.security import SecretsManager, IAM
from diagrams.onprem.client import User
from diagrams.programming.language import Python, Bash
from diagrams.generic.compute import Rack

OUTPUT = "docs/rds_mysql_upgrade_architecture"

with Diagram(
    "RDS MySQL Upgrade Assistant",
    filename=OUTPUT,
    show=False,
    direction="LR",
    graph_attr={"fontsize": "16", "pad": "0.8", "ranksep": "1.2", "nodesep": "0.8"},
):
    dba = User("DBA")

    with Cluster("Kiro IDE / CLI"):
        kiro = Rack("Natural Language\nInterface")

    with Cluster("MCP Server (FastMCP)"):
        mcp = Python("8 Tools\nstdio")

    with Cluster("Shell Scripts"):
        with Cluster(""):
            discover = Bash("Discovery\n& Precheck")
            migrate = Bash("Parameter &\nOption Migration")
            upgrade = Bash("Blue/Green &\nIn-Place Upgrade")
            validate = Bash("Infrastructure &\nApp Validation")
            batch = Bash("Batch\nOrchestrator")

    with Cluster("AWS Cloud"):
        rds_blue = RDS("RDS MySQL 8.0")
        rds_green = RDS("RDS MySQL 8.4")
        secrets = SecretsManager("Secrets\nManager")
        iam = IAM("IAM")

    # Flow
    dba >> kiro >> mcp >> batch

    batch >> discover
    batch >> migrate
    batch >> upgrade
    batch >> validate

    discover >> Edge(label="AWS CLI") >> iam
    discover >> Edge(label="mysql TLS") >> rds_blue
    upgrade >> Edge(label="B/G Deploy") >> rds_green
    validate >> Edge(label="verify") >> rds_green
    discover >> Edge(label="credentials") >> secrets

    rds_blue >> Edge(label="replication", style="dashed") >> rds_green

print(f"Diagram generated: {OUTPUT}.png")
