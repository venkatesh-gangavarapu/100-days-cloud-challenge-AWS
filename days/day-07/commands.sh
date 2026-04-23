#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 07: Changing EC2 Instance Type (t2.micro → t2.nano)
# Instance: nautilus-ec2 | Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="nautilus-ec2"
TARGET_TYPE="t2.nano"

# ============================================================
# STEP 1: FIND THE INSTANCE ID
# ============================================================

INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
        "Name=tag:Name,Values=${INSTANCE_NAME}" \
        "Name=instance-state-name,Values=running,stopped,pending" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Found instance: $INSTANCE_ID"

# Confirm current state and instance type
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,Type:InstanceType,State:State.Name}" \
    --output table

# ============================================================
# STEP 2: WAIT FOR STATUS CHECKS TO PASS (if initializing)
# ============================================================

echo "Checking status checks..."

aws ec2 describe-instance-status \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "InstanceStatuses[0].{SystemStatus:SystemStatus.Status,InstanceStatus:InstanceStatus.Status}" \
    --output table

echo "Waiting for both status checks to pass..."
aws ec2 wait instance-status-ok \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Status checks passed — safe to proceed"

# ============================================================
# STEP 3: STOP THE INSTANCE
# ============================================================

echo "Stopping instance $INSTANCE_ID..."
aws ec2 stop-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Waiting for instance to reach stopped state..."
aws ec2 wait instance-stopped \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Instance is stopped"

# Confirm stopped state
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,Type:InstanceType}" \
    --output table

# ============================================================
# STEP 4: CHANGE THE INSTANCE TYPE
# ============================================================

echo "Changing instance type to $TARGET_TYPE..."
aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --instance-type "{\"Value\": \"${TARGET_TYPE}\"}"

echo "Instance type updated to $TARGET_TYPE"

# ============================================================
# STEP 5: START THE INSTANCE
# ============================================================

echo "Starting instance..."
aws ec2 start-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Waiting for running state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Instance is running"

# ============================================================
# STEP 6: VERIFY
# ============================================================

echo "=== Final Verification ==="
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,Type:InstanceType,State:State.Name,PublicIP:PublicIpAddress}" \
    --output table

# Wait for status checks to pass after restart
echo "Waiting for post-restart status checks..."
aws ec2 wait instance-status-ok \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "All status checks passed. Done."

# ============================================================
# OPTIONAL: CHECK STATUS CHECKS EXPLICITLY
# ============================================================

aws ec2 describe-instance-status \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "InstanceStatuses[0].{SystemStatus:SystemStatus.Status,InstanceStatus:InstanceStatus.Status}" \
    --output table
