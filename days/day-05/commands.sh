#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 05: Creating an AWS EBS Volume
# Volume: devops-volume | Type: gp3 | Size: 2 GiB | Region: us-east-1
# ============================================================

REGION="us-east-1"
AZ="us-east-1a"
VOLUME_NAME="devops-volume"

# ============================================================
# STEP 1: CHECK AVAILABLE AZs
# ============================================================

aws ec2 describe-availability-zones \
    --region "$REGION" \
    --query "AvailabilityZones[*].ZoneName" \
    --output table

# ============================================================
# STEP 2: CREATE THE EBS VOLUME
# ============================================================

aws ec2 create-volume \
    --region "$REGION" \
    --availability-zone "$AZ" \
    --volume-type gp3 \
    --size 2 \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${VOLUME_NAME}}]"

# Note the VolumeId from the output
# Example: vol-0abc1234def567890

# ============================================================
# STEP 3: VERIFY CREATION
# ============================================================

aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${VOLUME_NAME}" \
    --query "Volumes[*].{ID:VolumeId,Type:VolumeType,Size:Size,State:State,AZ:AvailabilityZone}" \
    --output table

# ============================================================
# ATTACH TO EC2 INSTANCE (when needed)
# ============================================================

# Replace with actual volume and instance IDs
# VOLUME_ID="vol-0abc1234def567890"
# INSTANCE_ID="i-0abc1234def567890"

# aws ec2 attach-volume \
#     --region "$REGION" \
#     --volume-id "$VOLUME_ID" \
#     --instance-id "$INSTANCE_ID" \
#     --device /dev/xvdf

# ============================================================
# FORMAT AND MOUNT (run inside the EC2 instance after attach)
# ============================================================

# lsblk                                          # confirm device is visible
# sudo mkfs -t xfs /dev/xvdf                     # format (first use only!)
# sudo mkdir /data                               # create mount point
# sudo mount /dev/xvdf /data                     # mount
# df -h /data                                    # verify
# echo "/dev/xvdf  /data  xfs  defaults,nofail  0  2" | sudo tee -a /etc/fstab  # persist

# ============================================================
# SNAPSHOT (backup)
# ============================================================

# aws ec2 create-snapshot \
#     --region "$REGION" \
#     --volume-id "$VOLUME_ID" \
#     --description "devops-volume backup" \
#     --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=${VOLUME_NAME}-snap}]"

# ============================================================
# MODIFY VOLUME (live resize or IOPS change — no downtime)
# ============================================================

# aws ec2 modify-volume \
#     --region "$REGION" \
#     --volume-id "$VOLUME_ID" \
#     --size 10 \
#     --iops 4000 \
#     --throughput 250

# ============================================================
# DETACH
# ============================================================

# Unmount inside instance first: sudo umount /data
# Then detach:
# aws ec2 detach-volume --region "$REGION" --volume-id "$VOLUME_ID"

# ============================================================
# DELETE (volume must be in 'available' state — not attached)
# ============================================================

# aws ec2 delete-volume --region "$REGION" --volume-id "$VOLUME_ID"
