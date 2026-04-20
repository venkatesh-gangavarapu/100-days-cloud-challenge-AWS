# Day 04 — Enabling S3 Bucket Versioning

> **#100DaysOfCloud | Day 4 of 100**

---

## 📌 The Task

> *Data protection and recovery are fundamental aspects of data management. It's essential to have systems in place to ensure that data can be recovered in case of accidental deletion or corruption. The DevOps team has received a requirement for implementing such measures for one of the S3 buckets they are managing.*

**Requirement:** Enable versioning on the S3 bucket `nautilus-s3-12780` in `us-east-1`.

---

## 🧠 Core Concepts

### What Is S3 Versioning?

Amazon S3 Versioning is a bucket-level feature that keeps **multiple variants of an object** in the same bucket. Every time an object is uploaded, modified, or deleted, S3 preserves the previous state rather than overwriting it. Each version gets a unique **Version ID** — a randomly generated string that AWS assigns automatically.

Without versioning, uploading a file with the same key silently overwrites the previous version. With versioning enabled, both the old and new versions coexist in the bucket, accessible by their version IDs.

### Three States a Bucket Can Be In

| State | Description |
|-------|-------------|
| **Unversioned** | Default state. No version IDs. Overwrites and deletes are permanent. |
| **Versioning-enabled** | All objects get a version ID. Nothing is truly overwritten or deleted. |
| **Versioning-suspended** | Versioning was enabled but then paused. Existing versions are preserved; new uploads get a `null` version ID. |

> ⚠️ Once versioning is enabled on a bucket, it can be **suspended** but never fully disabled. You can't go back to the unversioned state.

### How Deletes Work With Versioning

When you delete an object in a versioning-enabled bucket **without specifying a version ID**, S3 doesn't actually remove the data. Instead, it inserts a **Delete Marker** — a special placeholder object that makes the key appear absent in the default object listing. The original versions are still there, retrievable by their version ID.

To permanently delete an object, you must **explicitly delete each version** by specifying the version ID. This is both the protection mechanism and the operational consideration when it comes to storage costs.

### Why This Matters in Production

Versioning is the foundation of several data protection strategies:

- **Accidental deletion recovery** — restore any object to any previous state in seconds
- **Ransomware protection** — attackers can overwrite objects, but previous clean versions survive
- **Audit trail** — a complete history of every change to every object in the bucket
- **MFA Delete** — when combined with MFA Delete, even the bucket owner can't permanently delete versions without a hardware MFA token (used for compliance-grade protection)
- **S3 Replication** — cross-region and same-region replication require versioning to be enabled on the source bucket

### Storage Cost Consideration

Every version of every object is stored and billed independently. A 100 MB file updated 50 times means roughly 5 GB of S3 storage. For large buckets with frequent writes, this can drive significant cost growth. **S3 Lifecycle Policies** exist specifically to manage this — for example, automatically deleting non-current versions older than 30 days.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Log in to the [AWS Console](https://415500486906.signin.aws.amazon.com/console?region=us-east-1)
2. Navigate to **S3** → search for and select `nautilus-s3-12780`
3. Click the **Properties** tab
4. Scroll to **Bucket Versioning** → click **Edit**
5. Select **Enable**
6. Click **Save changes**
7. Confirm: the Bucket Versioning section now shows **Enabled**

---

### Method 2 — AWS CLI

```bash
# Step 1: Verify the bucket exists and check its current versioning status
aws s3api get-bucket-versioning \
    --bucket nautilus-s3-12780 \
    --region us-east-1

# If versioning has never been enabled, the output will be empty: {}
# If suspended, it will show: { "Status": "Suspended" }

# Step 2: Enable versioning
aws s3api put-bucket-versioning \
    --bucket nautilus-s3-12780 \
    --region us-east-1 \
    --versioning-configuration Status=Enabled

# Step 3: Confirm versioning is now enabled
aws s3api get-bucket-versioning \
    --bucket nautilus-s3-12780 \
    --region us-east-1

# Expected output:
# {
#     "Status": "Enabled"
# }
```

---

### Verifying Versioning in Practice

Once versioning is enabled, upload an object twice to see multiple versions created:

```bash
# Create a test file and upload it
echo "version 1 content" > test-file.txt
aws s3 cp test-file.txt s3://nautilus-s3-12780/test-file.txt

# Overwrite it with new content
echo "version 2 content" > test-file.txt
aws s3 cp test-file.txt s3://nautilus-s3-12780/test-file.txt

# List all versions of the object — both should appear
aws s3api list-object-versions \
    --bucket nautilus-s3-12780 \
    --prefix test-file.txt

# Retrieve a specific older version by version ID
aws s3api get-object \
    --bucket nautilus-s3-12780 \
    --key test-file.txt \
    --version-id <VERSION_ID> \
    recovered-file.txt
```

---

### Suspending Versioning (If Required Later)

```bash
# Suspend versioning — does NOT delete existing versions
aws s3api put-bucket-versioning \
    --bucket nautilus-s3-12780 \
    --region us-east-1 \
    --versioning-configuration Status=Suspended
```

---

### Permanently Deleting a Specific Version

```bash
# List all versions
aws s3api list-object-versions --bucket nautilus-s3-12780

# Delete a specific version permanently
aws s3api delete-object \
    --bucket nautilus-s3-12780 \
    --key test-file.txt \
    --version-id <VERSION_ID>

# Delete a delete marker
aws s3api delete-object \
    --bucket nautilus-s3-12780 \
    --key test-file.txt \
    --version-id <DELETE_MARKER_VERSION_ID>
```

---

## 💻 Commands Reference

```bash
# --- CHECK CURRENT VERSIONING STATE ---
aws s3api get-bucket-versioning \
    --bucket nautilus-s3-12780 \
    --region us-east-1

# --- ENABLE VERSIONING ---
aws s3api put-bucket-versioning \
    --bucket nautilus-s3-12780 \
    --region us-east-1 \
    --versioning-configuration Status=Enabled

# --- VERIFY ---
aws s3api get-bucket-versioning \
    --bucket nautilus-s3-12780 \
    --region us-east-1

# --- LIST ALL VERSIONS OF ALL OBJECTS ---
aws s3api list-object-versions \
    --bucket nautilus-s3-12780

# --- LIST VERSIONS OF A SPECIFIC OBJECT ---
aws s3api list-object-versions \
    --bucket nautilus-s3-12780 \
    --prefix test-file.txt

# --- RETRIEVE A SPECIFIC VERSION ---
aws s3api get-object \
    --bucket nautilus-s3-12780 \
    --key test-file.txt \
    --version-id <VERSION_ID> \
    output-file.txt

# --- DELETE A SPECIFIC VERSION PERMANENTLY ---
aws s3api delete-object \
    --bucket nautilus-s3-12780 \
    --key test-file.txt \
    --version-id <VERSION_ID>

# --- SUSPEND VERSIONING ---
aws s3api put-bucket-versioning \
    --bucket nautilus-s3-12780 \
    --region us-east-1 \
    --versioning-configuration Status=Suspended
```

---

## ⚠️ Common Mistakes

**1. Assuming versioning can be fully disabled once enabled**
Once you enable versioning, you can only suspend it — never revert to the unversioned state. Suspending stops new versions from being created but preserves all existing versions. This is worth communicating to stakeholders before enabling it: it's a one-way door in terms of state.

**2. Confusing a delete marker with actual deletion**
Deleting an object in a versioning-enabled bucket (without specifying a version ID) does not remove the data. It creates a delete marker, which makes the object appear gone in normal listings. The data is still there, still billable, and fully recoverable. This surprises people who think they cleaned up a bucket and then get a storage bill.

**3. Not pairing versioning with a Lifecycle Policy**
Versioning without a lifecycle policy means every version of every object accumulates indefinitely. For a bucket with high write frequency, storage costs can balloon quickly. Always define a lifecycle rule to transition or expire non-current versions on a schedule that matches your recovery window requirements.

**4. Thinking versioning protects against all data loss scenarios**
Versioning protects against accidental overwrites and deletes within the same region. It does not protect against regional outages, bucket deletions (which deletes all versions too), or misconfigured access that allows mass version deletion. For those scenarios, you need cross-region replication and bucket policies that restrict `s3:DeleteBucket`.

**5. Forgetting that versioning applies only to new operations**
Enabling versioning on a bucket does not retroactively create versions for objects that already exist. Pre-existing objects get the version ID `null`. Only operations performed after versioning is enabled produce versioned objects.

---

## 🌍 Real-World Context

In production environments, enabling versioning is typically one of the first things applied to any S3 bucket that stores customer data, application artifacts, configuration files, or infrastructure state (like Terraform state stored in S3). The workflow usually looks like this:

1. **Enable versioning** — done immediately when the bucket is created or brought under management
2. **Enable MFA Delete** — for buckets holding critical or compliance-sensitive data, this prevents version deletion without a hardware token
3. **Set a Lifecycle Policy** — expire non-current versions after 30, 60, or 90 days depending on the data's recovery requirements
4. **Enable access logging or S3 Server Access Logs** — so you have an audit trail of who accessed or modified what version

Versioning is also a hard requirement for **S3 Cross-Region Replication (CRR)** and **Same-Region Replication (SRR)**. If you ever need to replicate a bucket to another region for disaster recovery, versioning must be enabled on the source bucket first.

A real-world pattern I see often: teams enable versioning after an incident (someone accidentally `aws s3 rm --recursive`'d the wrong bucket). Don't wait for the incident. Enable versioning — and pair it with a lifecycle policy — before anything important lands in the bucket.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. A developer accidentally deleted a critical file from an S3 bucket. How do you recover it — and what needs to have been in place beforehand?**

> If versioning was enabled before the deletion, recovery is straightforward. When an object is deleted without specifying a version ID, S3 inserts a Delete Marker rather than destroying the data. You list the object's versions with `aws s3api list-object-versions`, identify the Delete Marker version ID, delete the marker itself, and the object reappears as if nothing happened. If versioning was not enabled, the data is permanently gone — S3 doesn't have a recycle bin for non-versioned objects. This is exactly why enabling versioning upfront, before data lands in the bucket, is non-negotiable for anything important.

---

**Q2. What's the difference between versioning-enabled and versioning-suspended? When would you suspend it?**

> When versioning is enabled, every write produces a new version with a unique version ID and all versions are preserved. When versioning is suspended, new objects written to the bucket get a `null` version ID and overwrite any previously existing `null` version — effectively behaving like an unversioned bucket for new writes, while all previously versioned objects remain intact. You'd suspend versioning if storage costs from accumulated versions are becoming a problem and you can't immediately clean them up, or during a specific data migration where you deliberately want single-version behaviour temporarily. Suspension is reversible; you can re-enable versioning at any time.

---

**Q3. How do S3 Lifecycle Policies interact with versioning, and why should they always be used together?**

> Lifecycle policies let you define rules that automatically transition or expire object versions on a schedule. For versioned buckets, there are two key rule types: rules that apply to the **current version** (e.g., move to S3 Glacier after 90 days) and rules that apply to **non-current versions** (e.g., delete versions that are older than 30 days and are no longer current). Without a lifecycle policy, every version of every object accumulates indefinitely. In a bucket with thousands of objects updated frequently, this can mean millions of version objects and a storage bill that grows without bound. The standard pattern is: enable versioning for protection, and set a non-current version expiration rule to keep storage costs predictable — usually retaining the last 2–3 versions or anything within 30 days.

---

**Q4. Versioning is a prerequisite for which other S3 features?**

> Two main ones in day-to-day infrastructure work. First, **S3 Replication** — both Cross-Region Replication (CRR) for disaster recovery and Same-Region Replication (SRR) for compliance or data separation require versioning to be enabled on the source bucket (and recommended on the destination). Second, **MFA Delete** — which adds a layer of protection requiring an MFA token to permanently delete versions or change versioning state, can only be enabled on a bucket that already has versioning enabled. Versioning also integrates with **S3 Object Lock** for WORM (Write Once Read Many) compliance scenarios, though that's a distinct feature.

---

**Q5. What happens to objects in a bucket that existed before versioning was enabled?**

> They don't get retroactively versioned. Pre-existing objects get a version ID of `null`. If you later overwrite one of those objects after versioning is enabled, S3 stores both the new version (with a proper version ID) and the original `null` version. If you then delete the `null` version explicitly, you permanently remove the original. This is important to understand when auditing a bucket that had versioning enabled mid-life — not everything in it has a complete version history.

---

**Q6. What's MFA Delete and when would you actually use it?**

> MFA Delete requires the bucket owner to authenticate with a hardware MFA device to either permanently delete an object version or to change the versioning state of the bucket (enable or suspend). It's an additional safeguard on top of IAM permissions — even if an attacker gets your AWS credentials, they can't mass-delete versions without physical access to your MFA token. In practice, it's used for buckets storing financial records, audit logs, compliance data, or anything subject to regulations like SOC 2, PCI DSS, or HIPAA that requires immutable data retention. It's operationally annoying for day-to-day use, which is why it's reserved for the most critical buckets rather than applied broadly.

---

**Q7. A bucket has versioning enabled and an attacker gained write access and overwrote all objects with garbage data. Walk me through recovery.**

> First, revoke the attacker's access and rotate any compromised credentials. Then use `aws s3api list-object-versions` to enumerate all versions and delete markers for affected objects. For each overwritten object, identify the last clean version ID (the one before the attacker's write) and either copy it back as the current version or delete the attacker's version to restore the previous one. If the attack touched thousands of objects, this needs a script that iterates over all versions, identifies versions created after a known-clean timestamp, and programmatically deletes or restores accordingly. Going forward, pair versioning with **S3 Object Lock** in Governance or Compliance mode for buckets that can't tolerate even temporary overwrites — Lock prevents overwrite entirely, not just recovers after the fact.

---

## 📚 Resources

- [AWS Docs — Using Versioning in S3 Buckets](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)
- [AWS CLI Reference — put-bucket-versioning](https://docs.aws.amazon.com/cli/latest/reference/s3api/put-bucket-versioning.html)
- [S3 Lifecycle Policies with Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)
- [S3 MFA Delete](https://docs.aws.amazon.com/AmazonS3/latest/userguide/MultiFactorAuthenticationDelete.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
