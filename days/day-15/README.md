# Day 15 — Creating an EBS Snapshot

> **#100DaysOfCloud | Day 15 of 100**

---

## 📌 The Task

> *Create a snapshot of the existing EBS volume `xfusion-vol` in `us-east-1` as part of setting up automated backups for the team.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Source volume | `xfusion-vol` |
| Snapshot name | `xfusion-vol-ss` |
| Description | `xfusion Snapshot` |
| Required state | `completed` |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### What Is an EBS Snapshot?

An **EBS Snapshot** is a point-in-time backup of an EBS volume stored durably in **Amazon S3** (managed by AWS — you don't see or access this S3 directly). It captures the complete state of the volume at the moment the snapshot begins.

Snapshots are the fundamental backup primitive for EBS. Everything built on top — AMIs, cross-region replication, disaster recovery — relies on snapshots underneath.

### How Snapshots Work — The Incremental Model

The first snapshot of a volume is a **full copy** — every used block on the volume is copied to S3. Every subsequent snapshot of the same volume is **incremental** — only blocks that changed since the last snapshot are stored.

```
Snapshot 1 (full):       [A][B][C][D][E]          → stores all 5 blocks
Snapshot 2 (incremental): changes: [B'][D']        → stores only 2 changed blocks
Snapshot 3 (incremental): changes: [A'][E']        → stores only 2 changed blocks
```

Despite being stored incrementally, **each snapshot is independently restorable** — AWS reconstructs the full volume state from the snapshot chain automatically. Deleting an intermediate snapshot doesn't break the chain; AWS migrates the unique blocks to adjacent snapshots before deletion.

### Snapshot vs AMI — Recap

| | EBS Snapshot | AMI |
|--|-------------|-----|
| **Scope** | Single EBS volume | EC2 instance (references 1+ snapshots) |
| **Used for** | Volume backup, restore, cross-AZ/region migration | Launching new EC2 instances |
| **Standalone?** | Yes | References snapshots — deleting snapshots used by an AMI breaks the AMI |

### Snapshot States

| State | Meaning |
|-------|---------|
| `pending` | Copy in progress — the snapshot is being written to S3 |
| `completed` | Snapshot is fully written and usable for restore |
| `error` | Creation failed — check CloudTrail for the reason |
| `recoverable` | Internal AWS state — not typically seen |

The task requires `completed` state before submission. A snapshot in `pending` state can still be used to create volumes, but it's not fully durably committed until `completed`.

### Snapshot Consistency — Live vs Quiesced Volumes

Taking a snapshot of a **detached** volume guarantees point-in-time consistency — the volume is idle, all data is on disk.

Taking a snapshot of a **mounted and active** volume captures whatever is on disk at that instant. Any data buffered in OS or application memory that hasn't been flushed to disk won't be in the snapshot. For most workloads this is acceptable. For databases:

- **MySQL/MariaDB**: flush and lock tables (`FLUSH TABLES WITH READ LOCK`) before snapshotting, then unlock
- **PostgreSQL**: use `pg_start_backup()` / `pg_stop_backup()` around the snapshot
- **Amazon RDS**: RDS automated snapshots handle this internally — no user action needed

For EC2-hosted databases, quiescing writes before snapshotting produces a crash-consistent image. The snapshot itself doesn't corrupt data — the risk is missing in-flight writes from application buffers.

### Where Snapshots Live and Who Pays

Snapshots are stored in S3, but not in a bucket you own or can browse. AWS manages the storage transparently. You're billed for the **unique blocks** stored across your snapshot chain per GB-month. The incremental model means a daily snapshot of a volume with modest change rates costs significantly less than the full volume size would suggest.

Snapshots are **region-scoped** but can be **copied to other regions** using `copy-snapshot`. Copied snapshots are independent — they have their own snapshot ID and their own incremental chain in the destination region.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Navigate to **EC2 → Elastic Block Store → Volumes**
2. Find `xfusion-vol` → note the **Volume ID**
3. Select `xfusion-vol` → **Actions → Create snapshot**
4. Fill in:
   - **Description:** `xfusion Snapshot`
5. Under **Tags**, add:
   - Key: `Name` | Value: `xfusion-vol-ss`
6. Click **Create snapshot**
7. Navigate to **EC2 → Elastic Block Store → Snapshots**
8. Find `xfusion-vol-ss` → watch the **Status** column
9. Wait for **Status: Completed** ✅

---

### Method 2 — AWS CLI

```bash
# ============================================================
# Step 1: Resolve Volume ID for xfusion-vol
# ============================================================
VOLUME_ID=$(aws ec2 describe-volumes \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=xfusion-vol" \
    --query "Volumes[0].VolumeId" \
    --output text)

echo "Volume: xfusion-vol | ID: $VOLUME_ID"

# Confirm volume details before snapshotting
aws ec2 describe-volumes \
    --volume-ids "$VOLUME_ID" \
    --region us-east-1 \
    --query "Volumes[0].{ID:VolumeId,State:State,Size:Size,Type:VolumeType,AZ:AvailabilityZone,Encrypted:Encrypted}" \
    --output table

# ============================================================
# Step 2: Create the snapshot
# ============================================================
SNAPSHOT_ID=$(aws ec2 create-snapshot \
    --volume-id "$VOLUME_ID" \
    --description "xfusion Snapshot" \
    --region us-east-1 \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=xfusion-vol-ss},{Key=Source,Value=xfusion-vol}]' \
    --query "SnapshotId" \
    --output text)

echo "Snapshot initiated — Snapshot ID: $SNAPSHOT_ID"
echo "Status: pending (data being written to S3)"

# ============================================================
# Step 3: Wait for snapshot to complete
# ============================================================
echo "Waiting for snapshot to reach 'completed' state..."

aws ec2 wait snapshot-completed \
    --snapshot-ids "$SNAPSHOT_ID" \
    --region us-east-1

echo "Snapshot is completed: $SNAPSHOT_ID"

# ============================================================
# Step 4: Verify snapshot details
# ============================================================
aws ec2 describe-snapshots \
    --snapshot-ids "$SNAPSHOT_ID" \
    --region us-east-1 \
    --query "Snapshots[0].{ID:SnapshotId,Name:Tags[?Key=='Name']|[0].Value,Status:State,Description:Description,VolumeId:VolumeId,Size:VolumeSize,Progress:Progress,StartTime:StartTime,Encrypted:Encrypted}" \
    --output table
```

---

### Monitoring Snapshot Progress

```bash
# Check progress (shows percentage for pending snapshots)
aws ec2 describe-snapshots \
    --snapshot-ids "$SNAPSHOT_ID" \
    --region us-east-1 \
    --query "Snapshots[0].{ID:SnapshotId,Status:State,Progress:Progress}" \
    --output table

# Poll until completed (manual polling loop)
while true; do
    STATUS=$(aws ec2 describe-snapshots \
        --snapshot-ids "$SNAPSHOT_ID" \
        --region us-east-1 \
        --query "Snapshots[0].State" \
        --output text)
    PROGRESS=$(aws ec2 describe-snapshots \
        --snapshot-ids "$SNAPSHOT_ID" \
        --region us-east-1 \
        --query "Snapshots[0].Progress" \
        --output text)
    echo "  Status: $STATUS | Progress: $PROGRESS"
    [ "$STATUS" == "completed" ] && break
    sleep 10
done
echo "Snapshot completed"
```

---

### Restoring a Volume from a Snapshot

```bash
# Create a new EBS volume from the snapshot (in the same or different AZ)
aws ec2 create-volume \
    --region us-east-1 \
    --availability-zone us-east-1a \
    --snapshot-id "$SNAPSHOT_ID" \
    --volume-type gp3 \
    --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=xfusion-vol-restored}]'

# Attach and mount the restored volume (see Day 12 for full workflow)
```

---

### Copying a Snapshot to Another Region

```bash
# Copy snapshot from us-east-1 to ap-south-1 (for DR)
aws ec2 copy-snapshot \
    --source-region us-east-1 \
    --source-snapshot-id "$SNAPSHOT_ID" \
    --region ap-south-1 \
    --description "DR copy of xfusion-vol-ss" \
    --destination-region ap-south-1
```

---

### Listing and Auditing Snapshots

```bash
# List all snapshots owned by this account in the region
aws ec2 describe-snapshots \
    --region us-east-1 \
    --owner-ids self \
    --query "Snapshots[*].{ID:SnapshotId,Name:Tags[?Key=='Name']|[0].Value,Status:State,Size:VolumeSize,VolumeId:VolumeId,Created:StartTime}" \
    --output table

# Find snapshots for a specific volume
aws ec2 describe-snapshots \
    --region us-east-1 \
    --owner-ids self \
    --filters "Name=volume-id,Values=${VOLUME_ID}" \
    --query "Snapshots[*].{ID:SnapshotId,Name:Tags[?Key=='Name']|[0].Value,Status:State,Progress:Progress,Created:StartTime}" \
    --output table

# Find snapshots older than 90 days (for cleanup candidates)
aws ec2 describe-snapshots \
    --region us-east-1 \
    --owner-ids self \
    --query "Snapshots[?StartTime<='$(date -d '90 days ago' --utc +%Y-%m-%dT%H:%M:%SZ)'].{ID:SnapshotId,Name:Tags[?Key=='Name']|[0].Value,Created:StartTime,Size:VolumeSize}" \
    --output table
```

---

### Deleting a Snapshot

```bash
# Delete snapshot (only when no longer needed and not referenced by an AMI)
aws ec2 delete-snapshot \
    --snapshot-id "$SNAPSHOT_ID" \
    --region us-east-1

# Note: you cannot delete a snapshot that is referenced by an AMI
# You must deregister the AMI first, then delete the snapshot
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- RESOLVE VOLUME ID ---
VOLUME_ID=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:Name,Values=xfusion-vol" \
    --query "Volumes[0].VolumeId" --output text)

# --- CREATE SNAPSHOT ---
SNAPSHOT_ID=$(aws ec2 create-snapshot \
    --volume-id "$VOLUME_ID" \
    --description "xfusion Snapshot" \
    --region "$REGION" \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=xfusion-vol-ss}]' \
    --query "SnapshotId" --output text)

echo "Snapshot ID: $SNAPSHOT_ID"

# --- WAIT FOR COMPLETED ---
aws ec2 wait snapshot-completed \
    --snapshot-ids "$SNAPSHOT_ID" --region "$REGION"

# --- VERIFY ---
aws ec2 describe-snapshots \
    --snapshot-ids "$SNAPSHOT_ID" --region "$REGION" \
    --query "Snapshots[0].{ID:SnapshotId,Name:Tags[?Key=='Name']|[0].Value,Status:State,Description:Description,Progress:Progress,Size:VolumeSize}" \
    --output table

# --- LIST ALL SNAPSHOTS (owned by account) ---
aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
    --query "Snapshots[*].{ID:SnapshotId,Name:Tags[?Key=='Name']|[0].Value,Status:State,Size:VolumeSize,Created:StartTime}" \
    --output table

# --- RESTORE VOLUME FROM SNAPSHOT ---
aws ec2 create-volume --region "$REGION" \
    --availability-zone us-east-1a \
    --snapshot-id "$SNAPSHOT_ID" \
    --volume-type gp3 \
    --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=xfusion-vol-restored}]'

# --- COPY TO ANOTHER REGION ---
aws ec2 copy-snapshot --source-region "$REGION" \
    --source-snapshot-id "$SNAPSHOT_ID" \
    --region ap-south-1 --description "DR copy"

# --- DELETE SNAPSHOT ---
aws ec2 delete-snapshot --snapshot-id "$SNAPSHOT_ID" --region "$REGION"
```

---

## ⚠️ Common Mistakes

**1. Not waiting for `completed` state before reporting done**
A snapshot immediately after creation shows `pending` with a progress percentage. It's usable while pending (you can restore from it) but it's not fully committed and durable until `completed`. The task specifically requires `completed` — always use `aws ec2 wait snapshot-completed` to confirm before marking the task done.

**2. Forgetting that snapshots use `--owner-ids self` for listing**
`aws ec2 describe-snapshots` without any filters returns snapshots from AWS, the AWS Marketplace, and any public snapshots — millions of results. Always filter with `--owner-ids self` to list only your own account's snapshots. Without this, the command may time out or return unexpected results.

**3. Deleting a snapshot that's referenced by an AMI**
If an AMI was created from a volume and that AMI's block device mapping references a snapshot, you cannot delete the snapshot directly — AWS returns `InvalidSnapshot.InUse`. You must deregister the AMI first, then delete the snapshot. Running the deregister + snapshot cleanup script from Day 13 handles this correctly.

**4. Taking snapshots of a heavily-used volume without quiescing**
For critical databases, a raw EBS snapshot taken while the DB has active write transactions may capture a state that's internally inconsistent — write-ahead log (WAL) entries may reference data not yet flushed. Always quiesce database writes, take the snapshot, then resume. For most filesystems (XFS, ext4), the OS journal protects consistency on remount — the main concern is application-level write ordering.

**5. Snapshotting without tagging**
An untagged snapshot in a large account becomes orphaned clutter within weeks. You can't tell what volume it was from, what it was for, or whether it's safe to delete. Always tag with at minimum: `Name`, `Source` (volume name or ID), and `CreatedBy` or a cost allocation tag.

**6. Not accounting for snapshot costs in large fleets**
Snapshots are cheap per GB, but at scale they add up. 1000 instances, each with a 100 GiB volume, daily snapshots with 30-day retention = significant monthly cost. Incremental snapshots help, but only if the previous snapshot still exists. If you delete older snapshots aggressively, the next snapshot has to re-copy all changed blocks from scratch. Let AWS Data Lifecycle Manager manage retention schedules — it's purpose-built for this.

---

## 🌍 Real-World Context

Snapshots are the backbone of EBS backup strategy. In production, nobody takes snapshots manually — they're managed through one of two AWS-native mechanisms:

**AWS Data Lifecycle Manager (DLM):**
DLM lets you create snapshot lifecycle policies that target volumes by tag. You define a schedule (hourly, daily, weekly), a retention count or age, and optionally a cross-region copy rule. DLM then handles creation, retention enforcement, and deletion automatically. A typical policy: daily snapshot at 03:00 UTC, retain 14 snapshots, copy to `eu-west-1` for DR. Zero manual intervention once the policy is in place.

**AWS Backup:**
AWS Backup is the unified backup management service that covers EBS snapshots, RDS, DynamoDB, EFS, FSx, and more under a single policy framework. For organisations with compliance requirements (SOC 2, PCI DSS, HIPAA), AWS Backup provides a centralised backup vault, immutable backup retention, and audit reporting across all backup-protected resources. It's more overhead to set up than DLM but provides a single pane of glass across storage types.

**Snapshot-based DR Pattern:**
For stateful EC2 workloads, the standard DR pattern is: daily DLM snapshot policy → cross-region copy enabled → in DR scenario, restore volume from copied snapshot in secondary region → attach to a pre-launched recovery instance → mount and start the application. RTO of 30–60 minutes for most workloads, depending on volume size and application startup time.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. How does EBS snapshot incremental storage work? If I have 30 daily snapshots, am I paying for 30 full copies of the volume?**

> No — you're paying for the unique blocks across the snapshot chain. The first snapshot is a full copy of all used blocks. Each subsequent snapshot only stores blocks that changed since the previous one. If your 100 GiB volume has 5 GiB of data changing daily, you're paying for roughly 100 GiB (first snapshot) + 5 GiB × 29 = ~245 GiB total, not 3,000 GiB. The important caveat: if you delete a snapshot in the middle of the chain, AWS migrates any unique blocks from the deleted snapshot to the adjacent ones before deletion — so you never lose data by deleting an intermediate snapshot, but the storage accounting shifts. AWS Data Lifecycle Manager handles this correctly when managing retention schedules.

---

**Q2. You need to restore data from an EBS snapshot to a running EC2 instance without replacing the root volume. How do you do it?**

> Create a new EBS volume from the snapshot in the same AZ as the instance: `aws ec2 create-volume --snapshot-id snap-xxx --availability-zone us-east-1a`. Once it's available, attach it to the instance as a secondary volume (`/dev/sdc` or similar). SSH in, create a mount point, and mount it — the filesystem from the snapshot is ready to use. You can then copy specific files from the restored volume to the instance's live filesystem without any downtime. When done, unmount and detach the temporary restore volume, then delete it to stop incurring storage charges. This is the standard selective file recovery pattern for EBS.

---

**Q3. How does AWS Data Lifecycle Manager work and when would you use it over AWS Backup?**

> DLM is volume-centric and simpler: you define a policy targeting volumes by tag, a schedule, retention count, and optionally cross-region copy. It runs automatically and is the right tool for straightforward EBS snapshot automation with per-volume policies. AWS Backup is organisation-centric: it manages backups across multiple services (EBS, RDS, DynamoDB, EFS, S3, EC2 AMIs) under a unified policy framework, backup vault, compliance reporting, and cross-account backup. If you need backup compliance reporting, multi-service coverage, immutable backup vaults (for ransomware protection), or centralised management across AWS organisations, AWS Backup is the right choice. DLM for EBS-only environments; AWS Backup for multi-service or compliance-governed environments.

---

**Q4. A snapshot creation is stuck at 12% progress for 2 hours. What do you investigate?**

> EBS snapshot progress can be non-linear — large volumes or volumes with many changed blocks can spend a long time at single-digit percentages before accelerating. 2 hours at 12% for a modest volume is unusual but not necessarily broken. First, check CloudTrail for any error events on the snapshot. Check `describe-snapshots` — if the state is still `pending` (not `error`), it's likely still running. EBS snapshot throughput is shared infrastructure and can be throttled during peak periods. If the state has transitioned to `error`, check the `StateMessage` field — it will contain the error reason. In most cases, the fix is to delete the failed snapshot and retry, ideally during an off-peak window.

---

**Q5. Can you take a snapshot of an encrypted EBS volume? What happens to the snapshot?**

> Yes — and the snapshot inherits the encryption. A snapshot of an encrypted volume is automatically encrypted with the same KMS key (or a different key if you specify one at copy time). The snapshot remains encrypted at rest in S3. When you restore a volume from an encrypted snapshot, the resulting volume is encrypted. You cannot create an unencrypted snapshot from an encrypted volume — encryption is preserved through the entire snapshot lifecycle. Cross-account sharing of encrypted snapshots requires sharing the KMS key with the target account — without key access, the receiving account can't decrypt the snapshot to create volumes.

---

**Q6. You want to share an EBS snapshot with another AWS account so they can restore it. How do you do that?**

> Modify the snapshot's permissions to add the target account:
> ```bash
> aws ec2 modify-snapshot-attribute \
>     --snapshot-id snap-xxx \
>     --attribute createVolumePermission \
>     --operation-type add \
>     --user-ids 123456789012   # target account ID
> ```
> The target account can then create a volume from the snapshot using `create-volume --snapshot-id`. For encrypted snapshots, you also need to share the KMS key used for encryption with the target account via the KMS key policy. For public sharing (making a snapshot available to all AWS accounts), set `--group-names all` instead of `--user-ids` — but be very careful with this for any snapshot containing application data or configurations.

---

**Q7. What is the difference between using EBS snapshots for backup vs using S3 for backup? When would you choose each?**

> They serve different backup needs. **EBS snapshots** are block-level backups — they capture the raw disk state, not individual files. Restoring from a snapshot recreates the entire volume, which you then attach and mount. They're efficient for full-system recovery (restore an EC2 instance to a point in time) and for migrating volumes between AZs or regions. They don't support granular file-level restore without mounting the full volume. **S3 backup** (using tools like `aws s3 sync`, `s3fs`, or application-level export) is object-level — you copy specific files or data exports to S3. This is better for granular restore (recover a single file), long-term archival (S3 Glacier for 7-year compliance retention), cross-account sharing, and application data that doesn't map neatly to block boundaries (database dumps, config files, logs). In practice, most production systems use both: EBS snapshots for system recovery, and S3 exports for application data recovery at the file or record level.

---

## 📚 Resources

- [AWS Docs — Amazon EBS Snapshots](https://docs.aws.amazon.com/ebs/latest/userguide/EBSSnapshots.html)
- [AWS CLI Reference — create-snapshot](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-snapshot.html)
- [AWS Data Lifecycle Manager](https://docs.aws.amazon.com/ebs/latest/userguide/snapshot-lifecycle.html)
- [AWS Backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/whatisbackup.html)
- [Copying an EBS Snapshot](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-copy-snapshot.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
