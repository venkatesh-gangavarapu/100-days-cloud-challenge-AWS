# Day 05 — Creating an AWS EBS Volume

> **#100DaysOfCloud | Day 5 of 100**

---

## 📌 The Task

> *The Nautilus DevOps team is strategizing the migration of a portion of their infrastructure to the AWS cloud. As part of this incremental migration approach, they need to provision storage volumes as smaller, manageable units before attaching them to instances.*

**Requirements:**
- Volume name: `devops-volume`
- Volume type: `gp3`
- Volume size: `2 GiB`
- Region: `us-east-1`

---

## 🧠 Core Concepts

### What Is Amazon EBS?

**Amazon Elastic Block Store (EBS)** is AWS's block storage service for EC2. Think of it as a virtual hard drive that you attach to an EC2 instance — the instance OS sees it as a local disk, reads and writes to it like any other block device, and it persists independently of the instance lifecycle.

The key distinction from instance store (ephemeral) storage: **EBS volumes persist** after an instance is stopped or terminated. You can detach a volume from one instance and reattach it to another, create snapshots of it, and restore it. It's durable, replicated within its Availability Zone automatically.

### EBS Volume Types — Choosing the Right One

| Type | Class | Use Case | Key Spec |
|------|-------|----------|----------|
| `gp3` | General Purpose SSD | Most workloads — OS disks, dev/test, small DBs | 3,000 IOPS baseline, independently configurable throughput |
| `gp2` | General Purpose SSD | Legacy general purpose (being superseded by gp3) | IOPS tied to size (3 IOPS/GiB) |
| `io1` / `io2` | Provisioned IOPS SSD | High-performance DBs, latency-sensitive apps | Up to 64,000 IOPS |
| `st1` | Throughput Optimized HDD | Big data, log processing, data warehouses | High throughput, low IOPS |
| `sc1` | Cold HDD | Infrequently accessed data, lowest cost | Lowest throughput, cheapest |
| `standard` | Magnetic | Legacy only — avoid for new workloads | — |

### Why `gp3` Over `gp2`?

`gp3` is the current generation of general purpose SSD and is the **recommended default for most workloads**. The key advantages over `gp2`:

- **IOPS and throughput are independently configurable** — with `gp2`, IOPS scale with size (you had to over-provision storage just to get more IOPS). With `gp3`, you can set up to 16,000 IOPS regardless of volume size.
- **Baseline of 3,000 IOPS at no extra charge** — `gp2` only gives 100 IOPS at minimum.
- **20% cheaper per GB** than `gp2` — AWS explicitly recommends migrating `gp2` volumes to `gp3`.
- **Throughput** is configurable up to 1,000 MB/s vs `gp2`'s cap of 250 MB/s.

### EBS Volumes Are AZ-Specific

An EBS volume lives in a specific **Availability Zone** and can only be attached to EC2 instances in that same AZ. If you need to move a volume to a different AZ, you take a **snapshot** (which copies to S3 and becomes region-wide) and restore it in the target AZ. This is an important constraint when designing HA architectures.

### Key EBS Concepts

| Concept | Description |
|---------|-------------|
| **Snapshot** | Point-in-time backup stored in S3. Incremental after the first. Used for backups, AMI creation, AZ/region migration. |
| **IOPS** | Input/Output Operations Per Second — how many read/write operations per second the volume can handle |
| **Throughput** | MB/s — the bandwidth of data transferred per second |
| **Multi-Attach** | `io1`/`io2` only — allows attaching a single volume to multiple instances simultaneously (for clustered workloads) |
| **Encryption** | AES-256 at rest and in transit. Can be enabled at creation; can't be added to an unencrypted volume in-place (requires snapshot + restore). |

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Log in to the [AWS Console](https://062665041731.signin.aws.amazon.com/console?region=us-east-1)
2. Navigate to **EC2 → Elastic Block Store → Volumes**
3. Click **Create volume**
4. Fill in the details:
   - **Volume type:** `gp3`
   - **Size:** `2` GiB
   - **IOPS:** `3000` (default baseline for gp3 — leave as-is)
   - **Throughput:** `125` MB/s (default — leave as-is)
   - **Availability Zone:** `us-east-1a` (pick any AZ in us-east-1)
   - **Snapshot ID:** Leave empty (creating a fresh volume)
   - **Encryption:** Optional for this task
5. Under **Tags**, add:
   - Key: `Name` | Value: `devops-volume`
6. Click **Create volume**
7. Confirm: the volume appears in the list with state **Available** and the name `devops-volume`

---

### Method 2 — AWS CLI

```bash
# Step 1: Check available Availability Zones in us-east-1
aws ec2 describe-availability-zones \
    --region us-east-1 \
    --query "AvailabilityZones[*].ZoneName" \
    --output table

# Step 2: Create the EBS volume
aws ec2 create-volume \
    --region us-east-1 \
    --availability-zone us-east-1a \
    --volume-type gp3 \
    --size 2 \
    --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=devops-volume}]'

# Note the VolumeId from the output — e.g., vol-0abc1234def567890

# Step 3: Verify the volume was created correctly
aws ec2 describe-volumes \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=devops-volume" \
    --query "Volumes[*].{ID:VolumeId,Type:VolumeType,Size:Size,State:State,AZ:AvailabilityZone}" \
    --output table
```

**Expected output:**
```
---------------------------------------------------------------------------
|                           DescribeVolumes                               |
+------+------------+------+----------------------+-----------+-----------+
|  AZ  |     ID     | Size |        State         |   Type    |           |
+------+------------+------+----------------------+-----------+-----------+
|  us-east-1a  | vol-0abc...  |  2   |  available  |  gp3  |
+------+------------+------+----------------------+-----------+-----------+
```

---

### Attaching the Volume to an EC2 Instance

```bash
# Attach the volume to a running instance (must be in the same AZ)
aws ec2 attach-volume \
    --region us-east-1 \
    --volume-id <VOLUME_ID> \
    --instance-id <INSTANCE_ID> \
    --device /dev/xvdf

# Check attachment state
aws ec2 describe-volumes \
    --volume-ids <VOLUME_ID> \
    --query "Volumes[*].Attachments"
```

### After Attaching — Format and Mount (on the EC2 instance)

```bash
# SSH into your EC2 instance, then:

# Check the new device is visible
lsblk

# Format the volume (first use only — this destroys any existing data)
sudo mkfs -t xfs /dev/xvdf

# Create a mount point
sudo mkdir /data

# Mount the volume
sudo mount /dev/xvdf /data

# Verify the mount
df -h /data

# Make the mount persistent across reboots (add to /etc/fstab)
echo "/dev/xvdf  /data  xfs  defaults,nofail  0  2" | sudo tee -a /etc/fstab
```

---

### Detaching a Volume

```bash
# Unmount inside the instance first
sudo umount /data

# Then detach via CLI (instance must not be using it)
aws ec2 detach-volume \
    --region us-east-1 \
    --volume-id <VOLUME_ID>

# Check state returns to 'available'
aws ec2 describe-volumes --volume-ids <VOLUME_ID> \
    --query "Volumes[*].State" --output text
```

---

## 💻 Commands Reference

```bash
# --- CREATE ---
aws ec2 create-volume \
    --region us-east-1 \
    --availability-zone us-east-1a \
    --volume-type gp3 \
    --size 2 \
    --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=devops-volume}]'

# --- VERIFY ---
aws ec2 describe-volumes \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=devops-volume" \
    --query "Volumes[*].{ID:VolumeId,Type:VolumeType,Size:Size,State:State,AZ:AvailabilityZone}" \
    --output table

# --- DESCRIBE BY ID ---
aws ec2 describe-volumes --volume-ids <VOLUME_ID>

# --- ATTACH TO INSTANCE ---
aws ec2 attach-volume \
    --region us-east-1 \
    --volume-id <VOLUME_ID> \
    --instance-id <INSTANCE_ID> \
    --device /dev/xvdf

# --- DETACH ---
aws ec2 detach-volume --volume-id <VOLUME_ID>

# --- MODIFY (e.g., increase size or IOPS after creation) ---
aws ec2 modify-volume \
    --volume-id <VOLUME_ID> \
    --size 10 \
    --iops 4000

# --- SNAPSHOT (backup before changes) ---
aws ec2 create-snapshot \
    --volume-id <VOLUME_ID> \
    --description "devops-volume backup" \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=devops-volume-snap}]'

# --- DELETE ---
aws ec2 delete-volume --volume-id <VOLUME_ID>
```

---

## ⚠️ Common Mistakes

**1. Creating a volume in the wrong Availability Zone**
EBS volumes can only attach to instances in the same AZ. If your instance is in `us-east-1b` and your volume is in `us-east-1a`, the attach will fail with a dependency error. Always confirm the AZ of your target instance before creating the volume.

**2. Forgetting to format before mounting**
A freshly created EBS volume has no filesystem. If you attach it and try to mount it directly, it will fail. You must run `mkfs` on the device first (only on first use — running `mkfs` again destroys all data on the volume).

**3. Not updating `/etc/fstab` for persistent mounts**
Mounting a volume manually with `mount` survives only until the instance reboots. To make it permanent, add an entry to `/etc/fstab`. Always use the `nofail` option so a missing volume doesn't prevent the instance from booting.

**4. Deleting a volume that still has snapshots**
Deleting a volume does not delete its snapshots. Snapshots live independently in S3 and must be deleted separately if you want to stop incurring charges for them.

**5. Choosing `gp2` instead of `gp3` for new volumes**
`gp2` is the previous generation. For any new workload, `gp3` is cheaper, more performant at small sizes, and gives you independent IOPS/throughput configuration. There's almost no reason to create a new `gp2` volume in 2025.

**6. Not taking a snapshot before resizing or modifying a volume**
EBS volumes support online resizing (you can increase size without detaching), but you can't decrease size. And while online resize is generally safe, always snapshot before making storage changes. If something goes wrong, a snapshot lets you restore to the pre-change state.

---

## 🌍 Real-World Context

In production AWS environments, EBS volume management is rarely done by hand through the console or one-off CLI commands. It's typically handled in one of three ways:

1. **Terraform / CloudFormation** — volumes are declared as `aws_ebs_volume` resources alongside the EC2 instances that use them. Attachment, tagging, and AZ alignment are all managed as code.

2. **Launch Templates / AMIs** — the root EBS volume configuration is baked into the Launch Template used by Auto Scaling Groups, so every instance that launches gets the right volume type and size automatically.

3. **AWS Data Lifecycle Manager (DLM)** — manages automated EBS snapshot schedules and retention policies so backup compliance is handled without manual intervention.

The `gp3` migration story is also worth knowing for interviews: AWS released `gp3` in late 2020 and has been encouraging organizations to migrate `gp2` volumes since. Many large AWS environments still have hundreds of legacy `gp2` volumes that have never been converted. The conversion process is a live `modify-volume` call — no downtime required — and in most cases it's both a cost reduction and a performance improvement.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What's the difference between EBS and instance store? When would you choose one over the other?**

> EBS is **persistent** block storage — it exists independently of the EC2 instance. Stop the instance, the volume is fine. Terminate the instance, the volume survives (unless you checked the delete-on-termination option). Instance store is **ephemeral** — it's physically attached to the host machine, delivers very high IOPS with low latency, but the data is gone the moment the instance is stopped or terminated. You'd choose instance store for workloads that need maximum I/O performance and don't need persistence: cache layers, temporary processing, or anything where the application itself handles durability (like Cassandra nodes that replicate data across multiple instances). For anything where the data itself needs to survive beyond a single instance, EBS is the answer.

---

**Q2. You need to move an EBS volume from `us-east-1a` to `us-east-1b`. Walk me through the process.**

> You can't directly migrate a volume between AZs — they're AZ-scoped. The process is: create a snapshot of the volume (snapshots are region-scoped and stored in S3), then create a new volume from that snapshot in the target AZ (`us-east-1b`), then attach the new volume to your instance in `us-east-1b`. The snapshot captures the data at a point in time, so if the volume is in use when you snapshot it, it's best practice to either freeze the filesystem or take the snapshot during low-activity to ensure consistency. This same approach works for cross-region migrations — you'd copy the snapshot to the target region first.

---

**Q3. What are the key differences between `gp2` and `gp3`, and why does AWS recommend migrating to `gp3`?**

> The fundamental difference is how IOPS are allocated. With `gp2`, IOPS are coupled to volume size at a ratio of 3 IOPS per GiB — so a 100 GiB volume gives you 300 IOPS. If you need more IOPS, you have to increase the size, which means paying for storage you don't actually need. With `gp3`, IOPS and throughput are completely independent of size. You get a baseline of 3,000 IOPS on any size volume — even 1 GiB — and you can configure up to 16,000 IOPS separately. `gp3` is also about 20% cheaper per GiB than `gp2`. The migration is a live `modify-volume` call with no downtime, and in almost every case it either reduces cost, improves performance, or both.

---

**Q4. An EC2 instance was terminated and the team is panicking because they think all the data is gone. How do you approach this?**

> First, check whether the root volume had **Delete on Termination** enabled — this is the default for root volumes but not for additional volumes. If it was a root volume with delete-on-termination enabled and no snapshots exist, the data is gone. But if the volume was an additional data volume, by default it would have been detached and kept available — check EC2 → Volumes for any unattached volumes. Also check EC2 → Snapshots — if someone set up AWS Data Lifecycle Manager or manual snapshot schedules, there may be a recent snapshot to restore from. Going forward, the right answer is: never run production data on a root volume without either disabling delete-on-termination or snapshotting regularly, and use DLM to automate backup schedules.

---

**Q5. You have a `gp3` volume running at 3,000 IOPS and the application is reporting I/O wait. How do you diagnose and address this?**

> First verify the application is actually hitting the volume limit and not something else — check CloudWatch metrics for the volume: `VolumeReadOps`, `VolumeWriteOps`, and `VolumeQueueLength`. If queue depth is consistently above 1, the volume is saturated. Then check `VolumeReadBytes` and `VolumeWriteBytes` against the throughput limit. If IOPS are the bottleneck, use `modify-volume` to increase IOPS (up to 16,000 on `gp3`) — this is a live operation, no downtime. If throughput is the bottleneck, increase throughput (up to 1,000 MB/s on `gp3`). If neither resolves it, the workload may need `io2` with higher baseline guarantees or the instance type may have its own EBS bandwidth ceiling — EC2 instance types have a maximum EBS throughput cap that's separate from the volume limit.

---

**Q6. What is EBS Multi-Attach and what are its limitations?**

> Multi-Attach allows a single EBS volume to be simultaneously attached to up to 16 EC2 instances — but only for `io1` and `io2` volume types, and only within the same AZ. It's designed for clustered applications that manage concurrent write access at the application layer (like Oracle RAC or certain distributed filesystems). The big caveat is that standard Linux filesystems like ext4 and XFS are not cluster-aware — if two instances write to the same blocks simultaneously through a regular filesystem, you'll get corruption. Multi-Attach requires either a cluster-aware filesystem (like GFS2) or an application that explicitly coordinates I/O. It's a niche feature for specific workloads, not a general-purpose solution.

---

**Q7. How would you automate EBS snapshot backups at scale across hundreds of volumes?**

> The AWS-native answer is **Data Lifecycle Manager (DLM)**. You create a lifecycle policy that targets volumes by tag (e.g., all volumes with `Backup=daily`), define a schedule (e.g., every 24 hours at 02:00 UTC), and set a retention count or age. DLM handles creation, naming, and deletion automatically. For cross-region backup, you add a cross-region copy rule to the policy. For more complex requirements — cross-account copies, custom retention logic, integration with a backup compliance system — AWS Backup is the managed alternative that provides a unified backup view across EBS, RDS, EFS, DynamoDB, and more from a single policy framework.

---

## 📚 Resources

- [AWS Docs — Amazon EBS Volume Types](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html)
- [AWS CLI Reference — create-volume](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-volume.html)
- [gp2 to gp3 Migration Guide](https://docs.aws.amazon.com/ebs/latest/userguide/requesting-ebs-volume-modifications.html)
- [AWS Data Lifecycle Manager](https://docs.aws.amazon.com/ebs/latest/userguide/snapshot-lifecycle.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
