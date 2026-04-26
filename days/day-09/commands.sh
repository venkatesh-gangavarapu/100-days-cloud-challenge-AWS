#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 09: Enabling EC2 Termination Protection
# Instance: datacenter-ec2 | Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="datacenter-ec2"

# ============================================================
# STEP 1: RESOLVE INSTANCE ID
# ============================================================

INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Instance: $INSTANCE_NAME | ID: $INSTANCE_ID"

# Confirm instance details
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,State:State.Name,Type:InstanceType}" \
    --output table

# ============================================================
# STEP 2: CHECK CURRENT PROTECTION STATUS (before change)
# ============================================================

echo "=== Termination Protection (before) ==="
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiTermination \
    --region "$REGION"
# false = unprotected | true = protected

echo "=== Stop Protection (current) ==="
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiStop \
    --region "$REGION"

# ============================================================
# STEP 3: ENABLE TERMINATION PROTECTION
# ============================================================

echo "Enabling termination protection on $INSTANCE_ID..."

aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --disable-api-termination

echo "Done."

# ============================================================
# STEP 4: VERIFY
# ============================================================

echo "=== Termination Protection (after) ==="
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiTermination \
    --region "$REGION"
# Expected: { "DisableApiTermination": { "Value": true } }

# ============================================================
# STEP 5: CONFIRM PROTECTION BLOCKS TERMINATION
# ============================================================
# This WILL return OperationNotPermitted — that is the correct result

echo "=== Confirming termination is blocked (expected to fail) ==="
aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    && echo "ERROR: Termination succeeded — protection not applied correctly" \
    || echo "CONFIRMED: Termination blocked — protection is active"

# ============================================================
# OPTIONAL: ENABLE STOP PROTECTION AS WELL
# ============================================================

# aws ec2 modify-instance-attribute \
#     --instance-id "$INSTANCE_ID" \
#     --region "$REGION" \
#     --disable-api-stop

# ============================================================
# OPTIONAL: DISABLE TERMINATION PROTECTION (intentional only)
# ============================================================

# Step 1: Disable protection
# aws ec2 modify-instance-attribute \
#     --instance-id "$INSTANCE_ID" \
#     --region "$REGION" \
#     --no-disable-api-termination

# Verify disabled
# aws ec2 describe-instance-attribute \
#     --instance-id "$INSTANCE_ID" \
#     --attribute disableApiTermination \
#     --region "$REGION"

# Step 2: Now terminate
# aws ec2 terminate-instances \
#     --instance-ids "$INSTANCE_ID" \
#     --region "$REGION"

# ============================================================
# ACCOUNT-WIDE AUDIT: Instances without termination protection
# ============================================================

echo "=== Running account audit for unprotected instances ==="
aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text | tr '\t' '\n' | while read id; do
    result=$(aws ec2 describe-instance-attribute \
        --instance-id "$id" \
        --attribute disableApiTermination \
        --region "$REGION" \
        --query "DisableApiTermination.Value" \
        --output text)
    [ "$result" == "False" ] && echo "$id: termination protection DISABLED"
done
