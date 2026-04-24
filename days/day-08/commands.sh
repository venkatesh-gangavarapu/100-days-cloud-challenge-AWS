#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 08: Enabling EC2 Stop Protection
# Instance: xfusion-ec2 | Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="xfusion-ec2"

# ============================================================
# STEP 1: FIND THE INSTANCE ID
# ============================================================

INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Instance: $INSTANCE_NAME | ID: $INSTANCE_ID"

# Confirm current state and type
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,State:State.Name,Type:InstanceType}" \
    --output table

# ============================================================
# STEP 2: CHECK CURRENT STOP PROTECTION STATUS
# ============================================================

echo "=== Current Stop Protection Status ==="
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiStop \
    --region "$REGION"
# false = not protected | true = protected

# Also check termination protection while we're here
echo "=== Current Termination Protection Status ==="
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiTermination \
    --region "$REGION"

# ============================================================
# STEP 3: ENABLE STOP PROTECTION
# ============================================================

echo "Enabling stop protection on $INSTANCE_ID..."

aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --disable-api-stop

echo "Stop protection enabled"

# ============================================================
# STEP 4: VERIFY
# ============================================================

echo "=== Verification: Stop Protection Status ==="
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiStop \
    --region "$REGION"
# Expected: { "DisableApiStop": { "Value": true } }

# ============================================================
# STEP 5: CONFIRM PROTECTION WORKS
# ============================================================
# Attempt to stop the instance — this SHOULD FAIL with OperationNotPermitted
# That failure is the expected and desired result

echo "=== Confirming stop is blocked (expected to fail) ==="
aws ec2 stop-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    && echo "ERROR: Stop succeeded — protection may not have applied" \
    || echo "CONFIRMED: Stop was blocked — stop protection is active"

# ============================================================
# OPTIONAL: ENABLE TERMINATION PROTECTION TOO
# ============================================================

# aws ec2 modify-instance-attribute \
#     --instance-id "$INSTANCE_ID" \
#     --region "$REGION" \
#     --disable-api-termination

# ============================================================
# OPTIONAL: DISABLE STOP PROTECTION (when legitimately needed)
# ============================================================

# Step 1: Disable protection
# aws ec2 modify-instance-attribute \
#     --instance-id "$INSTANCE_ID" \
#     --region "$REGION" \
#     --no-disable-api-stop

# Step 2: Stop the instance
# aws ec2 stop-instances \
#     --instance-ids "$INSTANCE_ID" \
#     --region "$REGION"

# ============================================================
# ACCOUNT-WIDE AUDIT: Find instances without stop protection
# ============================================================

# echo "=== Instances with stop protection DISABLED ==="
# aws ec2 describe-instances \
#     --region "$REGION" \
#     --filters "Name=instance-state-name,Values=running" \
#     --query "Reservations[*].Instances[*].InstanceId" \
#     --output text | tr '\t' '\n' | while read id; do
#     result=$(aws ec2 describe-instance-attribute \
#         --instance-id "$id" --attribute disableApiStop \
#         --region "$REGION" \
#         --query "DisableApiStop.Value" --output text)
#     [ "$result" == "False" ] && echo "$id: stop protection DISABLED"
# done
