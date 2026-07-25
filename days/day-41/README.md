# Day 41 — AWS KMS: Create a Key, Encrypt, and Decrypt a File

> **#100DaysOfCloud | Day 41 of 100**

---

## 📌 The Task

> *Create a symmetric KMS key, encrypt a sensitive file, save the raw binary ciphertext, then decrypt and verify the result matches the original.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| KMS key alias | `xfusion-KMS-Key` |
| Key type | Symmetric, `ENCRYPT_DECRYPT` |
| Input file | `/root/SensitiveData.txt` |
| Encrypted output | `/root/EncryptedData.bin` (raw binary) |
| Verification | Decrypted content matches original |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### What Is AWS KMS?

**AWS Key Management Service (KMS)** is a managed service for creating, managing, and controlling cryptographic keys. It handles the hard parts of cryptography — secure key storage in HSMs (Hardware Security Modules), key rotation, access control via IAM policies, and a full audit trail in CloudTrail — while exposing a simple API for encrypting and decrypting data.

### Symmetric vs Asymmetric KMS Keys

| | Symmetric | Asymmetric |
|--|-----------|------------|
| **Keys** | One key for both encrypt + decrypt | Public key (encrypt) + Private key (decrypt) |
| **Use case** | AWS service integrations, envelope encryption, this task | Digital signatures, external party encryption |
| **API** | `Encrypt` / `Decrypt` both require the key | `Encrypt` uses public key, `Decrypt` uses private key |
| **Key material** | Never leaves AWS HSMs | Private key never leaves AWS HSMs |

Symmetric keys (`SYMMETRIC_DEFAULT` spec, AES-256-GCM) are the default and most common choice — used by S3-SSE, EBS, RDS, Secrets Manager, etc.

### The Base64 Dance — Why It Matters

The `aws kms encrypt` API returns the ciphertext as a **base64-encoded string** — the raw binary ciphertext is encoded to make it safe for transmission in JSON/HTTP responses and terminal output.

```
Raw bytes (binary ciphertext)
    → base64 encode → "AQIDAHj3..."  ← what the API returns
    → base64 decode → raw bytes      ← what EncryptedData.bin must contain
```

The task explicitly says "base64 decode the ciphertext and save as EncryptedData.bin" — this means the file must contain **raw binary**, not the base64 string. This matters because the validation script uses `fileb://` (`b` for binary) to pass it back to `kms decrypt`.

If you save the base64 string as-is (without decoding), `kms decrypt --ciphertext-blob fileb://EncryptedData.bin` will fail because it expects raw binary ciphertext, not ASCII characters.

### KMS Direct Encryption — 4KB Limit

KMS `Encrypt` has a hard limit of **4 KB (4,096 bytes)** per call. For files smaller than 4 KB (like a text file), this works perfectly. For large files, you need **envelope encryption**:

```
Envelope Encryption Pattern (for large data):
    1. Generate a Data Encryption Key (DEK) using kms:GenerateDataKey
    2. DEK comes back as: plaintext key + encrypted key (wrapped by KMS)
    3. Encrypt the large data locally using the plaintext DEK (e.g., AES-256)
    4. Discard the plaintext DEK — keep only the encrypted DEK alongside the encrypted data
    5. To decrypt: call kms:Decrypt on the encrypted DEK → get plaintext DEK → decrypt data locally
```

AWS services (S3, EBS, RDS) all use envelope encryption internally — the KMS key only ever encrypts the small DEK, not the actual data.

### KMS Key Policies vs IAM Policies

Every KMS key has a **key policy** — a resource-based policy that controls who can use the key. By default, a new key has a key policy granting full access to the AWS account's root user and allows IAM policies to further delegate access. This means IAM policies (user/role permissions) work for KMS operations — you don't need to modify the key policy for typical use cases.

### KMS and CloudTrail Audit Trail

Every `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey` call is logged to **AWS CloudTrail** — including who made the request, when, from which source IP, and which key was used. This audit trail is a primary compliance value of using KMS over managing your own encryption keys.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console + CLI

**The console can create the key but encryption/decryption must use the CLI.**

**Create the KMS Key (Console):**
1. **KMS Console → Customer managed keys → Create key**
2. Key type: **Symmetric** | Key usage: **Encrypt and decrypt**
3. Next → Alias: `xfusion-KMS-Key` | Description: `Key for sensitive data encryption`
4. Next → Key administrators: your IAM user
5. Next → Key users: your IAM user
6. Review → **Finish**

**Encrypt, save, and verify (CLI):**
```bash
REGION="us-east-1"
KEY_ALIAS="alias/xfusion-KMS-Key"
INPUT_FILE="/root/SensitiveData.txt"
ENCRYPTED_FILE="/root/EncryptedData.bin"
DECRYPTED_FILE="/root/DecryptedData.txt"

# Get the Key ID from the alias
KEY_ID=$(aws kms describe-key --key-id "$KEY_ALIAS" --region $REGION \
    --query "KeyMetadata.KeyId" --output text)

echo "Key ID: $KEY_ID"

# Encrypt: output is base64-encoded ciphertext
# Pipe through base64 --decode to get raw binary → EncryptedData.bin
aws kms encrypt \
    --region $REGION \
    --key-id "$KEY_ID" \
    --plaintext "fileb://${INPUT_FILE}" \
    --query "CiphertextBlob" \
    --output text | base64 --decode > "$ENCRYPTED_FILE"

echo "EncryptedData.bin created ($(wc -c < $ENCRYPTED_FILE) bytes)"

# Decrypt: input is raw binary, output is base64-encoded plaintext
# Pipe through base64 --decode to recover original bytes
aws kms decrypt \
    --region $REGION \
    --ciphertext-blob "fileb://${ENCRYPTED_FILE}" \
    --query "Plaintext" \
    --output text | base64 --decode > "$DECRYPTED_FILE"

echo "Decrypted: $(cat $DECRYPTED_FILE)"

# Verify
diff "$INPUT_FILE" "$DECRYPTED_FILE" && echo "✅ Files match" || echo "❌ Mismatch"
```

---

### Method 2 — Full AWS CLI Script

```bash
#!/bin/bash
set -e
REGION="us-east-1"
KEY_ALIAS="alias/xfusion-KMS-Key"
INPUT_FILE="/root/SensitiveData.txt"
ENCRYPTED_FILE="/root/EncryptedData.bin"
DECRYPTED_FILE="/root/DecryptedData.txt"

# ============================================================
# STEP 1: Verify input file
# ============================================================

echo "=== Step 1: Input file ==="
[ ! -f "$INPUT_FILE" ] && echo "ERROR: $INPUT_FILE not found" && exit 1
echo "Content: $(cat $INPUT_FILE)"
echo "Size: $(wc -c < $INPUT_FILE) bytes"
[O
# ============================================================
# STEP 2: Create symmetric KMS key + alias
# ============================================================

echo ""
echo "=== Step 2: Creating KMS key 'xfusion-KMS-Key' ==="

KEY_ID=$(aws kms create-key \
    --region $REGION \
    --description "xfusion-KMS-Key for sensitive data encryption and decryption" \
    --key-usage ENCRYPT_DECRYPT \
    --key-spec SYMMETRIC_DEFAULT \
    --origin AWS_KMS \
    --query "KeyMetadata.KeyId" --output text)

echo "Key ID: $KEY_ID"

aws kms create-alias \
    --alias-name "$KEY_ALIAS" \
    --target-key-id "$KEY_ID" \
    --region $REGION

echo "Alias created: $KEY_ALIAS"

aws kms describe-key --key-id "$KEY_ID" --region $REGION \
    --query "KeyMetadata.{ID:KeyId,Alias:'xfusion-KMS-Key',Status:KeyState,Usage:KeyUsage,Spec:KeySpec}" \
    --output table

# ============================================================
# STEP 3: ENCRYPT — api returns base64, we decode to binary
# ============================================================

echo ""
echo "=== Step 3: Encrypting SensitiveData.txt ==="

aws kms encrypt \
    --region $REGION \
    --key-id "$KEY_ID" \
    --plaintext "fileb://${INPUT_FILE}" \
    --query "CiphertextBlob" \
    --output text | base64 --decode > "$ENCRYPTED_FILE"

echo "EncryptedData.bin created: $ENCRYPTED_FILE"
echo "Encrypted size: $(wc -c < $ENCRYPTED_FILE) bytes"
echo "First bytes (hex, confirms binary format):"
xxd "$ENCRYPTED_FILE" | head -3

# ============================================================
# STEP 4: DECRYPT — binary input, base64 output → decode
# ============================================================

echo ""
echo "=== Step 4: Decrypting EncryptedData.bin ==="

aws kms decrypt \
    --region $REGION \
    --ciphertext-blob "fileb://${ENCRYPTED_FILE}" \
    --query "Plaintext" \
    --output text | base64 --decode > "$DECRYPTED_FILE"

echo "Decrypted content:"
cat "$DECRYPTED_FILE"

# ============================================================
# STEP 5: VERIFY
# ============================================================

echo ""
echo "=== Step 5: Verification ==="

ORIG_HASH=$(md5sum "$INPUT_FILE" | awk '{print $1}')
DECR_HASH=$(md5sum "$DECRYPTED_FILE" | awk '{print $1}')

echo "Original MD5:  $ORIG_HASH"
echo "Decrypted MD5: $DECR_HASH"

if diff -q "$INPUT_FILE" "$DECRYPTED_FILE" > /dev/null 2>&1; then
    echo "✅ SUCCESS: Decrypted data matches original file"
else
    echo "❌ MISMATCH: Decryption did not reproduce the original"
    exit 1
fi

echo ""
echo "============================================"
echo "  KMS Key:    $KEY_ID"
echo "  Alias:      $KEY_ALIAS"
echo "  Original:   $INPUT_FILE"
echo "  Encrypted:  $ENCRYPTED_FILE (binary)"
echo "  Status:     ✅ Verified"
echo "============================================"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CREATE KEY ---
KEY_ID=$(aws kms create-key \
    --description "xfusion-KMS-Key" \
    --key-usage ENCRYPT_DECRYPT \
    --region $REGION \
    --query "KeyMetadata.KeyId" --output text)

# --- CREATE ALIAS ---
aws kms create-alias \
    --alias-name alias/xfusion-KMS-Key \
    --target-key-id $KEY_ID \
    --region $REGION

# --- DESCRIBE KEY ---
aws kms describe-key --key-id $KEY_ID --region $REGION \
    --query "KeyMetadata.{ID:KeyId,State:KeyState,Usage:KeyUsage}"

# --- ENCRYPT → raw binary file ---
aws kms encrypt --key-id $KEY_ID \
    --plaintext fileb:///root/SensitiveData.txt \
    --query "CiphertextBlob" --output text \
    --region $REGION | base64 --decode > /root/EncryptedData.bin

# --- DECRYPT → original plaintext ---
aws kms decrypt \
    --ciphertext-blob fileb:///root/EncryptedData.bin \
    --query "Plaintext" --output text \
    --region $REGION | base64 --decode

# --- VERIFY ---
diff /root/SensitiveData.txt /root/DecryptedData.txt && echo "MATCH" || echo "FAIL"

# --- LIST ALIASES ---
aws kms list-aliases --region $REGION \
    --query "Aliases[?AliasName=='alias/xfusion-KMS-Key']"

# --- SCHEDULE KEY DELETION (cleanup — min 7 days waiting period) ---
aws kms schedule-key-deletion --key-id $KEY_ID \
    --pending-window-in-days 7 --region $REGION

# --- DISABLE KEY (immediate, reversible) ---
aws kms disable-key --key-id $KEY_ID --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Saving the base64 string instead of decoding it to binary**
`aws kms encrypt --output text` returns the ciphertext as a base64-encoded string. Saving that string directly as `EncryptedData.bin` would create a file of ASCII base64 characters — not binary ciphertext. When the validation script then tries `kms decrypt fileb://EncryptedData.bin`, it will fail because `fileb://` passes the raw bytes of the file as the ciphertext, and raw base64 ASCII characters are not valid KMS ciphertext. Always pipe through `| base64 --decode >` when saving the encrypted output.

**2. Using `file://` instead of `fileb://` for binary input**
`fileb://` is specifically for binary file input — it tells the CLI to read the file's raw bytes. `file://` reads the file as text (UTF-8 encoded). For `SensitiveData.txt` as the plaintext input, `file://` works fine (text is text). For `EncryptedData.bin` as the ciphertext input, you must use `fileb://` — the encrypted binary contains bytes that aren't valid UTF-8, and `file://` would corrupt or fail to read them.

**3. Trying to KMS-encrypt a file larger than 4 KB**
`kms:Encrypt` has a hard 4 KB limit per call. Attempting to encrypt a file larger than 4,096 bytes directly via this API fails with `InvalidCiphertextException` or a validation error. The solution for large files is envelope encryption: call `kms:GenerateDataKey` to get a plaintext + encrypted data key, encrypt the file locally using the plaintext key, then discard the plaintext key and store the encrypted key alongside the encrypted file.

**4. Deleting a KMS key without first checking what uses it**
KMS keys can't be immediately deleted — there's a mandatory waiting period of 7–30 days (`schedule-key-deletion`). But more importantly, deleting a KMS key used to encrypt data makes that data permanently unrecoverable. Before deleting any key, check CloudTrail for recent use, check which services reference the key (S3 buckets, EBS volumes, RDS instances, Secrets Manager secrets), and use `kms:GetKeyRotationStatus` and `kms:ListKeyPolicies` to understand who has access. In production, prefer `disable-key` (reversible) over deletion.

**5. Not setting a key alias — relying on the key ID directly**
While using the raw key ID (`KEY_ID`) in scripts works, it's fragile — if you need to rotate to a new key, you'd have to update every script that references the old ID. An alias (`alias/xfusion-KMS-Key`) provides a stable, human-readable pointer that can be remapped to a different key ID at any time without changing the scripts that use the alias. Always use aliases in production automation.

**6. Assuming the default key policy allows all IAM users**
The default key policy for a new KMS key grants the AWS account root user full access and allows IAM policies to delegate KMS permissions. This means an IAM user without explicit `kms:Encrypt` permission in their IAM policy will be denied, even if they created the key. If you're getting access denied errors, check both the key policy and the caller's IAM permissions.

---

## 🌍 Real-World Context

**KMS is the encryption backbone of AWS.** Almost every AWS service that stores data uses KMS optionally or by default for encryption at rest:
- **S3 SSE-KMS**: objects encrypted with a KMS key, per-request audit trail
- **EBS encryption**: volume data encrypted with a KMS key, transparent to the instance
- **RDS encrypted instances**: storage, snapshots, and replicas all encrypted under a KMS key
- **Secrets Manager**: secret values encrypted with a KMS key
- **Lambda environment variables**: optional KMS encryption for sensitive config values

**Envelope encryption in practice:** No AWS service actually calls `kms:Encrypt` on your data directly. They all use envelope encryption — generate a unique data key per object/volume/secret, encrypt locally with that data key, then store the encrypted data key alongside the encrypted data. KMS only ever touches small key material (32–64 bytes), not the actual data. This is why KMS can handle terabytes of encrypted EBS data while making only one API call per key generation.

**Key rotation:** AWS-managed KMS keys rotate automatically every year. Customer-managed keys (like `xfusion-KMS-Key`) support optional automatic annual rotation — `aws kms enable-key-rotation --key-id $KEY_ID`. When rotation happens, old versions of the key material are retained so previously-encrypted data can still be decrypted; new data uses the new key material. The key ID and alias don't change.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. What is envelope encryption and why does AWS use it instead of directly encrypting data with KMS?**
> Envelope encryption uses two layers: a small Data Encryption Key (DEK) generated uniquely per object, used to encrypt the actual data locally, and a KMS key used to encrypt (wrap) that DEK. The resulting ciphertext package contains the encrypted data + the encrypted DEK. To decrypt, you call `kms:Decrypt` on the encrypted DEK to recover the plaintext DEK, then use it locally to decrypt the data. AWS uses this pattern because: KMS's `Encrypt` API has a 4 KB limit (suitable for key material, not arbitrary data); the local AES-256-GCM encryption is much faster than round-tripping every byte through the KMS API; and key usage fees are minimized — one KMS call per object, not per byte. Every AWS service that "encrypts with KMS" actually uses envelope encryption under the hood.

**Q2. What is the difference between an AWS managed key and a customer managed key in KMS?**
> AWS managed keys are created and controlled by AWS on your behalf, one per service per region (e.g., `aws/s3`, `aws/ebs`). You can't change their key policy, rotation schedule, or delete them — AWS manages all lifecycle operations. They're free and simple. Customer managed keys (CMKs) are keys you create and control — you set the key policy, grant access to specific IAM users/roles, control rotation, can disable or schedule deletion, and pay per key per month plus per-API-call charges. CMKs provide full audit trail in CloudTrail, support cross-account access, and are required for fine-grained access control scenarios. Use AWS managed keys for simple encryption-at-rest requirements; use CMKs when you need to control who can decrypt specific data.

**Q3. Why does KMS have a mandatory waiting period before a key can be deleted?**
> Deleting a KMS key is irreversible and makes any data encrypted under that key permanently unrecoverable. The 7–30 day waiting period (`--pending-window-in-days`) exists to prevent accidental or hasty deletions. During the waiting period: the key can't be used for new encryption or decryption, existing resources encrypted with the key can be identified and migrated to a new key, and the deletion can be cancelled. CloudTrail shows every recent use of the key during this window, helping identify what's currently using it. In practice, most organisations `disable-key` (reversible, immediate, blocks usage without deleting) rather than scheduling deletion for active keys, only progressing to deletion once they're certain nothing depends on the key.

**Q4. A developer gets `AccessDeniedException` when calling `kms:Decrypt`. What are the two places you'd check?**
> KMS access control has two layers, and both must allow the operation for it to succeed. First, check the **IAM policy** for the developer's user or role — they need `kms:Decrypt` permission on the specific key ARN. Second, check the **KMS key policy** — the key policy must either explicitly grant the developer (or their role) `kms:Decrypt`, or have a statement allowing IAM policies to delegate access. The default key policy includes a statement enabling IAM delegation, but a custom key policy might restrict access to specific principals without including the delegation statement. Unlike most AWS resources where IAM alone is sufficient, KMS requires that both the IAM policy AND the key policy allow the operation.

**Q5. How does KMS protect key material?**
> Customer managed KMS keys' cryptographic key material is stored exclusively within FIPS 140-2 validated Hardware Security Modules (HSMs) that AWS manages. The plaintext key material never leaves the HSM — all cryptographic operations (encrypt, decrypt, sign) happen inside the HSM. When you call `kms:Encrypt`, the data travels encrypted over TLS to the KMS endpoint, gets decrypted temporarily in the HSM's protected memory, the plaintext key encrypts your data within the HSM, and the result comes back encrypted. For keys with `EXTERNAL` origin, you can import your own key material (still stored in the HSM), but AWS-origin keys are generated and fully managed by AWS's HSM fleet.

**Q6. What is the difference between `kms:Encrypt` + `kms:Decrypt` and `kms:GenerateDataKey` + `kms:Decrypt`?**
> `kms:Encrypt` takes your plaintext data (up to 4 KB) directly to KMS to be encrypted within the HSM. The ciphertext comes back to you. `kms:Decrypt` reverses this — sends the ciphertext to KMS, decryption happens in the HSM, plaintext comes back. Good for small data like passwords, tokens, or the key material in envelope encryption. `kms:GenerateDataKey` generates a fresh AES-256 key (the DEK) inside the HSM and returns two copies: the plaintext DEK and the same DEK encrypted under your CMK. You use the plaintext DEK locally with fast symmetric AES to encrypt large data, then discard the plaintext DEK. To decrypt: `kms:Decrypt` on the encrypted DEK (recovers the plaintext DEK), then decrypt the large data locally. This is the envelope encryption pattern — mandatory for anything over 4 KB.

**Q7. How would you audit which IAM entities used a specific KMS key in the last 30 days?**
> Every KMS API call (Encrypt, Decrypt, GenerateDataKey, etc.) is logged to **AWS CloudTrail** automatically. Query CloudTrail for events matching the specific key ARN: in the CloudTrail console, filter events by "Event name" = `Decrypt` and "Resource name" = the key ARN. For programmatic access: `aws cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue=arn:aws:kms:region:account:key/key-id --start-time ... --end-time ...`. The event records include the IAM principal (user/role ARN), source IP, timestamp, and the operation. For ongoing monitoring at scale, CloudTrail can stream to CloudWatch Logs where you can create metric filters and alarms for unusual KMS usage patterns — for example, an alert if `kms:Decrypt` is called from an unexpected IP address or by an unexpected role.

---

---

## 📍 Proof of Work

This learning is documented and shared on LinkedIn:
- [View on LinkedIn](https://www.linkedin.com/posts/venkatesh-gangavarapu_100daysofcloud-aws-kms-share-7480605254200332288-OP4D/)

## 📚 Resources

- [AWS Docs — AWS KMS Developer Guide](https://docs.aws.amazon.com/kms/latest/developerguide/overview.html)
- [Envelope Encryption](https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html#enveloping)
- [AWS CLI — kms encrypt](https://docs.aws.amazon.com/cli/latest/reference/kms/encrypt.html)
- [KMS Key Policies](https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html)
- [KMS Key Rotation](https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
