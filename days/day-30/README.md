# Day 30 — NAT Instance: Private Subnet Internet Access

> **#100DaysOfCloud | Day 30 of 100**

---

## 📌 The Task

> *Enable internet access for a private EC2 instance using a NAT Instance (not NAT Gateway) so it can upload files to S3. Verify by confirming the cron job's test file appears in the S3 bucket.*

**Pre-existing Resources:**
| Resource | Name | Detail |
|----------|------|--------|
| VPC | `xfusion-priv-vpc` | Custom VPC |
| Private subnet | `xfusion-priv-subnet` | No internet route |
| Private EC2 | `xfusion-priv-ec2` | Has cron job uploading to S3 |
| S3 bucket | `xfusion-nat-16441` | Target for verification |

**Tasks:**
| Task | Detail |
|------|--------|
| Public subnet | `xfusion-pub-subnet` in `xfusion-priv-vpc` |
| NAT instance | `xfusion-nat-instance` — AL2023, custom SG, NAT configured |
| Route table | Private subnet routes `0.0.0.0/0` → NAT instance |
| Verify | `xfusion-test.txt` appears in `xfusion-nat-16441` |

---

## 🧠 Core Concepts

### NAT Instance vs NAT Gateway

| | NAT Instance | NAT Gateway |
|--|-------------|------------|
| **What it is** | EC2 instance running IP masquerade | Managed AWS service |
| **Cost** | ~$0.012/hr (t2.micro) | ~$0.045/hr + data |
| **HA** | Manual (single instance = SPOF) | Built-in, multi-AZ |
| **Bandwidth** | Limited by instance type | Up to 100 Gbps |
| **Maintenance** | You manage OS, patches, iptables | Fully managed |
| **Source/dest check** | Must be **disabled** | N/A |
| **Use case** | Dev/test, cost-minimized | Production workloads |

For this task, cost minimization is the explicit requirement — NAT Instance is the correct choice.

### How a NAT Instance Works

A NAT Instance uses **IP masquerading** (network address translation) to forward traffic from private subnet instances to the internet:

```
Private EC2 (10.1.1.x)
    │  packet: src=10.1.1.5 dst=s3.amazonaws.com
    │
    ▼ (routed via route table: 0.0.0.0/0 → NAT instance ENI)
NAT Instance (public subnet, has public IP)
    │  iptables MASQUERADE rewrites: src=NAT_PUBLIC_IP dst=s3.amazonaws.com
    │
    ▼ (sent to internet via IGW)
S3 / Internet
    │  response: src=s3.amazonaws.com dst=NAT_PUBLIC_IP
    │
    ▼ (conntrack translates back: dst=10.1.1.5)
Private EC2 receives response
```

### Critical: Disable Source/Destination Check

Every EC2 network interface has a **source/destination check** enabled by default. This check drops any packet where the instance's IP isn't the source OR destination — which is exactly what happens with NAT traffic (packets are transiting through, not originating or terminating).

**You MUST disable this check on the NAT instance** or all forwarded traffic is silently dropped.

### AL2023 iptables Note

Amazon Linux 2023 uses **nftables** as the default firewall backend — `iptables` is not installed. The task explicitly notes this. You need to:
1. Install `iptables` and `iptables-services`
2. Enable IP forwarding in the kernel
3. Set up the MASQUERADE rule
4. Enable `iptables` service to persist rules across reboots

### The Complete Architecture

```
Internet
    │
    ▼ IGW (already attached to xfusion-priv-vpc)
xfusion-pub-subnet (new)
    │
    ▼ xfusion-nat-instance (public IP, source/dest check disabled)
    │ iptables MASQUERADE on eth0
    ▼
xfusion-priv-subnet (existing)
    │ route: 0.0.0.0/0 → xfusion-nat-instance ENI
    ▼
xfusion-priv-ec2 (cron job → S3 upload)
```

---

## 🔧 Step-by-Step Solution

### Full Script — Run on `aws-client`

```bash
#!/bin/bash
set -e
REGION="us-east-1"

# ============================================================
# STEP 1: Discover existing VPC and private subnet
# ============================================================

echo "=== Step 1: Discovering existing resources ==="

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=xfusion-priv-vpc" \
    --query "Vpcs[0].VpcId" --output text)

VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
    --region "$REGION" --query "Vpcs[0].CidrBlock" --output text)

PRIV_SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=tag:Name,Values=xfusion-priv-subnet" \
    --query "Subnets[0].SubnetId" --output text)

PRIV_SUBNET_CIDR=$(aws ec2 describe-subnets --subnet-ids "$PRIV_SUBNET_ID" \
    --region "$REGION" --query "Subnets[0].CidrBlock" --output text)

PRIV_SUBNET_AZ=$(aws ec2 describe-subnets --subnet-ids "$PRIV_SUBNET_ID" \
    --region "$REGION" --query "Subnets[0].AvailabilityZone" --output text)

PRIV_EC2_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=xfusion-priv-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

PRIV_EC2_IP=$(aws ec2 describe-instances --instance-ids "$PRIV_EC2_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)

echo "VPC:           $VPC_ID ($VPC_CIDR)"
echo "Private Subnet: $PRIV_SUBNET_ID ($PRIV_SUBNET_CIDR) in $PRIV_SUBNET_AZ"
echo "Private EC2:   $PRIV_EC2_ID ($PRIV_EC2_IP)"

# ============================================================
# STEP 2: Find or create Internet Gateway for the VPC
# ============================================================

echo ""
echo "=== Step 2: Checking Internet Gateway ==="

IGW_ID=$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query "InternetGateways[0].InternetGatewayId" --output text)

if [ -z "$IGW_ID" ] || [ "$IGW_ID" == "None" ]; then
    echo "No IGW found — creating one..."
    IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
        --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=xfusion-igw}]' \
        --query "InternetGateway.InternetGatewayId" --output text)
[O    aws ec2 attach-internet-gateway \
        --internet-gateway-id "$IGW_ID" \
        --vpc-id "$VPC_ID" --region "$REGION"
    echo "IGW created and attached: $IGW_ID"
else
    echo "IGW already exists: $IGW_ID"
fi

# ============================================================
# STEP 3: Create the public subnet (xfusion-pub-subnet)
# Use a non-overlapping CIDR in the same AZ as private subnet
# ============================================================

echo ""
echo "=== Step 3: Creating public subnet 'xfusion-pub-subnet' ==="

# Derive a public subnet CIDR from the private subnet CIDR
# If private is 10.x.1.0/24, use 10.x.2.0/24 for public
PUB_SUBNET_CIDR=$(echo "$PRIV_SUBNET_CIDR" | sed 's/\.1\.0/\.2\.0/')

PUB_SUBNET_ID=$(aws ec2 create-subnet \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --cidr-block "$PUB_SUBNET_CIDR" \
    --availability-zone "$PRIV_SUBNET_AZ" \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=xfusion-pub-subnet},{Key=Type,Value=Public}]' \
    --query "Subnet.SubnetId" --output text)

echo "Public subnet created: $PUB_SUBNET_ID ($PUB_SUBNET_CIDR)"

# Enable auto-assign public IP on the public subnet
aws ec2 modify-subnet-attribute \
    --subnet-id "$PUB_SUBNET_ID" \
    --map-public-ip-on-launch --region "$REGION"

echo "Auto-assign public IP enabled"

# ============================================================
# STEP 4: Create public route table and associate with pub subnet
# ============================================================

echo ""
echo "=== Step 4: Creating public route table ==="

PUB_RT_ID=$(aws ec2 create-route-table \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=xfusion-pub-rt}]' \
    --query "RouteTable.RouteTableId" --output text)

# Route all internet traffic through IGW
aws ec2 create-route \
    --route-table-id "$PUB_RT_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$IGW_ID" --region "$REGION"

# Associate public subnet with public route table
aws ec2 associate-route-table \
    --route-table-id "$PUB_RT_ID" \
    --subnet-id "$PUB_SUBNET_ID" --region "$REGION"

echo "Public route table $PUB_RT_ID created and associated"

# ============================================================
# STEP 5: Create security group for NAT instance
# Must allow outbound traffic and accept traffic from private subnet
# ============================================================

echo ""
echo "=== Step 5: Creating NAT instance security group ==="

NAT_SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name xfusion-nat-sg \
    --description "xfusion NAT instance — allow forwarded traffic from private subnet" \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=xfusion-nat-sg}]' \
    --query "GroupId" --output text)

echo "NAT SG created: $NAT_SG_ID"

# Allow ALL inbound traffic from the private subnet CIDR
# (NAT instance forwards packets originating from there)
aws ec2 authorize-security-group-ingress \
    --group-id "$NAT_SG_ID" \
    --protocol -1 \
    --port -1 \
    --cidr "$PRIV_SUBNET_CIDR" \
    --region "$REGION"

# Also allow SSH for management (your IP)
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --group-id "$NAT_SG_ID" \
    --protocol tcp --port 22 --cidr "${MY_IP}/32" \
    --region "$REGION"

echo "Inbound: all traffic from $PRIV_SUBNET_CIDR + SSH from $MY_IP"

# ============================================================
# STEP 6: Resolve latest Amazon Linux 2023 AMI
# ============================================================

echo ""
echo "=== Step 6: Resolving Amazon Linux 2023 AMI ==="

AL2023_AMI=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners amazon \
    --filters \
        "Name=name,Values=al2023-ami-2023*-x86_64" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "Amazon Linux 2023 AMI: $AL2023_AMI"

# ============================================================
# STEP 7: User Data for NAT instance
# Installs iptables, enables IP forwarding, sets up MASQUERADE
# NOTE: iptables is NOT installed by default on AL2023
# ============================================================

NAT_USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
exec >> /var/log/nat-setup.log 2>&1
echo "=== NAT setup started: $(date) ==="

# Install iptables (not default on AL2023 — uses nftables by default)
dnf install -y iptables iptables-services

# Enable IP forwarding in the kernel (immediately)
echo 1 > /proc/sys/net/ipv4/ip_forward

# Persist IP forwarding across reboots
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-nat.conf
sysctl -p /etc/sysctl.d/99-nat.conf

# Set up NAT/MASQUERADE on eth0
# This rewrites outgoing packet source IP to the NAT instance's public IP
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Allow forwarding of established/related connections back to private subnet
iptables -A FORWARD -i eth0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i eth0 -j ACCEPT

# Save rules so they survive reboots
service iptables save

# Enable iptables service to start on boot
systemctl enable iptables
systemctl start iptables

# Verify configuration
echo "=== iptables NAT rules ==="
iptables -t nat -L -v
echo "=== IP forwarding status ==="
cat /proc/sys/net/ipv4/ip_forward
echo "=== NAT setup completed: $(date) ==="
USERDATA
)

# ============================================================
# STEP 8: Launch the NAT instance in the public subnet
# ============================================================

echo ""
echo "=== Step 8: Launching NAT instance 'xfusion-nat-instance' ==="

NAT_INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AL2023_AMI" \
    --instance-type t2.micro \
    --subnet-id "$PUB_SUBNET_ID" \
    --security-group-ids "$NAT_SG_ID" \
    --associate-public-ip-address \
    --user-data "$NAT_USER_DATA" \
    --tag-specifications \
        'ResourceType=instance,Tags=[{Key=Name,Value=xfusion-nat-instance}]' \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "NAT instance launched: $NAT_INSTANCE_ID"

# ============================================================
# STEP 9: Wait for NAT instance to be running + disable source/dest check
# Source/dest check MUST be disabled for NAT to work
# ============================================================

echo ""
echo "=== Step 9: Waiting for NAT instance and disabling source/dest check ==="

aws ec2 wait instance-running \
    --instance-ids "$NAT_INSTANCE_ID" --region "$REGION"

echo "NAT instance is running"

# CRITICAL: Disable source/destination check
aws ec2 modify-instance-attribute \
    --instance-id "$NAT_INSTANCE_ID" \
    --no-source-dest-check \
    --region "$REGION"

echo "Source/destination check DISABLED on $NAT_INSTANCE_ID"

# Verify it's disabled
aws ec2 describe-instances \
    --instance-ids "$NAT_INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].NetworkInterfaces[0].SourceDestCheck" \
    --output text

NAT_PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$NAT_INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

NAT_ENI_ID=$(aws ec2 describe-instances \
    --instance-ids "$NAT_INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId" \
    --output text)

echo "NAT instance public IP: $NAT_PUBLIC_IP"
echo "NAT instance ENI: $NAT_ENI_ID"

# ============================================================
# STEP 10: Update private subnet route table
# Route all outbound traffic from private subnet → NAT instance
# ============================================================

echo ""
echo "=== Step 10: Updating private subnet route table ==="

# Find the route table associated with the private subnet
PRIV_RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=association.subnet-id,Values=${PRIV_SUBNET_ID}" \
    --query "RouteTables[0].RouteTableId" --output text)

# If no explicit association, use main route table
if [ -z "$PRIV_RT_ID" ] || [ "$PRIV_RT_ID" == "None" ]; then
    PRIV_RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.main,Values=true" \
        --query "RouteTables[0].RouteTableId" --output text)
    echo "Using VPC main route table: $PRIV_RT_ID"
else
    echo "Private subnet route table: $PRIV_RT_ID"
fi

# Add default route pointing to NAT instance (via ENI)
aws ec2 create-route \
    --route-table-id "$PRIV_RT_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --instance-id "$NAT_INSTANCE_ID" \
    --region "$REGION"

echo "Route added: 0.0.0.0/0 → $NAT_INSTANCE_ID"

# ============================================================
# STEP 11: Wait for NAT User Data to complete and verify
# ============================================================

echo ""
echo "=== Step 11: Waiting for NAT setup to complete (60s) ==="
sleep 60

echo "=== Verifying private subnet route table ==="
aws ec2 describe-route-tables \
    --route-table-ids "$PRIV_RT_ID" --region "$REGION" \
    --query "RouteTables[0].Routes[*].{Dest:DestinationCidrBlock,Target:InstanceId,State:State}" \
    --output table

echo ""
echo "============================================"
echo "  VPC:           xfusion-priv-vpc ($VPC_ID)"
echo "  Public Subnet: xfusion-pub-subnet ($PUB_SUBNET_ID)"
echo "  NAT Instance:  xfusion-nat-instance ($NAT_INSTANCE_ID)"
echo "  NAT Public IP: $NAT_PUBLIC_IP"
echo "  NAT SG:        xfusion-nat-sg ($NAT_SG_ID)"
echo "  Private RT:    $PRIV_RT_ID"
echo ""
echo "  Monitoring S3 for test file..."
echo "  aws s3 ls s3://xfusion-nat-16441"
echo "============================================"

# ============================================================
# STEP 12: Verify test file appears in S3 bucket
# ============================================================

echo ""
echo "=== Step 12: Waiting for xfusion-test.txt in S3 (cron runs every minute) ==="

for i in 1 2 3 4 5; do
    echo "Check $i/5..."
    RESULT=$(aws s3 ls s3://xfusion-nat-16441 2>/dev/null | grep "xfusion-test.txt" || echo "")

    if [ -n "$RESULT" ]; then
        echo "✅ SUCCESS: xfusion-test.txt found in S3!"
        echo "$RESULT"
        break
    fi

    echo "File not yet present — waiting 30 seconds..."
    sleep 30
done

if [ -z "$RESULT" ]; then
    echo "⚠️  File not found yet. Check NAT instance setup:"
    echo "  1. Verify source/dest check is disabled:"
    echo "     aws ec2 describe-instances --instance-ids $NAT_INSTANCE_ID \\"
    echo "       --query 'Reservations[0].Instances[0].NetworkInterfaces[0].SourceDestCheck'"
    echo "  2. Check NAT setup log:"
    echo "     ssh ec2-user@$NAT_PUBLIC_IP 'cat /var/log/nat-setup.log'"
    echo "  3. Verify iptables rules:"
    echo "     ssh ec2-user@$NAT_PUBLIC_IP 'sudo iptables -t nat -L -v'"
fi
```

---

### Verifying the NAT Setup Manually

```bash
# SSH into NAT instance and verify iptables
ssh -i /root/.ssh/id_rsa ec2-user@$NAT_PUBLIC_IP

# Inside NAT instance:
sudo cat /var/log/nat-setup.log       # User Data execution log
sudo iptables -t nat -L -v            # Should show MASQUERADE rule
cat /proc/sys/net/ipv4/ip_forward     # Should return: 1
sudo iptables -L FORWARD -v           # Should show ACCEPT rules

# Check if S3 file exists
aws s3 ls s3://xfusion-nat-16441
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CREATE PUBLIC SUBNET ---
PUB_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID \
    --cidr-block 10.x.2.0/24 --availability-zone us-east-1a \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=xfusion-pub-subnet}]' \
    --region $REGION --query "Subnet.SubnetId" --output text)

aws ec2 modify-subnet-attribute \
    --subnet-id $PUB_SUBNET_ID --map-public-ip-on-launch --region $REGION

# --- CREATE NAT SG (allow traffic from private subnet) ---
NAT_SG_ID=$(aws ec2 create-security-group \
    --group-name xfusion-nat-sg --vpc-id $VPC_ID \
    --description "NAT instance SG" --region $REGION \
    --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress --group-id $NAT_SG_ID \
    --protocol -1 --port -1 --cidr $PRIV_SUBNET_CIDR --region $REGION

# --- LAUNCH NAT INSTANCE ---
NAT_INSTANCE_ID=$(aws ec2 run-instances --region $REGION \
    --image-id $AL2023_AMI --instance-type t2.micro \
    --subnet-id $PUB_SUBNET_ID --security-group-ids $NAT_SG_ID \
    --associate-public-ip-address --user-data file:///tmp/nat-userdata.sh \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=xfusion-nat-instance}]' \
    --query "Instances[0].InstanceId" --output text)

aws ec2 wait instance-running --instance-ids $NAT_INSTANCE_ID --region $REGION

# --- CRITICAL: DISABLE SOURCE/DEST CHECK ---
aws ec2 modify-instance-attribute \
    --instance-id $NAT_INSTANCE_ID --no-source-dest-check --region $REGION

# --- UPDATE PRIVATE ROUTE TABLE ---
aws ec2 create-route --route-table-id $PRIV_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --instance-id $NAT_INSTANCE_ID --region $REGION

# --- VERIFY S3 ---
aws s3 ls s3://xfusion-nat-16441
```

---

## ⚠️ Common Mistakes

**1. Not disabling source/destination check — the #1 failure**
Every EC2 ENI validates that packets it receives are addressed to it, and packets it sends originate from it. NAT traffic violates both — the NAT instance receives packets from private IPs and forwards them. Without disabling this check, all forwarded traffic is silently dropped at the hypervisor level. This is the single most common NAT instance failure and leaves no error message — traffic just disappears.

**2. iptables not installed on AL2023**
Amazon Linux 2023 ships with nftables as the backend. `iptables` is a compatibility shim that must be explicitly installed with `dnf install -y iptables iptables-services`. The task explicitly warns about this. Attempting to run iptables commands without the package installed fails with "command not found."

**3. IP forwarding not enabled**
Even with iptables configured, the Linux kernel won't forward packets between interfaces unless `net.ipv4.ip_forward=1` is set. The `/proc/sys/net/ipv4/ip_forward` must be `1`. The User Data sets this both immediately (`echo 1 > /proc/sys/net/ipv4/ip_forward`) and persistently via `sysctl.d`.

**4. Routing to the instance ID vs ENI ID**
When adding the NAT route to the private subnet route table, you can target the instance ID (`--instance-id`) or the ENI ID (`--network-interface-id`). Both work, but the ENI ID is more stable — instance IDs change if you replace the NAT instance, while ENI IDs can remain constant if you keep the same ENI.

**5. Private subnet route table not found**
Some setups have the private subnet using the VPC's main route table (no explicit association). Always check both: the subnet-associated route table and the main route table as a fallback. The script handles this.

**6. NAT Security Group not allowing all traffic from private subnet**
The NAT instance's SG must accept inbound traffic from the private subnet CIDR — not just SSH. Using port-specific rules misses the variety of traffic the private EC2 sends (HTTPS to S3, DNS, etc.). Allow all protocols from `PRIV_SUBNET_CIDR`.

---

## 🌍 Real-World Context

NAT Instances are the budget alternative to NAT Gateway for non-production or cost-sensitive environments. The comparison is stark: NAT Gateway costs ~$0.045/hr + $0.045/GB data processed; a t2.micro NAT Instance costs ~$0.012/hr with no data processing charge. For a dev environment processing 100 GB/month, NAT Gateway costs ~$36/month vs NAT Instance at ~$9/month.

The operational trade-off: NAT Gateway is managed, HA, and scales automatically. A NAT Instance requires monitoring, patching, HA design (multiple instances behind a health check, ENI reassignment on failure), and periodic AMI updates. For production internet-access needs, NAT Gateway is almost always the right choice. For dev/test or cost-constrained workloads, a well-configured NAT Instance serves perfectly well.

In Terraform, both are expressible — `aws_nat_gateway` vs `aws_instance` with `source_dest_check = false` and a userdata script. The route entry uses `instance_id` for a NAT instance vs `nat_gateway_id` for a NAT Gateway.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is a NAT instance and how does it differ from a NAT Gateway?**

> Both provide outbound internet access for private subnet resources. A NAT instance is an EC2 instance you launch and configure with IP masquerading (iptables MASQUERADE) — you're responsible for the OS, iptables rules, IP forwarding, instance health, scaling, and patching. A NAT Gateway is a fully managed AWS service that's highly available within an AZ, scales automatically, requires no OS management, and processes up to 100 Gbps. NAT Gateway costs about 3-4x more than a comparably-sized NAT instance, which is why budget-constrained dev environments often use NAT instances. For production workloads where HA and operational simplicity matter, NAT Gateway is the standard recommendation.

---

**Q2. What is the source/destination check on an EC2 instance and why must it be disabled on a NAT instance?**

> Every EC2 network interface has a source/destination check that validates inbound packets are addressed to the instance's IP, and outbound packets originate from it. This is the correct behaviour for normal instances — they should only process traffic destined for them. A NAT instance, by design, receives packets from private subnet IPs (not its own IP) and forwards them to the internet with a rewritten source address. Both the inbound check (packet isn't addressed to the NAT instance's IP) and the outbound check (packet doesn't originate from the NAT instance's IP) would fail. Disabling the check tells the hypervisor to pass all packets regardless of IP ownership, allowing the NAT forwarding to work.

---

**Q3. Explain the iptables MASQUERADE rule and how it enables NAT.**

> `iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE` sets up dynamic source NAT. When a packet leaving through `eth0` is processed by this rule, iptables replaces the source IP (e.g., `10.1.1.5`) with the outbound interface's current IP address (the NAT instance's public IP). The connection is tracked in conntrack so that when the response arrives (addressed to the NAT instance's public IP), iptables translates the destination back to the original private IP and forwards it to the private instance. MASQUERADE is a special form of SNAT (source NAT) that automatically uses the interface's current IP — useful when the public IP changes (like with dynamic IPs), unlike static SNAT which requires hardcoding the IP.

---

**Q4. The private EC2 instance still can't reach the internet after setting up the NAT instance. Walk me through your debugging steps.**

> In order. First, confirm `SourceDestCheck` is false on the NAT instance — `describe-instances` and check the NetworkInterfaces field. Second, verify the private subnet's route table has `0.0.0.0/0 → nat-instance-id` — `describe-route-tables`. Third, SSH into the NAT instance and check: `cat /proc/sys/net/ipv4/ip_forward` should return `1`, and `iptables -t nat -L -v` should show the MASQUERADE rule. Fourth, check the NAT instance's security group allows all traffic from the private subnet CIDR. Fifth, from the NAT instance, verify it can reach the internet itself (`curl https://aws.amazon.com`) — if it can't, the issue is with the public subnet route table or IGW. Sixth, check the private EC2's security group has outbound rules allowing the traffic (default is allow-all outbound, but confirm).

---

**Q5. How would you make a NAT instance highly available?**

> A single NAT instance is a single point of failure. HA approaches in order of complexity: First, use CloudWatch to monitor the NAT instance and trigger an Auto Recovery action (re-launches the instance on the same ENI using the instance attribute `--no-source-dest-check`). Second, put the NAT instance in an Auto Scaling Group with min=1 — if it fails, ASG replaces it (but route table update needs automation). Third, use two NAT instances in different AZs, each with their own Elastic IP, and update the private subnet route tables in each AZ to point to the NAT instance in the same AZ. Use a Lambda + CloudWatch alarm to reroute traffic if one NAT fails. The honest answer for production: none of these are as simple or reliable as NAT Gateway's built-in HA. NAT Gateway should be used in production; NAT instances in dev/test.

---

**Q6. What is the difference between routing to a NAT instance by instance ID vs by ENI ID in a route table?**

> Both work, but the ENI (Elastic Network Interface) approach is more durable. Route tables support targeting by instance ID or network interface ID. If you target by instance ID and the instance is terminated and replaced (e.g., during HA failover), the route becomes invalid until updated. If you allocate a standalone ENI, disable source/dest check on the ENI, and always attach that ENI to whichever NAT instance is running, routing by ENI ID remains valid regardless of which instance the ENI is on. This is the basis of ENI-based NAT instance failover — the route never changes, only the underlying instance does.

---

**Q7. A NAT Gateway costs $0.045/hr + $0.045/GB data processed. A t2.micro NAT instance costs $0.012/hr with no data processing charge. At what monthly data transfer volume does NAT Gateway become the same cost as a NAT Instance?**

> Monthly fixed cost: NAT Gateway = $0.045 × 24 × 30 = $32.40/month. NAT Instance = $0.012 × 24 × 30 = $8.64/month. The NAT Gateway is already $23.76/month more expensive before any data transfer. To break even purely on cost, data transfer would need to be negative — it never gets cheaper. But the real comparison includes NAT Instance operational costs: instance monitoring, patching, on-call time if it fails, and engineering time to build HA. If your operations team values 2 hours of their time at $50/hr, one NAT instance failure that takes 2 hours to resolve costs $100 — wiping out 4+ months of cost savings vs NAT Gateway. The correct answer is: NAT instances are cheaper in direct billing; NAT Gateway is cheaper in total cost of ownership for production workloads.

---

## 📚 Resources

- [AWS Docs — NAT Instances](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_NAT_Instance.html)
- [AWS Docs — NAT Gateways](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html)
- [iptables MASQUERADE explanation](https://www.netfilter.org/documentation/HOWTO/NAT-HOWTO.html)
- [Amazon Linux 2023 — nftables vs iptables](https://docs.aws.amazon.com/linux/al2023/ug/filtering-network-traffic-with-nftables.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
