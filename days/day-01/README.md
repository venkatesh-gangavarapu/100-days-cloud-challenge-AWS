# Day 01 — Creating an AWS EC2 Key Pair

> **#100DaysOfCloud | Day 1 of 100**

---

## 📌 What I Worked On Today

Before you can SSH into any EC2 instance on AWS, you need a **Key Pair**. This is one of the very first things you set up in any AWS environment — it's the credential that replaces passwords for remote access to your Linux instances. Today I created an EC2 Key Pair both via the AWS Management Console and the AWS CLI, stored the private key correctly, and verified it's ready for use when I launch my first instance.

It sounds simple. But I've seen enough incidents caused by lost `.pem` files, wrong permissions, and misunderstood key ownership that I think it deserves a proper Day 1 treatment.

---

## 🧠 Core Concepts

### What Is an AWS Key Pair?

An AWS Key Pair is a set of asymmetric cryptographic keys — a **public key** and a **private key** — used to authenticate SSH connections to EC2 instances.

- AWS stores the **public key** on the instance at launch time (in `~/.ssh/authorized_keys`)
- You download and keep the **private key** (the `.pem` file) — AWS does **not** store it anywhere after the initial download
- When you SSH into the instance, your SSH client uses the private key to prove your identity against the public key on the server

If you lose the `.pem` file, you lose SSH access. There's no "forgot password" for this. That's why storing it properly from the start matters.

### Key Types Supported by AWS

| Type | Notes |
|------|-------|
| **RSA** | 2048-bit, widely compatible, older standard |
| **ED25519** | Modern, faster, more secure — recommended for new setups |

### Key Pair Formats

- **.pem** — Used with OpenSSH on Linux/macOS. This is what you'll use 95% of the time.
- **.ppk** — PuTTY format, used on Windows with PuTTY client. AWS can generate this too, or you can convert with PuTTYgen.

### Why You Must Set `chmod 400` on the `.pem` File

SSH is deliberately strict about private key file permissions. If your `.pem` file is group-readable or world-readable, the SSH client will refuse to use it and throw an "Unprotected private key file" error. Setting `chmod 400` makes the file readable only by you — that's the minimum required.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Log in to the [AWS Console](https://console.aws.amazon.com)
2. Navigate to **EC2 → Network & Security → Key Pairs**
3. Click **Create key pair**
4. Fill in the details:
   - **Name:** `my-aws-keypair` (use something descriptive — project name, environment, etc.)
   - **Key pair type:** `ED25519` *(preferred)* or `RSA`
   - **Private key file format:** `.pem` for Linux/macOS, `.ppk` for PuTTY on Windows
5. Click **Create key pair** — the `.pem` file downloads automatically
6. Move the key to a safe location and lock it down:

```bash
# Move to your SSH directory
mv ~/Downloads/my-aws-keypair.pem ~/.ssh/

# Set correct permissions — this is mandatory, SSH will reject it otherwise
chmod 400 ~/.ssh/my-aws-keypair.pem

# Verify the permission is set correctly
ls -l ~/.ssh/my-aws-keypair.pem
# Expected: -r-------- 1 youruser youruser ... my-aws-keypair.pem
```

---

### Method 2 — AWS CLI

```bash
# Create the key pair and save the private key directly to a .pem file
aws ec2 create-key-pair \
    --key-name my-aws-keypair \
    --key-type ed25519 \
    --key-format pem \
    --query "KeyMaterial" \
    --output text > ~/.ssh/my-aws-keypair.pem

# Lock down the private key
chmod 400 ~/.ssh/my-aws-keypair.pem

# Verify the key pair was created in AWS
aws ec2 describe-key-pairs --key-names my-aws-keypair
```

---

### Verifying the Key Pair

```bash
# List all key pairs in your account/region
aws ec2 describe-key-pairs

# Describe a specific key pair (shows fingerprint and metadata — not the private key)
aws ec2 describe-key-pairs --key-names my-aws-keypair

# Check the fingerprint of your local .pem file (to verify it matches AWS)
ssh-keygen -l -f ~/.ssh/my-aws-keypair.pem
```

---

### Using the Key Pair to SSH Into an EC2 Instance

Once you launch an EC2 instance and assign this key pair to it, connecting is straightforward:

```bash
# Generic SSH command
ssh -i ~/.ssh/my-aws-keypair.pem ec2-user@<PUBLIC_IP>

# Default usernames by AMI type:
# Amazon Linux 2 / Amazon Linux 2023 → ec2-user
# Ubuntu                              → ubuntu
# RHEL                                → ec2-user or cloud-user
# Debian                              → admin
# SUSE                                → ec2-user

# Example for Amazon Linux 2023
ssh -i ~/.ssh/my-aws-keypair.pem ec2-user@54.123.45.67
```

---

### Deleting a Key Pair

Deleting a key pair from AWS does **not** revoke access to instances already using it — the public key is embedded in those instances. Deletion just removes it from EC2's key pair registry, so it can't be assigned to new instances.

```bash
# Delete via CLI
aws ec2 delete-key-pair --key-name my-aws-keypair

# Remove the local private key as well
rm ~/.ssh/my-aws-keypair.pem
```

---

## 💻 Commands Reference

```bash
# --- INSTALLATION & SETUP ---
# Configure AWS CLI (if not already done)
aws configure

# Verify identity
aws sts get-caller-identity

# --- CREATE KEY PAIR (CLI) ---
aws ec2 create-key-pair \
    --key-name my-aws-keypair \
    --key-type ed25519 \
    --key-format pem \
    --query "KeyMaterial" \
    --output text > ~/.ssh/my-aws-keypair.pem

# Set correct file permissions
chmod 400 ~/.ssh/my-aws-keypair.pem

# --- VERIFY ---
# List all key pairs
aws ec2 describe-key-pairs

# Describe a specific key pair
aws ec2 describe-key-pairs --key-names my-aws-keypair

# View fingerprint of local private key
ssh-keygen -l -f ~/.ssh/my-aws-keypair.pem

# --- SSH ACCESS ---
ssh -i ~/.ssh/my-aws-keypair.pem ec2-user@<PUBLIC_IP>

# --- CLEANUP ---
aws ec2 delete-key-pair --key-name my-aws-keypair
rm ~/.ssh/my-aws-keypair.pem
```

---

## ⚠️ Common Mistakes

**1. Losing the `.pem` file**
AWS does not store your private key after you download it. If you lose it, the only option is to create a new key pair and replace it on your instances (or use EC2 Instance Connect / SSM Session Manager as a workaround). Back it up securely — password manager, encrypted vault, or a secrets manager like AWS Secrets Manager.

**2. Not running `chmod 400`**
SSH will refuse to connect with an overly permissive key file:
```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@         WARNING: UNPROTECTED PRIVATE KEY FILE!          @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
Permissions 0644 for 'my-aws-keypair.pem' are too open.
```
Fix: `chmod 400 ~/.ssh/my-aws-keypair.pem`

**3. Creating key pairs in the wrong region**
Key pairs are region-specific. A key pair created in `us-east-1` won't appear if you launch an instance in `ap-south-1`. Always confirm your CLI region or console region before creating.

**4. Sharing key pairs across teams**
A key pair represents an individual's access credential. If you share one `.pem` file among a team, you lose the ability to audit who accessed what, and revoking one person's access means rotating the key for everyone. Each person (or each service/role) should have their own key pair.

**5. Using root account to create key pairs**
Always use an IAM user or role for all AWS operations. Root is for account-level management only.

---

## 🌍 Real-World Context

In production, key-based SSH access to EC2 is increasingly being replaced or supplemented by **AWS Systems Manager (SSM) Session Manager**, which lets you open a shell session to an instance without exposing port 22 at all — no key pair, no inbound SSH rules on the security group required. This dramatically reduces the attack surface.

That said, key pairs are still fundamental knowledge. You'll use them in labs, personal projects, and any environment where SSM isn't set up. More importantly, understanding *how* SSH authentication works at this level makes everything else — security groups, bastion hosts, jump servers — easier to reason about.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

These are the questions that actually come up — in interviews, in on-call reviews, and in architecture discussions. Answers are written the way a working engineer would explain them, not the way a textbook would.

---

**Q1. You lost the `.pem` file for a running EC2 instance. How do you recover access?**

> You have a few options depending on what's available. If **SSM Agent is running** on the instance (which it is by default on Amazon Linux 2023 and many AMIs), you can use SSM Session Manager to open a shell without any key pair at all — navigate to EC2 → Connect → Session Manager. Once inside, you can add a new public key to `~/.ssh/authorized_keys` and then SSH normally from then on.
>
> If SSM isn't available, the next approach is to **detach the EBS root volume**, attach it to another instance as a secondary volume, mount it, drop a new public key into the `authorized_keys` file of the original instance's OS, reattach it, and start the instance back up.
>
> What you can't do is recover the original `.pem` — AWS never stored it. This is why production environments should use SSM Session Manager or AWS Systems Manager as the primary access method and treat key pairs as a backup, not the primary path.

---

**Q2. What's the difference between an EC2 Key Pair and an SSH key you generate locally with `ssh-keygen`?**

> Functionally they're the same thing — both produce an RSA or ED25519 public/private key pair. The difference is in workflow. When AWS creates the key pair, it generates both keys, gives you the private key as a `.pem` download, and stores the public key to inject into instances at launch. When you use `ssh-keygen` locally, *you* generate both keys and then import just the public key into AWS using the **Import key pair** option. The second approach is actually better practice — you keep full control of key generation, you can reuse the same keypair across clouds, and it integrates naturally with tools like `ssh-agent`.

---

**Q3. Why is ED25519 preferred over RSA for new key pairs?**

> ED25519 uses elliptic curve cryptography and produces shorter keys that are considered cryptographically stronger than 2048-bit RSA. It's also faster — key generation, signing, and verification are all quicker. The only reason you'd still choose RSA is compatibility with older systems or tools that don't support ED25519. For anything on AWS running a modern AMI, ED25519 is the right default.

---

**Q4. A new developer joins the team and needs SSH access to a set of EC2 instances. How do you handle this without sharing your `.pem` file?**

> You never share `.pem` files — that's a shared credential and it defeats the purpose of key-based authentication entirely. The proper approach: the developer generates their own SSH key pair locally with `ssh-keygen`, sends you their **public key**, and you add it to `~/.ssh/authorized_keys` on the relevant instances (either manually or via a provisioning tool like Ansible). Each person has their own private key, and you can revoke access individually by removing their public key from the file. At scale, this is managed with tools like AWS Systems Manager, HashiCorp Vault, or a centralized IAM-integrated approach.

---

**Q5. Your security team says "no port 22 should be open on any EC2 instance." But you still need shell access for debugging. What do you do?**

> This is where **SSM Session Manager** becomes the answer. It lets you open a terminal session to an instance entirely through the AWS API — no SSH, no port 22, no key pair required. All sessions are logged to CloudTrail and optionally to S3 or CloudWatch Logs, which gives you the audit trail the security team wants. The instance needs the SSM Agent running (standard on modern AMIs) and an IAM role with the `AmazonSSMManagedInstanceCore` policy attached. Once that's in place, `aws ssm start-session --target <instance-id>` drops you into a shell.

---

**Q6. Key pairs are region-specific. Walk me through what happens if you forget this.**

> You create a key pair in `us-east-1`, go to launch an instance in `ap-south-1`, and the dropdown for key pairs is empty — or worse, you pick a different key pair that happens to have the same name in another region, launch the instance, and then can't SSH in because you're using the wrong `.pem`. The fix is always the same: either re-create the key pair in the correct region, or use the **Import key pair** option to push your existing public key into every region you operate in. For multi-region environments, it's cleaner to import the same public key to all regions upfront so the name and fingerprint are consistent everywhere.

---

**Q7. What happens to an EC2 instance's key pair if you delete the key pair resource from AWS?**

> Nothing immediately — the instance keeps running and the public key is still sitting in `~/.ssh/authorized_keys` on the instance. The deletion only removes the key pair from EC2's registry, so it won't appear in the dropdown when launching new instances. If you still have the `.pem` file locally, you can still SSH in. The risk is that you delete the key pair from AWS, lose the `.pem`, and now have no record of what the key was — making recovery harder. It's a good reason to treat deletion of key pair records as a signal to immediately audit whether any running instances still depend on that key.

---

## 📚 Resources

- [AWS Docs — Amazon EC2 Key Pairs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-key-pairs.html)
- [AWS CLI Reference — create-key-pair](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-key-pair.html)
- [SSH Key Management Best Practices — AWS Security Blog](https://aws.amazon.com/blogs/security/)

---

*Part of my [#100DaysOfCloud](https://github.com/YOUR_USERNAME/100-days-cloud-aws) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/YOUR_PROFILE).*
