#!/usr/bin/env python3
"""
Generate architecture diagram for RDS MySQL Upgrade Assistant.

Requirements:
    pip install diagrams
    brew install graphviz  (macOS)

Usage:
    python docs/generate_architecture_diagram.py

Output:
    docs/rds_mysql_upgrade_architecture.png
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.database import RDS
from diagrams.aws.security import SecretsManager, IAM
from diagrams.aws.management import Cloudwatch
from diagrams.custom import Custom
from diagrams.onprem.client import User
from diagrams.programming.language import Python, Bash
from diagrams.generic.compute import Rack

# Output path
OUTPUT = "docs/rds_mysql_upgrade_architecture"

with Diagram(
    "RDS MySQL Upgrade Assistant",
    filename=OUTPUT,
    show=False,
    direction="TB",
    graph_attr={"fontsize": "14", "pad": "0.5"},
):
    dba = User("Database\nAdministrator")

    with Cluster("Developer Workstation / EC2"):
        with Cluster("Kiro IDE / CLI"):
            kiro = Rack("Kiro\n(Natural Language)")

        with Cluster("MCP Server"):
            mcp = Python("FastMCP\n(stdio)")

        with Cluster("Shell Scripts"):
            with Cluster("Discovery & Precheck"):
                discover = Bash("discover_instances.sh")
                precheck = Bash("mysql_precheck_run.sh\n+ phase1.sql")
                gen_config = Bash("generate_config.sh")

            with Cluster("Parameter & Option Migration"):
                param_migrate = Bash("migrate_param_group.sh")
                option_check = Bash("check_option_group.sh")
                prepare_param = Bash("prepare_param_group.sh")

            with Cluster("Upgrade Lifecycle"):
                create_bg = Bash("create_blue_green.sh")
                monitor_bg = Bash("monitor_blue_green.sh")
                pre_sw = Bash("pre_switchover_check.sh")
                switchover = Bash("switchover_blue_green.sh")
                in_place = Bash("in_place_upgrade.sh")
                cleanup = Bash("cleanup_blue_green.sh")

            with Cluster("Validation"):
                infra_validate = Bash("post_upgrade_validate.sh")
                app_validate = Bash("app_validate_run.sh")

            with Cluster("Orchestration"):
                batch = Bash("batch_upgrade.sh")

            with Cluster("Security Libraries"):
                audit = Bash("lib/audit_log.sh")
                integrity = Bash("lib/integrity_check.sh")

    with Cluster("AWS Cloud"):
        with Cluster("Amazon RDS"):
            rds_blue = RDS("MySQL 8.0\n(Blue)")
            rds_green = RDS("MySQL 8.4\n(Green)")

        secrets = SecretsManager("Secrets\nManager")
        iam = IAM("IAM")
        cw = Cloudwatch("CloudWatch")

    # Connections
    dba >> Edge(label="natural language") >> kiro
    dba >> Edge(label="shell direct") >> batch

    kiro >> Edge(label="stdio") >> mcp
    mcp >> Edge(label="subprocess") >> batch

    batch >> discover
    batch >> precheck
    batch >> gen_config
    batch >> param_migrate
    batch >> option_check
    batch >> create_bg
    batch >> monitor_bg
    batch >> pre_sw
    batch >> switchover
    batch >> in_place
    batch >> infra_validate
    batch >> app_validate
    batch >> cleanup

    # AWS connections
    discover >> Edge(label="AWS CLI") >> iam
    precheck >> Edge(label="mysql TLS") >> rds_blue
    create_bg >> Edge(label="create B/G") >> rds_green
    switchover >> Edge(label="switchover") >> rds_green
    in_place >> Edge(label="modify") >> rds_blue
    precheck >> Edge(label="get secret") >> secrets
    infra_validate >> Edge(label="describe") >> rds_green

    # Blue to Green
    rds_blue >> Edge(label="replication", style="dashed") >> rds_green

print(f"Diagram generated: {OUTPUT}.png")
