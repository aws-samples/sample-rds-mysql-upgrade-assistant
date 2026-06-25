# AWS Secrets Manager Setup Guide (Optional)

> **This step is optional.** The tool supports multiple authentication methods — you do not need Secrets Manager to use it.
> If you prefer interactive password prompts, IAM database authentication, or `mysql_config_editor`, you can skip this document.

This guide is for customers who want to centrally manage database credentials through Secrets Manager, especially when batch-upgrading multiple instances.

## Authentication Methods Comparison

The tool supports the following methods (in priority order):

| Method | Parameter | Use Case | Extra Setup |
|--------|-----------|----------|-------------|
| **Secrets Manager** | `--secret-id` | Production, batch operations, audit required | Create Secret + IAM permissions |
| **IAM Database Auth** | `--iam` | RDS instances with IAM auth enabled | IAM Policy + RDS configuration |
| **mysql_config_editor** | `--login-path` | Local encrypted storage, personal use | Run `mysql_config_editor set` |
| **Interactive prompt** | (none) | Quick tests, one-off runs | None |

For quick testing or upgrading a few instances, simply omit the password parameter and the script will prompt you interactively.

---

## Why Choose Secrets Manager?

| Traditional Approach | Secrets Manager |
|---------------------|----------------|
| Passwords stored in `.env` or scripts | Centralized encrypted storage |
| Plaintext via `-p` visible in `ps` output | Retrieved via API, never exposed on command line |
| Password rotation requires manual updates | Supports automatic rotation |
| Difficult to audit who accessed credentials | CloudTrail records every access |

## Prerequisites

- AWS CLI v2 installed and configured (`aws configure`)
- IAM identity with `secretsmanager:GetSecretValue` permission
- jq installed (for JSON parsing in scripts)

---

## Step 1: Create a Secret

### Option A: Via AWS Console

1. Go to [Secrets Manager Console](https://console.aws.amazon.com/secretsmanager/)
2. Click **Store a new secret**
3. Select **Credentials for Amazon RDS database** as the secret type
4. Enter **User name** and **Password**
5. Select the corresponding RDS instance
6. Click **Next**
7. Enter a meaningful secret name, e.g.: `prod/rds/db-01/admin`
8. Recommended tags:
   - `Purpose` = `rds-upgrade`
   - `Environment` = `production`
9. Click **Next** → **Next** → **Store**

### Option B: Via AWS CLI

```bash
# Create a secret (JSON with username and password)
aws secretsmanager create-secret \
  --name "prod/rds/db-01/admin" \
  --description "RDS MySQL prod-db-01 admin credentials for upgrade" \
  --secret-string '{"username":"admin","password":"YourSecurePassword123!"}' \
  --tags '[{"Key":"Purpose","Value":"rds-upgrade"},{"Key":"Environment","Value":"production"}]'
```

> **Important:** The secret JSON must contain a `password` field. The tool extracts the password from this field.
> Including a `username` field is recommended for easier management.

### Naming Conventions

Use hierarchical naming for easier management and permission control:

```
prod/rds/<instance-id>/admin     # Production
staging/rds/<instance-id>/admin  # Staging
dev/rds/<instance-id>/admin      # Development
```

---

## Step 2: Verify Secret Retrieval

```bash
# Test retrieval (confirm IAM permissions are correct)
aws secretsmanager get-secret-value \
  --secret-id "prod/rds/db-01/admin" \
  --query SecretString --output text | jq .

# Expected output:
# {
#   "username": "admin",
#   "password": "YourSecurePassword123!"
# }
```

If you get `AccessDeniedException`, verify your IAM role or user has the correct permissions (see Step 3).

---

## Step 3: Configure IAM Permissions

Attach the following IAM policy to the role or user performing upgrade operations:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SecretsManagerReadForUpgrade",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:*:*:secret:prod/rds/*"
    }
  ]
}
```

> **Least privilege:** Restrict `Resource` to the actual Secret ARNs or prefix you use.

If your secret is encrypted with a custom KMS key, also add:

```json
{
  "Sid": "KMSDecryptForSecrets",
  "Effect": "Allow",
  "Action": [
    "kms:Decrypt"
  ],
  "Resource": "arn:aws:kms:<region>:<account-id>:key/<key-id>"
}
```

---

## Step 4: Use with This Tool

### Single Instance Precheck

```bash
./scripts/precheck/mysql_precheck_run.sh \
  -h mydb.abc123.us-west-2.rds.amazonaws.com \
  -u admin \
  --secret-id "prod/rds/db-01/admin"
```

### Batch Precheck

```bash
./scripts/batch/batch_precheck.sh \
  -u admin \
  --secret-id "prod/rds/shared-admin" \
  --region us-west-2
```

### Via MCP Server (Kiro IDE)

In Kiro, simply say:

```
Run precheck on prod-db-01 using secret prod/rds/db-01/admin
```

Kiro will automatically call the `run_precheck` tool with the `secret_id` parameter.

---

## Step 5: (Optional) Batch-Create Secrets

If you have multiple instances to upgrade, use a script to create secrets in bulk:

```bash
#!/bin/bash
# batch_create_secrets.sh — Batch-create Secrets Manager entries
#
# Usage: Prepare a CSV file (instance-id,username,password)
# Example CSV: instances.csv
#   db-prod-01,admin,Password1
#   db-prod-02,admin,Password2

CSV_FILE="${1:-instances.csv}"
PREFIX="prod/rds"
REGION="us-west-2"

while IFS=',' read -r INSTANCE_ID USERNAME PASSWORD; do
  # Skip header row
  [[ "$INSTANCE_ID" == "instance-id" ]] && continue
  
  SECRET_NAME="${PREFIX}/${INSTANCE_ID}/${USERNAME}"
  
  echo "Creating secret: $SECRET_NAME"
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --secret-string "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}" \
    --tags "[{\"Key\":\"Purpose\",\"Value\":\"rds-upgrade\"},{\"Key\":\"InstanceId\",\"Value\":\"${INSTANCE_ID}\"}]" \
    --region "$REGION" 2>&1
  
  if [[ $? -eq 0 ]]; then
    echo "  ✓ Created: $SECRET_NAME"
  else
    echo "  ✗ Failed: $SECRET_NAME"
  fi
done < "$CSV_FILE"

echo "Done. Use --secret-prefix \"${PREFIX}/\" with generate_config.sh"
```

> **Security tip:** Delete the CSV file immediately after use. Never commit plaintext passwords to version control.

---

## Step 6: (Optional) Configure Automatic Rotation

Secrets Manager supports automatic RDS password rotation. Pause rotation during upgrades to avoid interference:

### Pause Rotation (During Upgrade)

```bash
# Cancel rotation schedule
aws secretsmanager cancel-rotate-secret \
  --secret-id "prod/rds/db-01/admin"
```

### Re-enable After Upgrade

```bash
# Re-enable (rotate every 30 days)
aws secretsmanager rotate-secret \
  --secret-id "prod/rds/db-01/admin" \
  --rotation-rules '{"AutomaticallyAfterDays": 30}'
```

### First-Time Rotation Setup

If you haven't configured rotation yet, use the Console:

1. Go to the Secret details page
2. In the **Rotation configuration** section, click **Edit rotation**
3. Enable **Automatic rotation**
4. Choose rotation interval (recommended: 30 days)
5. Select **Use a rotation function already created for this secret** (RDS auto-creates a Lambda)
6. Save

---

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| `ERROR: Failed to retrieve secret` | Wrong secret name or different region | Verify `--secret-id` spelling and `AWS_DEFAULT_REGION` |
| `AccessDeniedException` | Insufficient IAM permissions | Attach the policy from Step 3 |
| `Secret does not contain 'password' field` | Incorrect JSON format | Ensure secret contains `{"password":"..."}` format |
| `ResourceNotFoundException` | Secret does not exist | Run `aws secretsmanager list-secrets` to verify name |
| `DecryptionFailure` | Insufficient KMS key permissions | Add KMS Decrypt permission |

---

## Security Best Practices

1. **Least privilege** — Restrict IAM Policy Resource to specific Secret prefixes
2. **Tag management** — Use `Purpose=rds-upgrade` tag with IAM Conditions to limit access scope
3. **Encryption** — Use a custom KMS CMK for production (not the default key)
4. **Audit** — Enable CloudTrail to log all `GetSecretValue` events
5. **Rotation** — Enable automatic rotation after upgrade completes
6. **Cleanup** — Delete temporary secrets that are no longer needed after upgrade

---

## Related Resources

- [AWS Secrets Manager User Guide](https://docs.aws.amazon.com/secretsmanager/latest/userguide/)
- [Using Secrets Manager with RDS](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_how-services-use-secrets_rds.html)
- [IAM Policies Reference](./iam-policies.json)
- [Automatic Rotation Configuration](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets_managed.html)
