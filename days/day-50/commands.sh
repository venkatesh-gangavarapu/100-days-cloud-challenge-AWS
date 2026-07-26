#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 50: EBS Volume Expansion — 8 GiB → 12 GiB, Live Resize
# Instance: nautilus-ec2 | Key: /root/nautilus-keypair.pem
# Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
KEY_FILE="/root/nautilus-keypair.pem"
chmod 400 $KEY_FILE

# ============================================================
# STEP 1: IDENTIFY VOLUME ON nautilus-ec2
# ============================================================

echo "=== Step 1: Identifying volume ==="

INSTANCE_ID=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=nautilus-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

VOLUME_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId" \
    --output text)

DEVICE_NAME=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[0].DeviceName" \
    --output text)

CURRENT_SIZE=$(aws ec2 describe-volumes --volume-ids $VOLUME_ID \
    --region $REGION --query "Volumes[0].Size" --output text)

echo "Instance:      $INSTANCE_ID"
echo "Public IP:     $PUBLIC_IP"
echo "Volume ID:     $VOLUME_ID"
echo "Device name:   $DEVICE_NAME"
echo "Current size:  ${CURRENT_SIZE} GiB"

# ============================================================
# STEP 2: EXPAND VOLUME TO 12 GiB (AWS level)
# ============================================================

echo ""
echo "=== Step 2: Expanding volume to 12 GiB ==="

aws ec2 modify-volume \
    --volume-id $VOLUME_ID \
    --size 12 \
    --region $REGION \
    --query "VolumeModification.{Volume:VolumeId,State:ModificationState,From:OriginalSize,To:TargetSize}" \
    --output table

# Poll until modification is ready for filesystem extension
# 'optimizing' = blocks are available; 'completed' = fully done
echo "Polling modification state..."
while true; do
    STATE=$(aws ec2 describe-volumes-modifications \
        --volume-ids $VOLUME_ID --region $REGION \
        --query "VolumesModifications[0].ModificationState" --output text)
    echo "  State: $STATE"
    if [[ "$STATE" == "optimizing" || "$STATE" == "completed" ]]; then
        break
    fi
    sleep 10
done

echo "Volume expanded ✅ (AWS level)"

# Confirm new size
NEW_SIZE=$(aws ec2 describe-volumes --volume-ids $VOLUME_ID \
    --region $REGION --query "Volumes[0].Size" --output text)
echo "Volume size at AWS: ${NEW_SIZE} GiB"

# ============================================================
# STEP 3: EXTEND PARTITION + FILESYSTEM INSIDE THE INSTANCE
# Three-layer model:
#   AWS block device (done) → partition (growpart) → filesystem (resize2fs/xfs_growfs)
# Detect SSH user automatically (ubuntu or ec2-user)
# Detect device name and filesystem type automatically
# ============================================================

echo ""
echo "=== Step 3: Extending partition and filesystem on nautilus-ec2 ==="

# Determine SSH user
SSH_USER="ubuntu"
if ! ssh -i $KEY_FILE -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 ubuntu@${PUBLIC_IP} "echo ok" 2>/dev/null; then
    SSH_USER="ec2-user"
    echo "SSH user: ec2-user (Amazon Linux)"
else
    echo "SSH user: ubuntu"
fi

ssh -i $KEY_FILE -o StrictHostKeyChecking=no ${SSH_USER}@${PUBLIC_IP} << 'REMOTE'
set -e
echo "=== Inside nautilus-ec2 ==="

echo "--- Current layout (before) ---"
lsblk
df -hT /

echo ""
echo "--- Detecting root device ---"
ROOT_DEV=$(findmnt -n -o SOURCE /)
FS_TYPE=$(findmnt -n -o FSTYPE /)
echo "Root device:     $ROOT_DEV"
echo "Filesystem type: $FS_TYPE"

# Derive disk and partition number from the root device
# /dev/nvme0n1p1 → disk=/dev/nvme0n1, part=1
# /dev/xvda1     → disk=/dev/xvda,    part=1
if echo "$ROOT_DEV" | grep -q "nvme"; then
    DISK=$(echo $ROOT_DEV | sed 's/p[0-9]*$//')
    PART_NUM=$(echo $ROOT_DEV | grep -o 'p[0-9]*$' | tr -d 'p')
else
    DISK=$(echo $ROOT_DEV | sed 's/[0-9]*$//')
    PART_NUM=$(echo $ROOT_DEV | grep -o '[0-9]*$')
fi
echo "Disk:            $DISK"
echo "Partition #:     $PART_NUM"

echo ""
echo "--- Growing partition with growpart ---"
sudo growpart $DISK $PART_NUM
echo "Partition grown ✅"

echo ""
echo "--- Extending filesystem ---"
if [ "$FS_TYPE" = "xfs" ]; then
    sudo xfs_growfs /
    echo "XFS filesystem extended ✅"
else
    # ext4 / ext3 / ext2
    sudo resize2fs $ROOT_DEV
    echo "ext filesystem extended ✅"
fi

echo ""
echo "--- Updated layout (after) ---"
lsblk
echo ""
df -hT /

# Confirm 12 GiB
SIZE_GB=$(df -BG / | awk 'NR==2 {print $2}' | tr -d 'G')
echo ""
if [ "$SIZE_GB" -ge 12 ]; then
    echo "✅ Root filesystem is ${SIZE_GB} GiB — expansion confirmed"
else
    echo "⚠️  Root filesystem is ${SIZE_GB} GiB — check if extension completed"
fi
REMOTE

echo ""
echo "============================================"
echo "  Instance:   nautilus-ec2 ($INSTANCE_ID)"
echo "  Volume:     $VOLUME_ID"
echo "  Device:     $DEVICE_NAME"
echo "  Size:       8 GiB → 12 GiB"
echo "  IP:         $PUBLIC_IP"
echo "  Result:     ✅ Expanded without instance stop"
echo "============================================"
