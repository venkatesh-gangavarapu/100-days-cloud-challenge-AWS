# Day 06 — Launching an EC2 Instance

> **#100DaysOfCloud | Day 6 of 100**

---

## 📌 The Task

> *The Nautilus DevOps team is migrating infrastructure to AWS incrementally. As part of this effort, an EC2 instance needs to be provisioned with specific configuration.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Instance name | `devops-ec2` |
| AMI | Amazon Linux (latest Amazon Linux 2023) |
| Instance type | `t2.micro` |
| Key pair | `devops-kp` (new RSA key pair) |
| Security group | Default security group |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### What Is Amazon EC2?

**Amazon Elastic Compute Cloud (EC2)** is AWS's virtual machine service. Each EC2 instance is a virtual server running in AWS infrastructure — you choose the operating system, compute capacity, storage, and networking, and you pay only for what you use. EC2 is the foundational compute service that almost everything else in AWS either sits on or integrates with.

### AMI — Amazon Machine Image

An **AMI** is the blueprint for your instance. It defines:
- The operating system (Amazon Linux, Ubuntu, Windows, RHEL, etc.)
- Any pre-installed software
- The root volume snapshot
- Launch permissions and architecture (x86_64 vs ARM/Graviton)

AMIs are region-specific — the same AMI ID in `us-east-1` won't work in `us-west-2`. AWS provides official AMIs; you can also create custom AMIs from existing instances.

**Amazon Linux 2023 (AL2023)** is the current recommended Amazon Linux AMI. It replaced Amazon Linux 2 and is based on Fedora upstream with 5-year support. It's optimised for AWS, has the SSM Agent pre-installed, and comes with AWS CLI v2.

### Instance Types — The Compute Tier

Instance types define the CPU, memory, network, and storage characteristics. The naming convention breaks down as:

```
t2.micro
│ │  └── Size (nano, micro, small, medium, large, xlarge, 2xlarge...)
│ └───── Generation (1, 2, 3, 4...)
└─────── Family (t=burstable, m=general, c=compute, r=memory, g=GPU...)
```

| Family | Optimised For | Common Types |
|--------|--------------|--------------|
| `t` | Burstable general purpose | t3.micro, t3.small |
| `m` | Balanced general purpose | m5.large, m6i.xlarge |
| `c` | Compute intensive | c5.xlarge, c6i.2xlarge |
| `r` | Memory intensive | r5.large, r6i.4xlarge |
| `g` | GPU workloads | g4dn.xlarge |
| `i` | Storage optimised (NVMe) | i3.large |

**`t2.micro`** is a burstable instance — it earns CPU credits during idle periods and spends them during bursts. It falls within the AWS Free Tier (750 hours/month for the first 12 months). For production workloads with sustained CPU needs, `t3.medium` or an `m` family instance is more appropriate.

### Burstable Instances and CPU Credits

The `t` family instances (t2, t3, t3a) use a credit-based CPU model:
- The instance earns credits while CPU usage is below baseline
- Credits are spent when CPU usage exceeds baseline
- When credits run out, CPU is throttled to the baseline percentage
- `t3` and `t3a` support **unlimited mode** (spend credits and pay for extra CPU usage), while `t2` does not by default

For anything requiring predictable, sustained CPU performance — like a web server under constant load — choose a non-burstable instance type (`m`, `c`, etc.).

### The Five Components of Launching an EC2 Instance

Every instance launch requires decisions across five areas:

| Component | What It Controls |
|-----------|----------------|
| **AMI** | OS and base software |
| **Instance type** | CPU, RAM, network capacity |
| **Key pair** | SSH authentication |
| **Security group** | Network access rules (the firewall) |
| **Subnet / VPC** | Network placement and internet access |

### The Default Security Group

Every VPC is created with a **default security group**. Its rules are:
- **Inbound:** Allow all traffic from other instances associated with the same default security group
- **Outbound:** Allow all traffic to everywhere

For lab and development use, the default SG is fine. For production, you'd create purpose-built security groups with least-privilege rules as covered on Day 2.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Step 1 — Create the Key Pair**
1. Navigate to **EC2 → Network & Security → Key Pairs**
2. Click **Create key pair**
3. Name: `devops-kp` | Type: `RSA` | Format: `.pem`
4. Download and secure the `.pem` file:
```bash
mv ~/Downloads/devops-kp.pem ~/.ssh/
chmod 400 ~/.ssh/devops-kp.pem
```

**Step 2 — Launch the Instance**
1. Navigate to **EC2 → Instances → Launch instances**
2. **Name:** `devops-ec2`
3. **AMI:** Search for `Amazon Linux 2023 AMI` → select the 64-bit (x86) version
4. **Instance type:** `t2.micro`
5. **Key pair:** Select `devops-kp`
6. **Network settings:**
   - VPC: default
   - Subnet: any (no preference)
   - Security group: select **existing** → choose `default`
7. **Storage:** leave at default (8 GiB gp3 root volume)
8. Click **Launch instance**
9. Click the instance ID link → wait for **Instance state: Running** and **Status checks: 2/2**

---

### Method 2 — AWS CLI

```bash
# ============================================================
# Step 1: Create RSA Key Pair
# ============================================================
aws ec2 create-key-pair \
    --key-name devops-kp \
    --key-type rsa \
    --key-format pem \
    --region us-east-1 \
    --query "KeyMaterial" \
    --output text > ~/.ssh/devops-kp.pem

chmod 400 ~/.ssh/devops-kp.pem

# Verify key pair was created
aws ec2 describe-key-pairs --key-names devops-kp --region us-east-1

# ============================================================
# Step 2: Get the Latest Amazon Linux 2023 AMI ID
# ============================================================
aws ec2 describe-images \
    --region us-east-1 \
    --owners amazon \
    --filters \
        "Name=name,Values=al2023-ami-2023*-x86_64" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text

# ============================================================
# Step 3: Get the Default Security Group ID
# ============================================================
aws ec2 describe-security-groups \
    --region us-east-1 \
    --filters "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" \
    --output text

# ============================================================
# Step 4: Get the Default VPC's Default Subnet ID
# ============================================================
aws ec2 describe-subnets \
    --region us-east-1 \
    --filters "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" \
    --output text

# ============================================================
# Step 5: Launch the EC2 Instance
# ============================================================
aws ec2 run-instances \
    --region us-east-1 \
    --image-id <AMI_ID> \
    --instance-type t2.micro \
    --key-name devops-kp \
    --security-group-ids <DEFAULT_SG_ID> \
    --subnet-id <DEFAULT_SUBNET_ID> \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=devops-ec2}]' \
    --count 1

# Note the InstanceId from the output

# ============================================================
# Step 6: Wait for the Instance to be Running
# ============================================================
aws ec2 wait instance-running \
    --instance-ids <INSTANCE_ID> \
    --region us-east-1

echo "Instance is now running"
```

---

### Verifying the Instance

```bash
# Describe the instance with key details
aws ec2 describe-instances \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=devops-ec2" \
    --query "Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,PublicIP:PublicIpAddress,AMI:ImageId}" \
    --output table

# Get the public IP address
aws ec2 describe-instances \
    --region us-east-1 \
    --filters "Name=tag:Name,Values=devops-ec2" \
    --query "Reservations[*].Instances[*].PublicIpAddress" \
    --output text
```

---

### SSH Into the Instance

```bash
# Connect as ec2-user (default for Amazon Linux)
ssh -i ~/.ssh/devops-kp.pem ec2-user@<PUBLIC_IP>

# Verify you're on the right instance
cat /etc/os-release
curl http://169.254.169.254/latest/meta-data/instance-id
```

---

### Stopping, Starting, and Terminating

```bash
# Stop the instance (preserves EBS, releases public IP)
aws ec2 stop-instances \
    --instance-ids <INSTANCE_ID> \
    --region us-east-1

# Start it again
aws ec2 start-instances \
    --instance-ids <INSTANCE_ID> \
    --region us-east-1

# Terminate (permanent — deletes root EBS volume by default)
aws ec2 terminate-instances \
    --instance-ids <INSTANCE_ID> \
    --region us-east-1
```

---

## 💻 Commands Reference

```bash
# --- KEY PAIR ---
aws ec2 create-key-pair \
    --key-name devops-kp --key-type rsa --key-format pem \
    --region us-east-1 --query "KeyMaterial" --output text > ~/.ssh/devops-kp.pem
chmod 400 ~/.ssh/devops-kp.pem

# --- LOOKUP AMI ---
aws ec2 describe-images \
    --region us-east-1 --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text

# --- LOOKUP DEFAULT SG ---
aws ec2 describe-security-groups --region us-east-1 \
    --filters "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text

# --- LOOKUP DEFAULT SUBNET ---
aws ec2 describe-subnets --region us-east-1 \
    --filters "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" --output text

# --- LAUNCH INSTANCE ---
aws ec2 run-instances \
    --region us-east-1 \
    --image-id <AMI_ID> \
    --instance-type t2.micro \
    --key-name devops-kp \
    --security-group-ids <SG_ID> \
    --subnet-id <SUBNET_ID> \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=devops-ec2}]' \
    --count 1

# --- WAIT FOR RUNNING STATE ---
aws ec2 wait instance-running --instance-ids <INSTANCE_ID> --region us-east-1

# --- DESCRIBE ---
aws ec2 describe-instances --region us-east-1 \
    --filters "Name=tag:Name,Values=devops-ec2" \
    --query "Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,Type:InstanceType,PublicIP:PublicIpAddress}" \
    --output table

# --- SSH ---
ssh -i ~/.ssh/devops-kp.pem ec2-user@<PUBLIC_IP>

# --- STOP / START / TERMINATE ---
aws ec2 stop-instances --instance-ids <INSTANCE_ID> --region us-east-1
aws ec2 start-instances --instance-ids <INSTANCE_ID> --region us-east-1
aws ec2 terminate-instances --instance-ids <INSTANCE_ID> --region us-east-1
```

---

## ⚠️ Common Mistakes

**1. Using a hardcoded AMI ID across regions**
AMI IDs are region-specific. `ami-0abcdef1234567890` in `us-east-1` does not exist in `eu-west-1`. Always resolve the AMI ID dynamically using `describe-images` with filters, or use AWS SSM Parameter Store which stores the latest AMI IDs at a stable path: `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`.

**2. Forgetting `chmod 400` on the `.pem` file**
SSH will refuse to use a private key with overly permissive permissions and throw `WARNING: UNPROTECTED PRIVATE KEY FILE!`. Always `chmod 400` immediately after downloading or creating the key.

**3. Terminating vs stopping**
**Stop** shuts the instance down and preserves the EBS root volume — you pay for storage but not compute. **Terminate** permanently destroys the instance and, by default, deletes the root EBS volume. There is no undo for termination. Be deliberate about which command you run.

**4. Relying on the public IP across stop/start cycles**
When you stop and start an instance, the public IP address changes. If anything depends on that IP (DNS records, firewall rules, application config), it will break. The solution is an **Elastic IP** — a static public IP you allocate and associate with the instance. It persists through stop/start cycles.

**5. Using `t2.micro` for sustained workloads**
The `t2` family is burstable and doesn't support unlimited mode. Under sustained CPU load, once CPU credits are exhausted, performance is throttled. For anything beyond light or intermittent workloads, use `t3` (which supports unlimited mode) or a fixed-performance family like `m6i`.

**6. Launching without confirming subnet and AZ placement**
If you're also creating an EBS volume to attach to the instance, it must be in the same AZ as the instance. Launching the instance without specifying a subnet means AWS picks an AZ for you — and your pre-created volume in `us-east-1a` may end up needing to attach to an instance in `us-east-1b`.

---

## 🌍 Real-World Context

Clicking through the EC2 console to launch instances is fine for learning. In production, no one does it manually. EC2 instances in real environments are launched through one of these patterns:

- **Terraform** — `aws_instance` resource defined in code, reviewed, version-controlled, applied in CI/CD
- **Auto Scaling Groups (ASG)** — instances launched automatically from a Launch Template based on scaling policies or schedules, without any manual intervention
- **AWS Systems Manager (SSM) Automation** — runbook-based provisioning for specific operational workflows

The AMI you launch is also rarely the base Amazon Linux AMI. Production AMIs are typically **golden AMIs** — base AMIs hardened with your organisation's security baseline, pre-installed with monitoring agents, log shippers, and any application dependencies. They're built via EC2 Image Builder or HashiCorp Packer and stored in a private AMI registry.

The `t2.micro` Free Tier instance is the right starting point for learning. The mental model — AMI + type + key pair + security group + network placement — is identical whether you're launching a single dev instance or configuring an ASG for a thousand-node fleet.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. You need to launch an EC2 instance using the latest Amazon Linux AMI via a script or CI pipeline. How do you get the correct AMI ID without hardcoding it?**

> Two clean approaches. First, use AWS CLI with `describe-images` filtered by owner (`amazon`), name pattern, and architecture, sorted by creation date — `sort_by(Images, &CreationDate)[-1].ImageId` gives you the latest. Second, and cleaner for automation, use **SSM Parameter Store**: AWS publishes the latest AMI IDs at a well-known path like `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`. You can resolve it with `aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query "Parameter.Value" --output text`. In Terraform, the `aws_ssm_parameter` data source or the `aws_ami` data source with filters handles this cleanly without hardcoding anything.

---

**Q2. What's the difference between stopping and terminating an EC2 instance?**

> Stopping is like shutting down a computer — the instance powers off, the EBS root volume is preserved, and you keep paying for storage but not compute. You can start it again later, though the public IP will change. Terminating is permanent destruction — the instance is gone, and by default the root EBS volume is deleted with it (controlled by the Delete on Termination flag). Additional attached volumes are not deleted by default. There is no recovery from termination unless you have a snapshot or AMI. In production, **termination protection** is often enabled on critical instances — it prevents accidental termination via the console or CLI until explicitly disabled.

---

**Q3. An EC2 instance you just launched is reachable via ping but SSH is timing out. What are your first three checks?**

> In order: First, **security group inbound rules** — is port 22 allowed from my source IP? The most common cause by far. Second, **subnet route table** — is the instance in a public subnet with a route to an Internet Gateway? If it's in a private subnet, there's no inbound path from the internet. Third, **key pair and username** — am I using the right `.pem` file and the correct default username for the AMI? Amazon Linux uses `ec2-user`, Ubuntu uses `ubuntu`, RHEL uses `ec2-user` or `cloud-user`. A wrong username gives a connection that establishes but immediately drops, which can look like a timeout in some clients.

---

**Q4. Explain CPU credits on `t2` and `t3` instances. What happens when credits run out?**

> Burstable instances earn CPU credits over time while running below their baseline CPU utilisation. Each credit represents one minute of full vCPU usage. When the application needs more CPU than the baseline, it spends those credits. On `t2` instances, when credits are exhausted, the CPU is hard-throttled to the baseline percentage — a `t2.micro` baseline is 10% of one vCPU, so a depleted instance feels severely degraded. `t3` and `t3a` support **unlimited mode** (enabled by default since late 2020) — they can burst beyond their credit balance and you're billed for the extra CPU time at a small per-vCPU-hour rate. The symptom of a credit-depleted `t2` is high CPU wait, sluggish response times, and the CloudWatch `CPUCreditBalance` metric hitting zero. The fix is either switching to unlimited mode, upgrading to a `t3`, or moving to an `m` family instance if the workload needs consistent CPU.

---

**Q5. What is an Elastic IP and when should you use one?**

> An Elastic IP (EIP) is a static public IPv4 address that you allocate to your AWS account and associate with an EC2 instance or network interface. Unlike the auto-assigned public IP (which changes every time you stop and start the instance), an EIP persists until you explicitly release it. You use an EIP when something outside AWS needs to reach your instance at a predictable IP address — external firewall rules, DNS A records pointing directly to an IP, third-party allowlists, or SSL certificates tied to an IP. The cost caveat: EIPs are free while associated with a running instance, but AWS charges a small hourly fee if you have an EIP allocated but not associated — to discourage hoarding of public IPv4 addresses.

---

**Q6. What's the EC2 instance metadata service (IMDS) and how do applications use it?**

> The Instance Metadata Service (IMDS) is a local HTTP endpoint available inside every EC2 instance at `169.254.169.254`. It exposes instance-specific data — instance ID, region, AZ, public IP, IAM role credentials, user data, and more — without any authentication against AWS APIs. Applications use it to discover their own identity and environment at runtime: a script that needs to know which region it's running in calls `curl http://169.254.169.254/latest/meta-data/placement/region`. The newer version, **IMDSv2**, requires a session token and is the security-recommended default — it mitigates SSRF attacks where a compromised application could be tricked into fetching credentials from the metadata endpoint. When launching instances, you can enforce IMDSv2-only with `--metadata-options HttpTokens=required`.

---

**Q7. You need to pass a startup script to an EC2 instance — install packages, configure software, write files. How do you do that?**

> This is **EC2 User Data**. You pass a shell script at launch time (via `--user-data` in the CLI or the Advanced Details section in the console), and it runs automatically as root during the first boot of the instance. It's executed once — at first launch only, unless you explicitly re-enable it. A typical user data script might run `yum update -y`, install an application, write a config file, and start a service. The output is logged to `/var/log/cloud-init-output.log` on the instance, which is the first place to check if your startup script didn't behave as expected. For more complex provisioning — idempotent configuration management, secrets injection, drift detection — you'd use Ansible, AWS Systems Manager State Manager, or integrate with a tool like HashiCorp Vault during bootstrap.

---

## 📚 Resources

- [AWS Docs — Launch an EC2 Instance](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EC2_GetStarted.html)
- [AWS CLI Reference — run-instances](https://docs.aws.amazon.com/cli/latest/reference/ec2/run-instances.html)
- [EC2 Instance Types](https://aws.amazon.com/ec2/instance-types/)
- [Amazon Linux 2023 User Guide](https://docs.aws.amazon.com/linux/al2023/ug/what-is-amazon-linux.html)
- [EC2 IMDSv2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
