# Day 36 — EC2 + Nginx Behind an ALB (Reusing the Default Security Group)

> **#100DaysOfCloud | Day 36 of 100**

---

## 📌 The Task

> *Launch an EC2 instance running Nginx (via User Data), put it behind an Application Load Balancer, and wire up security groups so the ALB uses the account's `default` security group while the EC2 instance uses a new custom security group that only trusts traffic from the ALB.*

**Requirements:**
| Resource | Detail |
|----------|--------|
| EC2 Instance | `devops-ec2` — Ubuntu AMI, Nginx installed + started via User Data |
| Custom SG | `devops-sg` — attached to EC2, allows port 80 **from the default SG only** |
| ALB | `devops-alb` — uses the **default** security group |
| Target Group | `devops-tg` |
| Routing | ALB port 80 → `devops-tg` → `devops-ec2:80` |
| Final check | Nginx reachable via the **ALB's DNS name** |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### The Twist on the Usual ALB Pattern

Day 24 covered the standard ALB layering: create a dedicated SG for the ALB (open to the internet) and let the EC2 instance's SG reference it as the source. Today's task **inverts which SG goes where**:

| | Day 24 pattern | Day 36 pattern |
|--|----------------|----------------|
| ALB's security group | New custom SG (`xfusion-sg`) | The account's **default** SG |
| EC2's security group | Default SG (untouched) | New custom SG (`devops-sg`) |

The *logic* is identical — public-facing layer trusts the internet, private layer trusts only the public layer — just with the custom and default SGs swapped in terms of which resource they attach to. This is worth doing once this way specifically because it forces you to actually think about what each SG is doing, rather than pattern-matching "ALB always gets the new SG."

### Why the Default SG Needs an Inbound Rule Added

Every VPC's `default` security group ships with exactly one non-trivial inbound rule out of the box: **allow all traffic from other resources in the same security group** (a self-referencing rule). It does **not** allow inbound traffic from the internet (`0.0.0.0/0`) on any port — including port 80.

Since the ALB needs to receive HTTP requests from the public internet, the default SG must have an inbound rule added explicitly:
```
Type: HTTP | Port: 80 | Source: 0.0.0.0/0
```
This is the "Security group adjustments" the task calls out — without this, the ALB itself is unreachable regardless of how correctly everything downstream is wired.

### The Complete Traffic Path

```
Internet
    │  port 80
    ▼
devops-alb  (security group: default SG, now allowing 80 from 0.0.0.0/0)
    │  forwards via listener → target group
    ▼
devops-tg  (target group, health checks on port 80, path "/")
    │  routes to registered target
    ▼
devops-ec2  (security group: devops-sg, allowing 80 ONLY from default SG)
    │  Nginx listening on port 80 (installed via User Data)
    ▼
Response flows back through the same path
```

### Why `devops-sg` References the Default SG as Source — Not a CIDR

```
--source-group <default-sg-id>
```

This means: "accept port 80 traffic only from things that are members of the default SG" — which, after this setup, is the ALB. If you used a CIDR instead (the ALB's IP range), you'd have a moving target — ALB IPs aren't static and can change as AWS scales the load balancer. SG-referencing rules track membership, not addresses, making this the correct and durable approach (same principle as Day 24 and Day 35).

### User Data Recap (from Day 26)

The bootstrap script for Nginx hasn't changed from the established pattern:
```bash
#!/bin/bash
apt-get update -y
apt-get install -y nginx
systemctl start nginx
systemctl enable nginx
```
`apt-get update` first (Ubuntu's package index is stale on a fresh image), then install, then `start` + `enable` (the difference between "running now" and "running now and after every future reboot").

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

[O#### Part 1 — Create the EC2 Security Group (`devops-sg`)

1. **EC2 Console → Security Groups → Create security group**
2. Name: `devops-sg` | Description: `Allow HTTP from default SG (ALB)` | VPC: default VPC
3. **Inbound rules → Add rule:**
   - Type: **HTTP** (auto-fills port 80)
   - Source: **Custom** → search for and select the **default** security group (not a CIDR)
4. **Create security group**

#### Part 2 — Launch the EC2 Instance with User Data

1. **EC2 Console → Launch instances**
2. Name: `devops-ec2`
3. AMI: **Ubuntu Server 22.04 LTS** (or any available Ubuntu AMI)
4. Instance type: `t2.micro`
5. Security group: select **existing** → `devops-sg`
6. **Advanced details → User data** — paste:
```bash
#!/bin/bash
apt-get update -y
apt-get install -y nginx
systemctl start nginx
systemctl enable nginx
```
7. **Launch instance**
8. Wait for **Running** + status checks **2/2 passed**

#### Part 3 — Adjust the Default Security Group for ALB Use

1. **EC2 Console → Security Groups → select `default`**
2. **Inbound rules → Edit inbound rules → Add rule:**
   - Type: **HTTP** | Source: **Anywhere-IPv4** (`0.0.0.0/0`)
3. **Save rules**

This is the step the task refers to as "make appropriate changes in the default security group" — without it, the ALB can't accept public HTTP traffic.

#### Part 4 — Create the Target Group (`devops-tg`)

1. **EC2 Console → Target Groups → Create target group**
2. Target type: **Instances**
3. Name: `devops-tg` | Protocol: **HTTP** | Port: **80** | VPC: default VPC
4. Health check path: `/` (default)
5. **Next** → select `devops-ec2` from the instance list → **Include as pending below** → **Create target group**

#### Part 5 — Create the ALB (`devops-alb`)

1. **EC2 Console → Load Balancers → Create load balancer → Application Load Balancer**
2. Name: `devops-alb` | Scheme: **Internet-facing** | IP type: IPv4
3. VPC: default VPC → select **at least 2 Availability Zones / subnets**
4. Security groups: remove any pre-selected SG → select **default** only
5. Listeners: HTTP : 80 → forward to **devops-tg**
6. **Create load balancer**
7. Wait for state: **Active** (~2–3 minutes)

#### Part 6 — Verify

1. **EC2 Console → Load Balancers → devops-alb** → copy the **DNS name**
2. Open a browser → `http://<alb-dns-name>`
3. You should see the **Nginx welcome page** ✅
4. Also check **Target Groups → devops-tg → Targets** tab → status should be **healthy**

---

### Method 2 — AWS CLI

```bash
#!/bin/bash
set -e
REGION="us-east-1"

# ============================================================
# STEP 1: Resolve default VPC, subnets, and default SG
# ============================================================

echo "=== Step 1: Resolving default networking ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

DEFAULT_SG=$(aws ec2 describe-security-groups --region $REGION \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text)

SUBNET_IDS=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query "Subnets[*].SubnetId" --output text | tr '\t' ' ')

SUBNET1=$(echo $SUBNET_IDS | awk '{print $1}')

echo "VPC: $VPC_ID"
echo "Default SG: $DEFAULT_SG"
echo "Subnets: $SUBNET_IDS"

# ============================================================
# STEP 2: Create devops-sg — allow 80 from the default SG only
# ============================================================

echo ""
echo "=== Step 2: Creating 'devops-sg' ==="

DEVOPS_SG=$(aws ec2 create-security-group \
    --region $REGION \
    --group-name devops-sg \
    --description "devops-ec2 — allow HTTP 80 from default SG (ALB) only" \
    --vpc-id $VPC_ID \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=devops-sg}]' \
    --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $DEVOPS_SG --protocol tcp --port 80 \
    --source-group $DEFAULT_SG --region $REGION

echo "devops-sg: $DEVOPS_SG (port 80 from default SG $DEFAULT_SG)"

# ============================================================
# STEP 3: Open port 80 on the default SG (for ALB → internet)
# ============================================================

echo ""
echo "=== Step 3: Adjusting default SG for ALB use ==="

aws ec2 authorize-security-group-ingress \
    --group-id $DEFAULT_SG --protocol tcp --port 80 \
    --cidr 0.0.0.0/0 --region $REGION \
    2>/dev/null && echo "Port 80 opened on default SG" || echo "Rule may already exist"

# ============================================================
# STEP 4: Resolve latest Ubuntu 22.04 AMI
# ============================================================

echo ""
echo "=== Step 4: Resolving Ubuntu AMI ==="

AMI_ID=$(aws ec2 describe-images --region $REGION \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

echo "AMI: $AMI_ID"

# ============================================================
# STEP 5: Launch devops-ec2 with Nginx User Data, devops-sg attached
# ============================================================

echo ""
echo "=== Step 5: Launching devops-ec2 ==="

USER_DATA=$(cat <<'EOF'
#!/bin/bash
apt-get update -y
apt-get install -y nginx
systemctl start nginx
systemctl enable nginx
EOF
)

INSTANCE_ID=$(aws ec2 run-instances \
    --region $REGION \
    --image-id $AMI_ID \
    --instance-type t2.micro \
    --subnet-id $SUBNET1 \
    --security-group-ids $DEVOPS_SG \
    --associate-public-ip-address \
    --user-data "$USER_DATA" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=devops-ec2}]' \
    --query "Instances[0].InstanceId" --output text)

echo "Instance: $INSTANCE_ID"

aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID --region $REGION

echo "devops-ec2 is running and healthy"

# ============================================================
# STEP 6: Create target group (devops-tg) and register the instance
# ============================================================

echo ""
echo "=== Step 6: Creating target group 'devops-tg' ==="

TG_ARN=$(aws elbv2 create-target-group \
    --region $REGION \
    --name devops-tg \
    --protocol HTTP --port 80 \
    --vpc-id $VPC_ID \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path "/" \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --query "TargetGroups[0].TargetGroupArn" --output text)

aws elbv2 register-targets \
    --region $REGION \
    --target-group-arn $TG_ARN \
    --targets Id=$INSTANCE_ID,Port=80

echo "Target group: $TG_ARN (registered $INSTANCE_ID)"

# ============================================================
# STEP 7: Create the ALB (devops-alb) using the DEFAULT SG
# ============================================================

echo ""
echo "=== Step 7: Creating ALB 'devops-alb' ==="

ALB_ARN=$(aws elbv2 create-load-balancer \
    --region $REGION \
    --name devops-alb \
    --type application \
    --scheme internet-facing \
    --subnets $SUBNET_IDS \
    --security-groups $DEFAULT_SG \
    --tags Key=Name,Value=devops-alb \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)

echo "ALB: $ALB_ARN"

# ============================================================
# STEP 8: Create listener — port 80 → devops-tg
# ============================================================

echo ""
echo "=== Step 8: Creating listener ==="

aws elbv2 create-listener \
    --region $REGION \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN

# ============================================================
# STEP 9: Wait for ALB active, verify
# ============================================================

echo ""
echo "=== Step 9: Waiting for ALB to become active ==="

aws elbv2 wait load-balancer-available \
    --load-balancer-arns $ALB_ARN --region $REGION

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN --region $REGION \
    --query "LoadBalancers[0].DNSName" --output text)

echo "ALB DNS: $ALB_DNS"

echo ""
echo "=== Target health (allow 30s for first check) ==="
sleep 30
aws elbv2 describe-target-health \
    --target-group-arn $TG_ARN --region $REGION \
    --query "TargetHealthDescriptions[*].{Target:Target.Id,State:TargetHealth.State}" \
    --output table

echo ""
echo "=== HTTP test ==="
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" "http://$ALB_DNS"

echo ""
echo "============================================"
echo "  EC2:          devops-ec2 ($INSTANCE_ID)"
echo "  EC2 SG:       devops-sg ($DEVOPS_SG)"
echo "  ALB:          devops-alb"
echo "  ALB SG:       default ($DEFAULT_SG)"
echo "  Target Group: devops-tg"
echo "  ALB DNS:      http://$ALB_DNS"
echo "============================================"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CREATE EC2 SG, ALLOW 80 FROM DEFAULT SG ---
DEVOPS_SG=$(aws ec2 create-security-group --group-name devops-sg \
    --description "EC2 SG - HTTP from default SG only" --vpc-id $VPC_ID \
    --region $REGION --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress --group-id $DEVOPS_SG \
    --protocol tcp --port 80 --source-group $DEFAULT_SG --region $REGION

# --- OPEN 80 ON DEFAULT SG (for ALB) ---
aws ec2 authorize-security-group-ingress --group-id $DEFAULT_SG \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION

# --- LAUNCH EC2 WITH NGINX USER DATA ---
aws ec2 run-instances --image-id $AMI_ID --instance-type t2.micro \
    --subnet-id $SUBNET1 --security-group-ids $DEVOPS_SG \
    --associate-public-ip-address --user-data file://userdata.sh \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=devops-ec2}]' \
    --region $REGION

# --- CREATE TARGET GROUP ---
TG_ARN=$(aws elbv2 create-target-group --name devops-tg \
    --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type instance \
    --region $REGION --query "TargetGroups[0].TargetGroupArn" --output text)

aws elbv2 register-targets --target-group-arn $TG_ARN \
    --targets Id=$INSTANCE_ID,Port=80 --region $REGION

# --- CREATE ALB WITH DEFAULT SG ---
ALB_ARN=$(aws elbv2 create-load-balancer --name devops-alb \
    --type application --subnets $SUBNET1 $SUBNET2 \
    --security-groups $DEFAULT_SG --region $REGION \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)

# --- CREATE LISTENER ---
aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
    --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN --region $REGION

# --- VERIFY ---
aws elbv2 describe-target-health --target-group-arn $TG_ARN --region $REGION
curl http://$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
    --query "LoadBalancers[0].DNSName" --output text --region $REGION)
```

---

## ⚠️ Common Mistakes

**1. Forgetting to open port 80 on the default SG**
The default SG only allows traffic from members of itself by default — never from the internet. Since the ALB is now using the default SG and needs to receive public traffic, you must explicitly add an inbound rule for port 80 from `0.0.0.0/0`. Skipping this makes the ALB completely unreachable, and the failure looks identical to a DNS or routing problem — always check SG rules first.

**2. Attaching `devops-sg` to the ALB instead of the EC2 instance**
Re-read the requirement carefully: `devops-sg` goes on the **EC2 instance**, and the **default SG** goes on the **ALB**. It's easy to default to "new SG goes on the load balancer" out of habit from Day 24's pattern — this task deliberately swaps that to test understanding of the underlying logic, not memorized steps.

**3. Using a CIDR instead of `--source-group` for the EC2 SG rule**
`devops-sg`'s inbound rule should reference the default SG by ID (`--source-group`), not an IP range. This way the rule continues to work correctly no matter what the ALB's actual IP addresses are at any given moment — they change as AWS scales the ALB internally.

**4. Deploying the ALB into only one subnet/AZ**
Same constraint as every previous ALB task: `create-load-balancer` requires at least two subnets in two different Availability Zones. A single-subnet attempt fails validation immediately.

**5. Testing the ALB DNS before targets pass health checks**
A target sits in `initial` state for the first ~30-60 seconds while the first couple of health checks run. Testing the ALB DNS during this window can return a 503 Service Unavailable even though everything is configured correctly — wait for the target's health state to show `healthy` in `describe-target-health` before troubleshooting further.

**6. Missing `apt-get update -y` before `apt-get install -y nginx` in User Data**
Same as Day 26 — Ubuntu's package cache is stale by default on a freshly launched instance. Skipping the update step risks the install silently failing or pulling an outdated Nginx version.

---

## 🌍 Real-World Context

The pattern of reusing the **default security group** for one tier of an application, rather than always creating a new one, comes up in smaller AWS environments or sandbox/dev accounts where minimizing the number of security groups in play is a deliberate simplification — fewer SGs to audit, fewer to keep mental track of. In larger production environments, this is generally discouraged: the default SG is shared infrastructure that many unrelated resources might also be using, and tightly coupling its rules to one specific application's ALB makes it harder to reason about what's actually allowed to talk to what across the account. Most production setups create a dedicated SG per logical tier (ALB SG, app SG, DB SG) explicitly, exactly as Day 24 did — this task's value is purely in exercising flexibility with the underlying SG model, not in recommending the default-SG-reuse pattern for real deployments.
[I
This is also a good moment to point out: the `default` SG existing in every VPC with implicit self-referencing rules is itself a common audit finding. Security tooling (AWS Config, Trusted Advisor, third-party CSPM tools) frequently flags VPCs where the default SG has been modified beyond its baseline state, precisely because it's easy to lose track of what's been added to it over time across multiple unrelated tasks — exactly the risk this lab surfaces in miniature.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. What inbound rule does the default security group have out of the box, and why doesn't it allow internet traffic?**
> Every new VPC's default SG ships with a single self-referencing inbound rule: allow all traffic from other resources that are also members of the default SG. This is a friendly-but-private default — instances in the same SG can talk to each other freely (useful for quick experimentation), but nothing from outside the SG, including the internet, can get in. AWS deliberately avoids shipping any VPC with an open-to-the-world default, since that would be a serious security exposure for anyone who launches resources without configuring SGs explicitly. Any internet-facing access — like an ALB needing to receive public HTTP — has to be added as an explicit rule, regardless of which SG is involved.

**Q2. Why is it considered an anti-pattern to attach the default security group to production resources?**
> The default SG is implicitly shared by anything in the VPC that doesn't get an explicit SG assignment, and its rules apply uniformly to every resource attached to it. If you start adding rules to the default SG for one application's needs (say, opening port 80 for an ALB), those rules now apply to every other resource that happens to also be using the default SG — intentionally or by oversight. This makes it much harder to reason about your actual security posture: you can no longer look at "what's attached to this SG" and know it's scoped to one purpose. Production environments avoid this by giving every logical tier (load balancer, application, database) its own dedicated SG with rules scoped exactly to that tier's needs.

**Q3. If a target group shows a target in `unhealthy` state, but you've already confirmed the security groups are correct, what else would you check?**
> Beyond SGs, the next places to look: confirm Nginx (or whatever service) is actually running and listening on the expected port inside the instance (`systemctl status nginx`, `ss -tlnp | grep :80`); confirm the health check path configured on the target group (default `/`) actually returns a 2xx — if the app returns a redirect or a non-200 on `/`, the health check fails even though the service is technically up; check the health check's configured port matches the traffic port (these can be set independently); and check Network ACLs on the subnet, which are stateless and can silently block traffic that the SG explicitly allows.

**Q4. What's the practical difference between giving the ALB the default SG vs a purpose-built SG, from an operational standpoint?**
> Functionally, if the rules end up identical, there's no difference in how traffic flows — a security group is just a set of rules, and AWS doesn't care what you named it or whether it's "the default one." The operational difference is entirely about clarity and blast radius. A purpose-built SG named something like `devops-alb-sg` immediately tells anyone auditing the account what it's for and what's attached to it. The default SG accumulates rules over time from whoever's touched the account, with no naming signal about why any given rule exists — six months later, nobody remembers why port 80 is open on the default SG, or whether it's safe to remove that rule without breaking something unrelated.

**Q5. Why does an ALB require at least two subnets in two different Availability Zones, even for a simple test setup like this one?**
> This is a hard requirement enforced by the `create-load-balancer` API, not a recommendation — AWS designed the ALB to always be deployed in a way that survives a single AZ failure. Even for throwaway test infrastructure, you can't create an ALB in a single subnet; the API call itself fails validation with `At least two subnets in two different Availability Zones must be specified`. This is a deliberate design choice on AWS's part: there's no "single-AZ ALB" option, which means every ALB you ever create — test or production — gets baseline multi-AZ resilience by construction, whether or not the workload behind it actually needs it.

**Q6. The Nginx welcome page loads fine when you curl the EC2 instance's public IP directly, but times out via the ALB DNS. What's the most likely cause?**
> Given that direct access to the instance works, Nginx itself is healthy and correctly configured — the problem is somewhere in the ALB → target group → instance path specifically, not the instance itself. The most likely culprit is the security group on the EC2 instance not allowing inbound traffic from the ALB's security group (`devops-sg` needs `--source-group` pointing at whatever SG the ALB is using). The instance's SG might be allowing traffic from your personal IP (which is why direct curl works) but not from the ALB. The fix is exactly the rule from this task: confirm the EC2's SG has an inbound rule for port 80 sourced from the ALB's security group, not just your own IP or a narrower CIDR.

**Q7. How would you modify this setup so that only traffic from a specific corporate IP range can reach the ALB, while keeping the rest of the configuration the same?**
[O> Change the source on the public-facing inbound rule. Right now, the rule on whichever SG the ALB uses says `Type: HTTP, Port: 80, Source: 0.0.0.0/0` — replace `0.0.0.0/0` with the corporate CIDR block, e.g. `203.0.113.0/24`. Nothing else in the chain needs to change: the target group, the listener, and the EC2-to-ALB SG relationship (`devops-sg` trusting the ALB's SG) all stay exactly the same, because that part of the path was never exposed to the internet in the first place — it was always scoped to "things in the ALB's SG." Restricting the ALB's own internet-facing rule is the single change point for this kind of access control.

---

## 📚 Resources

- [AWS Docs — Default Security Groups](https://docs.aws.amazon.com/vpc/latest/userguide/default-custom-security-groups.html)
- [AWS Docs — Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html)
- [Target Group Health Checks](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html)
- [Day 24 — Original ALB Setup](../day-24/README.md)
- [Day 26 — Nginx via User Data](../day-26/README.md)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
