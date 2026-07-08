#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 41: AWS KMS — Create Key, Encrypt, and Decrypt a File
# Key: xfusion-KMS-Key | Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
KEY_ALIAS="alias/xfusion-KMS-Key"
INPUT_FILE="/root/SensitiveData.txt"
ENCRYPTED_FILE="/root/EncryptedData.bin"
DECRYPTED_FILE="/root/DecryptedData.txt"

# ============================================================
# STEP 1: VERIFY SensitiveData.txt EXISTS
# ============================================================

echo "=== Step 1: Verifying input file ==="

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: $INPUT_FILE not found on aws-client"
    exit 1
fi

echo "File: $INPUT_FILE"
echo "Content: $(cat $INPUT_FILE)"
echo "Size: $(wc -c < $INPUT_FILE) bytes"

# ============================================================
# STEP 2: CREATE SYMMETRIC KMS KEY
# Key spec: SYMMETRIC_DEFAULT = AES-256-GCM
# Key usage: ENCRYPT_DECRYPT (not signing/verification)
# Origin: AWS_KMS = key material generated and stored in AWS HSMs
# ============================================================

echo ""
echo "=== Step 2: Creating KMS key ==="

KEY_ID=$(aws kms create-key \
    --region $REGION \
    --description "xfusion-KMS-Key for sensitive data encryption and decryption" \
    --key-usage ENCRYPT_DECRYPT \
    --key-spec SYMMETRIC_DEFAULT \
    --origin AWS_KMS \
    --query "KeyMetadata.KeyId" \
    --output text)

echo "KMS Key ID: $KEY_ID"

# Create the alias
aws kms create-alias \
    --alias-name "$KEY_ALIAS" \
    --target-key-id "$KEY_ID" \
    --region $REGION

echo "Alias created: $KEY_ALIAS"

# Verify the key is enabled and ready
echo ""
echo "Key details:"
aws kms describe-key --key-id "$KEY_ID" --region $REGION \
    --query "KeyMetadata.{KeyId:KeyId,Status:KeyState,Usage:KeyUsage,Spec:KeySpec,Created:CreationDate}" \
    --output table

# ============================================================
# STEP 3: ENCRYPT SensitiveData.txt → EncryptedData.bin
#
# THE BASE64 FLOW:
#   aws kms encrypt --output text → returns CiphertextBlob as base64 string
#   | base64 --decode              → converts to raw binary bytes
#   > /root/EncryptedData.bin      → saves as binary file
#
# WHY: The task requires base64 DECODING the ciphertext.
# The validation script uses: kms decrypt --ciphertext-blob fileb://EncryptedData.bin
# fileb:// expects raw binary — NOT a base64 string.
# ============================================================

echo ""
echo "=== Step 3: Encrypting SensitiveData.txt → EncryptedData.bin ==="

aws kms encrypt \
    --region $REGION \
    --key-id "$KEY_ID" \
    --plaintext "fileb://${INPUT_FILE}" \
    --query "CiphertextBlob" \
    --output text | base64 --decode > "$ENCRYPTED_FILE"

echo "EncryptedData.bin created"
echo "Encrypted file size: $(wc -c < $ENCRYPTED_FILE) bytes"
echo "File type: $(file $ENCRYPTED_FILE)"
echo "First bytes (hex — confirms binary format, not text):"
xxd "$ENCRYPTED_FILE" | head -3

# ============================================================
# STEP 4: DECRYPT EncryptedData.bin → verify plaintext
#
# THE BASE64 FLOW (same pattern in reverse):
#   kms decrypt --ciphertext-blob fileb://EncryptedData.bin (binary input)
#   → returns Plaintext as base64 string
#   | base64 --decode → original plaintext bytes
#   > /root/DecryptedData.txt
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
# STEP 5: VERIFY — original vs decrypted
# ============================================================

echo ""
echo "=== Step 5: Verifying data integrity ==="

ORIG_HASH=$(md5sum "$INPUT_FILE" | awk '{print $1}')
DECR_HASH=$(md5sum "$DECRYPTED_FILE" | awk '{print $1}')

echo "Original MD5:  $ORIG_HASH"
echo "Decrypted MD5: $DECR_HASH"

if diff -q "$INPUT_FILE" "$DECRYPTED_FILE" > /dev/null 2>&1; then
    echo "✅ VERIFIED: Decrypted data is byte-for-byte identical to original"
else
    echo "❌ MISMATCH: Files differ!"
    echo "--- Original bytes ---"
    xxd "$INPUT_FILE"
    echo "--- Decrypted bytes ---"
    xxd "$DECRYPTED_FILE"
    exit 1
fi

# ============================================================
# STEP 6: LIST THE KEY AND ALIAS (for validation scripts)
# ============================================================

echo ""
echo "=== Step 6: Summary ==="

echo "--- KMS Key ---"
aws kms list-aliases --region $REGION \
    --query "Aliases[?AliasName=='${KEY_ALIAS}'].{Alias:AliasName,KeyID:TargetKeyId}" \
    --output table

echo "--- Files ---"
ls -lh /root/SensitiveData.txt /root/EncryptedData.bin /root/DecryptedData.txt

echo ""
echo "============================================"
echo "  KMS Key ID:     $KEY_ID"
echo "  KMS Alias:      $KEY_ALIAS"
echo "  Original:       $INPUT_FILE"
echo "  Encrypted:      $ENCRYPTED_FILE (raw binary)"
echo "  Verified:       ✅ Decrypted = Original"
echo ""
echo "  Validation cmd that will work:"
echo "  aws kms decrypt --ciphertext-blob fileb:///root/EncryptedData.bin \\"
echo "    --query Plaintext --output text --region $REGION | base64 --decode"
echo "============================================"

# ============================================================
# CLEANUP (commented — run to tear down)
# KMS keys have a minimum 7-day waiting period before deletion
# ============================================================

# # Schedule key for deletion (7-day minimum)
# aws kms schedule-key-deletion \
#     --key-id "$KEY_ID" \
#     --pending-window-in-days 7 \
#     --region $REGION
# echo "Key scheduled for deletion in 7 days: $KEY_ID"

# # Or disable immediately (reversible)
# aws kms disable-key --key-id "$KEY_ID" --region $REGION
# echo "Key disabled: $KEY_ID"
