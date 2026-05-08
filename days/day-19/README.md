# Day 19 — Attaching an IAM Policy to an IAM User

> **#100DaysOfCloud | Day 19 of 100**

---

## 📌 The Task

> *Attach the IAM policy `IAMANITA` to the IAM user `IAMANITHA`.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| IAM User | `IAMANITHA` |
| IAM Policy | `IAMANITA` |
| Action | Attach the policy to the user |

> **Note:** IAM is a global service — no `--region` flag required for IAM operations.

---

## 🧠 Core Concepts

### Bringing It All Together — Days 16, 17, 18, 19

This task is the culmination of the IAM series so far:

- **Day 16** — Created an IAM user (`iamuser_jim`)
- **Day 17** — Created an IAM group (`iamgroup_mark`)
- **Day 18** — Created an IAM policy (`iampolicy_kareem`)
- **Day 19** — Attach a policy to a user (connecting identity to permissions)

Without this final step, an IAM user is a shell — they can exist, log in, and authenticate, but they can't do anything in AWS. Attaching a policy is what grants the actual permissions.

### Two Ways to Attach Policies to Users

| Method | Mechanism | Recommended? |
|--------|-----------|-------------|
| **Direct user attachment** | Policy attached directly to the user | ⚠️ Only for one-off exceptions |
| **Via group membership** | User joins a group; group has the policy | ✅ Preferred at scale |

Both are valid. Direct attachment works fine for a single user or a specific exception permission. At scale (10+ users), group-based attachment is far more manageable. Today's task uses direct attachment — straightforward and appropriate for this scope.

### The Policy Attachment Hierarchy

When AWS evaluates a request from a user, it collects permissions from:

```
User: IAMANITHA
├── Direct policy attachments  ← what we're doing today
│   └── IAMANITA policy
├── Group memberships
│   └── Each group's attached policies
└── Permission boundaries (if set)
```

All of these are combined (unioned) as allows. Any explicit Deny in any of them overrides all allows.

### Managed Policy ARN Format

To attach a **customer managed policy**, you reference it by its full ARN:
```
arn:aws:iam::<ACCOUNT_ID>:policy/IAMANITA
```

To attach an **AWS managed policy**, you reference the AWS account ARN:
```
arn:aws:iam::aws:policy/ReadOnlyAccess
```

The `attach-user-policy` command requires the full ARN — not just the policy name. Always resolve the ARN first if you don't have it memorised.

### Inline vs Managed Policy Attachment

| | Managed Policy Attachment | Inline Policy |
|--|--------------------------|---------------|
| **Reusable** | ✅ Attach to any user/group/role | ❌ Belongs to one entity only |
| **Versioned** | ✅ Up to 5 versions | ❌ No versioning |
| **Audit by ARN** | ✅ Easy to track | ❌ Embedded, harder to audit |
| **Limits** | 10 managed policies per user | 2048 characters per inline policy |
| **Use when** | Standard, reusable permissions | Strict 1:1 entity-permission binding |

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Option A — From the User side:**
1. Navigate to **IAM → Users → IAMANITHA**
2. Click the **Permissions** tab
3. Click **Add permissions → Attach policies directly**
4. Search for `IAMANITA` in the policy search box
5. Select the checkbox next to `IAMANITA`
6. Click **Next → Add permissions**
7. **Verify:** The `IAMANITA` policy appears under **Permissions policies** for user `IAMANITHA`

**Option B — From the Policy side:**
1. Navigate to **IAM → Policies**
2. Search for and click `IAMANITA`
3. Click the **Entities attached** tab
4. Click **Attach** → select **Users** → select `IAMANITHA`
5. Click **Attach policy**

---

### Method 2 — AWS CLI

```bash
# ============================================================
# Step 1: Confirm the user exists
# ============================================================
aws iam get-user --user-name IAMANITHA \
    --query "User.{Username:UserName,UserID:UserId,ARN:Arn,Created:CreateDate}" \
    --output table

# ============================================================
# Step 2: Find the policy ARN for IAMANITA
# ============================================================

# Search customer managed policies
POLICY_ARN=$(aws iam list-policies \
    --scope Local \
    --query "Policies[?PolicyName=='IAMANITA'].Arn" \
    --output text)

# If not found in customer managed, check AWS managed policies
if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" == "None" ]; then
    POLICY_ARN=$(aws iam list-policies \
        --scope AWS \
        --query "Policies[?PolicyName=='IAMANITA'].Arn" \
        --output text)
fi

echo "Policy ARN: $POLICY_ARN"

# ============================================================
# Step 3: Check current policies attached to the user (before)
# ============================================================
echo "=== Policies on IAMANITHA (before) ==="
aws iam list-attached-user-policies \
    --user-name IAMANITHA \
    --query "AttachedPolicies[*].{PolicyName:PolicyName,ARN:PolicyArn}" \
    --output table

# ============================================================
# Step 4: Attach the policy to the user
# ============================================================
aws iam attach-user-policy \
    --user-name IAMANITHA \
    --policy-arn "$POLICY_ARN"

echo "Policy IAMANITA attached to user IAMANITHA"

# ============================================================
# Step 5: Verify the attachment
# ============================================================
echo "=== Policies on IAMANITHA (after) ==="
aws iam list-attached-user-policies \
    --user-name IAMANITHA \
    --query "AttachedPolicies[*].{PolicyName:PolicyName,ARN:PolicyArn}" \
    --output table

# ============================================================
# Step 6: Confirm from the policy side — who is it attached to?
# ============================================================
echo "=== Entities using IAMANITA policy ==="
aws iam list-entities-for-policy \
    --policy-arn "$POLICY_ARN" \
    --query "{Users:PolicyUsers[*].UserName,Groups:PolicyGroups[*].GroupName,Roles:PolicyRoles[*].RoleName}" \
    --output table
```

---

### Verify Using the IAM Policy Simulator

```bash
# Simulate what IAMANITHA can actually do with this policy attached
aws iam simulate-principal-policy \
    --policy-source-arn "arn:aws:iam::<ACCOUNT_ID>:user/IAMANITHA" \
    --action-names ec2:DescribeInstances ec2:TerminateInstances \
    --resource-arns "*" \
    --query "EvaluationResults[*].{Action:EvalActionName,Decision:EvalDecision}" \
    --output table
```

---

### Detaching the Policy (If Needed)

```bash
aws iam detach-user-policy \
    --user-name IAMANITHA \
    --policy-arn "$POLICY_ARN"

echo "Policy detached"

# Confirm it's gone
aws iam list-attached-user-policies --user-name IAMANITHA
```

---

### Attaching Multiple Policies at Once

```bash
# Attach several policies to one user in a loop
POLICIES=(
    "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
    "arn:aws:iam::<ACCOUNT_ID>:policy/IAMANITA"
)

for policy in "${POLICIES[@]}"; do
    aws iam attach-user-policy \
        --user-name IAMANITHA \
        --policy-arn "$policy"
    echo "Attached: $policy"
done

# Verify all
aws iam list-attached-user-policies --user-name IAMANITHA --output table
```

---

## 💻 Commands Reference

```bash
# --- FIND POLICY ARN ---
aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='IAMANITA'].Arn" --output text

# --- CHECK USER EXISTS ---
aws iam get-user --user-name IAMANITHA

# --- LIST CURRENT POLICIES ON USER ---
aws iam list-attached-user-policies \
    --user-name IAMANITHA --output table

# --- ATTACH POLICY ---
aws iam attach-user-policy \
    --user-name IAMANITHA \
    --policy-arn <POLICY_ARN>

# --- VERIFY ATTACHMENT ---
aws iam list-attached-user-policies \
    --user-name IAMANITHA \
    --query "AttachedPolicies[*].{Name:PolicyName,ARN:PolicyArn}" \
    --output table

# --- WHO IS USING THE POLICY ---
aws iam list-entities-for-policy \
    --policy-arn <POLICY_ARN> --output table

# --- SIMULATE EFFECTIVE PERMISSIONS ---
aws iam simulate-principal-policy \
    --policy-source-arn arn:aws:iam::<ACCOUNT_ID>:user/IAMANITHA \
    --action-names ec2:DescribeInstances ec2:TerminateInstances \
    --resource-arns "*" --output table

# --- DETACH POLICY ---
aws iam detach-user-policy \
    --user-name IAMANITHA \
    --policy-arn <POLICY_ARN>
```

---

## ⚠️ Common Mistakes

**1. Attaching by policy name instead of ARN**
`attach-user-policy` requires the full **ARN**, not the policy name. Using just `IAMANITA` will fail with a parameter validation error. Always resolve the ARN first via `list-policies --query "Policies[?PolicyName=='IAMANITA'].Arn"`.

**2. Hitting the managed policy attachment limit**
A single IAM user, group, or role can have a maximum of **10 managed policies** attached directly. If you're approaching this limit, it's usually a signal that the permission model needs restructuring — use groups, merge policies, or reconsider whether all those permissions should belong to a single identity.

**3. Attaching policies directly to users when a group structure already exists**
If `IAMANITHA` already belongs to a group, consider whether the new policy should be attached to the group (so all group members benefit) rather than just to the individual user. Direct user attachments create permission asymmetry within a group that's hard to audit later.

**4. Not verifying the attachment from both sides**
After attaching, confirm from both the user side (`list-attached-user-policies`) and the policy side (`list-entities-for-policy`). Both should reflect the attachment. If only one side shows it, there may have been an eventual consistency issue — re-run the verification after a few seconds.

**5. Confusing `attach-user-policy` with `put-user-policy`**
`attach-user-policy` attaches a **managed policy** (by ARN). `put-user-policy` creates or updates an **inline policy** (embedded JSON). They're completely different operations. If you want to attach a pre-existing policy to a user, always use `attach-user-policy`.

---

## 🌍 Real-World Context

Attaching a policy to a user is the final step that activates an IAM identity — it's what converts a dormant user record into a functional identity with actual cloud access. In production, this operation is almost always performed through infrastructure as code:

**In Terraform:**
```hcl
resource "aws_iam_user_policy_attachment" "anitha" {
  user       = aws_iam_user.anitha.name
  policy_arn = aws_iam_policy.anita.arn
}
```

**In the access request workflow:**
1. Developer submits an access request (via Jira, ServiceNow, or a custom tool)
2. Manager and security team approve
3. Automation creates or updates the IAM attachment (via Terraform PR or an approval Lambda)
4. CloudTrail logs the `AttachUserPolicy` event with requester, approver, and timestamp

This workflow ensures every policy attachment is documented, reviewed, and auditable. Ad-hoc CLI `attach-user-policy` calls in production are a governance red flag — they bypass the review process and create undocumented permission changes.

**The access review cycle:**
Permissions granted today should be reviewed periodically — quarterly is a common cadence. IAM **Access Advisor** shows the last time each service was actually accessed by a user. If `IAMANITHA` has the `IAMANITA` policy attached but hasn't made a single EC2 API call in 90 days, that's a right-sizing candidate — remove the policy, and re-grant if genuinely needed.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is the difference between `attach-user-policy` and `put-user-policy`? When would you use each?**

> `attach-user-policy` attaches a pre-existing **managed policy** (AWS managed or customer managed) to a user — you reference it by its ARN. The policy is independent, reusable, versioned, and can be attached to multiple entities. `put-user-policy` creates or replaces an **inline policy** embedded directly into the user — the policy JSON is provided in the call, lives inside the user record, can't be shared with other users, and is deleted when the user is deleted. Use `attach-user-policy` as the default — managed policies are auditable, reusable, and maintainable. Use `put-user-policy` only for one-off, entity-specific permissions that should never be shared and should logically live and die with the user.

---

**Q2. A user has three policies attached — two from groups and one directly. One group policy allows `s3:DeleteObject`, another group policy denies it, and the direct policy allows it. What is the effective permission for `s3:DeleteObject`?**

> The result is a **Deny**. IAM evaluation logic: all policies are collected and evaluated together — group memberships, direct attachments, and any permission boundaries. The union of allows is computed first, but any explicit Deny in any policy takes precedence over all allows. Since one group policy has an explicit `"Effect": "Deny"` on `s3:DeleteObject`, the action is denied regardless of the two allows from the other group and the direct policy. This is why explicit Deny statements are used as guardrails — they're absolute.

---

**Q3. How would you audit which policies are attached to a specific IAM user and verify their effective permissions?**

> Three tools: First, `aws iam list-attached-user-policies` shows directly attached managed policies. Add `list-groups-for-user` and then `list-attached-group-policies` for each group to get the full picture. Second, `aws iam list-user-policies` shows any inline policies. Third — and most powerful — `aws iam simulate-principal-policy` takes the user's ARN and a list of actions and resources, evaluates all applicable policies, and tells you exactly `allowed`, `implicitDeny`, or `explicitDeny` for each action. In the console, the **Access Advisor** tab on the user shows which services were actually accessed in the last 90 days, which is the data-driven way to right-size permissions.

---

**Q4. You need to give 30 developers the same set of permissions. Should you attach the policy to each user individually or create a group?**

> Create a group, attach the policy to the group, then add all 30 users to the group. Direct user attachment at that scale creates maintenance problems: adding a new permission means 30 API calls with 30 chances for inconsistency. Auditing what "developers" can do requires checking 30 individual user records rather than one group. Onboarding a new developer requires remembering which policies to attach. With a group: adding a permission is one operation on the group, onboarding is "add to group," and auditing is "look at the group." The only time direct user attachment makes sense for shared permissions is if you have one user and want a quick, one-off grant — even then, creating a small group for future use is worth the two extra minutes.

---

**Q5. What happens to a user's attached policies when the user is deleted?**

> Policy attachments are removed automatically when the user is deleted — managed policies are detached (the policies themselves continue to exist and remain available for other entities), and inline policies are permanently deleted along with the user record. This is part of why you must follow the cleanup sequence before `delete-user`: explicitly detach managed policies, delete inline policies, remove group memberships, and then delete the user. AWS enforces this — calling `delete-user` on a user with any attached policies or group memberships returns `DeleteConflict`.

---

**Q6. How does attaching a policy to a user differ from attaching one to a role?**

> The attachment mechanism is technically identical — `attach-user-policy` vs `attach-role-policy`, both take an ARN. The functional difference is in how the permissions are used. A user's attached policies apply every time that user authenticates and makes API calls — they're permanent for the duration the policy is attached. A role's attached policies apply only when the role is assumed — the entity (an EC2 instance, a Lambda function, another user) receives temporary STS credentials scoped to those policies for the duration of the session. For human users, attaching policies to roles and having users assume those roles (via IAM Identity Center or `sts:AssumeRole`) is generally preferred over direct user policy attachment — it enables time-limited access, session tagging, and a cleaner audit trail.

---

**Q7. What is `list-entities-for-policy` and when is it useful?**

> `list-entities-for-policy` takes a policy ARN and returns all users, groups, and roles that currently have that policy attached. It answers the question: "who has this permission?" rather than "what permissions does this entity have?" This is invaluable for impact analysis before modifying or deleting a policy — if you're about to update `IAMANITA` to remove certain permissions, you can first check whether 50 users are relying on it before making the change. It's also useful for security audits: "which identities have this broad policy attached?" or "who has AdministratorAccess?" Running it on `arn:aws:iam::aws:policy/AdministratorAccess` immediately shows every user, group, and role with full account access.

---

## 📚 Resources

- [AWS Docs — Attaching IAM Policies](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_manage-attach-detach.html)
- [AWS CLI Reference — attach-user-policy](https://docs.aws.amazon.com/cli/latest/reference/iam/attach-user-policy.html)
- [AWS CLI Reference — list-entities-for-policy](https://docs.aws.amazon.com/cli/latest/reference/iam/list-entities-for-policy.html)
- [IAM Policy Simulator](https://policysim.aws.amazon.com/)
- [IAM Access Advisor](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_access-advisor.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
