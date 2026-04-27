#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 10: Attaching an Elastic IP to an EC2 Instance
# Instance: nautilus-ec2 | EIP: nautilus-ec2-eip | Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="nautilus-ec2"
EIP_NAME="nautilus-ec2-eip"

# ============================================================
# STEP 1: RESOLVE INSTANCE ID
# ============================================================

INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Instance: $INSTANCE_NAME | ID: $INSTANCE_ID"

# Confirm instance state
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,CurrentPublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress}" \
    --output table

# ============================================================
# STEP 2: RESOLVE ELASTIC IP ALLOCATION ID
# ============================================================

ALLOCATION_ID=$(aws ec2 describe-addresses \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${EIP_NAME}" \
    --query "Addresses[0].AllocationId" \
    --output text)

EIP_ADDRESS=$(aws ec2 describe-addresses \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${EIP_NAME}" \
    --query "Addresses[0].PublicIp" \
    --output text)

echo "EIP Name: $EIP_NAME | Allocation ID: $ALLOCATION_ID | IP: $EIP_ADDRESS"

# ============================================================
# STEP 3: CONFIRM EIP IS CURRENTLY UNASSOCIATED
# ============================================================

echo "=== EIP Status (before association) ==="
aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" \
    --region "$REGION" \
    --query "Addresses[0].{IP:PublicIp,AllocID:AllocationId,AssocID:AssociationId,InstanceId:InstanceId}" \
    --output table
# AssociationId and InstanceId should be None

# ============================================================
# STEP 4: ASSOCIATE THE ELASTIC IP WITH THE INSTANCE
# ============================================================

echo "Associating $EIP_ADDRESS to $INSTANCE_ID..."

ASSOCIATION_ID=$(aws ec2 associate-address \
    --instance-id "$INSTANCE_ID" \
    --allocation-id "$ALLOCATION_ID" \
    --region "$REGION" \
    --query "AssociationId" \
    --output text)

echo "Association ID: $ASSOCIATION_ID"

# ============================================================
# STEP 5: VERIFY THE ASSOCIATION
# ============================================================

echo "=== EIP Status (after association) ==="
aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" \
    --region "$REGION" \
    --query "Addresses[0].{IP:PublicIp,AllocID:AllocationId,AssocID:AssociationId,InstanceId:InstanceId}" \
    --output table

echo "=== Instance Network Details (after association) ==="
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress}" \
    --output table

echo "Public IP on instance should now be: $EIP_ADDRESS"

# ============================================================
# STEP 6: SSH TEST (optional - requires security group to allow port 22)
# ============================================================

# ssh -i ~/.ssh/your-key.pem ec2-user@"$EIP_ADDRESS"

# ============================================================
# AUDIT: List ALL EIPs in region with association status
# ============================================================

echo "=== All Elastic IPs in $REGION ==="
aws ec2 describe-addresses \
    --region "$REGION" \
    --query "Addresses[*].{IP:PublicIp,AllocID:AllocationId,AssocID:AssociationId,InstanceId:InstanceId,Name:Tags[?Key=='Name']|[0].Value}" \
    --output table

# ============================================================
# AUDIT: Unassociated EIPs (costing money with no use)
# ============================================================

echo "=== Unassociated EIPs (billing without use) ==="
aws ec2 describe-addresses \
    --region "$REGION" \
    --query "Addresses[?AssociationId==null].{IP:PublicIp,AllocID:AllocationId,Name:Tags[?Key=='Name']|[0].Value}" \
    --output table

# ============================================================
# DISASSOCIATE (when needed)
# ============================================================

# aws ec2 disassociate-address \
#     --association-id "$ASSOCIATION_ID" \
#     --region "$REGION"

# ============================================================
# RELEASE (permanent — only if IP no longer needed)
# ============================================================

# Disassociate first, then:
# aws ec2 release-address \
#     --allocation-id "$ALLOCATION_ID" \
#     --region "$REGION"
