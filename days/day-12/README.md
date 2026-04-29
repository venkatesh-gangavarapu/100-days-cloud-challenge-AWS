# Day 12 — Attaching an EBS Volume to an EC2 Instance

> **#100DaysOfCloud | Day 12 of 100**

---

## 📌 The Task

> *An instance named `nautilus-ec2` and a volume named `nautilus-volume` already exist in `us-east-1`. Attach the volume to the instance with device name `/dev/sdb`.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Instance name | `nautilus-ec2` |
| Volume name | `nautilus-volume` |
| Device name | `/dev/sdb` |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### EBS Volumes and the Attach Model

An EBS volume is a block storage device that exists independently of any EC2 instance. It lives in a specific Availability Zone, and until it's attached, it just sits there — `available`, billable, waiting. Attaching it means the EC2 instance's hypervisor maps the volume as a virtual block device, and the OS can then see it as a disk drive.

The attachment is what AWS calls **hot-attach** for running instances — you don't have to stop the instance. EBS supports live attachment for data volumes (not the root volume). The volume appears to the OS without a reboot.

### Device Naming — AWS vs Linux Reality

This is one of the most important details of EBS attachment: **the device name you specify in AWS (`/dev/sdb`) may not be the device name the OS actually uses**.

When you attach a volume at `/dev/sdb`, AWS puts that in the API metadata and shows it in the console. But inside the Linux OS, the kernel uses a different naming scheme — specifically **NVMe-based naming** for Nitro instances (which includes all current-generation instance types: `t3`, `m5`, `c5`, etc.):

| What You Specify (AWS) | What Linux Sees (Nitro-based) |
|------------------------|-------------------------------|
| `/dev/sda1` (root) | `/dev/nvme0n1p1` |
| `/dev/sdb` | `/dev/nvme1n1` |
| `/dev/sdc` | `/dev/nvme2n1` |

For older, non-Nitro instances (like `t2`) the mapping may be more literal — `/dev/sdb` might show as `/dev/sdb` or `/dev/xvdb` inside the OS. The key habit: after attaching, always run `lsblk` inside the instance to find the actual device name before doing anything with it.

> **Shortcut for Nitro instances**: `lsblk -o NAME,SERIAL` — the `SERIAL` column shows the volume ID (`vol-xxxxxx`) which lets you map the AWS volume directly to its OS device name.

### The AZ Constraint — Same as ENIs

Just like ENIs (Day 11), EBS volumes are AZ-scoped. A volume in `us-east-1a` can only be attached to an instance in `us-east-1a`. The API will reject a cross-AZ attachment with `InvalidVolume.ZoneMismatch`. Always verify both are in the same AZ before running the attach command.

### Volume States

| State | Meaning |
|-------|---------|
| `available` | Volume exists, not attached — ready to attach |
| `in-use` | Attached to an instance |
| `creating` | Being provisioned |
| `deleting` | Being deleted |
| `error` | Something went wrong during creation |

An `in-use` volume is already attached. Standard EBS volumes can only be attached to **one instance at a time** (unlike `io1`/`io2` with Multi-Attach enabled).

### What Happens After Attachment — The OS Workflow

Attaching the volume in AWS is the first step, not the last. The full workflow to make a volume usable:

```
1. Attach volume (AWS API)     → volume state: in-use, attachment: attached
2. Verify inside OS (lsblk)    → see the raw block device
3. Format filesystem           → mkfs (first use only — destroys existing data)
4. Create mount point          → mkdir /data
5. Mount the volume            → mount /dev/nvme1n1 /data
6. Persist mount               → add to /etc/fstab with 'nofail'
```

If the volume already has data on it (was previously used), skip step 3 — formatting would wipe everything.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Navigate to **EC2 → Elastic Block Store → Volumes**
2. Find `nautilus-volume` → confirm it is in `Available` state
3. Note the **Availability Zone** — confirm it matches `nautilus-ec2`'s AZ
4. Select `nautilus-volume` → **Actions → Attach volume**
5. **Instance:** Select `nautilus-ec2`
6. **Device name:** Type `/dev/sdb`
7. Click **Attach volume**
8. Verify: volume state changes to `In-use`, attachment state shows `attached`

---

### Method 2 — AWS CLI

```bash
# ============================================================
# Step 1: Resolve Instance ID for nautilus-ec2
# ============================================================
INSTANCE_ID=$(aws ec2 describe-instances \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=nautilus-ec2" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Instance ID: $INSTANCE_ID"

# ============================================================
# Step 2: Resolve Volume ID for nautilus-volume
# ============================================================
VOLUME_ID=$(aws ec2 describe-volumes \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=nautilus-volume" \
    --query "Volumes[0].VolumeId" \
    --output text)

echo "Volume ID: $VOLUME_ID"

# ============================================================
# Step 3: Confirm AZ match (mandatory pre-check)
# ============================================================
INSTANCE_AZ=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region us-east-1 \
    --query "Reservations[0].Instances[0].Placement.AvailabilityZone" \
    --output text)

VOLUME_AZ=$(aws ec2 describe-volumes \
    --volume-ids "$VOLUME_ID" --region us-east-1 \
    --query "Volumes[0].AvailabilityZone" \
    --output text)

echo "Instance AZ: $INSTANCE_AZ"
echo "Volume AZ:   $VOLUME_AZ"

if [ "$INSTANCE_AZ" != "$VOLUME_AZ" ]; then
    echo "ERROR: AZ mismatch — cannot attach volume from $VOLUME_AZ to instance in $INSTANCE_AZ"
    exit 1
fi
echo "AZ check passed — both in $INSTANCE_AZ"

# ============================================================
# Step 4: Confirm volume is in 'available' state
# ============================================================
VOLUME_STATE=$(aws ec2 describe-volumes \
    --volume-ids "$VOLUME_ID" --region us-east-1 \
    --query "Volumes[0].State" --output text)

echo "Volume state: $VOLUME_STATE"

if [ "$VOLUME_STATE" != "available" ]; then
    echo "ERROR: Volume is not in available state (current: $VOLUME_STATE)"
    exit 1
fi

# ============================================================
# Step 5: Attach the volume
# ============================================================
aws ec2 attach-volume \
    --volume-id "$VOLUME_ID" \
    --instance-id "$INSTANCE_ID" \
    --device /dev/sdb \
    --region us-east-1

echo "Attach request sent — waiting for attachment to complete..."

# ============================================================
# Step 6: Wait and verify attachment status
# ============================================================

# Poll until status is 'attached'
while true; do
    ATTACH_STATE=$(aws ec2 describe-volumes \
        --volume-ids "$VOLUME_ID" --region us-east-1 \
        --query "Volumes[0].Attachments[0].State" \
        --output text)
    echo "Attachment state: $ATTACH_STATE"
    [ "$ATTACH_STATE" == "attached" ] && break
    sleep 3
done

echo "Volume is attached"

# Full attachment details
aws ec2 describe-volumes \
    --volume-ids "$VOLUME_ID" \
    --region us-east-1 \
    --query "Volumes[0].{ID:VolumeId,State:State,Type:VolumeType,Size:Size,AZ:AvailabilityZone,AttachState:Attachments[0].State,Device:Attachments[0].Device,InstanceId:Attachments[0].InstanceId}" \
    --output table
```

---

### Inside the EC2 Instance — Making the Volume Usable

```bash
# SSH into the instance
ssh -i ~/.ssh/your-key.pem ec2-user@<PUBLIC_IP>

# Step 1: Find the actual device name assigned by the OS
lsblk
# For Nitro instances: new volume appears as nvme1n1 (or nvme2n1, etc.)
# For older instances: may appear as xvdb

# Map volume ID to device name (Nitro instances)
lsblk -o NAME,SERIAL
# SERIAL column shows the volume ID (vol-xxxxxxxx)

# Step 2: Check if the volume already has a filesystem
sudo file -s /dev/nvme1n1
# "data" = no filesystem (needs formatting)
# "ext4/xfs filesystem" = already has data — skip mkfs

# Step 3: Format the volume (FIRST USE ONLY — destroys all data)
sudo mkfs -t xfs /dev/nvme1n1

# Step 4: Create a mount point
sudo mkdir -p /data

# Step 5: Mount the volume
sudo mount /dev/nvme1n1 /data

# Step 6: Verify
df -h /data

# Step 7: Persist across reboots (use UUID for stability)
sudo blkid /dev/nvme1n1
# Copy the UUID from the output

echo "UUID=<VOLUME_UUID>  /data  xfs  defaults,nofail  0  2" | sudo tee -a /etc/fstab

# Verify fstab is correct (test mount all)
sudo mount -a
```

---

### Detaching the Volume

```bash
# Unmount inside the instance first
sudo umount /data

# Then detach via CLI
aws ec2 detach-volume \
    --volume-id "$VOLUME_ID" \
    --region us-east-1

# Verify volume returns to 'available'
aws ec2 describe-volumes \
    --volume-ids "$VOLUME_ID" --region us-east-1 \
    --query "Volumes[0].State" --output text
# Expected: available
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- RESOLVE IDs ---
INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=nautilus-ec2" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

VOLUME_ID=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:Name,Values=nautilus-volume" \
    --query "Volumes[0].VolumeId" --output text)

# --- PRE-CHECKS ---
# AZ of instance
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].Placement.AvailabilityZone" --output text

# AZ and state of volume
aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --region "$REGION" \
    --query "Volumes[0].{State:State,AZ:AvailabilityZone,Type:VolumeType,Size:Size}" \
    --output table

# --- ATTACH ---
aws ec2 attach-volume \
    --volume-id "$VOLUME_ID" \
    --instance-id "$INSTANCE_ID" \
    --device /dev/sdb \
    --region "$REGION"

# --- VERIFY ---
aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --region "$REGION" \
    --query "Volumes[0].{State:State,AttachState:Attachments[0].State,Device:Attachments[0].Device,Instance:Attachments[0].InstanceId}" \
    --output table

# --- INSIDE OS ---
# lsblk                          # find the device
# lsblk -o NAME,SERIAL           # map volume ID to device name (Nitro)
# sudo file -s /dev/nvme1n1      # check for existing filesystem
# sudo mkfs -t xfs /dev/nvme1n1  # format (first use only)
# sudo mkdir /data && sudo mount /dev/nvme1n1 /data
# echo "UUID=<UUID>  /data  xfs  defaults,nofail  0  2" | sudo tee -a /etc/fstab

# --- DETACH ---
aws ec2 detach-volume --volume-id "$VOLUME_ID" --region "$REGION"
```

---

## ⚠️ Common Mistakes

**1. Not checking the AZ before attaching**
`InvalidVolume.ZoneMismatch` is the error you get when the volume and instance are in different AZs. It's entirely preventable with a two-line check before the attach call. Both the volume and instance must be in the same AZ — there is no workaround. To move a volume to a different AZ you must snapshot it and restore in the target AZ.

**2. Assuming `/dev/sdb` is the device name inside the OS**
On Nitro-based instances (all current-gen: t3, m5, c5, etc.), Linux uses NVMe device naming (`/dev/nvme1n1`). The `/dev/sdb` name you give AWS is stored in API metadata and shown in the console — the kernel never sees it. Always run `lsblk` inside the instance after attaching to find the real device name. For a reliable programmatic mapping, use `lsblk -o NAME,SERIAL` which shows the EBS volume ID in the `SERIAL` column.

**3. Formatting a volume that already has data**
`mkfs` is destructive — it overwrites the filesystem metadata and effectively wipes the volume. If the volume was previously used and has data you need, skip the format step. Run `sudo file -s /dev/nvme1n1` first: if it returns anything other than `data`, there's an existing filesystem — mount it directly without formatting.

**4. Using device name instead of UUID in /etc/fstab**
Device names (`/dev/nvme1n1`, `/dev/xvdb`) can change between reboots depending on the order volumes are detected. If you put the device name directly in `/etc/fstab` and the device name shifts, the instance can fail to boot. Always use the **UUID** in `/etc/fstab` (`sudo blkid` gives you the UUID), and always include the `nofail` option so that a missing volume doesn't prevent the instance from booting.

**5. Forgetting to unmount before detaching**
Detaching a volume that is still mounted is the cloud equivalent of yanking a USB drive while files are being written. Data can be corrupted, the filesystem can be left in an inconsistent state (requiring `fsck` on next mount), and the OS may throw I/O errors. Always `umount` the mount point cleanly before calling `detach-volume`.

**6. Attaching a volume to a stopped instance and not bringing it online**
You can attach a volume to a stopped instance — the attachment will succeed and show `attached`. But the OS won't see it until the instance starts. This is fine for pre-staging volumes before launch, but don't expect `lsblk` to show the volume until the instance is running.

---

## 🌍 Real-World Context

EBS volume attachment — and the full lifecycle from attach to formatted, mounted, and persisted — is one of the most routine operations in EC2-based infrastructure. In practice it comes up in several scenarios:

**Data migration between instances:** Detach a data volume from an old instance, attach to a new one (same AZ) — the data moves without any file copying, at any volume size, in seconds at the AWS API level.

**Disaster recovery restores:** An instance fails. You restore an EBS snapshot to a new volume in the same AZ, attach it to a recovery instance, and mount it to access the data. The entire operation can be scripted and completed in minutes.

**Scaling storage without replacing instances:** An EC2 instance running low on disk space can have an additional EBS volume attached and mounted at a new path — no instance resize required, no downtime.

**Database data separation:** Database instances often have the root OS volume (`/dev/sda1`) and a separate data volume (`/dev/sdb` mapped to `/data`). This separation means you can replace or resize the OS without touching the database files, and snapshot the data volume independently of the root.

In Terraform, the equivalent resources are `aws_volume_attachment` (to attach an existing `aws_ebs_volume` to an `aws_instance`). In production IaC, volumes, attachments, and the filesystem configuration (via user data or Ansible) are all managed as a unit rather than run as separate manual operations.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. You attach an EBS volume to an EC2 instance and run `lsblk` but don't see `/dev/sdb`. Where is it and how do you find it?**

> On Nitro-based instances (all current-generation types: t3, m5, c5, etc.), Linux uses NVMe device naming — the OS never registers `/dev/sdb`. The volume shows up as `/dev/nvme1n1` (for the first secondary volume), `/dev/nvme2n1` for the second, and so on. The AWS-assigned device name (`/dev/sdb`) lives only in the API metadata. To reliably identify which OS device corresponds to which EBS volume, run `lsblk -o NAME,SERIAL` — the `SERIAL` column shows the EBS volume ID (e.g., `vol-0abc1234`), which you can cross-reference with `describe-volumes`. On older non-Nitro instances (t2, m4), the mapping is closer to literal — `/dev/sdb` might appear as `/dev/xvdb`.

---

**Q2. You need to move a 2 TB data volume from an instance in `us-east-1a` to a new instance in `us-east-1b`. Walk me through the process.**

> You can't directly reattach across AZs — EBS volumes are AZ-scoped. The process: first, cleanly unmount the volume on the source instance and detach it. Create an EBS snapshot of the volume — this copies the data to S3 (region-scoped). Once the snapshot is complete, create a new EBS volume from the snapshot in `us-east-1b`, specifying the target AZ. Attach the new volume to the instance in `us-east-1b` and mount it. The data is identical to the original volume's state at snapshot time. The original volume in `us-east-1a` still exists until you delete it. For a 2 TB volume, snapshot creation time depends on how much data has changed since the last snapshot — AWS snapshots are incremental after the first, so if you have an existing snapshot chain, only the delta is copied.

---

**Q3. A developer accidentally ran `mkfs` on a mounted EBS volume that had production data on it. What are the recovery options?**

> `mkfs` overwrites the filesystem superblock and metadata but doesn't immediately zero out all data blocks. This means some recovery may be possible with forensic tools. First, immediately detach the volume and create a snapshot before any further writes overwrite more data. Then restore the volume in a recovery environment and use filesystem recovery tools (`xfs_repair`, `e2fsck`, `testdisk`, or `photorec`) to attempt to recover file metadata and data blocks. The success rate depends on how much new data was written after the `mkfs`. The real answer is: if you have a recent EBS snapshot (from a Data Lifecycle Manager policy), restore from that — it'll be faster and more complete than forensic recovery. This is exactly why DLM snapshots before any storage changes is non-negotiable on production volumes.

---

**Q4. What is the `nofail` option in `/etc/fstab` and why is it critical for EBS volumes?**

> `nofail` tells the OS boot process to continue even if the filesystem listed in `/etc/fstab` fails to mount. Without it, if an EBS volume is listed in `/etc/fstab` but isn't attached at boot time (or isn't formatted yet), the instance will drop into emergency mode — effectively bricking it until manual intervention. This scenario comes up when you snapshot an instance to make an AMI and launch a new instance from it: the new instance doesn't have the secondary EBS volumes the original had, so the fstab entries for those volumes fail at boot. With `nofail`, the instance boots cleanly and logs the mount failure, rather than hanging indefinitely. Always use `nofail` for any non-root volume. The full recommended line in fstab: `UUID=<UUID>  /data  xfs  defaults,nofail  0  2`.

---

**Q5. An EC2 instance's root volume is filling up and the application is about to run out of disk space. How do you address this without downtime?**

> Two options. First, **online resize of the existing root volume**: run `aws ec2 modify-volume --size <new-size> --volume-id <root-vol-id>`. EBS supports live resize — no detach needed, no reboot required. After the API call completes, you still need to grow the filesystem inside the OS: `sudo growpart /dev/nvme0n1 1` to extend the partition, then `sudo xfs_growfs /` (or `resize2fs` for ext4). This is the cleanest option. Second, **attach an additional EBS volume** for overflow data: attach a new volume, format it, and mount it at `/data` (or wherever the application writes). Then either configure the application to write to `/data` or symlink the overflowing directory to `/data`. The second approach avoids touching the root volume at all.

---

**Q6. What is the Delete on Termination flag on an EBS volume attachment, and what are the implications of getting it wrong?**

> When an EBS volume is attached to an EC2 instance, the attachment has a `DeleteOnTermination` attribute. For the **root volume**, this defaults to `true` — when the instance is terminated, the root EBS volume is deleted automatically. For **additional data volumes** attached afterward, this defaults to `false` — they survive termination as unattached volumes. Getting it wrong in either direction causes problems: if you set `DeleteOnTermination=true` on a data volume and the instance is terminated (even accidentally), the data is gone permanently. If the root volume has `DeleteOnTermination=false` and you terminate hundreds of instances, you accumulate orphaned root volumes that cost money and require manual cleanup. You can check and modify the flag with `modify-instance-attribute --block-device-mappings` while the instance is running.

---

**Q7. How does EBS Multi-Attach work, and what are the strict requirements for using it?**

> EBS Multi-Attach allows a single `io1` or `io2` volume to be simultaneously attached to up to 16 EC2 instances in the same AZ. It's designed for applications that manage concurrent I/O at the application layer — like clustered databases or high-availability systems that coordinate their own write locking. The requirements are strict: only `io1`/`io2` volume types (not `gp3`, `gp2`, or HDD types), all instances must be in the same AZ, and the application or filesystem must be explicitly cluster-aware — standard Linux filesystems like XFS and ext4 will be corrupted if two instances write to the same blocks simultaneously without coordination. Suitable filesystems include GFS2 or OCFS2. Multi-Attach is a niche feature for specific clustered workloads — it's not a general-purpose way to share a volume between instances. For most data sharing use cases, Amazon EFS (NFS-based shared filesystem) is the correct tool.

---

## 📚 Resources

- [AWS Docs — Attach an EBS Volume](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-attaching-volume.html)
- [AWS CLI Reference — attach-volume](https://docs.aws.amazon.com/cli/latest/reference/ec2/attach-volume.html)
- [Device Naming on Linux — AWS Docs](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-using-volumes.html)
- [Make EBS Volume Available — Format and Mount](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-using-volumes.html)
- [EBS Multi-Attach](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volumes-multi.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
