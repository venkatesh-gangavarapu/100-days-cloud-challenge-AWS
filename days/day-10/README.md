# Day 10 — Attaching an Elastic IP to an EC2 Instance

> **#100DaysOfCloud | Day 10 of 100**

---

## 📌 The Task

> *There is an instance named `nautilus-ec2` and an Elastic IP named `nautilus-ec2-eip` in `us-east-1`. Attach the Elastic IP to the instance.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Instance name | `nautilus-ec2` |
| Elastic IP name | `nautilus-ec2-eip` |
| Action | Associate the EIP to the instance |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### The Public IP Problem Without an Elastic IP

Every EC2 instance in a public subnet gets a **dynamic public IP address** at launch — it's assigned from AWS's pool, associated while the instance runs, and **released the moment the instance is stopped**. When the instance starts again, it gets a different IP from the pool. There's no guarantee it will ever get the same one.

This creates real operational problems:

- DNS records pointing to the old IP stop resolving correctly
- External firewall allowlists referencing the IP become stale
- Third-party services that only accept traffic from known IPs lose connectivity
- Application configs or clients hardcoded to the IP break silently

An **Elastic IP (EIP)** solves this by giving you a **static public IPv4 address** that belongs to your AWS account until you explicitly release it. You can associate it with any instance, detach it, and re-associate it with a different instance — all without the IP address changing.

### What Is an Elastic IP?

An **Elastic IP address** is a static public IPv4 address designed for dynamic cloud computing. Key characteristics:

- **Allocated to your account** — it's yours until released, regardless of what instance it's attached to
- **Region-specific** — an EIP in `us-east-1` cannot be used in `eu-west-1`
- **Can be remapped instantly** — if your primary instance fails, disassociate the EIP and associate it with a standby instance in seconds, with no DNS TTL wait
- **One-to-one** — a single EIP can only be associated with one instance (or network interface) at a time
- **Associated with a Network Interface** — technically, an EIP is associated with an Elastic Network Interface (ENI), not directly with the instance; the instance just has an ENI

### Elastic IP Pricing — The Important Detail

AWS charges for Elastic IPs in two specific scenarios:

| Scenario | Cost |
|----------|------|
| EIP associated with a **running** instance | **Free** |
| EIP allocated but **not associated** with any instance | Charged per hour (~$0.005/hr) |
| EIP associated with a **stopped** instance | Charged per hour (~$0.005/hr) |
| More than **one EIP per running instance** | Additional EIPs are charged |

The pricing model exists to discourage hoarding of public IPv4 addresses. The practical implication: if you allocate an EIP and don't attach it (or your instance is stopped), you're paying for it. Always release EIPs you're not using.

### EIP vs Auto-Assigned Public IP

| Feature | Auto-Assigned Public IP | Elastic IP |
|---------|------------------------|------------|
| Static | ❌ Changes on stop/start | ✅ Permanent |
| Ownership | Returned to AWS pool on stop | Belongs to your account |
| Cost | Free | Free while attached to running instance |
| Remappable | ❌ | ✅ Can move between instances |
| Survives stop/start | ❌ | ✅ |
| Required for production | No (use Route 53 instead) | For specific use cases |

### When to Use an Elastic IP in Production

Elastic IPs are the right tool in specific scenarios:

- **NAT instance** — a NAT instance needs a stable public IP for outbound traffic from private subnets
- **Bastion host** — SSH bastion IP whitelisted by external security teams; can't change without coordination
- **Third-party IP allowlists** — payment gateways, partner APIs, and external SaaS tools that only accept requests from registered IPs
- **Rapid failover** — remapping an EIP from a failed primary instance to a standby takes seconds with no DNS propagation delay
- **Legacy or on-premises integration** — systems that can't do DNS-based discovery and need a fixed IP

For modern web applications behind an ALB or CloudFront, a static IP is often unnecessary — the load balancer handles the fixed DNS name and health-based routing. Elastic IPs are better suited for infrastructure-layer needs than application-layer ones.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Step 1 — Find the Elastic IP allocation ID**
1. Navigate to **EC2 → Network & Security → Elastic IPs**
2. Find the EIP named `nautilus-ec2-eip`
3. Note the **Allocation ID** (e.g., `eipalloc-0abc1234def567890`) and the **IP address**
4. Confirm it shows **Association ID: —** (unassociated)

**Step 2 — Associate the EIP**
1. Select `nautilus-ec2-eip` → **Actions → Associate Elastic IP address**
2. **Resource type:** Instance
3. **Instance:** Select `nautilus-ec2` from the dropdown
4. **Private IP address:** Leave as default (the instance's primary private IP)
5. Click **Associate**

**Step 3 — Verify**
- The EIP row now shows an **Instance ID** and **Private IP address** in the association columns
- Navigate to **EC2 → Instances** → select `nautilus-ec2`
- Under **Details**, the **Elastic IP addresses** field now shows the EIP

---

### Method 2 — AWS CLI

```bash
# ============================================================
# Step 1: Get the Instance ID for nautilus-ec2
# ============================================================
INSTANCE_ID=$(aws ec2 describe-instances \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=nautilus-ec2" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Instance ID: $INSTANCE_ID"

# ============================================================
# Step 2: Get the Allocation ID for nautilus-ec2-eip
# ============================================================
ALLOCATION_ID=$(aws ec2 describe-addresses \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=nautilus-ec2-eip" \
    --query "Addresses[0].AllocationId" \
    --output text)

EIP_ADDRESS=$(aws ec2 describe-addresses \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=nautilus-ec2-eip" \
    --query "Addresses[0].PublicIp" \
    --output text)

echo "Allocation ID: $ALLOCATION_ID"
echo "Elastic IP:    $EIP_ADDRESS"

# ============================================================
# Step 3: Confirm the EIP is currently unassociated
# ============================================================
aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" \
    --region us-east-1 \
    --query "Addresses[0].{IP:PublicIp,AllocationId:AllocationId,AssociationId:AssociationId,InstanceId:InstanceId}" \
    --output table
# AssociationId and InstanceId should be None/null before association

# ============================================================
# Step 4: Associate the Elastic IP with the instance
# ============================================================
aws ec2 associate-address \
    --instance-id "$INSTANCE_ID" \
    --allocation-id "$ALLOCATION_ID" \
    --region us-east-1

# Output: { "AssociationId": "eipassoc-0abc1234def567890" }

# ============================================================
# Step 5: Verify the association
# ============================================================
aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" \
    --region us-east-1 \
    --query "Addresses[0].{IP:PublicIp,AllocationId:AllocationId,AssociationId:AssociationId,InstanceId:InstanceId}" \
    --output table

# Also confirm on the instance side
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1 \
    --query "Reservations[0].Instances[0].{ID:InstanceId,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,EIP:NetworkInterfaces[0].Association.PublicIp}" \
    --output table
```

---

### Disassociating an Elastic IP

```bash
# Get the Association ID
ASSOCIATION_ID=$(aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" \
    --region us-east-1 \
    --query "Addresses[0].AssociationId" \
    --output text)

# Disassociate (EIP is still allocated to your account, just not attached)
aws ec2 disassociate-address \
    --association-id "$ASSOCIATION_ID" \
    --region us-east-1

# Verify: EIP should now show no instance association
aws ec2 describe-addresses --allocation-ids "$ALLOCATION_ID" --region us-east-1
```

---

### Releasing an Elastic IP (Return to AWS Pool)

```bash
# Only run this when you want to permanently give up the EIP
# The IP address may be assigned to someone else after release

# Must disassociate first if still attached
aws ec2 disassociate-address --association-id "$ASSOCIATION_ID" --region us-east-1

# Then release — EIP is gone from your account
aws ec2 release-address \
    --allocation-id "$ALLOCATION_ID" \
    --region us-east-1
```

---

### Remapping an EIP to a Different Instance (Failover Pattern)

```bash
# Disassociate from the current (failed) instance
aws ec2 disassociate-address \
    --association-id "$ASSOCIATION_ID" \
    --region us-east-1

# Re-associate with the standby instance
aws ec2 associate-address \
    --instance-id "$STANDBY_INSTANCE_ID" \
    --allocation-id "$ALLOCATION_ID" \
    --region us-east-1

# The EIP now points to the standby — no DNS change required
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- RESOLVE IDs ---
INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=nautilus-ec2" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

ALLOCATION_ID=$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:Name,Values=nautilus-ec2-eip" \
    --query "Addresses[0].AllocationId" --output text)

EIP_ADDRESS=$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:Name,Values=nautilus-ec2-eip" \
    --query "Addresses[0].PublicIp" --output text)

# --- LIST ALL EIPs ---
aws ec2 describe-addresses --region "$REGION" \
    --query "Addresses[*].{IP:PublicIp,AllocID:AllocationId,AssocID:AssociationId,InstanceId:InstanceId,Name:Tags[?Key=='Name']|[0].Value}" \
    --output table

# --- ASSOCIATE ---
aws ec2 associate-address \
    --instance-id "$INSTANCE_ID" \
    --allocation-id "$ALLOCATION_ID" \
    --region "$REGION"

# --- VERIFY ---
aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" --region "$REGION" \
    --query "Addresses[0].{IP:PublicIp,AssocID:AssociationId,InstanceId:InstanceId}" \
    --output table

# --- DISASSOCIATE ---
ASSOCIATION_ID=$(aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" --region "$REGION" \
    --query "Addresses[0].AssociationId" --output text)

aws ec2 disassociate-address \
    --association-id "$ASSOCIATION_ID" --region "$REGION"

# --- RELEASE (permanent) ---
aws ec2 release-address \
    --allocation-id "$ALLOCATION_ID" --region "$REGION"
```

---

## ⚠️ Common Mistakes

**1. Confusing Allocation ID with Association ID**
These are two different identifiers. The **Allocation ID** (`eipalloc-xxx`) identifies the EIP itself — it's created when the EIP is allocated and persists until release. The **Association ID** (`eipassoc-xxx`) is created when the EIP is associated with a resource and destroyed when it's disassociated. You use the Allocation ID for most operations; the Association ID is specifically needed for `disassociate-address`.

**2. Forgetting to release unused EIPs**
An EIP that's allocated but not attached to a running instance costs money every hour. After detaching an EIP for maintenance or disassociating it during cleanup, explicitly release it if it's no longer needed. Build a periodic audit into your cost hygiene process: `describe-addresses` and filter for any where `AssociationId` is null.

**3. Associating an EIP with a stopped instance**
You can associate an EIP with a stopped instance — the operation succeeds. But you'll be charged for the EIP while the instance is stopped. If the intent was to reduce cost by stopping the instance, make sure you're not accumulating EIP charges alongside stopped-instance storage charges.

**4. Losing an EIP by releasing instead of disassociating**
Disassociate detaches the EIP from the instance but keeps it in your account. Release permanently returns it to AWS — the IP address may be reassigned to someone else. If any external system (DNS, firewall allowlist, partner API) references that IP, releasing it breaks those integrations permanently. Always disassociate unless you're certain the IP is no longer needed.

**5. Not re-associating after a stop/start cycle when using an EIP**
While an EIP persists through stop/start, a common confusion is when someone removes the EIP association to do maintenance and forgets to re-associate before starting the instance. The instance then gets a new random public IP instead of the EIP, breaking external connectivity that depended on the static IP.

**6. Using an EIP where a load balancer DNS name is the better solution**
For web applications, using an EIP on a single EC2 instance as the entry point is a single point of failure. The modern pattern is to put instances behind an Application Load Balancer and use Route 53 to alias the domain to the ALB's DNS name. The ALB handles health checks and failover automatically without any IP management.

---

## 🌍 Real-World Context

Elastic IPs are one of those AWS features that are genuinely useful for a specific class of problem but often overused by teams that haven't considered alternatives.

**Good use cases:**
- A bastion/jump host whose IP is allowlisted in external corporate firewalls — changing the IP requires a change request and coordination with security teams
- A NAT instance acting as the egress point for private subnets — outbound traffic needs a stable, known IP for partner IP allowlisting
- Failover scenarios where you want sub-minute RTO without relying on DNS TTL: associate the EIP with a standby instance and the failover is instantaneous from the client perspective

**Where teams go wrong:**
- Attaching an EIP to every production instance "just in case" — this creates unnecessary cost and management overhead
- Using EIPs instead of load balancers for redundancy — two instances each with their own EIP is not HA; it's two single points of failure
- Allocating EIPs speculatively and forgetting about them — these quietly accrue charges and eventually accumulate in the AWS account as forgotten resources

The modern recommendation for most web workloads is: use **Route 53 with an Alias record pointing to an ALB** instead of managing EIPs directly. The ALB has a stable DNS name, handles health-based routing, and scales its IP addresses automatically. Reserve EIPs for infrastructure-layer needs where a stable IP is genuinely required.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is an Elastic IP and why is it needed? When would you use one vs relying on a standard public IP?**

> A standard EC2 public IP is ephemeral — it's released when the instance stops and a different one is assigned when it restarts. An Elastic IP is a static public IPv4 address allocated to your account that persists independently of any instance's lifecycle. You use an EIP when something outside AWS needs to reach a specific, unchanging IP address — a payment gateway or partner API that allowlists IPs, a bastion host whose IP is registered in an external firewall, or a NAT instance providing stable outbound identity for private subnet traffic. For most web applications, you don't need an EIP at all — you'd use a load balancer with a stable DNS name and Route 53 Alias records instead. EIPs are a specific tool for infrastructure-layer needs, not a default for every production instance.

---

**Q2. What's the difference between disassociating and releasing an Elastic IP?**

> **Disassociating** detaches the EIP from its current instance or network interface but keeps it in your account — the Allocation ID still exists, you're still billed if it's not re-associated with a running instance, and you can associate it with a different resource later. **Releasing** permanently returns the EIP to AWS's pool. Once released, the IP address may be assigned to a different customer, and you lose it forever. If any DNS records, firewall rules, or partner allowlists reference that IP, releasing it breaks those integrations permanently with no recovery path. Always disassociate unless you are absolutely certain the IP address is no longer referenced anywhere.

---

**Q3. Your primary EC2 instance fails. You have a warm standby instance ready. How do you use an Elastic IP to achieve the fastest possible failover?**

> Disassociate the EIP from the failed instance and immediately re-associate it with the standby:
> ```bash
> aws ec2 disassociate-address --association-id $CURRENT_ASSOC_ID
> aws ec2 associate-address --allocation-id $EIP_ALLOC_ID --instance-id $STANDBY_ID
> ```
> This takes a few seconds. Clients connecting to the EIP address don't experience a DNS TTL wait — the IP itself doesn't change, only which instance it routes to. This is meaningfully faster than a DNS-based failover (which can take minutes to hours depending on TTL) for latency-sensitive scenarios. The limitation is that it requires an operator to trigger the reassociation — it's a manual failover. For automated failover, you'd combine this with a health check Lambda triggered by CloudWatch alarms.

---

**Q4. You're auditing an AWS account and find 12 Elastic IPs that are allocated but not associated with any instance. What's the business impact and how do you clean this up?**

> Each unassociated EIP costs approximately $0.005 per hour, or roughly $3.60/month per EIP. Twelve unassociated EIPs cost around $43/month for no value. To identify them:
> ```bash
> aws ec2 describe-addresses --region us-east-1 \
>     --query "Addresses[?AssociationId==null].{IP:PublicIp,AllocID:AllocationId}" \
>     --output table
> ```
> Before releasing them, check whether any external systems reference those IPs — DNS records, firewall allowlists, partner registrations. Cross-reference with your DNS provider and any documentation. For IPs that are definitely unused, release them with `aws ec2 release-address`. Going forward, add an AWS Config rule or a Cost Anomaly Detection alert to flag idle EIPs, and include EIP cleanup in your periodic cloud cost hygiene reviews.

---

**Q5. Can you associate an Elastic IP with an instance in a private subnet?**

> No — not in a way that provides internet access. An EIP provides a public IP for reaching a resource from the internet, but internet accessibility also requires the instance's subnet to have a route to an Internet Gateway. An instance in a private subnet (no IGW route) with an EIP associated will have the IP on paper but no path for inbound internet traffic to reach it. For outbound internet access from private subnets, the pattern is a NAT Gateway (or NAT instance) in a public subnet — the NAT Gateway gets the EIP, and all outbound traffic from the private subnet exits through it. Inbound initiated connections from the internet still can't reach the private instances through NAT.

---

**Q6. What happens to an Elastic IP when the associated EC2 instance is terminated?**

> The EIP is automatically **disassociated** from the instance when it's terminated — it's not released. It remains allocated to your account, unassociated, and you'll start being charged for it. This is a common source of forgotten EIP costs: an instance is terminated as part of cleanup, the team assumes the EIP is gone too, and it silently accrues charges. After terminating any instance that had an EIP attached, explicitly check whether the EIP was released or just disassociated, and release it if it's no longer needed.

---

**Q7. How does an Elastic IP relate to an Elastic Network Interface (ENI)? Why does this distinction matter?**

> Technically, an Elastic IP is associated with a **network interface** (ENI), not directly with an EC2 instance. When you associate an EIP with an instance, AWS is actually associating it with the instance's primary ENI. The reason this matters: if you're building more sophisticated network architectures — like an instance with multiple ENIs (each in a different subnet), or a network appliance that needs to be replaced without changing IP — you can manage EIPs at the ENI level directly. You can detach an ENI from one instance, attach it to another, and the EIP moves with it. This pattern is used in failover architectures where the ENI (with its EIP and private IP) is the stable identity, and the instance underneath is replaceable.

---

## 📚 Resources

- [AWS Docs — Elastic IP Addresses](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html)
- [AWS CLI Reference — associate-address](https://docs.aws.amazon.com/cli/latest/reference/ec2/associate-address.html)
- [AWS CLI Reference — describe-addresses](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-addresses.html)
- [EIP Pricing](https://aws.amazon.com/ec2/pricing/on-demand/#Elastic_IP_Addresses)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
