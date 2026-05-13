#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 23: S3 Data Migration
# Source: datacenter-s3-6464 → Destination: datacenter-sync-25967
# Region: us-east-1
# ============================================================

REGION="us-east-1"
SOURCE_BUCKET="datacenter-s3-6464"
DEST_BUCKET="datacenter-sync-25967"

# ============================================================
# STEP 1: CREATE THE NEW PRIVATE S3 BUCKET
# NOTE: us-east-1 does NOT use --create-bucket-configuration
# Every other region requires: --create-bucket-configuration LocationConstraint=<region>
# ============================================================

echo "=== Step 1: Creating destination bucket '$DEST_BUCKET' ==="

aws s3api create-bucket \
    --bucket "$DEST_BUCKET" \
    --region "$REGION"

# Verify bucket was created
aws s3api head-bucket --bucket "$DEST_BUCKET" \
    && echo "Bucket '$DEST_BUCKET' confirmed" \
    || echo "ERROR: Bucket creation may have failed"

# ============================================================
# STEP 2: ENFORCE PRIVATE ACCESS — BLOCK ALL PUBLIC ACCESS
# ============================================================

echo ""
echo "=== Step 2: Enabling Block Public Access ==="

aws s3api put-public-access-block \
    --bucket "$DEST_BUCKET" \
    --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Verify the settings
echo "=== Block Public Access Settings ==="
aws s3api get-public-access-block --bucket "$DEST_BUCKET"

# ============================================================
# STEP 3: INSPECT THE SOURCE BUCKET BEFORE MIGRATION
# ============================================================

echo ""
echo "=== Step 3: Source Bucket Inventory ==="
aws s3 ls s3://"$SOURCE_BUCKET" --recursive --human-readable --summarize

SOURCE_COUNT=$(aws s3api list-objects-v2 \
    --bucket "$SOURCE_BUCKET" \
    --query "length(Contents)" \
    --output text 2>/dev/null || echo "0")
echo "Total objects in source: $SOURCE_COUNT"

# ============================================================
# STEP 4: MIGRATE DATA USING aws s3 sync
# sync is idempotent — safe to re-run, only copies what's missing/changed
# ============================================================

echo ""
echo "=== Step 4: Migrating data from '$SOURCE_BUCKET' to '$DEST_BUCKET' ==="

aws s3 sync \
    s3://"$SOURCE_BUCKET" \
    s3://"$DEST_BUCKET" \
    --region "$REGION"

SYNC_EXIT=$?
if [ $SYNC_EXIT -eq 0 ]; then
    echo "Sync completed successfully"
else
    echo "ERROR: Sync exited with code $SYNC_EXIT — check errors above"
    exit $SYNC_EXIT
fi

# ============================================================
# STEP 5: VERIFY DATA CONSISTENCY
# ============================================================

echo ""
echo "=== Step 5: Data Consistency Verification ==="

echo "--- Source bucket summary ---"
aws s3 ls s3://"$SOURCE_BUCKET" --recursive --summarize | tail -3

echo ""
echo "--- Destination bucket summary ---"
aws s3 ls s3://"$DEST_BUCKET" --recursive --summarize | tail -3

# Object count comparison
SOURCE_COUNT=$(aws s3api list-objects-v2 \
    --bucket "$SOURCE_BUCKET" \
    --query "length(Contents)" \
    --output text 2>/dev/null || echo "0")

DEST_COUNT=$(aws s3api list-objects-v2 \
    --bucket "$DEST_BUCKET" \
    --query "length(Contents)" \
    --output text 2>/dev/null || echo "0")

echo ""
echo "Source object count:      $SOURCE_COUNT"
echo "Destination object count: $DEST_COUNT"

if [ "$SOURCE_COUNT" == "$DEST_COUNT" ]; then
    echo "✅ Object counts match: $SOURCE_COUNT"
else
    echo "⚠️  Count mismatch — source: $SOURCE_COUNT | dest: $DEST_COUNT"
fi

# ============================================================
# STEP 6: FINAL VERIFICATION — RE-RUN SYNC WITH --dryrun
# Zero output = both buckets are perfectly in sync
# ============================================================

echo ""
echo "=== Step 6: Final dry-run sync (should show no operations) ==="

DELTA=$(aws s3 sync \
    s3://"$SOURCE_BUCKET" \
    s3://"$DEST_BUCKET" \
    --dryrun \
    --region "$REGION" 2>&1)

if [ -z "$DELTA" ]; then
    echo "✅ VERIFIED: Both buckets are fully in sync — no differences detected"
else
    echo "⚠️  Differences detected — re-run sync to complete migration:"
    echo "$DELTA"
fi

# ============================================================
# STEP 7: SHOW DESTINATION BUCKET CONTENTS
# ============================================================

echo ""
echo "=== Step 7: Destination Bucket Contents ==="
aws s3 ls s3://"$DEST_BUCKET" --recursive --human-readable

# ============================================================
# OPTIONAL: ENABLE VERSIONING ON DESTINATION BUCKET
# ============================================================

# aws s3api put-bucket-versioning \
#     --bucket "$DEST_BUCKET" \
#     --versioning-configuration Status=Enabled
# echo "Versioning enabled on $DEST_BUCKET"

# ============================================================
# OPTIONAL: DETAILED ETag COMPARISON (for full data integrity check)
# ============================================================

# echo "=== Source ETags ==="
# aws s3api list-objects-v2 \
#     --bucket "$SOURCE_BUCKET" \
#     --query "Contents[*].{Key:Key,ETag:ETag,Size:Size}" \
#     --output table

# echo "=== Destination ETags ==="
# aws s3api list-objects-v2 \
#     --bucket "$DEST_BUCKET" \
#     --query "Contents[*].{Key:Key,ETag:ETag,Size:Size}" \
#     --output table

# ============================================================
# CLEANUP: DELETE DESTINATION BUCKET (only if undoing migration)
# ============================================================

# Step 1: Remove all objects
# aws s3 rm s3://"$DEST_BUCKET" --recursive

# Step 2: Delete the bucket
# aws s3api delete-bucket --bucket "$DEST_BUCKET" --region "$REGION"
# echo "Bucket '$DEST_BUCKET' deleted"
