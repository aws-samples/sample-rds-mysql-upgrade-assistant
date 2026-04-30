---
name: Security Scan and Threat Model
description: Run security audit, generate threat model, and verify all mitigations
inclusion: manual
---

# Security Scan and Threat Model

Perform a comprehensive security review of the project.

## Steps

### Step 1: Code Security Audit
Review all shell scripts against these categories:
1. Password Exposure via Command Line Arguments
2. SQL Injection via Unvalidated Database Names
3. Command Injection via Unvalidated Host Parameter
4. Insufficient Input Validation
5. Information Disclosure in Error Messages
6. Unquoted Variable Expansion
7. No Connection Timeout
8. Credential Logging Risk
9. Race Condition in User Input
10. No Audit Trail
11. Insecure Temporary File Handling
12. No TLS/SSL Enforcement
13. Weak Error Handling
14. No Script Integrity Verification

Output findings to `docs/SECURITY_AUDIT.md`.

### Step 2: Threat Model (STRIDE)
Use the Threat Modeling MCP Server to:
1. Set business context
2. Add architecture components and connections
3. Identify threats using STRIDE methodology
4. Add mitigations for each threat
5. Link mitigations to threats
6. Validate code against threat model

Output to `docs/threat-model.tc.md` and `docs/threat-model.tc.json`.

### Step 3: Verify Script Integrity
Regenerate checksums and compare:
```bash
shasum -a 256 scripts/**/*.sh > CHECKSUMS.sha256.new
diff CHECKSUMS.sha256 CHECKSUMS.sha256.new
```

### Step 4: Verify Dependencies
```bash
source scripts/lib/integrity_check.sh
verify_dependencies "aws:2.0" "jq:1.5" "mysql:8.0"
```

### Step 5: Report
Summarize:
- Number of findings by severity
- Number of threats by STRIDE category
- Mitigation coverage (all threats should have mitigations)
- Overall risk posture
