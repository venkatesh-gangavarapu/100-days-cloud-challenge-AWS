# Day 20 — Creating an IAM Role for EC2

> **#100DaysOfCloud | Day 20 of 100**

---

## 📌 The Task

> *Create an IAM role that EC2 instances can assume, with the specified policy attached.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Role name | `iamrole_kirsty` |
| Entity type | AWS Service |
| Use case | EC2 |
| Attach policy | `iampolicy_kirsty` |
| Region | `us-east-1` (IAM is global) |

---

## 🧠 Core Concepts

### What Is an IAM Role?

An **IAM Role** is a temporary identity that can be assumed by an AWS service, an IAM user, a federated identity, or another AWS account. Unlike an IAM user, a role has **no permanent credentials** — when assumed, it issues **short-lived STS (Security Token Service) credentials** that expire automatically (between 15 minutes and 12 hours).

Roles are the correct mechanism for **any machine or service access** in AWS. EC2 instances, Lambda functions, ECS tasks, and CodeBuild jobs should all use roles — never hardcoded access keys.

### Why Roles for EC2?

Before IAM roles existed, developers would SSH into EC2 instances and manually configure `~/.aws/credentials` with access keys. The problems:
- Keys were hardcoded in config files or environment variables
- When keys expired or were rotated, you had to update every instance manually
- Compromised keys meant permanent account access until manually revoked
- No audit trail of which instance used which key

With an IAM Instance Profile (an EC2-attached role), the instance automatically receives rotating temporary credentials via the **Instance Metadata Service (IMDS)** at `http://169.254.169.254/latest/meta-data/iam/security-credentials/<role-name>`. The AWS SDKs pick these up automatically — no configuration required. When the credentials expire, the SDK fetches fresh ones from IMDS transparently.

### IAM Role Anatomy — Three Required Components

Creating an IAM role requires three distinct pieces:

| Component | What It Does | Where It Comes From |
|-----------|-------------|---------------------|
| **Trust Policy** | Defines who/what can assume the role (the `Principal`) | Written as JSON, set at creation |
| **Permission Policy** | Defines what the role can do once assumed | Attached managed or inline policy |
| **Role Name/ARN** | The identity reference used in resource policies and SDK calls | Assigned at creation |

The **trust policy** is what makes a role usable by EC2. It's a resource-based policy that says: *"I trust the EC2 service to assume this role."*

### The Trust Policy for EC2

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

This tells IAM: "The EC2 service (`ec2.amazonaws.com`) is allowed to call `sts:AssumeRole` on this role." When an EC2 instance launches with this role attached (via an Instance Profile), it uses this trust policy to retrieve credentials.

### IAM Role vs IAM User — The Full Picture

| | IAM User | IAM Role |
|--|---------|---------|
| **Credentials** | Long-term (password, access keys) | Temporary (STS, auto-expire) |
| **Identity type** | Human users, legacy apps | Services, cross-account, federation |
| **Used by EC2** | ❌ (requires hardcoding keys) | ✅ (Instance Profile) |
| **Credential rotation** | Manual | Automatic |
| **Audit trail** | Per user | Per session (role + session name) |
| **Best practice** | Humans via SSO | All service/machine access |

### Instance Profile — The EC2-Specific Wrapper

IAM roles are not attached to EC2 instances directly. There is an intermediate resource called an **Instance Profile** that wraps the role. When you create a role for EC2 in the console, AWS automatically creates the Instance Profile for you. In the CLI, you must create it separately and then add the role to it.

```
EC2 Instance
    └── Instance Profile (container)
            └── IAM Role (iamrole_kirsty)
                    └── Permission Policy (iampolicy_kirsty)
```

### The STS Credential Flow

```
1. EC2 instance launches with Instance Profile attached
2. Instance calls IMDS: GET http://169.254.169.254/latest/meta-data/iam/security-credentials/iamrole_kirsty
3. IMDS returns: AccessKeyId, SecretAccessKey, Token, Expiration
4. AWS SDK uses these credentials automatically for all API calls
5. ~15 minutes before expiration, SDK fetches fresh credentials from IMDS
6. Cycle repeats — no manual rotation, no stored secrets
```

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Navigate to **IAM → Roles → Create role**
2. **Select trusted entity:**
   - Entity type: `AWS service`
   - Use case: `EC2`
   - Click **Next**
3. **Add permissions:**
   - Search for `iampolicy_kirsty`
   - Select the checkbox next to it
   - Click **Next**
4. **Name, review, and create:**
   - **Role name:** `iamrole_kirsty`
   - **Description:** `EC2 role with iampolicy_kirsty for kirsty workloads`
   - Review the trust policy and permissions
   - Click **Create role**
5. **Verify:**
   - Navigate to **IAM → Roles → iamrole_kirsty**
   - Confirm **Trust relationships** shows `ec2.amazonaws.com`
   - Confirm **Permissions** tab shows `iampolicy_kirsty` attached

---

### Method 2 — AWS CLI

```bash
# ============================================================
# Step 1: Create the trust policy document
# ============================================================
cat > /tmp/ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

echo "Trust policy document:"
cat /tmp/ec2-trust-policy.json

# ============================================================
# Step 2: Create the IAM role
# ============================================================
aws iam create-role \
    --role-name iamrole_kirsty \
    --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
    --description "EC2 role for kirsty workloads with iampolicy_kirsty" \
    --tags Key=Name,Value=iamrole_kirsty Key=UseCase,Value=EC2

echo "Role created"

# ============================================================
# Step 3: Resolve the policy ARN for iampolicy_kirsty
# ============================================================
POLICY_ARN=$(aws iam list-policies \
    --scope Local \
    --query "Policies[?PolicyName=='iampolicy_kirsty'].Arn" \
    --output text)

# Fallback to AWS managed if not found in customer managed
if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" == "None" ]; then
    POLICY_ARN=$(aws iam list-policies \
        --scope AWS \
        --query "Policies[?PolicyName=='iampolicy_kirsty'].Arn" \
        --output text)
fi

echo "Policy ARN: $POLICY_ARN"

# ============================================================
# Step 4: Attach the policy to the role
# ============================================================
aws iam attach-role-policy \
    --role-name iamrole_kirsty \
    --policy-arn "$POLICY_ARN"

echo "Policy iampolicy_kirsty attached to iamrole_kirsty"

# ============================================================
# Step 5: Create an Instance Profile and add the role to it
# (Required to attach the role to EC2 instances)
# ============================================================
aws iam create-instance-profile \
    --instance-profile-name iamrole_kirsty

aws iam add-role-to-instance-profile \
    --instance-profile-name iamrole_kirsty \
    --role-name iamrole_kirsty

echo "Instance Profile created and role added"

# ============================================================
# Step 6: Verify everything is correctly configured
# ============================================================
echo "=== Role Details ==="
aws iam get-role \
    --role-name iamrole_kirsty \
    --query "Role.{Name:RoleName,ARN:Arn,Created:CreateDate,Description:Description}" \
    --output table

echo "=== Trust Policy ==="
aws iam get-role \
    --role-name iamrole_kirsty \
    --query "Role.AssumeRolePolicyDocument"

echo "=== Attached Policies ==="
aws iam list-attached-role-policies \
    --role-name iamrole_kirsty \
    --query "AttachedPolicies[*].{PolicyName:PolicyName,ARN:PolicyArn}" \
    --output table

echo "=== Instance Profile ==="
aws iam get-instance-profile \
    --instance-profile-name iamrole_kirsty \
    --query "InstanceProfile.{Name:InstanceProfileName,ARN:Arn,Roles:Roles[*].RoleName}" \
    --output table
```

---

### Attaching the Role to an EC2 Instance at Launch

```bash
# Get the instance profile ARN
PROFILE_ARN=$(aws iam get-instance-profile \
    --instance-profile-name iamrole_kirsty \
    --query "InstanceProfile.Arn" \
    --output text)

# Launch an EC2 instance with the role attached
aws ec2 run-instances \
    --image-id <AMI_ID> \
    --instance-type t2.micro \
    --key-name your-key \
    --iam-instance-profile Arn="$PROFILE_ARN" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=kirsty-instance}]' \
    --count 1
```

---

### Attaching the Role to a Running EC2 Instance

```bash
# Associate the instance profile with a running instance
aws ec2 associate-iam-instance-profile \
    --instance-id <INSTANCE_ID> \
    --iam-instance-profile Name=iamrole_kirsty

# Verify the association
aws ec2 describe-iam-instance-profile-associations \
    --filters "Name=instance-id,Values=<INSTANCE_ID>" \
    --output table
```

---

### Verifying Credentials From Inside an EC2 Instance

```bash
# From within the EC2 instance (after SSH):

# Check that the role is active
curl http://169.254.169.254/latest/meta-data/iam/info

# Get the temporary credentials
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/iamrole_kirsty

# The AWS CLI inside the instance will use these automatically
aws sts get-caller-identity
# Output: the ARN will show arn:aws:sts::<account>:assumed-role/iamrole_kirsty/<instance-id>
```

---

### Deleting the Role (Full Cleanup)

```bash
# Order matters — cannot delete role if it has policies attached or is in an instance profile

# 1. Remove role from instance profile
aws iam remove-role-from-instance-profile \
    --instance-profile-name iamrole_kirsty \
    --role-name iamrole_kirsty

# 2. Delete the instance profile
aws iam delete-instance-profile \
    --instance-profile-name iamrole_kirsty

# 3. Detach all managed policies
for policy in $(aws iam list-attached-role-policies \
    --role-name iamrole_kirsty \
    --query "AttachedPolicies[*].PolicyArn" --output text); do
    aws iam detach-role-policy \
        --role-name iamrole_kirsty --policy-arn "$policy"
done

# 4. Delete any inline policies
for policy in $(aws iam list-role-policies \
    --role-name iamrole_kirsty \
    --query "PolicyNames[*]" --output text); do
    aws iam delete-role-policy \
        --role-name iamrole_kirsty --policy-name "$policy"
done

# 5. Delete the role
aws iam delete-role --role-name iamrole_kirsty
echo "Role deleted"
```

---

## 💻 Commands Reference

```bash
# --- CREATE TRUST POLICY ---
cat > /tmp/trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

# --- CREATE ROLE ---
aws iam create-role \
    --role-name iamrole_kirsty \
    --assume-role-policy-document file:///tmp/trust.json

# --- ATTACH POLICY ---
aws iam attach-role-policy \
    --role-name iamrole_kirsty \
    --policy-arn <POLICY_ARN>

# --- CREATE INSTANCE PROFILE (CLI only) ---
aws iam create-instance-profile \
    --instance-profile-name iamrole_kirsty

aws iam add-role-to-instance-profile \
    --instance-profile-name iamrole_kirsty \
    --role-name iamrole_kirsty

# --- VERIFY ROLE ---
aws iam get-role --role-name iamrole_kirsty
aws iam list-attached-role-policies --role-name iamrole_kirsty

# --- VERIFY INSTANCE PROFILE ---
aws iam get-instance-profile --instance-profile-name iamrole_kirsty

# --- ATTACH TO RUNNING EC2 ---
aws ec2 associate-iam-instance-profile \
    --instance-id <INSTANCE_ID> \
    --iam-instance-profile Name=iamrole_kirsty

# --- VERIFY FROM INSIDE INSTANCE ---
# curl http://169.254.169.254/latest/meta-data/iam/security-credentials/iamrole_kirsty
# aws sts get-caller-identity

# --- DELETE (strict cleanup order) ---
aws iam remove-role-from-instance-profile \
    --instance-profile-name iamrole_kirsty --role-name iamrole_kirsty
aws iam delete-instance-profile --instance-profile-name iamrole_kirsty
aws iam detach-role-policy --role-name iamrole_kirsty --policy-arn <POLICY_ARN>
aws iam delete-role --role-name iamrole_kirsty
```

---

## ⚠️ Common Mistakes

**1. Forgetting to create the Instance Profile when using the CLI**
When you create an EC2 role in the console, AWS silently creates an Instance Profile with the same name. In the CLI, you must explicitly create the Instance Profile and add the role to it. Skipping this means the role exists in IAM but cannot be attached to any EC2 instance — the `--iam-instance-profile` parameter at launch will fail with `InvalidParameterValue`.

**2. Confusing the trust policy with the permission policy**
The **trust policy** (also called the assume-role policy document) controls *who can assume* the role. The **permission policy** controls *what the role can do once assumed*. A common mistake is putting EC2 permissions in the trust policy, or using a service principal in the permission policy. They are entirely separate documents answering different questions.

**3. Using `ec2.amazonaws.com` instead of the regional endpoint for cross-region scenarios**
For standard EC2 roles, `ec2.amazonaws.com` as the Principal service is correct and works globally. Some newer services require the regional endpoint (e.g., `ec2.us-east-1.amazonaws.com`) but this is not needed for standard EC2 instance profiles.

**4. Trying to attach the role directly to an EC2 instance without an Instance Profile**
You cannot attach an IAM role directly to an EC2 instance — it must go through an Instance Profile. The Instance Profile is the container that EC2 uses to pass credentials to the instance. One Instance Profile can contain only one role. One role can be in multiple Instance Profiles.

**5. Not updating the trust policy when changing use cases**
If you create a role for EC2 and later want to use it for Lambda, you need to update the trust policy to include `lambda.amazonaws.com` as a trusted service. A role's trust policy can allow multiple services simultaneously. But forgetting to update it means the new service can't assume the role, resulting in `AccessDenied` on `sts:AssumeRole`.

**6. Granting `sts:AssumeRole` too broadly in the trust policy**
Setting `"Principal": "*"` in a trust policy means *anyone* can assume the role — any AWS account, any service, any user globally. This is a severe security misconfiguration. Always be explicit about which service (`ec2.amazonaws.com`), which account (`"AWS": "arn:aws:iam::123456789:root"`), or which specific role can assume this role.

---

## 🌍 Real-World Context

IAM roles for EC2 are the foundation of secure application-to-AWS authentication. Every production AWS environment uses this pattern — the days of access keys on EC2 instances are firmly behind us.

**The Instance Profile in Auto Scaling:**
When you configure an Auto Scaling Group with a Launch Template that includes an Instance Profile, every instance the ASG launches automatically has the role attached. All your application instances inherit the same role-based credentials without any per-instance configuration. Scale to 1000 instances — every one of them authenticates securely through the same role, with credentials that auto-rotate.

**Least privilege for EC2 roles:**
A role attached to an EC2 web server shouldn't have `s3:*` — it should have `s3:GetObject` on the specific bucket it needs to read. IAM Access Analyzer generates least-privilege policy suggestions based on actual CloudTrail activity — it reads what API calls the instance has actually made and generates a tighter policy from that data. Start broad for development, then tighten using Access Analyzer findings before production.

**Cross-service role chaining:**
An EC2 instance's role can have `sts:AssumeRole` permission allowing it to assume a second role — in the same account or a different account. This is role chaining, used for cross-account access where the EC2 instance in Account A needs to access resources in Account B. The Account B resource or trust policy allows the Account A role to assume a cross-account role.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is an IAM role and how is it fundamentally different from an IAM user?**

> An IAM role is a temporary identity — when assumed by a service or entity, it issues short-lived STS credentials (AccessKeyId, SecretAccessKey, and a SessionToken) that expire automatically between 15 minutes and 12 hours. No permanent credentials exist that could be leaked or left unrotated. An IAM user has long-term credentials — a password and/or access keys that persist until manually rotated or deleted. For EC2 instances, Lambda functions, and all machine access, roles are the correct approach. The application running on an EC2 instance gets credentials automatically from the Instance Metadata Service and the SDK rotates them transparently — no access key management, no risk of credentials persisting after the instance is gone.

---

**Q2. What is the difference between the trust policy and the permissions policy on an IAM role?**

> They answer entirely different questions. The **trust policy** (the assume-role policy document) defines *who can assume this role* — it's a resource-based policy on the role itself that specifies trusted principals: a service (`ec2.amazonaws.com`), an IAM user ARN, another role ARN, or an AWS account. Without a trust relationship, no one can use the role. The **permissions policy** defines *what the role can do once it's assumed* — these are the standard IAM policy statements granting actions on resources. A role with a trust policy allowing EC2 but with no permissions policy attached would successfully issue credentials to EC2 instances, but those credentials couldn't do anything. Both pieces must be correct for the role to work as intended.

---

**Q3. What is an EC2 Instance Profile and how does it relate to an IAM role?**

> An Instance Profile is an EC2-specific container that wraps an IAM role. EC2 doesn't attach IAM roles directly — it attaches Instance Profiles, and Instance Profiles contain roles. In the AWS console, creating an EC2 role automatically creates an Instance Profile with the same name. In the CLI and Terraform, you must create the Instance Profile explicitly (`aws iam create-instance-profile`) and add the role to it (`aws iam add-role-to-instance-profile`). One Instance Profile can only contain one role. When the instance launches, it exchanges the Instance Profile for short-lived STS credentials available at the IMDS endpoint. The distinction matters in CLI automation and Terraform — forgetting to create the Instance Profile is one of the most common EC2 role setup mistakes.

---

**Q4. An EC2 instance needs to read from an S3 bucket in the same account. Walk me through the complete IAM setup from scratch.**

> Create a customer managed policy with `s3:GetObject` and `s3:ListBucket` on the specific bucket ARN. Create an IAM role with a trust policy allowing `ec2.amazonaws.com` to assume it, then attach the policy to the role. Create an Instance Profile with the same name and add the role to it. Launch the EC2 instance with `--iam-instance-profile Name=<profile-name>`, or associate the profile to a running instance with `associate-iam-instance-profile`. Inside the instance, the AWS SDK will automatically find and use the credentials from IMDS — no `aws configure`, no access keys anywhere. Verify by running `aws sts get-caller-identity` inside the instance and confirming the ARN shows the assumed-role identity.

---

**Q5. How does `sts:AssumeRole` work and what are its components?**

> When an entity (service, user, or role) calls `sts:AssumeRole`, AWS performs a two-factor check: first, does the caller's permissions policy allow them to call `sts:AssumeRole` on the target role's ARN? Second, does the target role's trust policy allow the caller's principal? If both checks pass, STS returns temporary credentials — an AccessKeyId, SecretAccessKey, SessionToken, and expiration timestamp. The calling entity then uses those temporary credentials for subsequent API calls. The issued credentials have the permissions defined by the assumed role's permission policies, limited by any session policies passed in the `AssumeRole` call. This two-factor check (permission + trust) is why cross-account access requires changes in both accounts.

---

**Q6. What is the maximum session duration for an IAM role, and how do you configure it?**

> The maximum session duration for a role is configurable between 1 hour and 12 hours, set on the role itself with `--max-session-duration` in seconds. The default is 1 hour (3600 seconds). For EC2 instance profiles, the IMDS automatically refreshes credentials before they expire — the maximum duration setting is less critical for long-running instances. It matters more for human users assuming roles via the CLI or console, where you want sessions to last long enough to complete work without constant re-authentication. Setting it very high (12 hours) for roles that should only be used briefly is a security trade-off — if the temporary credentials are compromised, the blast window is longer. Use the minimum duration appropriate for the use case.

---

**Q7. A Lambda function and an EC2 instance need access to the same DynamoDB table. Should they share an IAM role? What's the correct design?**

> No — they should have separate roles, each with its own trust policy. An EC2 role's trust policy trusts `ec2.amazonaws.com`; a Lambda role's trust policy trusts `lambda.amazonaws.com`. You can't attach one role to both services. However, they *can* share the same **permission policy** — create a single customer managed policy granting `dynamodb:GetItem`, `dynamodb:PutItem`, etc. on the table, then attach it to both the EC2 role and the Lambda execution role. This gives you one policy to maintain for the shared permissions, while each service uses its own role with the appropriate trust relationship. If the permissions diverge (EC2 needs additional access Lambda doesn't), you create separate policies — shared permission policies are a convenience, not a requirement.

---

## 📚 Resources

- [AWS Docs — IAM Roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)
- [AWS Docs — EC2 Instance Profiles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html)
- [AWS CLI Reference — create-role](https://docs.aws.amazon.com/cli/latest/reference/iam/create-role.html)
- [AWS STS AssumeRole](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html)
- [IAM Best Practices for EC2](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
