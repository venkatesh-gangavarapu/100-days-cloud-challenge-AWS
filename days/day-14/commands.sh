#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 14: Terminating an EC2 Instance
# Instance: devops-ec2 | Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="devops-ec2"

# ============================================================
# STEP 1: RESOLVE AND CONFIRM THE CORRECT INSTANCE
# ============================================================

INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
        "Name=tag:Name,Values=${INSTANCE_NAME}" \
        "Name=instance-state-name,Values=running,stopped,pending" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "None" ]; then
    echo "ERROR: No active instance found with name '$INSTANCE_NAME'"
    exit 1
fi

echo "Found instance: $INSTANCE_NAME | ID: $INSTANCE_ID"

# Print full details — ALWAYS verify before a destructive operation
echo "=== Instance Details (verify before terminating) ==="
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value,State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress}" \
    --output table

# ============================================================
# STEP 2: PRE-TERMINATION CHECKS
# ============================================================

# 2a: Check termination protection
echo "=== Termination Protection ==="
TERM_PROTECTION=$(aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiTermination \
    --region "$REGION" \
    --query "DisableApiTermination.Value" \
    --output text)
echo "Termination protection: $TERM_PROTECTION"

if [ "$TERM_PROTECTION" == "True" ]; then
    echo "WARNING: Termination protection is ENABLED"
    echo "Disabling termination protection before proceeding..."
    aws ec2 modify-instance-attribute \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" \
        --no-disable-api-termination
    echo "Protection disabled"
fi

# 2b: Check attached volumes and Delete on Termination flags
echo "=== Attached Volumes (Delete on Termination status) ==="
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[*].{Device:DeviceName,VolumeId:Ebs.VolumeId,DeleteOnTermination:Ebs.DeleteOnTermination}" \
    --output table
# Volumes with DeleteOnTermination=false will SURVIVE termination
# Volumes with DeleteOnTermination=true will be DELETED with the instance

# 2c: Check for associated Elastic IPs (will remain allocated after termination)
echo "=== Associated Elastic IPs ==="
aws ec2 describe-addresses \
    --region "$REGION" \
    --filters "Name=instance-id,Values=${INSTANCE_ID}" \
    --query "Addresses[*].{IP:PublicIp,AllocationId:AllocationId,AssocID:AssociationId}" \
    --output table

# ============================================================
# STEP 3: TERMINATE THE INSTANCE
# ============================================================

echo "Terminating instance $INSTANCE_ID ($INSTANCE_NAME)..."

aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "TerminatingInstances[0].{ID:InstanceId,PreviousState:PreviousState.Name,CurrentState:CurrentState.Name}" \
    --output table

# ============================================================
# STEP 4: WAIT FOR TERMINATED STATE
# ============================================================

echo "Waiting for instance to reach 'terminated' state..."

aws ec2 wait instance-terminated \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Instance $INSTANCE_ID is now TERMINATED"

# ============================================================
# STEP 5: VERIFY TERMINATED STATE
# ============================================================

echo "=== Final State Verification ==="
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value,State:State.Name,Reason:StateTransitionReason}" \
    --output table

# ============================================================
# STEP 6: POST-TERMINATION CLEANUP CHECKS
# ============================================================

# Check for unassociated EIPs (still billing after termination)
echo "=== Unassociated EIPs in account (may need releasing) ==="
aws ec2 describe-addresses \
    --region "$REGION" \
    --query "Addresses[?AssociationId==null].{IP:PublicIp,AllocationId:AllocationId,Name:Tags[?Key=='Name']|[0].Value}" \
    --output table

# Check for orphaned volumes left over after termination
# (volumes where DeleteOnTermination was false)
echo "=== Unattached EBS Volumes (may be orphaned from terminated instance) ==="
aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=status,Values=available" \
    --query "Volumes[*].{ID:VolumeId,Name:Tags[?Key=='Name']|[0].Value,Size:Size,Type:VolumeType,Created:CreateTime}" \
    --output table

# ============================================================
# RELEASE ORPHANED EIP (if needed)
# ============================================================

# aws ec2 release-address \
#     --allocation-id <ALLOC_ID> \
#     --region "$REGION"

# ============================================================
# DELETE ORPHANED VOLUME (if no longer needed)
# ============================================================

# aws ec2 delete-volume \
#     --volume-id <VOLUME_ID> \
#     --region "$REGION"
