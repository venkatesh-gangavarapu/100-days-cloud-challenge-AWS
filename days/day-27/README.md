# Day 27 — Build a Custom Public VPC with Subnet and EC2 Instance

> **#100DaysOfCloud | Day 27 of 100**

---

## 📌 The Task

> *Create a complete public VPC networking stack from scratch — VPC, subnet with auto-IP assignment, Internet Gateway, route table — then launch an EC2 instance inside it with SSH access open to the internet.*

**Requirements:**
| Resource | Name / Detail |
|----------|--------------|
| VPC | `devops-pub-vpc` |
| Subnet | `devops-pub-subnet` (public, auto-assign public IP) |
| EC2 Instance | `devops-pub-ec2` (t2.micro) |
| SSH access | Port 22 open to internet |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### Why Build a Custom VPC Instead of Using the Default?

The **default VPC** is convenient for learning, but every production workload lives in a **custom VPC** for these reasons:

- **Network isolation** — your resources are in their own address space, separate from any other account or default infrastructure
- **CIDR control** — you choose the IP range, ensuring no conflicts with on-premises networks or VPC peering partners
- **Architecture control** — you define which subnets are public vs private, how many AZs, which route tables apply
- **Security posture** — the default VPC has permissive defaults (default security group allows all intra-VPC traffic); custom VPCs start clean

The default VPC is a shortcut. Any real deployment starts with a purpose-built VPC.

### The Complete Public VPC Component Stack

Making a subnet "public" requires five resources wired together in a specific order:

```
1. VPC (the container — defines the address space)
        │
2. Subnet (a segment of the VPC address space, tied to one AZ)
        │  + map-public-ip-on-launch=true
        │
3. Internet Gateway (the door to the internet — must be attached to VPC)
        │
4. Route Table (the traffic director — add 0.0.0.0/0 → IGW route)
        │
5. Route Table Association (wire the subnet to the public route table)
```

**Without any one of these five, the subnet is not truly public.** The most commonly missed steps are the route table association (step 5) and the internet gateway route (step 4).

### CIDR Design for This Task

| Resource | CIDR |
|----------|------|
| VPC | `10.0.0.0/16` — 65,536 addresses |
| Public Subnet | `10.0.1.0/24` — 256 addresses (251 usable after AWS reserves 5) |

The subnet CIDR must be a subset of the VPC CIDR. `10.0.1.0/24` fits within `10.0.0.0/16`.

### What "Auto-Assign Public IP" Actually Does

`map-public-ip-on-launch=true` on the subnet means every EC2 instance launched into this subnet automatically receives a public IPv4 address from AWS's pool — without needing an Elastic IP. This is what makes an instance internet-reachable without manual IP management.

The distinction from Day 10:
- **Auto-assign**: temporary dynamic IP, released on stop
- **Elastic IP** (Day 10): permanent static IP, survives stop/start

For `devops-pub-ec2`, auto-assign is sufficient — the task doesn't require a static IP.

### Security Group for SSH

The instance needs a security group allowing TCP port 22 from `0.0.0.0/0`. This is the minimum for internet-accessible SSH. In production you'd restrict this to a specific CIDR (your office IP, VPN range, or a bastion host security group), but for this task, open is the stated requirement.

### The Dependency Chain (Correct Build Order)

```
create-vpc
    ↓
create-subnet (with VPC ID)
    ↓
modify-subnet-attribute (enable auto-assign public IP)
    ↓
create-internet-gateway
    ↓
attach-internet-gateway (to VPC)
    ↓
create-route-table (with VPC ID)
    ↓
create-route (0.0.0.0/0 → IGW)
    ↓
associate-route-table (route table → subnet)
    ↓
create-security-group (SSH port 22)
    ↓
run-instances (instance into subnet, with SG)
```

Each step depends on IDs from the previous step. The order cannot be changed.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. **VPC**: VPC Console → Create VPC → Name: `devops-pub-vpc`, IPv4 CIDR: `10.0.0.0/16`
2. **Subnet**: Subnets → Create subnet → VPC: `devops-pub-vpc`, Name: `devops-pub-subnet`, CIDR: `10.0.1.0/24`
3. **Auto-IP**: Select subnet → Actions → Edit subnet settings → Enable auto-assign public IPv4
4. **IGW**: Internet gateways → Create → Name: `devops-pub-igw` → Attach to `devops-pub-vpc`
5. **Route Table**: Route tables → Create → VPC: `devops-pub-vpc` → Edit routes → Add `0.0.0.0/0 → devops-pub-igw` → Subnet associations → Associate `devops-pub-subnet`
6. **Security Group**: Security groups → Create → VPC: `devops-pub-vpc` → Inbound: TCP 22 from `0.0.0.0/0`
7. **EC2**: Launch instance → Name: `devops-pub-ec2` → t2.micro → Ubuntu AMI → Network: `devops-pub-vpc` → Subnet: `devops-pub-subnet` → Security group: from step 6

---

### Method 2 — AWS CLI (Full Script)

```bash
REGION="us-east-1"

# ============================================================
# STEP 1: Create the VPC
# ============================================================
VPC_ID=$(aws ec2 create-vpc \
    --region "$REGION" \
    --cidr-block 10.0.0.0/16 \
    --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=devops-pub-vpc}]' \
    --query "Vpc.VpcId" \
    --output text)

echo "VPC: $VPC_ID"

# Enable DNS hostnames (required for public instances to get DNS names)
[Oaws ec2 modify-vpc-attribute \
    --vpc-id "$VPC_ID" \
    --enable-dns-hostnames \
    --region "$REGION"

aws ec2 modify-vpc-attribute \
    --vpc-id "$VPC_ID" \
    --enable-dns-support \
    --region "$REGION"

echo "DNS hostnames and DNS support enabled on VPC"

# ============================================================
# STEP 2: Create the public subnet
# ============================================================
SUBNET_ID=$(aws ec2 create-subnet \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --cidr-block 10.0.1.0/24 \
    --availability-zone us-east-1a \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=devops-pub-subnet}]' \
    --query "Subnet.SubnetId" \
    --output text)

echo "Subnet: $SUBNET_ID"

# ============================================================
# STEP 3: Enable auto-assign public IP on the subnet
# ============================================================
aws ec2 modify-subnet-attribute \
    --subnet-id "$SUBNET_ID" \
    --map-public-ip-on-launch \
    --region "$REGION"

echo "Auto-assign public IP enabled on subnet"

# ============================================================
# STEP 4: Create Internet Gateway
# ============================================================
IGW_ID=$(aws ec2 create-internet-gateway \
    --region "$REGION" \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=devops-pub-igw}]' \
    --query "InternetGateway.InternetGatewayId" \
    --output text)

echo "Internet Gateway: $IGW_ID"

# ============================================================
# STEP 5: Attach IGW to the VPC
# ============================================================
aws ec2 attach-internet-gateway \
    --region "$REGION" \
    --internet-gateway-id "$IGW_ID" \
    --vpc-id "$VPC_ID"

echo "IGW attached to VPC"

# ============================================================
# STEP 6: Create a public route table
# ============================================================
RT_ID=$(aws ec2 create-route-table \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=devops-pub-rt}]' \
    --query "RouteTable.RouteTableId" \
    --output text)

echo "Route Table: $RT_ID"

# ============================================================
# STEP 7: Add route — all internet traffic → IGW
# ============================================================
aws ec2 create-route \
    --region "$REGION" \
    --route-table-id "$RT_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$IGW_ID"

echo "Route 0.0.0.0/0 → $IGW_ID added"

# ============================================================
# STEP 8: Associate the public subnet with the public route table
# ============================================================
aws ec2 associate-route-table \
    --region "$REGION" \
    --route-table-id "$RT_ID" \
    --subnet-id "$SUBNET_ID"

echo "Route table associated with subnet"

# ============================================================
# STEP 9: Create security group — SSH port 22 open to internet
# ============================================================
SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name devops-pub-sg \
    --description "devops-pub-ec2 security group — SSH port 22 from internet" \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=devops-pub-sg}]' \
    --query "GroupId" \
    --output text)

echo "Security Group: $SG_ID"

aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0

echo "Inbound rule: TCP port 22 from 0.0.0.0/0 added"

# ============================================================
# STEP 10: Resolve latest Ubuntu 22.04 LTS AMI
# ============================================================
AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "AMI: $AMI_ID"

# ============================================================
# STEP 11: Launch the EC2 instance
# ============================================================
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --tag-specifications \
        'ResourceType=instance,Tags=[{Key=Name,Value=devops-pub-ec2}]' \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Instance launched: $INSTANCE_ID"

# ============================================================
# STEP 12: Wait and verify
# ============================================================
echo "Waiting for instance to reach running state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

echo ""
echo "============================================"
echo "  VPC:         devops-pub-vpc  ($VPC_ID)"
echo "  Subnet:      devops-pub-subnet ($SUBNET_ID)"
echo "  IGW:         devops-pub-igw  ($IGW_ID)"
echo "  Route Table: devops-pub-rt   ($RT_ID)"
echo "  SG:          devops-pub-sg   ($SG_ID)"
echo "  Instance:    devops-pub-ec2  ($INSTANCE_ID)"
echo "  Public IP:   $PUBLIC_IP"
echo "  SSH:         ssh ubuntu@$PUBLIC_IP"
echo "============================================"
```

---

### Verifying the Full Stack

```bash
# Verify VPC
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
    --query "Vpcs[0].{CIDR:CidrBlock,State:State,DNS:EnableDnsHostnames}" \
    --output table

# Verify subnet has auto-assign enabled
aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --region "$REGION" \
    --query "Subnets[0].{CIDR:CidrBlock,AZ:AvailabilityZone,AutoAssignIP:MapPublicIpOnLaunch}" \
    --output table

# Verify route table has IGW route
aws ec2 describe-route-tables --route-table-ids "$RT_ID" --region "$REGION" \
    --query "RouteTables[0].Routes[*].{Destination:DestinationCidrBlock,Target:GatewayId}" \
    --output table

# Verify IGW is attached
aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" --region "$REGION" \
    --query "InternetGateways[0].{ID:InternetGatewayId,VPC:Attachments[0].VpcId,State:Attachments[0].State}" \
    --output table

# Test SSH reachability (nc checks if port 22 is open)
nc -zvw3 "$PUBLIC_IP" 22 && echo "Port 22 is open" || echo "Port 22 is closed"

# SSH in
ssh -o StrictHostKeyChecking=no ubuntu@"$PUBLIC_IP"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- VPC ---
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --region $REGION \
    --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=devops-pub-vpc}]' \
    --query "Vpc.VpcId" --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames --region $REGION

# --- SUBNET ---
SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 \
    --availability-zone us-east-1a --region $REGION \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=devops-pub-subnet}]' \
    --query "Subnet.SubnetId" --output text)
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch --region $REGION

# --- INTERNET GATEWAY ---
[IIGW_ID=$(aws ec2 create-internet-gateway --region $REGION \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=devops-pub-igw}]' \
    --query "InternetGateway.InternetGatewayId" --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION

# --- ROUTE TABLE ---
RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $REGION \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=devops-pub-rt}]' \
    --query "RouteTable.RouteTableId" --output text)
aws ec2 create-route --route-table-id $RT_ID \
    --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION
aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET_ID --region $REGION

# --- SECURITY GROUP (SSH) ---
SG_ID=$(aws ec2 create-security-group --group-name devops-pub-sg \
    --description "SSH from internet" --vpc-id $VPC_ID --region $REGION \
    --query "GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION

# --- LAUNCH EC2 ---
INSTANCE_ID=$(aws ec2 run-instances --region $REGION \
    --image-id $AMI_ID --instance-type t2.micro \
    --subnet-id $SUBNET_ID --security-group-ids $SG_ID \
    --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=devops-pub-ec2}]' \
    --query "Instances[0].InstanceId" --output text)

# --- CLEANUP (strict order) ---
# Terminate instance → delete SG → disassociate RT → delete RT → detach IGW →
# delete IGW → delete subnet → delete VPC
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID --region $REGION
aws ec2 delete-security-group --group-id $SG_ID --region $REGION
aws ec2 delete-route-table --route-table-id $RT_ID --region $REGION
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION
aws ec2 delete-subnet --subnet-id $SUBNET_ID --region $REGION
aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Skipping the route table association (subnet stays private)**
Creating a route table with `0.0.0.0/0 → IGW` is not enough — it must be explicitly associated with the subnet via `associate-route-table`. Without this, the subnet uses the VPC's main route table (which has no IGW route), and the subnet remains private despite having the correct route table and IGW configured.

**2. Forgetting `modify-subnet-attribute --map-public-ip-on-launch`**
Without this, instances launched into the subnet don't get a public IP even though the subnet has an IGW route. The instance is in a "public subnet" (it has an internet route) but isn't reachable because it has no public address. Both the subnet routing AND the auto-assign setting are required for a truly public subnet.

**3. Not enabling DNS hostnames on the VPC**
`modify-vpc-attribute --enable-dns-hostnames` is required for EC2 instances in the VPC to receive public DNS names. Without it, you can only use the IP address. This doesn't affect connectivity, but affects service discovery and any tooling that relies on DNS resolution of instance hostnames.

**4. Trying to delete a VPC before removing all dependent resources**
`delete-vpc` will fail if the VPC still has subnets, route tables (non-main), security groups, or internet gateways attached. The cleanup order is strictly: terminate instances → delete SGs → delete non-main route tables → detach IGW → delete IGW → delete subnets → delete VPC.

**5. Using overlapping CIDR blocks when multiple VPCs or on-premises networks exist**
If you later want to peer this VPC with another, or connect it to on-premises via VPN/Direct Connect, overlapping CIDRs cause routing conflicts. Choose CIDRs from RFC 1918 private space (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) that don't overlap with any existing network in your environment.

**6. Not tagging the Internet Gateway and Route Table**
Untagged infrastructure in a shared AWS account becomes invisible very quickly. Tag every resource: VPC, subnet, IGW, route table, security group. Without tags, correlating resources to their purpose, owner, or cost centre becomes guesswork.

---

## 🌍 Real-World Context

This task is the baseline VPC pattern that every production AWS environment starts from. The resources created today map directly to what you'd see in a Terraform module:

```hcl
resource "aws_vpc"                  "main" { cidr_block = "10.0.0.0/16" }
resource "aws_subnet"               "public" { vpc_id = ... cidr_block = "10.0.1.0/24" map_public_ip_on_launch = true }
resource "aws_internet_gateway"     "igw" { vpc_id = ... }
resource "aws_route_table"          "public" { vpc_id = ... }
resource "aws_route"                "internet" { destination_cidr_block = "0.0.0.0/0" gateway_id = ... }
resource "aws_route_table_association" "public" { subnet_id = ... route_table_id = ... }
```

In production, this public subnet pattern is extended with private subnets (no IGW route, outbound via NAT Gateway), isolated database subnets (no internet at all), and the full three-tier architecture from Day 3. The VPC itself may span 3 AZs with 9 subnets (3 public, 3 private, 3 database).

VPCs created this way are also the foundation for:
- **VPC Peering** — direct routing between two VPCs (same or different accounts)
- **Transit Gateway** — hub-and-spoke routing for many VPCs
- **AWS PrivateLink** — private connectivity to AWS services without internet traversal
- **Site-to-Site VPN / Direct Connect** — connecting on-premises networks to the VPC

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What are all the components required to make a subnet "public" in AWS?**

> Five components must be correctly configured: a **VPC** with the appropriate CIDR block; a **subnet** within that VPC tied to an AZ; an **Internet Gateway** created and attached to the VPC — this is the actual connection to the internet; a **route table** with a route `0.0.0.0/0 → IGW` so the subnet knows to send internet-bound traffic through the gateway; and a **route table association** explicitly linking that route table to the subnet. Additionally, `map-public-ip-on-launch` should be enabled on the subnet so instances automatically receive public IPs. If any of these five pieces is missing, the subnet is not truly public. The most commonly missed are the route table association and the auto-assign IP setting.

---

**Q2. What's the difference between the main route table and a custom route table in a VPC?**

> Every VPC has a **main route table** created automatically. Any subnet that isn't explicitly associated with a custom route table uses the main route table implicitly. The risk: if you add a route to the main route table (like `0.0.0.0/0 → IGW`), every unassociated subnet inherits that route — accidentally making private subnets public. Best practice: keep the main route table minimal (local route only) and create explicit custom route tables for public and private subnets, associating each subnet explicitly. This way, no subnet accidentally inherits an internet route through the main route table.

---

**Q3. Can you change a VPC's CIDR block after it's created?**

> The original CIDR block cannot be changed or removed. However, since 2017 AWS supports adding **secondary CIDR blocks** to an existing VPC — you can add up to 4 additional CIDR blocks (within the same RFC 1918 range). This allows VPC expansion when the original address space runs out. But you can't shrink or remove the primary CIDR. For subnets, there's no resize at all — once a subnet CIDR is set, it's permanent. If you need a different subnet CIDR, you must create a new subnet, migrate resources, and delete the old one. This makes upfront CIDR planning critical — especially for large Kubernetes deployments where EKS pods consume IP addresses rapidly.

---

**Q4. An EC2 instance in a custom VPC has a public IP but can't reach the internet. What do you investigate?**

> Work through the stack in order. First, confirm the subnet is associated with a route table that has `0.0.0.0/0 → IGW` — this is the most common cause. Second, confirm the Internet Gateway is attached to the VPC (not just created). Third, check the security group outbound rules — by default, outbound is allow-all, but if someone modified it to restrict outbound, that could block traffic. Fourth, check the Network ACL on the subnet — NACLs are stateless and a restrictive NACL can block traffic that the security group allows. Fifth, check if the instance OS has its own firewall (`iptables`, `ufw`) blocking outbound. Work outward from the routing layer in.

---

**Q5. What is the difference between a NAT Gateway and an Internet Gateway?**

> An **Internet Gateway** enables **bidirectional** communication between VPC resources and the internet. Resources with public IPs can receive inbound connections from the internet and initiate outbound connections — it's a two-way door. A **NAT Gateway** enables **outbound-only** communication from private subnet resources to the internet. A private instance behind a NAT Gateway can download packages, call external APIs, and push to external systems — but nothing from the internet can initiate a connection to the private instance. The internet only sees the NAT Gateway's Elastic IP, not the private instances behind it. NAT Gateway lives in a public subnet; private instances route their internet-bound traffic to it. This is how you keep application servers private while still letting them reach the internet.

---

**Q6. What happens to the resources in a VPC when you delete the VPC?**

> AWS prevents deletion of a VPC that still has resources in it — you'll get a dependency error. The deletion fails until you manually remove: EC2 instances (terminate), security groups (delete non-default ones), subnets (delete), route tables (delete non-main ones), internet gateways (detach then delete), NAT gateways, load balancers, RDS instances, EFS mount targets, and any other VPC-dependent resources. The correct cleanup order is innermost resources first, then networking components, then the VPC itself. For large VPCs, this is a significant operational task — tools like `aws-nuke` or VPC Reaper scripts automate the teardown.

---

**Q7. What are VPC Flow Logs and when would you enable them?**

> VPC Flow Logs capture IP traffic metadata going to and from network interfaces in your VPC — source/destination IP, port, protocol, bytes transferred, packets, and whether the traffic was accepted or rejected by security groups/NACLs. They're delivered to CloudWatch Logs or S3. You'd enable them for: security incident investigation (trace where traffic came from or went to), troubleshooting connectivity issues (confirm traffic is reaching/leaving an instance), compliance (some frameworks require network traffic audit trails), and baseline traffic analysis (understand normal traffic patterns before building alerting). Flow Logs don't capture packet payloads — just metadata. They can be enabled at the VPC level (all ENIs), subnet level, or individual ENI level. Cost is per GB of log data collected, so filtering to capture only REJECT events is a common cost optimization.

---

## 📚 Resources

- [AWS Docs — VPC with Public Subnet](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Scenario1.html)
- [AWS CLI Reference — create-vpc](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-vpc.html)
- [AWS CLI Reference — create-subnet](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-subnet.html)
- [AWS CLI Reference — create-internet-gateway](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-internet-gateway.html)
- [VPC Flow Logs](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
