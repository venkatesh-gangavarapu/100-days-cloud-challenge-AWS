# Day 49 — Multi-VPC Log Aggregation: VPC Peering, EC2, and S3

> **#100DaysOfCloud | Day 49 of 100**

---

## 📌 The Task

> *Build a secure cross-VPC log pipeline: private EC2 → (via SCP + VPC peering) → public EC2 → S3, automated with cron jobs on each instance.*

**Architecture:**

```
aws-client
    │ SSH (devops-key.pem)
    ▼
devops-pub-ec2 (public subnet, public IP, IAM role → S3)
    │
    │ SCP via VPC peering (private IP to private IP)
    ▼
devops-priv-ec2 (private subnet, no public IP)
    reads: /var/log/boots.log

Flow:
devops-priv-ec2 [cron every min]
  → scp /var/log/boots.log → ubuntu@devops-pub-ec2:/home/ubuntu/boots.log

devops-pub-ec2 [cron every min]
  → aws s3 cp boots.log s3://devops-s3-logs-28138/devops-priv-vpc/boot/boots.log
```

**Resources created:**

| Resource | Name | Detail |
|----------|------|--------|
| VPC | `devops-pub-vpc` | Public VPC, new CIDR |
| Subnet | `devops-pub-subnet` | Public, auto-assign IP |
| Route table | `devops-pub-rt` | `0.0.0.0/0 → IGW` |
| EC2 | `devops-pub-ec2` | Ubuntu, t2.micro, same key pair |
| IAM role | `devops-s3-role` | EC2 → S3 PutObject |
| S3 bucket | `devops-s3-logs-28138` | Private bucket |
| VPC peering | `devops-vpc-peering` | priv-vpc ↔ pub-vpc |
| Route (priv RT) | — | pub CIDR → peering |
| Route (pub RT) | — | priv CIDR → peering |
| Cron (private EC2) | — | SCP boots.log every minute |
| Cron (public EC2) | — | S3 push every minute |

---

## 🧠 Core Concepts

### VPC Peering — Bidirectional Route Updates Required

VPC peering creates a private network connection between two VPCs. Crucially: peering alone doesn't route traffic. Both route tables must be updated:

```
devops-priv-rt:  <pub-vpc-cidr>   → peering connection ID
devops-pub-rt:   <priv-vpc-cidr>  → peering connection ID
```

Missing either route means traffic flows one way only (or not at all). This is the most common peering mistake — the connection is accepted and active, but traffic still can't reach the other side.

### Cross-VPC Connectivity Path

Once peering and routes are in place:
```
devops-priv-ec2 (10.0.1.x)
  sends to devops-pub-ec2 private IP (10.1.1.x)
  → private RT: 10.1.0.0/16 → pcx-xxx
  → peering connection
  → public EC2 receives on its private interface
```

No public IP, no internet — pure private connectivity across the peering link.

### SSH ProxyJump for Accessing Private Instances

The private EC2 has no public IP. To reach it, jump through the public EC2:

```bash
# Direct access to private EC2 via public EC2 as jump host
ssh -i devops-key.pem \
    -o ProxyJump="ubuntu@${PUB_EC2_PUBLIC_IP}" \
    ubuntu@${PRIV_EC2_PRIVATE_IP}

# SCP via jump host
scp -i devops-key.pem \
    -o ProxyJump="ubuntu@${PUB_EC2_PUBLIC_IP}" \
    file ubuntu@${PRIV_EC2_PRIVATE_IP}:/path/
```

### Key Distribution for SCP

The private EC2 needs to SCP to the public EC2. For SCP to work:
- The private EC2 needs the private key (`devops-key.pem`)
- The key's public counterpart must already be in the public EC2's `authorized_keys` (it is, since both use the same key pair)

So: copy `devops-key.pem` to `/home/ubuntu/.ssh/` on the private EC2, and SCP from private to public works over the peering link.

### IAM Role vs Access Keys for S3 Uploads

The public EC2 uses an IAM instance profile (`devops-s3-role`) for S3 access — no credentials in cron scripts or environment variables. The `aws s3 cp` command on the instance automatically uses the instance metadata service to get temporary credentials.

### Cron Path Issue — Always Use Absolute Paths

Cron runs with a minimal `PATH` that doesn't include `/usr/bin` or `/usr/local/bin`. The AWS CLI at `/usr/bin/aws` must be referenced with its full path in cron entries:

```
* * * * * /usr/bin/aws s3 cp ...   # correct
* * * * * aws s3 cp ...            # fails silently — aws not in cron PATH
```

Same for `scp`: use `/usr/bin/scp`.

---

## 🔧 Step-by-Step Solution

### Phase 1 — Pre-Flight
```bash
# Get existing resources
PRIV_VPC_ID=$(aws ec2 describe-vpcs --region us-east-1 \
    --filters "Name=tag:Name,Values=devops-priv-vpc" \
    --query "Vpcs[0].VpcId" --output text)
# ... etc
chmod 400 /root/.ssh/devops-key.pem
```

### Phase 2 — Create Public VPC Stack
VPC → Subnet (public IP on launch) → IGW → Public route table (0.0.0.0/0 → IGW) → Associate

### Phase 3 — Launch Public EC2
Ubuntu AMI, same key pair, public subnet, security group allowing SSH + private VPC CIDR

### Phase 4 — S3 + IAM Role
Create private bucket → create role with `AmazonS3FullAccess` → create instance profile → attach to public EC2

### Phase 5 — VPC Peering
Create peering (priv→pub) → accept → update devops-priv-rt → update devops-pub-rt

### Phase 6 — Key Distribution
Copy key to public EC2 → copy key to private EC2 (via ProxyJump)

### Phase 7 — Cron Configuration
Private EC2: `scp /var/log/boots.log ubuntu@<pub-priv-ip>:/home/ubuntu/boots.log`
Public EC2: `aws s3 cp /home/ubuntu/boots.log s3://devops-s3-logs-28138/devops-priv-vpc/boot/boots.log`

### Phase 8 — Verify
```bash
aws s3 ls s3://devops-s3-logs-28138/devops-priv-vpc/boot/
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- VPC PEERING ---
PEER_ID=$(aws ec2 create-vpc-peering-connection \
    --vpc-id $PRIV_VPC_ID --peer-vpc-id $PUB_VPC_ID --region $REGION \
    --query "VpcPeeringConnection.VpcPeeringConnectionId" --output text)
aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id $PEER_ID --region $REGION

# --- ROUTE UPDATES ---
aws ec2 create-route --route-table-id $PRIV_RT_ID \
    --destination-cidr-block $PUB_VPC_CIDR \
    --vpc-peering-connection-id $PEER_ID --region $REGION
aws ec2 create-route --route-table-id $PUB_RT_ID \
    --destination-cidr-block $PRIV_VPC_CIDR \
    --vpc-peering-connection-id $PEER_ID --region $REGION

# --- SSH VIA JUMP HOST ---
ssh -i /root/.ssh/devops-key.pem -o StrictHostKeyChecking=no \
    -o ProxyJump="ubuntu@$PUB_EC2_PUB_IP" ubuntu@$PRIV_EC2_IP

# --- MANUAL S3 UPLOAD TEST ---
ssh -i /root/.ssh/devops-key.pem ubuntu@$PUB_EC2_PUB_IP \
    "aws s3 cp /home/ubuntu/boots.log s3://devops-s3-logs-28138/devops-priv-vpc/boot/boots.log"

# --- VERIFY S3 ---
aws s3 ls s3://devops-s3-logs-28138/devops-priv-vpc/boot/ --region $REGION
aws s3 cp s3://devops-s3-logs-28138/devops-priv-vpc/boot/boots.log /tmp/ --region $REGION
cat /tmp/boots.log
```

---

## ⚠️ Common Mistakes

**1. Updating only one route table for VPC peering**
The peering connection becoming `active` doesn't automatically route traffic. Both `devops-priv-rt` and `devops-pub-rt` need explicit routes pointing the other VPC's CIDR at the peering connection ID. Missing the public route table update is the confirmed failure mode from this task — the validator explicitly reports "Public VPC route table is missing a route to Private VPC via VPC Peering." Always verify both route tables with `describe-route-tables` before proceeding.

**2. Using relative paths in cron jobs**
Cron's minimal PATH doesn't include `/usr/bin`. Using `aws s3 cp` or `scp` without absolute paths produces silent failures — cron runs, logs nothing meaningful, and the file never moves. Always use `/usr/bin/aws`, `/usr/bin/scp`, `/usr/bin/rsync`.

**3. ProxyJump SCP doesn't inherit the `-i KEY_FILE` for the jump hop**
`scp -i KEY_FILE -o ProxyJump="ubuntu@JUMP_HOST" ...` applies the key to the final destination auth, not the jump host. The jump host fails with `Permission denied (publickey)`. Fix: SSH into the public EC2 first (it already has the key from an earlier `scp`), then run all further `scp` and `ssh` commands from inside the public EC2 where the key is present at `/home/ubuntu/.ssh/devops-key.pem`.

**4. Uploading placeholder content instead of the real log file**
The validator checks the *content* of `devops-priv-vpc/boot/boots.log` in S3, not just its existence. Uploading a test string like `"Test upload - $(date)"` fails with "Unexpected content in boots.log". The first S3 upload must pull the actual `/var/log/boots.log` from the private EC2 via SCP, then push that real file to S3.
[O
**5. Security groups blocking the SCP path**
The public EC2's security group must allow inbound SSH (port 22) from the private VPC's CIDR block — not just from the internet. VPC peering routes the traffic privately, but the security group still enforces port-level rules on each side.

**6. Wrong S3 path — missing the full prefix**
The task requires the file at `devops-priv-vpc/boot/boots.log`. The `aws s3 cp` command must specify the full key path. Uploading to just `boots.log` is a different S3 object and the validator won't find it.

**7. IAM inline policy blocked (`iam:PutRolePolicy`)**
Same constraint as Days 47–48. For `devops-s3-role`, use `ManagedPolicyArns: [AmazonS3FullAccess]` rather than a custom inline policy. The managed policy is broader but works in this environment where `iam:PutRolePolicy` is blocked.

---

## 🔍 Troubleshooting Reference

These diagnostics come from actual failures encountered during this task.

**Check both route tables have peering routes:**
```bash
REGION="us-east-1"
PRIV_RT_ID=$(aws ec2 describe-route-tables --region $REGION     --filters "Name=tag:Name,Values=devops-priv-rt"     --query "RouteTables[0].RouteTableId" --output text)
PUB_RT_ID=$(aws ec2 describe-route-tables --region $REGION     --filters "Name=tag:Name,Values=devops-pub-rt"     --query "RouteTables[0].RouteTableId" --output text)

aws ec2 describe-route-tables --route-table-ids $PRIV_RT_ID $PUB_RT_ID --region $REGION     --query "RouteTables[*].{Name:Tags[?Key=='Name'].Value|[0],Routes:Routes[*].{Dest:DestinationCidrBlock,Peer:VpcPeeringConnectionId}}"     --output json
```

**Test port 22 reachability from public EC2 to private EC2 (over peering):**
```bash
ssh -i /root/.ssh/devops-key.pem ubuntu@$PUB_EC2_PUB_IP     "nc -z -w5 $PRIV_EC2_IP 22 && echo 'reachable' || echo 'BLOCKED'"
```

**Add the missing public route table route (if forgotten):**
```bash
PEER_ID=$(aws ec2 describe-vpc-peering-connections --region $REGION     --filters "Name=tag:Name,Values=devops-vpc-peering"     --query "VpcPeeringConnections[0].VpcPeeringConnectionId" --output text)
aws ec2 create-route --route-table-id $PUB_RT_ID     --destination-cidr-block $PRIV_VPC_CIDR     --vpc-peering-connection-id $PEER_ID --region $REGION
```

**Check cron logs on both instances:**
```bash
# SCP log on private EC2 (via public EC2)
ssh -i /root/.ssh/devops-key.pem ubuntu@$PUB_EC2_PUB_IP     "ssh -i ~/.ssh/devops-key.pem ubuntu@$PRIV_EC2_IP 'cat ~/scp.log'"

# S3 upload log on public EC2
ssh -i /root/.ssh/devops-key.pem ubuntu@$PUB_EC2_PUB_IP "cat ~/s3-upload.log"
```

**Re-upload real boots.log to S3 (if content validation failed):**
```bash
ssh -i /root/.ssh/devops-key.pem ubuntu@$PUB_EC2_PUB_IP << 'REUP'
scp -i ~/.ssh/devops-key.pem -o StrictHostKeyChecking=no     ubuntu@PRIV_EC2_IP:/var/log/boots.log ~/boots.log
/usr/bin/aws s3 cp ~/boots.log     s3://BUCKET/devops-priv-vpc/boot/boots.log --region us-east-1
REUP
```

---

## 🌍 Real-World Context

**This architecture mirrors a common production log aggregation pattern:**

```
Private app servers (no internet)
  → [Fluentd/Filebeat via VPC peering or PrivateLink]
  → Log aggregation layer (Logstash, FluentBit forwarder)
  → S3 (raw storage) → Athena / CloudWatch Logs Insights (analysis)
```

The hand-rolled SCP/cron approach here is the educational version. Production implementations use:
- **AWS Systems Manager (SSM) Agent**: collect logs from private instances without any SSH or VPC peering
- **CloudWatch Agent**: ship logs directly to CloudWatch Logs from private instances (uses AWS endpoints, works without internet access via VPC endpoints)
- **AWS DataSync**: managed service for large-scale file transfer to S3, with bandwidth throttling and data integrity validation
- **S3 VPC Endpoint**: lets private instances push to S3 without internet access, without NAT Gateway, at no data transfer cost

The VPC peering pattern is valuable for cross-VPC database access, microservices communication, or centralizing logging from multiple VPCs — but for S3 access specifically, a Gateway Endpoint is cheaper and simpler.

---

## ❓ Interview Q&A

**Q1. What is VPC peering and what are its limitations?**
> VPC peering is a private network connection between two VPCs — traffic travels over AWS's backbone, never the public internet. Both VPCs' CIDR blocks must not overlap, and routes must be added to both sides' route tables explicitly. Key limitations: peering is non-transitive (A↔B and B↔C doesn't mean A↔C), peering doesn't support edge-to-edge routing (traffic can't go through the peered VPC to reach its IGW, VPN, or Direct Connect), and there's no bandwidth limit but each connection is point-to-point (N VPCs need N*(N-1)/2 peering connections vs. one Transit Gateway for N VPCs). For complex multi-VPC topologies, AWS Transit Gateway is the managed hub-and-spoke alternative.

**Q2. Why does SCP from private EC2 to public EC2 work over VPC peering?**
> Once the peering connection is active and both route tables have the other VPC's CIDR pointing at the peering connection, the private EC2 can reach the public EC2's private IP directly — no public IP involved. The private EC2's SCP connects to the public EC2's private IP on port 22 (SSH). The packet: private subnet → devops-priv-rt routes the public VPC CIDR to the peering → AWS delivers it to the public EC2's ENI. The public EC2's security group must allow port 22 inbound from the private VPC CIDR. Return traffic follows the reverse path via devops-pub-rt.

**Q3. Why use `ProxyJump` instead of a NAT or bastion in a separate subnet?**
> `ProxyJump` (formerly `ProxyCommand`) uses the jump host for SSH-level forwarding — SSH connects to the jump host and forwards the connection through it. No additional infrastructure, no separate bastion subnet or security group. The limitation: it requires SSH access to the jump host, which means the private EC2 only needs an inbound SSH rule from the jump host's IP (or private IP), not from the operator's laptop directly. In production, AWS Systems Manager Session Manager is the preferred approach — it provides shell access to private instances without any SSH port open at all, via the SSM agent and AWS's control plane.

**Q4. What would you use instead of SCP + cron for production log shipping?**
> The CloudWatch Agent or a log shipper like Fluent Bit. Both run as a process on the private EC2, read log files, and push to CloudWatch Logs (or S3) using AWS API calls. Since private instances can reach AWS service endpoints via VPC Endpoints (without internet access), this works without VPC peering, NAT Gateways, or jump hosts. The advantages: automatic log rotation handling, structured JSON logging, filtering, and sub-second latency — all without any SSH or file transfer infrastructure. For S3 specifically, an S3 Gateway Endpoint gives the private instance direct access at zero data transfer cost.

**Q5. What is the S3 object key format and why does the full prefix matter?**
> In S3, there are no actual folders — only keys with slashes that appear as folder structure in the console. `devops-priv-vpc/boot/boots.log` is the full key, and the task requires exactly that path. Uploading to `boots.log` (key at bucket root) or `boot/boots.log` (wrong prefix) is a different S3 object — verification scripts checking `s3://bucket/devops-priv-vpc/boot/boots.log` would show nothing. Always specify the complete key including all "directory" prefixes in the `aws s3 cp` target.

---

## 📚 Resources

- [VPC Peering Guide](https://docs.aws.amazon.com/vpc/latest/peering/what-is-vpc-peering.html)
- [SSH ProxyJump](https://man.openbsd.org/ssh_config#ProxyJump)
- [CloudWatch Agent for Log Shipping](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Install-CloudWatch-Agent.html)
- [Day 29 — VPC Peering Basics](../days/day-29/README.md)
- [Day 37 — EC2 IAM Role for S3](../days/day-37/README.md)
- [Day 45 — NAT Gateway](../days/day-45/README.md)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
