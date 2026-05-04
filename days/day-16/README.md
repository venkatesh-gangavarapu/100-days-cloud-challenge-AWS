# Day 16 — Creating an IAM User

> **#100DaysOfCloud | Day 16 of 100**

---

## 📌 The Task

> *IAM is among the first and most critical services to configure on AWS. The Nautilus DevOps team is configuring IAM resources and needs an IAM user created.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| IAM username | `iamuser_jim` |
| Region | `us-east-1` (IAM is global, but working from this region) |

---

## 🧠 Core Concepts

### What Is AWS IAM?

**Identity and Access Management (IAM)** is the AWS service that controls **who** can do **what** on **which** AWS resources. Every API call to AWS goes through IAM — it's the authorization layer for the entire platform.

IAM manages four core identity primitives:

| Primitive | What It Is |
|-----------|-----------|
| **Users** | Individual human or service identities with long-term credentials |
| **Groups** | Collections of users that share a permission set |
| **Roles** | Temporary identity assumed by services, instances, or federated users |
| **Policies** | JSON documents defining allowed/denied actions on resources |

### What Is an IAM User?

An **IAM User** is a permanent identity within an AWS account. It has:
- A unique username within the account
- Optional **console password** for AWS Management Console access
- Optional **access keys** (Access Key ID + Secret Access Key) for CLI/API/SDK access
- **Attached policies** or **group memberships** that grant permissions
- Optional **MFA device** for added security

By default, a newly created IAM user has **zero permissions** — the principle of least privilege is enforced from the moment of creation. The user exists but can't do anything until permissions are explicitly granted.

### IAM Is Global

Unlike most AWS services, **IAM is a global service** — it's not region-specific. An IAM user created in `us-east-1` is available across all regions. You interact with IAM via the console's global IAM dashboard or the `iam` CLI commands (no `--region` flag needed for IAM, though you can specify it).

### IAM User vs IAM Role — The Key Distinction

| | IAM User | IAM Role |
|--|---------|---------|
| **Credentials** | Long-term (password, access keys) | Temporary (STS tokens, expire in 1–12 hours) |
| **Designed for** | Human users, legacy service accounts | AWS services (EC2, Lambda), cross-account access, SSO federation |
| **Best practice** | Use for humans only; prefer SSO/federation | Preferred for all machine/service access |
| **Key rotation** | Manual (or automated via Secrets Manager) | Automatic (STS handles it) |

The modern AWS security posture: **human users should authenticate via SSO/federation (IAM Identity Center), not long-term IAM user credentials**. IAM users still exist for legacy integrations, specific tool requirements, and scenarios where federation isn't available.

### IAM User Credential Types

| Credential | Purpose | Security Note |
|-----------|---------|--------------|
| **Console password** | Login to AWS Management Console | Should require MFA |
| **Access keys** | CLI, SDK, API programmatic access | Rotate regularly; never commit to code |
| **SSH public keys** | AWS CodeCommit HTTPS git credentials | CodeCommit-specific |
| **Service-specific credentials** | CodeCommit, Amazon Keyspaces | Service-specific |

### The Principle of Least Privilege

Every IAM entity should have the minimum permissions required to do its job — nothing more. A user who only needs to read S3 objects should not have `s3:*`, let alone `AdministratorAccess`. Over-permissioned identities are the primary attack vector in cloud security incidents. AWS IAM Access Analyzer and Access Advisor help identify over-provisioned permissions in practice.

### IAM User Naming Conventions

IAM usernames are case-sensitive and can contain:
- Letters (a-z, A-Z)
- Numbers (0-9)
- The following special characters: `+ = , . @ - _`
- Maximum 64 characters

Common naming conventions in production: `firstname.lastname`, `service-account-name`, `team-application`, or prefixed patterns like `iamuser_jim` (as used in this task).

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Navigate to **IAM → Users → Create user**
2. **User name:** `iamuser_jim`
3. **Provide user access to the AWS Management Console:** Leave unchecked (unless console access is needed)
4. Click **Next**
5. **Set permissions:** Skip for now — user will have no permissions until explicitly granted
6. Click **Next** → review → **Create user**
7. **Verify:** Navigate to **IAM → Users** → confirm `iamuser_jim` appears in the list

---

### Method 2 — AWS CLI

```bash
# ============================================================
# Step 1: Create the IAM user
# ============================================================
aws iam create-user \
    --user-name iamuser_jim \
    --tags Key=Name,Value=iamuser_jim Key=ManagedBy,Value=cli

# Output confirms:
# {
#   "User": {
#     "UserName": "iamuser_jim",
#     "UserId": "AIDA...",
#     "Arn": "arn:aws:iam::152754585904:user/iamuser_jim",
#     "Path": "/",
#     "CreateDate": "2026-05-04T..."
#   }
# }

# ============================================================
# Step 2: Verify the user was created
# ============================================================
aws iam get-user --user-name iamuser_jim

# List all users to confirm it appears
aws iam list-users \
    --query "Users[*].{Username:UserName,UserID:UserId,ARN:Arn,Created:CreateDate}" \
    --output table
```

---

### Optional: Adding Console Access

```bash
# Create a login profile (enables console access with a password)
aws iam create-login-profile \
    --user-name iamuser_jim \
    --password "TempPassword@123!" \
    --password-reset-required

# The user must change their password on first login
```

---

### Optional: Creating Access Keys for CLI/API Access

```bash
# Create access keys (returns AccessKeyId + SecretAccessKey — store securely)
aws iam create-access-key \
    --user-name iamuser_jim

# IMPORTANT: The SecretAccessKey is shown ONLY ONCE at creation time
# Store it in a secrets manager — it cannot be retrieved again

# List existing access keys for the user
aws iam list-access-keys \
    --user-name iamuser_jim
```

---

### Optional: Attaching a Policy to the User

```bash
# Attach an AWS managed policy (e.g., ReadOnlyAccess)
aws iam attach-user-policy \
    --user-name iamuser_jim \
    --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

# List attached policies
aws iam list-attached-user-policies \
    --user-name iamuser_jim

# Detach a policy
aws iam detach-user-policy \
    --user-name iamuser_jim \
    --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
```

---

### Optional: Adding the User to a Group

```bash
# Create a group (if it doesn't exist)
aws iam create-group --group-name Developers

# Attach a policy to the group
aws iam attach-group-policy \
    --group-name Developers \
    --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

# Add the user to the group
aws iam add-user-to-group \
    --user-name iamuser_jim \
    --group-name Developers

# Verify group membership
aws iam list-groups-for-user \
    --user-name iamuser_jim
```

---

### Deleting the User (Full Cleanup)

```bash
# Before deleting a user, you must remove all attached resources:

# 1. Remove from groups
aws iam remove-user-from-group \
    --user-name iamuser_jim --group-name Developers

# 2. Detach policies
aws iam detach-user-policy \
    --user-name iamuser_jim \
    --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

# 3. Delete access keys
aws iam delete-access-key \
    --user-name iamuser_jim \
    --access-key-id <ACCESS_KEY_ID>

# 4. Delete login profile (if exists)
aws iam delete-login-profile --user-name iamuser_jim

# 5. Finally delete the user
aws iam delete-user --user-name iamuser_jim
```

---

## 💻 Commands Reference

```bash
# --- CREATE USER ---
aws iam create-user --user-name iamuser_jim

# --- VERIFY ---
aws iam get-user --user-name iamuser_jim

aws iam list-users \
    --query "Users[*].{Username:UserName,ARN:Arn,Created:CreateDate}" \
    --output table

# --- CONSOLE ACCESS ---
aws iam create-login-profile \
    --user-name iamuser_jim \
    --password "TempPassword@123!" \
    --password-reset-required

# --- ACCESS KEYS ---
aws iam create-access-key --user-name iamuser_jim
aws iam list-access-keys --user-name iamuser_jim

# --- ATTACH POLICY ---
aws iam attach-user-policy \
    --user-name iamuser_jim \
    --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

aws iam list-attached-user-policies --user-name iamuser_jim

# --- GROUP MEMBERSHIP ---
aws iam add-user-to-group \
    --user-name iamuser_jim --group-name Developers

aws iam list-groups-for-user --user-name iamuser_jim

# --- ENABLE MFA ---
# (Virtual MFA requires console interaction or TOTP token generation via CLI)
aws iam list-mfa-devices --user-name iamuser_jim

# --- DELETE USER (full cleanup) ---
# Remove groups → detach policies → delete keys → delete login profile → delete user
aws iam delete-user --user-name iamuser_jim
```

---

## ⚠️ Common Mistakes

**1. Assuming a new IAM user has any permissions**
A newly created IAM user has absolutely zero permissions by default — they can log in to the console if given a password, but they'll see nothing and can do nothing. Permissions come only from attached policies (directly on the user or via group membership). This is the intended behaviour — least privilege from day one.

**2. Creating access keys when they're not needed**
Access keys are long-term credentials. If they're compromised (leaked in code, committed to GitHub, logged accidentally), an attacker has persistent API access until the key is explicitly rotated or deleted. Don't create access keys unless the use case specifically requires them. For EC2 instances and Lambda functions, use IAM roles instead. For developers, use IAM Identity Center with short-lived credentials.

**3. Not enabling MFA on IAM users with console access**
An IAM user with a console password and no MFA is one phishing attempt away from full account compromise. Every IAM user with console access should have a virtual or hardware MFA device enforced. You can make it mandatory via an IAM policy that denies all actions unless MFA is present (`aws:MultiFactorAuthPresent: true` condition).

**4. Attaching policies directly to users instead of using groups**
When you have 50 developers, attaching policies individually to each user becomes unmanageable. Adding a new permission means updating 50 users. Groups solve this: put all developers in a `Developers` group, attach policies to the group, and managing permissions for the whole cohort is a single operation. Direct user policy attachments should be exceptions, not the rule.

**5. Using IAM users for EC2 or Lambda applications (storing access keys in code/env)**
This is one of the most common and dangerous mistakes in AWS. Hardcoded or environment-variable access keys in application code can be exfiltrated through application vulnerabilities, logged in plaintext, or committed to version control. EC2 instances should use **IAM Instance Profiles** (roles attached to the instance). Lambda should use **execution roles**. The instance metadata service (IMDS) provides the application with temporary credentials automatically — no access keys required.

**6. Never auditing unused IAM users or stale credentials**
IAM users for employees who left the company, service accounts for decommissioned systems, or access keys that haven't been used in 90+ days are all security liabilities. AWS **IAM Credential Reports** and **IAM Access Analyzer** surface this information. AWS Config has a managed rule (`iam-user-unused-credentials-check`) that flags credentials inactive for more than a configured number of days. Run these audits regularly.

---

## 🌍 Real-World Context

IAM user creation is the starting point of access management in AWS, but the modern approach has moved significantly beyond managing individual IAM users.

**The current best practice — IAM Identity Center (formerly AWS SSO):**
For organisations, human users should authenticate via **IAM Identity Center**, which federates with corporate identity providers (Active Directory, Okta, Azure AD, Google Workspace). Users log in with their corporate SSO credentials and receive short-lived, role-based access to specific AWS accounts and permission sets. No long-term IAM user credentials, no password management in AWS, automatic deprovisioning when the employee leaves the directory. IAM Identity Center is the recommended approach for any team with more than a handful of AWS users.

**When IAM users are still appropriate:**
- Specific tools or integrations that don't support STS assumed roles (rare but exists)
- Break-glass emergency access accounts (one or two per organisation, tightly controlled, MFA-enforced, heavily audited)
- CI/CD systems that can't use OIDC federation (though most modern CI/CD platforms now support OIDC → IAM role federation)

**The IAM user lifecycle in a compliant environment:**
Create → assign to group (not direct policy) → require MFA → enable credential rotation schedule → audit via Credential Report quarterly → deprovision when no longer needed.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is the difference between an IAM user, an IAM role, and an IAM group?**

> An **IAM user** is a permanent identity with long-term credentials — a username/password for console access and/or access keys for API access. It's designed for individual humans or legacy service integrations. An **IAM role** is a temporary identity assumed by an entity (an EC2 instance, a Lambda function, a developer via SSO, or another AWS account). When assumed, it issues short-lived STS credentials that expire automatically — no long-term credential management required. Roles are the preferred identity mechanism for all machine and service access. An **IAM group** is just a container for users that shares a policy set — adding a user to a group grants them all the group's permissions. Groups don't have credentials; they can't assume roles or make API calls themselves.

---

**Q2. A new IAM user is created and given `AdministratorAccess`. What are the security risks and how would you harden this?**

> `AdministratorAccess` grants unrestricted access to all AWS services and resources — equivalent to root for IAM purposes (though not identical to root). The risks: if the user's credentials are compromised, the attacker has full account access. Hardening steps: enforce MFA immediately (`aws:MultiFactorAuthPresent: true` condition on all actions); set a strong password policy; never create access keys for admin users unless absolutely necessary; rotate any access keys that do exist on a 90-day schedule; enable CloudTrail to log all API calls; set up CloudWatch alarms on sensitive actions (IAM changes, CloudTrail stops, root account usage). Long-term: migrate admin access to IAM Identity Center with time-limited permission sets, not permanent `AdministratorAccess` attached to a standing IAM user.

---

**Q3. How do you enforce MFA for all IAM users in an AWS account?**

> Create an IAM policy that allows all actions only when MFA is authenticated, and attach it to all users or a group all users belong to. The policy uses the condition `"Bool": {"aws:MultiFactorAuthPresent": "true"}` to allow access, and denies everything when MFA is absent — except for the specific actions needed to set up MFA (`iam:CreateVirtualMFADevice`, `iam:EnableMFADevice`, `iam:GetUser`, `iam:ListMFADevices`). When a user logs in without MFA, they can only navigate to IAM to enroll their MFA device — all other API calls are denied. At the organisation level, AWS Organizations SCPs can enforce that no actions are permitted unless the calling user has MFA enabled.

---

**Q4. What is the IAM Credential Report and what would you use it for?**

> The **IAM Credential Report** is a downloadable CSV file (available via the IAM console or `aws iam generate-credential-report`) that lists all IAM users in the account and the status of their credentials: when passwords were last used, when access keys were last rotated, whether MFA is enabled, and whether access keys are active. It's the primary tool for security audits: identifying users with old access keys that haven't been rotated, users with console passwords who have never logged in, users without MFA on console-enabled accounts, and access keys that haven't been used in months (indicating they may be stale and should be deleted). Most compliance frameworks (SOC 2, ISO 27001, CIS AWS Foundations) require regular credential report reviews.

---

**Q5. An EC2 instance needs to read objects from an S3 bucket. Should you create an IAM user and put access keys on the instance? What's the correct approach?**

> Never put access keys on an EC2 instance. The correct approach is an **IAM Instance Profile**: create an IAM role with a policy that allows `s3:GetObject` on the specific bucket, create an instance profile from that role, and attach it to the EC2 instance. The instance metadata service (IMDS) then automatically provides the application with short-lived, auto-rotating STS credentials. The AWS SDK picks these up transparently — no credential configuration, no key rotation, no risk of keys being leaked in code, logs, or debug output. If the instance is compromised, the blast radius is limited to the permissions granted to that specific role. This is the foundational principle behind all EC2-to-AWS service authentication.

---

**Q6. What is IAM Identity Center and how does it replace traditional IAM users for human access?**

> **IAM Identity Center** (formerly AWS SSO) is AWS's managed identity federation service. It connects to your existing identity provider — Active Directory, Okta, Azure AD, Google Workspace — and maps users and groups to **permission sets** (bundles of IAM policies) across one or many AWS accounts in your organisation. When a developer needs AWS access, they authenticate with their corporate SSO, select an account and role in the IAM Identity Center portal or CLI, and receive short-lived credentials scoped to that role. Benefits: no long-term AWS credentials to manage, automatic deprovisioning when an employee leaves the IdP, centralised access management across all accounts in an AWS Organisation, and a full audit trail in CloudTrail for all assumed-role sessions. For any organisation with more than a few people, this is the correct approach to human IAM access.

---

**Q7. You need to audit all IAM users in an account that have access keys older than 90 days. How do you do it?**

> The fastest approach is the IAM Credential Report:
> ```bash
> # Generate the report
> aws iam generate-credential-report
>
> # Download it
> aws iam get-credential-report \
>     --query "Content" --output text | base64 -d > credential-report.csv
>
> # Filter for access keys older than 90 days (using awk/python)
> # access_key_1_last_rotated column contains the rotation date
> ```
> Alternatively, iterate programmatically:
> ```bash
> aws iam list-users --query "Users[*].UserName" --output text | \
> tr '\t' '\n' | while read user; do
>     aws iam list-access-keys --user-name "$user" \
>         --query "AccessKeyMetadata[?Status=='Active'].{User:'$user',KeyID:AccessKeyId,Created:CreateDate}" \
>         --output table
> done
> ```
> In production, this runs as a scheduled Lambda that writes findings to Security Hub or sends alerts to Slack when stale keys are discovered. AWS Config's `access-keys-rotated` managed rule handles this automatically — it marks any active access key older than the configured max age as NON_COMPLIANT.

---

## 📚 Resources

- [AWS Docs — IAM Users](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users.html)
- [AWS CLI Reference — create-user](https://docs.aws.amazon.com/cli/latest/reference/iam/create-user.html)
- [IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html)
- [IAM Credential Report](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_getting-report.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
