# Day 14 — Terminating an EC2 Instance

> **#100DaysOfCloud | Day 14 of 100**

---

## 📌 The Task

> *An EC2 instance named `devops-ec2` in `us-east-1` is no longer needed. Terminate it and confirm the instance reaches `terminated` state.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Instance name | `devops-ec2` |
| Action | Terminate (permanent deletion) |
| Required final state | `terminated` |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### Stop vs Terminate — The Fundamental Distinction

This is the most important concept in EC2 lifecycle management and the one that causes the most irreversible mistakes:

| | Stop | Terminate |
|--|------|-----------|
| **What happens** | Instance powers off | Instance is permanently destroyed |
| **EBS root volume** | Preserved | Deleted by default (DeleteOnTermination=true) |
| **EBS data volumes** | Preserved (remain attached) | Preserved by default (DeleteOnTermination=false) |
| **Instance store** | Data wiped on stop | Data wiped on terminate |
| **Public IP** | Released | Released |
| **Private IP** | Preserved in VPC | Released |
| **Elastic IP** | Disassociated (EIP still in account) | Disassociated (EIP still in account, billed if not released) |
| **Instance ID** | Same on restart | Gone — new instance = new ID |
| **Reversible?** | ✅ Yes — can start again | ❌ No — permanent |
| **Billing** | Stops (EBS storage still billed) | Stops (for compute) |

**Terminate is permanent. There is no undo.**

### What Happens During Termination

When you terminate an instance, AWS:

1. Sends an ACPI shutdown signal to the OS (graceful shutdown attempt)
2. The OS has a configurable shutdown period (typically 120 seconds) to cleanly stop processes
3. After the shutdown period, the hypervisor forces the VM off
4. EBS volumes with `DeleteOnTermination=true` are scheduled for deletion
5. The instance transitions through: `running` → `shutting-down` → `terminated`
6. The instance record remains visible in the console for about **1 hour** after termination (for reference and billing reconciliation), then disappears

### The `terminated` State

`terminated` is a terminal state — the instance will never transition out of it. Once terminated:
- The instance ID becomes permanently invalid for API operations
- You cannot start, stop, or modify a terminated instance
- It remains visible in `describe-instances` responses for ~1 hour with the `terminated` state
- After ~1 hour, it stops appearing in default `describe-instances` output (you'd need to explicitly filter by `terminated` state to see it)

### Termination Protection — The Safety Gate

Instances can have `DisableApiTermination` enabled (as covered on Day 9). If it's set to `true`, calling `terminate-instances` returns `OperationNotPermitted`. You must disable the protection first:

```bash
# Check if termination protection is enabled
aws ec2 describe-instance-attribute \
    --instance-id <INSTANCE_ID> \
    --attribute disableApiTermination

# Disable protection if needed
aws ec2 modify-instance-attribute \
    --instance-id <INSTANCE_ID> \
    --no-disable-api-termination

# Then terminate
aws ec2 terminate-instances --instance-ids <INSTANCE_ID>
```

### Delete on Termination — What Storage Survives

Every EBS volume attached to an instance has a `DeleteOnTermination` flag:

| Volume Type | Default DeleteOnTermination |
|-------------|---------------------------|
| Root volume (`/dev/sda1`) | `true` — deleted when instance terminates |
| Additional data volumes | `false` — survive termination as unattached volumes |

This is why you should always check what volumes are attached before terminating — especially if there's data on secondary volumes you haven't backed up.

### Pre-Termination Checklist

Before terminating any instance, a responsible DevOps engineer runs through:

1. ✅ **Check for termination protection** — will the API call even succeed?
2. ✅ **Check attached volumes** — any data volumes that need backup before deletion?
3. ✅ **Check for Elastic IPs** — any EIPs associated that will remain allocated and billing after termination?
4. ✅ **Check for snapshots or AMIs** — do you need a final backup?
5. ✅ **Confirm the correct instance** — verify by ID, not just name (names are not unique)
6. ✅ **Check for dependencies** — is anything routing traffic to this instance (load balancer, Route 53, etc.)?

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Navigate to **EC2 → Instances**
[O2. Locate `devops-ec2` — note the **Instance ID**, **Instance state**, and **Instance type** to confirm correct instance
3. Check **Storage** tab → note any attached volumes and their Delete on Termination setting
4. Select `devops-ec2` → **Instance state → Terminate instance**
5. In the confirmation dialog → click **Terminate**
6. Watch the **Instance state** column transition: `Running` → `Shutting-down` → `Terminated`

**Verify:**
- State column shows `Terminated` with a red dot
- The instance disappears from default views after ~1 hour

---

### Method 2 — AWS CLI

```bash
# ============================================================
# Step 1: Resolve and confirm the correct instance
# ============================================================
[IINSTANCE_ID=$(aws ec2 describe-instances \
    --region us-east-1 \
    --filters \
        "Name=tag:Name,Values=devops-ec2" \
        "Name=instance-state-name,Values=running,stopped,pending" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Instance ID: $INSTANCE_ID"

# Confirm full details before doing anything destructive
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1 \
    --query "Reservations[0].Instances[0].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value,State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,PublicIP:PublicIpAddress}" \
    --output table

# ============================================================
# Step 2: Pre-termination checks
# ============================================================

# Check termination protection
echo "=== Termination Protection ==="
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiTermination \
    --region us-east-1
# Value: false = can terminate | true = must disable first

# Check attached volumes and DeleteOnTermination flags
echo "=== Attached Volumes ==="
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1 \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[*].{Device:DeviceName,VolumeId:Ebs.VolumeId,DeleteOnTermination:Ebs.DeleteOnTermination}" \
    --output table

# Check for associated Elastic IPs
echo "=== Associated Elastic IPs ==="
aws ec2 describe-addresses \
    --region us-east-1 \
    --filters "Name=instance-id,Values=${INSTANCE_ID}" \
    --query "Addresses[*].{IP:PublicIp,AllocationId:AllocationId,AssociationId:AssociationId}" \
    --output table

# ============================================================
# Step 3: Disable termination protection if enabled (only if needed)
# ============================================================
# aws ec2 modify-instance-attribute \
#     --instance-id "$INSTANCE_ID" \
#     --region us-east-1 \
#     --no-disable-api-termination

# ============================================================
# Step 4: Terminate the instance
# ============================================================
echo "Terminating instance $INSTANCE_ID..."

aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1

echo "Termination initiated — waiting for terminated state..."

# ============================================================
# Step 5: Wait for terminated state
# ============================================================
aws ec2 wait instance-terminated \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1

echo "Instance $INSTANCE_ID is now terminated"

# ============================================================
# Step 6: Verify terminated state
# ============================================================
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1 \
    --query "Reservations[0].Instances[0].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value,State:State.Name,TerminationTime:StateTransitionReason}" \
    --output table

# ============================================================
# Step 7: Check if any EIPs need to be released
# ============================================================
echo "=== Unassociated EIPs after termination (check for billing) ==="
aws ec2 describe-addresses \
    --region us-east-1 \
    --query "Addresses[?AssociationId==null].{IP:PublicIp,AllocationId:AllocationId}" \
    --output table
```

---

### Bulk Termination — Terminate Multiple Instances at Once

```bash
# Terminate multiple instances by ID in one API call
aws ec2 terminate-instances \
    --instance-ids i-0abc1234 i-0def5678 i-0ghi9012 \
    --region us-east-1

# Terminate all instances with a specific tag (USE WITH EXTREME CAUTION)
# Always do a dry-run first to see what would be affected
INSTANCE_IDS=$(aws ec2 describe-instances \
    --region us-east-1 \
    --filters \
        "Name=tag:Environment,Values=dev" \
        "Name=instance-state-name,Values=running,stopped" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text)

echo "Instances that WOULD be terminated: $INSTANCE_IDS"

# Confirm manually, then:
# aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region us-east-1
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- RESOLVE INSTANCE ID ---
INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=devops-ec2" \
               "Name=instance-state-name,Values=running,stopped,pending" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

# --- PRE-CHECKS ---
# Termination protection
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" --attribute disableApiTermination --region "$REGION"

# Volumes + DeleteOnTermination flags
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].BlockDeviceMappings[*].{Device:DeviceName,VolumeId:Ebs.VolumeId,DeleteOnTermination:Ebs.DeleteOnTermination}" \
    --output table

# Associated EIPs
aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=instance-id,Values=${INSTANCE_ID}" \
    --query "Addresses[*].{IP:PublicIp,AllocationId:AllocationId}" --output table

# --- DISABLE PROTECTION (if needed) ---
# aws ec2 modify-instance-attribute \
#     --instance-id "$INSTANCE_ID" --region "$REGION" --no-disable-api-termination

# --- TERMINATE ---
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"

# --- WAIT FOR TERMINATED STATE ---
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"

# --- VERIFY ---
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].{ID:InstanceId,State:State.Name}" --output table

# --- RELEASE ORPHANED EIPs (if any) ---
# aws ec2 release-address --allocation-id <ALLOC_ID> --region "$REGION"
```

---

## ⚠️ Common Mistakes

**1. Terminating the wrong instance because you filtered by name without verifying**
Instance names are tags — they're not unique identifiers. If multiple instances share the name `devops-ec2`, your filter will return one of them (the first in the response). **Always verify the Instance ID** before running a terminate command. Print the full instance details and confirm the correct one before proceeding.

**2. Not checking `DeleteOnTermination` on data volumes**
The root volume is deleted by default. Secondary data volumes are preserved by default — but if someone previously changed `DeleteOnTermination=true` on a data volume, it will be silently deleted when the instance terminates. Always check `BlockDeviceMappings` and their `Ebs.DeleteOnTermination` flags before terminating any instance with non-root volumes.

**3. Leaving an Elastic IP allocated after the instance is terminated**
Termination disassociates any EIP from the instance but does not release it. The EIP continues to sit in your account, unassociated, accruing charges. Always check for associated EIPs before termination and release any you no longer need after the instance is gone.

**4. Not waiting for `terminated` before reporting completion**
The API call to terminate returns immediately with the state changing to `shutting-down`. The instance isn't `terminated` until the shutdown process completes. The task specifically requires `terminated` state — always use `aws ec2 wait instance-terminated` to confirm.

**5. Confusing `terminated` with `stopped` when checking**
`describe-instances` by default filters out terminated instances. If you're checking state and see nothing, the instance might be terminated (not a filter issue, not an error). Add `--filters "Name=instance-state-name,Values=terminated"` to explicitly include terminated instances in results.

**6. Terminating without checking for load balancer or Route 53 dependencies**
A terminating instance may still be registered with an ALB target group or pointed to by a Route 53 record. Terminating without deregistering first means the load balancer will route traffic to a dead target (causing 502s) until health checks time out and deregister it automatically. The clean approach is to deregister from the target group first, wait for connections to drain, then terminate.

---

## 🌍 Real-World Context

Instance termination sounds like the simplest operation in AWS, but in production it's one that requires the most deliberate process. A few patterns worth knowing:

**Termination in Auto Scaling Groups**: When an ASG scales in, it terminates instances automatically based on termination policies (oldest instance, newest instance, closest to billing hour, etc.). Termination protection on an ASG instance blocks this — the ASG will skip that instance and try another. If all instances are protected, the scale-in gets stuck.

**Drain before terminate for stateful services**: For instances registered with a load balancer, the clean sequence is: deregister from target group → wait for connection draining (default 300 seconds) → terminate. This prevents in-flight requests from being dropped mid-connection.

**Spot Instance termination**: Spot Instances can be interrupted by AWS with a 2-minute warning. The instance receives a termination notice via the instance metadata endpoint and an EventBridge event. Applications running on Spot should handle this gracefully — checkpoint state, flush writes, deregister from load balancers — within that 2-minute window.

**Post-termination cleanup checklist**: After terminating, always check: unassociated EIPs (cost), orphaned EBS volumes with `DeleteOnTermination=false` (cost + data), Route 53 records pointing at the old IP (broken DNS), load balancer target groups still referencing the instance ID (stale registrations), and CloudWatch alarms with the instance ID as a dimension (will alarm on missing data).

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is the difference between stopping and terminating an EC2 instance?**

> Stopping powers the instance off gracefully — the EBS root volume is preserved, the instance ID is retained, you can restart it later, and you only pay for storage while stopped. Termination is permanent destruction — the instance is gone, the root EBS volume is deleted by default, the instance ID is invalidated, and there is no recovery unless you have a snapshot or AMI taken beforehand. Additional data volumes survive termination by default (their `DeleteOnTermination` flag defaults to `false`). In production, terminate is reserved for instances that are genuinely decommissioned — temporary work, migrations where the replacement is confirmed healthy, Auto Scaling scale-in events, and cleanup of obsolete infrastructure.

---

**Q2. You run `terminate-instances` and get `OperationNotPermitted`. What does that mean and what do you do?**

> Termination protection (`DisableApiTermination`) is enabled on the instance. AWS explicitly blocks the API call to prevent accidental termination. Before proceeding, confirm this is the right instance to terminate (verify by ID, check with the team who owns it). If you're certain, disable the protection:
> ```bash
> aws ec2 modify-instance-attribute \
>     --instance-id $ID --no-disable-api-termination
> aws ec2 terminate-instances --instance-ids $ID
> ```
> The requirement to actively disable protection before terminating is a deliberate two-step — it ensures no accidental termination bypasses the safeguard, and every disable event is logged in CloudTrail with who did it and when.

---

**Q3. After terminating an EC2 instance, you notice an Elastic IP is still showing up in your account. What happened and what do you do?**

> Termination automatically **disassociates** the EIP from the instance but does **not release** it back to AWS. The EIP remains allocated to your account and billing continues at the unattached rate (~$0.005/hr). To stop the charges, release it:
> ```bash
> aws ec2 release-address --allocation-id eipalloc-xxxxxxxx
> ```
> This is a very common source of quiet cost drift — teams terminate instances, assume the EIP is "gone," and never notice the per-hour charge accumulating. Build a periodic audit into your cost hygiene process: `aws ec2 describe-addresses --query "Addresses[?AssociationId==null]"` lists all unattached EIPs across your account.

---

**Q4. You need to terminate 200 EC2 instances that are tagged `Environment=dev` at the end of a sprint. How do you do this safely?**

> Never run a mass terminate directly. The safe sequence: first, list all instances that match the filter and review the output — confirm the count is right and no unexpected instances are in the list. Second, check for instances with termination protection enabled (you'll need to handle those separately). Third, check for any EIPs or important volumes attached. If everything looks right, terminate in batches:
> ```bash
> # List first — always
> aws ec2 describe-instances --region us-east-1 \
>     --filters "Name=tag:Environment,Values=dev" \
>               "Name=instance-state-name,Values=running,stopped" \
>     --query "Reservations[*].Instances[*].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value}" \
>     --output table
>
> # Then terminate in one call (AWS API handles batching)
> aws ec2 terminate-instances --instance-ids $(aws ec2 describe-instances ...) --region us-east-1
> ```
> After terminating, audit for orphaned EIPs, volumes, and load balancer registrations.

---

**Q5. How long does a terminated EC2 instance remain visible in the AWS console and API?**
[O
> A terminated instance remains visible in the EC2 console and in `describe-instances` responses for approximately **1 hour** after termination. After that, it disappears from default listings (which filter on active states). If you need to find it within that window, it's still there with `State.Name = terminated`. After the ~1 hour cleanup period, you can no longer query it by instance ID — the record is gone from the API. This is why you should note the instance ID, termination time, and any relevant details in your incident or change ticket before terminating, rather than trying to look them up afterward.

---

**Q6. An EC2 instance is registered with an Application Load Balancer target group. What's the correct sequence to terminate it without causing errors for end users?**

> The correct sequence: first, deregister the instance from the ALB target group — `aws elbv2 deregister-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID`. The ALB immediately stops sending new connections to that target but keeps existing connections alive through the **deregistration delay** (default 300 seconds, configurable down to 0). Wait for the deregistration delay to expire (or monitor until the target shows `unused` state in the target group). Then terminate the instance — at this point no traffic is flowing to it. This avoids the 504/502 errors that users would see if you terminated the instance while the ALB was still routing to it.

---

**Q7. What is a Spot Instance interruption and how should applications handle it?**

> AWS can reclaim Spot Instances with a **2-minute interruption notice** when it needs capacity back. The instance receives a termination signal via the instance metadata endpoint at `http://169.254.169.254/latest/meta-data/spot/instance-action` and an EventBridge event fires simultaneously. Applications running on Spot should be designed to handle this gracefully within that 2-minute window: checkpoint progress to S3 or DynamoDB, flush any buffered writes to durable storage, deregister from load balancers, and exit cleanly. For batch workloads, frameworks like AWS Batch and EMR handle Spot interruptions natively by checkpointing and retrying failed tasks. For long-running services, Spot is typically mixed with On-Demand in an ASG (`mixed instances policy`) so that an interruption doesn't take the whole fleet down — the On-Demand instances maintain minimum capacity while Spot provides cost-optimized burst capacity.

---

## 📚 Resources

- [AWS Docs — Terminate an EC2 Instance](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/terminating-instances.html)
- [AWS CLI Reference — terminate-instances](https://docs.aws.amazon.com/cli/latest/reference/ec2/terminate-instances.html)
- [EC2 Instance Lifecycle](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-lifecycle.html)
- [Spot Instance Interruption Notices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html)
- [ELB Deregistration Delay](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-target-groups.html#deregistration-delay)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
