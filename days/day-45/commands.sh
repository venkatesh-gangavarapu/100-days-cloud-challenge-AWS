#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 45: NAT Gateway — Private Subnet Internet Access
# VPC: nautilus-priv-vpc | NAT GW: nautilus-natgw
# S3 verification: nautilus-nat-225063692
# Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
S3_BUCKET="nautilus-nat-225063692"

# ============================================================
# STEP 1: RESOLVE EXISTING RESOURCES
# ============================================================

echo "=== Step 1: Resolving existing VPC and private subnet ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=tag:Name,Values=nautilus-priv-vpc" \
    --query "Vpcs[0].VpcId" --output text)

VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $REGION \
    --query "Vpcs[0].CidrBlock" --output text)

PRIV_SUBNET_ID=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=tag:Name,Values=nautilus-priv-subnet" \
    --query "Subnets[0].SubnetId" --output text)

PRIV_SUBNET_CIDR=$(aws ec2 describe-subnets \
    --subnet-ids $PRIV_SUBNET_ID --region $REGION \
    --query "Subnets[0].CidrBlock" --output text)

PRIV_SUBNET_AZ=$(aws ec2 describe-subnets \
    --subnet-ids $PRIV_SUBNET_ID --region $REGION \
    --query "Subnets[0].AvailabilityZone" --output text)

# Derive public subnet CIDR: increment the third octet by 1
PUB_SUBNET_CIDR=$(echo $PRIV_SUBNET_CIDR | \
    awk -F'[./]' '{print $1"."$2"."$3+1"."$4"/"$5}')

echo "VPC:            $VPC_ID ($VPC_CIDR)"
echo "Private Subnet: $PRIV_SUBNET_ID ($PRIV_SUBNET_CIDR, AZ: $PRIV_SUBNET_AZ)"
echo "Public Subnet:  (will be) $PUB_SUBNET_CIDR in $PRIV_SUBNET_AZ"

# Verify private EC2 exists
PRIV_EC2_ID=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=nautilus-priv-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

echo "Private EC2:    $PRIV_EC2_ID"

# ============================================================
# STEP 2: CREATE INTERNET GATEWAY AND ATTACH TO VPC
# ============================================================

echo ""
echo "=== Step 2: Creating Internet Gateway 'nautilus-igw' ==="

IGW_ID=$(aws ec2 create-internet-gateway \
    --region $REGION \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=nautilus-igw}]' \
    --query "InternetGateway.InternetGatewayId" --output text)

aws ec2 attach-internet-gateway \
    --internet-gateway-id $IGW_ID \
    --vpc-id $VPC_ID \
    --region $REGION

echo "IGW: $IGW_ID — attached to $VPC_ID"

# ============================================================
# STEP 3: CREATE PUBLIC SUBNET
# Same AZ as private subnet; enable auto-assign public IP
# ============================================================

echo ""
echo "=== Step 3: Creating public subnet 'nautilus-pub-subnet' ==="

PUB_SUBNET_ID=$(aws ec2 create-subnet \
    --region $REGION \
    --vpc-id $VPC_ID \
    --cidr-block $PUB_SUBNET_CIDR \
    --availability-zone $PRIV_SUBNET_AZ \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=nautilus-pub-subnet}]' \
    --query "Subnet.SubnetId" --output text)

aws ec2 modify-subnet-attribute \
    --subnet-id $PUB_SUBNET_ID \
    --map-public-ip-on-launch \
    --region $REGION

echo "Public subnet: $PUB_SUBNET_ID ($PUB_SUBNET_CIDR, AZ: $PRIV_SUBNET_AZ)"

# ============================================================
# STEP 4: CREATE PUBLIC ROUTE TABLE WITH IGW ROUTE
# Then associate it with the public subnet
# ============================================================

echo ""
echo "=== Step 4: Creating public route table 'nautilus-pub-rt' ==="

PUB_RT_ID=$(aws ec2 create-route-table \
    --region $REGION \
    --vpc-id $VPC_ID \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=nautilus-pub-rt}]' \
    --query "RouteTable.RouteTableId" --output text)

aws ec2 create-route \
    --route-table-id $PUB_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID \
    --region $REGION

aws ec2 associate-route-table \
    --route-table-id $PUB_RT_ID \
    --subnet-id $PUB_SUBNET_ID \
    --region $REGION

echo "Route table: $PUB_RT_ID (0.0.0.0/0 → $IGW_ID, associated with $PUB_SUBNET_ID)"

# ============================================================
# STEP 5: ALLOCATE EIP AND CREATE NAT GATEWAY
# NAT Gateway MUST go in the PUBLIC subnet — this is critical
# Wait for Available before updating private route table
# ============================================================

echo ""
echo "=== Step 5: Creating NAT Gateway 'nautilus-natgw' ==="

EIP_ALLOC=$(aws ec2 allocate-address \
    --domain vpc \
    --region $REGION \
    --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=nautilus-natgw-eip}]' \
    --query "AllocationId" --output text)

EIP_ADDR=$(aws ec2 describe-addresses \
    --allocation-ids $EIP_ALLOC --region $REGION \
    --query "Addresses[0].PublicIp" --output text)

echo "Elastic IP allocated: $EIP_ALLOC ($EIP_ADDR)"

NATGW_ID=$(aws ec2 create-nat-gateway \
    --region $REGION \
    --subnet-id $PUB_SUBNET_ID \
    --allocation-id $EIP_ALLOC \
    --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=nautilus-natgw}]' \
    --connectivity-type public \
    --query "NatGateway.NatGatewayId" --output text)

echo "NAT Gateway: $NATGW_ID — waiting for Available state (1-2 min)..."

aws ec2 wait nat-gateway-available \
    --nat-gateway-ids $NATGW_ID \
    --region $REGION

echo "NAT Gateway is Available"

# ============================================================
# STEP 6: UPDATE PRIVATE SUBNET ROUTE TABLE
# Find the route table that's actually associated with nautilus-priv-subnet
# (could be an explicit RT or the VPC's main RT)
# Add 0.0.0.0/0 → NAT Gateway
# ============================================================

echo ""
echo "=== Step 6: Updating private subnet route table ==="

# Check for explicit route table association first
PRIV_RT_ID=$(aws ec2 describe-route-tables --region $REGION \
    --filters "Name=association.subnet-id,Values=$PRIV_SUBNET_ID" \
    --query "RouteTables[0].RouteTableId" --output text)

if [ -z "$PRIV_RT_ID" ] || [ "$PRIV_RT_ID" == "None" ]; then
    # No explicit association — using VPC main route table
    PRIV_RT_ID=$(aws ec2 describe-route-tables --region $REGION \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
        --query "RouteTables[0].RouteTableId" --output text)
    echo "Private subnet uses VPC main route table: $PRIV_RT_ID"
else
    echo "Private subnet route table: $PRIV_RT_ID"
fi

# Remove any existing default route to avoid conflict
aws ec2 delete-route \
    --route-table-id $PRIV_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --region $REGION 2>/dev/null \
    && echo "Existing default route removed" \
    || echo "No existing default route to remove"

# Add the NAT Gateway route
aws ec2 create-route \
    --route-table-id $PRIV_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id $NATGW_ID \
    --region $REGION

echo "Route added: 0.0.0.0/0 → $NATGW_ID in $PRIV_RT_ID"

# ============================================================
# STEP 7: VERIFY ROUTE TABLE CONFIGURATION
# ============================================================

echo ""
echo "=== Step 7: Route Table Verification ==="

echo "--- Public subnet route table ($PUB_RT_ID) ---"
aws ec2 describe-route-tables \
    --route-table-ids $PUB_RT_ID --region $REGION \
    --query "RouteTables[0].Routes[*].{Dest:DestinationCidrBlock,Target:GatewayId,State:State}" \
    --output table

echo ""
echo "--- Private subnet route table ($PRIV_RT_ID) ---"
aws ec2 describe-route-tables \
    --route-table-ids $PRIV_RT_ID --region $REGION \
    --query "RouteTables[0].Routes[*].{Dest:DestinationCidrBlock,NatGW:NatGatewayId,IGW:GatewayId,State:State}" \
    --output table

# ============================================================
# STEP 8: VERIFY S3 UPLOAD FROM PRIVATE EC2
# The cron job runs every few minutes and uploads a test file
# Wait up to 3 minutes for it to appear
# ============================================================

echo ""
echo "=== Step 8: Waiting for cron job to upload to S3 (up to 3 min) ==="

for ATTEMPT in 1 2 3 4 5 6; do
    echo "Check $ATTEMPT/6 (waiting 30s)..."
    sleep 30

    S3_CONTENTS=$(aws s3 ls s3://${S3_BUCKET}/ 2>/dev/null || echo "")

    if [ -n "$S3_CONTENTS" ]; then
        echo ""
        echo "✅ SUCCESS: Files found in S3 bucket!"
        echo "$S3_CONTENTS"
        break
    fi

    if [ $ATTEMPT -eq 6 ]; then
        echo ""
        echo "⚠️  No files found after 3 minutes. Check:"
        echo "  1. Bucket name is correct: $S3_BUCKET"
        echo "  2. Cron job on nautilus-priv-ec2 is configured"
        echo "  3. EC2 instance has IAM role for S3 access"
        echo "  4. Route table update propagated correctly"
    fi
done

echo ""
echo "============================================"
echo "  VPC:           nautilus-priv-vpc ($VPC_ID)"
echo "  Public Subnet: nautilus-pub-subnet ($PUB_SUBNET_ID)"
echo "  IGW:           nautilus-igw ($IGW_ID)"
echo "  NAT Gateway:   nautilus-natgw ($NATGW_ID)"
echo "  Elastic IP:    $EIP_ADDR ($EIP_ALLOC)"
echo "  Pub RT:        nautilus-pub-rt ($PUB_RT_ID)"
echo "  Priv RT:       $PRIV_RT_ID"
echo "  S3 Bucket:     $S3_BUCKET"
echo "============================================"

# ============================================================
# CLEANUP (order matters — NAT GW must be deleted before EIP release)
# ============================================================

# aws ec2 delete-nat-gateway --nat-gateway-id $NATGW_ID --region $REGION
# aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NATGW_ID --region $REGION
# aws ec2 release-address --allocation-id $EIP_ALLOC --region $REGION
# aws ec2 delete-route --route-table-id $PRIV_RT_ID \
#     --destination-cidr-block 0.0.0.0/0 --region $REGION
# aws ec2 disassociate-route-table --association-id $ASSOC_ID --region $REGION
# aws ec2 delete-route-table --route-table-id $PUB_RT_ID --region $REGION
# aws ec2 delete-subnet --subnet-id $PUB_SUBNET_ID --region $REGION
# aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION
# aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION
