# Day 25 — EC2 Instance with CloudWatch CPU Alarm and SNS Notification

> **#100DaysOfCloud | Day 25 of 100**

---

## 📌 The Task

> *Launch an EC2 instance and create a CloudWatch alarm that fires when CPU utilization exceeds 90% for one consecutive 5-minute period, sending a notification via an existing SNS topic.*

**Requirements:**
| Resource | Specification |
|----------|--------------|
| EC2 Instance | `devops-ec2` — Ubuntu AMI |
| CloudWatch Alarm | `devops-alarm` |
| Metric | `CPUUtilization` |
| Statistic | `Average` |
| Threshold | `>= 90%` |
| Period | `300 seconds` (5 minutes) |
| Evaluation periods | `1` consecutive period |
| Alarm action | Notify `devops-sns-topic` |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### What Is Amazon CloudWatch?

**Amazon CloudWatch** is AWS's observability service — it collects metrics, logs, and events from AWS resources and applications, enables you to set alarms on thresholds, and triggers automated actions when those thresholds are breached.

Every EC2 instance automatically publishes **basic monitoring metrics** to CloudWatch every **5 minutes** at no charge:
- `CPUUtilization` — percentage of allocated EC2 compute units in use
- `NetworkIn` / `NetworkOut` — bytes transferred
- `DiskReadOps` / `DiskWriteOps` — disk I/O operations
- `StatusCheckFailed` — system and instance health

With **Detailed Monitoring** enabled (additional charge), metrics are published every **1 minute**.

### CloudWatch Alarm States

| State | Meaning |
|-------|---------|
| `OK` | Metric is within the defined threshold |
| `ALARM` | Metric has breached the threshold for the required consecutive periods |
| `INSUFFICIENT_DATA` | Not enough data to evaluate (common on new alarms) |

### Alarm Configuration — Breaking It Down

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `Namespace` | `AWS/EC2` | The metric namespace |
| `MetricName` | `CPUUtilization` | Which metric to watch |
| `Dimensions` | `InstanceId=i-xxx` | Scope to a specific instance |
| `Statistic` | `Average` | Aggregate data points in each period |
| `Period` | `300` | 5-minute window (in seconds) |
| `EvaluationPeriods` | `1` | Must breach for 1 consecutive period |
| `Threshold` | `90` | The comparison value |
| `ComparisonOperator` | `GreaterThanOrEqualToThreshold` | Comparison direction |

**Period vs EvaluationPeriods:**
- `Period=300` — CloudWatch looks at 5-minute averages
- `EvaluationPeriods=1` — if even ONE 5-minute average is >= 90%, alarm fires immediately
- `EvaluationPeriods=3` would require 15 consecutive minutes above 90% — less sensitive to spikes

### The Full Monitoring Flow

```
EC2 Instance (devops-ec2)
    │
    │  publishes CPUUtilization every 5 min (basic monitoring)
    ▼
CloudWatch — AWS/EC2 namespace
    │
    │  evaluates: Average CPUUtilization over 300s >= 90?
    ▼
CloudWatch Alarm (devops-alarm)  [OK / INSUFFICIENT_DATA / ALARM]
    │
    │  threshold breached for 1 period → transitions to ALARM
    ▼
SNS Topic (devops-sns-topic)
    │
    ▼
Subscribers: email / Lambda / PagerDuty / Slack webhook
```

### What Is Amazon SNS?

**Amazon Simple Notification Service (SNS)** is a pub/sub messaging service. An SNS **topic** is a communication channel. When a CloudWatch alarm fires, it calls `sns:Publish` on the configured topic ARN — every subscriber receives the notification. The `devops-sns-topic` in this task already exists; we need its ARN.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Step 1 — Launch EC2:**
1. EC2 → Launch instances → Name: `devops-ec2`
2. AMI: Ubuntu Server 22.04 LTS | Type: t2.micro
3. Launch instance

**Step 2 — Create CloudWatch Alarm:**
1. CloudWatch → Alarms → Create alarm
2. Select metric → EC2 → Per-Instance Metrics → Select `CPUUtilization` for `devops-ec2`
3. Statistic: `Average` | Period: `5 minutes`
4. Conditions: `>= 90`
5. Next → Notification: Select `devops-sns-topic`
6. Alarm name: `devops-alarm` → Create alarm

---

### Method 2 — AWS CLI

```bash
# ============================================================
# STEP 1: Resolve latest Ubuntu 22.04 LTS AMI
# ============================================================
REGION="us-east-1"

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
# STEP 2: Resolve default networking
# ============================================================
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" --output text)

DEFAULT_SG=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text)

# ============================================================
# STEP 3: Launch EC2 instance (devops-ec2)
# ============================================================
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$DEFAULT_SG" \
    --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=devops-ec2}]' \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

[Oecho "Instance: $INSTANCE_ID"

aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" --region "$REGION"

echo "Instance is running"

# ============================================================
# STEP 4: Resolve SNS topic ARN for devops-sns-topic
# ============================================================
SNS_TOPIC_ARN=$(aws sns list-topics \
    --region "$REGION" \
    --query "Topics[?ends_with(TopicArn, ':devops-sns-topic')].TopicArn" \
    --output text)

echo "SNS ARN: $SNS_TOPIC_ARN"

# ============================================================
# STEP 5: Create the CloudWatch alarm (devops-alarm)
# ============================================================
aws cloudwatch put-metric-alarm \
    --region "$REGION" \
    --alarm-name "devops-alarm" \
    --alarm-description "Alert when CPUUtilization >= 90% for 5 minutes on devops-ec2" \
    --namespace "AWS/EC2" \
    --metric-name "CPUUtilization" \
    --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
    --statistic "Average" \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 90 \
    --comparison-operator "GreaterThanOrEqualToThreshold" \
    --alarm-actions "$SNS_TOPIC_ARN" \
    --ok-actions "$SNS_TOPIC_ARN" \
    --treat-missing-data "missing" \
    --unit "Percent"

echo "Alarm 'devops-alarm' created"

# ============================================================
# STEP 6: Verify
# ============================================================
echo ""
echo "=== Instance ==="
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,State:State.Name,Type:InstanceType}" \
    --output table

echo ""
echo "=== CloudWatch Alarm ==="
aws cloudwatch describe-alarms \
    --alarm-names "devops-alarm" --region "$REGION" \
    --query "MetricAlarms[0].{Name:AlarmName,State:StateValue,Metric:MetricName,Threshold:Threshold,Period:Period,EvalPeriods:EvaluationPeriods,Statistic:Statistic,Action:AlarmActions[0]}" \
    --output table
```

---

### Simulating the Alarm (Testing Without Waiting for High CPU)

```bash
# Force the alarm into ALARM state for testing — no real traffic needed
aws cloudwatch set-alarm-state \
    --alarm-name devops-alarm \
    --state-value ALARM \
    --state-reason "Manual test — simulating high CPU utilisation" \
    --region us-east-1

# Verify state changed + SNS notification sent
aws cloudwatch describe-alarms \
    --alarm-names devops-alarm --region us-east-1 \
    --query "MetricAlarms[0].{State:StateValue,Reason:StateReason}" \
    --output table

# Reset to OK after testing
aws cloudwatch set-alarm-state \
    --alarm-name devops-alarm \
    --state-value OK \
    --state-reason "Manual reset after test" \
    --region us-east-1
```

---

### Viewing Actual CPU Metric Data

```bash
# Pull the last hour of CPU data for devops-ec2
aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value=$INSTANCE_ID \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
    --period 300 \
    --statistics Average \
    --region us-east-1 \
    --query "sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,CPU:Average}" \
    --output table
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- RESOLVE AMI ---
AMI_ID=$(aws ec2 describe-images --region "$REGION" --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
              "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

# --- LAUNCH ---
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" --instance-type t2.micro \
    --subnet-id $SUBNET_ID --security-group-ids $DEFAULT_SG \
    --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=devops-ec2}]' \
    --query "Instances[0].InstanceId" --output text)

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

# --- GET SNS ARN ---
SNS_TOPIC_ARN=$(aws sns list-topics --region "$REGION" \
    --query "Topics[?ends_with(TopicArn, ':devops-sns-topic')].TopicArn" \
    --output text)

# --- CREATE ALARM ---
aws cloudwatch put-metric-alarm \
    --alarm-name "devops-alarm" \
    --namespace "AWS/EC2" --metric-name "CPUUtilization" \
    --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
    --statistic "Average" --period 300 --evaluation-periods 1 \
    --threshold 90 --comparison-operator "GreaterThanOrEqualToThreshold" \
    --alarm-actions "$SNS_TOPIC_ARN" \
    --treat-missing-data "missing" --unit "Percent" --region "$REGION"

# --- VERIFY ALARM ---
aws cloudwatch describe-alarms --alarm-names "devops-alarm" --region "$REGION"

# --- GET ALARM HISTORY ---
aws cloudwatch describe-alarm-history --alarm-name devops-alarm --region "$REGION"

# --- FORCE TEST ---
aws cloudwatch set-alarm-state --alarm-name devops-alarm \
    --state-value ALARM --state-reason "Test" --region "$REGION"

# --- DELETE ALARM ---
aws cloudwatch delete-alarms --alarm-names "devops-alarm" --region "$REGION"
```

---

## ⚠️ Common Mistakes

**1. Confusing `Period` with `EvaluationPeriods`**
`Period` (seconds) defines the width of each evaluation window — `300` = 5 minutes. `EvaluationPeriods` defines how many consecutive windows must breach the threshold. These multiply together: `Period=300, EvaluationPeriods=3` = 15 minutes of sustained breach before alarm fires. For this task: `Period=300, EvaluationPeriods=1` — alarms after the first 5-minute window at 90%+.

**2. Alarm stuck in `INSUFFICIENT_DATA`**
Expected for new instances — basic monitoring publishes every 5 minutes. No data = no evaluation. Give it 5–10 minutes after the instance starts. If it persists beyond 15 minutes, verify the `InstanceId` dimension is correct and the instance is actively running.

**3. Using the topic name instead of the full ARN in `--alarm-actions`**
CloudWatch requires the full SNS topic ARN: `arn:aws:sns:us-east-1:ACCOUNT_ID:devops-sns-topic`. The topic name alone fails validation. Always use `aws sns list-topics` to resolve the ARN programmatically.

**4. Not adding `--ok-actions`**
Without `--ok-actions`, you get alerted when the problem starts but receive no "all clear" notification when CPU drops back below 90%. In production, missing OK notifications means operators never know if a problem resolved on its own or is still ongoing.

**5. Creating the alarm before the instance is running**
If the `InstanceId` referenced in the dimension doesn't exist yet, the alarm is created but evaluates no data — it stays in `INSUFFICIENT_DATA`. Always wait for the instance to reach `running` state before creating the alarm against it.

**6. Not testing the alarm before assuming it works**
`set-alarm-state` lets you force the alarm into `ALARM` state and verify the SNS notification fires — without actually generating 90% CPU. Always test the notification path after setup. Nothing is more embarrassing than discovering during an actual incident that the alarm was configured correctly but the SNS topic had no subscribers.

---

## 🌍 Real-World Context

A single CPU alarm is the starting point, not the destination. In production, the monitoring strategy expands across several dimensions:

**Metric coverage:** CPU alone misses most real failure modes. A healthy CPU with exhausted memory causes OOM kills. Full disk causes write failures. Network saturation causes request timeouts. Installing the **CloudWatch Agent** enables memory (`mem_used_percent`) and disk (`disk_used_percent`) metrics, filling the default monitoring gap. These are typically added to the golden AMI so every instance ships with the agent pre-configured.

**Alarm tiering:** A single threshold alarm doesn't distinguish between a brief spike and a sustained problem. Production environments typically use two alarms per metric: a warning (e.g., CPU > 75% for 5 minutes → PagerDuty warning) and a critical (CPU > 90% for 10 minutes → PagerDuty critical, wake the on-call). Different evaluation periods prevent the critical alarm from firing on momentary spikes.

**Auto Scaling integration:** CloudWatch alarms on CPU are the trigger mechanism for EC2 Auto Scaling. A `CPUUtilization >= 70%` alarm triggers a scale-out policy (add instances); a `CPUUtilization <= 30%` alarm triggers a scale-in policy (remove instances). The alarm itself doesn't scale — it notifies the Auto Scaling policy, which performs the scaling action.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is the difference between `Period` and `EvaluationPeriods` in a CloudWatch alarm?**

> `Period` is the length in seconds of each evaluation window — `300` means CloudWatch computes a 5-minute average of the metric. `EvaluationPeriods` is how many consecutive windows must exceed the threshold before the alarm fires. `Period=300, EvaluationPeriods=1` alarms immediately after one 5-minute average above 90%. `Period=300, EvaluationPeriods=3` requires 15 consecutive minutes above 90%. The total monitoring window is `Period × EvaluationPeriods`. Higher evaluation periods reduce false alarms from brief transient spikes at the cost of slower alerting on real sustained problems.

---

**Q2. A CloudWatch alarm is in `INSUFFICIENT_DATA` state 30 minutes after the EC2 instance launched. What do you investigate?**

> Three likely causes. First, check the dimensions — is the `InstanceId` in the alarm definition exactly matching the running instance's ID? A typo here means CloudWatch is watching a metric that will never publish. Second, confirm the instance is actually running and publishing metrics — check `describe-instances` state and try `get-metric-statistics` manually against the instance ID to see if any data points exist. Third, check if basic monitoring is enabled — it's the default, but confirm with `describe-instances --query "Instances[0].Monitoring.State"`. If monitoring is `disabled`, enable it. If the instance is running, metrics exist, and the dimension is correct but the alarm is still stuck, check the alarm's namespace — a typo in `AWS/EC2` causes silent failures.

---

**Q3. How does a CloudWatch alarm integrate with Auto Scaling?**

> An Auto Scaling Group has scaling policies — rules that say "when alarm X fires, do Y." You create a scale-out policy (`increase desired capacity by 1`) and attach a CloudWatch alarm as its trigger (`CPUUtilization >= 70% for 1 period`). When the alarm transitions to `ALARM`, it calls the Auto Scaling API action specified in the policy, which adds an instance. Similarly, a scale-in policy is triggered by a different alarm (`CPUUtilization <= 30%`) that removes an instance. The alarm doesn't scale directly — it acts as a signal that the scaling policy responds to. CloudWatch alarms can also trigger other actions: EC2 instance recovery (`RecoverInstance` action), Lambda functions, Systems Manager automation runbooks, and more.

---

**Q4. What is `treat-missing-data` and when would you set it to `breaching` vs `missing`?**

> `treat-missing-data` controls how CloudWatch handles evaluation periods where no metric data arrived. `missing` (default) — the alarm's state doesn't change; the last evaluated state persists. `breaching` — missing data is treated as if it exceeded the threshold, potentially triggering an alarm. `notBreaching` — missing data is treated as normal, preventing an alarm. Use `breaching` for heartbeat or health-check type alarms where a missing data point indicates a problem (the agent crashed, the application stopped reporting). Use `missing` for normal workload metrics like CPU where absence might mean the instance was stopped — you don't want an alarm firing on a cleanly stopped instance.

---

**Q5. Why are memory and disk metrics not included in default EC2 CloudWatch metrics?**

> The default EC2 metrics (`CPUUtilization`, `NetworkIn`, etc.) are collected by the AWS hypervisor — the infrastructure layer between the physical hardware and the virtual machine. The hypervisor can see how much CPU and network the VM is using from the outside. But memory and disk utilisation are internal OS metrics — the hypervisor can see that memory is allocated to the VM, but it can't see how the OS inside is using it (what processes are holding it, how much is cached vs actively used). The **CloudWatch Agent** runs inside the OS, where it has access to `/proc/meminfo`, `df` output, and other OS-level data, and ships that to CloudWatch under the `CWAgent` namespace.

---

**Q6. How would you create a composite alarm that only fires when BOTH CPU is high AND the status check is failing?**

> First create the two child alarms: a CPU alarm (`cpu-high-alarm`: `CPUUtilization >= 90%`) and a status check alarm (`status-fail-alarm`: `StatusCheckFailed >= 1`). Then create a composite alarm: `aws cloudwatch put-composite-alarm --alarm-name combined-alarm --alarm-rule "ALARM(cpu-high-alarm) AND ALARM(status-fail-alarm)" --alarm-actions $SNS_ARN`. The composite alarm only transitions to `ALARM` when both children are simultaneously in `ALARM` state. This eliminates false positives from CPU bursts during legitimate batch jobs while still alerting on genuine degradation where high CPU coincides with instance health issues. Composite alarms reduce alert fatigue significantly in busy production environments.

---

**Q7. How would you trigger a Lambda function when a CloudWatch alarm fires instead of sending an email?**

> Add the Lambda function's ARN as an alarm action. But Lambda can't be invoked directly by CloudWatch alarms — the integration goes through SNS. Create an SNS topic, subscribe the Lambda function to that topic (`aws sns subscribe --protocol lambda --endpoint $LAMBDA_ARN`), and grant SNS permission to invoke the Lambda (`aws lambda add-permission --action lambda:InvokeFunction --principal sns.amazonaws.com`). Set the SNS topic ARN as the alarm action. When the alarm fires, it publishes to SNS, which invokes the Lambda with the alarm notification as the event payload. The Lambda function receives the alarm name, metric, threshold, and new state and can format a Slack message, create a Jira ticket, trigger a runbook, or take any other automated action.

---

## 📚 Resources

- [AWS Docs — CloudWatch Alarms](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/AlarmThatSendsEmail.html)
- [AWS CLI Reference — put-metric-alarm](https://docs.aws.amazon.com/cli/latest/reference/cloudwatch/put-metric-alarm.html)
- [CloudWatch Agent Setup](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Install-CloudWatch-Agent.html)
- [Composite Alarms](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Create_Composite_Alarm.html)
- [CloudWatch Anomaly Detection](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Anomaly_Detection.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
