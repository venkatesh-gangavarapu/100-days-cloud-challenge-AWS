# Day 24 — Setting Up an Application Load Balancer (ALB)

> **#100DaysOfCloud | Day 24 of 100**

---

## 📌 The Task

> *Set up an ALB in front of a running EC2 instance (`xfusion-ec2`) with Nginx on port 80. All public traffic on port 80 should route through the ALB to the instance.*

**Requirements:**
| Resource | Name / Detail |
|----------|--------------|
| Load Balancer | `xfusion-alb` (Application Load Balancer) |
| Target Group | `xfusion-tg` |
| Security Group | `xfusion-sg` — open port 80 to public |
| Instance | `xfusion-ec2` (Nginx on port 80) |
| ALB routing | Port 80 → `xfusion-tg` → `xfusion-ec2:80` |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### What Is an Application Load Balancer?

An **Application Load Balancer (ALB)** operates at **Layer 7 (HTTP/HTTPS)** — it understands application protocols, not just TCP connections. This allows it to make routing decisions based on:
- URL path (`/api/*` → API servers, `/images/*` → static servers)
- HTTP headers and host names (virtual hosting)
- Query strings and methods
- Source IP conditions

Compared to a Classic Load Balancer (Layer 4, legacy) and Network Load Balancer (Layer 4, TCP/UDP), the ALB is the right choice for any web application running HTTP/HTTPS.

### The Three Components Required

Every ALB setup requires three resources wired together:

```
Internet
    │
    ▼
[ALB: xfusion-alb]  ← has Listener (port 80) + security group
    │
    ▼
[Target Group: xfusion-tg]  ← health check config + routing rule
    │
    ▼
[EC2 Target: xfusion-ec2:80]  ← registered target
```

| Component | What It Does |
|-----------|-------------|
| **Load Balancer** | The entry point — has DNS name, holds listeners, spans AZs |
| **Listener** | Binds a port (80) to a rule set — "on port 80, forward to target group X" |
| **Target Group** | A pool of targets (EC2 instances, IPs, Lambda) with health checks |

### Security Group Design — Two Layers

This task involves two security groups working together:

| Security Group | Attached To | Inbound Rule |
|---------------|-------------|-------------|
| `xfusion-sg` | ALB | Port 80 from `0.0.0.0/0` (internet) |
| Default SG | EC2 instance | Port 80 from `xfusion-sg` only |

This is the correct **layered security model**:
- The internet can only reach the ALB (port 80)
- The EC2 instance only accepts traffic from the ALB's security group
- Direct public access to the EC2 instance on port 80 is blocked

### ALB Health Checks

The Target Group performs **health checks** against each registered target. If a target fails health checks, the ALB stops sending traffic to it. For this task, the health check is:
- Protocol: HTTP
- Port: 80 (traffic port)
- Path: `/` (root path, Nginx default page)
- Healthy threshold: 2 consecutive successes
- Unhealthy threshold: 2 consecutive failures

An instance that fails health checks becomes `unhealthy` in the target group and is excluded from rotation until it recovers.

### ALB DNS Name vs Elastic IP

ALBs use **DNS names** (not IP addresses) as their stable entry point:
```
xfusion-alb-1234567890.us-east-1.elb.amazonaws.com
```

The IP addresses behind an ALB change dynamically as AWS scales the load balancer — you should **never** hardcode an ALB's IP. Always reference the DNS name (or alias it in Route 53).

### ALB Spans Multiple AZs

An ALB must be deployed across at least **two Availability Zones** (two subnets in different AZs). This is required — a single-AZ ALB deployment is rejected by the API. The task requires finding at least two subnets to deploy the ALB into.

---

## 🔧 Step-by-Step Solution

### Full CLI Workflow

```bash
# ============================================================
# SETUP: Get required resource IDs
# ============================================================
REGION="us-east-1"

# Get instance details for xfusion-ec2
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=xfusion-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

INSTANCE_AZ=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].Placement.AvailabilityZone" \
    --output text)

echo "Instance: $INSTANCE_ID | AZ: $INSTANCE_AZ"

# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

echo "VPC: $VPC_ID"

# Get at least two subnets in different AZs (ALB requirement)
SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query "Subnets[*].SubnetId" --output text | tr '\t' ' ')

echo "Subnets: $SUBNET_IDS"

# ============================================================
# STEP 1: Create the ALB security group (xfusion-sg)
# Opens port 80 to the public
# ============================================================
echo ""
echo "=== Step 1: Creating security group 'xfusion-sg' ==="

ALB_SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name xfusion-sg \
    --description "ALB security group - allow HTTP port 80 from internet" \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=xfusion-sg}]' \
    --query "GroupId" --output text)
[O
echo "ALB Security Group: $ALB_SG_ID"

# Add inbound rule: port 80 from anywhere
aws ec2 authorize-security-group-ingress \
    --group-id "$ALB_SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    --region "$REGION"

echo "Port 80 open to 0.0.0.0/0 on $ALB_SG_ID"

# ============================================================
# STEP 2: Update the EC2 instance's security group
# Allow port 80 ONLY from the ALB security group
# ============================================================
echo ""
echo "=== Step 2: Updating EC2 security group to allow traffic from ALB ==="

# Get the security group(s) attached to xfusion-ec2
EC2_SG_ID=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
    --output text)

echo "EC2 Security Group: $EC2_SG_ID"

# Allow port 80 from the ALB security group (not from internet directly)
aws ec2 authorize-security-group-ingress \
    --group-id "$EC2_SG_ID" \
    --protocol tcp \
    --port 80 \
    --source-group "$ALB_SG_ID" \
    --region "$REGION"

echo "Port 80 from ALB SG ($ALB_SG_ID) allowed on EC2 SG ($EC2_SG_ID)"

# ============================================================
# STEP 3: Create the Target Group (xfusion-tg)
# ============================================================
echo ""
echo "=== Step 3: Creating target group 'xfusion-tg' ==="

TG_ARN=$(aws elbv2 create-target-group \
    --region "$REGION" \
    --name xfusion-tg \
    --protocol HTTP \
    --port 80 \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-port "80" \
    --health-check-path "/" \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text)

echo "Target Group ARN: $TG_ARN"

# ============================================================
# STEP 4: Register xfusion-ec2 as a target in the group
# ============================================================
echo ""
echo "=== Step 4: Registering $INSTANCE_ID in target group ==="

aws elbv2 register-targets \
    --region "$REGION" \
    --target-group-arn "$TG_ARN" \
    --targets Id="$INSTANCE_ID",Port=80

echo "Instance registered in target group"

# ============================================================
# STEP 5: Create the Application Load Balancer (xfusion-alb)
# Requires at least 2 subnets in different AZs
# ============================================================
echo ""
echo "=== Step 5: Creating ALB 'xfusion-alb' ==="

ALB_ARN=$(aws elbv2 create-load-balancer \
    --region "$REGION" \
    --name xfusion-alb \
    --type application \
    --scheme internet-facing \
    --ip-address-type ipv4 \
    --subnets $SUBNET_IDS \
    --security-groups "$ALB_SG_ID" \
    --tags Key=Name,Value=xfusion-alb \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text)

echo "ALB ARN: $ALB_ARN"

# ============================================================
# STEP 6: Create a Listener on port 80 → forward to xfusion-tg
# ============================================================
echo ""
echo "=== Step 6: Creating listener (port 80 → xfusion-tg) ==="

LISTENER_ARN=$(aws elbv2 create-listener \
    --region "$REGION" \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
    --query "Listeners[0].ListenerArn" \
    --output text)

echo "Listener ARN: $LISTENER_ARN"

# ============================================================
# STEP 7: Wait for ALB to become active
# ============================================================
echo ""
echo "=== Step 7: Waiting for ALB to become active ==="

aws elbv2 wait load-balancer-available \
    --load-balancer-arns "$ALB_ARN" \
    --region "$REGION"

echo "ALB is active"

# ============================================================
# STEP 8: Get the ALB DNS name and verify
# ============================================================
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" --region "$REGION" \
    --query "LoadBalancers[0].DNSName" --output text)

echo ""
echo "============================================"
echo "  ALB DNS: $ALB_DNS"
echo "  Test:    curl http://$ALB_DNS"
echo "============================================"

# Test the ALB (Nginx should respond)
echo ""
echo "=== Testing ALB endpoint ==="
sleep 10   # brief pause for health checks to run
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" "http://$ALB_DNS"
```

---

### Verifying the Full Setup

```bash
# Check ALB state
aws elbv2 describe-load-balancers \
    --names xfusion-alb --region us-east-1 \
    --query "LoadBalancers[0].{State:State.Code,DNS:DNSName,AZs:AvailabilityZones[*].ZoneName}" \
    --output table

# Check target health
aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --region us-east-1 \
    --query "TargetHealthDescriptions[*].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}" \
    --output table

# Check listener rules
aws elbv2 describe-rules \
    --listener-arn "$LISTENER_ARN" \
    --region us-east-1 \
    --query "Rules[*].{Priority:Priority,Action:Actions[0].Type,TargetGroup:Actions[0].ForwardConfig.TargetGroups[0].TargetGroupArn}" \
    --output table

# Full curl test
curl -v http://$ALB_DNS
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CREATE ALB SECURITY GROUP ---
ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name xfusion-sg --description "ALB HTTP SG" \
    --vpc-id $VPC_ID --region $REGION \
    --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION

# --- UPDATE EC2 SG (allow from ALB SG only) ---
aws ec2 authorize-security-group-ingress \
    --group-id $EC2_SG_ID --protocol tcp --port 80 \
    --source-group $ALB_SG_ID --region $REGION

# --- CREATE TARGET GROUP ---
TG_ARN=$(aws elbv2 create-target-group \
    --name xfusion-tg --protocol HTTP --port 80 \
    --vpc-id $VPC_ID --target-type instance --region $REGION \
    --query "TargetGroups[0].TargetGroupArn" --output text)

# --- REGISTER TARGET ---
aws elbv2 register-targets \
    --target-group-arn $TG_ARN \
    --targets Id=$INSTANCE_ID,Port=80 --region $REGION

# --- CREATE ALB ---
ALB_ARN=$(aws elbv2 create-load-balancer \
    --name xfusion-alb --type application --scheme internet-facing \
    --subnets $SUBNET1 $SUBNET2 \
    --security-groups $ALB_SG_ID --region $REGION \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)

# --- CREATE LISTENER ---
aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN --region $REGION

# --- WAIT FOR ACTIVE ---
aws elbv2 wait load-balancer-available \
    --load-balancer-arns $ALB_ARN --region $REGION

# --- GET DNS NAME ---
aws elbv2 describe-load-balancers --names xfusion-alb --region $REGION \
    --query "LoadBalancers[0].DNSName" --output text

# --- CHECK TARGET HEALTH ---
aws elbv2 describe-target-health --target-group-arn $TG_ARN --region $REGION

# --- TEST ---
curl http://$ALB_DNS

# --- CLEANUP ---
aws elbv2 delete-listener --listener-arn $LISTENER_ARN --region $REGION
aws elbv2 deregister-targets --target-group-arn $TG_ARN \
    --targets Id=$INSTANCE_ID --region $REGION
aws elbv2 delete-target-group --target-group-arn $TG_ARN --region $REGION
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN --region $REGION
aws ec2 delete-security-group --group-id $ALB_SG_ID --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Deploying the ALB with only one subnet**
`create-load-balancer` requires at least two subnets in **different Availability Zones**. Providing a single subnet fails with `ValidationError: At least two subnets in two different Availability Zones must be specified`. Use the default subnets from multiple AZs in the VPC.

**2. Attaching the ALB security group to the EC2 instance instead of creating a separate one**
The ALB and the EC2 instance should have separate security groups. The ALB's SG (`xfusion-sg`) accepts internet traffic on port 80. The EC2's SG should allow port 80 only from `xfusion-sg` — not from the internet directly. Using one SG for both defeats the layered security model.

**3. Forgetting to open port 80 on the EC2's security group from the ALB**
The most common "target unhealthy" debugging scenario: the ALB SG is correctly configured, the target is registered, but health checks fail because the EC2 security group doesn't allow port 80 from the ALB. The ALB health checks originate from the ALB's IP space, which is represented by its security group. Add `source-group: alb-sg-id` to the EC2 SG inbound rules.

**4. Targets stuck in `initial` state after registration**
Newly registered targets spend a brief period in `initial` state while the first health checks run. After two successful health checks (with default interval of 30 seconds), the target becomes `healthy`. If a target stays `initial` for more than 2 minutes, it indicates a health check failure — check security groups, verify Nginx is running on port 80, and confirm the health check path returns a 200.

**5. Registering the target without specifying the port**
`register-targets` with just `Id=$INSTANCE_ID` uses the target group's default port (80 in this case). Explicitly specifying `Id=$INSTANCE_ID,Port=80` is clearer and required when the target port differs from the target group port.

**6. Using the ALB ARN instead of the Target Group ARN for `describe-target-health`**
These are different ARNs. `describe-target-health` requires the Target Group ARN — not the ALB ARN. `describe-load-balancers` gives the ALB ARN. `list-target-groups` (or `describe-target-groups`) gives the TG ARN.

---

## 🌍 Real-World Context

The ALB + Target Group + EC2 pattern is the foundational building block of AWS web application architecture. From this baseline, real production environments add:

**Path-based routing:** Multiple target groups serving different parts of the application. One listener can have multiple rules: `/api/*` → API target group (t3.medium, high CPU), `/` → web target group (t3.small, lower CPU), `/static/*` → S3 bucket (via a Lambda or redirect).

**Auto Scaling integration:** The Auto Scaling Group is wired to the target group directly. When a new instance launches, it's automatically registered in the target group. When it terminates (scale-in or health failure), it's automatically deregistered after connection draining completes. The ALB never routes to an instance that hasn't passed its health check.

**HTTPS termination:** Add a port 443 listener with an ACM SSL certificate. The ALB terminates TLS and forwards plain HTTP to the backend — instances don't need certificates. Combined with an HTTP→HTTPS redirect rule on port 80, this is the standard HTTPS setup.

**WAF integration:** AWS WAF can be attached to an ALB to block SQL injection, XSS, geographic restrictions, and rate limiting rules — without any changes to the application code.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What are the differences between an ALB, NLB, and Classic Load Balancer?**

> An **Application Load Balancer (ALB)** operates at Layer 7 (HTTP/HTTPS) and can route based on URL paths, host headers, query strings, and HTTP methods. It supports WebSockets, HTTP/2, and integrates with WAF. It's the right choice for any web application needing content-based routing. A **Network Load Balancer (NLB)** operates at Layer 4 (TCP/UDP) and handles millions of requests per second with ultra-low latency. It preserves the client's source IP and is used for non-HTTP workloads, gaming backends, IoT, and any scenario needing TCP-level control. The **Classic Load Balancer** is the legacy option — it supports both Layer 4 and Layer 7 but lacks advanced features and is no longer recommended for new workloads. AWS has deprecated it and encourages migration to ALB or NLB.

---

**Q2. A target is registered in a target group but shows `unhealthy`. What's your debugging sequence?**

> Start at the health check level. Check `describe-target-health` — the `TargetHealth.Reason` field will often explain the failure (`Target.Timeout`, `Target.FailedHealthChecks`, `Elb.InitialHealthChecking`). Then work down the stack: first, verify the security group on the EC2 instance allows port 80 from the ALB's security group — this is the most common cause. Second, SSH into the instance and verify Nginx is running (`systemctl status nginx`) and responding on port 80 (`curl localhost`). Third, verify the health check path (`/` by default) returns a 200 — not a 3xx redirect. An HTTP 301 redirect on the health check path will cause health check failures unless you configure the target group to accept 3xx responses.

---

**Q3. What is connection draining (deregistration delay) and why does it matter?**

> Connection draining (now called **deregistration delay**) is the period during which the ALB allows in-flight requests to a target to complete before fully deregistering it. The default is 300 seconds (5 minutes). When you deregister a target (e.g., during an Auto Scaling scale-in), the ALB stops sending new connections to it but keeps the existing connections alive for up to the deregistration delay period. After the delay expires (or all existing connections close), the target is fully removed. This prevents in-flight requests from being dropped during deployments, scaling events, or rolling restarts. For APIs with short request lifetimes, you can lower this to 30–60 seconds. For long-lived connections (file uploads, streaming), you might need to increase it.

---

**Q4. What is the difference between a target group's health check and an EC2 status check?**

> They're completely independent. An **EC2 status check** is AWS's infrastructure-level check — it monitors whether the physical host and the OS kernel are healthy. If the instance status check fails, AWS may automatically recover the instance. A **target group health check** is an application-level check — the ALB makes an HTTP request to the instance on the configured port and path and evaluates the response code. An instance can pass EC2 status checks (OS is running) but fail ALB health checks (Nginx crashed, app returned 500, wrong port open). Auto Scaling uses both: EC2 health checks to replace failed instances and ALB health checks to prevent unhealthy instances from receiving traffic.

---

**Q5. You need to add HTTPS support to this ALB setup. What are the steps?**

> Three steps. First, provision a TLS certificate in **AWS Certificate Manager (ACM)** for your domain. If your domain is in Route 53, ACM can validate automatically via DNS validation in seconds. Second, add a port 443 listener to the ALB with the ACM certificate attached and forward action to the same `xfusion-tg` target group. Third, add a port 80 listener rule that redirects HTTP → HTTPS (HTTP 301). Update the ALB security group to also allow port 443 inbound. The backend EC2 instances don't need certificates — TLS is terminated at the ALB. You'd also update the Route 53 record (or DNS entry) to point your domain to the ALB's DNS name with an Alias record.

---

**Q6. How does an ALB integrate with an Auto Scaling Group?**

> The Auto Scaling Group (ASG) is associated with the Target Group ARN during ASG creation or via `attach-load-balancer-target-groups`. When the ASG launches a new instance, it waits for the instance to pass its health check (EC2 or ALB, depending on the ASG health check type), then registers it in the target group automatically. When the ASG scales in or terminates an instance (due to a failing health check), it deregisters the instance from the target group and waits for the deregistration delay before terminating — allowing in-flight connections to complete. This integration means you never manually manage target registration at scale. The ASG handles instance lifecycle; the ALB handles traffic distribution.

---

**Q7. What is sticky session (session affinity) and when would you enable it on an ALB?**

> Sticky sessions (configured at the target group level) cause the ALB to route a user's requests to the same target for the duration of the stickiness period, based on a cookie. There are two types: duration-based stickiness (ALB generates and manages the cookie) and application-based stickiness (your application generates the cookie). You'd enable stickiness when your application stores session state locally on the instance — a shopping cart stored in server memory, for example — and different requests from the same user must land on the same instance. The modern architectural recommendation is to avoid server-side session state entirely (use DynamoDB, ElastiCache, or JWT tokens instead) so that any instance can serve any user — this removes the need for stickiness, simplifies scaling, and makes deployments easier.

---

## 📚 Resources

- [AWS Docs — Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html)
- [AWS CLI Reference — create-load-balancer](https://docs.aws.amazon.com/cli/latest/reference/elbv2/create-load-balancer.html)
- [AWS CLI Reference — create-target-group](https://docs.aws.amazon.com/cli/latest/reference/elbv2/create-target-group.html)
- [Target Group Health Checks](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html)
- [ALB Security Groups](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-update-security-groups.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
