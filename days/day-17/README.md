# Day 17 — Creating an IAM Group

> **#100DaysOfCloud | Day 17 of 100**

---

## 📌 The Task

> *As part of the AWS cloud migration, the Nautilus DevOps team needs IAM groups configured to organise user access.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| IAM group name | `iamgroup_mark` |
| Region | `us-east-1` (IAM is global) |

---

## 🧠 Core Concepts

### What Is an IAM Group?

An **IAM Group** is a collection of IAM users. Groups exist for one reason: **scalable permission management**. Instead of attaching policies to individual users (which becomes unmanageable at any meaningful scale), you attach policies to groups and add users to those groups.

A group is not an identity — it cannot make API calls, assume roles, or be referenced as a principal in a resource policy. It's purely an administrative container for organising policy assignments to users.

Key characteristics:
- A group can contain **multiple users**
- A user can belong to **multiple groups** (up to 10 groups per user)
- Policies attached to a group apply to **all members** of the group
- Groups **cannot be nested** — a group cannot contain another group
- Groups are **global** — not region-specific

### Why Groups Beat Direct Policy Attachment

Consider the difference between these two approaches at scale:

**Without groups (direct attachment):**
```
Developer 1 → PowerUserAccess
Developer 2 → PowerUserAccess
Developer 3 → PowerUserAccess
...
Developer 50 → PowerUserAccess

To add a new permission: 50 individual update operations
To onboard a new developer: remember to attach the right policies
To audit what developers can do: check 50 individual users
```

**With groups:**
```
Group: Developers → PowerUserAccess
  └── Developer 1, 2, 3... 50

To add a new permission: 1 group policy update
To onboard a new developer: add to group
To audit: inspect the group's policies
```

Groups are the first step toward managing permissions at scale without chaos.

### How Permissions Accumulate Through Groups

A user's effective permissions are the **union** of all policies attached to them:
- Policies attached directly to the user
- Policies attached to every group the user belongs to

An explicit `Deny` in any policy always overrides an `Allow` — this is the fundamental IAM evaluation logic. The union of allows happens first, then explicit denies take precedence.

```
User: iamuser_jim
  Direct policies:    ReadOnlyAccess
  Group: Developers:  PowerUserAccess
  Group: S3Admins:    S3 full access

Effective permissions = ReadOnly + PowerUser + S3Full
(minus any explicit denies)
```

### IAM Group vs IAM Role — Important Distinction

A common question: *why not use a role instead of a group?*

| | IAM Group | IAM Role |
|--|-----------|---------|
| **Contains** | IAM users | No members — entities assume it |
| **Credentials** | Users keep their own credentials | Issues temporary STS credentials |
| **Use case** | Organise human users with shared permissions | EC2/Lambda/cross-account access |
| **Can be a policy principal** | ❌ No | ✅ Yes |
| **Nestable** | ❌ No (flat structure) | N/A |

Groups and roles serve complementary purposes. Groups organise static human user permissions. Roles handle dynamic, temporary credential issuance for services and cross-account access.

### Group Naming Conventions in Production

Production IAM groups are typically named by function, team, or permission tier:

| Pattern | Example |
|---------|---------|
| Team-based | `platform-team`, `data-team`, `security-team` |
| Function-based | `developers`, `ops`, `read-only`, `billing-viewers` |
| Environment-scoped | `prod-admins`, `dev-admins` |
| Application-scoped | `app-payments-devs`, `app-auth-ops` |

Clear naming makes permission audits and onboarding significantly easier.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

1. Navigate to **IAM → User groups → Create group**
2. **User group name:** `iamgroup_mark`
3. **Add users:** Skip for now — group can be populated after creation
4. **Attach permissions policies:** Skip for now — policies added post-creation
5. Click **Create user group**
6. **Verify:** Navigate to **IAM → User groups** → confirm `iamgroup_mark` appears

---
[O
### Method 2 — AWS CLI

```bash
# ============================================================
# Step 1: Create the IAM group
# ============================================================
aws iam create-group --group-name iamgroup_mark

# Output:
# {
#   "Group": {
#     "GroupName": "iamgroup_mark",
#     "GroupId": "AGPA...",
#     "Arn": "arn:aws:iam::637423303501:group/iamgroup_mark",
#     "Path": "/",
#     "CreateDate": "2026-05-05T..."
#   }
# }

# ============================================================
# Step 2: Verify the group was created
# ============================================================
aws iam get-group --group-name iamgroup_mark

# List all groups in the account
aws iam list-groups \
    --query "Groups[*].{GroupName:GroupName,GroupId:GroupId,ARN:Arn,Created:CreateDate}" \
    --output table
```

---

### Adding Users to the Group

```bash
# Add an existing IAM user to the group
aws iam add-user-to-group \
    --group-name iamgroup_mark \
    --user-name iamuser_jim

# Add multiple users
for user in iamuser_jim iamuser_alice iamuser_bob; do
    aws iam add-user-to-group \
        --group-name iamgroup_mark \
        --user-name "$user"
    echo "Added $user to iamgroup_mark"
done

# List all users in the group
aws iam get-group \
    --group-name iamgroup_mark \
    --query "{Group:Group.GroupName,Users:Users[*].UserName}" \
    --output table
```

---

### Attaching Policies to the Group

```bash
# Attach an AWS managed policy to the group
aws iam attach-group-policy \
    --group-name iamgroup_mark \
    --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

# Attach multiple policies
aws iam attach-group-policy \
    --group-name iamgroup_mark \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess

aws iam attach-group-policy \
    --group-name iamgroup_mark \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

# List attached policies
aws iam list-attached-group-policies \
    --group-name iamgroup_mark \
    --query "AttachedPolicies[*].{PolicyName:PolicyName,PolicyARN:PolicyArn}" \
    --output table

# Detach a policy
aws iam detach-group-policy \
    --group-name iamgroup_mark \
    --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
```

---

### Inline Policy on a Group

```bash
# Create and attach a custom inline policy directly on the group
aws iam put-group-policy \
    --group-name iamgroup_mark \
    --policy-name S3BucketReadPolicy \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": ["s3:GetObject", "s3:ListBucket"],
                "Resource": [
                    "arn:aws:s3:::my-specific-bucket",
                    "arn:aws:s3:::my-specific-bucket/*"
                ]
            }
        ]
    }'

# List inline policies on a group
aws iam list-group-policies --group-name iamgroup_mark
```

---

### Deleting the Group (Full Cleanup)

```bash
# Groups cannot be deleted if they have users or policies attached

# 1. Remove all users
for user in $(aws iam get-group --group-name iamgroup_mark \
    --query "Users[*].UserName" --output text); do
    aws iam remove-user-from-group \
        --group-name iamgroup_mark --user-name "$user"
    echo "Removed $user from iamgroup_mark"
done

# 2. Detach all managed policies
for policy in $(aws iam list-attached-group-policies \
    --group-name iamgroup_mark \
    --query "AttachedPolicies[*].PolicyArn" --output text); do
    aws iam detach-group-policy \
        --group-name iamgroup_mark --policy-arn "$policy"
    echo "Detached $policy"
done

# 3. Delete all inline policies
for policy in $(aws iam list-group-policies \
    --group-name iamgroup_mark \
    --query "PolicyNames[*]" --output text); do
    aws iam delete-group-policy \
        --group-name iamgroup_mark --policy-name "$policy"
    echo "Deleted inline policy $policy"
done

# 4. Delete the group
aws iam delete-group --group-name iamgroup_mark
echo "Group iamgroup_mark deleted"
```

---

## 💻 Commands Reference

```bash
# --- CREATE GROUP ---
aws iam create-group --group-name iamgroup_mark

# --- VERIFY ---
aws iam get-group --group-name iamgroup_mark

aws iam list-groups \
    --query "Groups[*].{Name:GroupName,ID:GroupId,ARN:Arn}" \
    --output table

# --- ADD USER TO GROUP ---
aws iam add-user-to-group \
    --group-name iamgroup_mark --user-name iamuser_jim

# --- LIST GROUP MEMBERS ---
aws iam get-group --group-name iamgroup_mark \
    --query "Users[*].{Username:UserName,UserId:UserId}" \
    --output table

# --- ATTACH MANAGED POLICY ---
aws iam attach-group-policy \
    --group-name iamgroup_mark \
    --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

# --- LIST ATTACHED POLICIES ---
aws iam list-attached-group-policies --group-name iamgroup_mark

# --- INLINE POLICY ---
aws iam put-group-policy \
    --group-name iamgroup_mark \
    --policy-name MyInlinePolicy \
    --policy-document file://policy.json

# --- REMOVE USER ---
aws iam remove-user-from-group \
    --group-name iamgroup_mark --user-name iamuser_jim

# --- DELETE GROUP (cleanup order: users → policies → group) ---
aws iam delete-group --group-name iamgroup_mark
```

---

## ⚠️ Common Mistakes

**1. Trying to delete a group that still has members or policies**
`aws iam delete-group` will fail with `DeleteConflict` if the group still has users in it or policies attached. The cleanup order is strict: remove all users first, detach all managed policies, delete all inline policies, then delete the group.

**2. Expecting groups to work as policy principals**
Groups cannot be used in IAM policy `Principal` fields. You cannot write a resource policy that says "allow group X to access this S3 bucket." Resource policies work with users, roles, accounts, or services — not groups. Groups are exclusively an administrative tool for organising user→policy relationships.

**3. Nesting groups (it doesn't work)**
IAM groups are flat — a group cannot contain another group. If you're coming from an Active Directory mindset where nested groups are common, this is a behaviour difference worth knowing. In AWS, the equivalent of nested groups is achieved through roles and permission boundaries, or through IAM Identity Center's more sophisticated assignment model.

**4. Attaching policies directly to users when groups exist**
If a user belongs to a group, attaching an additional policy directly to them creates a mix of group-managed and individually-managed permissions that's harder to audit. The general rule: permissions come from groups, not individual attachments. Direct user policy attachments are the exception for truly one-off permissions.

**5. A user belonging to too many groups with overlapping permissions**
A user can belong to up to 10 groups. If each group has several policies, the effective permission set becomes difficult to reason about. When permissions seem wrong (either too permissive or too restrictive), use the **IAM Policy Simulator** or **Access Advisor** to evaluate the actual effective permissions for the user rather than manually tracing through all group memberships.

**6. Forgetting that group membership changes take effect immediately**
Adding a user to a group or attaching a policy to a group takes effect immediately on all current and future API calls — there's no propagation delay. This is important to remember during incident response: removing a user from a group or detaching a policy stops unauthorized access immediately.

---

## 🌍 Real-World Context

In a well-managed AWS account, the group structure mirrors the organisation's functional roles and follows the principle of least privilege for each function:

**Typical group structure for an engineering organisation:**

| Group | Policies | Who Belongs |
|-------|---------|-------------|
| `platform-admins` | `AdministratorAccess` | Senior platform engineers |
| `developers` | `PowerUserAccess` (minus IAM) | All developers |
| `security-auditors` | `SecurityAudit`, `ReadOnlyAccess` | Security team |
| `billing-viewers` | `Billing` | Finance team |
| `read-only` | `ReadOnlyAccess` | External reviewers, compliance |
| `support` | `SupportUser` | Support engineers |

The pattern for onboarding a new engineer: add them to the `developers` group. They immediately inherit all developer permissions. If they need elevated access temporarily (e.g., for an infra project), add them to `platform-admins` for the duration and remove them afterward.

At larger organisations, this group-based model is often replaced or supplemented by **IAM Identity Center permission sets** — which are essentially the same concept but applied across multiple AWS accounts in an Organisation. A developer's `developer` permission set applies consistently across all dev accounts, a `read-only` set across all prod accounts, etc.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is an IAM group and why should you use groups instead of attaching policies directly to users?**

> An IAM group is an administrative container for IAM users that allows you to apply policies to a collection of users at once. The operational reason to use groups is scalability and maintainability. When you have 50 developers and need to add a new permission, updating a single group policy is one operation. Updating 50 individual users is 50 operations with 50 opportunities for inconsistency. Onboarding a new developer is "add to group" rather than "remember which four policies to attach." Auditing what developers can do is "look at the group policy" rather than "check 50 individual policy lists." Direct user policy attachments are the exception for one-off, user-specific permissions — not the rule for shared permission sets.

---

**Q2. Can an IAM group be used as a principal in a resource-based policy (like an S3 bucket policy)?**

> No — IAM groups cannot be used as principals in resource policies. If you write an S3 bucket policy and try to put a group ARN in the `Principal` field, the policy will be invalid or silently ignored. Resource policies only accept users, roles, AWS services, and AWS accounts as principals. Groups are administrative containers — they're not identities that can authenticate or be granted access in policy documents. To grant an S3 bucket access to a group of users, you attach an IAM policy to the group that allows access to the bucket — working from the identity side rather than the resource side.

---

**Q3. What happens to a user's permissions when they're removed from a group?**

> The permissions granted by the group are immediately revoked — there's no delay. Any subsequent API call from that user will be evaluated without those group-granted permissions. If a user is in two groups and both grant access to EC2, removing them from one group (while remaining in the other) still leaves the EC2 access intact — permissions are additive across all group memberships and direct attachments. If the removed group was the only source of a particular permission, that permission is gone the moment the removal completes. This immediacy is useful for rapid access revocation during incident response.

---

**Q4. A user complains they can't access a resource even though the group they're in has the right policy attached. How do you debug this?**

> Start with the **IAM Policy Simulator** — put in the user, the action they're trying to perform, and the resource, and it will evaluate all applicable policies (user-level, group-level, resource-level) and tell you exactly which policy is allowing or denying the action. Also check: first, whether the user is actually in the group they think they're in (`list-groups-for-user`). Second, whether the group actually has the policy attached (`list-attached-group-policies`). Third, whether there's an explicit Deny somewhere — either in a directly attached user policy, a permission boundary, or an SCP at the organisation level. Explicit Denies always override Allows regardless of which policy grants the Allow. Fourth, check if there's a resource-based policy on the resource itself (S3 bucket policy, SQS queue policy) that restricts access.

---

**Q5. How many groups can an IAM user belong to, and what's the impact of this limit?**

> The default limit is **10 groups per IAM user**. This limit is a soft limit that can be raised by service quota request, but hitting it in practice usually signals a design problem — if you need a user in more than 10 groups to get the right permission set, the group structure is probably too granular or the policy architecture needs to be rethought. In well-designed environments, most users belong to 2–4 groups: one for their functional role (e.g., `developers`), one for their product team (e.g., `team-payments`), and possibly one for their seniority tier (e.g., `senior-engineers`). The intersection of those groups defines their effective permissions, and that's usually enough.

---

**Q6. What is the difference between an inline policy and a managed policy attached to a group?**

> A **managed policy** is a standalone IAM policy resource with its own ARN — it's created separately, can be attached to multiple groups/users/roles simultaneously, is versioned, and changes to it propagate to all entities it's attached to instantly. An **inline policy** is embedded directly into a group (or user or role) and exists only in the context of that entity — it can't be attached anywhere else, it's not independently versionable, and deleting the group deletes the inline policy with it. AWS recommends managed policies for most use cases because they're reusable, auditable by ARN, and easier to manage at scale. Inline policies are used when you want a policy that's strictly 1:1 with a specific entity and should never be inadvertently attached to anything else — useful for environment isolation or highly specific permissions.

---

**Q7. Your company is migrating from individual IAM user management to IAM Identity Center. How does the concept of IAM groups translate to the new model?**

> In IAM Identity Center, the equivalent of IAM groups is **permission sets** combined with **group assignments in the identity source** (your IdP). Instead of an IAM group named `developers` with `PowerUserAccess` attached, you create a permission set named `Developer` in Identity Center with the same policy, then assign your IdP's `developers` group to that permission set across the relevant AWS accounts. When a developer's manager adds them to the `developers` group in Okta or Active Directory, they automatically get the `Developer` permission set in AWS — no manual IAM group management required. When they leave, removing them from the IdP group revokes all AWS access automatically. The mental model is the same (group → permissions → users) but the implementation moves the source of truth for group membership to your corporate identity provider, which is where it should be.

---

## 📚 Resources

- [AWS Docs — IAM Groups](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_groups.html)
- [AWS CLI Reference — create-group](https://docs.aws.amazon.com/cli/latest/reference/iam/create-group.html)
- [IAM Policy Evaluation Logic](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)
- [IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
