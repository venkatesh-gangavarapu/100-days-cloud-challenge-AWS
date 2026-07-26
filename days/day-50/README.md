# Day 50 — EBS Volume Expansion: Live Resize Without Downtime

> **#100DaysOfCloud | Day 50 of 100**

---

## 📌 The Task

> *Expand the EBS root volume on `nautilus-ec2` from 8 GiB to 12 GiB and ensure the root filesystem inside the instance reflects the new size — without stopping or rebooting the instance.*

**Steps:**

| Step | Action |
|------|--------|
| 1 | Identify the volume attached to `nautilus-ec2` |
| 2 | Expand volume from 8 GiB → 12 GiB via `modify-volume` |
| 3 | Extend the partition inside the instance with `growpart` |
| 4 | Extend the filesystem with `resize2fs` (ext4) or `xfs_growfs` (xfs) |

---

## 🧠 Core Concepts

### EBS Live Resize — Two Separate Operations

Expanding an EBS volume is a **two-phase process**. Phase 1 happens at the AWS control plane level; phase 2 happens inside the OS. Many people do phase 1 and stop — the volume is larger in AWS but the OS still sees the old size.

```
Phase 1 (AWS):  aws ec2 modify-volume → EBS block device is 12 GiB
                                         (visible in lsblk, invisible to df)
Phase 2 (OS):   growpart → partition table updated to use new blocks
                resize2fs or xfs_growfs → filesystem fills the partition
                                         (now visible in df -h)
```

### Why `df -h` Still Shows 8 GiB After `modify-volume`

`modify-volume` grows the underlying EBS block device. The OS doesn't automatically see this as usable space because:
- The **partition table** (GPT or MBR) still defines the partition as 8 GiB
- The **filesystem** was formatted to fill that partition

Both must be explicitly expanded. `lsblk` will show the disk has grown (the new raw device size), but `df` will still show the old size until the partition and filesystem catch up.

### `growpart` — Expanding the Partition

`growpart` modifies the partition table to extend a partition to fill available space:

```bash
sudo growpart /dev/xvda 1    # disk, partition number
# or for NVMe:
sudo growpart /dev/nvme0n1 1
```

This is safe on a live, mounted partition. The kernel re-reads the partition table without needing a reboot (on Linux kernels 3.6+).

### `resize2fs` vs `xfs_growfs`

| Filesystem | Command | Mount state |
|------------|---------|-------------|
| **ext4** | `sudo resize2fs /dev/xvda1` | Can resize mounted (online) |
| **XFS** | `sudo xfs_growfs /` | Mount point, not device |
| **ext4 (offline)** | `sudo e2fsck -f /dev/xvda1` then `resize2fs` | Only for unmounted |

Amazon Linux 2 and AL2023 typically use XFS. Ubuntu typically uses ext4.

### Detecting Device Names (xvd vs nvme)

AWS uses two device naming conventions depending on instance type:
- **Older instance types** (t2, m4): `/dev/xvda`, `/dev/xvdb` etc.
- **Nitro-based instances** (t3, m5, c5+): `/dev/nvme0n1`, `/dev/nvme1n1` etc.

The partition suffix differs too: `/dev/xvda1` vs `/dev/nvme0n1p1`. The script uses `findmnt` to detect the actual root device automatically rather than hardcoding the name.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Console + SSH

**Step 1 — Modify Volume Size**
1. EC2 Console → `nautilus-ec2` → Storage tab → click the volume ID
2. Actions → **Modify volume**
3. Size: change `8` to `12` → Modify → confirm
4. Wait for state to change from `modifying` → `optimizing`

**Step 2 — SSH into the instance**
```bash
chmod 400 /root/nautilus-keypair.pem
ssh -i /root/nautilus-keypair.pem ubuntu@<PUBLIC_IP>
# or ec2-user@<PUBLIC_IP> for Amazon Linux
```

**Step 3 — Extend partition and filesystem**
```bash
# Check current layout
lsblk
df -hT /

# Extend the partition (replace xvda 1 with actual disk/partition)
sudo growpart /dev/xvda 1

# Extend the filesystem
# For ext4:
sudo resize2fs /dev/xvda1
# For XFS:
sudo xfs_growfs /

# Verify
df -hT /
```

### Method 2 — Full AWS CLI Script

See `commands.sh` for the complete automated script covering all steps.

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- FIND VOLUME ---
INSTANCE_ID=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=nautilus-ec2" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

VOLUME_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId" \
    --output text)

echo "Volume: $VOLUME_ID ($(aws ec2 describe-volumes --volume-ids $VOLUME_ID \
    --region $REGION --query "Volumes[0].Size" --output text) GiB)"

# --- EXPAND VOLUME ---
aws ec2 modify-volume --volume-id $VOLUME_ID --size 12 --region $REGION

# --- POLL MODIFICATION STATE ---
aws ec2 describe-volumes-modifications --volume-ids $VOLUME_ID --region $REGION \
    --query "VolumesModifications[0].{State:ModificationState,Old:OriginalSize,New:TargetSize}" \
    --output table

# --- INSIDE THE INSTANCE ---
# Check layout
lsblk
df -hT /

# Detect root device
findmnt -n -o SOURCE /

# Extend partition
sudo growpart /dev/xvda 1          # t2/m4 type
sudo growpart /dev/nvme0n1 1       # t3/m5/Nitro type

# Extend filesystem
sudo resize2fs /dev/xvda1          # ext4
sudo xfs_growfs /                  # XFS

# Verify
df -hT /
```

---

## ⚠️ Common Mistakes

**1. Only modifying the volume at the AWS level and not extending inside the OS**
`aws ec2 modify-volume` grows the block device. `df -h` will still show 8 GiB until `growpart` and `resize2fs`/`xfs_growfs` are run inside the instance. The volume IS larger — the OS just doesn't know it yet. Always do both phases.

**2. Running `resize2fs` before `growpart`**
`resize2fs` expands the filesystem to fill the partition. If the partition hasn't been grown yet (growpart not run), resize2fs sees the partition boundaries and does nothing (or errors). Always: `growpart` first, then `resize2fs` or `xfs_growfs`.

**3. Using the wrong device name for growpart**
Hardcoding `/dev/xvda` on a Nitro-based instance (which uses `/dev/nvme0n1`) fails. Use `findmnt -n -o SOURCE /` to detect the actual root device, then derive the disk and partition number from it.

**4. Using `xfs_growfs` with the device path instead of the mount point**
For XFS: `sudo xfs_growfs /` (mount point). Not `sudo xfs_growfs /dev/xvda1`. XFS growfs takes a mount point or a path within the filesystem, not the block device path.

**5. Not waiting for the modification state to leave 'modifying'**
The OS can begin the partition/filesystem extension once the volume modification reaches `optimizing` — it doesn't need to reach `completed` (which can take hours for large volumes as data is migrated). Polling with `describe-volumes-modifications` and checking for `optimizing` or `completed` is the correct gate.

---

## 🌍 Real-World Context

**Zero-downtime storage expansion** is one of EBS's most operationally useful features. Unlike traditional on-premises storage where expanding a disk typically required scheduled downtime, rebooting to resize, and often LVM configuration, EBS allows:
- Modifying the volume while the instance is running and actively serving traffic
- Extending the partition and filesystem online (no unmount required)
- No service restart or application disruption

**The three-layer model to remember:**
```
EBS block device (AWS layer) — modified by modify-volume
    ↓
Partition (OS layer)         — extended by growpart
    ↓
Filesystem (OS layer)        — extended by resize2fs / xfs_growfs
```

Each layer must be explicitly grown. Missing any layer means the space exists physically but isn't accessible to applications.

**Production automation:** Teams often use CloudWatch Alarms on `VolumeWriteOps` or a custom metric for disk utilisation, triggering a Lambda that calls `modify-volume` automatically when disk usage crosses a threshold. The in-instance extension still requires running `growpart` and `resize2fs` — typically done via SSM Run Command from the Lambda, making the entire expansion fully automated without any SSH access.

---

## ❓ Interview Q&A

**Q1. What are the two phases of EBS volume expansion and why are both required?**
> Phase 1 is the AWS control plane operation — `modify-volume` increases the EBS block device size. This is reflected immediately in `lsblk` (the disk appears larger) but not in `df -h` (the filesystem still reports the old size). Phase 2 is the OS-level operation — `growpart` extends the partition table entry to use the newly available blocks, then `resize2fs` (ext4) or `xfs_growfs` (XFS) extends the filesystem to fill the partition. Both are required because the kernel maintains separate representations of disk size, partition boundaries, and filesystem size. Each must be explicitly updated.

**Q2. Can you shrink an EBS volume the same way you expand it?**
> No. EBS volumes can only be increased in size, never decreased, via `modify-volume`. Shrinking requires creating a new smaller volume, copying data to it (via snapshot restore with a smaller size, which also isn't directly supported — you'd copy the data at the filesystem level), and swapping the volumes. This is operationally complex and disruptive. The practical approach for right-sizing oversized volumes is to migrate to a new instance with the correct storage allocation. This asymmetry is why starting with a smaller volume and expanding as needed is better than over-provisioning upfront.

**Q3. What is the `growpart` tool and what does it actually modify?**
> `growpart` is part of the `cloud-guest-utils` package (standard on AWS AMIs). It modifies the partition table — either GPT or MBR — to extend a specified partition to fill all available space on the disk. It doesn't touch the filesystem. On Linux kernels 3.6+, it also signals the kernel to re-read the partition table without requiring a reboot. The result: `lsblk` shows the partition now fills the disk, but `df -h` still shows the old filesystem size until the filesystem extension step runs.

**Q4. How would you automate the full EBS expansion (both phases) without requiring SSH access?**
> Use AWS Systems Manager Run Command. After `modify-volume` completes (poll `describe-volumes-modifications` until state is `optimizing`), run an SSM document on the instance: `aws ssm send-command --instance-ids $INSTANCE_ID --document-name AWS-RunShellScript --parameters 'commands=["sudo growpart /dev/xvda 1","sudo resize2fs /dev/xvda1"]'`. This requires the SSM agent to be running on the instance and an IAM instance profile with `ssm:SendCommand` permissions — no SSH port open, no key management. Combined with a Lambda triggered by a CloudWatch alarm on disk utilisation, this creates a fully automated zero-touch disk expansion pipeline.

**Q5. What is the difference between `resize2fs` and `xfs_growfs`, and how do you determine which to use?**
> `resize2fs` is for ext2/ext3/ext4 filesystems; `xfs_growfs` is for XFS. To determine which applies: `findmnt -n -o FSTYPE /` returns the filesystem type of the root mount. Ubuntu AMIs typically use ext4; Amazon Linux 2 and AL2023 use XFS. The syntax also differs: `resize2fs` takes the block device path (`/dev/xvda1`), while `xfs_growfs` takes the mount point (`/`) or any path within the mounted filesystem — using the device path with `xfs_growfs` causes an error.

---

## 📍 Proof of Work

This learning is documented and shared on LinkedIn:
- [View on LinkedIn](https://www.linkedin.com/posts/venkatesh-gangavarapu_100daysofcloud-aws-ebs-share-7487082403384176640-K2Gy/)



## 📚 Resources

- [AWS Docs — EBS Volume Modification](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-modify-volume.html)
- [Extend a Linux Filesystem After Resizing](https://docs.aws.amazon.com/ebs/latest/userguide/recognize-expanded-volume-linux.html)
- [growpart man page](https://manpages.ubuntu.com/manpages/focal/man1/growpart.1.html)
- [Day 1 — EC2 Storage Basics](../day-01/README.md)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
