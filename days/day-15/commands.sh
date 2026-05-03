#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 15: Creating an EBS Snapshot
# Volume: xfusion-vol | Snapshot: xfusion-vol-ss | Region: us-east-1
# ============================================================

REGION="us-east-1"
VOLUME_NAME="xfusion-vol"
SNAPSHOT_NAME="xfusion-vol-ss"
SNAPSHOT_DESC="xfusion Snapshot"

# ============================================================
# STEP 1: RESOLVE VOLUME ID
# ============================================================

VOLUME_ID=$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${VOLUME_NAME}" \
    --query "Volumes[0].VolumeId" \
    --output text)

if [ -z "$VOLUME_ID" ] || [ "$VOLUME_ID" == "None" ]; then
    echo "ERROR: Volume '$VOLUME_NAME' not found in $REGION"
    exit 1
fi

echo "Volume: $VOLUME_NAME | ID: $VOLUME_ID"

# Confirm volume details before snapshotting
echo "=== Volume Details ==="
aws ec2 describe-volumes \
    --volume-ids "$VOLUME_ID" \
    --region "$REGION" \
    --query "Volumes[0].{ID:VolumeId,State:State,Size:Size,Type:VolumeType,AZ:AvailabilityZone,Encrypted:Encrypted,Attachments:Attachments[0].InstanceId}" \
    --output table

# ============================================================
# STEP 2: CREATE THE SNAPSHOT
# ============================================================

echo "Creating snapshot '$SNAPSHOT_NAME' from volume $VOLUME_ID..."

SNAPSHOT_ID=$(aws ec2 create-snapshot \
    --volume-id "$VOLUME_ID" \
    --description "$SNAPSHOT_DESC" \
    --region "$REGION" \
    --tag-specifications \
        "ResourceType=snapshot,Tags=[{Key=Name,Value=${SNAPSHOT_NAME}},{Key=Source,Value=${VOLUME_NAME}}]" \
    --query "SnapshotId" \
    --output text)

echo "Snapshot initiated — Snapshot ID: $SNAPSHOT_ID"
echo "Status: pending"

# ============================================================
# STEP 3: MONITOR PROGRESS AND WAIT FOR COMPLETED
# ============================================================

echo "Monitoring snapshot progress..."

while true; do
    STATUS=$(aws ec2 describe-snapshots \
        --snapshot-ids "$SNAPSHOT_ID" \
        --region "$REGION" \
        --query "Snapshots[0].State" \
        --output text)
    PROGRESS=$(aws ec2 describe-snapshots \
        --snapshot-ids "$SNAPSHOT_ID" \
        --region "$REGION" \
        --query "Snapshots[0].Progress" \
        --output text)
    echo "  Status: $STATUS | Progress: $PROGRESS"
    [ "$STATUS" == "completed" ] && break
    [ "$STATUS" == "error" ] && echo "ERROR: Snapshot failed" && exit 1
    sleep 10
done

echo "Snapshot is COMPLETED: $SNAPSHOT_ID"

# Alternative: use the built-in waiter (no progress output)
# aws ec2 wait snapshot-completed \
#     --snapshot-ids "$SNAPSHOT_ID" \
#     --region "$REGION"

# ============================================================
# STEP 4: VERIFY SNAPSHOT DETAILS
# ============================================================

echo "=== Snapshot Details ==="
aws ec2 describe-snapshots \
    --snapshot-ids "$SNAPSHOT_ID" \
    --region "$REGION" \
    --query "Snapshots[0].{ID:SnapshotId,Name:Tags[?Key=='Name']|[0].Value,Status:State,Description:Description,VolumeId:VolumeId,Size:VolumeSize,Progress:Progress,Encrypted:Encrypted,StartTime:StartTime}" \
    --output table

# ============================================================
# STEP 5: LIST ALL SNAPSHOTS FOR THIS VOLUME
# ============================================================

echo "=== All Snapshots for Volume $VOLUME_ID ==="
aws ec2 describe-snapshots \
    --region "$REGION" \
    --owner-ids self \
    --filters "Name=volume-id,Values=${VOLUME_ID}" \
    --query "Snapshots[*].{ID:SnapshotId,Name:Tags[?Key=='Name']|[0].Value,Status:State,Progress:Progress,Created:StartTime}" \
    --output table

# ============================================================
# OPTIONAL: RESTORE VOLUME FROM SNAPSHOT
# ============================================================

# aws ec2 create-volume \
#     --region "$REGION" \
#     --availability-zone us-east-1a \
#     --snapshot-id "$SNAPSHOT_ID" \
#     --volume-type gp3 \
#     --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${VOLUME_NAME}-restored}]"

# ============================================================
# OPTIONAL: COPY SNAPSHOT TO ANOTHER REGION (DR)
# ============================================================

# aws ec2 copy-snapshot \
#     --source-region "$REGION" \
#     --source-snapshot-id "$SNAPSHOT_ID" \
#     --region ap-south-1 \
#     --description "DR copy of $SNAPSHOT_NAME"

# ============================================================
# ACCOUNT-WIDE AUDIT: All snapshots with status and size
# ============================================================

# aws ec2 describe-snapshots \
#     --region "$REGION" \
#     --owner-ids self \
#     --query "Snapshots[*].{ID:SnapshotId,Name:Tags[?Key=='Name']|[0].Value,Status:State,Size:VolumeSize,Created:StartTime}" \
#     --output table

# ============================================================
# CLEANUP: DELETE SNAPSHOT (only when no longer needed)
# ============================================================

# Cannot delete if referenced by an AMI — deregister AMI first
# aws ec2 delete-snapshot \
#     --snapshot-id "$SNAPSHOT_ID" \
#     --region "$REGION"
