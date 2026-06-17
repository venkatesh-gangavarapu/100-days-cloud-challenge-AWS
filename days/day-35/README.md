# Day 35 — Private RDS Instance + PHP App Connectivity from EC2

> **#100DaysOfCloud | Day 35 of 100**

---

## 📌 The Task

> *Provision a private MySQL RDS instance, configure security groups so an existing EC2 instance can reach it on port 3306, set up passwordless SSH to that instance, deploy a PHP file that connects to the RDS database, and confirm connectivity in the browser.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| RDS identifier | `devops-rds` |
| Template | Sandbox (Dev/Test) |
| Engine | MySQL 8.4.5 |
| Instance class | `db.t3.micro` |
| Master username | `devops_admin` |
| Storage | gp2, 5 GiB |
| Initial database | `devops_db` |
| SG rules | RDS: 3306 from `devops-ec2` | EC2: port 80 from internet |
| SSH | `/root/.ssh/id_rsa` → injected into `devops-ec2` root `authorized_keys` |
| App file | `/root/index.php` → `devops-ec2:/var/www/html/` |
| Verification | Browser shows "Connected successfully" |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### This Task Combines Four Patterns From Earlier Days

| Pattern | Where it appeared before |
|---------|--------------------------|
| RDS provisioning | Day 31 |
| Layered security groups | Day 24 (ALB) |
| SSH key injection | Day 22 |
| Web server + app deployment | Day 26 |

Day 35 is effectively the **integration test** of everything learned so far — provisioning a database, securing network access between tiers, establishing remote access, and deploying an application that ties it together.

### Sandbox / Dev-Test Template

The "Sandbox" template (labelled "Dev/Test" in the current console) configures an RDS instance without production safeguards:
- Single-AZ (no standby replica)
- No enhanced monitoring by default
- Lower-cost instance classes available
- Faster provisioning, lower cost

This matches the explicit requirement here — `db.t3.micro` with no Multi-AZ, appropriate for development/testing rather than production.

### Initial Database Name vs Creating a Database Later

RDS lets you specify an **initial database name** at creation time (`--db-name devops_db` in CLI, "Initial database name" field in console). RDS automatically runs `CREATE DATABASE devops_db;` during instance initialization — no manual SQL needed after the instance is available. This is different from creating additional databases later, which requires connecting via a MySQL client and running `CREATE DATABASE` manually.

### The Security Group Layering for App ↔ Database

```
Internet
    │  port 80
    ▼
devops-ec2 (security group: allow 80 from 0.0.0.0/0)
    │  port 3306
    ▼
devops-rds (security group: allow 3306 from devops-ec2's SG)
```

The RDS security group should reference **devops-ec2's security group as the source** (`--source-group`), not a CIDR block. This means only traffic originating from instances in that specific security group can reach port 3306 — regardless of what IP that instance happens to have. This is the same SG-as-source pattern used for the ALB → EC2 relationship on Day 24.

### Why PHP Needs `mysqli` or `PDO`

PHP doesn't talk to MySQL natively — it needs an extension. The two common options:
- **`mysqli`** — MySQL-specific procedural/OOP extension, simpler API
- **`PDO`** (PHP Data Objects) — database-agnostic, supports prepared statements across multiple DB engines

A typical "Connected successfully" test script uses `mysqli_connect()`:

```php
<?php
$servername = "RDS_ENDPOINT_HERE";
$username = "devops_admin";
$password = "YOUR_PASSWORD";
$dbname = "devops_db";

$conn = mysqli_connect($servername, $username, $password, $dbname);

if (!$conn) {
    die("Connection failed: " . mysqli_connect_error());
}
echo "Connected successfully";
?>
```

The script must have the **PHP mysqli extension installed** on the EC2 instance (`php-mysqlnd` on Amazon Linux, `php-mysql` on Ubuntu) — without it, `mysqli_connect()` is an undefined function and the page errors instead of showing the success message.

### RDS Endpoint — Why It Must Be Used, Not an IP

RDS endpoints are DNS names (`devops-rds.xxxxx.us-east-1.rds.amazonaws.com`), not static IPs. The underlying IP can change (failover, maintenance, replacement). The PHP script must reference the **endpoint hostname**, retrieved fresh via `describe-db-instances`, never a hardcoded IP.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

#### Part 1 — Create the RDS Instance

**Step 1.1 — Open RDS Console**
RDS Console → Databases → **Create database**

**Step 1.2 — Creation Method & Engine**
- **Standard create**
- Engine type: **MySQL**
- Engine version: **MySQL 8.4.5**

**Step 1.3 — Templates**
- Select **Dev/Test** (this is the "Sandbox" template)

**Step 1.4 — Settings**
- DB instance identifier: `devops-rds`
- Master username: `devops_admin`
- Master password: set a strong password and note it down

**Step 1.5 — Instance Configuration**
- DB instance class: **db.t3.micro**

**Step 1.6 — Storage**
- Storage type: **gp2**
- Allocated storage: **5 GiB**
- Leave storage autoscaling unchecked (not required for this task)

**Step 1.7 — Connectivity**
- Compute resource: **Don't connect to an EC2 compute resource**
- VPC: Default VPC
- Public access: **No**
- VPC security group: **Create new** → name: `devops-rds-sg`

**Step 1.8 — Additional Configuration** (expand this section)
- **Initial database name:** `devops_db`
- Leave everything else default

**Step 1.9 — Create**
- Click **Create database**
- Wait 10–15 minutes for status → **Available**

---

#### Part 2 — Configure Security Groups

**Step 2.1 — Get devops-ec2's Security Group**
EC2 Console → Instances → `devops-ec2` → **Security** tab → note the SG name/ID

**Step 2.2 — Allow Port 80 on devops-ec2's SG**
1. EC2 Console → Security Groups → select devops-ec2's SG
2. Inbound rules → Edit inbound rules → Add rule
   - Type: **HTTP** | Source: **Anywhere-IPv4** (`0.0.0.0/0`)
3. Save rules

**Step 2.3 — Allow Port 3306 on the RDS Security Group**
1. EC2 Console → Security Groups → select `devops-rds-sg`
2. Inbound rules → Edit inbound rules → Add rule
   - Type: **MYSQL/Aurora** (auto-fills port 3306)
   - Source: **Custom** → search and select **devops-ec2's security group** (not a CIDR)
3. Save rules

This way only traffic from instances in devops-ec2's SG can reach the database — not the whole internet.

---

#### Part 3 — Connect to devops-ec2 and Set Up SSH Key

**Step 3.1 — Connect via Console**
EC2 Console → `devops-ec2` → **Connect** → **EC2 Instance Connect** tab → **Connect**

A browser terminal opens.

**Step 3.2 — Get the Public Key from aws-client**
In a separate terminal on aws-client:
```bash
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
fi
cat /root/.ssh/id_rsa.pub
```
Copy the full output.

**Step 3.3 — Add the Key to devops-ec2's Root authorized_keys**
In the EC2 Instance Connect browser terminal:
```bash
sudo mkdir -p /root/.ssh
sudo chmod 700 /root/.ssh
echo "PASTE_YOUR_PUBLIC_KEY_HERE" | sudo tee -a /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys
```

**Step 3.4 — Allow SSH from aws-client**
1. EC2 Console → Security Groups → devops-ec2's SG
2. Inbound rules → Add rule → Type: **SSH** | Source: **My IP**
3. Save

**Step 3.5 — Test SSH from aws-client**
```bash
ssh -i /root/.ssh/id_rsa root@<devops-ec2-public-ip>
```
Should log in without a password prompt.

---

#### Part 4 — Deploy index.php

**Step 4.1 — Get the RDS Endpoint**
RDS Console → Databases → `devops-rds` → **Connectivity & security** tab → copy the **Endpoint** value

**Step 4.2 — Copy index.php from aws-client to devops-ec2**
On aws-client:
```bash
scp -i /root/.ssh/id_rsa /root/index.php root@<devops-ec2-public-ip>:/tmp/index.php
```

**Step 4.3 — Detect the OS Before Installing the Web Server**

⚠️ Don't assume the AMI family — `httpd` (Amazon Linux/RHEL) and `apache2` (Ubuntu/Debian) are **not interchangeable package or service names**. Check first:

```bash
ssh -i /root/.ssh/id_rsa root@<devops-ec2-public-ip>
cat /etc/os-release | grep -i PRETTY_NAME
```

**If Amazon Linux / RHEL** (`dnf` available):
```bash
dnf install -y httpd php php-mysqlnd
systemctl enable httpd
systemctl start httpd
```

**If Ubuntu / Debian** (`apt-get` available):
```bash
apt-get update -y
apt-get install -y apache2 php libapache2-mod-php php-mysql
systemctl enable apache2
systemctl start apache2
```

Running `systemctl enable httpd` on an Ubuntu instance fails with `Unit file httpd.service does not exist` — the unit simply isn't there because Ubuntu never installs a package called `httpd`. Always confirm the OS/package manager before assuming the service name.

**Step 4.4 — Edit index.php with the RDS Connection Details**
While still connected to devops-ec2:
```bash
nano /tmp/index.php
```
Update these lines:
```php
$servername = "devops-rds.xxxxxxxxxx.us-east-1.rds.amazonaws.com";
$username   = "devops_admin";
$password   = "YOUR_RDS_PASSWORD";
$dbname     = "devops_db";
```
Save and exit (Ctrl+O, Enter, Ctrl+X in nano).

**Step 4.5 — Move to Web Root and Restart**
```bash
cp /tmp/index.php /var/www/html/index.php

# Restart whichever web server is actually installed:
systemctl restart httpd     # Amazon Linux/RHEL
# or
systemctl restart apache2   # Ubuntu/Debian
```

---

#### Part 5 — Verify in Browser

1. EC2 Console → `devops-ec2` → copy the **Public IPv4 address**
2. Open a browser → `http://<public-ip>`
3. You should see: **`Connected successfully`** ✅

**Troubleshooting if the message doesn't appear:**

| Symptom | Check |
|---|---|
| Connection timeout in browser | Port 80 not open on devops-ec2 SG (Step 2.2) |
| Blank page | PHP mysqli extension not installed, or syntax error in index.php |
| "Connection failed" message | RDS endpoint/credentials wrong, or port 3306 not allowed from devops-ec2 SG (Step 2.3) |
| Page shows raw PHP code | Apache not configured to process .php files — confirm PHP module installed alongside the web server |
| `systemctl enable httpd` fails: "Unit file httpd.service does not exist" | Wrong package for this OS — see Step 4.3, use `apache2` on Ubuntu instead |

---

### Method 2 — AWS CLI

#### Full Script — Run on `aws-client`

```bash
#!/bin/bash
set -e
REGION="us-east-1"

DB_ID="devops-rds"
DB_PASSWORD="DevOps_Admin123!"
DB_NAME="devops_db"
DB_USER="devops_admin"

# ============================================================
# STEP 1: Resolve VPC and devops-ec2 details
# ============================================================

echo "=== Step 1: Resolving resources ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

EC2_ID=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=devops-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

EC2_SG=$(aws ec2 describe-instances --instance-ids $EC2_ID --region $REGION \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

EC2_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $EC2_ID --region $REGION \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "VPC: $VPC_ID"
echo "devops-ec2: $EC2_ID  SG: $EC2_SG  IP: $EC2_PUBLIC_IP"

# ============================================================
# STEP 2: Open port 80 on devops-ec2's security group
# ============================================================

echo ""
echo "=== Step 2: Opening port 80 on devops-ec2 SG ==="

aws ec2 authorize-security-group-ingress \
    --group-id $EC2_SG --protocol tcp --port 80 \
    --cidr 0.0.0.0/0 --region $REGION \
    2>/dev/null && echo "Port 80 opened" || echo "Rule may already exist"

# ============================================================
# STEP 3: Create a dedicated RDS security group
# Allow 3306 ONLY from devops-ec2's security group
# ============================================================

echo ""
echo "=== Step 3: Creating RDS security group ==="

RDS_SG=$(aws ec2 create-security-group \
    --region $REGION \
    --group-name devops-rds-sg \
    --description "devops-rds — MySQL 3306 from devops-ec2 only" \
    --vpc-id $VPC_ID \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=devops-rds-sg}]' \
    --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $RDS_SG --protocol tcp --port 3306 \
    --source-group $EC2_SG --region $REGION

echo "RDS SG: $RDS_SG (port 3306 from $EC2_SG)"

# ============================================================
# STEP 4: Resolve exact MySQL 8.4.5 engine version
# ============================================================

echo ""
echo "=== Step 4: Confirming MySQL 8.4.5 availability ==="

aws rds describe-db-engine-versions \
    --engine mysql --region $REGION \
    --query "DBEngineVersions[?EngineVersion=='8.4.5'].EngineVersion" \
    --output text

# ============================================================
# STEP 5: Create the RDS instance (private, sandbox-equivalent)
# ============================================================

echo ""
echo "=== Step 5: Creating RDS instance '$DB_ID' ==="

aws rds create-db-instance \
    --region $REGION \
    --db-instance-identifier "$DB_ID" \
    --db-instance-class "db.t3.micro" \
    --engine "mysql" \
    --engine-version "8.4.5" \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASSWORD" \
    --db-name "$DB_NAME" \
    --allocated-storage 5 \
    --storage-type "gp2" \
    --no-publicly-accessible \
    --no-multi-az \
    --vpc-security-group-ids $RDS_SG \
    --backup-retention-period 1 \
    --no-deletion-protection \
    --tags Key=Name,Value="$DB_ID"

echo "Creation started — waiting for available (~10-15 min)..."

aws rds wait db-instance-available \
    --db-instance-identifier "$DB_ID" --region $REGION

RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_ID" --region $REGION \
    --query "DBInstances[0].Endpoint.Address" --output text)

echo "✅ RDS available — endpoint: $RDS_ENDPOINT"

# ============================================================
# STEP 6: SSH key generation and injection into devops-ec2
# ============================================================

echo ""
echo "=== Step 6: SSH key setup ==="

if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -C "root@aws-client"
    echo "Generated new SSH key"
else
    echo "SSH key already exists"
fi
chmod 600 /root/.ssh/id_rsa
PUB_KEY=$(cat /root/.ssh/id_rsa.pub)

# Allow SSH from aws-client to devops-ec2
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --group-id $EC2_SG --protocol tcp --port 22 \
    --cidr "${MY_IP}/32" --region $REGION \
    2>/dev/null || echo "SSH rule may already exist"

# Inject public key via SSM (instance must have SSM agent + IAM role)
echo "Injecting public key via SSM Run Command..."
CMD_ID=$(aws ssm send-command \
    --region $REGION \
    --instance-ids "$EC2_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[
        'mkdir -p /root/.ssh',
        'chmod 700 /root/.ssh',
        'grep -qF \"${PUB_KEY}\" /root/.ssh/authorized_keys 2>/dev/null || echo \"${PUB_KEY}\" >> /root/.ssh/authorized_keys',
        'chmod 600 /root/.ssh/authorized_keys'
    ]" \
    --query "Command.CommandId" --output text)

sleep 10
echo "SSM command status:"
aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$EC2_ID" --region $REGION \
    --query "Status" --output text

# ============================================================
# STEP 7: Test SSH and copy index.php
# ============================================================

echo ""
echo "=== Step 7: Testing SSH and deploying index.php ==="

ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    root@$EC2_PUBLIC_IP "echo SSH OK"

# Copy index.php to the instance
scp -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no \
    /root/index.php root@$EC2_PUBLIC_IP:/tmp/index.php

# ============================================================
# STEP 8: Update DB connection details in index.php and deploy
# ============================================================

echo ""
echo "=== Step 8: Configuring index.php with RDS connection details ==="

ssh -i /root/.ssh/id_rsa root@$EC2_PUBLIC_IP bash -s << REMOTESCRIPT
set -e

# Ensure web server and PHP+MySQL extension are installed
if command -v dnf >/dev/null; then
    dnf install -y httpd php php-mysqlnd
    systemctl enable httpd
    systemctl start httpd
elif command -v apt-get >/dev/null; then
    apt-get update -y
    apt-get install -y apache2 php libapache2-mod-php php-mysql
    systemctl enable apache2
    systemctl start apache2
fi

# Update connection variables in index.php
sed -i "s/\\\$servername.*/\\\$servername = \"$RDS_ENDPOINT\";/" /tmp/index.php
sed -i "s/\\\$username.*/\\\$username = \"$DB_USER\";/" /tmp/index.php
sed -i "s/\\\$password.*/\\\$password = \"$DB_PASSWORD\";/" /tmp/index.php
sed -i "s/\\\$dbname.*/\\\$dbname = \"$DB_NAME\";/" /tmp/index.php

# Move to web root
cp /tmp/index.php /var/www/html/index.php

echo "index.php deployed and configured"
cat /var/www/html/index.php
REMOTESCRIPT

# ============================================================
# STEP 9: Verify "Connected successfully" in browser/curl
# ============================================================

echo ""
echo "=== Step 9: Verifying connection ==="

sleep 5
RESPONSE=$(curl -s http://$EC2_PUBLIC_IP)
echo "Response: $RESPONSE"

if echo "$RESPONSE" | grep -qi "Connected successfully"; then
    echo "✅ SUCCESS: PHP app connected to RDS"
else
    echo "⚠️  Did not see 'Connected successfully' — check PHP errors and SG rules"
fi

echo ""
echo "============================================"
echo "  RDS:        $DB_ID  ($RDS_ENDPOINT)"
echo "  Database:   $DB_NAME"
echo "  EC2:        devops-ec2 ($EC2_PUBLIC_IP)"
echo "  Test URL:   http://$EC2_PUBLIC_IP"
echo "============================================"
```

---

### The index.php Template

```php
<?php
$servername = "devops-rds.xxxxxxxxxx.us-east-1.rds.amazonaws.com";
$username   = "devops_admin";
$password   = "YOUR_PASSWORD";
$dbname     = "devops_db";

// Create connection
$conn = mysqli_connect($servername, $username, $password, $dbname);

// Check connection
if (!$conn) {
    die("Connection failed: " . mysqli_connect_error());
}
echo "Connected successfully";
?>
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CREATE RDS WITH INITIAL DB ---
aws rds create-db-instance \
    --db-instance-identifier devops-rds \
    --db-instance-class db.t3.micro \
    --engine mysql --engine-version 8.4.5 \
    --master-username devops_admin --master-user-password 'YourPass123!' \
    --db-name devops_db \
    --allocated-storage 5 --storage-type gp2 \
    --no-publicly-accessible --no-multi-az \
    --vpc-security-group-ids $RDS_SG --region $REGION

# --- WAIT ---
aws rds wait db-instance-available --db-instance-identifier devops-rds --region $REGION

# --- GET ENDPOINT ---
aws rds describe-db-instances --db-instance-identifier devops-rds --region $REGION \
    --query "DBInstances[0].Endpoint.Address" --output text

# --- ALLOW RDS PORT FROM EC2 SG ---
aws ec2 authorize-security-group-ingress --group-id $RDS_SG \
    --protocol tcp --port 3306 --source-group $EC2_SG --region $REGION

# --- ALLOW HTTP ON EC2 ---
aws ec2 authorize-security-group-ingress --group-id $EC2_SG \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION

# --- COPY FILE ---
scp -i /root/.ssh/id_rsa root@$EC2_IP:/tmp/index.php /var/www/html/

# --- TEST FROM EC2 TO RDS DIRECTLY ---
mysql -h $RDS_ENDPOINT -u devops_admin -p devops_db -e "SELECT 1;"

# --- VERIFY APP ---
curl http://$EC2_PUBLIC_IP
```

---

## ⚠️ Common Mistakes

**1. RDS security group allowing 3306 from `0.0.0.0/0` instead of the EC2's SG**
Opening the database port to the world defeats the purpose of a private RDS instance. Use `--source-group $EC2_SG` so only traffic originating from instances in that security group is allowed — regardless of their IP.

**2. PHP missing the `mysqli` or `pdo_mysql` extension**
A blank page or a `Call to undefined function mysqli_connect()` fatal error means the extension isn't installed. On Amazon Linux: `dnf install php-mysqlnd`. On Ubuntu: `apt-get install php-mysql`. Restart Apache/httpd after installing.

**3. Hardcoding an RDS IP instead of using the endpoint hostname**
RDS instances don't have a guaranteed static IP. Always reference the DNS endpoint from `describe-db-instances` — never resolve and hardcode an IP address, which can change after failover or maintenance.

**4. Forgetting the initial database name at creation**
Without `--db-name devops_db` at creation, RDS provisions the instance but no `devops_db` schema exists. The PHP script's `mysqli_connect()` call with `dbname` set would fail because the database doesn't exist. You'd have to connect manually and run `CREATE DATABASE devops_db;` after the fact.

**5. Testing before httpd/apache2 is actually running**
Copying `index.php` to `/var/www/html/` does nothing if the web server isn't installed or running. Confirm with `systemctl status httpd` (or `apache2`) before testing via curl/browser.

**6. Assuming `httpd` without checking the OS first**
`httpd` is the Apache package/service name on Amazon Linux and RHEL-family distros. Ubuntu and Debian use `apache2` instead — there is no `httpd` package or unit on Ubuntu at all. Running `dnf install httpd` or `systemctl enable httpd` on an Ubuntu instance fails outright (`Unit file httpd.service does not exist`), and `dnf` itself won't even be present since Ubuntu uses `apt-get`. Always run `cat /etc/os-release` (or check `which dnf apt-get`) before installing the web server, rather than assuming the AMI family.

**7. sed replacing PHP variable lines incorrectly**
When scripting changes to PHP variable assignments via `sed`, dollar signs need escaping in here-docs and quoting needs care — a malformed `sed` substitution can corrupt the PHP syntax (missing semicolon, broken string). Always `cat` the file after editing to confirm it's syntactically valid PHP before testing.

---

## 🌍 Real-World Context

This task is the classic **two-tier web application** pattern — web/app tier talking to a database tier, with security groups enforcing the boundary. In production, this evolves into:

**Connection pooling:** A single EC2 instance opening a new MySQL connection per page request doesn't scale. Production PHP apps use persistent connections or a connection pool (ProxySQL, RDS Proxy) to avoid exhausting `max_connections` on the database.

**Secrets management:** Hardcoding the DB password in `index.php` (as done here for simplicity) is unacceptable in production. The password should come from AWS Secrets Manager or SSM Parameter Store, fetched at runtime — never committed to source control or left in plaintext on disk.

**Multi-tier architecture:** In production, the EC2 instance running PHP would sit behind an ALB (Day 24), in a private subnet itself, with the RDS instance in an even more isolated database subnet — no direct internet exposure for either tier, only the ALB facing the internet.

**Database migrations:** The `devops_db` schema created here would, in a real app, be managed via migration tooling (Flyway, Liquibase, or framework-native migrations) rather than relying on the RDS initial database name feature — which only creates an empty schema, not the actual table structure the application needs.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. Why should an RDS security group reference another security group as the source instead of a CIDR block?**
> Referencing a security group as the source (`--source-group`) means the rule applies to any instance that's a member of that SG, regardless of its IP address — including IPs that change due to instance replacement, Auto Scaling, or stop/start cycles. A CIDR-based rule is tied to a fixed IP range and breaks the moment the application tier's IPs change, or admits unintended traffic if the CIDR is too broad. SG-referencing rules are dynamic, self-maintaining, and the standard pattern for any tier-to-tier access control within a VPC — exactly the same principle used for ALB-to-EC2 traffic on Day 24.

**Q2. What's the difference between specifying an initial database name at RDS creation vs creating it manually afterward?**
> The `--db-name` flag at creation time tells RDS to automatically run `CREATE DATABASE <name>;` as part of the instance initialization, before it reaches the `available` state. This means the schema exists immediately when the instance becomes usable — no extra steps. Creating a database manually afterward requires connecting with a MySQL client (`mysql -h endpoint -u admin -p`) and running `CREATE DATABASE devops_db;` yourself. Functionally equivalent, but the initial database name approach is one less manual step and is the standard approach when you know the application's primary database name upfront.

**Q3. The PHP page shows a blank screen instead of "Connected successfully" or an error message. How do you debug it?**
> A blank PHP page usually means a fatal error occurred but PHP's error display is turned off (the production-safe default). First, check the web server's error log — `/var/log/httpd/error_log` (Amazon Linux) or `/var/log/apache2/error.log` (Ubuntu) — which captures PHP fatal errors regardless of display settings. Common causes: the `mysqli` extension isn't installed (`Call to undefined function`), a PHP syntax error introduced during automated config edits, or incorrect file permissions preventing Apache from reading the file. Temporarily setting `display_errors = On` in `php.ini` (only in a non-production debugging context) surfaces the error directly in the browser for faster diagnosis.

**Q4. How would you avoid hardcoding the database password in the PHP file in a real deployment?**
> Store the credential in AWS Secrets Manager or SSM Parameter Store (as a SecureString) instead of the source file. At runtime, the PHP script calls the AWS SDK for PHP to fetch the secret: `$client->getSecretValue(['SecretId' => 'devops-rds-credentials'])`. This requires the EC2 instance to have an IAM role with `secretsmanager:GetSecretValue` permission — no credentials stored on disk at all. For simpler setups, environment variables (set via systemd unit `Environment=` directives or an `.env` file outside web root with restricted permissions) are a step up from hardcoding, though still less secure than Secrets Manager.

**Q5. What does `db.t3.micro` actually provide and when would you need to scale up?**
> `db.t3.micro` provides 2 vCPUs (burstable) and 1 GiB of RAM, with a baseline CPU performance that can burst higher using accumulated CPU credits. It supports roughly 60-80 concurrent MySQL connections depending on configuration. You'd need to scale up when: CPU credits are consistently exhausted (sustained load, not just bursts), `max_connections` is regularly hit (consider RDS Proxy before scaling compute), or query latency increases due to insufficient memory for the InnoDB buffer pool. The next steps up are `db.t3.small` (2 GiB RAM) or `db.t3.medium` (4 GiB RAM) — CloudWatch metrics (`CPUUtilization`, `DatabaseConnections`, `FreeableMemory`) tell you which dimension is actually constrained before you pick a bigger instance class.

**Q6. How do you verify network connectivity from EC2 to RDS without relying on the PHP application?**
> Use the MySQL client directly from the EC2 instance: `mysql -h <rds-endpoint> -u devops_admin -p -e "SELECT 1;"`. If this succeeds, the network path and credentials are correct, and any PHP-level failure is isolated to the application code or PHP extension, not infrastructure. If it fails with a connection timeout, the issue is network-level (security group, route table, or VPC misconfiguration). If it fails with an authentication error, the network path is fine but credentials are wrong. This step-by-step isolation — test transport layer before application layer — is the standard debugging order for any "can't connect" issue.

**Q7. What changes would you make to this setup before calling it production-ready?**
> At minimum: enable Multi-AZ on the RDS instance for automatic failover; move the database password to Secrets Manager with rotation enabled; put the EC2 instance behind an ALB rather than exposing it directly on port 80; move both EC2 and RDS into private subnets with no direct internet route, fronting only the ALB publicly; enable RDS automated backups with a longer retention window and enable deletion protection; switch the PHP `mysqli_connect()` to use TLS (`MYSQLI_CLIENT_SSL`) for encrypted connections to RDS; and replace the manually-edited `index.php` with a proper deployment pipeline (CodeDeploy, or at minimum a Git-based deploy script) rather than `scp` and `sed`.

---

## 📚 Resources

- [AWS Docs — Connecting to an RDS MySQL Instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ConnectToInstance.html)
- [PHP mysqli Extension](https://www.php.net/manual/en/book.mysqli.php)
- [RDS Security Groups](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Overview.RDSSecurityGroups.html)
- [AWS Secrets Manager for RDS Credentials](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_how-services-use-secrets_RS.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
