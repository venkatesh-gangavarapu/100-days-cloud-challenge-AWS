#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 12: Attaching an EBS Volume to an EC2 Instance
# Instance: nautilus-ec2 | Volume: nautilus-volume | Device: /dev/sdb
# Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="nautilus-ec2"
VOLUME_NAME="nautilus-volume"
DEVICE="/dev/sdb"

# ============================================================
# STEP 1: RESOLVE INSTANCE ID
# ============================================================

INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Instance: $INSTANCE_NAME | ID: $INSTANCE_ID"

aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,AZ:Placement.AvailabilityZone,Type:InstanceType}" \
    --output table

# ============================================================
# STEP 2: RESOLVE VOLUME ID
# ============================================================

VOLUME_ID=$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${VOLUME_NAME}" \
    --query "Volumes[0].VolumeId" \
    --output text)

echo "Volume: $VOLUME_NAME | ID: $VOLUME_ID"

aws ec2 describe-volumes \
    --volume-ids "$VOLUME_ID" --region "$REGION" \
    --query "Volumes[0].{ID:VolumeId,State:State,Type:VolumeType,Size:Size,AZ:AvailabilityZone}" \
    --output table

# ============================================================
# STEP 3: AZ MATCH PRE-CHECK
# ============================================================

INSTANCE_AZ=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].Placement.AvailabilityZone" \
    --output text)

VOLUME_AZ=$(aws ec2 describe-volumes \
    --volume-ids "$VOLUME_ID" --region "$REGION" \
    --query "Volumes[0].AvailabilityZone" \
    --output text)

echo "Instance AZ : $INSTANCE_AZ"
echo "Volume AZ   : $VOLUME_AZ"

if [ "$INSTANCE_AZ" != "$VOLUME_AZ" ]; then
    echo "ERROR: AZ mismatch — cannot attach volume in $VOLUME_AZ to instance in $INSTANCE_AZ"
    exit 1
fi
echo "AZ check passed — both in $INSTANCE_AZ"

# ============================================================
# STEP 4: CONFIRM VOLUME IS IN 'available' STATE
# ============================================================

VOLUME_STATE=$(aws ec2 describe-volumes \
    --volume-ids "$VOLUME_ID" --region "$REGION" \
    --query "Volumes[0].State" --output text)

echo "Volume state: $VOLUME_STATE"

if [ "$VOLUME_STATE" != "available" ]; then
    echo "ERROR: Volume is not available (current state: $VOLUME_STATE). Cannot attach."
    exit 1
fi

# ============================================================
# STEP 5: ATTACH THE VOLUME
# ============================================================

echo "Attaching $VOLUME_ID to $INSTANCE_ID at $DEVICE..."

aws ec2 attach-volume \
    --volume-id "$VOLUME_ID" \
    --instance-id "$INSTANCE_ID" \
    --device "$DEVICE" \
    --region "$REGION"

echo "Attach request sent — polling for 'attached' status..."

# ============================================================
# STEP 6: WAIT FOR ATTACHMENT TO COMPLETE
# ============================================================

while true; do
    ATTACH_STATE=$(aws ec2 describe-volumes \
        --volume-ids "$VOLUME_ID" --region "$REGION" \
        --query "Volumes[0].Attachments[0].State" \
        --output text 2>/dev/null)
    echo "  Attachment state: $ATTACH_STATE"
    [ "$ATTACH_STATE" == "attached" ] && break
    sleep 3
done

echo "Volume is attached"

# ============================================================
# STEP 7: VERIFY — FULL ATTACHMENT DETAILS
# ============================================================

echo "=== Final Verification ==="
aws ec2 describe-volumes \
    --volume-ids "$VOLUME_ID" --region "$REGION" \
    --query "Volumes[0].{VolumeID:VolumeId,State:State,Type:VolumeType,Size:Size,AttachState:Attachments[0].State,Device:Attachments[0].Device,InstanceId:Attachments[0].InstanceId,DeleteOnTermination:Attachments[0].DeleteOnTermination}" \
    --output table

# Also verify from the instance's perspective
echo "=== All Volumes Attached to Instance ==="
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[*].{Device:DeviceName,VolumeId:Ebs.VolumeId,Status:Ebs.Status,DeleteOnTermination:Ebs.DeleteOnTermination}" \
    --output table

# ============================================================
# STEP 8: INSIDE THE OS (via SSH — run after attaching)
# ============================================================

# Find the actual device name (Nitro instances use NVMe naming)
# lsblk
# lsblk -o NAME,SERIAL                   # maps volume ID to device

# Check if there is an existing filesystem
# sudo file -s /dev/nvme1n1
# "data" = no filesystem, safe to format
# Any filesystem string = data present, do NOT format

# Format (FIRST USE ONLY — destroys data)
# sudo mkfs -t xfs /dev/nvme1n1

# Mount
# sudo mkdir -p /data
# sudo mount /dev/nvme1n1 /data
# df -h /data

# Persist with UUID (safer than device name)
# sudo blkid /dev/nvme1n1
# echo "UUID=<UUID>  /data  xfs  defaults,nofail  0  2" | sudo tee -a /etc/fstab
# sudo mount -a                           # test fstab is correct

# ============================================================
# DETACH (clean unmount first)
# ============================================================

# Inside the instance:
# sudo umount /data

# Then via CLI:
# aws ec2 detach-volume --volume-id "$VOLUME_ID" --region "$REGION"

# Verify returns to 'available'
# aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --region "$REGION" \
#     --query "Volumes[0].State" --output text
