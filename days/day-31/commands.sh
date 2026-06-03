#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 31: Private RDS MySQL Instance
# DB: datacenter-rds | Engine: MySQL 8.4.x | Class: db.t3.micro
# Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
DB_ID="datacenter-rds"
DB_PASSWORD="Admin1234!"   # Change this to a strong password

# ============================================================
# STEP 1: GET DEFAULT VPC AND NETWORKING
# ============================================================

echo "=== Step 1: Getting default VPC details ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID \
    --region $REGION --query "Vpcs[0].CidrBlock" --output text)

echo "Default VPC: $VPC_ID ($VPC_CIDR)"

# Get default DB subnet group name
SUBNET_GROUP=$(aws rds describe-db-subnet-groups --region $REGION \
    --query "DBSubnetGroups[?contains(DBSubnetGroupName,'default')].DBSubnetGroupName | [0]" \
    --output text)

echo "DB Subnet Group: $SUBNET_GROUP"

# ============================================================
# STEP 2: CREATE SECURITY GROUP FOR RDS
# Allow MySQL port 3306 only from within the VPC
# ============================================================

echo ""
echo "=== Step 2: Creating RDS security group ==="

RDS_SG=$(aws ec2 create-security-group \
    --region $REGION \
    --group-name datacenter-rds-sg \
    --description "datacenter-rds MySQL port 3306 from VPC only" \
    --vpc-id $VPC_ID \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=datacenter-rds-sg}]' \
    --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $RDS_SG \
    --protocol tcp --port 3306 \
    --cidr $VPC_CIDR --region $REGION

echo "RDS SG: $RDS_SG (port 3306 from $VPC_CIDR)"

# ============================================================
# STEP 3: GET LATEST MYSQL 8.4.x VERSION
# ============================================================

echo ""
echo "=== Step 3: Resolving MySQL 8.4.x version ==="

MYSQL_VERSION=$(aws rds describe-db-engine-versions \
    --engine mysql \
    --region $REGION \
    --query "DBEngineVersions[?contains(EngineVersion,'8.4')].EngineVersion | [-1]" \
    --output text)

echo "MySQL version: $MYSQL_VERSION"

# ============================================================
# STEP 4: CREATE THE RDS INSTANCE
# Key flags:
#   --max-allocated-storage 50     → enables autoscaling up to 50 GB
#   --no-publicly-accessible       → private instance
#   --no-multi-az                  → free tier (single AZ)
# ============================================================

echo ""
echo "=== Step 4: Creating RDS instance '$DB_ID' ==="

aws rds create-db-instance \
    --region $REGION \
    --db-instance-identifier "$DB_ID" \
    --db-instance-class "db.t3.micro" \
    --engine "mysql" \
    --engine-version "$MYSQL_VERSION" \
    --master-username "admin" \
    --master-user-password "$DB_PASSWORD" \
    --allocated-storage 20 \
    --storage-type "gp2" \
    --max-allocated-storage 50 \
    --no-publicly-accessible \
    --no-multi-az \
    --backup-retention-period 7 \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --vpc-security-group-ids $RDS_SG \
    --no-deletion-protection \
    --tags Key=Name,Value="$DB_ID" Key=Environment,Value=Development

echo "RDS instance creation initiated"
echo "NOTE: This takes 10-15 minutes — waiting..."

# ============================================================
# STEP 5: WAIT FOR AVAILABLE STATUS
# ============================================================

echo ""
echo "=== Step 5: Waiting for 'available' status ==="

aws rds wait db-instance-available \
    --db-instance-identifier "$DB_ID" \
    --region $REGION

echo "✅ RDS instance is AVAILABLE"

# ============================================================
# STEP 6: VERIFY AND DISPLAY DETAILS
# ============================================================

echo ""
echo "=== Step 6: Instance details ==="

aws rds describe-db-instances \
    --db-instance-identifier "$DB_ID" \
    --region $REGION \
    --query "DBInstances[0].{
        Identifier:DBInstanceIdentifier,
        Status:DBInstanceStatus,
        Engine:Engine,
        Version:EngineVersion,
        Class:DBInstanceClass,
        AllocatedGB:AllocatedStorage,
        MaxStorageGB:MaxAllocatedStorage,
        PublicAccess:PubliclyAccessible,
        MultiAZ:MultiAZ,
        Endpoint:Endpoint.Address,
        Port:Endpoint.Port,
        AZ:AvailabilityZone
    }" --output table

ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_ID" --region $REGION \
    --query "DBInstances[0].Endpoint.Address" --output text)

echo ""
echo "============================================"
echo "  DB Identifier:    $DB_ID"
echo "  Engine:           MySQL $MYSQL_VERSION"
echo "  Instance Class:   db.t3.micro"
echo "  Storage:          20 GB (autoscales to 50 GB)"
echo "  Public Access:    No (private)"
echo "  Status:           available ✅"
echo "  Endpoint:         $ENDPOINT"
echo "  Port:             3306"
echo "  Username:         admin"
echo "============================================"

# ============================================================
# CLEANUP (when done — uncomment to run)
# ============================================================

# aws rds delete-db-instance \
#     --db-instance-identifier "$DB_ID" \
#     --skip-final-snapshot \
#     --region $REGION
# echo "Deletion initiated — takes ~5 minutes"
