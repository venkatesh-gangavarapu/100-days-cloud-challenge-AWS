# Day 32 — RDS Snapshot and Restore

> **#100DaysOfCloud | Day 32 of 100**

---

## 📌 The Task

> *Take a snapshot of an existing RDS instance, then restore it to a new instance — validating the backup and restore process before a production database update.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Source RDS instance | `nautilus-rds` (must be Available first) |
| Snapshot name | `nautilus-snapshot` |
| Restored instance name | `nautilus-snapshot-restore` |
| Restored instance class | `db.t3.micro` |
| Final state | `nautilus-snapshot-restore` must be Available |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### RDS Backup Types

RDS has two distinct backup mechanisms that serve different purposes:

| | Automated Backups | Manual Snapshots |
|--|------------------|-----------------|
| **Triggered by** | RDS automatically, daily | You, on demand |
| **Retention** | 0–35 days (deleted with instance) | Indefinite (until you delete) |
| **Granularity** | Point-in-time (any second in window) | Specific moment in time |
| **Survives deletion?** | No (unless final snapshot taken) | Yes |
| **Cost** | Free up to DB size | Standard S3 storage rates |
| **Use case** | Continuous protection, PITR | Before upgrades, DR, cloning |

For this task we use a **manual snapshot** — an on-demand, persistent backup of the entire DB instance state at the moment it's taken.

### What a Snapshot Contains

An RDS snapshot is a complete copy of the DB instance's storage volume at a point in time:
- All databases and tables
- All data and schema
- DB parameter group association
- Storage configuration (size, type, IOPS)

A snapshot does **not** contain:
- The instance configuration (class, VPC, SG — these are set fresh at restore time)
- Read replicas
- Data written after the snapshot was taken

### Snapshot → Restore Creates a New Instance

Restoring a snapshot doesn't overwrite the original. It creates a **brand new RDS instance** with:
- The data from the snapshot
- A new endpoint DNS name
- Whatever instance class, VPC, and SG you specify at restore time
- The same engine version as the snapshot

This is why it's ideal for testing a major update: restore the snapshot to `nautilus-snapshot-restore`, run the update against it, validate everything works, then apply to production `nautilus-rds`.

### Snapshot States

| State | Meaning |
|-------|---------|
| `creating` | Snapshot is being taken — don't restore yet |
| `available` | Ready to restore from |
| `copying` | Being copied to another region |
| `deleting` | Being deleted |

**Always wait for `available` before restoring.** Restoring from a `creating` snapshot fails.

### The Timeline for This Task

```
nautilus-rds (available)
    │
    ▼ take snapshot
nautilus-snapshot (creating → available) ~3-5 min
    │
    ▼ restore snapshot
nautilus-snapshot-restore (creating → available) ~10-15 min
    │
    ▼ verify available ✅
```

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Step 1 — Verify source instance is Available**
- RDS → Databases → confirm `nautilus-rds` status = **Available**

**Step 2 — Take snapshot**
- Select `nautilus-rds` → Actions → **Take snapshot**
- Snapshot name: `nautilus-snapshot` → Take snapshot
- Wait: RDS → Snapshots → `nautilus-snapshot` status = **Available**

**Step 3 — Restore snapshot**
- RDS → Snapshots → select `nautilus-snapshot`
- Actions → **Restore snapshot**
- DB instance identifier: `nautilus-snapshot-restore`
- DB instance class: `db.t3.micro`
- Public access: No
- All other settings: default
- Restore DB instance

**Step 4 — Verify**
- RDS → Databases → `nautilus-snapshot-restore` status = **Available** ✅

---

### Method 2 — AWS CLI

```bash
#!/bin/bash
set -e
REGION="us-east-1"
SOURCE_DB="nautilus-rds"
SNAPSHOT_ID="nautilus-snapshot"
RESTORE_DB="nautilus-snapshot-restore"

# ============================================================
# STEP 1: Confirm source instance is Available
# ============================================================

echo "=== Step 1: Checking source RDS instance status ==="

STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$SOURCE_DB" \
    --region $REGION \
    --query "DBInstances[0].DBInstanceStatus" \
    --output text)

echo "nautilus-rds status: $STATUS"

if [ "$STATUS" != "available" ]; then
    echo "Waiting for nautilus-rds to become available..."
    aws rds wait db-instance-available \
        --db-instance-identifier "$SOURCE_DB" \
        --region $REGION
    echo "nautilus-rds is now available"
fi

# ============================================================
# STEP 2: Take the manual snapshot
# ============================================================

echo ""
echo "=== Step 2: Taking snapshot '$SNAPSHOT_ID' ==="

aws rds create-db-snapshot \
    --region $REGION \
    --db-instance-identifier "$SOURCE_DB" \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --tags Key=Name,Value="$SNAPSHOT_ID"

echo "Snapshot creation initiated"

[O# Wait for snapshot to be available
echo "Waiting for snapshot to be available (~3-5 minutes)..."

aws rds wait db-snapshot-available \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --region $REGION

echo "Snapshot '$SNAPSHOT_ID' is AVAILABLE"

# Show snapshot details
aws rds describe-db-snapshots \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --region $REGION \
    --query "DBSnapshots[0].{
        ID:DBSnapshotIdentifier,
        Status:Status,
        Engine:Engine,
        EngineVersion:EngineVersion,
        AllocatedStorage:AllocatedStorage,
        CreatedAt:SnapshotCreateTime
    }" --output table

# ============================================================
# STEP 3: Restore the snapshot to a new instance
# ============================================================

echo ""
echo "=== Step 3: Restoring snapshot to '$RESTORE_DB' ==="

# Get the subnet group from the source instance
SUBNET_GROUP=$(aws rds describe-db-instances \
    --db-instance-identifier "$SOURCE_DB" --region $REGION \
    --query "DBInstances[0].DBSubnetGroup.DBSubnetGroupName" \
    --output text)

# Get VPC security groups from source instance
VPC_SG=$(aws rds describe-db-instances \
    --db-instance-identifier "$SOURCE_DB" --region $REGION \
    --query "DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId" \
    --output text)

echo "Using subnet group: $SUBNET_GROUP"
echo "Using security group: $VPC_SG"

aws rds restore-db-instance-from-db-snapshot \
    --region $REGION \
    --db-instance-identifier "$RESTORE_DB" \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --db-instance-class "db.t3.micro" \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --vpc-security-group-ids "$VPC_SG" \
    --no-publicly-accessible \
    --no-multi-az \
    --tags Key=Name,Value="$RESTORE_DB"

echo "Restore initiated — waiting for available (~10-15 minutes)..."

# ============================================================
# STEP 4: Wait for restored instance to be Available
# ============================================================

aws rds wait db-instance-available \
    --db-instance-identifier "$RESTORE_DB" \
    --region $REGION

echo "✅ '$RESTORE_DB' is AVAILABLE"

# ============================================================
# STEP 5: Verify both instances and snapshot
# ============================================================

echo ""
echo "=== Step 5: Final verification ==="

echo "--- Snapshot ---"
aws rds describe-db-snapshots \
    --db-snapshot-identifier "$SNAPSHOT_ID" --region $REGION \
    --query "DBSnapshots[0].{ID:DBSnapshotIdentifier,Status:Status,Engine:Engine,Size:AllocatedStorage}" \
    --output table

echo ""
echo "--- Restored Instance ---"
aws rds describe-db-instances \
    --db-instance-identifier "$RESTORE_DB" --region $REGION \
    --query "DBInstances[0].{
        ID:DBInstanceIdentifier,
        Status:DBInstanceStatus,
        Engine:Engine,
        Version:EngineVersion,
        Class:DBInstanceClass,
        Public:PubliclyAccessible,
        Endpoint:Endpoint.Address
    }" --output table

ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$RESTORE_DB" --region $REGION \
    --query "DBInstances[0].Endpoint.Address" --output text)

echo ""
echo "============================================"
echo "  Snapshot:       $SNAPSHOT_ID  ✅ available"
echo "  Restored DB:    $RESTORE_DB   ✅ available"
echo "  Class:          db.t3.micro"
echo "  Endpoint:       $ENDPOINT"
echo "============================================"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CHECK SOURCE INSTANCE STATUS ---
aws rds describe-db-instances \
    --db-instance-identifier nautilus-rds --region $REGION \
    --query "DBInstances[0].DBInstanceStatus" --output text

# --- TAKE SNAPSHOT ---
aws rds create-db-snapshot \
    --db-instance-identifier nautilus-rds \
    --db-snapshot-identifier nautilus-snapshot \
    --region $REGION

# --- WAIT FOR SNAPSHOT AVAILABLE ---
aws rds wait db-snapshot-available \
    --db-snapshot-identifier nautilus-snapshot --region $REGION

# --- LIST SNAPSHOTS ---
aws rds describe-db-snapshots --region $REGION \
    --query "DBSnapshots[*].{ID:DBSnapshotIdentifier,Status:Status,DB:DBInstanceIdentifier}" \
    --output table

# --- RESTORE SNAPSHOT ---
aws rds restore-db-instance-from-db-snapshot \
    --db-instance-identifier nautilus-snapshot-restore \
    --db-snapshot-identifier nautilus-snapshot \
    --db-instance-class db.t3.micro \
    --no-publicly-accessible \
    --region $REGION

# --- WAIT FOR RESTORE AVAILABLE ---
aws rds wait db-instance-available \
    --db-instance-identifier nautilus-snapshot-restore --region $REGION

# --- VERIFY STATUS ---
aws rds describe-db-instances \
    --db-instance-identifier nautilus-snapshot-restore --region $REGION \
    --query "DBInstances[0].{Status:DBInstanceStatus,Class:DBInstanceClass,Endpoint:Endpoint.Address}" \
    --output table

# --- CLEANUP ---
aws rds delete-db-instance \
    --db-instance-identifier nautilus-snapshot-restore \
    --skip-final-snapshot --region $REGION
aws rds delete-db-snapshot \
    --db-snapshot-identifier nautilus-snapshot --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Taking the snapshot before the source instance is Available**
If `nautilus-rds` is in `Creating`, `Backing-up`, or `Modifying` state when you request a snapshot, the operation fails. Always confirm `available` status first. The `backing-up` state happens during automated daily backups — it's brief (minutes) but blocks manual snapshot creation.

**2. Restoring before the snapshot reaches Available**
A snapshot in `creating` state cannot be restored from. Always wait for `available` — the `aws rds wait db-snapshot-available` waiter handles this automatically in CLI. In the console, check the Snapshots section and confirm the status before clicking Restore.

**3. Not specifying `db.t3.micro` at restore time**
The restored instance defaults to the same class as the source instance. If the source was `db.t3.medium`, the restore will also be `db.t3.medium` unless overridden. The task explicitly requires `db.t3.micro` — always set the class explicitly at restore time.

**4. Forgetting that the restored instance has a new endpoint**
The restored instance gets an entirely new DNS endpoint. Any application that hardcodes the source endpoint won't automatically switch. After validating the restored instance, you'd update the application's connection string to point to the new endpoint.

**5. Manual snapshots incur storage costs indefinitely**
Unlike automated backups (which are deleted when the instance is deleted), manual snapshots persist until you explicitly delete them. A forgotten 100 GB snapshot costs ~$1.25/month in storage forever. Always clean up test snapshots after the task is complete.

---

## 🌍 Real-World Context

**Pre-upgrade validation** — exactly the pattern described in this task — is one of the most common uses for RDS snapshots in production:

1. Take snapshot of production DB
2. Restore to `prod-db-test`
3. Run the migration script against `prod-db-test`
4. Validate application works against the migrated DB
5. Run the same migration on production
6. Delete the test instance and snapshot

This gives a dry run with real production data, at a fraction of the cost (test instance runs for hours, not days).

**Snapshot copying for DR:** RDS snapshots can be copied to another region: `aws rds copy-db-snapshot --source-region us-east-1 --target-region eu-west-1`. This gives a cross-region backup for disaster recovery — if us-east-1 goes down, you restore from the copy in eu-west-1. Many compliance frameworks require cross-region backup copies.

**Cross-account snapshot sharing:** Snapshots can be shared with specific AWS accounts: `aws rds modify-db-snapshot-attribute --attribute-name restore --values-to-add ACCOUNT_ID`. This lets a DevOps account create a sanitized copy of production data and share it to a development account — without giving the dev account access to production.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. What is the difference between RDS automated backups and manual snapshots?**
> Automated backups are taken daily by RDS automatically within a configurable backup window and retained for 0–35 days. They enable point-in-time recovery to any second within the retention window by combining the daily snapshot with transaction logs. They are deleted when the DB instance is deleted (unless you take a final snapshot). Manual snapshots are taken on-demand, persist indefinitely until explicitly deleted, and capture a specific moment in time — no PITR capability between snapshots. Use automated backups for continuous protection and PITR; use manual snapshots for checkpoints before major changes, cross-account sharing, or long-term retention beyond the automated backup window.

**Q2. Can you restore an RDS snapshot to a different DB engine or version?**
> You cannot change the engine (e.g., MySQL to PostgreSQL). You can restore to a higher minor version of the same engine (e.g., MySQL 8.0.28 to 8.0.35) but not to a lower version. Major version upgrades require a separate upgrade process on the running instance, not via snapshot restore. For MySQL, you can restore a MySQL 8.0 snapshot to a MySQL 8.0 instance — the exact patch version at restore is configurable within the same major.minor family. Engine version is one of the few parameters you can override at restore time; the engine itself is fixed.

**Q3. How long does an RDS snapshot take and what affects the duration?**
> The first snapshot of an RDS instance takes longer because it backs up the entire allocated storage volume. Subsequent snapshots are incremental — they only capture blocks changed since the last snapshot — so they're faster. Duration depends on: allocated storage size (not used data — a 20 GB allocated volume with 1 GB of data still processes 20 GB), I/O activity on the instance during the snapshot (heavy writes slow it), and storage type. A 20 GB gp2 instance with minimal load takes 2–5 minutes. A 1 TB io1 instance under heavy load could take 30+ minutes. During the snapshot, the instance remains available but may have slightly elevated latency.

**Q4. A restore took the wrong instance class — the instance is already Available. How do you fix it?**
> Modify the running instance: `aws rds modify-db-instance --db-instance-identifier nautilus-snapshot-restore --db-instance-class db.t3.micro --apply-immediately`. Changing instance class requires a brief downtime (1–5 minutes for the instance to restart on new hardware). Without `--apply-immediately`, the change happens during the next maintenance window. In the console: Databases → select instance → Modify → change instance class → Apply immediately.

**Q5. How would you automate regular RDS snapshots beyond the built-in automated backup?**
> Three approaches in order of complexity. First, use **AWS Backup** — a centralised backup service that can schedule RDS snapshots, enforce retention policies, and copy to other regions/accounts. Second, use **EventBridge + Lambda**: a scheduled EventBridge rule triggers a Lambda function that calls `create-db-snapshot` with a timestamp in the name, and another Lambda on a longer schedule calls `describe-db-snapshots` to delete snapshots older than the retention period. Third, for cross-region DR specifically, **RDS snapshot copy** can be triggered from a Lambda after each automated snapshot completes, using the `RDS DB Snapshot Event` via EventBridge as the trigger. AWS Backup is the cleanest solution for most teams — purpose-built, auditable, and policy-driven.

**Q6. What is the difference between restoring a snapshot vs promoting a Read Replica?**
> Restoring a snapshot creates a new independent DB instance from a point-in-time backup. It has no ongoing relationship with the source — it's a fresh standalone instance from historical data. It takes 10–20 minutes. Promoting a Read Replica breaks the replication relationship and converts the replica into a standalone DB instance — it becomes writable and independent. The replica is already running and has been continuously receiving changes from the primary, so its data is near-current (seconds behind, depending on replication lag). Promotion is near-instant. Snapshot restore is used for data recovery and cloning; replica promotion is used for DR failover when the primary is unavailable and the replica has been kept in sync.

**Q7. How do you share an RDS snapshot with another AWS account?**
> Two steps. First, make the snapshot visible to the target account by modifying the snapshot's restore attribute: `aws rds modify-db-snapshot-attribute --db-snapshot-identifier nautilus-snapshot --attribute-name restore --values-to-add TARGET_ACCOUNT_ID`. Second, from the target account, copy the snapshot to their own account: `aws rds copy-db-snapshot --source-db-snapshot-identifier arn:aws:rds:us-east-1:SOURCE_ACCOUNT_ID:snapshot:nautilus-snapshot --target-db-snapshot-identifier nautilus-snapshot-copy --source-region us-east-1`. The target account can then restore from their local copy. For encrypted snapshots, you must also share the KMS key used to encrypt it by adding the target account as a key user in the KMS key policy.

---

## 📚 Resources

- [AWS Docs — RDS Snapshots](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_CreateSnapshot.html)
- [AWS Docs — Restoring from Snapshot](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_RestoreFromSnapshot.html)
- [RDS Point-In-Time Recovery](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIT.html)
- [AWS Backup for RDS](https://docs.aws.amazon.com/aws-backup/latest/devguide/creating-a-backup-plan.html)
- [Cross-Region Snapshot Copy](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_CopySnapshot.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
