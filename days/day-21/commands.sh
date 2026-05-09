#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 21: Launch EC2 Instance and Associate Elastic IP
# Instance: xfusion-ec2 | EIP: xfusion-eip | Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="xfusion-ec2"
EIP_NAME="xfusion-eip"

# ============================================================
# STEP 1: RESOLVE LATEST UBUNTU 22.04 LTS AMI
# Canonical's AWS account ID: 099720109477
# ============================================================

echo "=== Resolving latest Ubuntu 22.04 LTS AMI ==="
AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "Ubuntu 22.04 AMI: $AMI_ID"

# ============================================================
# STEP 2: RESOLVE DEFAULT VPC, SUBNET, AND SECURITY GROUP
# ============================================================

VPC_ID=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" \
    --output text)

DEFAULT_SG=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" \
    --output text)

echo "VPC: $VPC_ID | Subnet: $SUBNET_ID | SG: $DEFAULT_SG"

# ============================================================
# STEP 3: LAUNCH THE EC2 INSTANCE
# ============================================================

echo "Launching instance '$INSTANCE_NAME'..."

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$DEFAULT_SG" \
    --associate-public-ip-address \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Instance launched: $INSTANCE_ID"

# ============================================================
# STEP 4: ALLOCATE THE ELASTIC IP (can run in parallel with boot)
# ============================================================

echo "Allocating Elastic IP '$EIP_NAME'..."

ALLOCATION_ID=$(aws ec2 allocate-address \
    --region "$REGION" \
    --domain vpc \
    --tag-specifications \
        "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${EIP_NAME}}]" \
    --query "AllocationId" \
    --output text)

EIP_ADDRESS=$(aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" \
    --region "$REGION" \
    --query "Addresses[0].PublicIp" \
    --output text)

echo "EIP allocated: $EIP_ADDRESS (Allocation ID: $ALLOCATION_ID)"

# ============================================================
# STEP 5: WAIT FOR INSTANCE TO BE RUNNING
# Must wait before associating the EIP
# ============================================================

echo "Waiting for instance to reach 'running' state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Instance is running"

# ============================================================
# STEP 6: ASSOCIATE THE EIP WITH THE INSTANCE
# ============================================================

echo "Associating EIP $EIP_ADDRESS with instance $INSTANCE_ID..."

ASSOCIATION_ID=$(aws ec2 associate-address \
    --instance-id "$INSTANCE_ID" \
    --allocation-id "$ALLOCATION_ID" \
    --region "$REGION" \
    --query "AssociationId" \
    --output text)

echo "EIP associated — Association ID: $ASSOCIATION_ID"

# ============================================================
# STEP 7: VERIFY — BOTH INSTANCE AND EIP SIDES
# ============================================================

echo ""
echo "=== Instance Details ==="
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,State:State.Name,Type:InstanceType,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,AZ:Placement.AvailabilityZone}" \
    --output table

echo ""
echo "=== Elastic IP Details ==="
aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" \
    --region "$REGION" \
    --query "Addresses[0].{Name:Tags[?Key=='Name']|[0].Value,IP:PublicIp,AllocID:AllocationId,AssocID:AssociationId,InstanceId:InstanceId}" \
    --output table

echo ""
echo "============================================"
echo "  Summary"
echo "  Instance:    $INSTANCE_NAME ($INSTANCE_ID)"
echo "  Elastic IP:  $EIP_NAME ($EIP_ADDRESS)"
echo "  Association: $ASSOCIATION_ID"
echo "  SSH:         ssh -i <key.pem> ubuntu@$EIP_ADDRESS"
echo "============================================"

# ============================================================
# OPTIONAL: VERIFY EIP VIA INSTANCE METADATA
# ============================================================
# After SSHing in:
# curl -s http://169.254.169.254/latest/meta-data/public-ipv4
# Expected: the EIP address ($EIP_ADDRESS)

# ============================================================
# AUDIT: Check for any unassociated EIPs (billing leak check)
# ============================================================

echo ""
echo "=== Unassociated EIPs in account (billing check) ==="
aws ec2 describe-addresses \
    --region "$REGION" \
    --query "Addresses[?AssociationId==null].{IP:PublicIp,AllocID:AllocationId,Name:Tags[?Key=='Name']|[0].Value}" \
    --output table

# ============================================================
# CLEANUP (run when done — strict order)
# ============================================================

# 1. Disassociate EIP
# aws ec2 disassociate-address \
#     --association-id "$ASSOCIATION_ID" --region "$REGION"

# 2. Release EIP
# aws ec2 release-address \
#     --allocation-id "$ALLOCATION_ID" --region "$REGION"

# 3. Terminate instance
# aws ec2 terminate-instances \
#     --instance-ids "$INSTANCE_ID" --region "$REGION"
# aws ec2 wait instance-terminated \
#     --instance-ids "$INSTANCE_ID" --region "$REGION"

# echo "Full cleanup complete"
