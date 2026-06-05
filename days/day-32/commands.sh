#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 32: RDS Snapshot and Restore
# Source: nautilus-rds | Snapshot: nautilus-snapshot
# Restore: nautilus-snapshot-restore | Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
SOURCE_DB="nautilus-rds"
SNAPSHOT_ID="nautilus-snapshot"
RESTORE_DB="nautilus-snapshot-restore"

# ============================================================
# STEP 1: CONFIRM SOURCE INSTANCE IS AVAILABLE
# ============================================================

echo "=== Step 1: Checking nautilus-rds status ==="

STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$SOURCE_DB" --region $REGION \
    --query "DBInstances[0].DBInstanceStatus" --output text)

echo "Current status: $STATUS"

if [ "$STATUS" != "available" ]; then
    echo "Waiting for $SOURCE_DB to become available..."
    aws rds wait db-instance-available \
        --db-instance-identifier "$SOURCE_DB" --region $REGION
fi

echo "✅ $SOURCE_DB is available — safe to take snapshot"

# Show source instance details
aws rds describe-db-instances \
    --db-instance-identifier "$SOURCE_DB" --region $REGION \
    --query "DBInstances[0].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Class:DBInstanceClass}" \
    --output table

# ============================================================
# STEP 2: TAKE MANUAL SNAPSHOT
# ============================================================

echo ""
echo "=== Step 2: Creating snapshot '$SNAPSHOT_ID' ==="

aws rds create-db-snapshot \
    --region $REGION \
    --db-instance-identifier "$SOURCE_DB" \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --tags Key=Name,Value="$SNAPSHOT_ID" \
           Key=Source,Value="$SOURCE_DB"

echo "Snapshot creation started"

echo "Waiting for snapshot to become available (~3-5 minutes)..."
aws rds wait db-snapshot-available \
    --db-snapshot-identifier "$SNAPSHOT_ID" --region $REGION

echo "✅ Snapshot '$SNAPSHOT_ID' is AVAILABLE"

# Verify snapshot
aws rds describe-db-snapshots \
    --db-snapshot-identifier "$SNAPSHOT_ID" --region $REGION \
    --query "DBSnapshots[0].{
        ID:DBSnapshotIdentifier,
        Status:Status,
        Engine:Engine,
        EngineVersion:EngineVersion,
        AllocatedGB:AllocatedStorage,
        CreatedAt:SnapshotCreateTime,
        SourceDB:DBInstanceIdentifier
    }" --output table

# ============================================================
# STEP 3: RESTORE SNAPSHOT TO NEW INSTANCE
# ============================================================

echo ""
echo "=== Step 3: Restoring '$SNAPSHOT_ID' to '$RESTORE_DB' ==="

# Get subnet group and security group from source
SUBNET_GROUP=$(aws rds describe-db-instances \
    --db-instance-identifier "$SOURCE_DB" --region $REGION \
    --query "DBInstances[0].DBSubnetGroup.DBSubnetGroupName" --output text)

VPC_SG=$(aws rds describe-db-instances \
    --db-instance-identifier "$SOURCE_DB" --region $REGION \
    --query "DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId" --output text)

echo "Subnet group: $SUBNET_GROUP"
echo "Security group: $VPC_SG"

aws rds restore-db-instance-from-db-snapshot \
    --region $REGION \
    --db-instance-identifier "$RESTORE_DB" \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --db-instance-class "db.t3.micro" \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --vpc-security-group-ids "$VPC_SG" \
    --no-publicly-accessible \
    --no-multi-az \
    --tags Key=Name,Value="$RESTORE_DB" \
           Key=RestoredFrom,Value="$SNAPSHOT_ID"

echo "Restore initiated — waiting for available (~10-15 minutes)..."

aws rds wait db-instance-available \
    --db-instance-identifier "$RESTORE_DB" --region $REGION

echo "✅ '$RESTORE_DB' is AVAILABLE"

# ============================================================
# STEP 4: FINAL VERIFICATION
# ============================================================

echo ""
echo "=== Step 4: Final Verification ==="

echo "--- Snapshot ---"
aws rds describe-db-snapshots \
    --db-snapshot-identifier "$SNAPSHOT_ID" --region $REGION \
    --query "DBSnapshots[0].{ID:DBSnapshotIdentifier,Status:Status}" \
    --output table

echo ""
echo "--- Restored Instance ---"
aws rds describe-db-instances \
    --db-instance-identifier "$RESTORE_DB" --region $REGION \
    --query "DBInstances[0].{
        ID:DBInstanceIdentifier,
        Status:DBInstanceStatus,
        Engine:Engine,
        Version:EngineVersion,
        Class:DBInstanceClass,
        Public:PubliclyAccessible,
        Endpoint:Endpoint.Address,
        Port:Endpoint.Port
    }" --output table

ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$RESTORE_DB" --region $REGION \
    --query "DBInstances[0].Endpoint.Address" --output text)

echo ""
echo "============================================"
echo "  Source:    $SOURCE_DB         ✅ available"
echo "  Snapshot:  $SNAPSHOT_ID       ✅ available"
echo "  Restored:  $RESTORE_DB        ✅ available"
echo "  Class:     db.t3.micro"
echo "  Endpoint:  $ENDPOINT"
echo "============================================"

# ============================================================
# CLEANUP (when done — uncomment)
# ============================================================

# aws rds delete-db-instance \
#     --db-instance-identifier "$RESTORE_DB" \
#     --skip-final-snapshot --region $REGION
# aws rds wait db-instance-deleted \
#     --db-instance-identifier "$RESTORE_DB" --region $REGION
# aws rds delete-db-snapshot \
#     --db-snapshot-identifier "$SNAPSHOT_ID" --region $REGION
# echo "Cleanup complete"
