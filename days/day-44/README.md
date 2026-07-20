# Day 44 — Auto Scaling Group + ALB + Nginx: High Availability Web Stack

> **#100DaysOfCloud | Day 44 of 100**

---

## 📌 The Task

> *Build a complete highly available web stack: a launch template with Nginx on Amazon Linux 2, an Auto Scaling Group that maintains 1–2 instances with 50% CPU target tracking, and an ALB routing traffic across the ASG — verified by the Nginx default page loading from the ALB DNS.*

**Requirements:**
| Resource | Detail |
|----------|--------|
| Launch Template | `datacenter-launch-template` — Amazon Linux 2, t2.micro, Nginx via User Data |
| Security Group | Port 80 from internet |
| Auto Scaling Group | `datacenter-asg` — min:1, desired:1, max:2, CPU 50% target tracking |
| Target Group | `datacenter-tg` — HTTP/80, health check `/` |
| ALB | `datacenter-alb` — internet-facing, listener HTTP 80 |
| Verification | ALB DNS serves the Nginx default page |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### Why This Stack Is the Foundation of HA on AWS

This task assembles the four components that underpin nearly every scalable web application on AWS:

```
Internet
    │
    ▼ ALB (datacenter-alb)
    │  — internet-facing, security group allows port 80
    │  — listener: HTTP 80 → forward to target group
    │
    ▼ Target Group (datacenter-tg)
    │  — health checks on port 80, path /
    │  — only routes to healthy instances
    │
    ▼ Auto Scaling Group (datacenter-asg)
    │  — maintains 1–2 EC2 instances
    │  — registers/deregisters instances with target group
    │  — scales out when CPU > 50%, in when CPU < 50%
    │
    ▼ EC2 Instances (from launch template)
       — Amazon Linux 2, t2.micro
       — Nginx installed and running
```

### Launch Template vs Launch Configuration

Launch templates replaced Launch Configurations (deprecated 2021). Key differences:

| | Launch Configuration | Launch Template |
|--|---------------------|----------------|
| **Versioning** | No — immutable | Yes — multiple versions |
| **Mixtures** | EC2 only | EC2 + Spot + multiple instance types |
| **Auto Scaling** | ✅ | ✅ (preferred) |
| **Run Instances** | ❌ | ✅ |
| **Status** | Deprecated (read-only) | Current standard |

Always use launch templates for new ASGs.

### Amazon Linux 2 vs Amazon Linux 2023

The task specifies **Amazon Linux 2** (not AL2023). The critical difference for this task:

| | Amazon Linux 2 | Amazon Linux 2023 |
|--|----------------|-------------------|
| **Package manager** | `yum` | `dnf` |
| **nginx package** | `yum install nginx` | `dnf install nginx` |
| **iptables** | Pre-installed | Not pre-installed (Day 30!) |
| **EOL** | June 30, 2025 | Current |

For this task's User Data, `yum install -y nginx` is correct for Amazon Linux 2. Using `dnf` on AL2 or `yum` on AL2023 both fail.

### Target Tracking Scaling — How It Works

Target tracking is the simplest and most effective ASG scaling policy. You declare a target metric value and ASG handles the math:

- **Scale out**: when the metric exceeds the target for a sustained period → launch new instances
- **Scale in**: when the metric drops below the target → terminate instances (with cooldown)
- **Target metric**: `ASGAverageCPUUtilization` — average CPU across all instances in the ASG
- **Target value**: 50% — ASG tries to keep the fleet average at 50%

At 50% CPU target: if your single instance hits 80% average CPU, ASG launches a second instance to bring the average down toward 50%. If CPU drops to 20% with two instances, ASG terminates one (scale-in protection periods apply).

### ELB Health Checks vs EC2 Health Checks in ASG

ASGs support two health check types:

| Type | Checks | Unhealthy = |
|------|--------|-------------|
| **EC2** (default) | AWS infrastructure-level (instance status checks) | Terminated and replaced |
| **ELB** | ALB/NLB target health checks (is port 80 responding 200?) | Terminated and replaced |

ELB health checks are the correct choice here — they verify Nginx is actually running and serving HTTP 200, not just that the EC2 instance's OS is up. An instance with a crashed Nginx would pass EC2 health checks but fail ELB health checks, correctly triggering replacement.

The `--health-check-grace-period 120` gives new instances 120 seconds before health checks begin — enough time for User Data to install Nginx (which takes 60–90 seconds on Amazon Linux 2).

### The Deregistration Delay (Connection Draining)

When an ASG terminates an instance (scale-in or health failure), it doesn't immediately kill active connections. The ALB target group's **deregistration delay** (default 300 seconds) keeps the dying instance in the pool and finishes in-flight requests before the instance is actually terminated. For Nginx serving quick HTTP requests, this can be reduced to 30–60 seconds.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

[O#### Part 1 — Create Security Group
EC2 → Security Groups → Create → Name: `datacenter-sg` → Port 80 from `0.0.0.0/0`

#### Part 2 — Create Launch Template
EC2 → Launch Templates → Create launch template
- Name: `datacenter-launch-template`
- ✅ Guidance for Auto Scaling
- AMI: Amazon Linux 2 (search, select 64-bit x86)
- Instance type: `t2.micro`
- Security group: `datacenter-sg`
- Advanced details → User data:
```bash
#!/bin/bash
yum update -y
yum install -y nginx
systemctl start nginx
systemctl enable nginx
```

#### Part 3 — Create Target Group
EC2 → Target Groups → Create → Instances → Name: `datacenter-tg` → HTTP 80 → default VPC → Health check `/` → don't register instances → Create

#### Part 4 — Create ALB
EC2 → Load Balancers → Create → Application → Name: `datacenter-alb` → internet-facing → default VPC → select ≥2 subnets → SG: `datacenter-sg` → Listener HTTP 80 → forward to `datacenter-tg` → Create

#### Part 5 — Create Auto Scaling Group
EC2 → Auto Scaling Groups → Create
1. Name: `datacenter-asg` | LT: `datacenter-launch-template`
2. VPC: default | Subnets: all
3. Load balancing: **Attach to existing LB** → `datacenter-tg` | ✅ ELB health checks
4. Min: `1` | Desired: `1` | Max: `2`
5. Scaling policies → **Target tracking** → CPU → Target: `50`
6. Create

#### Part 6 — Verify
EC2 → Load Balancers → `datacenter-alb` → copy DNS name → open `http://DNS` in browser

---

### Method 2 — AWS CLI (Full Script)

```bash
#!/bin/bash
set -e
REGION="us-east-1"

# --- Step 1: Networking ---
VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

SUBNET_IDS=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
    --query "Subnets[*].SubnetId" --output text | tr '\t' ',')

echo "VPC: $VPC_ID | Subnets: $SUBNET_IDS"

# --- Step 2: Security group ---
SG_ID=$(aws ec2 create-security-group \
    --region $REGION --group-name datacenter-sg \
    --description "HTTP port 80" --vpc-id $VPC_ID \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=datacenter-sg}]' \
    --query "GroupId" --output text)
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION

# --- Step 3: Amazon Linux 2 AMI ---
AL2_AMI=$(aws ec2 describe-images --region $REGION --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)
echo "AL2 AMI: $AL2_AMI"

# --- Step 4: Launch template ---
USER_DATA=$(printf '#!/bin/bash\nyum update -y\nyum install -y nginx\nsystemctl start nginx\nsystemctl enable nginx' | base64)

LT_ID=$(aws ec2 create-launch-template \
    --region $REGION \
    --launch-template-name datacenter-launch-template \
    --launch-template-data "{\"ImageId\":\"${AL2_AMI}\",\"InstanceType\":\"t2.micro\",\"SecurityGroupIds\":[\"${SG_ID}\"],\"UserData\":\"${USER_DATA}\"}" \
    --query "LaunchTemplate.LaunchTemplateId" --output text)
echo "Launch template: $LT_ID"

# --- Step 5: Target group ---
TG_ARN=$(aws elbv2 create-target-group \
    --region $REGION --name datacenter-tg \
    --protocol HTTP --port 80 --vpc-id $VPC_ID \
    --target-type instance --health-check-path "/" \
    --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
    --query "TargetGroups[0].TargetGroupArn" --output text)

# --- Step 6: ALB ---
SUBNET_ARRAY=$(echo $SUBNET_IDS | tr ',' ' ')
ALB_ARN=$(aws elbv2 create-load-balancer \
    --region $REGION --name datacenter-alb \
    --type application --scheme internet-facing \
    --subnets $SUBNET_ARRAY --security-groups $SG_ID \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)

aws elbv2 create-listener \
    --region $REGION --load-balancer-arn $ALB_ARN \
    --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN

aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_ARN --region $REGION

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
    --query "LoadBalancers[0].DNSName" --output text --region $REGION)
echo "ALB DNS: $ALB_DNS"

# --- Step 7: Auto Scaling Group ---
aws autoscaling create-auto-scaling-group \
    --region $REGION \
    --auto-scaling-group-name datacenter-asg \
    --launch-template "LaunchTemplateName=datacenter-launch-template,Version=\$Latest" \
    --min-size 1 --desired-capacity 1 --max-size 2 \
    --target-group-arns $TG_ARN \
    --health-check-type ELB \
    --health-check-grace-period 120 \
    --vpc-zone-identifier $SUBNET_IDS

# --- Step 8: Target tracking policy (CPU 50%) ---
aws autoscaling put-scaling-policy \
    --region $REGION \
    --auto-scaling-group-name datacenter-asg \
    --policy-name datacenter-cpu-policy \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration '{
        "PredefinedMetricSpecification": {
            "PredefinedMetricType": "ASGAverageCPUUtilization"
        },
        "TargetValue": 50.0
    }'

# --- Step 9: Verify ---
echo "Waiting 3 minutes for instance launch and health checks..."
sleep 180

aws elbv2 describe-target-health --target-group-arn $TG_ARN --region $REGION \
    --query "TargetHealthDescriptions[*].{ID:Target.Id,State:TargetHealth.State}" \
    --output table

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$ALB_DNS")
echo "HTTP from ALB: $HTTP_STATUS"
[ "$HTTP_STATUS" == "200" ] && echo "✅ Nginx serving via ALB" || echo "⚠️ Check target health"

echo "ALB DNS: http://$ALB_DNS"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- DESCRIBE ASG ---
aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names datacenter-asg --region $REGION \
    --query "AutoScalingGroups[0].{Min:MinSize,Desired:DesiredCapacity,Max:MaxSize,Instances:Instances[*].InstanceId}"

# --- CHECK SCALING ACTIVITIES ---
aws autoscaling describe-scaling-activities \
    --auto-scaling-group-name datacenter-asg --region $REGION \
    --query "Activities[*].{Status:StatusCode,Description:Description,StartTime:StartTime}"

# --- CHECK TARGET HEALTH ---
aws elbv2 describe-target-health --target-group-arn $TG_ARN --region $REGION

# --- ALB DNS ---
aws elbv2 describe-load-balancers --names datacenter-alb --region $REGION \
    --query "LoadBalancers[0].DNSName" --output text

# --- TEST ---
curl http://$(aws elbv2 describe-load-balancers --names datacenter-alb --region $REGION \
    --query "LoadBalancers[0].DNSName" --output text)

# --- CLEANUP ORDER ---
# 1. Detach TG from ASG, then delete ASG (terminates instances)
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name datacenter-asg \
    --force-delete --region $REGION
# 2. Delete listener, TG, ALB
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN --region $REGION
aws elbv2 delete-target-group --target-group-arn $TG_ARN --region $REGION
# 3. Delete launch template + SG
aws ec2 delete-launch-template --launch-template-id $LT_ID --region $REGION
aws ec2 delete-security-group --group-id $SG_ID --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Using `dnf` instead of `yum` in User Data for Amazon Linux 2**
Amazon Linux 2 uses `yum`. `dnf` is the package manager for Amazon Linux 2023. Using `dnf install nginx` on AL2 fails silently or with a command-not-found error — Nginx never gets installed, health checks fail, and the target stays `unhealthy` indefinitely. The task specifies Amazon Linux 2 specifically — use `yum`.

**2. Setting health check type to EC2 instead of ELB on the ASG**
EC2 health checks only verify the instance's OS is running (infrastructure-level). ELB health checks verify that the application (Nginx on port 80) is actually responding. If Nginx crashes, an EC2-only health check sees a running instance and never replaces it. Always use `--health-check-type ELB` for application workloads behind a load balancer.

**3. Health check grace period too short**
The default grace period is 0–30 seconds. User Data on Amazon Linux 2 takes 60–90 seconds to run `yum update` + `yum install nginx`. If health checks start before Nginx is ready, the instance is immediately marked unhealthy and terminated — which triggers a replacement that also fails, causing an infinite replacement loop. Always set at least 120 seconds for instances that install packages via User Data.

**4. Not attaching the ASG to the target group at creation**
If you create the ASG without specifying `--target-group-arns`, instances launch but never register with the target group. The ALB has nothing to route to, and you'd need to manually update the ASG or register instances. Always include `--target-group-arns` in `create-auto-scaling-group`.

**5. ALB deployed in only one subnet/AZ**
ALB requires subnets in at least two AZs. This is enforced at the API level — a single-subnet ALB creation fails immediately.

**6. Expecting immediate Nginx availability after ASG creation**
The full chain takes 3–5 minutes: EC2 instance launches → User Data runs (60-90s) → Nginx starts → Health check grace period (120s) → first health checks run → target becomes healthy → ALB routes traffic. Testing immediately after `create-auto-scaling-group` returns will get a 503.

**7. 502 Bad Gateway — target unhealthy even though instance is running**
A 502 from the ALB (distinct from 503) means the ALB reached the instance's IP but got no valid HTTP response on port 80. The instance is running but Nginx is not. Root causes in order of likelihood: (a) User Data failed silently — `yum update` timed out or `yum install nginx` errored, leaving no Nginx binary; (b) the grace period expired before Nginx finished installing so the health check fired too early; (c) Nginx installed but failed to start (rare on AL2). Diagnosis: use SSM Run Command to check `systemctl status nginx` and `tail /var/log/cloud-init-output.log` without needing SSH. Fix without relaunching: run `yum install -y nginx && systemctl start nginx` via SSM directly on the running instance. Fix permanently: create a new launch template version with corrected User Data and terminate the bad instance so ASG replaces it.

---

## 🔧 Troubleshooting: 502 Bad Gateway + Unhealthy Targets

If the ALB returns 502 and the target group shows `unhealthy`, run this diagnostic sequence:

### Step 1 — Check Nginx status on the instance

```bash
REGION="us-east-1"

INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names devops-asg --region $REGION \
    --query "AutoScalingGroups[0].Instances[0].InstanceId" --output text)

echo "Instance: $INSTANCE_ID"

CMD_ID=$(aws ssm send-command \
    --region $REGION \
    --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
        "echo === Nginx status ===",
        "systemctl status nginx --no-pager 2>&1 || echo NOT_RUNNING",
        "echo === Port 80 ===",
        "ss -tlnp | grep :80 || echo NOTHING_ON_PORT_80",
        "echo === User Data log ===",
        "tail -20 /var/log/cloud-init-output.log"
    ]' \
    --query "Command.CommandId" --output text)

sleep 15

aws ssm get-command-invocation \
    --command-id $CMD_ID --instance-id $INSTANCE_ID --region $REGION \
    --query "StandardOutputContent" --output text
```

### Step 2 — Fix immediately via SSM (no relaunch needed)

```bash
aws ssm send-command \
    --region $REGION \
    --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
        "yum install -y nginx",
        "systemctl start nginx",
        "systemctl enable nginx",
        "curl -s -o /dev/null -w \"local: %{http_code}\" http://localhost"
    ]' \
    --query "Command.CommandId" --output text

sleep 30

TG_ARN=$(aws elbv2 describe-target-groups --names devops-tg --region $REGION \
    --query "TargetGroups[0].TargetGroupArn" --output text)

aws elbv2 describe-target-health --target-group-arn $TG_ARN --region $REGION \
    --query "TargetHealthDescriptions[*].{Target:Target.Id,State:TargetHealth.State}" \
    --output table
```

### Step 3 — If SSM unavailable: fix via new launch template version + instance replacement

```bash
AL2_AMI=$(aws ec2 describe-images --region $REGION --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

SG_ID=$(aws ec2 describe-security-groups --region $REGION \
    --filters "Name=group-name,Values=devops-sg" \
    --query "SecurityGroups[0].GroupId" --output text)

USER_DATA_B64=$(printf '#!/bin/bash\nyum update -y\nyum install -y nginx\nsystemctl start nginx\nsystemctl enable nginx' | base64 -w 0)

# New launch template version
aws ec2 create-launch-template-version \
    --region $REGION \
    --launch-template-name devops-launch-template \
    --version-description "v2-nginx-fixed" \
    --launch-template-data "{
        \"ImageId\": \"${AL2_AMI}\",
        \"InstanceType\": \"t2.micro\",
        \"SecurityGroupIds\": [\"${SG_ID}\"],
        \"UserData\": \"${USER_DATA_B64}\"
    }"

# Terminate bad instance — ASG relaunches with new template version
aws autoscaling terminate-instance-in-auto-scaling-group \
    --instance-id $INSTANCE_ID \
    --should-decrement-desired-capacity false \
    --region $REGION

echo "New instance launching — wait 5 minutes then check health"
```

---

## 🌍 Real-World Context

This stack is the AWS reference architecture for any stateless web application. In production it extends to:

**Blue/Green deployments:** Two ASGs (blue and v2 canary/green), with ALB listener rules gradually shifting traffic from blue to green target group. If the green group fails health checks, roll the listener rule back — zero-downtime deployment with instant rollback capability.

**Multi-region active-active:** The same ASG+ALB stack in two regions, fronted by Route 53 latency-based routing or Global Accelerator. Users get directed to the nearest healthy region automatically.

**Scheduled scaling:** In addition to CPU target tracking, a scheduled scaling action pre-warms instances ahead of a known traffic spike (e.g., double capacity every Monday at 8 AM, reduce Friday at 6 PM). Combines with target tracking for both planned and unplanned scaling events.

**Termination policies:** By default, ASG terminates the oldest instance during scale-in. `OldestLaunchTemplate` policy ensures instances on a superseded launch template version are terminated first, automatically rolling out new AMIs as the fleet naturally scales.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. What is the difference between a Launch Template and a Launch Configuration?**
> Launch Configurations were the original EC2 Auto Scaling resource for specifying instance configuration. They're now deprecated (read-only since 2021) and cannot be created for new ASGs. Launch Templates replaced them with several improvements: versioning (you can have $Latest, $Default, or specific numbered versions), support for mixed instance types and purchase options (On-Demand + Spot in the same ASG), and usability in `run-instances` as well as ASGs. For any new work, always use launch templates. When migrating old ASGs from launch configurations, convert them to launch templates before AWS removes support entirely.

**Q2. What is target tracking scaling and how does it differ from step scaling?**
> Target tracking tells the ASG "maintain this metric at this value" and handles all the scaling math automatically — it creates both scale-out and scale-in CloudWatch alarms internally and adjusts capacity to keep the metric close to the target. Step scaling requires you to define explicit alarm thresholds and corresponding capacity adjustments: "when CPU > 60% for 5 min, add 1 instance; when CPU > 80% for 5 min, add 2 instances." Target tracking is simpler, responds more smoothly, and is the recommended default for most workloads. Step scaling gives you more control over how aggressively the ASG responds at different thresholds — useful for workloads with known non-linear scaling behaviour.

**Q3. Why does the ASG need a health check grace period and how do you determine the right value?**
> The grace period is the time after an instance launches before the ASG starts evaluating health checks. Without it, health checks might run before the application has started — marking a healthy instance as unhealthy and terminating it, causing an endless replacement loop. The right value is the sum of: time to boot the OS + time for User Data to complete + time for the application to start accepting requests, plus a buffer. For a simple Nginx install on Amazon Linux 2 (`yum update` + `yum install nginx`), that's roughly 90–120 seconds. For a Java application that downloads JAR files and warms up a JVM, it might be 300–600 seconds. Monitor the `InstanceInService` timing in scaling activities and set the grace period to that measured value plus 30 seconds.

**Q4. An ASG keeps terminating and replacing a new instance immediately after launch. What's wrong?**
> This is almost always a health check grace period issue or a User Data failure. If the grace period is too short, health checks run before Nginx starts and the instance fails immediately. Check scaling activities: `describe-scaling-activities --auto-scaling-group-name asg-name` — the `StatusCode` and `Description` fields explain why each instance was terminated. If activities show `Terminating:Wait` with a health reason, increase the grace period. If User Data failed, the instance might be healthy from EC2's perspective but Nginx isn't running — in which case check `/var/log/cloud-init-output.log` on the instance for errors. With ELB health check type, `unhealthy` target in the target group is the specific trigger.

**Q5. How does the ALB know which instances to route traffic to when the ASG adds or removes instances?**
> The ASG integrates directly with the target group. When a new instance launches and passes its health checks, the ASG automatically calls `register-targets` on the target group with the new instance's ID. When an instance is terminated (scale-in or health replacement), the ASG first deregisters it from the target group and waits for the deregistration delay (default 300 seconds, during which in-flight requests complete) before actually terminating the EC2 instance. This means you never manually manage which instances are in the target group — the ASG lifecycle hooks handle it. The ALB continuously evaluates target health and stops routing to any target that fails two consecutive health checks, regardless of ASG registration.

**Q6. What is connection draining / deregistration delay and why does it matter for zero-downtime deployments?**
> When a target is deregistered from a target group (either by the ASG during termination, or manually), the ALB stops sending new connections to it immediately. But existing open connections are kept alive for the deregistration delay period (default 300 seconds). During this window, in-flight requests finish normally — the client never sees a connection reset. After the delay expires (or all existing connections close, whichever is sooner), the target is fully removed. Without deregistration delay, terminating an instance would abruptly close any in-progress HTTP connections, producing errors for active users. For long-running requests (file uploads, streaming), keep the default 300 seconds. For quick API requests where 5 minutes feels excessive, reduce to 30–60 seconds.

**Q7. How would you roll out a new AMI across a running ASG with zero downtime?**
> Update the launch template to a new version pointing at the new AMI. Then use ASG instance refresh: `aws autoscaling start-instance-refresh --auto-scaling-group-name datacenter-asg --preferences MinHealthyPercentage=50,InstanceWarmup=120`. Instance refresh replaces running instances with the new launch template version in a controlled rolling fashion — it terminates old instances in batches while keeping at least `MinHealthyPercentage` of capacity healthy throughout. Each new instance must pass health checks before the refresh proceeds to the next batch. If you set `MinHealthyPercentage=100`, the ASG scales out to double capacity first, waits for all new instances to be healthy, then terminates the old ones — effectively a blue/green deployment within the ASG.

---

## 📚 Resources

- [AWS Docs — Auto Scaling Groups](https://docs.aws.amazon.com/autoscaling/ec2/userguide/AutoScalingGroup.html)
- [Target Tracking Scaling](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html)
- [Launch Templates](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-launch-templates.html)
- [ASG Instance Refresh](https://docs.aws.amazon.com/autoscaling/ec2/userguide/asg-instance-refresh.html)
- [Day 24 — Original ALB Setup](../day-24/README.md)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
