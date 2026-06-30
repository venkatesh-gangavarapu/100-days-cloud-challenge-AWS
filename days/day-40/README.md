# Day 40 — Troubleshooting: VPC Internet Connectivity for an EC2 Web Server

> **#100DaysOfCloud | Day 40 of 100**

---

## 📌 The Task

> *An Nginx web server on EC2 in `datacenter-vpc` is unreachable on port 80 from the internet, despite the security group correctly allowing port 80. Diagnose and fix the VPC-level networking issue.*

**Given:**
| Resource | State |
|----------|-------|
| VPC | `datacenter-vpc` |
| EC2 Instance | `datacenter-ec2` — running Nginx |
| Security Group | `datacenter-sg` — already allows port 80 (confirmed working) |
| Symptom | Application unreachable from the internet on port 80 |

**Goal:** Identify and fix the VPC-level misconfiguration preventing internet access.

---

## 🧠 Core Concepts

### Why "the Security Group Is Correct" Isn't Enough

This task is a deliberate lesson: a correctly configured security group is **necessary but not sufficient** for internet accessibility. Five independent layers must all be correct simultaneously for an EC2 instance to be reachable from the internet:

```
1. Internet Gateway exists and is ATTACHED to the VPC
        ↓
2. Subnet's route table has a route: 0.0.0.0/0 → IGW
        ↓
3. Instance has a public IPv4 address assigned
        ↓
4. Security group allows the inbound port  ← (already confirmed OK)
        ↓
5. Network ACL on the subnet allows the traffic (both directions — stateless)
        ↓
6. The application is actually listening on the port inside the instance
```

The task statement tells us layer 4 is already correct — which means the problem is almost certainly in layers 1, 2, 3, 5, or 6. This README walks through diagnosing each one systematically, since "the VPC configuration" framing in the task points strongly at layers 1–3.

### The Most Common Root Cause: Missing or Unattached Internet Gateway

A VPC created from scratch (as opposed to the AWS-provided default VPC) does **not** automatically get an Internet Gateway. Many lab/training environments deliberately create a custom VPC without one, or with one created but never attached, specifically to test whether you can recognize and fix this.

Without an IGW:
- The instance can have a public IP assigned
- The security group can be perfectly configured
- The instance can be 100% healthy
- **None of that matters** — there's no path for the traffic to physically reach the VPC from the internet at all

### The Second Most Common Cause: Missing Route in the Route Table

Even with an IGW attached to the VPC, the **subnet's route table** must explicitly have a route directing internet-bound traffic (`0.0.0.0/0`) to that IGW. The IGW being attached to the VPC is necessary but not sufficient — each subnet's route table independently decides whether traffic in that subnet actually uses the IGW.

A subnet using the VPC's default **main route table** (which has no IGW route unless explicitly added) will have no internet access even with a perfectly attached IGW sitting right there in the VPC.

### Why This Specific Failure Mode Is Tricky to Spot

The EC2 console will often **still show a public IP address** assigned to the instance, even when the IGW or route is missing. This is misleading — having a public IP doesn't guarantee a route exists for that IP's traffic to actually flow. People who only check "does my instance have a public IP" and stop there miss this category of fault entirely.

### Diagnostic Order — Outside-In

The correct debugging approach works from the network edge inward, since that's the order traffic actually has to pass through to reach the instance:

```
Internet
   │
   ▼ Is there an IGW, and is it attached?           ← Check 1
   │
   ▼ Does the route table route 0.0.0.0/0 → IGW?    ← Check 2
   │
   ▼ Does the instance have a public IP?            ← Check 3
   │
   ▼ Does the NACL allow the traffic (both ways)?   ← Check 4
   │
   ▼ Does the Security Group allow the traffic?     ← Already confirmed OK
[O   │
   ▼ Is the application actually listening?         ← Check 5
   │
   ▼ Success
```

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

#### Step 1 — Check for an Internet Gateway

1. **VPC Console → Internet gateways**
2. Look for an IGW with **State: Attached** and **VPC: datacenter-vpc**
3. **If none exists:**
   - Click **Create internet gateway** → name it `datacenter-igw` → Create
   - Select it → **Actions → Attach to VPC** → choose `datacenter-vpc` → Attach
4. **If one exists but is `Detached`:**
   - Select it → **Actions → Attach to VPC** → choose `datacenter-vpc` → Attach

#### Step 2 — Check the Route Table

1. **VPC Console → Route tables**
2. Find the route table associated with `datacenter-ec2`'s subnet (check the subnet's **Route table** tab to identify which one)
3. Select it → **Routes tab**
4. Look for a route: `0.0.0.0/0 → igw-xxxxxxxx`
5. **If missing:**
   - **Edit routes → Add route**
   - Destination: `0.0.0.0/0` | Target: **Internet Gateway** → select your IGW
   - Save changes

#### Step 3 — Confirm the Subnet Association

1. Still in the route table, check the **Subnet associations** tab
2. Confirm `datacenter-ec2`'s subnet is explicitly associated with this route table
3. **If the subnet has no explicit association**, it's using the VPC's main route table — verify that one has the IGW route instead, or explicitly associate the subnet with the correct route table

#### Step 4 — Confirm the Instance Has a Public IP

1. **EC2 Console → Instances → datacenter-ec2**
2. Check the **Public IPv4 address** field
3. **If blank:**
   - The subnet likely doesn't auto-assign public IPs, and the instance wasn't launched with one
   - Allocate and associate an Elastic IP instead: **EC2 → Elastic IPs → Allocate → Associate with datacenter-ec2**

#### Step 5 — Check the Network ACL

1. **VPC Console → Network ACLs**
2. Find the NACL associated with the instance's subnet
3. Confirm **Inbound rules** allow port 80 from `0.0.0.0/0`
4. Confirm **Outbound rules** allow ephemeral ports (`1024-65535`) to `0.0.0.0/0` — NACLs are stateless, so the **response** traffic needs its own explicit allow rule
5. The default NACL allows all traffic both ways — if a custom NACL was applied, this is a likely culprit

#### Step 6 — Verify and Test

1. Note the instance's public IP
2. From a browser or `curl`: `curl http://<public-ip>`
3. Should return the Nginx welcome page

---

### Method 2 — AWS CLI (Full Diagnostic + Fix Script)

```bash
#!/bin/bash
set -e
REGION="us-east-1"

# ============================================================
# STEP 1: Resolve VPC, instance, and subnet
# ============================================================

echo "=== Step 1: Resolving resources ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=tag:Name,Values=datacenter-vpc" \
    --query "Vpcs[0].VpcId" --output text)

INSTANCE_ID=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=datacenter-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

SUBNET_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
    --query "Reservations[0].Instances[0].SubnetId" --output text)

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "VPC: $VPC_ID | Instance: $INSTANCE_ID | Subnet: $SUBNET_ID | Public IP: $PUBLIC_IP"

# ============================================================
# STEP 2: DIAGNOSTIC — Check for an attached Internet Gateway
# ============================================================

echo ""
echo "=== Step 2: Checking Internet Gateway ==="

IGW_ID=$(aws ec2 describe-internet-gateways --region $REGION \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query "InternetGateways[0].InternetGatewayId" --output text)

if [ -z "$IGW_ID" ] || [ "$IGW_ID" == "None" ]; then
    echo "❌ ROOT CAUSE FOUND: No Internet Gateway attached to $VPC_ID"
    echo "Creating and attaching one..."

    IGW_ID=$(aws ec2 create-internet-gateway --region $REGION \
        --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=datacenter-igw}]' \
        --query "InternetGateway.InternetGatewayId" --output text)

    aws ec2 attach-internet-gateway \
        --internet-gateway-id $IGW_ID \
        --vpc-id $VPC_ID --region $REGION

    echo "✅ FIXED: Created and attached $IGW_ID to $VPC_ID"
else
    echo "✅ IGW already attached: $IGW_ID"
fi

# ============================================================
# STEP 3: DIAGNOSTIC — Check the subnet's route table for IGW route
# ============================================================

echo ""
echo "=== Step 3: Checking route table ==="

# Find the route table explicitly associated with the subnet
RT_ID=$(aws ec2 describe-route-tables --region $REGION \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query "RouteTables[0].RouteTableId" --output text)

if [ -z "$RT_ID" ] || [ "$RT_ID" == "None" ]; then
    echo "Subnet has no explicit route table association — using VPC main route table"
    RT_ID=$(aws ec2 describe-route-tables --region $REGION \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
        --query "RouteTables[0].RouteTableId" --output text)
fi

echo "Route table in use: $RT_ID"

HAS_IGW_ROUTE=$(aws ec2 describe-route-tables --route-table-ids $RT_ID --region $REGION \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && GatewayId=='${IGW_ID}']" \
    --output text)

if [ -z "$HAS_IGW_ROUTE" ]; then
    echo "❌ ROOT CAUSE FOUND: No 0.0.0.0/0 → IGW route in $RT_ID"
    echo "Adding the route..."

    aws ec2 create-route \
        --route-table-id $RT_ID \
        --destination-cidr-block 0.0.0.0/0 \
        --gateway-id $IGW_ID \
        --region $REGION

    echo "✅ FIXED: Added 0.0.0.0/0 → $IGW_ID to $RT_ID"
else
    echo "✅ Route already exists: 0.0.0.0/0 → $IGW_ID"
fi

# ============================================================
# STEP 4: DIAGNOSTIC — Check instance has a public IP
# ============================================================

echo ""
echo "=== Step 4: Checking public IP assignment ==="

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" == "None" ]; then
    echo "❌ ROOT CAUSE FOUND: Instance has no public IP"
    echo "Allocating and associating an Elastic IP..."

    ALLOC_ID=$(aws ec2 allocate-address --domain vpc --region $REGION \
        --query "AllocationId" --output text)

    aws ec2 associate-address \
        --instance-id $INSTANCE_ID \
        --allocation-id $ALLOC_ID \
        --region $REGION

    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
        --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

    echo "✅ FIXED: Associated Elastic IP $PUBLIC_IP with $INSTANCE_ID"
else
    echo "✅ Instance already has public IP: $PUBLIC_IP"
fi

# ============================================================
# STEP 5: DIAGNOSTIC — Check Network ACL rules
# ============================================================

echo ""
echo "=== Step 5: Checking Network ACL ==="

NACL_ID=$(aws ec2 describe-network-acls --region $REGION \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query "NetworkAcls[0].NetworkAclId" --output text)

echo "NACL: $NACL_ID"

echo "Inbound rules:"
aws ec2 describe-network-acls --network-acl-ids $NACL_ID --region $REGION \
    --query "NetworkAcls[0].Entries[?Egress==\`false\`].{Rule:RuleNumber,Protocol:Protocol,Port:PortRange,CIDR:CidrBlock,Action:RuleAction}" \
    --output table

echo "Outbound rules:"
aws ec2 describe-network-acls --network-acl-ids $NACL_ID --region $REGION \
    --query "NetworkAcls[0].Entries[?Egress==\`true\`].{Rule:RuleNumber,Protocol:Protocol,Port:PortRange,CIDR:CidrBlock,Action:RuleAction}" \
    --output table

echo "⚠️  Manually verify: inbound allows port 80, outbound allows ephemeral ports (1024-65535)"
echo "   The default NACL allows all traffic — if this is custom, check carefully."

# ============================================================
# STEP 6: Confirm security group (already stated as correct)
# ============================================================

echo ""
echo "=== Step 6: Confirming security group (sanity check) ==="

SG_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

aws ec2 describe-security-groups --group-ids $SG_ID --region $REGION \
    --query "SecurityGroups[0].IpPermissions[?ToPort==\`80\`]" --output table

# ============================================================
# STEP 7: Verify Nginx is actually running
# ============================================================

echo ""
echo "=== Step 7: Verifying Nginx via SSM ==="

aws ssm send-command --region $REGION \
    --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["systemctl is-active nginx","curl -s -o /dev/null -w \"local: %{http_code}\n\" http://localhost"]' \
    --query "Command.CommandId" --output text > /tmp/cmd_id.txt

sleep 10
CMD_ID=$(cat /tmp/cmd_id.txt)
aws ssm get-command-invocation \
    --command-id $CMD_ID --instance-id $INSTANCE_ID --region $REGION \
    --query "StandardOutputContent" --output text

# ============================================================
# STEP 8: FINAL VERIFICATION — Test from outside
# ============================================================

echo ""
echo "=== Step 8: Testing from aws-client (external network path) ==="

sleep 5
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://$PUBLIC_IP")
echo "HTTP Status: $HTTP_STATUS"

if [ "$HTTP_STATUS" == "200" ]; then
    echo "✅ SUCCESS: datacenter-ec2 is reachable on http://$PUBLIC_IP"
else
    echo "⚠️  Still not reachable — re-check NACL rules and SG rules manually"
fi

echo ""
echo "============================================"
echo "  VPC:        $VPC_ID"
echo "  IGW:        $IGW_ID (attached)"
echo "  Route Table: $RT_ID (0.0.0.0/0 → IGW)"
echo "  Instance:   $INSTANCE_ID"
echo "  Public IP:  $PUBLIC_IP"
echo "  Test URL:   http://$PUBLIC_IP"
echo "============================================"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CHECK FOR IGW ---
aws ec2 describe-internet-gateways --region $REGION \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID"

# --- CREATE + ATTACH IGW IF MISSING ---
IGW_ID=$(aws ec2 create-internet-gateway --region $REGION \
    --query "InternetGateway.InternetGatewayId" --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID \
    --vpc-id $VPC_ID --region $REGION

# --- CHECK ROUTE TABLE FOR IGW ROUTE ---
aws ec2 describe-route-tables --region $REGION \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query "RouteTables[0].Routes"

# --- ADD MISSING ROUTE ---
aws ec2 create-route --route-table-id $RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID --region $REGION

# --- CHECK INSTANCE PUBLIC IP ---
aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
    --query "Reservations[0].Instances[0].PublicIpAddress"

# --- ASSOCIATE ELASTIC IP IF MISSING ---
ALLOC_ID=$(aws ec2 allocate-address --domain vpc --region $REGION \
    --query "AllocationId" --output text)
aws ec2 associate-address --instance-id $INSTANCE_ID \
    --allocation-id $ALLOC_ID --region $REGION

# --- CHECK NACL ---
aws ec2 describe-network-acls --region $REGION \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID"

# --- TEST ---
curl http://$PUBLIC_IP
```

---

## ⚠️ Common Mistakes

**1. Stopping the investigation after confirming the security group**
The task description is explicit that the SG is already correctly configured — this is the entire point of the exercise. People who re-check the SG repeatedly without looking elsewhere waste time on a layer that's already confirmed fine. Move outward to the VPC-level components (IGW, route table) once the SG and instance-level settings are ruled out.

**2. Assuming a public IP guarantees internet connectivity**
An instance can have a perfectly valid public IPv4 address assigned and still be completely unreachable if there's no IGW attached to the VPC, or no route directing traffic to it. The public IP is necessary but not sufficient — it's just an address; it doesn't create the network path on its own.

**3. Checking the VPC's main route table when the subnet uses a different one**
If a subnet is explicitly associated with a custom route table, changes to the VPC's main route table have zero effect on that subnet. Always confirm which specific route table is associated with the subnet in question — `describe-route-tables --filters "Name=association.subnet-id,Values=..."` — rather than assuming it's the main one.

**4. Forgetting that NACLs are stateless**
Unlike security groups (which automatically allow return traffic for any permitted inbound request), NACLs require **separate explicit rules for both directions**. An inbound rule allowing port 80 doesn't automatically allow the response traffic back out — you need an outbound rule allowing the ephemeral port range (typically `1024-65535`) that the client's OS used for the connection. The default NACL handles this with an allow-all rule in both directions; a custom NACL needs both rules explicitly present.

**5. Not verifying the application is actually running, post-network-fix**
After fixing VPC-level connectivity, it's still worth confirming Nginx is actually running and listening on port 80 inside the instance. A correctly networked instance with a crashed or never-started web server will still fail the external `curl` test — for a different reason than the original VPC issue, but with an identical symptom from the outside.

---

## 🌍 Real-World Context

This exact failure mode — "security group is right, but it's still unreachable" — is one of the most common production incidents in any team's early AWS adoption, and it recurs even in mature environments whenever someone provisions infrastructure through a partial or buggy Infrastructure-as-Code template.

**Terraform/CloudFormation drift:** A common real-world cause is a Terraform module that creates a VPC and subnet but has a bug (or a deliberately incomplete example used as a starting point) where the `aws_internet_gateway` resource or the `aws_route` resource is missing or not correctly referenced. The apply succeeds without error — Terraform doesn't know your route table is "supposed to" have an internet route — and the resulting infrastructure silently has no internet path.

**The systematic debugging habit this builds:** Treating "is this reachable from the internet" as a checklist with a fixed order — IGW → route table → public IP → NACL → security group → application — rather than randomly checking things, is the difference between a 5-minute fix and an hour of guessing. This same checklist applies whether the symptom is "can't reach my EC2 instance," "can't reach my RDS instance," or "ALB returns 503" — the layers are always the same, just with different specific resources at each layer.

**VPC Reachability Analyzer:** For exactly this class of problem, AWS provides a purpose-built diagnostic tool — **VPC Reachability Analyzer** — which traces the theoretical path between a source and destination (e.g., the internet and an EC2 instance) and reports exactly which hop blocks the connection, without needing to manually walk through each layer by hand. It's worth knowing this tool exists, even though working through the manual checklist (as this task requires) builds the underlying understanding the tool's output assumes you have.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. An EC2 instance has a public IP and a security group correctly allowing port 80, but is still unreachable from the internet. What's your debugging order?**
> Work from the network edge inward, since that's the order traffic has to physically pass through. First, confirm an Internet Gateway exists and is attached to the VPC — without this, there's no internet path into the VPC at all, regardless of anything else being correct. Second, confirm the subnet's route table (specifically the one associated with that subnet, not necessarily the VPC's main route table) has a route sending `0.0.0.0/0` traffic to that IGW. Third, re-confirm the public IP is actually assigned and not just expected. Fourth, check the subnet's Network ACL for both inbound and outbound rules — NACLs are stateless and a missing outbound rule for ephemeral ports will silently drop return traffic even if everything else is correct. Only after exhausting these would I go back to re-examine the security group, and finally confirm the application itself is actually running and listening on the port inside the instance.

**Q2. Why can an EC2 instance have a public IP address but still have no internet connectivity?**
> A public IP is just an address — it doesn't by itself create a network path. For traffic to actually flow between that address and the internet, the VPC needs an Internet Gateway attached, and the specific subnet the instance lives in needs a route table entry directing internet-bound traffic to that IGW. If either of those is missing, the public IP is essentially decorative: AWS will still display it in the console, the instance "has" it in the sense that it's allocated, but no traffic can actually use it to reach the instance from outside the VPC. This is a common point of confusion because the public IP being present looks like everything should work.

**Q3. What's the difference between a VPC's main route table and a custom route table, and why does it matter for troubleshooting?**
> Every VPC has exactly one main route table, created automatically. Any subnet that isn't explicitly associated with a different route table implicitly uses the main one. When troubleshooting connectivity, this matters because someone might add the correct `0.0.0.0/0 → IGW` route to the main route table, see no improvement, and not realize the subnet in question is actually associated with a separate custom route table that doesn't have that route — or vice versa, fix the wrong one. Always explicitly check which route table is associated with the specific subnet you're troubleshooting (`describe-route-tables` filtered by `association.subnet-id`) rather than assuming.

**Q4. Why are Network ACLs more error-prone to configure correctly than Security Groups?**
> Security groups are stateful — if you allow inbound traffic on a port, the corresponding outbound response traffic is automatically permitted without needing a matching outbound rule. Network ACLs are stateless — every direction of traffic needs its own explicit rule. For a web server, this means an inbound NACL rule allowing port 80 only handles the request coming in; the response going back out uses a different, OS-assigned ephemeral port (typically in the 1024-65535 range), and without an explicit outbound rule allowing that range, the response is silently dropped, the connection from the client's perspective looks like it timed out, and there's no error to point to the NACL specifically. This statelessness is exactly why misconfigured custom NACLs are a disproportionately common source of "everything looks right but it doesn't work" tickets.

**Q5. What is AWS VPC Reachability Analyzer and how would it help with this exact scenario?**
> Reachability Analyzer is a network diagnostics tool that takes a source and destination (for example, an internet gateway and a specific EC2 instance's port) and computes the theoretical network path between them by analyzing route tables, security groups, and NACLs — without sending any actual traffic. It reports either "Reachable" or, if not, exactly which component blocks the path (a missing route, a security group rule, a NACL deny). For a scenario exactly like this task — multiple possible VPC-level causes and a need to isolate the specific one — it removes the need to manually check each layer by hand and points directly at the actual blocker, which is especially valuable in VPCs with many route tables, NACLs, and security groups where manual tracing becomes tedious.

**Q6. If both the route table and the Internet Gateway look correctly configured, what else specifically should you check at the VPC level before assuming the problem is the application itself?**
> Check whether the IGW, while present in the account, is actually attached to *this specific* VPC and not a different one — `describe-internet-gateways` shows the `Attachments` field with the VPC ID, and it's easy to have an IGW that exists but is attached elsewhere or detached entirely. Also confirm the route table's IGW route has `State: active` and not `blackhole` (which happens if the referenced IGW was deleted after the route was created, leaving a dangling reference). Finally, check whether the subnet itself is actually a "public" subnet in the sense the task assumes — confirm its CIDR doesn't overlap unexpectedly with another subnet and that `MapPublicIpOnLaunch` is set if you're relying on auto-assigned public IPs rather than an Elastic IP.

**Q7. How would you prevent this exact failure mode (correctly configured SG, broken VPC networking) from recurring across future deployments?**
> Treat VPC creation as a single atomic unit in Infrastructure as Code rather than something assembled ad-hoc — a Terraform module or CloudFormation template that always creates the VPC, IGW, IGW attachment, public route table, the `0.0.0.0/0` route, and the route table association together, so it's structurally impossible to end up with a VPC that has one piece without the others. Add a post-deployment validation step (which could literally be a scripted version of the diagnostic checklist used here, or a call to Reachability Analyzer) that runs automatically after any new public-facing resource is provisioned, failing the pipeline if the expected path isn't reachable. This shifts the failure from "discovered by a confused engineer days later" to "caught automatically before the deployment is considered complete."

---

## 📚 Resources

- [AWS Docs — VPC Internet Gateways](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html)
- [AWS Docs — Route Tables](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html)
- [AWS Docs — Network ACLs](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html)
- [AWS VPC Reachability Analyzer](https://docs.aws.amazon.com/vpc/latest/reachability/what-is-reachability-analyzer.html)
- [Day 27 — Building a Public VPC From Scratch](../day-27/README.md)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
