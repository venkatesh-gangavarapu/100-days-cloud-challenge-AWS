# Day 26 — Launch EC2 Web Server with Nginx via User Data

> **#100DaysOfCloud | Day 26 of 100**

---

## 📌 The Task

> *Create an EC2 instance named `xfusion-ec2` using Ubuntu, configure it to install and start Nginx automatically via User Data, and ensure port 80 is accessible from the internet.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Instance name | `xfusion-ec2` |
| AMI | Ubuntu (latest 22.04 LTS) |
| User Data | Install Nginx + start service |
| Security Group | Port 80 open to internet (`0.0.0.0/0`) |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### User Data + Security Group: The Two Pillars of Automated Web Server Provisioning

This task combines two concepts that have each appeared individually in earlier days:

- **User Data** (Day 22) — bootstrap script injected at launch, runs once as root on first boot
- **Security Groups** (Day 2) — virtual firewall controlling inbound/outbound traffic

Together, they form the minimal automated web server pattern: the instance self-configures (User Data), and the network path to reach it is open (Security Group). No manual SSH, no post-launch configuration steps.

### What User Data Does in This Task

```
Instance first boot timeline:
  ├── OS kernel starts
  ├── cloud-init initializes
  ├── User Data script runs as root:
  │     apt-get update -y
  │     apt-get install -y nginx
  │     systemctl start nginx
  │     systemctl enable nginx   ← persist across reboots
  └── Instance passes status checks
```

By the time the instance is `running` and has passed status checks, Nginx is already installed and serving. No operator action required after launch.

### Why `systemctl enable` Matters

`systemctl start nginx` starts the service right now. `systemctl enable nginx` creates the systemd symlink so Nginx automatically starts on every subsequent reboot. Without `enable`, a stop/start cycle or instance reboot would require manual intervention to bring Nginx back up. Both commands belong in any production bootstrap script.

### Security Group Port 80 — Why and How

Without an inbound rule allowing port 80, the instance's public IP is unreachable from browsers even though Nginx is running and listening. The security group acts as the outer gate. The correct rule:
- Protocol: TCP
- Port: 80
- Source: `0.0.0.0/0` (all IPv4) and optionally `::/0` (all IPv6)

For a production web server, port 80 from the internet is correct — but you'd typically also add port 443 (HTTPS) and put an ALB in front rather than exposing the instance directly. For this task, direct port 80 access is the stated requirement.

### The `apt-get update` Before Install — Why It's Non-Negotiable

Ubuntu cloud images are minimal — they don't have a fresh package index pre-cached. Without `apt-get update -y` before the install, `apt-get install nginx` may fail with "package not found" or install a stale version because the local package lists are outdated. Always update the package index before installing anything in User Data.

### Verifying the Setup

The verification chain works from the network inward:

```
curl http://<PUBLIC_IP>
        │
        ▼ (should return HTTP 200)
Security Group ── port 80 allowed?
        │
        ▼
Nginx running? ── systemctl status nginx
        │
        ▼
Nginx listening on port 80? ── ss -tlnp | grep :80
        │
        ▼
User Data ran? ── cat /var/log/cloud-init-output.log
```

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Step 1 — Create Security Group**
1. EC2 → Security Groups → Create security group
2. Name: `xfusion-sg` | VPC: default
3. Inbound rules: TCP port 80, source `0.0.0.0/0`
4. Create

**Step 2 — Launch Instance**
1. EC2 → Launch instances
2. Name: `xfusion-ec2`
3. AMI: Ubuntu Server 22.04 LTS (64-bit x86)
4. Instance type: `t2.micro`
5. Security group: select `xfusion-sg`
6. Expand **Advanced details** → **User data** — paste:
```bash
#!/bin/bash
apt-get update -y
apt-get install -y nginx
systemctl start nginx
systemctl enable nginx
```
7. Launch instance

**Verify:**
1. Wait for Instance state: `Running` and Status checks: `2/2 passed`
2. Copy the Public IPv4 address
3. Open `http://<PUBLIC_IP>` in a browser → should display the Nginx welcome page

---

### Method 2 — AWS CLI (Full Script)

```bash
REGION="us-east-1"
INSTANCE_NAME="xfusion-ec2"

# ============================================================
# STEP 1: Resolve latest Ubuntu 22.04 LTS AMI
# ============================================================
AMI_ID=$(aws ec2 describe-images \
[O    --region "$REGION" \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "AMI: $AMI_ID"

# ============================================================
# STEP 2: Resolve default VPC
# ============================================================
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" --output text)

echo "VPC: $VPC_ID | Subnet: $SUBNET_ID"

# ============================================================
# STEP 3: Create a dedicated security group for the web server
# ============================================================
SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name xfusion-sg \
    --description "xfusion web server — allow HTTP port 80 from internet" \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=xfusion-sg}]' \
    --query "GroupId" --output text)

echo "Security Group: $SG_ID"

# Add inbound rule: HTTP port 80 from anywhere
aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

echo "Inbound rule: TCP 80 from 0.0.0.0/0 added"

# ============================================================
# STEP 4: Build the User Data script
# Install Nginx, start it, enable it for reboots
# ============================================================
USER_DATA=$(cat <<'EOF'
#!/bin/bash
set -e
exec >> /var/log/user-data.log 2>&1
echo "=== User Data started: $(date) ==="

# Update package index
apt-get update -y

# Install Nginx
apt-get install -y nginx

# Start Nginx immediately
systemctl start nginx

# Enable Nginx to start on every reboot
systemctl enable nginx

# Verify Nginx is running and record status
systemctl status nginx >> /var/log/user-data.log 2>&1

echo "=== Nginx installed and running: $(date) ==="
echo "=== User Data completed ==="
EOF
)

# ============================================================
# STEP 5: Launch the EC2 instance with User Data
# ============================================================
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --user-data "$USER_DATA" \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Instance launched: $INSTANCE_ID"

# ============================================================
# STEP 6: Wait for running + status checks pass
# ============================================================
echo "Waiting for running state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" --region "$REGION"

echo "Waiting for status checks (2/2)..."
aws ec2 wait instance-status-ok \
    --instance-ids "$INSTANCE_ID" --region "$REGION"

echo "Instance is healthy"

# ============================================================
# STEP 7: Get public IP and verify
# ============================================================
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

echo ""
echo "============================================"
echo "  Instance:   $INSTANCE_NAME ($INSTANCE_ID)"
echo "  Public IP:  $PUBLIC_IP"
echo "  URL:        http://$PUBLIC_IP"
echo "============================================"

# Allow a brief pause for User Data to finish (runs after status checks)
echo "Waiting 30s for User Data to complete..."
sleep 30

# Test HTTP response
echo ""
echo "=== HTTP Test ==="
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$PUBLIC_IP")
echo "HTTP Status from Nginx: $HTTP_STATUS"

if [ "$HTTP_STATUS" == "200" ]; then
    echo "✅ Nginx is serving HTTP 200 at http://$PUBLIC_IP"
else
    echo "⚠️  Got HTTP $HTTP_STATUS — User Data may still be running. Retry in 30s."
    echo "    Debug: ssh ubuntu@$PUBLIC_IP then: cat /var/log/user-data.log"
fi
```

---

### Verifying Nginx from Inside the Instance

```bash
# SSH in (if key pair was specified)
ssh -i ~/.ssh/your-key.pem ubuntu@<PUBLIC_IP>

# Inside the instance:

# Check Nginx service status
sudo systemctl status nginx

# Confirm Nginx is listening on port 80
ss -tlnp | grep :80

# Check User Data ran correctly
cat /var/log/user-data.log

# Check full cloud-init output (all bootstrap activity)
cat /var/log/cloud-init-output.log | tail -30

# Confirm Nginx starts on reboot
sudo systemctl is-enabled nginx   # should return "enabled"

# Make a local request
curl -s http://localhost | head -5
```

---

### Optional: Custom Nginx HTML Page via User Data

```bash
# Extend the User Data script to serve a custom page
USER_DATA=$(cat <<'EOF'
#!/bin/bash
apt-get update -y
apt-get install -y nginx

# Replace default Nginx page with custom content
cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html>
<html>
<head><title>xfusion-ec2</title></head>
<body>
  <h1>Welcome to xfusion-ec2</h1>
  <p>Nginx is running. Deployment phase beginning soon.</p>
</body>
</html>
HTML

systemctl start nginx
systemctl enable nginx
EOF
)
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

# --- CREATE SECURITY GROUP (port 80) ---
SG_ID=$(aws ec2 create-security-group \
    --group-name xfusion-sg --description "HTTP port 80 for xfusion web server" \
    --vpc-id $VPC_ID --region "$REGION" --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION"

# --- LAUNCH INSTANCE WITH USER DATA ---
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" --instance-type t2.micro \
    --subnet-id $SUBNET_ID --security-group-ids $SG_ID \
    --associate-public-ip-address \
    --user-data '#!/bin/bash
apt-get update -y
apt-get install -y nginx
systemctl start nginx
systemctl enable nginx' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=xfusion-ec2}]' \
    --query "Instances[0].InstanceId" --output text)

# --- WAIT ---
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --region "$REGION"

# --- GET IP ---
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

# --- TEST ---
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" "http://$PUBLIC_IP"

# --- DEBUG USER DATA (from inside instance) ---
# cat /var/log/user-data.log
# cat /var/log/cloud-init-output.log | tail -30
# sudo systemctl status nginx

# --- CLEANUP ---
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 delete-security-group --group-id $SG_ID --region "$REGION"
```

---

## ⚠️ Common Mistakes

**1. Missing `apt-get update -y` before installing Nginx**
Ubuntu cloud images ship with a stale local package index. Running `apt-get install -y nginx` without updating first may fail with "package not found" or install an outdated version. The update is mandatory before any `apt install` in User Data.

**2. `systemctl start` without `systemctl enable`**
`start` runs Nginx now. `enable` makes it start on every boot. If the instance is stopped and started (which changes the public IP and reboots the instance), Nginx will be dead until someone manually starts it — or until the server is SSHed into and fixed. Always include both in bootstrap scripts.

**3. No security group rule for port 80 (or using the wrong source)**
The most common symptom: Nginx is running inside the instance (`curl localhost` returns 200), but the public IP returns a connection timeout. Check the security group — the instance's SG must have TCP port 80 with source `0.0.0.0/0`. If using the default security group without modification, port 80 is blocked by default.

**4. Testing immediately after `instance-status-ok` without waiting for User Data**
The `aws ec2 wait instance-status-ok` waiter returns when the EC2 status checks pass — but User Data is still running in the background at that point. On a clean Ubuntu image, `apt-get update` and `apt-get install nginx` typically take 30–60 seconds. Testing immediately may return a connection refused (nginx not yet installed) rather than a 200. A `sleep 30` buffer after the waiter or polling with `curl` until 200 is the correct approach.

**5. Forgetting to redirect User Data output to a log file**
User Data errors are silent unless you explicitly capture them. Adding `exec >> /var/log/user-data.log 2>&1` at the top of the script ensures all stdout/stderr goes to a log file you can inspect later. Without this, a failed `apt-get install` during bootstrap is invisible until you notice Nginx isn't running.

**6. Using `service nginx start` instead of `systemctl`**
`service` is a compatibility wrapper — it works, but `systemctl` is the correct interface for systemd-based systems (Ubuntu 16.04+). Use `systemctl start nginx` and `systemctl enable nginx` for clarity and consistency.

---

## 🌍 Real-World Context

Launching a web server via User Data is one of the most practical AWS patterns, and it forms the foundation of immutable infrastructure:

**Auto Scaling Group web servers:** ASG Launch Templates embed the User Data script. Every instance the ASG spins up runs the same bootstrap — install app, start service, register with load balancer. Scale to 50 instances and every one is identical. No configuration drift, no manual SSH.

**Golden AMI approach (more mature):** For faster scaling, teams pre-bake Nginx into a golden AMI. Launch → Nginx already installed and configured → instance is serving in 30 seconds instead of 90. User Data in this case might be a lightweight per-instance customization (write config file, register with service mesh) rather than full software installation.

**Nginx as a reverse proxy:** In production, Nginx rarely serves content directly. It sits in front of application servers (Node, Python, Java) running on the same instance or on internal targets, handling TLS termination, gzip compression, static asset caching, and request routing. The User Data pattern is the same — install Nginx, write the `/etc/nginx/sites-available/` config, enable the site, start the service.

**Configuration management at scale:** For complex setups, User Data runs a configuration management tool rather than doing everything inline. User Data installs the Ansible or Puppet agent, points it at the configuration server or S3-hosted playbook, and the tool handles the rest. This keeps the bootstrap script minimal and puts complex configuration in a maintainable, version-controlled format.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is EC2 User Data and how does it differ from running commands manually after launch?**

> User Data is a shell script (or cloud-init config) passed to an instance at launch time that runs automatically once, as root, during the first boot via cloud-init. The key distinction from manual post-launch configuration: it's **automated, repeatable, and scalable**. When you launch 10 instances from the same configuration (an ASG, a fleet deployment), each one runs the same User Data independently and self-configures. Manual post-launch commands require human intervention per instance — they don't scale and they introduce human error. User Data is the foundation of automated, immutable infrastructure. The output is logged to `/var/log/cloud-init-output.log`, which is the first diagnostic tool when something goes wrong at launch.

---

**Q2. Nginx is running inside the instance (`curl localhost` returns 200) but the public IP returns a connection timeout. What's wrong?**

> The security group blocking port 80 is the overwhelming likely cause. When `curl localhost` works (the OS loop-back interface, bypasses the firewall), but the public IP doesn't, the problem is at the network access control layer. Check the inbound rules of every security group attached to the instance: is there a rule allowing TCP port 80 from `0.0.0.0/0`? If not, add it. If the rule is there and it still doesn't work, check the subnet's Network ACL — NACLs are stateless and might be blocking the traffic at the subnet level. Finally, confirm the instance has a public IP assigned and is in a public subnet with a route to an Internet Gateway.

---

**Q3. What is the difference between `systemctl start` and `systemctl enable`?**

> `systemctl start nginx` starts the service immediately in the current running session — equivalent to "run it now." `systemctl enable nginx` creates systemd symlinks that cause the service to start automatically on every subsequent system boot — equivalent to "start it automatically every time the system starts." They're independent: a service can be started but not enabled (starts now, doesn't survive reboot), enabled but not started (will start next boot, not running now), both (running now and on every reboot), or neither. In a web server bootstrap, you need both: start for immediate availability, enable for persistence. Omitting `enable` is a common oversight that only reveals itself the first time the instance reboots.

---

**Q4. The User Data script runs `apt-get install -y nginx` but the instance is accessible and shows "connection refused" on port 80. What are your diagnostic steps?**

> Work down the stack. First, SSH in and check if Nginx is actually running: `systemctl status nginx`. If it's stopped or failed, Nginx either didn't install correctly or the service failed to start. Check the User Data log: `cat /var/log/user-data.log` and `cat /var/log/cloud-init-output.log`. If `apt-get install nginx` failed, the logs will show the error — usually either missing `apt-get update` or a network issue during package fetch. If Nginx is running but port 80 shows refused, check if it's actually listening: `ss -tlnp | grep :80`. If nothing's listening on 80, Nginx may have started on a different port due to a conflicting config. If it is listening on 80, the problem returns to the security group (see previous Q).

---

**Q5. What is the default Nginx web root path and what file does it serve?**

> The default document root for Nginx on Ubuntu is `/var/www/html/`. The default page served is `/var/www/html/index.nginx-debian.html` — the "Welcome to nginx!" page that appears in a browser after fresh installation. This is defined in the default Nginx site configuration at `/etc/nginx/sites-enabled/default`, which points the root directive to `/var/www/html`. To serve a custom page, you either replace `index.nginx-debian.html` with your own `index.html` (or symlink it), or modify the Nginx site config to point to a different document root. In User Data, you can write a custom `index.html` to `/var/www/html/index.html` after installation and Nginx will serve it immediately.

---

**Q6. How would you verify that Nginx will survive an instance reboot without SSHing in after the reboot?**

> Two verification approaches. Before the reboot: `sudo systemctl is-enabled nginx` inside the instance — if the output is `enabled`, the service is registered to start on boot. After a stop/start cycle (which triggers a reboot): wait for the instance to come back up, then run `curl http://<PUBLIC_IP>` — if Nginx is configured correctly with `systemctl enable`, it will have restarted automatically and will respond. The reboot also changes the public IP (if no Elastic IP), so get the new public IP after the instance restarts. In automated testing, you can add a CloudWatch alarm on `StatusCheckFailed` and a health check script that sends a test request after each reboot event.

---

**Q7. What is the difference between using User Data directly vs baking an application into a custom AMI?**

> Both install software on EC2 instances, but at different points in the lifecycle. **User Data at launch** installs software during first boot — the instance starts, runs the script, and becomes ready after the bootstrap completes (typically 60–120 seconds for a fresh apt install). This is flexible but slower for large-scale launches and adds boot time variability. **Custom AMI** pre-bakes software into a snapshot — the instance launches and the software is already present, reducing time to serving from 90 seconds to ~30 seconds. AMIs are immutable snapshots tested before use, reducing configuration drift risk. The trade-off: AMIs need to be updated when software versions change (regular pipeline rebuilds), while User Data always installs the latest version (which is both a feature and a risk — a broken package release can take down your fleet at launch). Production teams typically combine both: bake the slow or complex setup into the AMI, use User Data for per-instance runtime configuration.

---

## 📚 Resources

- [AWS Docs — Run Commands at Launch with User Data](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html)
- [cloud-init Documentation](https://cloudinit.readthedocs.io/)
- [Nginx on Ubuntu — Official Docs](https://nginx.org/en/linux_packages.html#Ubuntu)
- [systemd Unit Management](https://www.freedesktop.org/software/systemd/man/systemctl.html)
- [EC2 Security Groups — Day 2 Reference](../day-02/README.md)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
