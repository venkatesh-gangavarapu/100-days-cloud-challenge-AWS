#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 13: Creating an AMI from an EC2 Instance
# Source: nautilus-ec2 | AMI Name: nautilus-ec2-ami | Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="nautilus-ec2"
AMI_NAME="nautilus-ec2-ami"

# ============================================================
# STEP 1: RESOLVE INSTANCE ID
# ============================================================

INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Instance: $INSTANCE_NAME | ID: $INSTANCE_ID"

# Confirm instance details and attached volumes
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,Volumes:BlockDeviceMappings[*].DeviceName}" \
    --output table

# ============================================================
# STEP 2: CREATE THE AMI
# ============================================================

echo "Creating AMI '$AMI_NAME' from instance $INSTANCE_ID..."

AMI_ID=$(aws ec2 create-image \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "AMI created from ${INSTANCE_NAME} — migration baseline" \
    --region "$REGION" \
    --no-reboot \
    --tag-specifications \
        "ResourceType=image,Tags=[{Key=Name,Value=${AMI_NAME}},{Key=Source,Value=${INSTANCE_NAME}}]" \
        "ResourceType=snapshot,Tags=[{Key=Name,Value=${AMI_NAME}-snapshot},{Key=Source,Value=${INSTANCE_NAME}}]" \
    --query "ImageId" \
    --output text)

echo "AMI creation initiated — AMI ID: $AMI_ID"
echo "Status: pending (snapshots being created in background)"

# ============================================================
# STEP 3: WAIT FOR AMI TO REACH 'available' STATE
# ============================================================

echo "Waiting for AMI to become available (may take several minutes)..."

aws ec2 wait image-available \
    --image-ids "$AMI_ID" \
    --region "$REGION"

echo "AMI is now available: $AMI_ID"

# ============================================================
# STEP 4: VERIFY AMI DETAILS
# ============================================================

echo "=== AMI Details ==="
aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --region "$REGION" \
    --query "Images[0].{ID:ImageId,Name:Name,State:State,Created:CreationDate,Arch:Architecture,VirtType:VirtualizationType,RootDeviceType:RootDeviceType}" \
    --output table

echo "=== Block Device Mappings (Snapshots) ==="
aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --region "$REGION" \
    --query "Images[0].BlockDeviceMappings[*].{Device:DeviceName,SnapshotId:Ebs.SnapshotId,Size:Ebs.VolumeSize,VolumeType:Ebs.VolumeType,DeleteOnTermination:Ebs.DeleteOnTermination}" \
    --output table

# ============================================================
# STEP 5: LIST ALL AMIS OWNED BY THIS ACCOUNT
# ============================================================

echo "=== All AMIs in account ($REGION) ==="
aws ec2 describe-images \
    --region "$REGION" \
    --owners self \
    --query "Images[*].{ID:ImageId,Name:Name,State:State,Created:CreationDate}" \
    --output table

# ============================================================
# OPTIONAL: LAUNCH A NEW INSTANCE FROM THE AMI
# ============================================================

# DEFAULT_SG=$(aws ec2 describe-security-groups --region "$REGION" \
#     --filters "Name=group-name,Values=default" \
#     --query "SecurityGroups[0].GroupId" --output text)

# DEFAULT_SUBNET=$(aws ec2 describe-subnets --region "$REGION" \
#     --filters "Name=default-for-az,Values=true" \
#     --query "Subnets[0].SubnetId" --output text)

# aws ec2 run-instances \
#     --region "$REGION" \
#     --image-id "$AMI_ID" \
#     --instance-type t2.micro \
#     --security-group-ids "$DEFAULT_SG" \
#     --subnet-id "$DEFAULT_SUBNET" \
#     --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}-clone}]" \
#     --count 1

# ============================================================
# OPTIONAL: COPY AMI TO ANOTHER REGION
# ============================================================

# aws ec2 copy-image \
#     --source-region "$REGION" \
#     --source-image-id "$AMI_ID" \
#     --region ap-south-1 \
#     --name "$AMI_NAME" \
#     --description "DR copy from $REGION"

# ============================================================
# CLEANUP: DEREGISTER AMI + DELETE SNAPSHOTS
# (Run only when AMI is permanently no longer needed)
# ============================================================

# Step 1: Collect snapshot IDs BEFORE deregistering
# SNAPSHOT_IDS=$(aws ec2 describe-images \
#     --image-ids "$AMI_ID" --region "$REGION" \
#     --query "Images[0].BlockDeviceMappings[*].Ebs.SnapshotId" \
#     --output text)

# Step 2: Deregister the AMI
# aws ec2 deregister-image --image-id "$AMI_ID" --region "$REGION"
# echo "AMI deregistered"

# Step 3: Delete the snapshots
# for SNAP in $SNAPSHOT_IDS; do
#     echo "Deleting snapshot: $SNAP"
#     aws ec2 delete-snapshot --snapshot-id "$SNAP" --region "$REGION"
# done
# echo "Snapshots deleted"
