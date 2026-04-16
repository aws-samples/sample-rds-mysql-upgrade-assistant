# Architecture Diagrams

Render these Mermaid diagrams at https://mermaid.live or in any Markdown viewer that supports Mermaid.
For the blog, recreate using draw.io with AWS Architecture Icons.

---

## Diagram 1: Solution Architecture

```mermaid
graph TB
    subgraph User["Database Administrator"]
        DBA["👤 DBA"]
    end

    subgraph Local["Local Environment"]
        direction TB
        Kiro["🔧 Kiro IDE<br/>(Natural Language)"]
        MCP["MCP Server<br/>FastMCP / stdio<br/>8 tools"]
        Steering["📄 Steering File<br/>mysql-upgrade-guide.md"]

        subgraph Scripts["Shell Scripts (independently runnable)"]
            direction LR
            subgraph Discovery["Inventory"]
                S1["discover_instances.sh"]
            end
            subgraph Precheck["Precheck"]
                S2["mysql_precheck_run.sh<br/>+ phase1.sql (19 checks)"]
            end
            subgraph Params["Parameters"]
                S3["migrate_param_group.sh<br/>(from rds-support-tools)"]
            end
            subgraph Upgrade["Upgrade"]
                S4["create_blue_green.sh"]
                S5["monitor_blue_green.sh"]
                S6["switchover_blue_green.sh"]
                S7["in_place_upgrade.sh"]
                S8["cleanup_blue_green.sh"]
            end
            subgraph Validate["Validation"]
                S9["post_upgrade_validate.sh"]
            end
            subgraph Batch["Batch"]
                S10["batch_upgrade.sh<br/>(orchestrator)"]
            end
        end
    end

    subgraph AWS["AWS Cloud"]
        RDS["Amazon RDS<br/>MySQL 8.0 → 8.4"]
        BG["RDS Blue/Green<br/>Deployments"]
        SM["AWS Secrets<br/>Manager"]
        CW["Amazon<br/>CloudWatch"]
    end

    DBA -->|"natural language"| Kiro
    DBA -->|"direct CLI"| Scripts
    Kiro --> Steering
    Kiro -->|"MCP protocol"| MCP
    MCP -->|"subprocess"| Scripts

    S1 -->|"aws rds describe-db-instances"| RDS
    S2 -->|"mysql client"| RDS
    S3 -->|"aws rds describe/modify-db-parameters"| RDS
    S4 -->|"aws rds create-blue-green-deployment"| BG
    S5 -->|"aws rds describe-blue-green-deployments"| BG
    S6 -->|"aws rds switchover-blue-green-deployment"| BG
    S7 -->|"aws rds modify-db-instance"| RDS
    S8 -->|"aws rds delete-blue-green-deployment"| BG
    S9 -->|"aws rds + mysql client"| RDS
    S2 -.->|"credentials"| SM
    S9 -.->|"credentials"| SM
    S10 --> S1 & S2 & S3 & S4 & S5 & S6 & S9 & S8

    style AWS fill:#FF9900,color:#232F3E
    style RDS fill:#3B48CC,color:white
    style BG fill:#3B48CC,color:white
    style SM fill:#DD344C,color:white
    style CW fill:#FF4F8B,color:white
    style Kiro fill:#00A4EF,color:white
    style MCP fill:#00A4EF,color:white
```

---

## Diagram 2: Upgrade Workflow (per instance)

```mermaid
flowchart LR
    subgraph Phase1["Phase 1: Assessment"]
        A["1. Discover<br/>Instances"] --> B["2. Precheck<br/>(19 SQL checks)"]
        B --> C["3. Migrate<br/>Param Group"]
    end

    subgraph Phase2["Phase 2: Blue/Green Upgrade"]
        C --> D["4. Create<br/>Blue/Green"]
        D --> E["5. Monitor<br/>Green Ready"]
        E --> F["6. Precheck<br/>Green Env"]
        F --> G["7. Switchover"]
    end

    subgraph Phase3["Phase 3: Validation"]
        G --> H["8. Validate<br/>(5 checks)"]
        H --> I["9. Cleanup<br/>Blue Env"]
    end

    B -->|"ERROR findings"| SKIP["⛔ SKIP<br/>Instance"]

    style Phase1 fill:#E8F5E9
    style Phase2 fill:#E3F2FD
    style Phase3 fill:#FFF3E0
    style SKIP fill:#FFEBEE,color:red
```

---

## Diagram 3: Upgrade Workflow (In-Place alternative)

```mermaid
flowchart LR
    A["1. Discover"] --> B["2. Precheck"]
    B --> C["3. Migrate<br/>Params"]
    C --> D["4. In-Place<br/>Upgrade<br/>⚠️ Downtime"]
    D --> E["5. Validate"]

    B -->|"ERROR"| SKIP["⛔ SKIP"]

    style D fill:#FFF9C4
    style SKIP fill:#FFEBEE,color:red
```

---

## Diagram 4: Batch Orchestration

```mermaid
flowchart TB
    Config["batch_config.yaml<br/>100+ instances"] --> Parse["Parse Config"]
    Parse --> Dedup["Dedup Parameter Groups<br/>(migrate once per unique group)"]
    Dedup --> Queue["Instance Queue"]

    Queue --> |"concurrency=3"| Slot1["Slot 1<br/>prod-db-01<br/>🔵 Blue/Green"]
    Queue --> Slot2["Slot 2<br/>prod-db-02<br/>🔵 Blue/Green"]
    Queue --> Slot3["Slot 3<br/>dev-db-01<br/>⚡ In-Place"]

    Slot1 --> |"✅ COMPLETED"| Next1["Next instance"]
    Slot2 --> |"❌ FAILED"| Log2["Log error<br/>Continue"]
    Slot3 --> |"✅ COMPLETED"| Next3["Next instance"]

    Next1 --> Summary
    Log2 --> Summary
    Next3 --> Summary

    Summary["📊 Batch Summary<br/>Completed: 47 | Failed: 2 | Skipped: 1"]
    State["💾 batch_state.json<br/>(resume support)"]

    Queue -.-> State
    Summary -.-> State

    style Config fill:#E8EAF6
    style Summary fill:#E8F5E9
    style State fill:#FFF3E0
    style Log2 fill:#FFEBEE
```

---

## Diagram 5: Precheck Engine Detail

```mermaid
flowchart TB
    subgraph Phase1["Phase 1 — Read-Only (Safe for Production)"]
        direction TB
        C1["#1 removedSysVars ⏭️ SKIP"]
        C2["#2 sysVarsNewDefaults ⚠️"]
        C3["#3 checkTableForUpgrade → Phase 2"]
        C4["#4 foreignKeyReferences ⚠️"]
        C5["#5 authMethodUsage 🔴/⚠️"]
        C6["#6 pluginUsage 🔴/⚠️"]
        C7["#7 deprecatedDefaultAuth ⏭️ SKIP"]
        C8["#8 deprecatedRouterAuth ⏭️ SKIP"]
        C9["#9 columnDefinition 🔴"]
        C10["#10 sysVarsAllowedValues ⚠️"]
        C11["#11 invalidPrivileges ℹ️"]
        C12["#12 partitionsWithPrefixKeys 🔴"]
        C13["#13 nonInclusiveLanguage ⚠️"]
        C14["#14 memcachedPlugin 🔴"]
        C15["#15 sysSchemaObjects 🔴"]
        C16["#16 dollarSignName ⚠️"]
        C17["#17 reservedKeywords ⚠️"]
        C18["#18 deprecatedTemporalDelimiter 🔴"]
        C19["#19 spatialIndex ⚠️"]
    end

    subgraph Phase2["Phase 2 — CHECK TABLE FOR UPGRADE (Opt-in)"]
        CT["CHECK TABLE ... FOR UPGRADE<br/>on all user tables<br/>⚠️ Acquires metadata locks"]
    end

    Phase1 --> |"generates CHECK TABLE<br/>statements"| Phase2
    Phase1 --> Report["📋 Precheck Report<br/>errors / warnings / notices"]
    Phase2 --> Report

    style Phase1 fill:#E8F5E9
    style Phase2 fill:#FFF9C4
    style Report fill:#E3F2FD
```
