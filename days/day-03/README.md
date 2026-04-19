# Day 03 — Creating a Subnet in AWS VPC

> **#100DaysOfCloud | Day 3 of 100**

---

## 📌 What I Worked On Today

A Key Pair authenticates you, a Security Group controls traffic — but none of that matters if your instance isn't sitting in the right network segment. Today I worked through **Subnets**: what they are, how they carve up a VPC, and how the public vs private distinction shapes every architecture decision you'll make in AWS.

Subnets are where networking theory meets real infrastructure. Get this mental model right early and every subsequent topic — route tables, NAT gateways, load balancers, VPC peering — snaps into place much more naturally.

---

## 🧠 Core Concepts

### What Is a VPC?

Before subnets make sense, you need the container they live in. A **Virtual Private Cloud (VPC)** is your own logically isolated network within AWS. When you create an AWS account, a default VPC exists in every region. It has a CIDR block of `172.31.0.0/16`, which gives you 65,536 IP addresses to work with.

In production, you create custom VPCs with your own CIDR range — typically something like `10.0.0.0/16` — so the address space fits cleanly into your broader corporate network design and avoids conflicts with on-premises ranges.

### What Is a Subnet?

A **Subnet** is a range of IP addresses within a VPC — a subdivision of the VPC's CIDR block. Every resource you launch (EC2 instances, RDS databases, Lambda in VPC, etc.) lives in a specific subnet. Subnets are tied to a single **Availability Zone** — you cannot span a subnet across AZs.

The relationship: **Region → VPC → Availability Zone → Subnet → Resources**

### Public vs Private Subnets

This distinction is the most important concept in VPC design:

| | Public Subnet | Private Subnet |
|---|---|---|
| **Route to internet** | Via Internet Gateway (IGW) | Via NAT Gateway (or none) |
| **Resources get public IPs** | Yes (if enabled) | No |
| **Directly reachable from internet** | Yes | No |
| **Typical use** | Load balancers, bastion hosts, NAT GW | App servers, databases, internal services |

A subnet is "public" not because of a setting on the subnet itself — it's public because its **route table** has a route pointing `0.0.0.0/0` to an Internet Gateway. Change the route table, and the same subnet becomes private. The route table is what makes the subnet public or private.

### CIDR Notation and Subnetting

AWS reserves **5 IP addresses** in every subnet — the first four and the last one:

| Address | Reserved For |
|---------|-------------|
| `10.0.1.0` | Network address |
| `10.0.1.1` | VPC router |
| `10.0.1.2` | AWS DNS |
| `10.0.1.3` | Future AWS use |
| `10.0.1.255` | Broadcast (not used in AWS, but reserved) |

So a `/24` subnet gives you 256 addresses minus 5 = **251 usable IPs**. Plan your CIDR blocks with this in mind.

### Subnet Sizing Strategy

| CIDR | Total IPs | Usable IPs | Good For |
|------|-----------|------------|---------|
| `/28` | 16 | 11 | Very small, specific-use subnets |
| `/27` | 32 | 27 | Small workloads |
| `/24` | 256 | 251 | Standard workload subnets |
| `/22` | 1024 | 1019 | Large workloads, EKS node groups |
| `/20` | 4096 | 4091 | Very large, EKS pod CIDR ranges |

The general rule: **size subnets larger than you think you need**. Expanding a subnet CIDR after the fact requires replacing it — there's no resize in place.

### Multi-AZ Design — Why One Subnet Is Never Enough

For anything production-grade, you create the same logical subnet in multiple Availability Zones. If AZ-A goes down, your resources in AZ-B and AZ-C keep running. The standard pattern is two or three AZs, each with a public and a private subnet:

```
VPC: 10.0.0.0/16
├── AZ-A (us-east-1a)
│   ├── Public Subnet:  10.0.1.0/24
│   └── Private Subnet: 10.0.11.0/24
├── AZ-B (us-east-1b)
│   ├── Public Subnet:  10.0.2.0/24
│   └── Private Subnet: 10.0.12.0/24
└── AZ-C (us-east-1c)
    ├── Public Subnet:  10.0.3.0/24
    └── Private Subnet: 10.0.13.0/24
```

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Navigate to **VPC → Subnets → Create subnet**
2. Select your **VPC** (use the default VPC or a custom one)
3. Fill in subnet details:
   - **Subnet name:** `public-subnet-1a`
   - **Availability Zone:** `us-east-1a`
   - **IPv4 CIDR block:** `10.0.1.0/24`
4. Click **Create subnet**
5. Repeat for additional AZs and for private subnets

To make a subnet **public** — enable auto-assign public IP:
- Select the subnet → **Actions → Edit subnet settings**
- Enable **Auto-assign public IPv4 address**
- Then attach a route table that points `0.0.0.0/0` to an Internet Gateway

---

### Method 2 — AWS CLI

```bash
# Step 1: Get your VPC ID
aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text

# Step 2: List available Availability Zones in your region
aws ec2 describe-availability-zones \
    --query "AvailabilityZones[*].ZoneName" \
    --output table

# Step 3: Create a public subnet in AZ-a
aws ec2 create-subnet \
    --vpc-id <YOUR_VPC_ID> \
    --cidr-block 10.0.1.0/24 \
    --availability-zone us-east-1a \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-subnet-1a},{Key=Type,Value=Public}]'

# Step 4: Create a private subnet in AZ-a
aws ec2 create-subnet \
    --vpc-id <YOUR_VPC_ID> \
    --cidr-block 10.0.11.0/24 \
    --availability-zone us-east-1a \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-subnet-1a},{Key=Type,Value=Private}]'

# Step 5: Create public and private subnets in AZ-b
aws ec2 create-subnet \
    --vpc-id <YOUR_VPC_ID> \
    --cidr-block 10.0.2.0/24 \
    --availability-zone us-east-1b \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-subnet-1b},{Key=Type,Value=Public}]'

aws ec2 create-subnet \
    --vpc-id <YOUR_VPC_ID> \
    --cidr-block 10.0.12.0/24 \
    --availability-zone us-east-1b \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-subnet-1b},{Key=Type,Value=Private}]'

# Step 6: Enable auto-assign public IP on public subnets
aws ec2 modify-subnet-attribute \
    --subnet-id <PUBLIC_SUBNET_ID> \
    --map-public-ip-on-launch
```

---

### Making a Subnet Truly Public — Route Table + IGW

A subnet with `map-public-ip-on-launch` is still private until it has a route to an Internet Gateway:

```bash
# Create an Internet Gateway
aws ec2 create-internet-gateway \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=my-igw}]'

# Attach it to your VPC
aws ec2 attach-internet-gateway \
    --internet-gateway-id <IGW_ID> \
    --vpc-id <YOUR_VPC_ID>

# Create a public route table
aws ec2 create-route-table \
    --vpc-id <YOUR_VPC_ID> \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=public-rt}]'

# Add a route: all internet traffic goes to the IGW
aws ec2 create-route \
    --route-table-id <RT_ID> \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id <IGW_ID>

# Associate the public subnet with the public route table
aws ec2 associate-route-table \
    --route-table-id <RT_ID> \
    --subnet-id <PUBLIC_SUBNET_ID>
```

---

### Verifying Subnets

```bash
# List all subnets in a VPC
aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=<YOUR_VPC_ID>" \
    --query "Subnets[*].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,Name:Tags[?Key=='Name']|[0].Value,PublicIP:MapPublicIpOnLaunch}" \
    --output table

# Describe a specific subnet
aws ec2 describe-subnets --subnet-ids <SUBNET_ID>
```

---

### Deleting a Subnet

```bash
# Subnet must have no running resources before deletion
aws ec2 delete-subnet --subnet-id <SUBNET_ID>
```

---

## 💻 Commands Reference

```bash
# --- LOOKUP ---
# Get VPC ID
aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text

# List AZs
aws ec2 describe-availability-zones \
    --query "AvailabilityZones[*].ZoneName" --output table

# --- CREATE SUBNETS ---
# Public subnet - AZ-a
aws ec2 create-subnet \
    --vpc-id <VPC_ID> --cidr-block 10.0.1.0/24 \
    --availability-zone us-east-1a \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-subnet-1a}]'

# Private subnet - AZ-a
aws ec2 create-subnet \
    --vpc-id <VPC_ID> --cidr-block 10.0.11.0/24 \
    --availability-zone us-east-1a \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-subnet-1a}]'

# Enable auto-assign public IP on public subnet
aws ec2 modify-subnet-attribute \
    --subnet-id <PUBLIC_SUBNET_ID> --map-public-ip-on-launch

# --- INTERNET GATEWAY ---
aws ec2 create-internet-gateway \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=my-igw}]'

aws ec2 attach-internet-gateway \
    --internet-gateway-id <IGW_ID> --vpc-id <VPC_ID>

# --- ROUTE TABLE ---
aws ec2 create-route-table --vpc-id <VPC_ID> \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=public-rt}]'

aws ec2 create-route \
    --route-table-id <RT_ID> \
    --destination-cidr-block 0.0.0.0/0 --gateway-id <IGW_ID>

aws ec2 associate-route-table \
    --route-table-id <RT_ID> --subnet-id <PUBLIC_SUBNET_ID>

# --- VERIFY ---
aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=<VPC_ID>" \
    --query "Subnets[*].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,PublicIP:MapPublicIpOnLaunch}" \
    --output table

# --- DELETE ---
aws ec2 delete-subnet --subnet-id <SUBNET_ID>
```

---

## ⚠️ Common Mistakes

**1. Thinking the subnet setting makes it "public" — it's the route table**
A subnet doesn't become public by ticking "auto-assign public IP." That setting only controls whether instances get a public IP address. What makes the subnet *reachable from the internet* is having a route to an Internet Gateway in its associated route table. Both pieces are required.

**2. Using CIDR blocks that overlap**
If your VPC is `10.0.0.0/16` and you create subnets `10.0.1.0/24` and `10.0.1.0/25`, AWS will reject the second one — the ranges overlap. Sketch out your address plan before creating subnets, especially if you're planning VPC peering or VPN connectivity to on-premises networks.

**3. Making subnets too small**
A `/28` subnet gives you 11 usable IPs. That sounds fine for a small deployment — until you add an ALB (which requires at least 8 IPs per AZ to function), an EKS cluster (which burns through IPs for pods), or any service that provisions ENIs automatically. Size generously. `/24` is a reasonable default for most workloads.

**4. Deploying everything in one AZ**
A single subnet in one AZ means that AZ going down takes your entire application with it. The standard is at minimum two AZs for anything that matters. Three AZs is the production standard in regions that support it.

**5. Putting databases in public subnets**
RDS instances, ElastiCache clusters, and anything storing sensitive data should never be in a public subnet. Even with a restrictive security group, the instance having a public IP is unnecessary exposure. Private subnets exist for a reason.

**6. Forgetting to tag subnets properly**
Subnets need specific tags for certain AWS services to work correctly. EKS requires `kubernetes.io/role/internal-elb: 1` on private subnets and `kubernetes.io/role/elb: 1` on public subnets to deploy load balancers correctly. Missing tags means silent failures that are painful to debug.

---

## 🌍 Real-World Context

Every production AWS architecture starts with the same question: *"How should I divide my VPC?"* The answer is almost always some variation of the three-tier subnet model:

- **Public subnets** — hold your internet-facing resources: Application Load Balancers, NAT Gateways, bastion hosts. Nothing that isn't supposed to accept internet traffic belongs here.
- **Private subnets** — hold your application tier: EC2 instances, ECS tasks, EKS worker nodes. They can initiate outbound internet traffic through a NAT Gateway but can't be reached directly from the internet.
- **Database subnets (isolated)** — hold RDS, ElastiCache, Redshift. No outbound internet route at all. The only traffic they accept comes from the private app-tier subnets.

When AWS Well-Architected reviews flag VPC issues, it's almost always one of two things: either the wrong resources are in the wrong subnet tier, or the subnets are only deployed in a single AZ. Both are avoidable with a little upfront CIDR planning.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What actually makes a subnet "public" in AWS — is it a setting on the subnet itself?**

> No — and this trips up a lot of people. The subnet itself has no public/private toggle. What makes a subnet public is its **route table**: specifically, the presence of a route pointing `0.0.0.0/0` to an Internet Gateway. The "auto-assign public IPv4" setting on the subnet just controls whether instances launched into it automatically get a public IP — but without the IGW route, that public IP is unreachable from the internet. You need both: the auto-assign setting AND the IGW route in the associated route table.

---

**Q2. You have a private subnet with EC2 instances that need to download packages from the internet (e.g., `yum install`). How do you enable that without making the subnet public?**

> You deploy a **NAT Gateway** in a *public* subnet and add a route in the private subnet's route table pointing `0.0.0.0/0` to the NAT Gateway. The NAT Gateway translates outbound requests from private instances to its own public IP, sends them to the internet, and routes the responses back. Critically, this is one-way — inbound connections from the internet can't reach the private instances through a NAT Gateway. That's the whole point: outbound access without inbound exposure. The NAT Gateway lives in a public subnet, the private instances never need one.

---

**Q3. AWS reserves 5 IPs per subnet. Name them and explain why this matters for planning.**

> The reserved addresses in, say, `10.0.1.0/24` are: `10.0.1.0` (network address), `10.0.1.1` (VPC router), `10.0.1.2` (AWS DNS), `10.0.1.3` (reserved for future use), and `10.0.1.255` (broadcast, not used but reserved). This matters most when sizing subnets for services that consume multiple IPs automatically. An Application Load Balancer requires at least 8 free IPs per AZ to scale. EKS pods each consume an IP from the node's subnet. A `/28` with only 11 usable IPs will quietly fail or cause launch errors in these scenarios long before you run out of instances. Always plan with the 5-IP reservation in mind.

---

**Q4. Your team wants to deploy across three Availability Zones for high availability. Walk me through the subnet layout you'd design.**

> For a standard three-tier application, I'd create nine subnets across three AZs — three public, three private (app tier), three isolated (database tier). Something like: public subnets at `10.0.1.0/24`, `10.0.2.0/24`, `10.0.3.0/24`; private app subnets at `10.0.11.0/24`, `10.0.12.0/24`, `10.0.13.0/24`; isolated DB subnets at `10.0.21.0/24`, `10.0.22.0/24`, `10.0.23.0/24`. Public subnets share a route table pointing to the IGW. Each private subnet routes outbound through a NAT Gateway in its AZ's public subnet (one NAT GW per AZ to avoid cross-AZ traffic charges and single points of failure). DB subnets have no internet route at all.

---

**Q5. Can you resize a subnet CIDR block after it's been created?**

> No — subnet CIDR blocks are immutable once created. If you need a larger subnet, you have to create a new one with the desired CIDR, migrate your resources into it, and delete the old one. This is why sizing generously upfront matters. The VPC CIDR can be extended by adding a secondary CIDR block (AWS allows this), but existing subnets within it cannot be resized. Plan carefully, and when in doubt, use `/24` as a default.

---

**Q6. What's the difference between a subnet route table and a VPC main route table? What's the risk of relying on the main route table?**

> Every VPC has a **main route table** that applies to all subnets that haven't been explicitly associated with a custom route table. The risk is that if you add a route to the main route table — say, a route to the internet via an IGW — it applies to *every* subnet that hasn't opted out, including subnets you intended to be private. The correct practice is to create explicit custom route tables for both public and private subnets and associate them explicitly, so the main route table remains minimal and no subnet accidentally inherits a route it shouldn't have.

---

**Q7. EKS isn't deploying load balancers into the correct subnets. What's likely the issue?**

> Almost certainly missing subnet tags. The AWS Load Balancer Controller (which manages ALBs and NLBs for EKS) uses subnet tags to discover where to deploy: `kubernetes.io/role/elb: 1` on public subnets for internet-facing load balancers, and `kubernetes.io/role/internal-elb: 1` on private subnets for internal ones. Without these tags, the controller can't find eligible subnets and either fails silently or deploys to the wrong tier. The fix is to add the tags to the correct subnets. In Terraform, this is managed via `tags` on the `aws_subnet` resource — easy to forget if you built the VPC before EKS was part of the plan.

---

## 📚 Resources

- [AWS Docs — VPCs and Subnets](https://docs.aws.amazon.com/vpc/latest/userguide/configure-subnets.html)
- [AWS CLI Reference — create-subnet](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-subnet.html)
- [VPC CIDR Planning — AWS Best Practices](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html)
- [AWS Well-Architected — Network Design](https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu.*
