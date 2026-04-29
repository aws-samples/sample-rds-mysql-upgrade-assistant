# Threat Model — RDS MySQL Upgrade Assistant

**Date:** 2026-04-29  
**Tool:** Threat Modeling MCP Server  
**Methodology:** STRIDE  
**Code Validation:** 22 files analyzed (*.sh, *.py, *.sql)  

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

**Description:** RDS MySQL Upgrade Assistant — an open-source CLI tool and MCP server that automates batch Blue/Green deployment upgrades for Amazon RDS MySQL 8.0 to 8.4. Includes shell scripts for discovery, SQL prechecks, parameter migration, Blue/Green lifecycle, in-place upgrades (instances and Multi-AZ DB Clusters), and validation. Python MCP server enables Kiro IDE/CLI natural language interaction.

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
| Status | Mitigated |
| Components | C002, C006 |

**Threat:** An attacker with local process access on the developer workstation, with ability to intercept or modify MCP stdio communication, can inject malicious tool calls through the MCP stdio pipe, leading to unauthorized RDS operations executed through the MCP server.

**Mitigation:** M7 — Audit logging captures all operations with user identity and AWS caller ARN.

---

### T2: Batch Misconfiguration DoS (Denial of Service)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Possible |
| Status | Mitigated |
| Components | C001, C003 |

**Threat:** An operator misconfiguring batch upgrade parameters, with access to batch configuration files, can configure high concurrency targeting all instances simultaneously, leading to simultaneous downtime across multiple production databases.

**Mitigation:** M5 — Batch orchestrator enforces configurable concurrency limits (default: 3), precheck gating, and dry-run mode.

---

### T3: Unattributable Operations (Repudiation)

| Attribute | Value |
|-----------|-------|
| Severity | Medium |
| Likelihood | Possible |
| Status | Mitigated |
| Components | C001 |

**Threat:** A malicious operator performing unauthorized upgrades, when upgrade scripts lack comprehensive audit logging, can perform destructive operations without traceable audit trail, leading to inability to attribute or investigate unauthorized database modifications.

**Mitigation:** M7 — Audit logging via `scripts/lib/audit_log.sh` logs user, timestamp, AWS caller identity, operation, instance ID, and exit code.

---

### T4: Debug Mode Credential Leak (Information Disclosure)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Unlikely |
| Status | Mitigated |
| Components | C001, C004 |

**Threat:** An operator or attacker with access to script debug output, when bash debug mode (set -x) is enabled, can capture credentials from debug trace output when scripts retrieve secrets, leading to exposure of database passwords and IAM auth tokens.

**Mitigation:** M4 — Credentials handled via Secrets Manager/IAM auth, written to `--defaults-extra-file` with `umask 077`, and unset from memory.

---

### T5: Script Tampering (Tampering)

| Attribute | Value |
|-----------|-------|
| Severity | Critical |
| Likelihood | Unlikely |
| Status | Mitigated |
| Components | C001, C003 |

**Threat:** A malicious insider or attacker with filesystem access, with write access to the script directory, can modify shell scripts to inject malicious commands during upgrade operations, leading to unauthorized modification or deletion of production RDS instances.

**Mitigation:** M8 — Script integrity verification via `scripts/lib/integrity_check.sh` + `CHECKSUMS.sha256` with SHA-256 checksums and dependency version checks.

---

### T6: CLI Password Exposure (Information Disclosure)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Possible |
| Status | Mitigated |
| Components | C001 |

**Threat:** A local user or attacker on the execution host, with access to process listing or shell history, can observe database credentials passed via `-p` CLI argument in ps output or bash_history, leading to exposure of database credentials.

**Mitigation:** M4 — Use `--secret-id` or `--iam` instead of `-p`. Deprecation warning displayed. Credentials written to temp file with `umask 077`.

---

### T7: Error Message Information Leak (Information Disclosure)

| Attribute | Value |
|-----------|-------|
| Severity | Low |
| Likelihood | Possible |
| Status | Mitigated |
| Components | C001 |

**Threat:** An attacker with access to script output or log files, when error handling exposes raw AWS API responses, can trigger error conditions to extract AWS account details, leading to disclosure of AWS account IDs and ARNs.

**Mitigation:** M2 — All error messages sanitized. Generic guidance shown without ARNs, account IDs, or internal API details.

---

### T8: MySQL MITM via Missing CA Pinning (Spoofing)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Unlikely |
| Status | Mitigated |
| Components | C001, C003 |

**Threat:** A network-level attacker with a rogue CA certificate, with network position to perform MITM on MySQL connections, can intercept MySQL connections using `ssl-mode=REQUIRED` without CA certificate pinning, leading to credential theft or data interception.

**Mitigation:** M1 — TLS enforced via `--ssl-mode=REQUIRED`. RDS CA bundle available for `VERIFY_IDENTITY` upgrade.

---

### T9: YAML Config Injection (Tampering)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Unlikely |
| Status | Mitigated |
| Components | C001 |

**Threat:** An attacker who can modify batch configuration files can inject malicious values into batch config YAML parsed by shell, leading to command injection or unintended operations on RDS instances.

**Mitigation:** M3 — All inputs validated via regex patterns for instance IDs, version numbers, ports, regions, and hostnames.

---

### T10: Excessive IAM Permissions (Elevation of Privilege)

| Attribute | Value |
|-----------|-------|
| Severity | High |
| Likelihood | Possible |
| Status | Mitigated |
| Components | C001, C003 |

**Threat:** An authorized user with excessive IAM permissions can use upgrade scripts to modify or delete RDS instances beyond intended scope, leading to unauthorized upgrade, modification, or deletion of production databases.

**Mitigation:** M6 — IAM least-privilege policies in `docs/iam-policies.json` with separate ReadOnly, Upgrade, and ParameterGroup roles and region-scoped conditions.

---

## Mitigations Summary

| ID | Mitigation | Type | Effectiveness | Status | Threats |
|----|-----------|------|---------------|--------|---------|
| M1 | Enforce TLS via `--ssl-mode=REQUIRED` for MySQL connections | Preventive | Medium | Resolved | T8 |
| M2 | Sanitize error messages — no raw AWS API output | Preventive | High | Resolved | T7 |
| M3 | Validate all inputs via regex patterns | Preventive | High | Resolved | T9 |
| M4 | Secrets Manager / IAM auth with `--defaults-extra-file` + `umask 077` | Preventive | High | Resolved | T4, T6 |
| M5 | Concurrency limits, precheck gating, dry-run mode | Preventive | High | Resolved | T2 |
| M6 | IAM least-privilege policies (`docs/iam-policies.json`) | Preventive | High | Resolved | T10 |
| M7 | Audit logging (`scripts/lib/audit_log.sh`) | Detective | High | Resolved | T1, T3 |
| M8 | Script integrity verification (`CHECKSUMS.sha256`) | Preventive | High | Resolved | T5 |

---

## Risk Summary

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 1 | ✅ Mitigated (M8) |
| High | 6 | ✅ All mitigated |
| Medium | 2 | ✅ All mitigated |
| Low | 1 | ✅ Mitigated (M2) |

**Overall Risk Posture:** Low — All 10 identified threats have implemented mitigations (8 resolved). STRIDE coverage is complete across all 6 categories.

---

## Files Implementing Security Controls

| File | Controls |
|------|----------|
| `scripts/lib/audit_log.sh` | M7 — Audit logging library |
| `scripts/lib/integrity_check.sh` | M8 — SHA-256 integrity verification |
| `CHECKSUMS.sha256` | M8 — Script checksums |
| `docs/iam-policies.json` | M6 — IAM least-privilege policies |
| `scripts/precheck/mysql_precheck_run.sh` | M1, M2, M3, M4 — TLS, error sanitization, input validation, credential handling |
| `scripts/validate/post_upgrade_validate.sh` | M1, M2, M4 — TLS, error sanitization, credential handling |
| `scripts/upgrade/create_blue_green.sh` | M2, M7, M8 — Error sanitization, audit logging, integrity check |
| `scripts/upgrade/switchover_blue_green.sh` | M2, M7, M8 — Error sanitization, audit logging, integrity check |
| `scripts/upgrade/cleanup_blue_green.sh` | M2, M7, M8 — Error sanitization, audit logging, integrity check |
| `scripts/upgrade/in_place_upgrade.sh` | M2, M3, M7, M8 — Error sanitization, input validation, audit logging, integrity check |
| `scripts/batch/batch_upgrade.sh` | M5 — Concurrency limits, precheck gating, dry-run |
