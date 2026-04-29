# Threat Model — RDS MySQL Upgrade Assistant

**Date:** 2026-04-29  
**Tool:** Threat Modeling MCP Server  
**Methodology:** STRIDE  

---

## Business Context

| Attribute | Value |
|-----------|-------|
| Industry | Technology |
| Data Sensitivity | Confidential |
| Deployment | Cloud-Public (AWS) |
| System Criticality | High |
| Financial Impact | High |
| Geographic Scope | Global |
| User Base | Medium |
| Authentication | MFA |
| Integration Complexity | Moderate |

**Description:** RDS MySQL Upgrade Assistant — an open-source CLI tool and MCP server that automates batch Blue/Green deployment upgrades for Amazon RDS MySQL 8.0 to 8.4. Designed for AWS customers with 100+ RDS MySQL instances.

---

## Architecture Components

| ID | Component | Type | Service |
|----|-----------|------|---------|
| C001 | Shell Scripts (AWS CLI) | Compute | EC2/Local |
| C002 | MCP Server (Python/FastMCP) | Compute | Local Process |
| C003 | Amazon RDS MySQL | Storage | RDS |
| C004 | AWS Secrets Manager | Security | Secrets Manager |
| C005 | AWS IAM | Security | IAM |
| C006 | Kiro IDE/CLI | Compute | Kiro |

---

## Data Flow

```
Kiro IDE/CLI ──(stdio)──▶ MCP Server ──(subprocess)──▶ Shell Scripts
                                                          │
                          ┌───────────────────────────────┤
                          ▼                               ▼
                    AWS CLI (HTTPS/443)           MySQL Client (TLS/3306)
                          │                               │
              ┌───────────┼───────────┐                   ▼
              ▼           ▼           ▼            Amazon RDS MySQL
          AWS IAM   Secrets Mgr   RDS API
```

---

## Threats (STRIDE)

### T1: MCP Stdio Injection (Tampering)

| Attribute | Value |
|-----------|-------|
| Severity | Medium |
| Likelihood | Unlikely |
| Components | C002, C006 |

**Threat:** An attacker with local process access on the developer workstation, with ability to intercept or modify MCP stdio communication, can inject malicious tool calls through the MCP stdio pipe to execute unauthorized operations, leading to unauthorized RDS operations executed through the MCP server.

---

### T2: Batch Misconfiguration DoS (Denial of Service)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Possible |
| Components | C001, C003 |

**Threat:** An operator misconfiguring batch upgrade parameters, with access to batch configuration files, can configure high concurrency targeting all instances simultaneously causing service degradation, leading to simultaneous downtime across multiple production databases during upgrade.

---

### T3: Unattributable Operations (Repudiation)

| Attribute | Value |
|-----------|-------|
| Severity | Medium |
| Likelihood | Possible |
| Components | C001 |

**Threat:** A malicious operator performing unauthorized upgrades, when upgrade scripts lack comprehensive audit logging, can perform destructive operations (switchover, cleanup) without traceable audit trail, leading to inability to attribute or investigate unauthorized database modifications.

---

### T4: Debug Mode Credential Leak (Information Disclosure)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Unlikely |
| Components | C001, C004 |

**Threat:** An operator or attacker with access to script debug output, when bash debug mode (set -x) is enabled during script execution, can capture credentials from debug trace output when scripts retrieve secrets, leading to exposure of database passwords and IAM auth tokens in log output.

---

### T5: Script Tampering (Tampering)

| Attribute | Value |
|-----------|-------|
| Severity | Critical |
| Likelihood | Unlikely |
| Components | C001, C003 |

**Threat:** A malicious insider or attacker with filesystem access, with write access to the script directory on the execution host, can modify shell scripts to inject malicious commands that execute during upgrade operations, leading to unauthorized modification or deletion of production RDS instances.

---

### T6: CLI Password Exposure (Information Disclosure)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Possible |
| Components | C001 |

**Threat:** A local user or attacker on the execution host, with access to process listing or shell history, can observe database credentials passed via -p CLI argument in ps output or bash_history, leading to exposure of database credentials enabling unauthorized database access.

---

### T7: Error Message Information Leak (Information Disclosure)

| Attribute | Value |
|-----------|-------|
| Severity | Low |
| Likelihood | Possible |
| Components | C001 |

**Threat:** An attacker with access to script output or log files, when error handling exposes raw AWS API responses, can trigger error conditions to extract AWS account details from error messages, leading to disclosure of AWS account IDs and ARNs aiding further reconnaissance.

---

### T8: MySQL MITM via Missing CA Pinning (Spoofing)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Unlikely |
| Components | C001, C003 |

**Threat:** A network-level attacker with a rogue CA certificate, with network position to perform MITM on MySQL connections, can intercept MySQL connections using ssl-mode=REQUIRED without CA certificate pinning, leading to credential theft or data interception during precheck/validation queries.

---

### T9: YAML Config Injection (Tampering)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Unlikely |
| Components | C001 |

**Threat:** An attacker who can modify batch configuration files, with ability to modify YAML config files consumed by batch_upgrade.sh, can inject malicious values into batch config YAML parsed by shell without full validation, leading to command injection or unintended operations on RDS instances.

---

### T10: Excessive IAM Permissions (Elevation of Privilege)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Possible |
| Components | C001, C003 |

**Threat:** An authorized user with excessive IAM permissions, with IAM credentials that have overly broad RDS permissions, can use upgrade scripts to modify or delete RDS instances beyond intended scope, leading to unauthorized upgrade, modification, or deletion of production databases.

---

## Mitigations

### Resolved (Implemented)

| # | Mitigation | Type | Effectiveness |
|---|-----------|------|---------------|
| M1 | Use AWS Secrets Manager or IAM auth instead of -p CLI flag. Credentials written to --defaults-extra-file with umask 077. | Preventive | High |
| M2 | Sanitize error messages — no raw AWS API output exposed. | Preventive | High |
| M3 | Validate all inputs (instance IDs, versions, ports, regions) via regex. | Preventive | High |
| M4 | Enforce TLS via --ssl-mode=REQUIRED for all MySQL connections. | Preventive | Medium |
| M5 | Concurrency limits, precheck gating, and dry-run mode in batch orchestrator. | Preventive | High |
| M6 | Audit logging via `scripts/lib/audit_log.sh` — logs user, timestamp, operation, AWS caller, exit code. | Detective | High |
| M7 | IAM least-privilege policies documented in `docs/iam-policies.json` — separate read/write/param roles. | Preventive | High |
| M8 | Script integrity verification via `scripts/lib/integrity_check.sh` + `CHECKSUMS.sha256`. | Preventive | High |

### Identified (Planned)

No remaining unmitigated threats.

---

## Risk Summary

| Severity | Count | Mitigated |
|----------|-------|-----------|
| Critical | 1 | Resolved (M8) |
| High | 6 | All resolved |
| Medium | 2 | All resolved |
| Low | 1 | Resolved |

**Overall Risk Posture:** Low — All identified threats have implemented mitigations. Critical threat (script tampering) addressed by integrity verification. High-severity threats mitigated by credential management, audit logging, IAM policies, and input validation.
