# Day 45 — NAT Gateway: Private Subnet Internet Access

> **#100DaysOfCloud | Day 45 of 100**

---

## 📌 The Task

> *Enable internet access for a private EC2 instance by creating a public subnet, Internet Gateway, NAT Gateway, and updating route tables — verified by the private instance's cron job successfully uploading a file to S3.*

**Pre-existing Resources:**
| Resource | Name | Detail |
|----------|------|--------|
| VPC | `nautilus-priv-vpc` | Custom VPC |
| Private subnet | `nautilus-priv-subnet` | No internet route |
| Private EC2 | `nautilus-priv-ec2` | Has cron job → uploads to S3 |
| S3 bucket | `nautilus-nat-225063692` | Verification target |

**Tasks:**
| Task | Detail |
|------|--------|
| Public subnet | `nautilus-pub-subnet` in same VPC and AZ |
| Internet Gateway | Created and attached to `nautilus-priv-vpc` |
| Public route table | `nautilus-pub-rt` with `0.0.0.0/0 → IGW` |
| NAT Gateway | `nautilus-natgw` in the public subnet with Elastic IP |
| Private route table | Updated: `0.0.0.0/0 → nautilus-natgw` |
| Verify | Test file appears in `nautilus-nat-225063692` |

---

## 🧠 Core Concepts

### NAT Gateway vs NAT Instance — Day 30 Revisited

Day 30 used a **NAT Instance** (an EC2 running iptables MASQUERADE). Day 45 uses a **NAT Gateway** — a fully managed AWS service. This is the comparison that drives the decision in every real project:

| | NAT Gateway | NAT Instance (Day 30) |
|--|-------------|----------------------|
| **Management** | Fully managed by AWS | You manage OS, iptables, patching |
| **Availability** | Built-in per-AZ redundancy | Single EC2 — SPOF unless you build HA |
| **Bandwidth** | Up to 100 Gbps | Limited by instance type |
| **Source/dest check** | Not applicable | **Must be disabled** |
| **iptables** | Not needed | Required (not on AL2023 by default) |
| **Cost** | ~$0.045/hr + $0.045/GB | ~$0.012/hr for t2.micro |
| **Setup** | No configuration after creation | iptables MASQUERADE + IP forwarding |
| **Use case** | Production | Dev/test, cost-constrained |

The operational simplicity of NAT Gateway — no iptables, no source/dest check, no OS to patch — is why it's the default choice for production. The cost premium is worth the operational savings for most teams.

### The Complete Architecture

```
Internet
    │
    ▼ IGW (nautilus-igw — attached to nautilus-priv-vpc)
nautilus-pub-subnet
    │
    ▼ NAT Gateway (nautilus-natgw — has Elastic IP, sits here)
    │
    ▼ (private route table: 0.0.0.0/0 → NAT Gateway)
nautilus-priv-subnet
    │
    ▼ nautilus-priv-ec2
       (cron: aws s3 cp → nautilus-nat-225063692)
```

### Why the NAT Gateway Must Be in the Public Subnet

A NAT Gateway needs a public IP (Elastic IP) to source-NAT private instance traffic. For a public IP to be routable, the subnet must have a route to an Internet Gateway. If you place the NAT Gateway in the private subnet, it has no route to the internet — the NAT Gateway itself can't reach the internet, so it can't forward traffic to it. Always: NAT Gateway in the **public** subnet, route from the **private** subnet pointing to it.

### Elastic IP for NAT Gateway

NAT Gateway requires a dedicated Elastic IP — unlike NAT Instances which use the instance's auto-assigned public IP. The Elastic IP becomes the stable, internet-visible source address for all traffic from the private subnet. Any external service that needs to whitelist your private instances' IP sees this Elastic IP.

### Route Table Logic — Both Sides

```
Public subnet route table (nautilus-pub-rt):
  10.x.0.0/16   → local   (VPC-internal traffic stays internal)
  0.0.0.0/0     → IGW     (internet-bound goes through IGW)

Private subnet route table:
  10.x.0.0/16   → local   (VPC-internal traffic stays internal)
  0.0.0.0/0     → NATGW   (internet-bound goes to NAT Gateway)
```

Traffic from the private instance to S3 (`aws s3 cp`) hits the `0.0.0.0/0` route → goes to NAT Gateway → NAT Gateway source-NATs to its Elastic IP → exits through IGW → reaches S3.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Step 1 — Get existing resource details (aws-client)**
```bash
aws ec2 describe-vpcs --region us-east-1 \
    --filters "Name=tag:Name,Values=nautilus-priv-vpc" \
    --query "Vpcs[0].{ID:VpcId,CIDR:CidrBlock}" --output table

aws ec2 describe-subnets --region us-east-1 \
    --filters "Name=tag:Name,Values=nautilus-priv-subnet" \
    --query "Subnets[0].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}" --output table
```

Note the VPC ID, private subnet CIDR, and AZ.

**Step 2 — Create public subnet**
VPC → Subnets → Create subnet → VPC: `nautilus-priv-vpc` → Name: `nautilus-pub-subnet` → same AZ as private subnet → CIDR: use non-overlapping block → Create → Edit subnet settings → Enable auto-assign public IPv4

**Step 3 — Create Internet Gateway**
VPC → Internet gateways → Create → Name: `nautilus-igw` → Create → Actions → Attach to VPC → `nautilus-priv-vpc`

**Step 4 — Create public route table**
VPC → Route tables → Create → Name: `nautilus-pub-rt` → VPC: `nautilus-priv-vpc` → Routes → Edit → Add: `0.0.0.0/0 → nautilus-igw` → Subnet associations → Associate `nautilus-pub-subnet`

**Step 5 — Create NAT Gateway**
VPC → NAT gateways → Create → Name: `nautilus-natgw` → Subnet: `nautilus-pub-subnet` (public!) → Allocate Elastic IP → Create → ⏳ Wait for **Available**

**Step 6 — Update private route table**
VPC → Route tables → find private subnet's RT → Routes → Edit → Add: `0.0.0.0/0 → nautilus-natgw` → Save

**Step 7 — Verify (aws-client)**
```bash
sleep 180  # wait for cron job to run
aws s3 ls s3://nautilus-nat-225063692/
```

---

### Method 2 — AWS CLI (Full Script)

See the complete script in `commands.sh` — it handles all 7 steps with automatic CIDR derivation and route table discovery.

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CREATE IGW AND ATTACH ---
IGW_ID=$(aws ec2 create-internet-gateway --region $REGION \
    --query "InternetGateway.InternetGatewayId" --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID \
    --vpc-id $VPC_ID --region $REGION

# --- CREATE PUBLIC SUBNET ---
PUB_SUBNET_ID=$(aws ec2 create-subnet --region $REGION \
    --vpc-id $VPC_ID --cidr-block 10.x.2.0/24 \
    --availability-zone us-east-1a \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=nautilus-pub-subnet}]' \
    --query "Subnet.SubnetId" --output text)
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_ID \
    --map-public-ip-on-launch --region $REGION

# --- CREATE PUBLIC ROUTE TABLE ---
PUB_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $REGION \
[O    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=nautilus-pub-rt}]' \
    --query "RouteTable.RouteTableId" --output text)
aws ec2 create-route --route-table-id $PUB_RT_ID \
    --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION
aws ec2 associate-route-table --route-table-id $PUB_RT_ID \
    --subnet-id $PUB_SUBNET_ID --region $REGION

# --- ALLOCATE EIP AND CREATE NAT GATEWAY ---
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --region $REGION \
    --query "AllocationId" --output text)
NATGW_ID=$(aws ec2 create-nat-gateway --region $REGION \
    --subnet-id $PUB_SUBNET_ID --allocation-id $EIP_ALLOC \
    --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=nautilus-natgw}]' \
    --query "NatGateway.NatGatewayId" --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids $NATGW_ID --region $REGION

# --- UPDATE PRIVATE ROUTE TABLE ---
aws ec2 create-route --route-table-id $PRIV_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id $NATGW_ID --region $REGION

# --- VERIFY S3 ---
aws s3 ls s3://nautilus-nat-225063692/

# --- CLEANUP (order matters) ---
aws ec2 delete-nat-gateway --nat-gateway-id $NATGW_ID --region $REGION
aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NATGW_ID --region $REGION
aws ec2 release-address --allocation-id $EIP_ALLOC --region $REGION
aws ec2 delete-route --route-table-id $PRIV_RT_ID \
    --destination-cidr-block 0.0.0.0/0 --region $REGION
aws ec2 delete-route-table --route-table-id $PUB_RT_ID --region $REGION
aws ec2 delete-subnet --subnet-id $PUB_SUBNET_ID --region $REGION
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Creating the NAT Gateway in the private subnet**
This is the most critical mistake and has no error message — the NAT Gateway is created successfully and reaches Available status, but it has no internet connectivity because the private subnet has no route to an IGW. The private EC2's traffic reaches the NAT Gateway but goes nowhere. Always create the NAT Gateway in the **public** subnet — the one with `0.0.0.0/0 → IGW`.

**2. Forgetting to allocate an Elastic IP before creating the NAT Gateway**
`create-nat-gateway` requires an `--allocation-id` for the Elastic IP. Attempting to create without one fails immediately. Allocate first: `aws ec2 allocate-address --domain vpc`.

**3. Not waiting for the NAT Gateway to reach Available before updating the route table**
NAT Gateways take 1–2 minutes to provision. Adding a route pointing to a NAT Gateway that's still in `pending` state creates a route that doesn't work yet. The `aws ec2 wait nat-gateway-available` waiter handles this correctly — always include it.

**4. Not associating the public subnet with the public route table**
Creating a route table and adding an IGW route is not enough — the route table must be explicitly associated with the public subnet, otherwise the subnet uses the VPC's default main route table (which has no IGW route) and the NAT Gateway itself has no internet access. Always associate the route table with the subnet.

**5. Forgetting the Elastic IP costs money even when unused**
An Elastic IP that's allocated but not associated with a running instance or NAT Gateway incurs a small hourly charge (~$0.005/hr). After the task is complete or during cleanup, release the Elastic IP: `aws ec2 release-address`. You can only release it after the NAT Gateway is deleted.

**6. Not finding the correct private route table**
A common mistake is adding the NAT Gateway route to the VPC's main route table when the private subnet has its own explicit route table association. Changes to the main route table don't affect subnets with explicit associations. Always check which route table is actually associated with `nautilus-priv-subnet` before adding the route.

---

## 🌍 Real-World Context

**NAT Gateway vs NAT Instance — the production decision:** NAT Gateway costs ~3–4x more per hour than a t2.micro NAT Instance but provides built-in HA within the AZ, no OS management, automatic scaling to 100 Gbps, and zero configuration. For production workloads, the operational savings are worth the cost difference — an on-call incident to fix a crashed NAT Instance at 2 AM erases months of savings.

**Multi-AZ NAT for production HA:** A single NAT Gateway covers one AZ. If that AZ fails, private instances in other AZs lose their internet route. For true HA, deploy one NAT Gateway per AZ and configure each AZ's private subnet route table to point to its own NAT Gateway. This doubles the NAT Gateway cost but eliminates cross-AZ dependency.

**Cost optimization with NAT Instance at scale:** For workloads that need to pass large amounts of data through NAT (e.g., downloading large datasets, bulk S3 uploads from many private instances), a larger NAT Instance can be significantly cheaper than NAT Gateway's per-GB data processing charge. A c5.large NAT Instance costs ~$0.085/hr with no data charge vs NAT Gateway's $0.045/hr + $0.045/GB. At 100 GB/day of egress, NAT Instance saves ~$130/month.

**S3 VPC Endpoint as the better answer:** For private instances that primarily need S3 access (exactly the use case in this task), an **S3 Gateway Endpoint** is free, provides direct routing to S3 within AWS's backbone (no internet exposure), and eliminates NAT costs entirely. Add `com.amazonaws.us-east-1.s3` as a gateway endpoint on the VPC and add a route for the S3 prefix list to the private subnet's route table — no NAT Gateway needed for S3 traffic.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. What is the difference between a NAT Gateway and an Internet Gateway, and when would you use each?**
> An Internet Gateway is the VPC's door to the internet — it enables **bidirectional** communication. Resources with public IPs (instances in public subnets) can receive inbound connections from the internet and initiate outbound connections. A NAT Gateway enables **outbound-only** internet access for private subnet resources. Instances behind a NAT Gateway can initiate connections to the internet (download packages, call APIs, upload to S3) but nothing from the internet can initiate a connection to those instances — the NAT Gateway's Elastic IP is the only visible address. Use an IGW when resources legitimately need to be reachable from the internet (web servers, bastion hosts). Use a NAT Gateway when resources need internet access but should not be directly reachable (application servers, database migration tools, internal services that call external APIs).

**Q2. Why must a NAT Gateway be placed in a public subnet?**
> A NAT Gateway needs a public Elastic IP and must be able to route internet-bound traffic out to the internet. For that to work, the subnet the NAT Gateway is in must have a route `0.0.0.0/0 → IGW` — which is the definition of a public subnet. If you place the NAT Gateway in a private subnet, it has no path to the internet itself, so it cannot forward traffic from private instances to the internet. The flow is: private instance → private route table `0.0.0.0/0 → NAT Gateway` → NAT Gateway source-NATs to its Elastic IP → NAT Gateway's subnet route table `0.0.0.0/0 → IGW` → internet.

**Q3. How does NAT Gateway handle traffic from multiple private instances simultaneously?**
> NAT Gateway uses **Port Address Translation (PAT)** — the same technique used by home routers. Each outbound connection from a private instance uses a unique source port on the NAT Gateway's Elastic IP. For example, instance 10.0.1.5 connecting to S3 on TCP port 443 becomes `EIP:54321 → S3:443` at the NAT Gateway. Instance 10.0.1.6 making a different connection becomes `EIP:54322 → S3:443`. The NAT Gateway maintains a connection tracking table mapping each EIP:port to the originating private instance:port. When the response arrives at EIP:54321, the NAT Gateway knows to forward it to 10.0.1.5. Up to 55,000 simultaneous connections per unique destination IP:port combination are supported.

**Q4. What is the S3 VPC Gateway Endpoint and when would you use it instead of NAT Gateway for S3 access?**
> An S3 Gateway Endpoint provides a private route directly from your VPC to S3 through AWS's internal network — traffic never traverses the internet or a NAT Gateway. It's free (no hourly cost, no data transfer charge), reduces latency slightly, and eliminates the security consideration of S3 traffic leaving your VPC. You'd use it whenever private instances need S3 access: just create the gateway endpoint for `com.amazonaws.region.s3`, add a route entry to the private subnet's route table for the S3 prefix list pointing to the endpoint, and private instances can reach S3 directly. For this task's use case (private EC2 uploading to S3), a Gateway Endpoint would be the cost-optimal and more secure solution — but NAT Gateway is correct when the instance also needs access to non-AWS internet endpoints.

**Q5. A private EC2 instance can ping 8.8.8.8 via the NAT Gateway but cannot reach an external HTTPS endpoint. What could be wrong?**
> Ping works differently from HTTPS — ping uses ICMP while HTTPS uses TCP 443. If ICMP works but TCP 443 doesn't, the most likely cause is the security group on the private EC2 instance's outbound rules. By default, security groups allow all outbound traffic — but if someone configured a restrictive outbound rule, they might have allowed ICMP but not TCP 443. Check `describe-security-groups` on the instance's SG and confirm the outbound rules include TCP 443 to `0.0.0.0/0`. The Network ACL on the private subnet is another possibility — NACLs are stateless, and a custom NACL might deny TCP 443 outbound or the ephemeral port range inbound for the response.

**Q6. You have three private subnets in three AZs all routing through a single NAT Gateway in us-east-1a. What happens if us-east-1a fails and how would you fix it?**
> All three private subnets lose their internet route simultaneously — the `0.0.0.0/0 → natgw-xxx` route still exists but the NAT Gateway is in a failed AZ and unreachable. Private instances in us-east-1b and us-east-1c cannot make any internet connections until the AZ recovers. The fix for production: deploy one NAT Gateway per AZ and configure each AZ's private subnet route table to route through its own AZ-local NAT Gateway. Three NAT Gateways cost 3× as much but each AZ's private instances are independent — a failure in one AZ doesn't affect the others. This is the standard architecture in the AWS VPC documentation.

**Q7. After setting up the NAT Gateway and updating route tables, the private EC2 still can't reach the internet. What's your debugging checklist?**
> In order. First, confirm the NAT Gateway is in `available` state — `describe-nat-gateways`. Second, confirm the private subnet's route table has `0.0.0.0/0 → nat-gateway-id` and the state is `active` — `describe-route-tables`. Third, confirm the public subnet's route table has `0.0.0.0/0 → igw-xxx` — the NAT Gateway itself needs this path. Fourth, check the private EC2's security group outbound rules — default allows all, but custom SGs might block outbound. Fifth, check the private subnet's Network ACL for restrictive outbound or inbound ephemeral port rules. Sixth, confirm the private EC2's OS-level firewall (iptables, firewalld) isn't blocking outbound traffic. From the instance itself, `curl -s https://checkip.amazonaws.com` — if it returns an IP address, the path is working; if it times out, the problem is in the network path.

---

## 📚 Resources

- [AWS Docs — NAT Gateways](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html)
- [NAT Gateway vs NAT Instance Comparison](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-comparison.html)
- [S3 Gateway Endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html)
- [Multi-AZ NAT Architecture](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-scenarios.html)
- [Day 30 — NAT Instance (comparison)](../day-30/README.md)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
