#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 11: Attaching an ENI to an EC2 Instance
# Instance: datacenter-ec2 | ENI: datacenter-eni | Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="datacenter-ec2"
ENI_NAME="datacenter-eni"

# ============================================================
# STEP 1: RESOLVE INSTANCE ID AND WAIT FOR STATUS CHECKS
# ============================================================

INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Instance: $INSTANCE_NAME | ID: $INSTANCE_ID"

# Show current state
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,AZ:Placement.AvailabilityZone,Type:InstanceType}" \
    --output table

# Check status checks before proceeding
echo "Checking status checks..."
aws ec2 describe-instance-status \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "InstanceStatuses[0].{SystemStatus:SystemStatus.Status,InstanceStatus:InstanceStatus.Status}" \
    --output table

# Wait for both status checks to pass (2/2)
echo "Waiting for instance initialization to complete..."
aws ec2 wait instance-status-ok \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Status checks passed — safe to proceed"

# ============================================================
# STEP 2: RESOLVE ENI ID AND CONFIRM PRE-CONDITIONS
# ============================================================

ENI_ID=$(aws ec2 describe-network-interfaces \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${ENI_NAME}" \
    --query "NetworkInterfaces[0].NetworkInterfaceId" \
    --output text)

echo "ENI: $ENI_NAME | ID: $ENI_ID"

# Confirm ENI status and AZ
echo "=== ENI Details ==="
aws ec2 describe-network-interfaces \
    --network-interface-ids "$ENI_ID" \
    --region "$REGION" \
    --query "NetworkInterfaces[0].{ID:NetworkInterfaceId,Status:Status,AZ:AvailabilityZone,SubnetId:SubnetId,PrivateIP:PrivateIpAddress,Description:Description}" \
    --output table

# Confirm AZ match — ENI and instance MUST be in the same AZ
INSTANCE_AZ=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].Placement.AvailabilityZone" --output text)

ENI_AZ=$(aws ec2 describe-network-interfaces \
    --network-interface-ids "$ENI_ID" --region "$REGION" \
    --query "NetworkInterfaces[0].AvailabilityZone" --output text)

echo "Instance AZ: $INSTANCE_AZ"
echo "ENI AZ:      $ENI_AZ"

if [ "$INSTANCE_AZ" != "$ENI_AZ" ]; then
    echo "ERROR: AZ mismatch — cannot attach ENI from $ENI_AZ to instance in $INSTANCE_AZ"
    exit 1
fi

echo "AZ check passed — both in $INSTANCE_AZ"

# ============================================================
# STEP 3: ATTACH THE ENI
# ============================================================

echo "Attaching $ENI_ID to $INSTANCE_ID at device index 1..."

ATTACHMENT_ID=$(aws ec2 attach-network-interface \
    --network-interface-id "$ENI_ID" \
    --instance-id "$INSTANCE_ID" \
    --device-index 1 \
    --region "$REGION" \
    --query "AttachmentId" \
    --output text)

echo "Attachment ID: $ATTACHMENT_ID"

# ============================================================
# STEP 4: VERIFY ATTACHMENT STATUS IS 'attached'
# ============================================================

echo "=== ENI Attachment Status ==="
aws ec2 describe-network-interfaces \
    --network-interface-ids "$ENI_ID" \
    --region "$REGION" \
    --query "NetworkInterfaces[0].{ENI_ID:NetworkInterfaceId,Status:Status,AttachStatus:Attachment.Status,AttachID:Attachment.AttachmentId,InstanceId:Attachment.InstanceId,DeviceIndex:Attachment.DeviceIndex}" \
    --output table

# Expected:
# Status:      in-use
# AttachStatus: attached
# InstanceId:   i-xxxxxxxxxxxxxxxxx
# DeviceIndex:  1

echo "=== All ENIs on Instance ==="
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].NetworkInterfaces[*].{ENI:NetworkInterfaceId,Index:Attachment.DeviceIndex,Status:Attachment.Status,PrivateIP:PrivateIpAddress}" \
    --output table

# ============================================================
# STEP 5: VERIFY INSIDE THE OS (via SSH)
# ============================================================

# After SSH-ing in:
# ip addr show              → list all interfaces and IPs
# ip link show              → show link state
# sudo dhclient eth1        → request IP on secondary interface (if needed)

# ============================================================
# DETACH SECONDARY ENI (when needed)
# ============================================================

# Get attachment ID
# ATTACHMENT_ID=$(aws ec2 describe-network-interfaces \
#     --network-interface-ids "$ENI_ID" --region "$REGION" \
#     --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text)

# Graceful detach
# aws ec2 detach-network-interface \
#     --attachment-id "$ATTACHMENT_ID" --region "$REGION"

# Force detach (instance unresponsive)
# aws ec2 detach-network-interface \
#     --attachment-id "$ATTACHMENT_ID" --region "$REGION" --force

# Verify ENI returns to 'available'
# aws ec2 describe-network-interfaces \
#     --network-interface-ids "$ENI_ID" --region "$REGION" \
#     --query "NetworkInterfaces[0].Status" --output text

# ============================================================
# DELETE ENI (when permanently done with it)
# ============================================================

# ENI must be detached first
# aws ec2 delete-network-interface \
#     --network-interface-id "$ENI_ID" --region "$REGION"
