# Day 18 — Creating an IAM Policy

> **#100DaysOfCloud | Day 18 of 100**

---

## 📌 The Task

> *Create an IAM policy named `iampolicy_kareem` that allows read-only access to the EC2 console — users must be able to view all instances, AMIs, and snapshots.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Policy name | `iampolicy_kareem` |
| Permissions | EC2 read-only: view instances, AMIs, snapshots |
| Region | `us-east-1` (IAM is global) |

---

## 🧠 Core Concepts

### What Is an IAM Policy?

An **IAM Policy** is a JSON document that defines permissions — which **actions** are **allowed** or **denied** on which **resources**, optionally under certain **conditions**. Policies are the fundamental mechanism through which IAM controls what any identity (user, group, role) can do in AWS.

A policy answers three questions:
- **What actions?** (`ec2:DescribeInstances`, `s3:GetObject`, `iam:*`, etc.)
- **On which resources?** (`*` for all, or specific ARNs)
- **Under what conditions?** (optional — MFA required, specific IP, time of day, etc.)

### Policy Types

| Type | Description | Stored |
|------|-------------|--------|
| **AWS Managed** | Pre-built by AWS, regularly updated (e.g., `ReadOnlyAccess`, `AdministratorAccess`) | AWS account |
| **Customer Managed** | Created by you, reusable across identities, versioned | Your account |
| **Inline** | Embedded directly into a single user/group/role, not independently versioned | Attached entity |

For this task, we're creating a **customer managed policy** — a standalone policy resource with its own ARN that can be attached to users, groups, and roles.

### IAM Policy Structure — JSON Anatomy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "HumanReadableStatementID",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeImages"
      ],
      "Resource": "*"
    }
  ]
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `Version` | Yes | Policy language version — always `"2012-10-17"` |
| `Statement` | Yes | Array of one or more permission statements |
| `Sid` | No | Optional statement ID for human readability |
| `Effect` | Yes | `"Allow"` or `"Deny"` |
| `Action` | Yes | API actions the statement applies to |
| `Resource` | Yes | ARN(s) the actions apply to (`"*"` means all) |
| `Condition` | No | Optional constraints (MFA, IP, time, tags, etc.) |

### EC2 Actions for This Policy

The task requires read-only access to view instances, AMIs, and snapshots in the EC2 console. The relevant `Describe*` actions are:

| Action | What It Allows |
|--------|---------------|
| `ec2:DescribeInstances` | View instance list and details |
| `ec2:DescribeInstanceStatus` | View instance status checks |
| `ec2:DescribeImages` | View AMI list (including private AMIs) |
| `ec2:DescribeSnapshots` | View EBS snapshots |
| `ec2:DescribeVolumes` | View EBS volumes |
| `ec2:DescribeSecurityGroups` | View security groups |
| `ec2:DescribeKeyPairs` | View key pairs |
| `ec2:DescribeTags` | View resource tags |
| `ec2:DescribeRegions` | View available regions |
| `ec2:DescribeAvailabilityZones` | View AZs |

For a complete EC2 console read-only experience, a broader `ec2:Describe*` wildcard is appropriate — this covers everything a user would see when browsing the EC2 console without the ability to make any changes.

### The AWS Managed Alternative

AWS provides a managed policy called `AmazonEC2ReadOnlyAccess` that grants `ec2:Describe*` and `elasticloadbalancing:Describe*`. For production use, attaching this managed policy is often sufficient and preferred over a custom policy — AWS maintains and updates it. The custom policy in this task gives you precise control and demonstrates the policy authoring workflow.

### Policy Versioning

Customer managed policies support **versioning** — up to 5 versions can be stored simultaneously. When you update a policy, the old version is retained and the new version becomes the default. You can roll back to any stored version. This makes policy changes safe and auditable.

---

## 🔧 Step-by-Step Solution

### The Policy Document

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2ConsoleReadOnly",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
```

Using `ec2:Describe*` as a wildcard covers all Describe actions — instances, AMIs, snapshots, volumes, security groups, key pairs, and every other viewable EC2 resource. This is the standard approach for EC2 console read-only access.

---

### Method 1 — AWS Management Console

1. Navigate to **IAM → Policies → Create policy**
2. Click the **JSON** tab
3. Paste the policy document above
4. Click **Next**
5. **Policy name:** `iampolicy_kareem`
6. **Description:** `Read-only access to EC2 console — view instances, AMIs, and snapshots`
7. Click **Create policy**
8. **Verify:** Search for `iampolicy_kareem` in the policies list — confirm it appears with type `Customer managed`

---

### Method 2 — AWS CLI

```bash
# ============================================================
# Step 1: Create the policy document file
# ============================================================
cat > /tmp/ec2-readonly-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2ConsoleReadOnly",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
EOF

echo "Policy document created"
cat /tmp/ec2-readonly-policy.json

# ============================================================
# Step 2: Create the IAM policy
# ============================================================
POLICY_ARN=$(aws iam create-policy \
    --policy-name iampolicy_kareem \
    --description "Read-only access to EC2 console — view instances, AMIs, and snapshots" \
    --policy-document file:///tmp/ec2-readonly-policy.json \
    --tags Key=Name,Value=iampolicy_kareem Key=Purpose,Value=EC2ReadOnly \
    --query "Policy.Arn" \
    --output text)

echo "Policy created — ARN: $POLICY_ARN"

# ============================================================
# Step 3: Verify the policy
# ============================================================
echo "=== Policy Details ==="
aws iam get-policy --policy-arn "$POLICY_ARN"

# Retrieve the policy document (default version)
echo "=== Policy Document ==="
VERSION=$(aws iam get-policy \
    --policy-arn "$POLICY_ARN" \
    --query "Policy.DefaultVersionId" \
    --output text)

aws iam get-policy-version \
    --policy-arn "$POLICY_ARN" \
    --version-id "$VERSION" \
    --query "PolicyVersion.Document"

# List all customer managed policies in the account
echo "=== All Customer Managed Policies ==="
aws iam list-policies \
    --scope Local \
    --query "Policies[*].{Name:PolicyName,ARN:Arn,Created:CreateDate,AttachCount:AttachmentCount}" \
    --output table
```

---

### Attaching the Policy to an IAM User

```bash
# Attach to a user
aws iam attach-user-policy \
    --user-name iamuser_jim \
    --policy-arn "$POLICY_ARN"

# Verify attachment
aws iam list-attached-user-policies \
    --user-name iamuser_jim \
    --query "AttachedPolicies[*].{PolicyName:PolicyName,ARN:PolicyArn}" \
    --output table
```

---

### Attaching the Policy to an IAM Group

```bash
# Attach to a group (preferred over individual user attachment)
aws iam attach-group-policy \
    --group-name iamgroup_mark \
    --policy-arn "$POLICY_ARN"

# Verify
aws iam list-attached-group-policies \
    --group-name iamgroup_mark \
    --output table
```

---

### Updating the Policy (Creating a New Version)

```bash
# Create a more granular v2 — explicit actions instead of wildcard
cat > /tmp/ec2-readonly-policy-v2.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2ViewInstances",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeInstanceTypes"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2ViewAMIs",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeImages",
        "ec2:DescribeImageAttribute"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2ViewSnapshots",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeSnapshots",
        "ec2:DescribeSnapshotAttribute"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# Create a new version and set it as default
aws iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document file:///tmp/ec2-readonly-policy-v2.json \
    --set-as-default

# List all versions
aws iam list-policy-versions --policy-arn "$POLICY_ARN"
```

---

### Deleting the Policy (Full Cleanup)

```bash
# 1. Detach from all entities first
# List all entities using the policy
aws iam list-entities-for-policy --policy-arn "$POLICY_ARN"

# Detach from users
aws iam detach-user-policy \
    --user-name iamuser_jim \
    --policy-arn "$POLICY_ARN"

# Detach from groups
aws iam detach-group-policy \
    --group-name iamgroup_mark \
    --policy-arn "$POLICY_ARN"

# 2. Delete non-default policy versions (max 5 versions)
for version in $(aws iam list-policy-versions \
    --policy-arn "$POLICY_ARN" \
    --query "Versions[?IsDefaultVersion==\`false\`].VersionId" \
    --output text); do
    aws iam delete-policy-version \
        --policy-arn "$POLICY_ARN" \
        --version-id "$version"
    echo "Deleted version: $version"
done

# 3. Delete the policy
aws iam delete-policy --policy-arn "$POLICY_ARN"
echo "Policy deleted"
```

---

## 💻 Commands Reference

```bash
# --- CREATE POLICY DOCUMENT ---
cat > /tmp/policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2ConsoleReadOnly",
      "Effect": "Allow",
      "Action": ["ec2:Describe*"],
      "Resource": "*"
    }
  ]
}
EOF

# --- CREATE POLICY ---
POLICY_ARN=$(aws iam create-policy \
    --policy-name iampolicy_kareem \
    --description "EC2 console read-only: view instances, AMIs, snapshots" \
    --policy-document file:///tmp/policy.json \
    --query "Policy.Arn" --output text)

# --- VERIFY ---
aws iam get-policy --policy-arn "$POLICY_ARN"

# Get policy document
VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" \
    --query "Policy.DefaultVersionId" --output text)
aws iam get-policy-version \
    --policy-arn "$POLICY_ARN" --version-id "$VERSION"

# --- LIST CUSTOMER MANAGED POLICIES ---
aws iam list-policies --scope Local \
    --query "Policies[*].{Name:PolicyName,ARN:Arn,Attachments:AttachmentCount}" \
    --output table

# --- ATTACH TO USER ---
aws iam attach-user-policy \
    --user-name iamuser_jim --policy-arn "$POLICY_ARN"

# --- ATTACH TO GROUP ---
aws iam attach-group-policy \
    --group-name iamgroup_mark --policy-arn "$POLICY_ARN"

# --- WHO IS USING THIS POLICY ---
aws iam list-entities-for-policy --policy-arn "$POLICY_ARN"

# --- SIMULATE POLICY (test before attaching) ---
aws iam simulate-custom-policy \
    --policy-input-list file:///tmp/policy.json \
    --action-names ec2:DescribeInstances ec2:DescribeImages ec2:TerminateInstances \
    --resource-arns "*" \
    --query "EvaluationResults[*].{Action:EvalActionName,Decision:EvalDecision}" \
    --output table

# --- DELETE POLICY ---
aws iam detach-user-policy --user-name iamuser_jim --policy-arn "$POLICY_ARN"
aws iam delete-policy --policy-arn "$POLICY_ARN"
```

---

## ⚠️ Common Mistakes

**1. Using `"*"` for both Action and Resource without understanding what that grants**
`"Action": "*", "Resource": "*"` with `"Effect": "Allow"` is essentially `AdministratorAccess`. Even scoping Action to `"ec2:*"` on `"Resource": "*"` grants full EC2 write access. Always use the minimum actions required — prefer explicit `Describe*` wildcards for read-only, not the full `ec2:*` wildcard.

**2. Forgetting `"Version": "2012-10-17"` in the policy document**
The version field is not the version of your policy — it's the IAM policy language version, and `2012-10-17` is the only valid value in production (the older `2008-10-17` lacks policy variables and other features). Omitting it doesn't necessarily fail but produces a policy evaluated against the older language rules. Always include it.

**3. Confusing `ec2:Describe*` with console read-only for all services**
`ec2:Describe*` only covers EC2 resources. A complete "AWS console read-only" experience typically also needs `elasticloadbalancing:Describe*`, `cloudwatch:Get*`, `cloudwatch:List*`, `cloudwatch:Describe*`, `autoscaling:Describe*`, and others. For the EC2 console specifically, `ec2:Describe*` is the right scope. The AWS managed `AmazonEC2ReadOnlyAccess` policy is a good reference for what's needed.

**4. Not using `simulate-custom-policy` before attaching to production identities**
The IAM Policy Simulator allows you to test a policy document against specific actions and resources before it's attached to anything. Running a quick simulation confirms that `ec2:DescribeInstances` is `allowed` and `ec2:TerminateInstances` is `implicitDeny` — exactly what you want for a read-only policy — without any risk.

**5. Hitting the 5-version limit without cleaning up old versions**
Customer managed policies store up to 5 versions. When you try to create a 6th version, the API returns `LimitExceeded`. Before updating a policy, check how many versions exist. Delete non-default, unused versions before creating new ones if you're near the limit.

**6. Leaving the policy document as a file reference instead of an inline string**
`file://` references work from the CLI but not everywhere. In CI/CD pipelines, Lambda functions running `boto3`, or CloudFormation templates, the policy document needs to be a proper JSON string, not a file path. Always test your policy JSON independently before embedding it in automation.

---

## 🌍 Real-World Context

IAM policy authoring is one of the most important and most error-prone activities in AWS security engineering. A few patterns from real production environments:

**Policy authoring workflow in mature teams:**
1. Draft the policy JSON
2. Run through the IAM Policy Simulator to verify intended allow/deny behaviour
3. Attach to a test user or role in a non-production account
4. Have a second engineer review the policy (four-eyes principle for any policy with broad scope)
5. Commit the policy JSON to version control (alongside Terraform or CloudFormation)
6. Deploy through CI/CD — same code review process as infrastructure changes

**The principle of least privilege in practice:**
Start maximally restrictive and widen permissions only when a specific use case requires it. The worst thing you can do is start with `AdministratorAccess` "temporarily" and never revisit it. AWS IAM **Access Advisor** shows which services a user has actually accessed in the last 90 days — this is the data-driven way to right-size permissions.

**Tag-based access control:**
For more sophisticated policies, resource conditions using tags enable attribute-based access control (ABAC). For example: `"Condition": {"StringEquals": {"ec2:ResourceTag/Environment": "dev"}}` restricts an action to only resources tagged `Environment=dev`. This scales better than ARN-based resource constraints in dynamic environments where resource IDs change frequently.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is an IAM policy and what are the three types? When would you choose each?**

> An IAM policy is a JSON document that defines what actions are allowed or denied on which resources. The three types: **AWS managed policies** are created and maintained by AWS — regularly updated, cover common use cases, and can be attached to any identity in any account. You'd use these for standard permissions like `ReadOnlyAccess`, `AdministratorAccess`, or `AmazonEC2ReadOnlyAccess`. **Customer managed policies** are created by you, stored in your account, versioned, and reusable across multiple identities. Use these for custom permission sets specific to your organisation's needs. **Inline policies** are embedded directly into a single user, group, or role — not independently versioned, not reusable. Use these sparingly for one-off permissions that should strictly belong to a single entity and shouldn't accidentally be attached elsewhere.

---

**Q2. Explain the IAM policy evaluation logic. How does AWS determine whether an API call is allowed or denied?**

> AWS evaluates policies in a specific order. First, if there's an explicit `Deny` anywhere — in any attached policy, SCP, permission boundary, or resource policy — the request is denied. Explicit Denies always win. Second, AWS checks for an explicit `Allow` — from identity-based policies (user, group, role), resource-based policies (S3 bucket policy, SQS policy), or session policies. If an explicit Allow exists and no explicit Deny overrides it, the request is allowed. Third, if there's no explicit Allow anywhere, the default is an **implicit Deny** — the request is denied. The practical implication: to allow access, you need at least one explicit Allow and no explicit Deny. To block access, an explicit Deny in any policy is sufficient regardless of how many Allows exist.

---

**Q3. What is the IAM Policy Simulator and how do you use it?**

> The IAM Policy Simulator is a tool (available in the console at `https://policysim.aws.amazon.com/` and via `aws iam simulate-principal-policy` CLI) that lets you test IAM policies against specific actions and resources without actually performing those actions. You specify an IAM entity (user, group, or role), a list of actions to test, and optionally specific resource ARNs. The simulator evaluates all applicable policies and returns `allowed`, `implicitDeny`, or `explicitDeny` for each action. This is indispensable for: verifying a new policy before attaching it to production identities, debugging why a user can't perform an action, validating that a read-only policy doesn't accidentally allow write operations, and regression-testing policies after updates.

---

**Q4. A policy has `"Effect": "Allow"` with `"Action": "ec2:*"` and another policy attached to the same user has `"Effect": "Deny"` with `"Action": "ec2:TerminateInstances"`. Can the user terminate instances?**

> No. Explicit Deny always wins over Allow, regardless of the source policy or the order of evaluation. Even if ten different policies all explicitly Allow `ec2:TerminateInstances`, a single explicit Deny in any attached policy makes the net result a Deny. This is the fundamental rule of IAM policy evaluation — explicit Deny is the highest-priority decision. This is why you need to be careful with Deny statements: they're absolute and can't be overridden. The intended use case for explicit Denies is as guardrails — a policy that blocks specific dangerous actions regardless of what other policies grant.

---

**Q5. What is the difference between an identity-based policy and a resource-based policy? Give an example of each.**

> An **identity-based policy** is attached to an IAM identity (user, group, or role) and defines what that identity can do. Example: an IAM policy attached to a role that allows `s3:GetObject` on a specific bucket — any user who assumes that role can get objects from the bucket. A **resource-based policy** is attached to an AWS resource and defines who can access it. Example: an S3 bucket policy that allows a specific IAM role from another AWS account to `s3:PutObject` — it's attached to the bucket itself and controls access to the bucket from any principal, including cross-account ones. For cross-account access, resource-based policies are often necessary because you need both the identity's policy to allow the action AND the resource policy to allow the principal. For same-account access, either type alone is sufficient.

---

**Q6. What is a permission boundary in IAM and when would you use it?**

> A **permission boundary** is an IAM managed policy that sets the maximum permissions an identity can have — it acts as a ceiling. Even if an identity has `AdministratorAccess` attached, if its permission boundary only allows `ec2:Describe*`, the effective permissions are just EC2 read-only. Boundaries are used in delegation scenarios: a central platform team can create an IAM role that allows developers to create and manage their own IAM roles, but the permission boundary on those developer-created roles ensures they can only grant permissions up to a certain ceiling — preventing privilege escalation. Without permission boundaries, giving developers IAM `create-role` and `attach-policy` permissions would allow them to create a role with `AdministratorAccess` and effectively grant themselves any permissions.

---

**Q7. How would you audit which IAM policies in your account grant `s3:*` or `*` on `*` resources (overly permissive policies)?**

> Use a combination of CLI queries and AWS tools. For customer managed policies:
> ```bash
> # List all customer managed policies and check their documents
> for policy_arn in $(aws iam list-policies --scope Local \
>     --query "Policies[*].Arn" --output text); do
>     version=$(aws iam get-policy --policy-arn "$policy_arn" \
>         --query "Policy.DefaultVersionId" --output text)
>     doc=$(aws iam get-policy-version \
>         --policy-arn "$policy_arn" --version-id "$version" \
>         --query "PolicyVersion.Document" --output json)
>     echo "$policy_arn: $doc"
> done | grep -l '"Action": "\*"'
> ```
> More powerfully: **IAM Access Analyzer** has a policy checker that flags overly permissive policies and generates findings. **AWS Config** has managed rules (`iam-policy-no-statements-with-admin-access`) that continuously monitor for policies granting `*` on `*`. **Security Hub** aggregates these findings with severity ratings. In mature environments, this analysis runs continuously via Config and findings are routed to a security operations queue for review.

---

## 📚 Resources

- [AWS Docs — IAM Policies](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html)
- [AWS CLI Reference — create-policy](https://docs.aws.amazon.com/cli/latest/reference/iam/create-policy.html)
- [IAM Policy Simulator](https://policysim.aws.amazon.com/)
- [IAM Policy Evaluation Logic](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)
- [EC2 Actions Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html)
- [IAM Access Analyzer](https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
