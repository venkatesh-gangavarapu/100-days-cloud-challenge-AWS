#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 04: Enabling S3 Bucket Versioning
# Bucket: nautilus-s3-12780 | Region: us-east-1
# ============================================================

BUCKET="nautilus-s3-12780"
REGION="us-east-1"

# ============================================================
# STEP 1: CHECK CURRENT VERSIONING STATE
# ============================================================

aws s3api get-bucket-versioning \
    --bucket "$BUCKET" \
    --region "$REGION"

# Empty output {}       → versioning never enabled (unversioned)
# { "Status": "Suspended" } → was enabled, now suspended
# { "Status": "Enabled" }   → already enabled

# ============================================================
# STEP 2: ENABLE VERSIONING
# ============================================================

aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --versioning-configuration Status=Enabled

# ============================================================
# STEP 3: VERIFY
# ============================================================

aws s3api get-bucket-versioning \
    --bucket "$BUCKET" \
    --region "$REGION"

# Expected:
# {
#     "Status": "Enabled"
# }

# ============================================================
# OPTIONAL: VERIFY VERSIONING IN PRACTICE
# ============================================================

# Upload version 1
echo "version 1 content" > test-file.txt
aws s3 cp test-file.txt s3://"$BUCKET"/test-file.txt --region "$REGION"

# Overwrite with version 2
echo "version 2 content" > test-file.txt
aws s3 cp test-file.txt s3://"$BUCKET"/test-file.txt --region "$REGION"

# List all versions — both v1 and v2 should appear
aws s3api list-object-versions \
    --bucket "$BUCKET" \
    --prefix test-file.txt

# Retrieve a specific version (replace <VERSION_ID> from above output)
aws s3api get-object \
    --bucket "$BUCKET" \
    --key test-file.txt \
    --version-id <VERSION_ID> \
    recovered-v1.txt

cat recovered-v1.txt

# ============================================================
# SUSPEND VERSIONING (only if needed later)
# ============================================================

# aws s3api put-bucket-versioning \
#     --bucket "$BUCKET" \
#     --region "$REGION" \
#     --versioning-configuration Status=Suspended

# ============================================================
# PERMANENTLY DELETE A SPECIFIC VERSION
# ============================================================

# List all versions and delete markers
aws s3api list-object-versions --bucket "$BUCKET"

# Delete a specific version permanently (requires version ID)
# aws s3api delete-object \
#     --bucket "$BUCKET" \
#     --key test-file.txt \
#     --version-id <VERSION_ID>

# ============================================================
# CLEANUP TEST OBJECTS
# ============================================================

# Remove all versions of the test file (use with caution)
# aws s3api list-object-versions --bucket "$BUCKET" --prefix test-file.txt \
#     --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
#     | aws s3api delete-objects --bucket "$BUCKET" --delete file:///dev/stdin

rm -f test-file.txt recovered-v1.txt
