# Day 21 — Launch EC2 Instance and Associate an Elastic IP

> **#100DaysOfCloud | Day 21 of 100**

---

## 📌 The Task

> *The Development Team needs an EC2 instance with a stable, consistent public IP address for hosting a new application. An Elastic IP ensures the IP never changes across stop/start cycles.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Instance name | `xfusion-ec2` |
| AMI | Any Linux AMI (Ubuntu) |
| Instance type | `t2.micro` |
| Elastic IP name | `xfusion-eip` |
| Action | Create instance + allocate EIP + associate EIP |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### Why This Task Combines Two Previous Days

This task is a **compound operation** — it brings together Day 6 (launch EC2), Day 10 (Elastic IP), and adds a new wrinkle: doing them in the right sequence and as one coherent workflow.

The dependency chain is:
```
1. Launch EC2 instance (get Instance ID)
      ↓
2. Allocate Elastic IP (get Allocation ID)
      ↓
3. Wait for instance to be running
      ↓
4. Associate EIP with instance (get Association ID)
      ↓
5. Verify: instance public IP = EIP address
```

Getting the sequence wrong — especially trying to associate before the instance is running — is the most common failure mode.

### The Problem This Solves

A standard EC2 instance in a public subnet gets a **dynamic public IP** at launch. Every time the instance is stopped and started, a different IP is assigned from AWS's pool. For:
- Application endpoints that clients hardcode
- DNS records that need to stay valid
- Third-party IP allowlists (payment gateways, partner APIs)
- SSL certificates bound to a specific IP

…a dynamic IP is a maintenance nightmare. The Elastic IP provides a **static public IPv4 address** that persists through stop/start cycles and stays in your account until you explicitly release it.

### The Three-Step EIP Workflow

| Step | Operation | What You Get |
|------|-----------|-------------|
| **Allocate** | `allocate-address` | A public IPv4 address in your account (Allocation ID) |
| **Associate** | `associate-address` | The EIP mapped to a specific instance (Association ID) |
| **Release** | `release-address` | The EIP returned to AWS pool (must disassociate first) |

The Allocation ID is what identifies the EIP in your account. The Association ID is what identifies which instance it's mapped to. Understanding both is essential for working with EIPs programmatically.

### Ubuntu vs Amazon Linux — When to Choose

| AMI | Default User | Best For |
|-----|-------------|---------|
| Amazon Linux 2023 | `ec2-user` | AWS-optimised workloads, CLI pre-installed |
| Ubuntu 22.04/24.04 | `ubuntu` | Wider package availability, familiar for developers |
| RHEL / CentOS | `ec2-user` | Enterprise compatibility, RHEL workloads |

For this task, Ubuntu is specified. The latest Ubuntu 22.04 LTS AMI on AWS is resolved dynamically to avoid hardcoding stale IDs.

### EIP Billing Reminder

| State | Billing |
|-------|---------|
| Associated with running instance | **Free** |
| Allocated but not associated | Charged (~$0.005/hr) |
| Associated with stopped instance | Charged (~$0.005/hr) |

Always release EIPs you no longer need. A stopped instance with an EIP attached still costs money.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Step 1 — Launch EC2:**
1. Navigate to **EC2 → Instances → Launch instances**
2. **Name:** `xfusion-ec2`
3. **AMI:** Ubuntu Server 22.04 LTS (64-bit x86)
4. **Instance type:** `t2.micro`
5. **Key pair:** Select or create one
6. **Network settings:** Default VPC, default subnet, auto-assign public IP enabled
7. Click **Launch instance**

**Step 2 — Allocate EIP:**
1. Navigate to **EC2 → Network & Security → Elastic IPs**
2. Click **Allocate Elastic IP address** → **Allocate**
3. Select the new EIP → **Actions → Add/Edit tags** → add `Name: xfusion-eip`

**Step 3 — Associate EIP:**
1. Select `xfusion-eip` → **Actions → Associate Elastic IP address**
2. Resource type: `Instance` → select `xfusion-ec2`
3. Click **Associate**

**Verify:** EC2 instance details now show the EIP as the Public IPv4 address.

---

### Method 2 — AWS CLI (Full Scripted Workflow)

```bash
# ============================================================
# Step 1: Resolve the latest Ubuntu 22.04 LTS AMI ID
# ============================================================
AMI_ID=$(aws ec2 describe-images \
    --region us-east-1 \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "Latest Ubuntu 22.04 AMI: $AMI_ID"

# ============================================================
# Step 2: Get default VPC and subnet details
# ============================================================
VPC_ID=$(aws ec2 describe-vpcs \
    --region us-east-1 \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
    --region us-east-1 \
    --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" \
    --output text)

DEFAULT_SG=$(aws ec2 describe-security-groups \
    --region us-east-1 \
    --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" \
    --output text)

echo "VPC: $VPC_ID | Subnet: $SUBNET_ID | SG: $DEFAULT_SG"

# ============================================================
# Step 3: Launch the EC2 instance
# ============================================================
INSTANCE_ID=$(aws ec2 run-instances \
    --region us-east-1 \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$DEFAULT_SG" \
    --associate-public-ip-address \
    --tag-specifications \
        'ResourceType=instance,Tags=[{Key=Name,Value=xfusion-ec2}]' \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Instance launched: $INSTANCE_ID"

# ============================================================
# Step 4: Allocate the Elastic IP
# ============================================================
ALLOCATION_ID=$(aws ec2 allocate-address \
    --region us-east-1 \
    --domain vpc \
    --tag-specifications \
        'ResourceType=elastic-ip,Tags=[{Key=Name,Value=xfusion-eip}]' \
    --query "AllocationId" \
    --output text)

EIP_ADDRESS=$(aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" \
    --region us-east-1 \
    --query "Addresses[0].PublicIp" \
    --output text)

echo "EIP allocated: $EIP_ADDRESS (Allocation ID: $ALLOCATION_ID)"

# ============================================================
# Step 5: Wait for instance to be in running state
# ============================================================
echo "Waiting for instance to reach running state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1

echo "Instance is running"

# ============================================================
# Step 6: Associate the Elastic IP with the instance
# ============================================================
ASSOCIATION_ID=$(aws ec2 associate-address \
    --instance-id "$INSTANCE_ID" \
    --allocation-id "$ALLOCATION_ID" \
    --region us-east-1 \
    --query "AssociationId" \
    --output text)

echo "EIP associated — Association ID: $ASSOCIATION_ID"

# ============================================================
[O# Step 7: Verify everything is correctly configured
# ============================================================
echo ""
echo "=== Instance Details ==="
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1 \
    --query "Reservations[0].Instances[0].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value,State:State.Name,Type:InstanceType,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,AZ:Placement.AvailabilityZone}" \
    --output table

echo ""
echo "=== Elastic IP Details ==="
aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" \
    --region us-east-1 \
    --query "Addresses[0].{IP:PublicIp,Name:Tags[?Key=='Name']|[0].Value,AllocID:AllocationId,AssocID:AssociationId,InstanceId:InstanceId}" \
    --output table

echo ""
echo "Summary:"
echo "  Instance:  xfusion-ec2 ($INSTANCE_ID)"
echo "  EIP:       xfusion-eip ($EIP_ADDRESS)"
echo "  Association: $ASSOCIATION_ID"
echo "  SSH:       ssh -i <key.pem> ubuntu@$EIP_ADDRESS"
```

---

### SSH Into the Instance

```bash
# Default user for Ubuntu AMI is 'ubuntu'
ssh -i ~/.ssh/your-key.pem ubuntu@"$EIP_ADDRESS"

# Verify the instance can see its own EIP via metadata
curl -s http://169.254.169.254/latest/meta-data/public-ipv4
# Should return the EIP address
```

---

### Disassociate and Release EIP (Cleanup)

```bash
# Step 1: Disassociate the EIP from the instance
aws ec2 disassociate-address \
    --association-id "$ASSOCIATION_ID" \
    --region us-east-1

# Step 2: Release the EIP back to AWS pool
aws ec2 release-address \
    --allocation-id "$ALLOCATION_ID" \
    --region us-east-1

# Step 3: Terminate the instance
aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1

aws ec2 wait instance-terminated \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1

echo "Cleanup complete"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- RESOLVE UBUNTU AMI ---
AMI_ID=$(aws ec2 describe-images --region "$REGION" \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
              "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

# --- GET DEFAULT NETWORKING ---
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" --output text)

# --- LAUNCH INSTANCE ---
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" --instance-type t2.micro \
    --subnet-id "$SUBNET_ID" --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=xfusion-ec2}]' \
    --query "Instances[0].InstanceId" --output text)

# --- ALLOCATE EIP ---
ALLOCATION_ID=$(aws ec2 allocate-address --region "$REGION" \
    --domain vpc \
    --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=xfusion-eip}]' \
    --query "AllocationId" --output text)

# --- WAIT THEN ASSOCIATE ---
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

ASSOCIATION_ID=$(aws ec2 associate-address --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --allocation-id "$ALLOCATION_ID" \
    --query "AssociationId" --output text)

# --- VERIFY ---
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].{Name:Tags[?Key=='Name']|[0].Value,State:State.Name,PublicIP:PublicIpAddress}" \
    --output table

aws ec2 describe-addresses --allocation-ids "$ALLOCATION_ID" --region "$REGION" \
    --query "Addresses[0].{IP:PublicIp,Name:Tags[?Key=='Name']|[0].Value,InstanceId:InstanceId}" \
    --output table

# --- SSH ---
ssh -i ~/.ssh/your-key.pem ubuntu@"$EIP_ADDRESS"

# --- CLEANUP ---
aws ec2 disassociate-address --association-id "$ASSOCIATION_ID" --region "$REGION"
aws ec2 release-address --allocation-id "$ALLOCATION_ID" --region "$REGION"
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
```

---

## ⚠️ Common Mistakes

**1. Trying to associate the EIP before the instance reaches `running` state**
`associate-address` can technically succeed while the instance is still in `pending`, but the association may not be stable and can cause inconsistent public IP assignment. Always use `aws ec2 wait instance-running` before associating. It's a ten-second guard that prevents a class of timing-related failures.

**2. Forgetting `--domain vpc` when allocating the EIP**
`allocate-address` without `--domain vpc` allocates an EC2-Classic EIP — a legacy type that doesn't work with VPC instances in modern regions. Always specify `--domain vpc` explicitly. In most current regions EC2-Classic is completely gone, but the flag is still needed for correctness.

**3. Not tagging the EIP at allocation time**
EIPs are notoriously hard to track after the fact. Tag them immediately at `allocate-address` using `--tag-specifications`. If you forget to tag and end up with 20 untagged EIPs in a busy account, correlating them to instances or purposes becomes a frustrating guessing game.

**4. Releasing the EIP without disassociating first**
You must disassociate before releasing. Calling `release-address` on an EIP that's still associated will fail with `InvalidAllocationID.NotFound` or `AddressLimitExceeded` depending on the region. The correct order is always: disassociate → release.

**5. Not knowing the SSH username for Ubuntu**
Ubuntu AMIs use `ubuntu` as the default user, not `ec2-user`. Attempting `ssh ec2-user@<IP>` will authenticate but immediately disconnect with "Permission denied (publickey)" in the Ubuntu logs. Check the AMI description for the default user — it varies by OS.

**6. Leaving EIP allocated after stopping/terminating the instance**
Terminating the instance disassociates the EIP but does not release it. The EIP stays in your account and starts billing. After any instance cleanup, always verify there are no unassociated EIPs remaining: `aws ec2 describe-addresses --query "Addresses[?AssociationId==null]"`.

---

## 🌍 Real-World Context

The pattern of "EC2 instance + Elastic IP" is a classic setup for small, self-managed services that need a stable network identity. While modern architectures increasingly move toward load balancers and DNS-based discovery (which removes the need for static IPs at the instance level), EIPs remain relevant for:

**Bastion / Jump Hosts:** A bastion host whitelisted by corporate firewalls needs a static IP that security teams can register. Changing it requires another change request and coordination — EIPs remove that friction entirely.

**NAT Instances (legacy):** Before AWS Managed NAT Gateway, teams would run EC2 instances as NAT servers. These needed stable IPs for outbound traffic identity. NAT Gateway is the modern replacement, but the pattern still appears in legacy environments.

**Self-managed databases:** A PostgreSQL or MySQL instance running directly on EC2 (not RDS) may need a fixed IP for connection string stability, especially when the database isn't behind a load balancer.

**Third-party IP allowlisting:** Payment processors, partner APIs, and B2B integrations often require IP allowlisting. When your application server makes outbound calls to these services, a fixed EIP ensures those calls always originate from a known, registered IP.

In Terraform, this entire workflow collapses to three resource blocks:

```hcl
resource "aws_instance" "xfusion" { ... }
resource "aws_eip" "xfusion" { domain = "vpc" }
resource "aws_eip_association" "xfusion" {
  instance_id   = aws_instance.xfusion.id
  allocation_id = aws_eip.xfusion.id
}
```

The `depends_on` is handled automatically by Terraform's dependency graph — it knows to wait for the instance before associating.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is the correct sequence to create an EC2 instance with an Elastic IP, and why does order matter?**

> Launch the instance first, then allocate the EIP, then wait for the instance to reach `running` state, then associate the EIP. Order matters for two reasons: you need the Instance ID before you can associate, and you need the instance in a stable state before association to avoid timing failures. You can allocate the EIP before the instance is running — the allocation is independent — but association should only happen after the instance is running. In automation, the `wait instance-running` call is the synchronisation point that makes the script deterministic rather than timing-dependent.

---

**Q2. A customer says their application lost connectivity after they stopped and restarted their EC2 instance. What's the most likely cause and how do you fix it?**

> The instance had a regular dynamic public IP (auto-assigned at launch) rather than an Elastic IP. When the instance was stopped, that dynamic IP was released back to AWS's pool. When it started again, a new, different IP was assigned. Any DNS record, application config, firewall rule, or client pointing to the old IP now points to the wrong or non-existent address. The fix going forward: allocate an Elastic IP and associate it with the instance. The EIP persists through stop/start cycles and through any AMI launches from that instance. For the immediate outage: update the DNS record or config to point to the new public IP, then associate an EIP to prevent this from happening again.

---

**Q3. You need to migrate an application from a failing EC2 instance to a new one without changing the public IP. How do you use an EIP to achieve this?**

> The EIP is the stable anchor point. Disassociate the EIP from the failing instance — this takes seconds. Launch the replacement instance (from an AMI or fresh). Once the new instance is running, associate the EIP to it. From the perspective of any external client, DNS, or allowlist, the IP never changed — they reconnect to the same address, now backed by the healthy instance. This is the manual failover pattern. For automated failover, you'd combine this with a CloudWatch alarm on the failing instance that triggers a Lambda to perform the disassociate/associate sequence automatically when health checks fail.

---

**Q4. What is the difference between the Allocation ID and the Association ID for an Elastic IP?**

> The **Allocation ID** (`eipalloc-xxx`) is created when you allocate the EIP — it's the stable identifier for that IP address within your account. It persists from allocation until release, regardless of which instance (if any) the EIP is attached to. The **Association ID** (`eipassoc-xxx`) is created when you associate the EIP with an instance — it identifies that specific mapping. It's destroyed when you disassociate. In practice: use the Allocation ID to manage the EIP itself (release, describe, tag), and the Association ID specifically for the `disassociate-address` call.

---

**Q5. Can an EC2 instance have both an auto-assigned public IP and an Elastic IP simultaneously?**

> No — once an EIP is associated with an instance, it replaces the auto-assigned public IP. The instance's public IP address becomes the EIP. The dynamic IP is effectively "hidden" by the EIP and released. If you disassociate the EIP, the instance loses its public IP entirely — it does not get the dynamic IP back. If you want the instance to have a public IP again after disassociation, you'd need to either re-associate an EIP or stop and start the instance (which assigns a new dynamic IP, provided the subnet has auto-assign public IP enabled).

---

**Q6. An application team wants all their outbound traffic from EC2 to always come from the same IP for a partner's allowlist. How do you architect this?**

> For a single EC2 instance, associate an EIP — all outbound traffic from the instance will originate from the EIP's address. For multiple EC2 instances that all need to egress from the same IP (Auto Scaling Group, ECS cluster), the correct architecture is a **NAT Gateway** in a public subnet with an EIP attached. The private instances route all outbound traffic through the NAT Gateway, which translates their private IPs to the NAT Gateway's EIP. External systems see one consistent IP regardless of how many instances are behind it or how they scale. This is the standard egress pattern for private-subnet workloads.

---

**Q7. What happens to an Elastic IP if you terminate the EC2 instance it's associated with?**

> The EIP is automatically **disassociated** from the terminated instance — it's no longer mapped to anything. But it remains **allocated** to your account and continues to incur charges at the unassociated rate (~$0.005/hr). This is a very common source of billing drift — teams terminate instances and assume the EIP is "cleaned up" when it's actually still sitting in the account. The correct cleanup sequence is: disassociate the EIP → release it → then terminate the instance (or terminate first, then release the now-orphaned EIP). After any instance termination, always audit for unassociated EIPs: `aws ec2 describe-addresses --query "Addresses[?AssociationId==null]"`.

---

## 📚 Resources

- [AWS Docs — Elastic IP Addresses](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html)
- [AWS Docs — Launch EC2 Instance](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EC2_GetStarted.html)
- [AWS CLI Reference — allocate-address](https://docs.aws.amazon.com/cli/latest/reference/ec2/allocate-address.html)
- [AWS CLI Reference — associate-address](https://docs.aws.amazon.com/cli/latest/reference/ec2/associate-address.html)
- [Ubuntu AWS AMI Locator](https://cloud-images.ubuntu.com/locator/ec2/)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
