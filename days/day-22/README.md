# Day 22 — SSH Key Setup and Passwordless EC2 Access via User Data

> **#100DaysOfCloud | Day 22 of 100**

---

## 📌 The Task

> *Set up a new EC2 instance (`devops-ec2`, `t2.micro`) accessible via passwordless SSH from the `aws-client` host. Generate an SSH key (`id_rsa`) on `aws-client` under `/root/.ssh/` if it doesn't exist, and inject the public key into the EC2 instance's `root` user's `authorized_keys`.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| EC2 instance name | `devops-ec2` |
| Instance type | `t2.micro` |
| SSH key location (aws-client) | `/root/.ssh/id_rsa` |
| Inject key to | `root` user's `authorized_keys` on EC2 |
| Access method | Passwordless SSH from `aws-client` → `devops-ec2` |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### Two Different SSH Key Concepts in This Task

This task involves **two separate SSH key mechanisms** that are easy to confuse:

| Key | Purpose | Where It Lives |
|-----|---------|---------------|
| **AWS Key Pair** | Initial SSH access to the instance (via the default AMI user) | AWS + local `.pem` file |
| **Custom `id_rsa` key** | The key we generate on `aws-client` and inject into `root`'s `authorized_keys` | `/root/.ssh/id_rsa` on `aws-client` |

The AWS Key Pair is used for the AMI's default user (e.g., `ubuntu` or `ec2-user`). The custom `id_rsa` key is what enables root-to-root passwordless SSH — the **actual goal** of this task.

### What Is EC2 User Data?

**User Data** is a shell script (or cloud-init configuration) passed to an EC2 instance at launch. It runs automatically **once**, as root, during the first boot — before any application starts, after the OS finishes booting. It's the mechanism for bootstrap automation: installing packages, writing config files, injecting SSH keys.

```
Instance first boot:
  OS initializes
      ↓
  cloud-init runs
      ↓
  User Data script executes (as root)
      ↓
  Instance becomes available
```

For this task, User Data is the cleanest injection mechanism — we embed the public key directly in the launch command, and the instance configures itself without any post-boot manual steps.

### How SSH Key Authentication Works

```
aws-client                          EC2 Instance
    │                                    │
    │  /root/.ssh/id_rsa (private)       │  /root/.ssh/authorized_keys
    │  /root/.ssh/id_rsa.pub (public) ──→│  (contains id_rsa.pub)
    │                                    │
    └──── ssh root@<IP> ────────────────→│
          Challenge: sign with private key
          Verify: against public key in authorized_keys
          Result: access granted ✅
```

The private key (`id_rsa`) never leaves `aws-client`. The public key (`id_rsa.pub`) is what gets placed on the EC2 instance. SSH authentication works by the client proving it holds the private key that matches the public key — without ever transmitting the private key.

### Why Root Access Requires Additional Steps

Most Linux AMIs disable direct `root` SSH login by default and disable password authentication for root entirely. The `authorized_keys` file for `root` at `/root/.ssh/authorized_keys` is typically empty or doesn't exist. To enable root SSH access, we need to:

1. Place the public key in `/root/.ssh/authorized_keys`
2. Ensure `/root/.ssh/` has permissions `700`
3. Ensure `authorized_keys` has permissions `600`
4. Ensure the SSH daemon allows root login (`PermitRootLogin` in `/etc/ssh/sshd_config`)

User Data handles all of this during first boot.

### The Full Workflow

```
On aws-client:
  1. Generate SSH key at /root/.ssh/id_rsa (if not exists)
  2. Read the public key: /root/.ssh/id_rsa.pub
  3. Build User Data script embedding the public key
  4. Launch EC2 instance with that User Data

On EC2 instance (automatic, via User Data):
  5. Create /root/.ssh/ directory with correct permissions
  6. Write the public key to /root/.ssh/authorized_keys
  7. Set correct permissions on authorized_keys
  8. Enable PermitRootLogin in sshd_config
  9. Restart SSH daemon

Back on aws-client:
  10. SSH to root@<EC2_IP> — passwordless access confirmed ✅
```

---

## 🔧 Step-by-Step Solution

### Full Script — Run on `aws-client`

```bash
#!/bin/bash
# ============================================================
# Day 22: Generate SSH key + Launch EC2 + Inject key via User Data
# Run this entire script on the aws-client host
# ============================================================

REGION="us-east-1"
KEY_PATH="/root/.ssh/id_rsa"
INSTANCE_NAME="devops-ec2"

# ============================================================
# STEP 1: Generate SSH key on aws-client (if not exists)
# ============================================================
if [ ! -f "$KEY_PATH" ]; then
    echo "Generating new SSH key at $KEY_PATH..."
    ssh-keygen -t rsa -b 4096 -f "$KEY_PATH" -N "" -C "root@aws-client"
    echo "SSH key generated"
else
    echo "SSH key already exists at $KEY_PATH — skipping generation"
fi

# Set correct permissions on the key
chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.pub"

# Read the public key content
PUB_KEY=$(cat "${KEY_PATH}.pub")
echo "Public key: $PUB_KEY"

# ============================================================
# STEP 2: Resolve the latest Amazon Linux 2023 AMI
# ============================================================
AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners amazon \
    --filters \
        "Name=name,Values=al2023-ami-2023*-x86_64" \
        "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "AMI: $AMI_ID"

# ============================================================
# STEP 3: Get default networking resources
# ============================================================
VPC_ID=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" --output text)

DEFAULT_SG=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text)

echo "VPC: $VPC_ID | Subnet: $SUBNET_ID | SG: $DEFAULT_SG"

# ============================================================
# STEP 4: Build User Data script with the public key embedded
# This runs on the EC2 instance at first boot as root
# ============================================================
USER_DATA=$(cat <<EOF
#!/bin/bash

# Create /root/.ssh directory with correct permissions
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Inject the public key into root's authorized_keys
echo "${PUB_KEY}" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Enable root SSH login via key (disable password auth)
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin without-password/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Restart SSH daemon to apply changes
systemctl restart sshd

echo "SSH key injection complete" >> /var/log/user-data.log
[OEOF
)

# ============================================================
# STEP 5: Launch the EC2 instance with User Data
# ============================================================
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$DEFAULT_SG" \
    --associate-public-ip-address \
    --user-data "$USER_DATA" \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Instance launched: $INSTANCE_ID"

# ============================================================
# STEP 6: Wait for instance to be running and pass status checks
# ============================================================
echo "Waiting for instance to reach running state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Waiting for status checks to pass..."
aws ec2 wait instance-status-ok \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

# ============================================================
# STEP 7: Get the public IP address
# ============================================================
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

echo ""
echo "============================================"
echo "  Instance: $INSTANCE_NAME ($INSTANCE_ID)"
echo "  Public IP: $PUBLIC_IP"
echo "  SSH command: ssh -i $KEY_PATH root@$PUBLIC_IP"
echo "============================================"

# ============================================================
# STEP 8: Wait a moment for SSH daemon to be ready and User Data to complete
# ============================================================
echo "Waiting 30 seconds for SSH daemon and User Data to complete..."
sleep 30

# ============================================================
# STEP 9: Test passwordless SSH connectivity
# ============================================================
echo "Testing passwordless SSH to root@$PUBLIC_IP..."

ssh -i "$KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    root@"$PUBLIC_IP" \
    "echo 'SSH connection successful — hostname: \$(hostname) — whoami: \$(whoami)'"

if [ $? -eq 0 ]; then
    echo "✅ Passwordless SSH to root@$PUBLIC_IP CONFIRMED"
else
    echo "⚠️  SSH test failed — User Data may still be running. Retry in 30 seconds."
fi
```

---

### Verifying the Setup

```bash
# Verify User Data ran correctly — check the log
ssh -i /root/.ssh/id_rsa root@<PUBLIC_IP> \
    "cat /var/log/user-data.log"

# Check authorized_keys was populated
ssh -i /root/.ssh/id_rsa root@<PUBLIC_IP> \
    "cat /root/.ssh/authorized_keys"

# Confirm sshd config allows root login
ssh -i /root/.ssh/id_rsa root@<PUBLIC_IP> \
    "grep PermitRootLogin /etc/ssh/sshd_config"

# Verify you're actually root
ssh -i /root/.ssh/id_rsa root@<PUBLIC_IP> "whoami && id"

# Check User Data script execution log (cloud-init)
ssh -i /root/.ssh/id_rsa root@<PUBLIC_IP> \
    "cat /var/log/cloud-init-output.log | tail -20"
```

---

### Adding SSH Key to Security Group (Port 22)

If the default security group doesn't allow SSH inbound, add the rule:

```bash
# Get your aws-client public IP
MY_IP=$(curl -s https://checkip.amazonaws.com)

# Add SSH inbound rule to default SG
aws ec2 authorize-security-group-ingress \
    --group-id "$DEFAULT_SG" \
    --protocol tcp \
    --port 22 \
    --cidr "${MY_IP}/32" \
    --region "$REGION"

echo "SSH rule added for $MY_IP/32"
```

---

## 💻 Commands Reference

```bash
# --- GENERATE SSH KEY (if not exists) ---
[ ! -f /root/.ssh/id_rsa ] && \
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -C "root@aws-client"

# Set correct permissions
chmod 600 /root/.ssh/id_rsa
chmod 644 /root/.ssh/id_rsa.pub

# Read public key
cat /root/.ssh/id_rsa.pub

# --- RESOLVE AMI ---
aws ec2 describe-images --region us-east-1 --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text

# --- LAUNCH WITH USER DATA ---
aws ec2 run-instances --region us-east-1 \
    --image-id <AMI_ID> --instance-type t2.micro \
    --subnet-id <SUBNET_ID> --security-group-ids <SG_ID> \
    --associate-public-ip-address \
    --user-data file:///tmp/userdata.sh \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=devops-ec2}]'

# --- WAIT ---
aws ec2 wait instance-status-ok --instance-ids <INSTANCE_ID> --region us-east-1

# --- GET IP ---
aws ec2 describe-instances --instance-ids <INSTANCE_ID> --region us-east-1 \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text

# --- TEST SSH ---
ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no root@<PUBLIC_IP> "whoami"

# --- CHECK USER DATA LOG ---
ssh -i /root/.ssh/id_rsa root@<PUBLIC_IP> "cat /var/log/cloud-init-output.log | tail -30"
```

---

## ⚠️ Common Mistakes

**1. Forgetting `PermitRootLogin` in sshd_config**
Most Linux AMIs set `PermitRootLogin prohibit-password` (AL2) or `PermitRootLogin no` (some Ubuntu). Even with the public key in `authorized_keys`, SSH will refuse to connect as `root` if `PermitRootLogin` is set to `no`. The User Data script must update this setting and restart sshd — without it, you'll see `Permission denied (publickey)` even with a perfectly injected key.

**2. Incorrect file permissions on `authorized_keys`**
SSH is strict about permissions. If `/root/.ssh/` is not `700` or `authorized_keys` is not `600`, the SSH daemon ignores the file entirely and falls back to other auth methods (which all fail). Always set permissions explicitly in User Data: `chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys`.

**3. Testing SSH before User Data finishes**
User Data runs after the instance passes status checks, but it runs asynchronously — the instance can be in `running` state and pass status checks while the User Data script is still executing. If you SSH in immediately after the waiter returns, the `authorized_keys` file may not exist yet. A 30-second sleep after `instance-status-ok` provides a practical buffer.

**4. Using `>>` instead of `>` when writing `authorized_keys` (or vice versa)**
`>` overwrites — if there were any previously injected keys (from the AMI default), they'd be gone. `>>` appends — safe for adding to existing entries. In this task `>>` is the correct choice since other keys may already be present in `authorized_keys`.

**5. Not testing with `StrictHostKeyChecking=no` on first connection**
On first SSH connection to a new host, SSH prompts: `The authenticity of host ... can't be established. Are you sure you want to continue?`. In automated scripts this interactive prompt causes the script to hang. Use `-o StrictHostKeyChecking=no` for automation (and add the host fingerprint to `known_hosts` afterward if this is a long-lived instance).

**6. Hardcoding the public key in the script instead of reading it from file**
The User Data script embeds the public key at the time of script execution (on `aws-client`). If the key file doesn't exist yet when you run the script, `PUB_KEY` will be empty and `authorized_keys` will get a blank line — SSH will fail silently. Always generate the key first, verify `id_rsa.pub` exists, then read it and embed it in User Data.

---

## 🌍 Real-World Context

Injecting SSH keys via EC2 User Data is a foundational pattern for automated instance provisioning. In production environments, several variations exist:

**AWS Systems Manager (SSM) Session Manager — The Modern Alternative:**
For most production use cases, direct SSH is replaced by SSM Session Manager — no port 22, no key management, full session logging to CloudTrail and S3. But understanding SSH key injection is still valuable for legacy environments, on-premises hybrid scenarios, and any situation where SSM isn't available.

**Automated bastion/jump host setup:**
When provisioning a bastion host via IaC, the operator's SSH public keys are injected via User Data (from a secrets manager, parameter store, or a public keys registry). Every authorised engineer has their key in the bastion's `authorized_keys` — access is managed centrally rather than per-instance.

**GitOps / Pipeline Integration:**
CI/CD systems (Jenkins, GitHub Actions) often need SSH access to EC2 instances for deployment. The pipeline generates (or retrieves from Secrets Manager) an SSH key pair, injects the public key during instance provisioning, and uses the private key in the pipeline credential store. The key is scoped to the pipeline role — no human ever sees the private key.

**The cloud-init standard:**
User Data in AWS uses `cloud-init` under the hood. For more complex bootstrap scenarios, YAML `cloud-config` documents (also supported as User Data) provide declarative syntax for writing files, running commands, installing packages, and adding users — without raw bash scripting.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is EC2 User Data and when does it run?**

> EC2 User Data is a script (shell script or cloud-init config) you provide at instance launch time. It runs **once**, automatically, during the **first boot** of the instance — executed as root by cloud-init after the OS initializes. It's the standard mechanism for bootstrap automation: installing packages, writing config files, injecting credentials, configuring services. The script runs after the instance passes network connectivity but before it's considered "ready" from an application perspective. Output is logged to `/var/log/cloud-init-output.log`, which is the first place to look when bootstrap behaviour is unexpected. By default, User Data only runs once — on first boot. You can configure it to run on every boot, but this is unusual.

---

**Q2. What permissions must `/root/.ssh/` and `authorized_keys` have for SSH key authentication to work?**

> The SSH daemon enforces strict ownership and permissions as a security measure. `/root/.ssh/` must be owned by root and have permissions `700` (owner read/write/execute only). `authorized_keys` must be owned by root and have permissions `600` (owner read/write only). If the directory is world-readable (`755`) or the file is group-readable (`644`), SSH silently ignores the `authorized_keys` file and authentication fails. The error in the client's output is `Permission denied (publickey)` — the same error as a wrong key — which makes this hard to diagnose without inspecting the server-side logs at `/var/log/auth.log` (Ubuntu) or `/var/log/secure` (Amazon Linux).

---

**Q3. Why would root SSH login fail even with the correct public key in `authorized_keys`?**

> The most common cause is the `PermitRootLogin` directive in `/etc/ssh/sshd_config`. Common values and their effects: `no` — root SSH login is completely forbidden; `prohibit-password` — root can authenticate with a key but not a password (this is the default on many AMIs); `yes` — root can authenticate with either key or password. If `PermitRootLogin no` is set, the SSH daemon refuses the connection regardless of what's in `authorized_keys`. The fix is to change the directive to `without-password` or `prohibit-password` and restart sshd. In User Data, we do this with `sed -i 's/^#*PermitRootLogin.*/PermitRootLogin without-password/' /etc/ssh/sshd_config && systemctl restart sshd`.

---

**Q4. What is the difference between using an AWS Key Pair at launch vs injecting a custom SSH key via User Data?**

> An **AWS Key Pair** is managed by AWS — you create it in the EC2 service, and at launch, AWS injects the public key into the default AMI user's `authorized_keys` (e.g., `ubuntu`, `ec2-user`). It gives you access as that default user. A **User Data-injected key** is managed by you — you generate the key pair independently, and at launch you include the public key in the bootstrap script, which writes it to any user's `authorized_keys` (including `root`). The User Data approach gives you more control: inject multiple keys, inject for arbitrary users, combine with key rotation logic. For automated pipelines and multi-user environments, the User Data pattern is more flexible than relying solely on the AWS Key Pair mechanism.

---

**Q5. The User Data script failed to inject the SSH key. How do you diagnose and recover?**

> First, check `/var/log/cloud-init-output.log` inside the instance — this contains the complete output of the User Data script execution and will show any errors. Access the instance via the AWS EC2 Serial Console (EC2 → Connect → EC2 Serial Console) or via Systems Manager Session Manager if the SSM agent is running, since regular SSH is unavailable if key injection failed. Once inside, manually verify: does `/root/.ssh/authorized_keys` exist? Does it contain the expected key? Are the permissions correct (`700`/`600`)? Is `PermitRootLogin` correctly set? You can manually run the failed commands and then restart sshd (`systemctl restart sshd`) to recover access.

---

**Q6. What is `StrictHostKeyChecking` in SSH and when should you disable it?**

> `StrictHostKeyChecking` controls whether SSH verifies the host's identity against known fingerprints in `~/.ssh/known_hosts`. When set to `yes` (default), SSH prompts for confirmation on first connection and refuses to connect if the stored fingerprint doesn't match — this protects against man-in-the-middle attacks. When set to `no`, SSH accepts any host fingerprint without prompting — useful in automation where interactive prompts would cause the script to hang. Use `no` only in controlled automation contexts where you've already validated the instance (e.g., you just launched it, you know the IP, and MITM risk is negligible). For long-lived connections or connections over untrusted networks, `yes` (the default) is correct security posture.

---

**Q7. What is the modern alternative to SSH for accessing EC2 instances and why is it preferred?**

> **AWS Systems Manager (SSM) Session Manager** is the modern replacement. It provides shell access to EC2 instances through the AWS API — no port 22 open, no SSH key management, no bastion host needed. The instance needs the SSM Agent (pre-installed on modern AMIs) and an IAM role with `AmazonSSMManagedInstanceCore`. Access is authenticated by the caller's IAM credentials and fully logged — every command run in a session can be captured to S3 and CloudWatch Logs. Security teams prefer it because: no inbound network exposure, no key rotation burden, audit trail with user attribution, and it works even if the instance has no public IP. `aws ssm start-session --target <instance-id>` opens a terminal in seconds.

---

## 📚 Resources

- [AWS Docs — Run Commands at Launch with User Data](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html)
- [cloud-init Documentation](https://cloudinit.readthedocs.io/)
- [AWS SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [SSH Authorized Keys Best Practices](https://www.ssh.com/academy/ssh/authorized-keys)
- [EC2 Serial Console](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-serial-console.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
