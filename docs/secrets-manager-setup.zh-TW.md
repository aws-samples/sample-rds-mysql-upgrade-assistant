# AWS Secrets Manager 設定指南（選用）

> **此步驟為選用。** 本工具支援多種認證方式，您不需要啟用 Secrets Manager 也能正常使用。
> 如果您偏好互動式密碼輸入、IAM 資料庫認證、或 `mysql_config_editor`，可以跳過本文件。

本指南適用於希望透過 Secrets Manager 集中管理資料庫密碼的客戶，特別是需要批次升級多個執行個體的場景。

## 認證方式比較

本工具支援以下認證方式（依優先順序）：

| 方式 | 參數 | 適用場景 | 需額外設定 |
|------|------|----------|-----------|
| **Secrets Manager** | `--secret-id` | 正式環境、批次作業、需稽核 | 需建立 Secret + IAM 權限 |
| **IAM 資料庫認證** | `--iam` | 已啟用 IAM auth 的 RDS 執行個體 | 需 IAM Policy + RDS 設定 |
| **mysql_config_editor** | `--login-path` | 本機加密儲存，個人使用 | 需執行 `mysql_config_editor set` |
| **互動式輸入** | （無參數） | 臨時測試、單次執行 | 無 |

如果您只是要快速測試或升級少量執行個體，直接省略密碼參數讓腳本提示輸入即可。

---

## 為什麼選擇 Secrets Manager？

| 傳統方式 | Secrets Manager |
|---------|----------------|
| 密碼存在 `.env` 或腳本中 | 密碼集中加密存放 |
| 明文傳遞（`-p`）可在 `ps` 中看到 | 透過 API 取得，不暴露在命令列 |
| 密碼輪換需手動更新多處 | 支援自動輪換 |
| 難以稽核誰存取了密碼 | CloudTrail 完整記錄每次存取 |

## 前置需求

- AWS CLI v2 已安裝並設定（`aws configure`）
- 執行者的 IAM 身分需有 `secretsmanager:GetSecretValue` 權限
- jq 已安裝（腳本解析 JSON 用）

---

## 步驟 1：建立 Secret

### 方法 A：透過 AWS Console

1. 前往 [Secrets Manager Console](https://console.aws.amazon.com/secretsmanager/)
2. 點選 **Store a new secret**
3. Secret type 選擇 **Credentials for Amazon RDS database**
4. 輸入 **User name** 和 **Password**
5. 選擇對應的 RDS 執行個體
6. 點選 **Next**
7. Secret name 輸入有意義的名稱，例如：`prod/rds/db-01/admin`
8. 建議加上標籤：
   - `Purpose` = `rds-upgrade`
   - `Environment` = `production`
9. 點選 **Next** → **Next** → **Store**

### 方法 B：透過 AWS CLI

```bash
# 建立 Secret（JSON 格式包含 username 和 password）
aws secretsmanager create-secret \
  --name "prod/rds/db-01/admin" \
  --description "RDS MySQL prod-db-01 admin credentials for upgrade" \
  --secret-string '{"username":"admin","password":"YourSecurePassword123!"}' \
  --tags '[{"Key":"Purpose","Value":"rds-upgrade"},{"Key":"Environment","Value":"production"}]'
```

> **重要：** Secret 的 JSON 結構必須包含 `password` 欄位。本工具會從中擷取密碼。
> 建議也包含 `username` 欄位以方便管理。

### 命名建議

使用階層式命名，便於管理和權限控制：

```
prod/rds/<instance-id>/admin     # 生產環境
staging/rds/<instance-id>/admin  # 測試環境
dev/rds/<instance-id>/admin      # 開發環境
```

---

## 步驟 2：驗證 Secret 可正常讀取

```bash
# 測試讀取（確認 IAM 權限正確）
aws secretsmanager get-secret-value \
  --secret-id "prod/rds/db-01/admin" \
  --query SecretString --output text | jq .

# 預期輸出：
# {
#   "username": "admin",
#   "password": "YourSecurePassword123!"
# }
```

如果出現 `AccessDeniedException`，請確認您的 IAM 角色或使用者具備正確權限（見步驟 3）。

---

## 步驟 3：設定 IAM 權限

將以下 IAM Policy 附加到執行升級操作的 IAM 角色或使用者：

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

> **最小權限原則：** 將 `Resource` 限縮為實際使用的 Secret ARN 或前綴。

如果您的 Secret 使用了自訂 KMS 金鑰加密，還需要加入：

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

## 步驟 4：搭配本工具使用

### 單一執行個體 Precheck

```bash
./scripts/precheck/mysql_precheck_run.sh \
  -h mydb.abc123.us-west-2.rds.amazonaws.com \
  -u admin \
  --secret-id "prod/rds/db-01/admin"
```

### 批次 Precheck

```bash
./scripts/batch/batch_precheck.sh \
  -u admin \
  --secret-id "prod/rds/shared-admin" \
  --region us-west-2
```

### 透過 MCP Server（Kiro IDE）

在 Kiro 中直接說：

```
Run precheck on prod-db-01 using secret prod/rds/db-01/admin
```

Kiro 會自動呼叫 `run_precheck` 工具並帶入 `secret_id` 參數。

---

## 步驟 5：（選用）批次建立 Secret

如果有多個執行個體需要升級，可以用腳本批次建立：

```bash
#!/bin/bash
# batch_create_secrets.sh — 批次建立 Secrets Manager 密碼
#
# 使用方式：準備 CSV 檔案（instance-id,username,password）
# 範例 CSV：instances.csv
#   db-prod-01,admin,Password1
#   db-prod-02,admin,Password2

CSV_FILE="${1:-instances.csv}"
PREFIX="prod/rds"
REGION="us-west-2"

while IFS=',' read -r INSTANCE_ID USERNAME PASSWORD; do
  # 跳過標題行
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

> **安全提示：** 建立完成後請立即刪除 CSV 檔案。避免將含有明文密碼的檔案存入版本控制。

---

## 步驟 6：（選用）設定自動密碼輪換

Secrets Manager 支援自動輪換 RDS 密碼，升級前建議暫停輪換以避免干擾：

### 暫停輪換（升級期間）

```bash
# 取消輪換排程
aws secretsmanager cancel-rotate-secret \
  --secret-id "prod/rds/db-01/admin"
```

### 升級完成後重新啟用

```bash
# 重新啟用（每 30 天輪換一次）
aws secretsmanager rotate-secret \
  --secret-id "prod/rds/db-01/admin" \
  --rotation-rules '{"AutomaticallyAfterDays": 30}'
```

### 初次設定自動輪換

如果尚未設定輪換，可透過 Console：

1. 前往 Secret 詳情頁
2. 在 **Rotation configuration** 區段點選 **Edit rotation**
3. 啟用 **Automatic rotation**
4. 選擇輪換週期（建議 30 天）
5. 選擇 **Use a rotation function already created for this secret**（RDS 會自動建立 Lambda）
6. 儲存

---

## 故障排除

| 問題 | 原因 | 解決方式 |
|------|------|----------|
| `ERROR: Failed to retrieve secret` | Secret 名稱錯誤或不在同一 region | 確認 `--secret-id` 拼寫，確認 `AWS_DEFAULT_REGION` |
| `AccessDeniedException` | IAM 權限不足 | 附加步驟 3 的 Policy |
| `Secret does not contain 'password' field` | JSON 格式不正確 | 確認 Secret 內容為 `{"password":"..."}` 格式 |
| `ResourceNotFoundException` | Secret 不存在 | 用 `aws secretsmanager list-secrets` 確認名稱 |
| `DecryptionFailure` | KMS 金鑰權限不足 | 加入 KMS Decrypt 權限 |

---

## 安全最佳實踐

1. **最小權限** — IAM Policy 的 Resource 限定到特定 Secret 前綴
2. **標籤管理** — 使用 `Purpose=rds-upgrade` 標籤，搭配 IAM Condition 限縮存取範圍
3. **加密** — 正式環境使用自訂 KMS CMK（而非預設金鑰）
4. **稽核** — 啟用 CloudTrail 記錄所有 `GetSecretValue` 事件
5. **輪換** — 升級完成後啟用自動輪換
6. **清理** — 升級完成後，如不再需要的臨時 Secret 應予以刪除

---

## 相關資源

- [AWS Secrets Manager 使用者指南](https://docs.aws.amazon.com/secretsmanager/latest/userguide/)
- [Secrets Manager 搭配 RDS 使用](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_how-services-use-secrets_rds.html)
- [IAM 權限參考](./iam-policies.json)
- [自動輪換設定](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets_managed.html)
