# Day 29 — VPC Peering: Connect Default VPC to Private VPC

> **#100DaysOfCloud | Day 29 of 100**

---

## 📌 The Task

> *Establish a VPC Peering connection between the default public VPC and a private VPC, configure route tables to enable routing between them, and verify end-to-end connectivity by pinging the private EC2 instance from the public EC2 instance.*

**Pre-existing Resources:**
| Resource | Name | CIDR / Detail |
|----------|------|--------------|
| Public EC2 instance | `datacenter-public-ec2` | In default VPC |
| Private VPC | `datacenter-private-vpc` | `10.1.0.0/16` |
| Private Subnet | `datacenter-private-subnet` | `10.1.1.0/24` |
| Private EC2 instance | `datacenter-private-ec2` | In private VPC |

**Tasks:**
| Task | Detail |
|------|--------|
| VPC Peering | `datacenter-vpc-peering` — default VPC ↔ datacenter-private-vpc |
| Route tables | Configure both sides to route traffic through the peering connection |
| SSH access | Add `aws-client`'s public key to `datacenter-public-ec2` |
| Connectivity test | SSH to public EC2 → ping private EC2 |

---

## 🧠 Core Concepts

### What Is VPC Peering?

**VPC Peering** is a networking connection between two VPCs that allows them to route traffic between each other using private IPv4 addresses — as if the instances were in the same network. Traffic between peered VPCs never traverses the public internet; it stays on the AWS backbone network.

Key characteristics:
- **One-to-one**: Each peering connection links exactly two VPCs
- **Non-transitive**: If VPC-A peers with VPC-B, and VPC-B peers with VPC-C, VPC-A **cannot** reach VPC-C through VPC-B
- **Cross-account and cross-region**: Peering works across AWS accounts and regions
- **No bandwidth bottleneck**: The connection uses AWS's internal network — not a gateway device
- **No single point of failure**: There's no VPC Peering gateway device to fail

### The Non-Transitive Routing Rule

This is the most important concept to understand about VPC Peering:

```
VPC-A ←→ VPC-B ←→ VPC-C

VPC-A CANNOT reach VPC-C via VPC-B
Each pair requires its own peering connection
```

If you need hub-and-spoke routing between many VPCs, **AWS Transit Gateway** is the correct solution — it handles transitive routing.

### The Five Steps to Working VPC Peering

VPC Peering requires more than just creating the connection:

```
1. Create peering connection request (Requester VPC → Accepter VPC)
        ↓
2. Accept the peering connection (Accepter side)
        ↓
3. Update requester's route table (add route: accepter CIDR → pcx-xxx)
        ↓
4. Update accepter's route table (add route: requester CIDR → pcx-xxx)
        ↓
5. Update security groups to allow traffic from the peer VPC's CIDR
```

**Missing any of these five steps causes connectivity failure.** The most commonly missed are steps 3, 4 (both route table updates needed), and 5 (security group updates).

### Route Table Updates — Both Sides Required

This is the #1 mistake in VPC Peering setups: updating only one side's route table.

| Route Table | Route To Add |
|-------------|-------------|
| Default VPC's route table | `10.1.0.0/16` → `pcx-xxxxxxxx` |
| Private VPC's route table | `172.31.0.0/16` (default VPC CIDR) → `pcx-xxxxxxxx` |

Without both routes, traffic is one-directional at best, and usually neither direction works because return traffic has no route.

### Security Group Rules for ICMP (Ping)

Ping uses ICMP protocol. By default, security groups don't allow ICMP. To enable ping from the public VPC to the private EC2 instance:

- **Private EC2's security group**: Allow ICMP (type -1 = all ICMP) from the **default VPC CIDR** (typically `172.31.0.0/16`)

### SSH Key Injection for the Public EC2

To SSH from `aws-client` → `datacenter-public-ec2`, the `aws-client`'s public key (`/root/.ssh/id_rsa.pub`) needs to be in `datacenter-public-ec2`'s `ec2-user`'s `~/.ssh/authorized_keys`. This is the same pattern covered on Day 22.

---

## 🔧 Step-by-Step Solution

### Full Script — Run on `aws-client`

```bash
#!/bin/bash
set -e
REGION="us-east-1"

# ============================================================
# STEP 1: Discover existing resource IDs
# ============================================================

echo "=== Step 1: Discovering existing resources ==="

# Default VPC
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

DEFAULT_VPC_CIDR=$(aws ec2 describe-vpcs \
    --vpc-ids "$DEFAULT_VPC_ID" --region "$REGION" \
    --query "Vpcs[0].CidrBlock" --output text)

echo "Default VPC: $DEFAULT_VPC_ID | CIDR: $DEFAULT_VPC_CIDR"

# Private VPC
PRIVATE_VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=datacenter-private-vpc" \
    --query "Vpcs[0].VpcId" --output text)

PRIVATE_VPC_CIDR=$(aws ec2 describe-vpcs \
    --vpc-ids "$PRIVATE_VPC_ID" --region "$REGION" \
    --query "Vpcs[0].CidrBlock" --output text)

echo "Private VPC: $PRIVATE_VPC_ID | CIDR: $PRIVATE_VPC_CIDR"

# Public EC2 instance
PUBLIC_EC2_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=datacenter-public-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

PUBLIC_EC2_IP=$(aws ec2 describe-instances --instance-ids "$PUBLIC_EC2_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

PUBLIC_EC2_PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids "$PUBLIC_EC2_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)

echo "Public EC2: $PUBLIC_EC2_ID | Public IP: $PUBLIC_EC2_IP | Private IP: $PUBLIC_EC2_PRIVATE_IP"

# Private EC2 instance
PRIVATE_EC2_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=datacenter-private-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

PRIVATE_EC2_IP=$(aws ec2 describe-instances --instance-ids "$PRIVATE_EC2_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)

PRIVATE_EC2_SG=$(aws ec2 describe-instances \
    --instance-ids "$PRIVATE_EC2_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

echo "Private EC2: $PRIVATE_EC2_ID | Private IP: $PRIVATE_EC2_IP | SG: $PRIVATE_EC2_SG"

# ============================================================
# STEP 2: Create the VPC Peering Connection
# ============================================================

echo ""
echo "=== Step 2: Creating VPC Peering Connection ==="

PCX_ID=$(aws ec2 create-vpc-peering-connection \
    --region "$REGION" \
    --vpc-id "$DEFAULT_VPC_ID" \
    --peer-vpc-id "$PRIVATE_VPC_ID" \
    --tag-specifications \
        'ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=datacenter-vpc-peering}]' \
    --query "VpcPeeringConnection.VpcPeeringConnectionId" \
    --output text)

echo "Peering Connection created: $PCX_ID"

# ============================================================
# STEP 3: Accept the Peering Connection
[O# (Same account — can accept immediately)
# ============================================================

echo ""
echo "=== Step 3: Accepting Peering Connection ==="

aws ec2 accept-vpc-peering-connection \
    --vpc-peering-connection-id "$PCX_ID" \
    --region "$REGION"

echo "Peering connection $PCX_ID accepted"

# Wait for peering to be active
echo "Waiting for peering connection to become active..."
aws ec2 wait vpc-peering-connection-exists \
    --filters "Name=status-code,Values=active" \
    --vpc-peering-connection-ids "$PCX_ID" \
    --region "$REGION" 2>/dev/null || sleep 5

# Verify peering status
aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids "$PCX_ID" --region "$REGION" \
    --query "VpcPeeringConnections[0].{ID:VpcPeeringConnectionId,Status:Status.Code,RequesterCIDR:RequesterVpcInfo.CidrBlock,AccepterCIDR:AccepterVpcInfo.CidrBlock}" \
    --output table

# ============================================================
# STEP 4: Update Default VPC's route table
# Add route: private VPC CIDR → peering connection
# ============================================================

echo ""
echo "=== Step 4: Updating Default VPC route table ==="

# Get the main route table of the default VPC
DEFAULT_RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=${DEFAULT_VPC_ID}" \
               "Name=association.main,Values=true" \
    --query "RouteTables[0].RouteTableId" --output text)

echo "Default VPC main route table: $DEFAULT_RT_ID"

# Add route to private VPC via peering connection
aws ec2 create-route \
    --route-table-id "$DEFAULT_RT_ID" \
    --destination-cidr-block "$PRIVATE_VPC_CIDR" \
    --vpc-peering-connection-id "$PCX_ID" \
    --region "$REGION"

echo "Route added: $PRIVATE_VPC_CIDR → $PCX_ID in $DEFAULT_RT_ID"

# ============================================================
# STEP 5: Update Private VPC's route table
# Add route: default VPC CIDR → peering connection
# ============================================================

echo ""
echo "=== Step 5: Updating Private VPC route table ==="

# Get the main route table of the private VPC
PRIVATE_RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=${PRIVATE_VPC_ID}" \
               "Name=association.main,Values=true" \
    --query "RouteTables[0].RouteTableId" --output text)

echo "Private VPC main route table: $PRIVATE_RT_ID"

# Add route back to default VPC via peering connection
aws ec2 create-route \
    --route-table-id "$PRIVATE_RT_ID" \
    --destination-cidr-block "$DEFAULT_VPC_CIDR" \
    --vpc-peering-connection-id "$PCX_ID" \
    --region "$REGION"

echo "Route added: $DEFAULT_VPC_CIDR → $PCX_ID in $PRIVATE_RT_ID"

# ============================================================
# STEP 6: Update Private EC2 Security Group
# Allow ICMP from the default VPC CIDR (enables ping)
# ============================================================

echo ""
echo "=== Step 6: Updating private EC2 security group for ICMP ==="

aws ec2 authorize-security-group-ingress \
    --group-id "$PRIVATE_EC2_SG" \
    --region "$REGION" \
    --protocol icmp \
    --port -1 \
    --cidr "$DEFAULT_VPC_CIDR"

echo "ICMP allowed from $DEFAULT_VPC_CIDR on $PRIVATE_EC2_SG"

# ============================================================
# STEP 7: Inject ssh public key into public EC2's authorized_keys
# ============================================================

echo ""
echo "=== Step 7: Injecting aws-client SSH public key into public EC2 ==="

# Ensure key exists on aws-client
if [ ! -f /root/.ssh/id_rsa ]; then
    echo "Generating SSH key on aws-client..."
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -C "root@aws-client"
fi

PUB_KEY=$(cat /root/.ssh/id_rsa.pub)
echo "Public key: $PUB_KEY"

# Get the public EC2's security group and allow SSH from aws-client
PUBLIC_EC2_SG=$(aws ec2 describe-instances \
    --instance-ids "$PUBLIC_EC2_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

MY_IP=$(curl -s https://checkip.amazonaws.com)

echo "Adding SSH rule for $MY_IP/32 on public EC2's SG $PUBLIC_EC2_SG..."
aws ec2 authorize-security-group-ingress \
    --group-id "$PUBLIC_EC2_SG" \
    --protocol tcp --port 22 --cidr "${MY_IP}/32" \
    --region "$REGION" 2>/dev/null || echo "SSH rule may already exist — continuing"

# Use Systems Manager to inject the key (if SSM agent available)
# Otherwise, use the instance's existing key to SSH in and inject

# Attempt injection via SSM Session Manager
echo "Injecting public key via SSM..."
aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$PUBLIC_EC2_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[
        'mkdir -p /home/ec2-user/.ssh',
        'chmod 700 /home/ec2-user/.ssh',
        'echo \"${PUB_KEY}\" >> /home/ec2-user/.ssh/authorized_keys',
        'chmod 600 /home/ec2-user/.ssh/authorized_keys',
        'chown -R ec2-user:ec2-user /home/ec2-user/.ssh'
    ]" \
    --output text > /dev/null 2>&1 \
    && echo "Key injected via SSM" \
    || echo "SSM injection failed — inject key manually via User Data or existing key"

# ============================================================
# STEP 8: Verify everything and test connectivity
# ============================================================

echo ""
echo "=== Step 8: Verification ==="

echo "--- Peering Connection ---"
aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids "$PCX_ID" --region "$REGION" \
    --query "VpcPeeringConnections[0].{Name:Tags[?Key=='Name']|[0].Value,ID:VpcPeeringConnectionId,Status:Status.Code}" \
    --output table

echo ""
echo "--- Default VPC Routes ---"
aws ec2 describe-route-tables \
    --route-table-ids "$DEFAULT_RT_ID" --region "$REGION" \
    --query "RouteTables[0].Routes[?VpcPeeringConnectionId!=null].{Destination:DestinationCidrBlock,PeeringConnection:VpcPeeringConnectionId,State:State}" \
    --output table

echo ""
echo "--- Private VPC Routes ---"
aws ec2 describe-route-tables \
    --route-table-ids "$PRIVATE_RT_ID" --region "$REGION" \
    --query "RouteTables[0].Routes[?VpcPeeringConnectionId!=null].{Destination:DestinationCidrBlock,PeeringConnection:VpcPeeringConnectionId,State:State}" \
    --output table

echo ""
echo "============================================"
echo "  Peering:          datacenter-vpc-peering ($PCX_ID)"
echo "  Default VPC:      $DEFAULT_VPC_ID ($DEFAULT_VPC_CIDR)"
echo "  Private VPC:      $PRIVATE_VPC_ID ($PRIVATE_VPC_CIDR)"
echo "  Public EC2 IP:    $PUBLIC_EC2_IP"
echo "  Private EC2 IP:   $PRIVATE_EC2_IP"
echo ""
echo "  SSH test:"
echo "    ssh -i /root/.ssh/id_rsa ec2-user@$PUBLIC_EC2_IP"
echo "  Ping test (from public EC2):"
echo "    ping -c 4 $PRIVATE_EC2_IP"
echo "============================================"

# ============================================================
# STEP 9: End-to-end connectivity test
# ============================================================

echo ""
echo "=== Step 9: End-to-end ping test (aws-client → public EC2 → private EC2) ==="

sleep 15   # Allow SSM command to complete and sshd to process key

ssh -i /root/.ssh/id_rsa \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    ec2-user@"$PUBLIC_EC2_IP" \
    "ping -c 4 $PRIVATE_EC2_IP" \
    && echo "✅ Ping from public EC2 to private EC2 SUCCESSFUL" \
    || echo "⚠️  Ping failed — check security groups and route tables"
```

---

### Manual Route Table Updates (If Main RT Has Subnet-Specific Associations)

```bash
# If the private VPC subnet uses its own route table (not main):
PRIVATE_SUBNET_RT=$(aws ec2 describe-route-tables --region us-east-1 \
    --filters "Name=association.subnet-id,Values=${PRIVATE_SUBNET_ID}" \
    --query "RouteTables[0].RouteTableId" --output text)

aws ec2 create-route \
    --route-table-id "$PRIVATE_SUBNET_RT" \
    --destination-cidr-block "$DEFAULT_VPC_CIDR" \
    --vpc-peering-connection-id "$PCX_ID" \
    --region us-east-1
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CREATE PEERING ---
PCX_ID=$(aws ec2 create-vpc-peering-connection \
    --vpc-id $DEFAULT_VPC_ID --peer-vpc-id $PRIVATE_VPC_ID \
    --tag-specifications 'ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=datacenter-vpc-peering}]' \
    --region $REGION --query "VpcPeeringConnection.VpcPeeringConnectionId" --output text)

# --- ACCEPT PEERING ---
aws ec2 accept-vpc-peering-connection \
    --vpc-peering-connection-id $PCX_ID --region $REGION

# --- ADD ROUTES (both sides) ---
aws ec2 create-route --route-table-id $DEFAULT_RT_ID \
    --destination-cidr-block $PRIVATE_VPC_CIDR \
    --vpc-peering-connection-id $PCX_ID --region $REGION

aws ec2 create-route --route-table-id $PRIVATE_RT_ID \
    --destination-cidr-block $DEFAULT_VPC_CIDR \
    --vpc-peering-connection-id $PCX_ID --region $REGION

# --- ALLOW ICMP ON PRIVATE EC2 SG ---
aws ec2 authorize-security-group-ingress \
    --group-id $PRIVATE_EC2_SG --protocol icmp --port -1 \
    --cidr $DEFAULT_VPC_CIDR --region $REGION

# --- VERIFY PEERING STATUS ---
aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids $PCX_ID --region $REGION \
    --query "VpcPeeringConnections[0].{Status:Status.Code,Requester:RequesterVpcInfo.CidrBlock,Accepter:AccepterVpcInfo.CidrBlock}"

# --- VERIFY ROUTES ---
aws ec2 describe-route-tables --route-table-ids $DEFAULT_RT_ID --region $REGION \
    --query "RouteTables[0].Routes[*].{Dest:DestinationCidrBlock,Target:VpcPeeringConnectionId}"

# --- SSH + PING TEST ---
ssh -i /root/.ssh/id_rsa ec2-user@$PUBLIC_EC2_IP "ping -c 4 $PRIVATE_EC2_IP"

# --- DELETE PEERING (cleanup) ---
aws ec2 delete-vpc-peering-connection \
    --vpc-peering-connection-id $PCX_ID --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Only updating one side's route table**
This is the single most common VPC peering failure. Both the requester VPC's route table AND the accepter VPC's route table must have routes pointing to the peering connection. Without the return route, traffic goes one way but responses have no path back — the connection appears broken in both directions.

**2. Forgetting to accept the peering connection**
A peering connection starts in `pending-acceptance` state. Until it's accepted, no traffic flows. For same-account peering, acceptance is immediate via CLI. For cross-account peering, the accepting account must log in and explicitly accept. The connection expires after 7 days if not accepted.

**3. Not updating security groups to allow cross-VPC traffic**
The route tables allow routing between the VPCs, but security groups control which protocols reach each instance. Even with perfect routing, ping fails if the private EC2's SG doesn't allow ICMP from the requester VPC's CIDR. Security group rules must use the peer VPC's CIDR range as the source — not the specific instance IP.

**4. Overlapping CIDR blocks between peered VPCs**
VPC Peering requires non-overlapping CIDR blocks. If both VPCs use `10.0.0.0/16`, the peering creation fails because AWS can't determine which VPC owns which IP address. Always design VPC CIDRs to be unique across all VPCs you might peer.

**5. Expecting transitive routing to work**
If VPC-A peers with VPC-B, and VPC-B peers with VPC-C, instances in VPC-A cannot reach VPC-C. Routing is not transitive in VPC peering. For full mesh connectivity between many VPCs, each pair needs its own peering connection. At scale, AWS Transit Gateway is the correct solution.

**6. Using the main route table for the private VPC without checking subnet associations**
If the private VPC's subnet uses a custom route table (not the main route table), adding the route to the main route table has no effect for that subnet. Always check which route table is actually associated with the target subnet before adding routes.

---

## 🌍 Real-World Context

VPC Peering is the foundational multi-VPC connectivity pattern in AWS. Real-world scenarios:

**Centralized services VPC:** A "shared services" VPC hosts DNS, Active Directory, monitoring, logging, and CI/CD tools. Application VPCs peer with the shared services VPC to access these tools without duplicating them. This is the hub-and-spoke pattern before Transit Gateway.

**Dev/Staging/Prod isolation with shared access:** Each environment has its own VPC for isolation (a prod security incident doesn't affect dev). A management VPC peers with all three for operations access (Ansible, monitoring agents, log forwarders). Only the management VPC can reach the production VPC.

**Database tier isolation:** A dedicated RDS VPC with peering to application VPCs. The database VPC's security groups only allow traffic from the specific application VPC CIDRs — no direct internet access, no other VPC access. This provides a strong isolation boundary for sensitive data.

**At scale — when to switch to Transit Gateway:** VPC Peering scales poorly past ~10 VPCs because it requires N*(N-1)/2 peering connections for full mesh. Ten VPCs need 45 peering connections; each adds management overhead. AWS Transit Gateway provides centralized hub-and-spoke routing where each VPC only attaches once to the TGW, and the TGW handles routing between all of them — including transitive routing that VPC Peering can't provide.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is VPC Peering and what are its fundamental limitations?**

> VPC Peering is a private networking connection between two VPCs that routes traffic using private IPs on AWS's backbone — no internet exposure. The key limitations: it's **non-transitive** (VPC-A can't reach VPC-C through VPC-B — requires a direct peering per pair), requires **non-overlapping CIDRs** (can't peer VPCs with the same address space), scales poorly (N VPCs need N*(N-1)/2 connections for full mesh), and provides no routing policy controls beyond route table entries. For up to ~10 VPCs, peering is practical. Beyond that, the management overhead is significant and Transit Gateway is the right tool.

---

**Q2. You set up a VPC Peering connection and both VPCs show status `active`, but instances can't communicate. What do you check?**

> Three layers, in order. First, **route tables** — both VPCs' route tables must have routes pointing to the peering connection ID for the peer's CIDR. The most common miss is only updating one side. Second, **security groups** — the instances' security groups must allow the specific protocol from the peer VPC's CIDR. Routing being correct doesn't override security group denies. For ping, ICMP must be explicitly allowed; for SSH, port 22 must be open. Third, **Network ACLs** — if custom NACLs are in use (the default NACL allows all), they might be blocking traffic at the subnet boundary. NACLs are stateless — both inbound and outbound rules for each direction of traffic need to be present.

---

**Q3. What is the difference between VPC Peering and AWS Transit Gateway?**

> VPC Peering is a direct, point-to-point private connection between two VPCs — simple, low-latency, no additional cost beyond data transfer. It doesn't support transitive routing (A → B → C doesn't work). Transit Gateway is a managed regional hub that acts as a central router: each VPC, VPN, and Direct Connect attachment connects to the TGW once, and the TGW handles routing between all of them — including transitive routing. TGW supports thousands of VPC attachments, route table isolation (segment traffic between environment tiers), and centralized network policy. The trade-off: TGW has hourly attachment costs and data processing charges. Use peering for simple, small-scale multi-VPC connectivity; use TGW for large, complex, or growing multi-VPC networks.

---

**Q4. A VPC Peering connection request has been in `pending-acceptance` state for 2 days. What should you do?**

> A peering request expires after **7 days** if not accepted. If you're within that window, log into the accepting account and accept it via the console (VPC → Peering Connections → Actions → Accept) or CLI (`accept-vpc-peering-connection`). If the request is from a different AWS account, ensure the accepting account's administrator knows to accept it. If the connection has expired or was rejected, you'll need to create a new peering request. There's no way to extend an expired request or reverse a rejection.

---

**Q5. Can you peer VPCs that have overlapping CIDR blocks?**

> No — this is a hard constraint of VPC Peering. If two VPCs have overlapping CIDRs (e.g., both use `10.0.0.0/16`), AWS cannot create a peering connection between them because the routing would be ambiguous — it can't determine which VPC owns which address range. If your VPCs have overlapping CIDRs and you need them to communicate, you'd need to re-IP one of the VPCs (create new subnets with non-overlapping CIDRs, migrate resources, delete old subnets) before peering. This is expensive and disruptive — which is why CIDR planning during initial VPC design is critical. AWS PrivateLink (sharing specific services via endpoint interfaces) is an alternative for specific use cases where re-IP isn't feasible.

---

**Q6. You have 5 VPCs and all need to communicate with each other. How many VPC peering connections do you need and when would you consider Transit Gateway instead?**

> For 5 VPCs in a full mesh, you need **N*(N-1)/2 = 5*4/2 = 10** peering connections. Each connection needs its own route table entries and security group rules. As N grows: 10 VPCs = 45 connections, 20 VPCs = 190 connections. This becomes operationally unmanageable quickly. At 5-7 VPCs, peering is still viable if the connectivity requirements are simple. Beyond that — or whenever transitive routing is needed, or when you need central policy control — Transit Gateway is the right choice. TGW adds ~$0.05/hr per attachment plus data processing costs, but the operational simplification at scale far outweighs the cost.

---

**Q7. How would you enable DNS resolution across peered VPCs (so instances can resolve each other's private DNS names)?**

> By default, VPC Peering only routes IP traffic — it doesn't enable DNS resolution across the peer. To allow instances in VPC-A to resolve the private DNS hostnames of instances in VPC-B (e.g., `ip-10-1-1-5.us-east-1.compute.internal`), you must enable two options on the peering connection: `AllowDnsResolutionFromRemoteVpc` on the accepter side and `AllowDnsResolutionFromRemoteVpc` on the requester side. In the CLI: `aws ec2 modify-vpc-peering-connection-options --vpc-peering-connection-id pcx-xxx --requester-peering-connection-options AllowDnsResolutionFromRemoteVpc=true --accepter-peering-connection-options AllowDnsResolutionFromRemoteVpc=true`. Both VPCs also need `enableDnsHostnames` and `enableDnsSupport` set to true.

---

## 📚 Resources

- [AWS Docs — VPC Peering](https://docs.aws.amazon.com/vpc/latest/peering/what-is-vpc-peering.html)
- [AWS CLI Reference — create-vpc-peering-connection](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-vpc-peering-connection.html)
- [AWS Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html)
- [VPC Peering Limitations](https://docs.aws.amazon.com/vpc/latest/peering/vpc-peering-basics.html#vpc-peering-limitations)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
