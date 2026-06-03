# Day 31 — Provision a Private RDS MySQL Instance

> **#100DaysOfCloud | Day 31 of 100**

---

## 📌 The Task

> *Provision a private RDS MySQL instance for application development and testing using the free tier, with storage autoscaling enabled.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| DB Identifier | `datacenter-rds` |
| Creation method | Standard create (Full configuration) |
| Template | Free tier |
| Engine | MySQL 8.4.x |
| Instance class | `db.t3.micro` |
| Public access | No (private) |
| Storage autoscaling | Enabled |
| Max storage threshold | 50 GB |
| Final state | Available |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### What Is Amazon RDS?

**Amazon RDS (Relational Database Service)** is a fully managed relational database service. "Managed" means AWS handles the undifferentiated heavy lifting:

| You manage | AWS manages |
|-----------|-------------|
| Schema design | OS patching |
| Query optimization | DB engine patching |
| Application configuration | Backups |
| Data | HA / failover (Multi-AZ) |
| Access control | Hardware provisioning |
| | Storage scaling |

You run SQL; AWS runs the database server.

### RDS vs Self-Managed MySQL on EC2

| | RDS MySQL | MySQL on EC2 |
|--|-----------|-------------|
| **Setup** | Minutes via console/CLI | Hours (install, configure, harden) |
| **Backups** | Automated (point-in-time recovery) | Manual (scripts, cron jobs) |
| **Patching** | Automated during maintenance window | Manual |
| **HA** | Multi-AZ with one config change | Build it yourself (replication) |
| **Cost** | Higher (managed premium) | Lower (raw compute) |
| **Control** | Limited (no OS access) | Full |

For most application workloads, RDS is the right choice. The managed premium pays for itself in operational time saved.

### Free Tier vs Production RDS

| | Free Tier | Production |
|--|-----------|-----------|
| **Template** | Free tier | Production / Dev/Test |
| **Instance** | db.t3.micro (750 hrs/month free) | db.r6g.large+ |
| **Storage** | 20 GB (free) | 100 GB+ |
| **Multi-AZ** | ❌ Not available | ✅ Recommended |
| **Read replicas** | ❌ Not available | ✅ Available |
| **Backups** | 7 days | 7–35 days |

### What "Private" RDS Means

**Public access: No** means the RDS endpoint is not reachable from the internet. The instance gets a private DNS name and IP only. To connect, you must:
- Be in the same VPC
- Go through a bastion host or VPN
- Use SSM port forwarding

This is the correct security posture for any database holding application data. A publicly accessible RDS instance is a security risk even with strong passwords.

### Storage Autoscaling

RDS Storage Autoscaling automatically increases storage capacity when:
- Free storage < 10% of allocated storage, **AND**
- The low-storage condition lasts at least 5 minutes, **AND**
- At least 6 hours have passed since the last storage modification

With 20 GB allocated and a 50 GB threshold:
- RDS can grow from 20 GB up to 50 GB automatically
- Each expansion increases storage by at least 10% or 5 GB (whichever is larger)
- No downtime during storage expansion (gp2/gp3)

### RDS Endpoint Format

Every RDS instance gets a DNS endpoint:
```
datacenter-rds.xxxxxxxxxx.us-east-1.rds.amazonaws.com:3306
```

Applications connect using this hostname — never the IP address (IPs change during failovers). The endpoint is available once the instance reaches `Available` state.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. **RDS Console → Create database**
2. **Standard create** (Full configuration method)
3. Engine: **MySQL** | Version: **MySQL 8.4.x**
4. Template: **Free tier**
5. DB identifier: `datacenter-rds`
6. Master username: `admin` | Set a strong password
7. Instance class: **db.t3.micro**
8. Storage: 20 GB gp2 | ✅ Enable autoscaling | Max threshold: **50 GB**
9. Connectivity → Public access: **No**
10. Create → wait ~15 minutes for `Available` status

---

### Method 2 — AWS CLI

```bash
REGION="us-east-1"

# ============================================================
# STEP 1: Get default VPC and subnet group
# ============================================================

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

# Get default subnet group (RDS creates one automatically for the default VPC)
aws rds describe-db-subnet-groups --region $REGION \
    --query "DBSubnetGroups[?contains(DBSubnetGroupName,'default')].DBSubnetGroupName" \
    --output text

# ============================================================
# STEP 2: Create a security group for RDS (allow MySQL port 3306)
# ============================================================

RDS_SG=$(aws ec2 create-security-group \
    --region $REGION \
    --group-name datacenter-rds-sg \
    --description "datacenter-rds MySQL access" \
    --vpc-id $VPC_ID \
    --query "GroupId" --output text)

# Allow MySQL from within the VPC only
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $REGION \
    --query "Vpcs[0].CidrBlock" --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $RDS_SG \
    --protocol tcp --port 3306 \
    --cidr $VPC_CIDR --region $REGION

echo "RDS SG: $RDS_SG (MySQL port 3306 from $VPC_CIDR)"

# ============================================================
# STEP 3: Create the RDS instance
# ============================================================

aws rds create-db-instance \
    --region $REGION \
    --db-instance-identifier "datacenter-rds" \
    --db-instance-class "db.t3.micro" \
    --engine "mysql" \
    --engine-version "8.4.3" \
    --master-username "admin" \
    --master-user-password "Admin1234!" \
    --allocated-storage 20 \
    --storage-type "gp2" \
    --max-allocated-storage 50 \
    --no-publicly-accessible \
    --no-multi-az \
    --backup-retention-period 7 \
    --vpc-security-group-ids $RDS_SG \
    --no-deletion-protection \
    --tags Key=Name,Value=datacenter-rds

echo "RDS instance creation started"

# ============================================================
# STEP 4: Wait for available status (~10-15 minutes)
# ============================================================

echo "Waiting for RDS instance to become available (this takes 10-15 min)..."

aws rds wait db-instance-available \
    --db-instance-identifier "datacenter-rds" \
    --region $REGION

echo "RDS instance is AVAILABLE"

# ============================================================
# STEP 5: Get instance details
# ============================================================

aws rds describe-db-instances \
    --db-instance-identifier "datacenter-rds" \
    --region $REGION \
    --query "DBInstances[0].{
        ID:DBInstanceIdentifier,
        Status:DBInstanceStatus,
        Engine:Engine,
        Version:EngineVersion,
        Class:DBInstanceClass,
        Storage:AllocatedStorage,
        MaxStorage:MaxAllocatedStorage,
        PublicAccess:PubliclyAccessible,
        Endpoint:Endpoint.Address,
        Port:Endpoint.Port
    }" --output table
```

---

### Verify the Instance is Available

```bash
# Quick status check
aws rds describe-db-instances \
    --db-instance-identifier datacenter-rds \
    --region us-east-1 \
    --query "DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address}" \
    --output table

# Test connectivity (from an EC2 instance in the same VPC)
mysql -h datacenter-rds.xxxxxxxxx.us-east-1.rds.amazonaws.com \
    -u admin -p --connect-timeout=5 \
    -e "SELECT VERSION();"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CREATE RDS ---
aws rds create-db-instance \
    --db-instance-identifier "datacenter-rds" \
    --db-instance-class "db.t3.micro" \
    --engine "mysql" --engine-version "8.4.3" \
    --master-username "admin" \
    --master-user-password "YourPassword123!" \
    --allocated-storage 20 \
    --max-allocated-storage 50 \
    --no-publicly-accessible \
    --no-multi-az \
    --region $REGION

# --- WAIT FOR AVAILABLE ---
aws rds wait db-instance-available \
    --db-instance-identifier datacenter-rds --region $REGION

# --- CHECK STATUS ---
aws rds describe-db-instances \
    --db-instance-identifier datacenter-rds --region $REGION \
    --query "DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address,Engine:Engine,Version:EngineVersion}" \
    --output table

# --- LIST ALL RDS INSTANCES ---
aws rds describe-db-instances --region $REGION \
    --query "DBInstances[*].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:Engine,Class:DBInstanceClass}" \
    --output table

# --- DELETE RDS ---
aws rds delete-db-instance \
    --db-instance-identifier datacenter-rds \
    --skip-final-snapshot \
    --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Using `db.t2.micro` instead of `db.t3.micro`**
The task specifies `db.t3.micro`. Free tier supports both, but always match the exact specification. `db.t2.micro` is older generation and AWS may not offer it for newer MySQL versions.

**2. Setting Public access to Yes**
The task explicitly requires a private instance. Public access = Yes exposes the MySQL port to the internet — a serious security risk even with a strong password. Always set `no-publicly-accessible` for any database instance.

**3. Not waiting for Available before submitting**
RDS creation takes 10–15 minutes. The task requires the instance to be in `Available` state. Submitting while the status is still `Creating` or `Backing-up` will fail validation.

**4. Forgetting to enable storage autoscaling**
The `--max-allocated-storage` flag in the CLI (or the checkbox + threshold in the console) enables autoscaling. Without it, the database will stop accepting writes when the 20 GB fills up. The task specifically requires this to be set to 50 GB.

**5. Wrong MySQL version**
The task requires MySQL 8.4.x. Selecting 8.0.x passes the engine check but fails version validation. In the console, expand the version dropdown — `8.4.x` is a separate minor version line from `8.0.x`.

**6. Not creating the instance in the correct VPC/subnet**
For a private instance, it must be in a VPC where `Public access: No` and the subnet has no direct internet route. Using the default VPC with the correct settings is fine for this task.

---

## 🌍 Real-World Context

**RDS in the three-tier architecture:**
In production, RDS sits in the **database tier** — private subnets with no internet access, security groups allowing only port 3306 from the application tier's security group. The application EC2 instances (or ECS tasks) connect using the RDS endpoint DNS name. No direct access from the internet, no bastion required for app traffic.

**Connection pooling:**
Direct RDS connections are expensive (MySQL has a `max_connections` limit based on instance size — db.t3.micro supports ~60-80). Production applications use connection pooling (PgBouncer for PostgreSQL, ProxySQL for MySQL, or **Amazon RDS Proxy**) to multiplex thousands of application connections into a small pool of actual DB connections.

**Parameter groups and option groups:**
RDS uses parameter groups to configure MySQL settings (e.g., `max_connections`, `innodb_buffer_pool_size`, `slow_query_log`). The default parameter group works for dev/test. Production databases use custom parameter groups tuned to the workload.

**Automated backups and PITR:**
RDS takes daily snapshots and stores transaction logs, enabling **Point-In-Time Recovery (PITR)** to any second within the backup retention window (7 days for free tier). This means you can restore to exactly 3 days, 4 hours, and 27 minutes ago if needed.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is the difference between RDS Multi-AZ and Read Replicas?**

> **Multi-AZ** is for **high availability**. RDS maintains a synchronous standby replica in a different AZ. If the primary fails, RDS automatically fails over to the standby with typically 60–120 seconds of downtime. The standby is not accessible for reads — it's purely a failover target. **Read Replicas** are for **read scaling**. They use asynchronous replication and can be in the same region, different regions, or different accounts. Applications can direct read queries to replicas to offload the primary. Read replicas can be promoted to standalone instances for DR. Free tier supports neither — both require Multi-AZ or replica-capable instance classes.

---

**Q2. How does RDS storage autoscaling work and what triggers it?**

> RDS storage autoscaling monitors free storage and expands automatically when three conditions are all true simultaneously: free storage is below 10% of allocated storage, the low-storage condition has persisted for at least 5 minutes, and at least 6 hours have passed since the last storage modification. The expansion increases storage by whichever is larger: 5 GB or 10% of current storage. It continues expanding in increments until free storage is above 10% or the maximum threshold is reached. With 20 GB allocated and a 50 GB maximum: the first trigger fires when free space drops below 2 GB, expanding to ~22 GB. This repeats until the database reaches 50 GB, after which no further autoscaling occurs.

---

**Q3. Why should an RDS instance never have Public access enabled?**

> A publicly accessible RDS instance exposes the MySQL port (3306) directly to the internet. Even with a strong password, this surface area is unnecessary — brute force attacks, credential stuffing, and zero-day exploits in the MySQL protocol all become viable attack vectors. In production, databases should only be reachable from within the VPC, from specific security groups (the application tier), through a bastion host for administrative access, or via RDS Proxy for connection management. The principle of least privilege applies to network access: if the database doesn't need to be reachable from the internet, it shouldn't be. AWS Security Hub and AWS Config both flag publicly accessible RDS instances as security findings.

---

**Q4. What is RDS Proxy and when would you use it?**

> RDS Proxy is a fully managed database proxy that sits between your application and RDS. It maintains a pool of established database connections and multiplexes many application connections into fewer actual database connections. Use cases: Lambda functions (each invocation creates a new DB connection — hundreds of concurrent Lambdas can exhaust `max_connections` in seconds; Proxy pools them), containerized microservices (pods scale up quickly and overwhelm the DB), and applications with bursty connection patterns. Proxy also improves failover times — it caches connections and transparently re-routes them after a Multi-AZ failover, reducing application-visible downtime from ~60 seconds to ~5 seconds. It's an additional cost but often worth it for serverless and container workloads.

---

**Q5. How do you connect to a private RDS instance that has no public access?**

> Four common approaches. **Bastion host**: EC2 instance in a public subnet that you SSH into, then connect to RDS from there. **SSH tunneling**: `ssh -L 3306:rds-endpoint:3306 ec2-user@bastion-ip` — forwards your local port 3306 to the RDS instance through the bastion. Your local MySQL client connects to `localhost:3306`. **SSM port forwarding**: `aws ssm start-session --target bastion-instance-id --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host=rds-endpoint,portNumber=3306,localPortNumber=3306` — no open SSH port needed on the bastion. **AWS Client VPN or Site-to-Site VPN**: establishes a network connection from your workstation directly into the VPC, making all private resources reachable.

---

**Q6. What happens to RDS data when you delete an instance?**

> By default, when you delete an RDS instance, AWS prompts you to create a **final snapshot** before deletion. If you skip the final snapshot, the data is gone permanently — there's no recycle bin or recovery option. If deletion protection is enabled, the delete operation fails entirely until you first disable deletion protection. Automated backups are deleted with the instance (unless you took a final snapshot). Manual snapshots persist indefinitely after instance deletion and continue to accrue storage costs until you delete them. For production databases, deletion protection should always be enabled — it prevents accidental deletion via console misclick or a stray `terraform destroy`.

---

**Q7. What is the difference between a DB parameter group and a DB option group?**

> A **parameter group** controls MySQL engine configuration variables — the equivalent of settings in `my.cnf`. Examples: `max_connections`, `innodb_buffer_pool_size`, `slow_query_log`, `character_set_server`. Changes to static parameters require a reboot; dynamic parameters apply immediately. Every RDS instance is associated with exactly one parameter group. A **option group** controls additional features that can be enabled for the database engine — MySQL-specific add-ons like `MARIADB_AUDIT_PLUGIN` (audit logging), `MEMCACHED` (InnoDB memcached plugin), or `MYSQL_AUDIT` (Oracle audit). Option groups are optional and specific to features that aren't part of core MySQL configuration. Most deployments only need custom parameter groups; option groups are used for specific compliance or integration requirements.

---

## 📚 Resources

- [AWS Docs — Amazon RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html)
- [AWS Docs — RDS Free Tier](https://aws.amazon.com/rds/free/)
- [RDS Storage Autoscaling](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIOPS.StorageTypes.html#USER_PIOPS.Autoscaling)
- [RDS Multi-AZ vs Read Replicas](https://aws.amazon.com/rds/features/multi-az/)
- [AWS RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
