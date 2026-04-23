# Day 07 — Changing an EC2 Instance Type

> **#100DaysOfCloud | Day 7 of 100**

---

## 📌 The Task

> *The Nautilus DevOps team discovered that the `nautilus-ec2` instance was underutilized. To optimize resource usage and reduce cost, they need to downsize the instance type.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Instance name | `nautilus-ec2` |
| Current type | `t2.micro` |
| Target type | `t2.nano` |
| Region | `us-east-1` |
| Post-change state | `running` |

> ⚠️ Wait for **Status checks** to complete (pass 2/2) before making any changes if the instance is still initializing.

---

## 🧠 Core Concepts

### Why You Can't Resize a Running Instance

Changing an EC2 instance type requires the instance to be in a **stopped** state. This is because an instance type change is not just a software setting — it's a physical reallocation. AWS needs to schedule the instance onto a host with the right hardware characteristics for the new type. The hypervisor, CPU, memory allocation, and network bandwidth are all tied to the underlying host. You stop the instance, AWS migrates it to an appropriate host for the new type, and you start it again.

This is one of the key distinctions between vertical scaling (resizing one instance — requires downtime) and horizontal scaling (adding more instances — no downtime).

### The Resize Workflow

```
Running → Stop → [Wait: stopped] → Modify instance type → Start → [Wait: running] → Verify
```

Every step matters:
- **Don't modify while stopping** — the API call will be rejected if the instance hasn't fully stopped
- **Don't start before the modify completes** — the type won't have changed
- The `aws ec2 wait` commands exist precisely to handle this — they poll until the state transition completes before returning

### Instance Type Compatibility

Not every instance type is available in every Availability Zone, and not every resize is compatible. Key rules:

| Scenario | Compatible? |
|----------|------------|
| `t2.micro` → `t2.nano` | ✅ Same family, same generation |
| `t2.micro` → `t3.micro` | ✅ Cross-generation upgrade, same family |
| `t2.micro` → `c5.large` | ✅ Cross-family (different use case) |
| `t2.micro` → `mac1.metal` | ❌ Dedicated host required |
| Any x86 → Graviton (ARM) | ⚠️ Requires OS/software to be ARM-compatible |

For most standard instance type changes within the `t2`, `t3`, `m5`, `c5` families, compatibility is not an issue.

### t2.micro vs t2.nano — What Actually Changes

| Spec | t2.micro | t2.nano |
|------|----------|---------|
| vCPU | 1 | 1 |
| Memory | 1 GiB | 0.5 GiB |
| Baseline CPU | 10% | 5% |
| CPU Credits/hr | 12 | 3 |
| Network | Low to Moderate | Low |
| Free Tier eligible | Yes | No |

The `t2.nano` is the smallest instance in the t2 family. The primary trade-off is memory (1 GiB → 0.5 GiB) and CPU credit accumulation rate (12/hr → 3/hr). For a genuinely underutilized instance running a lightweight workload, this is a valid cost optimization.

### What Happens to Data During a Resize?

- **EBS root volume**: fully preserved — data, configuration, installed packages, everything
- **Instance store (ephemeral)**: cleared — any data on NVMe/SSD instance store is lost on stop (t2 instances don't have instance store, so not relevant here)
- **Public IP**: changes after stop/start unless an Elastic IP is assigned
- **Private IP**: preserved within the VPC
- **IAM instance profile**: preserved
- **Security groups**: preserved

### Status Checks — What They Mean

EC2 instances have two status checks visible in the console and via the CLI:

| Check | What It Monitors | Failure Means |
|-------|-----------------|---------------|
| **System status check** | The underlying AWS infrastructure (host hardware, power, network) | AWS-side issue — usually auto-recovered or requires stop/start |
| **Instance status check** | The OS inside the instance (kernel panics, corrupt filesystem, misconfigured networking) | Your responsibility — you need to investigate and fix |

Both must show **passed** (2/2) before touching a production instance. Modifying an instance that hasn't passed status checks can mask an underlying problem — you'd resize it and still have a broken instance.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Step 1 — Verify status checks have passed**
1. Navigate to **EC2 → Instances**
2. Select `nautilus-ec2`
3. In the **Status checks** column, wait for **2/2 checks passed**
4. If still initializing, wait — do not proceed until both checks are green

**Step 2 — Stop the instance**
1. Select `nautilus-ec2` → **Instance state → Stop instance**
2. Confirm the stop
3. Wait for **Instance state: Stopped** (the state column turns grey)

**Step 3 — Change the instance type**
1. With the instance still selected → **Actions → Instance settings → Change instance type**
2. Select `t2.nano` from the dropdown
3. Click **Apply**

**Step 4 — Start the instance**
1. **Instance state → Start instance**
2. Wait for **Instance state: Running** and **Status checks: 2/2 checks passed**

**Step 5 — Verify**
1. Select the instance → **Details** tab
2. Confirm **Instance type: t2.nano**
3. Confirm **Instance state: running**

---

### Method 2 — AWS CLI

```bash
# ============================================================
# Step 1: Find the Instance ID for nautilus-ec2
# ============================================================
INSTANCE_ID=$(aws ec2 describe-instances \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=nautilus-ec2" \
               "Name=instance-state-name,Values=running,stopped,pending" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Instance ID: $INSTANCE_ID"

# ============================================================
# Step 2: Check Current State and Status Checks
# ============================================================

# Current instance state
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1 \
    --query "Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,StatusChecks:''}" \
    --output table

# Status check results (wait for 'ok' on both)
aws ec2 describe-instance-status \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1 \
    --query "InstanceStatuses[0].{System:SystemStatus.Status,Instance:InstanceStatus.Status}" \
    --output table

# Wait until both status checks pass before proceeding
aws ec2 wait instance-status-ok \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1

echo "Status checks passed — safe to proceed"

# ============================================================
# Step 3: Stop the Instance
# ============================================================
aws ec2 stop-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1

echo "Stopping instance — waiting for stopped state..."

aws ec2 wait instance-stopped \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1

echo "Instance is stopped"

# ============================================================
# Step 4: Change the Instance Type
# ============================================================
aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region us-east-1 \
    --instance-type '{"Value": "t2.nano"}'

echo "Instance type changed to t2.nano"

# ============================================================
# Step 5: Start the Instance
# ============================================================
aws ec2 start-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1

echo "Starting instance — waiting for running state..."

aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1

echo "Instance is running"

# ============================================================
# Step 6: Verify the Change
# ============================================================
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1 \
    --query "Reservations[0].Instances[0].{ID:InstanceId,Type:InstanceType,State:State.Name,PublicIP:PublicIpAddress}" \
    --output table
```

---

### Verifying the Instance Type Change

```bash
# Confirm type is now t2.nano and state is running
aws ec2 describe-instances \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=nautilus-ec2" \
    --query "Reservations[*].Instances[*].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,Type:InstanceType,State:State.Name}" \
    --output table

# Re-check status checks after restart
aws ec2 describe-instance-status \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- FIND INSTANCE ---
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=nautilus-ec2" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

# --- CHECK STATUS ---
aws ec2 describe-instance-status \
    --instance-ids "$INSTANCE_ID" --region "$REGION"

# --- WAIT FOR STATUS CHECKS TO PASS ---
aws ec2 wait instance-status-ok \
    --instance-ids "$INSTANCE_ID" --region "$REGION"

# --- STOP ---
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"

# --- CHANGE INSTANCE TYPE ---
aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --instance-type '{"Value": "t2.nano"}'

# --- START ---
aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

# --- VERIFY ---
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].{ID:InstanceId,Type:InstanceType,State:State.Name}" \
    --output table
```

---

## ⚠️ Common Mistakes

**1. Trying to modify the instance type while it's still running**
`modify-instance-attribute` will return an `IncorrectInstanceState` error if the instance isn't stopped. The API is explicit about this — there's no graceful degradation. Stop first, wait for the stopped state, then modify.

**2. Not waiting for the stopped state before modifying**
Even after calling `stop-instances`, the instance goes through a `stopping` transition state before reaching `stopped`. If you call `modify-instance-attribute` during `stopping`, it will fail. Always use `aws ec2 wait instance-stopped` to ensure the transition is complete.

**3. Forgetting that the public IP changes after stop/start**
Unless an Elastic IP is assigned, the public IP is released when the instance stops and a new one is assigned when it starts. SSH connections, DNS records, or monitoring agents pointing at the old IP will fail after the resize. Check and update any IP-dependent configuration after the restart.

**4. Not re-checking status checks after restart**
The instance being in `running` state doesn't mean the OS has fully booted and passed health checks. If you immediately SSH in after `instance-running` returns, you might catch the instance mid-boot. Use `aws ec2 wait instance-status-ok` after starting to confirm both system and instance checks have passed.

**5. Downsizing without checking memory usage first**
`t2.micro` → `t2.nano` halves the available memory from 1 GiB to 0.5 GiB. If the workload on the instance is using more than 400–450 MB of RAM at idle (leaving headroom for the OS), the instance will start swapping heavily after the resize or fail to start services. Always check `free -h` or CloudWatch `mem_used_percent` (requires CloudWatch agent) before downsizing.

**6. Confusing instance type change with instance family migration**
Changing between instance families (e.g., `t2` to `m6i`) is perfectly valid, but if the source instance was built on an HVM AMI (standard for all modern AMIs), cross-family changes work without issue. The only complexity is if you're moving to Graviton (ARM) — the AMI and all application binaries must be ARM-compatible.

---

## 🌍 Real-World Context

Instance right-sizing is one of the highest-ROI activities in cloud cost optimization. In most organisations, a significant percentage of EC2 instances are over-provisioned — teams request larger instances than they need "just in case" and never revisit the sizing. AWS Cost Explorer has a **right-sizing recommendations** feature that analyses CloudWatch utilization metrics and suggests cheaper instance types. AWS Compute Optimizer provides even more detailed recommendations using machine learning.

The challenge in production is that right-sizing requires a **maintenance window** — the instance must be stopped. For stateless workloads behind a load balancer, this isn't a problem: you terminate the over-provisioned instance and let the Auto Scaling Group launch a correctly-sized replacement. For stateful workloads (databases, single-instance apps), you need to schedule downtime, notify stakeholders, and have a rollback plan if the smaller instance can't handle the load.

A common pattern for large-scale right-sizing is to use **Launch Templates with instance type overrides** in Auto Scaling Groups — this lets you specify a priority-ordered list of instance types, and the ASG will use whichever is available and most cost-effective at launch time. This shifts the conversation from "resize this specific instance" to "define the acceptable range of instance types for this workload."

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. You need to resize a critical production EC2 instance with zero downtime. How do you approach it?**

> True zero downtime for a vertical resize isn't possible — changing instance type requires a stop. The way to achieve zero-impact resizing in production is through **horizontal architecture**: if the application runs behind a load balancer with multiple instances in an Auto Scaling Group, you can do a rolling replacement. Update the Launch Template with the new instance type, then do an instance refresh — the ASG terminates old instances one at a time and replaces them with new ones, keeping enough capacity in service throughout. No single instance needs to be stopped while traffic is running through it. For a single stateful instance with no redundancy, the honest answer is: you need a maintenance window. That's an architectural problem to fix for the next iteration.

---

**Q2. After resizing an EC2 instance from `t2.micro` to `t2.nano`, the application starts responding slowly under load. What's your first hypothesis and how do you diagnose it?**

> First hypothesis: the instance has run out of CPU credits. `t2.nano` earns only 3 CPU credits per hour (vs 12 for `t2.micro`) and has a 5% CPU baseline (vs 10%). If the application has any sustained CPU activity, the credit balance will drain faster and the CPU will be throttled to 5% of one vCPU — which manifests as slow response times under load. Check the `CPUCreditBalance` CloudWatch metric for the instance. If it's at or near zero and `CPUUtilization` is at 5%, that's the diagnosis. Fix options: enable `t2.unlimited` mode (allows the instance to burst beyond credits and pay for the extra CPU time), or acknowledge the instance was genuinely underutilized in CPU terms but the memory halving (`1 GiB → 0.5 GiB`) is the real issue. Check `mem_used_percent` via CloudWatch agent or `free -h` via SSH.

---

**Q3. What are EC2 instance status checks and what do they tell you?**

> There are two: the **system status check** monitors the underlying AWS infrastructure — the physical host, power, networking to the host. A failure here is AWS's problem and usually resolves automatically (AWS migrates the instance to healthy hardware) or requires a stop/start to get scheduled to a new host. The **instance status check** monitors what's happening inside the instance — can the OS respond to network packets, is the kernel functional, is the filesystem healthy. A failure here is your problem — something inside the OS needs investigation. You'd SSH in, check `dmesg`, look at system logs, check disk health. In practice, an instance status check failure often means an OOM kill took out a critical process, a filesystem filled up, or a bad update broke the boot process.

---

**Q4. What's the difference between `modify-instance-attribute` and the newer `modify-instance-type` API call for changing instance types?**

> For changing the instance type specifically, `modify-instance-attribute` with `--instance-type` is the standard CLI approach and what most documentation shows. AWS also has a dedicated `modify-instance-type` API in some SDK versions. In practice, both achieve the same result — they update the instance type attribute that takes effect on the next start. The key constraint is identical: the instance must be stopped. In Terraform, the same operation is achieved by changing the `instance_type` argument on an `aws_instance` resource — Terraform handles the stop/modify/start cycle automatically when it detects the change.

---

**Q5. An Auto Scaling Group is launching `t2.micro` instances but you want to move to `t3.micro` for better performance. How do you do this without disrupting running instances?**

> Update the **Launch Template** (not directly the ASG) to change the instance type to `t3.micro`. Create a new version of the Launch Template with the new type, then update the ASG to use the new Launch Template version. Existing running instances are unaffected — they continue running on `t2.micro`. New instances launched by scale-out events or replacements will use `t3.micro`. To replace the existing `t2.micro` instances with `t3.micro`, trigger an **Instance Refresh** on the ASG — this does a controlled rolling replacement with configurable minimum healthy percentage and warm-up time, ensuring the fleet migrates with no traffic impact.

---

**Q6. When would you choose `t2.nano` over `t2.micro`, and what are the real-world use cases for such small instances?**

> `t2.nano` makes sense for workloads with extremely low, sporadic resource requirements: a lightweight cron-based job runner, a personal DNS resolver, a VPN gateway handling minimal traffic, a monitoring sidecar, a small NAT instance, or a bastion/jump host that's accessed occasionally. The 0.5 GiB memory is the constraint that eliminates it from most application workloads — many standard web server stacks (nginx + a small app + OS) comfortably exceed 500 MB at idle. Where `t2.nano` genuinely shines is infrastructure tooling that runs briefly, exits, and sits idle most of the time. At scale, running hundreds of these at $0.006/hour vs $0.012/hour (`t2.micro`) does add up to meaningful monthly savings.

---

**Q7. How does AWS Cost Explorer's right-sizing feature work, and what are its limitations?**

> Cost Explorer's right-sizing recommendations analyse **CloudWatch CPU utilization** over the past 14 days and suggest cheaper instance types that would still comfortably handle the observed load. It compares the recommended instance against your current one and shows the projected monthly savings. The limitations are significant in practice: it only looks at CPU — it doesn't consider memory, network throughput, or IOPS, which means it can recommend a downsize that looks fine on CPU but causes OOM issues because memory wasn't factored in. It also requires the CloudWatch agent to be installed for memory metrics, which most basic deployments don't have. **AWS Compute Optimizer** is the more sophisticated alternative — it uses machine learning across CPU, memory, network, and disk metrics and requires the CloudWatch agent for full accuracy. For serious right-sizing work, Compute Optimizer with the CloudWatch agent deployed is the right tool.

---

## 📚 Resources

- [AWS Docs — Change the Instance Type](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-resize.html)
- [AWS CLI Reference — modify-instance-attribute](https://docs.aws.amazon.com/cli/latest/reference/ec2/modify-instance-attribute.html)
- [AWS Compute Optimizer](https://docs.aws.amazon.com/compute-optimizer/latest/ug/what-is-compute-optimizer.html)
- [EC2 Instance Status Checks](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/monitoring-system-instance-status-check.html)
- [T2 Unlimited Mode](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances-unlimited-mode.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
