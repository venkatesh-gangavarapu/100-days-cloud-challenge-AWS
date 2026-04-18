# Day 02 — Creating an AWS Security Group

> **#100DaysOfCloud | Day 2 of 100**

---

## 📌 What I Worked On Today

A Key Pair gets you in the door — but a **Security Group** decides whether the door is even reachable. Today I worked through creating and configuring EC2 Security Groups: what they are, how they enforce traffic rules, and how to set them up correctly via both the AWS Console and the CLI.

Security Groups are one of those things that look simple on the surface but carry a lot of operational weight. Misconfigured security groups are one of the most common causes of exposed AWS infrastructure. Getting comfortable with them early is non-negotiable.

---

## 🧠 Core Concepts

### What Is a Security Group?

A Security Group is a **stateful virtual firewall** that controls inbound and outbound traffic for AWS resources — primarily EC2 instances. Every instance must be associated with at least one security group. If you don't specify one at launch, AWS attaches the default security group for that VPC.

The key word is **stateful**: if you allow inbound traffic on port 80, the return traffic for that connection is automatically allowed outbound — you don't need a separate outbound rule for it. This is fundamentally different from Network ACLs (NACLs), which are stateless and require explicit rules in both directions.

### Inbound vs Outbound Rules

| Direction | Controls | Default Behaviour |
|-----------|----------|-------------------|
| **Inbound** | Traffic coming *into* the instance | All blocked by default |
| **Outbound** | Traffic going *out* from the instance | All allowed by default |

When you create a new security group, it starts with no inbound rules (deny everything) and one outbound rule (allow all). You add inbound rules explicitly based on what the instance needs to serve.

### Rule Components

Every rule has four parts:

| Field | Description |
|-------|-------------|
| **Type / Protocol** | TCP, UDP, ICMP, or All traffic |
| **Port Range** | Single port (22) or range (8080–8090) |
| **Source/Destination** | IP CIDR block, another security group, or prefix list |
| **Description** | Optional but should be treated as mandatory — it's the only context future-you has |

### Security Group as a Source

One of the most powerful features is using a **security group ID as the source** in an inbound rule. For example: your app server's security group can allow inbound traffic on port 5432 only from the security group assigned to your web servers. This means "any instance in the web-tier SG can talk to me on port 5432" — IP-independent, scales automatically as you add or remove instances.

### Default Security Group Behaviour

- All **inbound traffic is denied** unless explicitly allowed
- All **outbound traffic is allowed** by default
- Security groups are **allow-only** — there is no explicit deny rule. If traffic doesn't match any allow rule, it's dropped.
- Multiple security groups can be attached to one instance — the rules are **additive** (unioned together)
- Changes take effect **immediately** — no restart required

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Log in to the [AWS Console](https://console.aws.amazon.com)
2. Navigate to **EC2 → Network & Security → Security Groups**
3. Click **Create security group**
4. Fill in:
   - **Name:** `web-server-sg`
   - **Description:** `Allow HTTP, HTTPS, and SSH access for web servers`
   - **VPC:** Select your target VPC (default VPC for now)
5. Add **Inbound rules**:

   | Type | Protocol | Port | Source | Description |
   |------|----------|------|--------|-------------|
   | SSH | TCP | 22 | My IP | Admin SSH access |
   | HTTP | TCP | 80 | 0.0.0.0/0 | Public web traffic |
   | HTTPS | TCP | 443 | 0.0.0.0/0 | Public HTTPS traffic |

6. Leave **Outbound rules** as default (Allow All)
7. Add **Tags**: `Key: Name, Value: web-server-sg`
8. Click **Create security group**

---

### Method 2 — AWS CLI

```bash
# Step 1: Get your VPC ID (use the default VPC)
aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text

# Step 2: Create the security group
aws ec2 create-security-group \
    --group-name web-server-sg \
    --description "Allow HTTP, HTTPS, and SSH access for web servers" \
    --vpc-id <YOUR_VPC_ID> \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=web-server-sg}]'

# Note the GroupId from the output — e.g., sg-0abc1234def567890

# Step 3: Get your current public IP
curl -s https://checkip.amazonaws.com

# Step 4: Add inbound rule — SSH (restricted to your IP only)
aws ec2 authorize-security-group-ingress \
    --group-id sg-0abc1234def567890 \
    --protocol tcp \
    --port 22 \
    --cidr <YOUR_IP>/32

# Step 5: Add inbound rule — HTTP (public)
aws ec2 authorize-security-group-ingress \
    --group-id sg-0abc1234def567890 \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

# Step 6: Add inbound rule — HTTPS (public)
aws ec2 authorize-security-group-ingress \
    --group-id sg-0abc1234def567890 \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0
```

---

### Verifying the Security Group

```bash
# Describe the security group and all its rules
aws ec2 describe-security-groups --group-ids sg-0abc1234def567890

# List all security groups in the current region
aws ec2 describe-security-groups \
    --query "SecurityGroups[*].{Name:GroupName,ID:GroupId,VPC:VpcId}" \
    --output table

# Filter by name
aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=web-server-sg"
```

---

### Adding and Removing Rules After Creation

```bash
# Add a custom TCP rule (e.g., app running on port 8080)
aws ec2 authorize-security-group-ingress \
    --group-id sg-0abc1234def567890 \
    --protocol tcp \
    --port 8080 \
    --cidr 0.0.0.0/0

# Remove a rule (revoke)
aws ec2 revoke-security-group-ingress \
    --group-id sg-0abc1234def567890 \
    --protocol tcp \
    --port 8080 \
    --cidr 0.0.0.0/0

# Allow traffic from another security group (e.g., DB tier allowing only app tier)
aws ec2 authorize-security-group-ingress \
    --group-id sg-db-tier \
    --protocol tcp \
    --port 5432 \
    --source-group sg-app-tier
```

---

### Deleting a Security Group

```bash
# A security group cannot be deleted if it is attached to a running instance
# First detach it or terminate the instance, then:
aws ec2 delete-security-group --group-id sg-0abc1234def567890
```

---

## 💻 Commands Reference

```bash
# --- SETUP ---
# Get default VPC ID
aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text

# Get your public IP
curl -s https://checkip.amazonaws.com

# --- CREATE ---
aws ec2 create-security-group \
    --group-name web-server-sg \
    --description "Allow HTTP, HTTPS, and SSH for web servers" \
    --vpc-id <YOUR_VPC_ID> \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=web-server-sg}]'

# --- ADD INBOUND RULES ---
# SSH (your IP only)
aws ec2 authorize-security-group-ingress \
    --group-id <SG_ID> --protocol tcp --port 22 --cidr <YOUR_IP>/32

# HTTP (public)
aws ec2 authorize-security-group-ingress \
    --group-id <SG_ID> --protocol tcp --port 80 --cidr 0.0.0.0/0

# HTTPS (public)
aws ec2 authorize-security-group-ingress \
    --group-id <SG_ID> --protocol tcp --port 443 --cidr 0.0.0.0/0

# Allow from another security group
aws ec2 authorize-security-group-ingress \
    --group-id <SG_ID> --protocol tcp --port 5432 --source-group <SOURCE_SG_ID>

# --- VERIFY ---
aws ec2 describe-security-groups --group-ids <SG_ID>

aws ec2 describe-security-groups \
    --query "SecurityGroups[*].{Name:GroupName,ID:GroupId,VPC:VpcId}" \
    --output table

# --- REMOVE RULE ---
aws ec2 revoke-security-group-ingress \
    --group-id <SG_ID> --protocol tcp --port 8080 --cidr 0.0.0.0/0

# --- DELETE ---
aws ec2 delete-security-group --group-id <SG_ID>
```

---

## ⚠️ Common Mistakes

**1. Opening SSH (port 22) to `0.0.0.0/0`**
This exposes your instance to the entire internet. Bots scan for port 22 constantly — within minutes of launching an instance with this rule, you'll see brute-force attempts in your auth logs. Always restrict SSH to your IP (`/32`) or a bastion host security group.

**2. Not adding descriptions to rules**
AWS allows you to add a description per rule. Skipping this means six months later nobody knows why port 3000 is open or who added it. Treat rule descriptions as mandatory documentation.

**3. Confusing Security Groups with Network ACLs**
Security Groups are stateful and operate at the instance level. NACLs are stateless and operate at the subnet level. They're complementary, not interchangeable. A common mistake is debugging connectivity issues at the Security Group level when the NACL is actually blocking the traffic.

**4. Deleting a security group that's still in use**
AWS will block the deletion with an error: `DependencyViolation`. You must detach the SG from all resources first. If you're seeing this error, `describe-security-groups` combined with `describe-instances` will show you what's still referencing it.

**5. Stacking too many security groups on one instance**
EC2 allows up to 5 security groups per network interface by default. Attaching too many makes the effective rule set hard to audit and reason about. Prefer fewer, well-named security groups with clear ownership over a pile of overlapping ones.

---

## 🌍 Real-World Context

In any real AWS environment, security groups are organised by **tier** and **function**:

- `bastion-sg` — allows SSH from the corporate VPN CIDR only
- `web-sg` — allows 80/443 from the internet; SSH only from `bastion-sg`
- `app-sg` — allows app port only from `web-sg`; no direct internet access
- `db-sg` — allows database port only from `app-sg`; no internet whatsoever

This tiered model means that even if the web tier is compromised, the attacker can't directly reach the database — they'd have to pivot through the app tier. Security groups are the primary mechanism that enforces this separation in AWS.

The other production pattern worth knowing: in large environments, security group rules are managed through **Terraform** or **CloudFormation** and reviewed as code changes — not clicked through the console. The console is for debugging, not for making changes.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What's the difference between a Security Group and a Network ACL? When would you use each?**

> Security Groups are stateful and operate at the **instance level** — rules you add for inbound traffic automatically allow the return traffic. NACLs are stateless and operate at the **subnet level** — you need explicit allow rules in both directions, and they process rules in numbered order, stopping at the first match. In practice, Security Groups handle most of your traffic filtering. NACLs are used as a coarser, subnet-wide backstop — for example, blocking an entire IP range from reaching any resource in a subnet at all. If something can reach your instance that you think should be blocked, check both layers.

---

**Q2. A developer says "my app can't connect to the database on port 5432." How do you troubleshoot this using security groups?**

> First, confirm the obvious: is there an inbound rule on the database server's security group that allows TCP 5432 from the app server's IP or security group? Check both the database SG inbound rules and the app server's outbound rules (usually open by default, but worth confirming). If the rules look correct, check the NACL on the database's subnet — NACLs are stateless and might be blocking return traffic even if inbound is allowed. Then check OS-level firewalls (`iptables`, `firewalld`) on the DB instance itself. Work layer by layer: SG → NACL → OS firewall → application config.

---

**Q3. Your security group has `0.0.0.0/0` on port 22. You want to restrict it to only your office IP without any downtime. How do you do that safely?**

> Add the new rule (office IP `/32` on port 22) first, then remove the `0.0.0.0/0` rule. Security groups take effect immediately, so if you delete the open rule before adding the restricted one you'll lock yourself out. The order here is add-then-remove. In production I'd do this via CLI to avoid accidental console mistakes — one command to add the restricted rule, verify current active sessions are unaffected, then revoke the broad rule.

---

**Q4. Explain the "security group as source" pattern and give a use case.**

> Instead of specifying an IP range as the source for an inbound rule, you specify another security group ID. Any instance that belongs to that source security group is allowed through — regardless of its IP address. This is valuable in Auto Scaling environments where instance IPs change constantly. For example: your database SG allows TCP 5432 from the app-tier SG. When your Auto Scaling group launches new app servers, they inherit the app-tier SG and immediately have database access — no rule updates needed. You're expressing "any instance in this logical tier can talk to me" rather than "this specific IP can talk to me."

---

**Q5. Can you have explicit deny rules in a Security Group?**

> No. Security groups are **allow-only**. There's no explicit deny — if traffic doesn't match any allow rule, it's silently dropped. This is actually a deliberate design choice to keep rule sets simple and avoid the conflicts you can get with ordered deny/allow logic. If you need explicit denies — for example, blocking a specific IP that's hitting your application — that's a use case for NACLs, which do support deny rules and process them in numeric order.

---

**Q6. What happens to traffic if you attach two security groups to the same instance and they have conflicting rules?**

> There's no such thing as a conflict between security groups — the rules are unioned together, not evaluated against each other. If SG-A allows port 80 and SG-B allows port 443, the instance effectively allows both. If SG-A allows port 22 from `10.0.0.0/8` and SG-B allows port 22 from `0.0.0.0/0`, the effective rule is the union — port 22 from everywhere. This is a common source of unintended access: someone attaches a permissive SG for debugging and forgets to remove it.

---

**Q7. You need to audit all security groups in your account that have port 22 open to `0.0.0.0/0`. How do you do it?**

> AWS CLI with a filter and query:
> ```bash
> aws ec2 describe-security-groups \
>     --filters "Name=ip-permission.from-port,Values=22" \
>               "Name=ip-permission.to-port,Values=22" \
>               "Name=ip-permission.cidr,Values=0.0.0.0/0" \
>     --query "SecurityGroups[*].{Name:GroupName,ID:GroupId,VPC:VpcId}" \
>     --output table
> ```
> In a real production account this would run on a schedule — AWS Config has a managed rule called `restricted-ssh` that flags this automatically and can trigger a remediation Lambda to revoke the rule. Security Hub also surfaces this as a finding under the AWS Foundational Security Best Practices standard.

---

## 📚 Resources

- [AWS Docs — Security Groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html)
- [AWS CLI Reference — authorize-security-group-ingress](https://docs.aws.amazon.com/cli/latest/reference/ec2/authorize-security-group-ingress.html)
- [AWS Security Best Practices — VPC](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-best-practices.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
