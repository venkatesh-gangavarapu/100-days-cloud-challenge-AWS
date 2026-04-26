# Day 09 — Enabling EC2 Termination Protection

> **#100DaysOfCloud | Day 9 of 100**

---

## 📌 The Task

> *The Nautilus DevOps team forgot to enable termination protection on an EC2 instance during creation. An accidental termination here would cause immediate data loss and service disruption.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Instance name | `datacenter-ec2` |
| Action | Enable termination protection |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### Why Termination Protection Exists

Termination is the most destructive action you can take against an EC2 instance — it is **permanent and irreversible**. When an instance is terminated:

- The instance is permanently destroyed
- The **root EBS volume is deleted** by default (Delete on Termination = true)
- Any **instance store data** is wiped immediately
- The **instance ID is gone forever** — it cannot be restarted, recovered, or un-terminated
- Only snapshots or AMIs taken beforehand can bring the workload back

This is categorically different from stopping an instance, which is fully reversible. Termination protection (`DisableApiTermination`) exists as a deliberate gate against this permanent action — it forces any termination attempt to fail until the protection is explicitly removed.

### How Termination Protection Works

When `DisableApiTermination` is set to `true` on an instance:

- `aws ec2 terminate-instances` returns `OperationNotPermitted`
- The **Terminate** option in the EC2 console is greyed out
- Any CI/CD pipeline, cleanup script, or Auto Scaling action trying to terminate the instance will fail
- The instance **can still be stopped** — termination protection has no effect on stop operations
- The instance **can still be rebooted** — unaffected
- An IAM principal with `ec2:ModifyInstanceAttribute` can disable the protection and then terminate

### Stop Protection vs Termination Protection — Side-by-Side

| Attribute | Stop Protection | Termination Protection |
|-----------|----------------|----------------------|
| **API flag** | `DisableApiStop` | `DisableApiTermination` |
| **CLI flag (enable)** | `--disable-api-stop` | `--disable-api-termination` |
| **CLI flag (disable)** | `--no-disable-api-stop` | `--no-disable-api-termination` |
| **Blocks** | `stop-instances` | `terminate-instances` |
| **Error returned** | `OperationNotPermitted` | `OperationNotPermitted` |
| **Reversibility of action** | Recoverable (EBS preserved) | Permanent (data loss) |
| **Default on new instances** | Disabled | Disabled |
| **Can be set at launch** | Yes (Launch Template) | Yes (Launch Template) |

Both are off by default. Both need to be explicitly enabled. And critically — **they are completely independent**. Enabling one does not enable the other.

### The Termination Risk in Real Environments

Accidental terminations happen more often than teams expect:

- A developer runs `terraform destroy` in the wrong workspace
- An auto-scaling group scale-in event targets an instance that should be exempt
- A cleanup Lambda iterates over instances by tag and the filter is one character off
- Someone runs `aws ec2 terminate-instances --instance-ids` and pastes the wrong ID
- An IaC drift-correction job terminates an instance it doesn't recognize in its state file

In every one of these cases, termination protection would have converted a catastrophic irreversible event into a blocked API call with a clear error message — giving the operator time to realize what happened.

### What Termination Protection Does NOT Prevent

| Scenario | Protected? |
|----------|-----------|
| Manual terminate via console | ✅ Blocked |
| `terminate-instances` via CLI | ✅ Blocked |
| Auto Scaling Group scale-in termination | ✅ Blocked (ASG respects the flag) |
| AWS-initiated instance retirement | ❌ Not blocked |
| Spot Instance interruption | ❌ Not applicable (Spot can't have termination protection) |
| `stop-instances` | ❌ Not blocked (separate attribute) |
| Deleting the entire VPC or account | ❌ Not blocked |

> ⚠️ Note on Auto Scaling Groups: If an instance with termination protection is in an ASG, the ASG **will respect the flag** and the scale-in will fail for that specific instance. This can cause the ASG to behave unexpectedly if not accounted for. Termination protection on ASG-managed instances should be used deliberately and with awareness of this behaviour.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Log in to the [AWS Console](https://748553123153.signin.aws.amazon.com/console?region=us-east-1)
2. Navigate to **EC2 → Instances**
3. Select the instance `datacenter-ec2`
4. Go to **Actions → Instance settings → Change termination protection**
5. Tick **Enable**
6. Click **Save**

**Verify:**
- With the instance selected → **Actions → Instance state → Terminate instance**
- You should see: *"Termination protection is enabled. To terminate this instance, you must first disable termination protection."*
- The Terminate option will be blocked

---

### Method 2 — AWS CLI

```bash
# Step 1: Resolve the Instance ID
INSTANCE_ID=$(aws ec2 describe-instances \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=datacenter-ec2" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "Instance ID: $INSTANCE_ID"

# Step 2: Check current termination protection status
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiTermination \
    --region us-east-1
# Expected before: { "DisableApiTermination": { "Value": false } }

# Step 3: Enable termination protection
aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region us-east-1 \
    --disable-api-termination

# Step 4: Verify
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiTermination \
    --region us-east-1
# Expected after: { "DisableApiTermination": { "Value": true } }

# Step 5: Confirm protection blocks termination
# This WILL FAIL — that failure is the proof it's working
aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1
# Error: An error occurred (OperationNotPermitted) when calling the
# TerminateInstances operation: The instance 'i-xxxx' may not be terminated.
# Modify its 'disableApiTermination' instance attribute and try again.
```

---

### Disabling Termination Protection (When Intentionally Needed)

```bash
# Step 1: Disable the protection
aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region us-east-1 \
    --no-disable-api-termination

# Verify it's disabled
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiTermination \
    --region us-east-1
# { "DisableApiTermination": { "Value": false } }

# Step 2: Now terminate safely
aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region us-east-1
```

---

### Enable Both Stop AND Termination Protection Together

```bash
# Full protection — blocks both stop and terminate
aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region us-east-1 \
    --disable-api-stop

aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region us-east-1 \
    --disable-api-termination

# Verify both
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiStop \
    --region us-east-1

aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiTermination \
    --region us-east-1
```

---

### Setting Protection in a Launch Template (for new instances)

```bash
aws ec2 create-launch-template \
    --launch-template-name production-template \
    --launch-template-data '{
        "ImageId": "ami-xxxxxxxxxxxxxxxxx",
        "InstanceType": "t2.micro",
        "KeyName": "my-key",
        "DisableApiStop": true,
        "DisableApiTermination": true
    }'
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- FIND INSTANCE ---
INSTANCE_ID=$(aws ec2 describe-instances \
[O    --region "$REGION" \
    --filters "Name=tag:Name,Values=datacenter-ec2" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

# --- CHECK CURRENT STATUS ---
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiTermination \
    --region "$REGION"

# --- ENABLE TERMINATION PROTECTION ---
aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --disable-api-termination

# --- VERIFY ---
aws ec2 describe-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --attribute disableApiTermination \
    --region "$REGION"
# Expected: { "DisableApiTermination": { "Value": true } }

# --- ENABLE STOP PROTECTION TOGETHER ---
aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --disable-api-stop

# --- DISABLE TERMINATION PROTECTION (intentional) ---
aws ec2 modify-instance-attribute \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --no-disable-api-termination

# --- AUDIT: List instances without termination protection ---
aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text | tr '\t' '\n' | while read id; do
    result=$(aws ec2 describe-instance-attribute \
        --instance-id "$id" --attribute disableApiTermination \
        --region "$REGION" \
        --query "DisableApiTermination.Value" --output text)
    [ "$result" == "False" ] && echo "$id: termination protection DISABLED"
done
```

---

## ⚠️ Common Mistakes

**1. Enabling only termination protection but not stop protection**
These two attributes don't overlap. An instance with termination protection enabled can still be stopped — and a stopped instance with a Delete on Termination root volume is one `terminate-instances` call away from data loss once someone disables the flag. For critical instances, enable both.

**2. Trusting termination protection as the only safeguard**
Protection is a safeguard against accidental API calls, not a comprehensive data protection strategy. A regular **snapshot schedule** (via AWS Data Lifecycle Manager) and potentially an AMI backup are the real safety net. Termination protection just buys you the window to realize a mistake was made before it becomes unrecoverable.

**3. Not accounting for it in Auto Scaling Group design**
If an instance in an ASG has termination protection enabled, ASG scale-in events targeting that instance will fail. The ASG will attempt to terminate it, get blocked, and may enter an error state or try other instances. Termination protection on ASG instances is unusual by design — ASGs are meant to manage instance lifecycle automatically. If you need a long-lived ASG instance to be protected, that's usually a sign it should be outside the ASG.

**4. Forgetting that `terraform destroy` can still terminate with protection**
By default, Terraform's AWS provider respects termination protection — it will error if it tries to destroy a protected instance. However, some teams force-override this with `prevent_destroy = false` in lifecycle blocks, or use `terraform force-unlock` approaches that bypass it. Protection is not a substitute for proper IaC workspace hygiene.

**5. Not using CloudTrail to log protection disable events**
Every time termination protection is disabled (`ModifyInstanceAttribute` with `disableApiTermination=false`), it's a significant event. Without CloudTrail, you can't answer: who disabled it, when, and from where. Enable CloudTrail with an EventBridge rule or CloudWatch alarm that fires on any `ModifyInstanceAttribute` call targeting production instances.

---

## 🌍 Real-World Context

In most mature AWS environments, termination protection is considered a **mandatory default for any production instance** — whether it's a database, an application server, a monitoring host, or any service that would cause an incident if suddenly gone.

The gap between "enabled" and "not enabled" is a single API call made in the wrong context. A common real-world pattern is to enforce it through three layers:

1. **IaC defaults** — Terraform `aws_instance` module always sets `disable_api_termination = true` in production workspaces. The module variable requires an explicit override to turn it off.

2. **AWS Config rule** — a custom Config rule evaluates all EC2 instances with a `Environment=Production` tag and marks any without termination protection as NON_COMPLIANT. Security Hub surfaces this as a finding and it stays open until fixed.

3. **IAM SCP at the Organizations level** — an SCP denies `ec2:ModifyInstanceAttribute` on resources tagged `Environment=Production` for all principals except a designated break-glass IAM role. This means even an account admin can't disable protection without switching to the break-glass role — which is logged, alerted, and reviewed.

Together, these three layers ensure protection is on by default, drift is detected automatically, and deliberate override requires escalation and leaves an audit trail.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. A critical production EC2 instance was accidentally terminated by a junior engineer running a cleanup script. Walk me through the recovery process and what you'd put in place afterward.**

> First, assess the damage. Check whether the root EBS volume was deleted (depends on the Delete on Termination setting) and whether any EBS snapshots or AMIs exist from before the termination. If an AMI exists, launch a new instance from it and restore as much state as possible. If only a snapshot exists, create a new volume from it, launch a fresh instance, and attach it. If neither exists, you're rebuilding from scratch — application configs, data, everything. After recovery: enable termination protection on the rebuilt instance immediately. Enable Delete on Termination = false on all non-root volumes going forward. Set up AWS Data Lifecycle Manager for automated snapshots. Add a CloudTrail alarm on `TerminateInstances` events. And fix the cleanup script — filter more precisely, add a dry-run mode, require explicit confirmation before terminating anything.

---

**Q2. What's the exact error message returned when you try to terminate a protected instance via the CLI?**

> `An error occurred (OperationNotPermitted) when calling the TerminateInstances operation: The instance 'i-xxxxxxxxxxxxxxxxx' may not be terminated. Modify its 'disableApiTermination' instance attribute and try again.` The key part is the explicit instruction in the error itself: it tells you exactly what attribute to change. This error is the intended result of the protection working correctly — in automated contexts, you'd catch this specific error code to differentiate "protection is active" from a genuine API failure.

---

**Q3. Can termination protection be bypassed by someone with full EC2 permissions?**

> Yes — anyone with `ec2:ModifyInstanceAttribute` permission can disable termination protection in one API call and then terminate the instance. The protection is an operational safeguard, not a cryptographic or access-control boundary. To make it meaningful in a security context, you need IAM policies that restrict `ModifyInstanceAttribute` (specifically the `disableApiTermination` attribute) on production instances. AWS IAM supports condition keys that allow you to restrict attribute modification by resource tag — for example, deny `ModifyInstanceAttribute` on any instance tagged `Environment=Production` for all roles except a designated privileged role.

---

**Q4. Does termination protection affect Auto Scaling Group behaviour?**

> Yes, and this is a subtle but important operational point. If an instance in an ASG has `DisableApiTermination = true`, and the ASG triggers a scale-in event that selects that instance for termination, the termination will fail with `OperationNotPermitted`. The ASG will log an error and may attempt to select a different instance, or it may get stuck depending on how the termination policy is configured. This is why termination protection is generally not recommended for instances inside an ASG — the ASG's ability to manage instance lifecycle is a core feature, and blocking it creates unexpected behaviour. If you have a long-lived, stateful instance that needs protection, it typically shouldn't be in an ASG at all.

---

**Q5. You need to terminate 50 EC2 instances at the end of a project. How do you identify which ones have termination protection enabled so you know which ones need to be handled carefully?**

> Termination protection status isn't exposed in the main `describe-instances` response — you have to query it per-instance via `describe-instance-attribute`. For 50 instances you'd script it: list all instance IDs for the project (filtered by a project tag), then iterate and call `describe-instance-attribute --attribute disableApiTermination` for each, collecting those with `Value: true`. That gives you the protected list to handle as a deliberate manual step, while the unprotected ones can be terminated in a single batch call. For larger scale, this can be parallelized with `xargs -P` or done as a Lambda function that writes results to S3 or DynamoDB.

---

**Q6. How does `Delete on Termination` for EBS volumes relate to termination protection?**

> They're complementary but separate concepts. **Termination protection** (`DisableApiTermination`) prevents the instance from being terminated at all. **Delete on Termination** is an EBS volume attribute that controls whether a volume is deleted when its attached instance *is* terminated. For the root volume, Delete on Termination defaults to `true` — when the instance is terminated, the root volume is gone. For additional data volumes, it defaults to `false` — they persist as unattached volumes after termination. If you disable termination protection and terminate an instance, Delete on Termination determines what happens to the storage. Best practice: set Delete on Termination to `false` for any volume holding data you'd want to recover, and maintain a snapshot schedule regardless.

---

**Q7. How would you alert your team when termination protection is disabled on any production EC2 instance?**

> The sequence is: CloudTrail logs every `ModifyInstanceAttribute` call → EventBridge (CloudWatch Events) filters for events where the attribute being modified is `disableApiTermination` and the new value is `false` → EventBridge triggers an SNS notification to the team's alert channel (Slack, PagerDuty, email). The EventBridge pattern would look for CloudTrail events with `eventName = ModifyInstanceAttribute` and inspect the `requestParameters` for `attribute = disableApiTermination` and the value being set to false. In Terraform, this is a `aws_cloudwatch_event_rule` with a `aws_cloudwatch_event_target` pointing at an SNS topic. This turns a silent, dangerous action into an immediately visible event with full audit context: who made the call, from which IP, at what time, and on which instance.

---

## 📚 Resources

- [AWS Docs — Enable Termination Protection](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/terminating-instances.html#Using_ChangingDisableAPITermination)
- [AWS CLI Reference — modify-instance-attribute](https://docs.aws.amazon.com/cli/latest/reference/ec2/modify-instance-attribute.html)
- [AWS CloudTrail — Monitoring EC2 Events](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-event-reference.html)
- [AWS Config — Custom Rules for Compliance](https://docs.aws.amazon.com/config/latest/developerguide/evaluate-config_develop-rules.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
