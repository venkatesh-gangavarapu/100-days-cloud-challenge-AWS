# Day 13 — Creating an AMI from an EC2 Instance

> **#100DaysOfCloud | Day 13 of 100**

---

## 📌 The Task

> *Create an AMI from the existing EC2 instance `nautilus-ec2`. The AMI must be named `nautilus-ec2-ami` and must reach `available` state.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Source instance | `nautilus-ec2` |
| AMI name | `nautilus-ec2-ami` |
| Required state | `available` |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### What Is an AMI?

An **Amazon Machine Image (AMI)** is a complete snapshot of an EC2 instance — the operating system, installed software, configuration files, and data on the root volume — packaged into a template you can use to launch identical instances. It's the answer to "I want to launch 10 more instances that look exactly like this one."

An AMI contains:
- A **root volume snapshot** (the OS + everything installed on it)
- **Block device mappings** — which EBS volumes to attach and at which device names, with what size
- **Launch permissions** — who can use this AMI
- **Virtualization type** — HVM (hardware virtual machine, standard for all modern instances)
- **Architecture** — x86_64 or arm64

### AMI vs Snapshot — The Difference

This is a common point of confusion:

| | AMI | EBS Snapshot |
|--|-----|-------------|
| **What it is** | Launch template for EC2 instances | Point-in-time backup of a single EBS volume |
| **Contains** | Snapshot(s) + metadata + block device mappings | Raw volume data only |
| **Used for** | Launching new instances | Restoring individual volumes, creating AMIs |
| **Relationship** | An AMI *references* one or more snapshots | A snapshot can *be part of* an AMI |

When you create an AMI from an instance, AWS automatically creates an EBS snapshot of each volume attached to that instance and bundles them into the AMI definition. The AMI is the launch template; the snapshots are the underlying data.

### No-Reboot vs Reboot Behavior

When creating an AMI, you have a choice:

| Option | Behavior | Data Consistency |
|--------|----------|-----------------|
| **Default (reboot)** | AWS reboots the instance, flushes OS buffers to disk, takes the snapshot, then restarts | Guaranteed filesystem consistency |
| **No-reboot** | Instance stays running, snapshot is taken without flushing OS buffers | May miss in-flight writes — application-consistent, not crash-consistent |

For most use cases, the **no-reboot** option is preferred in production because it avoids downtime — but you accept that any data buffered in OS memory at snapshot time may not be captured. For databases, you'd want to quiesce writes or take the snapshot with the DB in a consistent state (e.g., flush + lock tables).

### AMI States

| State | Meaning |
|-------|---------|
| `pending` | AMI creation in progress — underlying snapshots being created |
| `available` | AMI is ready to launch instances from |
| `failed` | Creation failed — check CloudTrail for the reason |
| `deregistered` | AMI has been deregistered (deleted) — snapshots may still exist |

AMI creation takes time proportional to the volume size and the amount of data. A fresh 8 GiB root volume with a standard Amazon Linux install typically takes 2–5 minutes. A 500 GiB heavily-used volume can take 15–30+ minutes.

### AMIs Are Region-Specific

Like EBS snapshots, AMIs are regional. An AMI created in `us-east-1` cannot be used to launch instances in `ap-south-1` without first **copying** it to the target region. The copy process replicates the underlying snapshots and creates a new AMI registration in the destination region.

### The AMI Lifecycle: Create → Launch → Deregister

```
EC2 Instance
    │
    ▼  create-image
   AMI (available)  ──────────────→  Launch new EC2 instances
    │                                  (as many as needed)
    ▼  deregister-image
   AMI (deregistered)
    │
    ▼  delete-snapshot
   Snapshots deleted (separately)
```

Deregistering an AMI does **not** automatically delete the underlying snapshots. You must explicitly delete them after deregistering to stop incurring snapshot storage charges.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Navigate to **EC2 → Instances**
2. Select `nautilus-ec2`
3. **Actions → Image and templates → Create image**
4. Fill in:
   - **Image name:** `nautilus-ec2-ami`
   - **Image description:** *(optional but recommended)*
   - **No reboot:** Leave unchecked for consistency *(or check if you want no downtime)*
   - **Instance volumes:** Review the block device mappings — adjust sizes if needed
5. Click **Create image**
6. Navigate to **EC2 → Images → AMIs**
7. Find `nautilus-ec2-ami` — watch the **Status** column
8. Wait until **Status: Available** ✅

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

# Confirm instance state
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1 \
    --query "Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone}" \
    --output table

# ============================================================
# Step 2: Create the AMI
# ============================================================
AMI_ID=$(aws ec2 create-image \
    --instance-id "$INSTANCE_ID" \
    --name "nautilus-ec2-ami" \
    --description "AMI created from nautilus-ec2 for migration" \
    --region us-east-1 \
    --no-reboot \
    --tag-specifications 'ResourceType=image,Tags=[{Key=Name,Value=nautilus-ec2-ami},{Key=Source,Value=nautilus-ec2}]' \
    --query "ImageId" \
    --output text)

echo "AMI creation initiated — AMI ID: $AMI_ID"

# ============================================================
# Step 3: Wait for AMI to reach 'available' state
# ============================================================
echo "Waiting for AMI to become available (this may take several minutes)..."

aws ec2 wait image-available \
    --image-ids "$AMI_ID" \
    --region us-east-1

echo "AMI is now available"

# ============================================================
# Step 4: Verify AMI details
# ============================================================
aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --region us-east-1 \
    --query "Images[0].{ID:ImageId,Name:Name,State:State,Created:CreationDate,RootDevice:RootDeviceType,Arch:Architecture,VirtType:VirtualizationType}" \
    --output table

# Also show the underlying snapshots
aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --region us-east-1 \
    --query "Images[0].BlockDeviceMappings[*].{Device:DeviceName,SnapshotId:Ebs.SnapshotId,Size:Ebs.VolumeSize,Type:Ebs.VolumeType}" \
    --output table
```

---

### Launching a New Instance from the AMI

```bash
# Get default SG and subnet
DEFAULT_SG=$(aws ec2 describe-security-groups --region us-east-1 \
    --filters "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text)

DEFAULT_SUBNET=$(aws ec2 describe-subnets --region us-east-1 \
    --filters "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" --output text)

# Launch from the AMI
aws ec2 run-instances \
    --region us-east-1 \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --key-name your-key-pair \
    --security-group-ids "$DEFAULT_SG" \
    --subnet-id "$DEFAULT_SUBNET" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=nautilus-ec2-clone}]' \
    --count 1
```

---

### Copying an AMI to Another Region

```bash
# Copy AMI from us-east-1 to ap-south-1
aws ec2 copy-image \
    --source-region us-east-1 \
    --source-image-id "$AMI_ID" \
    --region ap-south-1 \
    --name "nautilus-ec2-ami" \
    --description "Copied from us-east-1 for DR"
```

---

### Deregistering an AMI and Cleaning Up Snapshots

```bash
# Step 1: Get the snapshot IDs before deregistering
SNAPSHOT_IDS=$(aws ec2 describe-images \
    --image-ids "$AMI_ID" --region us-east-1 \
    --query "Images[0].BlockDeviceMappings[*].Ebs.SnapshotId" \
    --output text)

echo "Associated snapshots: $SNAPSHOT_IDS"

# Step 2: Deregister the AMI
aws ec2 deregister-image \
    --image-id "$AMI_ID" \
    --region us-east-1

echo "AMI deregistered"

# Step 3: Delete the underlying snapshots (separately)
for SNAP in $SNAPSHOT_IDS; do
    echo "Deleting snapshot: $SNAP"
    aws ec2 delete-snapshot --snapshot-id "$SNAP" --region us-east-1
done

echo "Cleanup complete"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- RESOLVE INSTANCE ID ---
INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=nautilus-ec2" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

# --- CREATE AMI ---
AMI_ID=$(aws ec2 create-image \
    --instance-id "$INSTANCE_ID" \
    --name "nautilus-ec2-ami" \
    --description "AMI from nautilus-ec2" \
    --region "$REGION" \
    --no-reboot \
    --tag-specifications 'ResourceType=image,Tags=[{Key=Name,Value=nautilus-ec2-ami}]' \
    --query "ImageId" --output text)

echo "AMI ID: $AMI_ID"

# --- WAIT FOR AVAILABLE ---
aws ec2 wait image-available --image-ids "$AMI_ID" --region "$REGION"

# --- VERIFY ---
aws ec2 describe-images --image-ids "$AMI_ID" --region "$REGION" \
    --query "Images[0].{ID:ImageId,Name:Name,State:State,Created:CreationDate}" \
    --output table

# --- LIST ALL AMIS OWNED BY ME ---
aws ec2 describe-images --region "$REGION" --owners self \
    --query "Images[*].{ID:ImageId,Name:Name,State:State,Created:CreationDate}" \
    --output table

# --- LAUNCH FROM AMI ---
aws ec2 run-instances --region "$REGION" --image-id "$AMI_ID" \
    --instance-type t2.micro --count 1 \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=from-ami}]'

# --- COPY TO ANOTHER REGION ---
aws ec2 copy-image --source-region "$REGION" \
    --source-image-id "$AMI_ID" --region ap-south-1 --name "nautilus-ec2-ami"

# --- DEREGISTER + CLEANUP ---
SNAPS=$(aws ec2 describe-images --image-ids "$AMI_ID" --region "$REGION" \
    --query "Images[0].BlockDeviceMappings[*].Ebs.SnapshotId" --output text)
aws ec2 deregister-image --image-id "$AMI_ID" --region "$REGION"
for SNAP in $SNAPS; do aws ec2 delete-snapshot --snapshot-id "$SNAP" --region "$REGION"; done
```

---

## ⚠️ Common Mistakes

**1. Not waiting for `available` state before trying to launch**
Immediately after `create-image` returns an AMI ID, the AMI is in `pending` state — the underlying snapshots are still being created. Trying to launch an instance from it at this point will fail with `InvalidAMIID.NotFound` or `InvalidAMIState`. Always use `aws ec2 wait image-available` or poll the state before attempting to use the AMI.

**2. Deregistering an AMI without saving the snapshot IDs first**
Once an AMI is deregistered, you can no longer look up its associated snapshots through the AMI API. Describe the snapshots from the AMI's block device mappings *before* deregistering, or the snapshots become orphaned — they'll still exist and still accrue charges, but are harder to identify and clean up.

**3. Assuming the AMI includes all attached EBS volumes**
By default, `create-image` includes all EBS volumes attached to the instance at the time of creation, using the block device mappings from the instance. If you have a large data volume and only want to snapshot the root OS volume, you can customise the `--block-device-mappings` parameter to exclude specific volumes, or set `NoDevice` to suppress a volume from being included.

**4. Not tagging AMIs and their snapshots**
AMIs and their underlying snapshots are separate resources. Tagging the AMI doesn't tag its snapshots. In a large account with many AMIs, untagged snapshots become orphaned debris over time — you can't tell which AMI they belong to after the AMI is deregistered. Use `--tag-specifications` for both `ResourceType=image` and `ResourceType=snapshot` in the same `create-image` call.

**5. Using AMI names as unique identifiers**
AMI names are unique within an account and region, but they're not immutable. When automation creates AMIs by name (e.g., as part of a CI/CD pipeline), name collisions fail at creation time. The AMI ID is the stable unique identifier — always track and reference AMIs by ID in automation, not by name.

**6. Forgetting that AMIs are region-specific when building multi-region deployments**
A pipeline that creates an AMI in `us-east-1` and then tries to launch instances in `eu-west-1` using that AMI ID will fail. Multi-region deployment pipelines must include an explicit AMI copy step to each target region, and the resulting region-specific AMI IDs must be tracked per region.

---

## 🌍 Real-World Context

AMI creation is the foundation of two critical production practices: **golden AMI pipelines** and **disaster recovery playbooks**.

**Golden AMI Pipeline:**
Instead of launching base OS instances and configuring them at boot time via user data, production teams build "golden AMIs" — pre-baked images containing the OS hardening baseline, monitoring agents, log shippers, application runtimes, and security patches. The pipeline looks like:
1. Launch a base Amazon Linux 2023 instance
2. Run Ansible or AWS Systems Manager to apply the configuration
3. Create an AMI from the configured instance
4. Run security scanning (Inspector, Trivy, etc.) against the AMI
5. If it passes, tag it as `approved` and push the AMI ID to Parameter Store
6. All Auto Scaling Groups pull the latest approved AMI ID from Parameter Store

This means every new instance that launches is already fully configured — no boot-time config delay, no partial configuration failures, consistent across all environments.

**Disaster Recovery:**
For stateful workloads, scheduled AMI creation is a DR strategy. AWS Data Lifecycle Manager (DLM) can be configured to create AMIs on a schedule (daily, weekly), retain a rolling window of them, and optionally copy them to a secondary region. If the primary region has an issue, you launch from the copied AMI in the secondary region.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What's the difference between an AMI and an EBS snapshot? How do they relate to each other?**

> An EBS snapshot is a point-in-time backup of a single EBS volume stored in S3 — it captures raw block data. An AMI is a launch template for EC2 instances — it contains one or more snapshot references (one per volume attached to the source instance), plus metadata like architecture, virtualization type, block device mappings, and launch permissions. When you create an AMI from an instance, AWS automatically creates snapshots of all attached EBS volumes and registers them as part of the AMI definition. The AMI is the template; the snapshots are the underlying data it references. You can create a snapshot without an AMI, but every AMI is backed by one or more snapshots.

---

**Q2. What's the difference between creating an AMI with and without the `--no-reboot` flag?**

> Without `--no-reboot` (the default), AWS reboots the instance before taking the snapshot. This ensures the OS has flushed all in-memory buffers to disk — the result is a crash-consistent image, meaning the snapshot exactly matches what's on disk. With `--no-reboot`, the instance keeps running throughout the AMI creation. This avoids downtime but means any data buffered in OS memory that hasn't been written to disk yet may not appear in the snapshot. For most workloads this is acceptable — the OS filesystem journals protect against inconsistency on next mount. For databases with active write operations, you'd want to quiesce writes or use a database-native snapshot mechanism (like RDS automated snapshots, or `mysqldump`/`pg_dump`) rather than relying on a volume-level snapshot of an active database.

---

**Q3. You create an AMI from an instance and then deregister it. Are the EBS snapshots deleted automatically?**

> No — deregistering an AMI only removes the AMI's registration metadata. The underlying EBS snapshots continue to exist and continue to accrue storage charges. To fully clean up, you must: first note all snapshot IDs from the AMI's block device mappings (before deregistering, because you lose that association afterward), deregister the AMI, then explicitly delete each snapshot. In production, this is why AMI lifecycle management tools like AWS DLM with AMI policies (not just volume snapshot policies) are important — they handle the coordinated deregistration + snapshot deletion together on a schedule.

---

**Q4. How would you build a golden AMI pipeline and what tools would you use?**

> A typical pipeline: start with a base AMI trigger (either a new Amazon Linux 2023 release or a scheduled weekly build). Use **EC2 Image Builder** (AWS-native) or **HashiCorp Packer** to launch an instance from the base AMI, run a configuration playbook (Ansible or SSM documents), validate the image (run tests, security scans with **Amazon Inspector** or **Trivy**), then snapshot it into a new AMI. Tag the resulting AMI with version, build date, and approval status. Push the approved AMI ID to **SSM Parameter Store** at a stable path like `/ami/golden/al2023/latest`. Auto Scaling Groups and Launch Templates reference that SSM parameter, so they always pull the latest approved image. Automate this in a CI/CD pipeline (CodePipeline or GitHub Actions) so every AMI goes through the same review gate before reaching production.

---

**Q5. An EC2 instance in `us-east-1` needs to be replicated to `ap-south-1` for disaster recovery. Walk me through it using AMIs.**

> Create an AMI from the source instance in `us-east-1` and wait for it to reach `available` state. Then use `aws ec2 copy-image --source-region us-east-1 --source-image-id ami-xxx --region ap-south-1`. This copies the underlying snapshots to `ap-south-1` and registers a new AMI there. Wait for the copied AMI to reach `available` in `ap-south-1`. Store the AMI ID for `ap-south-1` in a location your DR runbook can reference (SSM Parameter Store, a configuration file, or directly in a Terraform variable). For automated DR, this copy step runs on a schedule — daily or weekly — and the DLM AMI policy handles the lifecycle including copy, retention, and cleanup.

---

**Q6. You have 50 EC2 instances that need to be migrated to a new instance type. How would you use AMIs to do this with minimal risk?**

> Create AMIs from each running instance before touching anything — these are your rollback snapshots. Then, for each instance: create an AMI, launch a new instance of the target type from that AMI, validate the new instance (health checks, application smoke test), then terminate the old instance. If validation fails, the AMI is your rollback — you can relaunch the original configuration immediately without any data loss. For stateless instances behind a load balancer, you can do this as a rolling replacement: create AMIs in batch, update the Launch Template with the new instance type, trigger an ASG Instance Refresh, and the rollback path is to revert the Launch Template. The individual AMI-per-instance approach is for stateful workloads where you need per-instance rollback capability.

---

**Q7. AMI creation is taking much longer than expected. What factors affect AMI creation time and how do you monitor progress?**

> AMI creation time is primarily driven by the size and data density of the volumes being snapshotted. An 8 GiB root volume with a fresh OS install creates quickly (2–5 minutes). A 1 TB volume with lots of data can take 30–60+ minutes. Two other factors: snapshot throughput is shared across AWS's infrastructure and can vary, and incremental snapshots (if a previous snapshot exists for the volume) are faster because only changed blocks are copied. To monitor progress: poll `describe-images` and watch the `State` field change from `pending` to `available`, or watch the associated snapshot's `Progress` field via `describe-snapshots --filters "Name=tag:...,Values=..."`. In CloudTrail, the `CreateImage` event fires at the start and `CreateSnapshot` events fire for each volume. There's no real acceleration option — you can't speed up the snapshot process. Plan AMI creation windows accordingly in maintenance schedules.

---

## 📚 Resources

- [AWS Docs — Create an AMI from an EC2 Instance](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/creating-an-ami-ebs.html)
- [AWS CLI Reference — create-image](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-image.html)
- [AWS EC2 Image Builder](https://docs.aws.amazon.com/imagebuilder/latest/userguide/what-is-image-builder.html)
- [AWS DLM — AMI Lifecycle Policies](https://docs.aws.amazon.com/ebs/latest/userguide/ami-policy.html)
- [Copying an AMI to Another Region](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/CopyingAMIs.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
