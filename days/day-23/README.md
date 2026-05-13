# Day 23 — S3 Data Migration: Create Bucket and Sync Data

> **#100DaysOfCloud | Day 23 of 100**

---

## 📌 The Task

> *Migrate all data from an existing S3 bucket to a new private S3 bucket. Ensure data consistency after migration.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Source bucket | `datacenter-s3-6464` |
| Destination bucket | `datacenter-sync-25967` |
| Bucket type | Private |
| Migration tool | AWS CLI |
| Region | `us-east-1` |
| Verification | Both buckets must have identical data |

---

## 🧠 Core Concepts

### S3 Bucket Basics

**Amazon S3 (Simple Storage Service)** is AWS's object storage service. Objects are stored in **buckets** — globally unique namespaced containers. S3 is not a traditional filesystem; it has a flat structure where "folders" are just key prefixes. Every object has a **key** (its full path), **data** (the content), and **metadata** (content-type, tags, encryption settings, etc.).

### Private Bucket — What It Means

A "private" S3 bucket in 2024+ AWS means:
- **Block Public Access** is enabled (all four settings)
- No bucket ACL grants public read/write
- No bucket policy grants `Principal: "*"` access
- Objects are not individually public

AWS now defaults to **block public access enabled** for all new buckets — a change made after several high-profile data breaches from misconfigured public buckets. Creating a private bucket today is essentially the default; what you're doing is confirming the settings are correct.

### `aws s3 cp` vs `aws s3 sync` — Choosing the Right Tool

| Command | What It Does | When to Use |
|---------|-------------|-------------|
| `aws s3 cp` | Copies individual files or a prefix with `--recursive` | Single objects, simple recursive copies |
| `aws s3 sync` | Syncs the **delta** — copies only objects that don't exist or differ in destination | Incremental migrations, ongoing sync jobs |
| `aws s3 mv` | Moves objects (copy + delete source) | When you want to empty the source |

For a **data migration with consistency verification**, `aws s3 sync` is the correct choice:
- It's idempotent — running it twice doesn't duplicate data
- It handles large datasets efficiently (skips objects already transferred)
- If the migration fails partway through, rerunning `sync` continues from where it left off
- The final state is guaranteed: destination matches source

### How `aws s3 sync` Determines What to Copy

By default, `sync` compares objects by:
1. **Object key** — if the key doesn't exist in destination, copy it
2. **Size** — if sizes differ, copy it
3. **Last modified date** — if source is newer, copy it (for local→S3; for S3→S3, ETag is used)

This means if both buckets have identical objects (same key, same size, same ETag), `sync` won't copy anything — it correctly identifies no work to do.

### Cross-Bucket Copy — Same Account vs Cross-Account

This task is a **same-account S3-to-S3 copy**. AWS handles this server-side — data doesn't leave AWS infrastructure. The CLI orchestrates the transfer by:
1. Listing source objects
2. Issuing server-side copy requests (no data downloaded to your client)
3. Verifying each copy succeeds

For cross-account copies, the source bucket needs a bucket policy granting the destination account read access, and you'd use `--source-region` / `--region` flags when accounts are in different regions.

### Verification Methods

| Method | What It Checks | How to Do It |
|--------|---------------|-------------|
| Object count | Same number of objects in both buckets | `aws s3 ls --recursive | wc -l` |
| Total size | Same total bytes transferred | `aws s3 ls --summarize` |
| ETag comparison | Per-object hash match | Script comparing ETags |
| Re-run sync | No additional objects copied = in sync | `aws s3 sync --dryrun` |

A re-run of `sync --dryrun` showing zero operations is the cleanest verification — it proves the destination already matches the source.

---

## 🔧 Step-by-Step Solution

### Method — AWS CLI (as required by the task)

```bash
# ============================================================
# Step 1: Create the new private S3 bucket
# ============================================================

# In us-east-1, do NOT use --create-bucket-configuration
# (us-east-1 is the default region and doesn't accept a LocationConstraint)
aws s3api create-bucket \
    --bucket datacenter-sync-25967 \
    --region us-east-1

# Confirm creation
echo "Bucket created. Verifying..."

# ============================================================
# Step 2: Enable Block Public Access (enforce private)
# ============================================================

aws s3api put-public-access-block \
    --bucket datacenter-sync-25967 \
    --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "Block Public Access enabled — bucket is private"

# ============================================================
# Step 3: Verify the source bucket exists and list its contents
# ============================================================

echo "=== Source Bucket Contents ==="
aws s3 ls s3://datacenter-s3-6464 --recursive --human-readable --summarize

# ============================================================
# Step 4: Sync all data from source to destination
# ============================================================

echo "=== Starting Data Migration ==="
aws s3 sync \
    s3://datacenter-s3-6464 \
    s3://datacenter-sync-25967 \
    --region us-east-1

echo "Sync complete"

# ============================================================
# Step 5: Verify data consistency
# ============================================================

echo ""
echo "=== Verification: Source Bucket ==="
aws s3 ls s3://datacenter-s3-6464 --recursive --summarize | tail -3

echo ""
echo "=== Verification: Destination Bucket ==="
aws s3 ls s3://datacenter-sync-25967 --recursive --summarize | tail -3

# ============================================================
# Step 6: Re-run sync --dryrun to confirm zero delta
# (No output = both buckets are in sync)
# ============================================================

echo ""
echo "=== Final Check: Re-running sync --dryrun (should show no operations) ==="
DELTA=$(aws s3 sync \
    s3://datacenter-s3-6464 \
    s3://datacenter-sync-25967 \
    --dryrun \
    --region us-east-1)

if [ -z "$DELTA" ]; then
    echo "✅ VERIFIED: Both buckets are in sync — no differences detected"
else
    echo "⚠️ Differences still exist:"
    echo "$DELTA"
fi
```

---

### Creating the Bucket in Any Other Region (Reference)

```bash
# For any region OTHER than us-east-1 (requires LocationConstraint)
aws s3api create-bucket \
    --bucket my-bucket-name \
    --region ap-south-1 \
    --create-bucket-configuration LocationConstraint=ap-south-1
```

> ⚠️ **Important:** `us-east-1` is the only region that does NOT accept `--create-bucket-configuration`. Every other region requires it. This is a well-known AWS quirk.

---

### Detailed Object-Level Verification (ETag Comparison)

```bash
# List all objects with ETag, size, and key from source
echo "=== Source Objects ==="
aws s3api list-objects-v2 \
    --bucket datacenter-s3-6464 \
    --query "Contents[*].{Key:Key,Size:Size,ETag:ETag}" \
    --output table

# List all objects with ETag, size, and key from destination
echo "=== Destination Objects ==="
aws s3api list-objects-v2 \
    --bucket datacenter-sync-25967 \
    --query "Contents[*].{Key:Key,Size:Size,ETag:ETag}" \
    --output table

# Count comparison
SOURCE_COUNT=$(aws s3api list-objects-v2 \
    --bucket datacenter-s3-6464 \
    --query "length(Contents)" \
    --output text)

DEST_COUNT=$(aws s3api list-objects-v2 \
    --bucket datacenter-sync-25967 \
    --query "length(Contents)" \
    --output text)

echo "Source object count:      $SOURCE_COUNT"
echo "Destination object count: $DEST_COUNT"

if [ "$SOURCE_COUNT" == "$DEST_COUNT" ]; then
    echo "✅ Object counts match"
else
    echo "⚠️  Object count mismatch — re-run sync"
fi
```

---

### Enabling Versioning on the New Bucket (Optional Best Practice)

```bash
# Enable versioning for protection against accidental overwrites
aws s3api put-bucket-versioning \
    --bucket datacenter-sync-25967 \
    --versioning-configuration Status=Enabled

# Verify
aws s3api get-bucket-versioning \
    --bucket datacenter-sync-25967
```

---

## 💻 Commands Reference

```bash
# --- CREATE BUCKET (us-east-1) ---
aws s3api create-bucket \
    --bucket datacenter-sync-25967 --region us-east-1

# --- BLOCK PUBLIC ACCESS ---
aws s3api put-public-access-block \
    --bucket datacenter-sync-25967 \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# --- VERIFY BUCKET EXISTS ---
aws s3api head-bucket --bucket datacenter-sync-25967

# --- LIST SOURCE CONTENTS ---
aws s3 ls s3://datacenter-s3-6464 --recursive --human-readable --summarize

# --- MIGRATE DATA ---
aws s3 sync s3://datacenter-s3-6464 s3://datacenter-sync-25967 --region us-east-1

# --- VERIFY: OBJECT COUNTS ---
aws s3api list-objects-v2 --bucket datacenter-s3-6464 \
    --query "length(Contents)" --output text

aws s3api list-objects-v2 --bucket datacenter-sync-25967 \
    --query "length(Contents)" --output text

# --- VERIFY: FULL SUMMARY ---
aws s3 ls s3://datacenter-sync-25967 --recursive --summarize | tail -3

# --- VERIFY: DRY RUN SYNC (zero output = in sync) ---
aws s3 sync s3://datacenter-s3-6464 s3://datacenter-sync-25967 \
    --dryrun --region us-east-1

# --- DELETE BUCKET (cleanup — must empty first) ---
aws s3 rm s3://datacenter-sync-25967 --recursive
aws s3api delete-bucket --bucket datacenter-sync-25967 --region us-east-1
```

---

## ⚠️ Common Mistakes

**1. Using `--create-bucket-configuration` for `us-east-1`**
Every region except `us-east-1` requires `--create-bucket-configuration LocationConstraint=<region>`. Using it for `us-east-1` causes: `An error occurred (InvalidLocationConstraint)`. This is the most common S3 bucket creation error and is an AWS-specific quirk worth memorising.

**2. Using `aws s3 cp --recursive` instead of `aws s3 sync` for migration**
`cp --recursive` copies everything unconditionally — if you run it twice, you pay double the PUT requests. `sync` is idempotent and efficient — it only copies what's missing or different. For any migration that might need to be re-run (network interruptions, large datasets), `sync` is always the right choice.

**3. Verifying only by running the sync once and assuming it worked**
The gold-standard verification is: run `sync --dryrun` after migration. If the output is empty, the destination is a perfect match of the source. If it shows objects to copy, the migration isn't complete. Object count comparison is a quick sanity check but doesn't catch object corruption or partial uploads.

**4. Forgetting to check Block Public Access settings**
Even though new buckets default to block-public-access enabled in modern AWS, you should explicitly verify and set it on any bucket holding sensitive or production data. Never assume the default is applied — explicitly configure it and verify.

**5. Not considering S3 Object Ownership and ACLs during cross-account migration**
In a same-account migration (this task), object ownership is automatic and ACLs aren't an issue. In cross-account migrations, objects copied from Account A to Account B are owned by Account B by default — but if the source had ACLs, those ACLs don't transfer by default. Use `--acl bucket-owner-full-control` when syncing cross-account if the destination needs full object ownership.

**6. Not accounting for versioned objects in the source bucket**
If the source bucket has versioning enabled, `aws s3 sync` only copies the **current version** of each object — non-current versions are not migrated. To migrate all versions of all objects, you need to list all versions via `list-object-versions` and copy each explicitly. For this task, a non-versioned sync is sufficient.

---

## 🌍 Real-World Context

S3 data migration is one of the most common operational tasks in AWS environments. It comes up in multiple scenarios:

**Bucket rename (workaround):** S3 buckets can't be renamed. The only way to "rename" a bucket is to create a new one with the desired name, sync all data, update all references (application configs, IAM policies, CloudFront origins), and delete the old bucket. This is a multi-step process that teams underestimate — the `sync` is the easy part; updating every reference to the old bucket name is where the work is.

**Region migration:** Moving data from one region to another requires creating a bucket in the target region and syncing. Cross-region `aws s3 sync` works directly — AWS handles the transfer server-side. Consider the egress costs: S3 → S3 in the same region is free; cross-region transfers are charged.

**Account migration:** When consolidating AWS accounts or migrating workloads to a new account, S3 data migration is always part of the effort. This requires bucket policies on the source to allow the destination account to read, and `--acl bucket-owner-full-control` on the sync to ensure the new account owns the copied objects.

**Backup and DR:** Regular `aws s3 sync` from production bucket to a DR bucket in a secondary region is a common backup pattern — simpler than S3 Cross-Region Replication for workloads where near-real-time replication isn't needed.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is the difference between `aws s3 cp --recursive` and `aws s3 sync`?**

> `cp --recursive` copies all objects unconditionally — every time you run it, all objects are re-copied regardless of whether they already exist in the destination. This is inefficient for large datasets and means re-runs double your S3 request costs. `sync` compares the source and destination and only copies objects that are missing or have changed (different size or modification date). It's idempotent — running it multiple times converges to the same state without duplicating operations. For data migration, `sync` is almost always the right tool: efficient, resumable if interrupted, and the re-run `--dryrun` gives you a clean verification mechanism.

---

**Q2. Why does `aws s3api create-bucket` fail with `InvalidLocationConstraint` for `us-east-1`?**

> `us-east-1` (US East, N. Virginia) is the original AWS region and is treated as the default S3 region. When you call `create-bucket` without `--create-bucket-configuration`, the bucket is created in `us-east-1` implicitly. If you *also* pass `--create-bucket-configuration LocationConstraint=us-east-1`, AWS considers it contradictory (you're saying "put this in us-east-1" while the default is already us-east-1) and returns `InvalidLocationConstraint`. For every other region, the LocationConstraint parameter is required. The fix: for `us-east-1`, never include `--create-bucket-configuration`. For all other regions, always include it.

---

**Q3. How would you verify that a data migration between two S3 buckets was completely successful?**

> A layered verification approach: first, compare object counts — `aws s3api list-objects-v2 --query "length(Contents)"` on both buckets should return the same number. Second, compare total sizes via `aws s3 ls --summarize` — total bytes should match. Third — and most definitive — re-run the sync with `--dryrun`. If the output is empty, the destination is a perfect match of the source and no further action is needed. If objects appear in the dry-run output, the migration isn't complete. For maximum confidence, an ETag comparison (listing ETags from both buckets and diffing them) validates per-object data integrity, not just counts and sizes.

---

**Q4. The source bucket has 10 million objects. How does `aws s3 sync` handle this efficiently?**

> For very large buckets, `aws s3 sync` with `--size-only` and parallel workers is the right approach. Add `--size-only` to skip the modification date comparison and rely only on size (faster for large inventories). Add `--page-size` to control how many objects are listed per API call. For extremely large migrations (hundreds of terabytes or billions of objects), the better tool is **AWS DataSync** or **S3 Batch Operations** — they're purpose-built for massive-scale migrations with bandwidth controls, retry logic, and task monitoring. The CLI `sync` is appropriate for most workloads up to a few hundred thousand objects; beyond that, purpose-built services are more reliable.

---

**Q5. What does Block Public Access actually do and why should you always enable it on new buckets?**

> Block Public Access is a bucket-level setting that overrides any bucket policies or ACLs that would otherwise make objects public. It has four settings: `BlockPublicAcls` prevents new ACLs from granting public access; `IgnorePublicAcls` makes the bucket ignore any existing ACLs that grant public access; `BlockPublicPolicy` prevents bucket policies that allow public access from being added; `RestrictPublicBuckets` blocks public and cross-account access to buckets with bucket policies that grant those permissions. Enabling all four creates a strong safety layer — even if a developer accidentally adds a policy granting `Principal: "*"`, the block overrides it. Several major data breaches (Capital One, GoDaddy, etc.) involved misconfigured S3 buckets without block public access. It should be the default for all data buckets.

---

**Q6. How would you migrate S3 data from one AWS account to another?**

> Three steps. First, add a bucket policy to the source bucket that grants the destination account's IAM role read access — `s3:GetObject`, `s3:ListBucket` on the source. Second, from the destination account (assuming the cross-account role), run `aws s3 sync` with `--acl bucket-owner-full-control` — this flag ensures the copied objects are owned by the destination account, not the source account. Without it, objects in the destination bucket are owned by the source account and the destination account can't modify or delete them. Third, verify as usual with object count, size comparison, and a dry-run sync. Clean up the bucket policy on the source after migration is confirmed.

---

**Q7. What is S3 Cross-Region Replication (CRR) and when would you use it instead of `sync`?**

> S3 Cross-Region Replication is a continuous, near-real-time replication feature that automatically copies every new object written to the source bucket to one or more destination buckets in different regions. It's configured once via a replication rule and runs automatically — no scheduled jobs, no manual syncs. Use CRR when: you need near-real-time data availability in a secondary region for DR; compliance requires geographic data residency in multiple regions; you want a hot standby with sub-minute RPO (Recovery Point Objective). Use `aws s3 sync` when: you're doing a one-time migration; you need to replicate historical data (CRR only replicates objects added after the rule is created — you'd still need an initial `sync` to backfill); you need full control over when and how often data is replicated; or the cost of continuous replication isn't justified for your RPO requirements.

---

## 📚 Resources

- [AWS Docs — create-bucket CLI](https://docs.aws.amazon.com/cli/latest/reference/s3api/create-bucket.html)
- [AWS Docs — aws s3 sync](https://docs.aws.amazon.com/cli/latest/reference/s3/sync.html)
- [S3 Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)
- [S3 Cross-Region Replication](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication.html)
- [AWS DataSync for Large-Scale Migration](https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
