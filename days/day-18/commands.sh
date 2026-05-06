#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 18: Creating an IAM Policy
# Policy: iampolicy_kareem | EC2 Console Read-Only
# NOTE: IAM is global — no --region flag required
# ============================================================

POLICY_NAME="iampolicy_kareem"
POLICY_DESC="Read-only access to EC2 console — view instances, AMIs, and snapshots"
POLICY_FILE="/tmp/iampolicy_kareem.json"

# ============================================================
# STEP 1: CREATE THE POLICY DOCUMENT
# ============================================================

cat > "$POLICY_FILE" << 'EOF'
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

echo "Policy document:"
cat "$POLICY_FILE"

# ============================================================
# STEP 2: CREATE THE IAM POLICY
# ============================================================

POLICY_ARN=$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --description "$POLICY_DESC" \
    --policy-document file://"$POLICY_FILE" \
    --tags Key=Name,Value="$POLICY_NAME" \
           Key=Purpose,Value=EC2ReadOnly \
    --query "Policy.Arn" \
    --output text)

echo "Policy created — ARN: $POLICY_ARN"

# ============================================================
# STEP 3: VERIFY THE POLICY
# ============================================================

echo "=== Policy Metadata ==="
aws iam get-policy \
    --policy-arn "$POLICY_ARN" \
    --query "Policy.{Name:PolicyName,ARN:Arn,Created:CreateDate,DefaultVersion:DefaultVersionId,AttachCount:AttachmentCount}" \
    --output table

# Retrieve and display the policy document
echo "=== Policy Document ==="
VERSION=$(aws iam get-policy \
    --policy-arn "$POLICY_ARN" \
    --query "Policy.DefaultVersionId" \
    --output text)

aws iam get-policy-version \
    --policy-arn "$POLICY_ARN" \
    --version-id "$VERSION" \
    --query "PolicyVersion.Document"

# List all customer managed policies
echo "=== All Customer Managed Policies ==="
aws iam list-policies \
    --scope Local \
    --query "Policies[*].{Name:PolicyName,ARN:Arn,Attachments:AttachmentCount,Created:CreateDate}" \
    --output table

# ============================================================
# STEP 4: SIMULATE TO VERIFY ALLOW/DENY BEHAVIOUR
# ============================================================

echo "=== Policy Simulation: verify read = allowed, write = denied ==="
aws iam simulate-custom-policy \
    --policy-input-list file://"$POLICY_FILE" \
    --action-names \
        ec2:DescribeInstances \
        ec2:DescribeImages \
        ec2:DescribeSnapshots \
        ec2:DescribeVolumes \
        ec2:TerminateInstances \
        ec2:RunInstances \
        ec2:StopInstances \
    --resource-arns "*" \
    --query "EvaluationResults[*].{Action:EvalActionName,Decision:EvalDecision}" \
    --output table

# Expected:
# DescribeInstances    → allowed
# DescribeImages       → allowed
# DescribeSnapshots    → allowed
# DescribeVolumes      → allowed
# TerminateInstances   → implicitDeny
# RunInstances         → implicitDeny
# StopInstances        → implicitDeny

# ============================================================
# OPTIONAL: ATTACH TO USER (from Day 16)
# ============================================================

# aws iam attach-user-policy \
#     --user-name iamuser_jim \
#     --policy-arn "$POLICY_ARN"

# aws iam list-attached-user-policies \
#     --user-name iamuser_jim --output table

# ============================================================
# OPTIONAL: ATTACH TO GROUP (from Day 17)
# ============================================================

# aws iam attach-group-policy \
#     --group-name iamgroup_mark \
#     --policy-arn "$POLICY_ARN"

# aws iam list-attached-group-policies \
#     --group-name iamgroup_mark --output table

# ============================================================
# OPTIONAL: UPDATE POLICY (create a new explicit version)
# ============================================================

# cat > /tmp/iampolicy_kareem_v2.json << 'EOF'
# {
#   "Version": "2012-10-17",
#   "Statement": [
#     {
#       "Sid": "EC2ViewInstances",
#       "Effect": "Allow",
#       "Action": [
#         "ec2:DescribeInstances",
#         "ec2:DescribeInstanceStatus",
#         "ec2:DescribeInstanceTypes"
#       ],
#       "Resource": "*"
#     },
#     {
#       "Sid": "EC2ViewAMIs",
#       "Effect": "Allow",
#       "Action": [
#         "ec2:DescribeImages",
#         "ec2:DescribeImageAttribute"
#       ],
#       "Resource": "*"
#     },
#     {
#       "Sid": "EC2ViewSnapshots",
#       "Effect": "Allow",
#       "Action": [
#         "ec2:DescribeSnapshots",
#         "ec2:DescribeSnapshotAttribute"
#       ],
#       "Resource": "*"
#     }
#   ]
# }
# EOF

# aws iam create-policy-version \
#     --policy-arn "$POLICY_ARN" \
#     --policy-document file:///tmp/iampolicy_kareem_v2.json \
#     --set-as-default

# aws iam list-policy-versions --policy-arn "$POLICY_ARN" --output table

# ============================================================
# CLEANUP: DELETE POLICY (strict order)
# ============================================================

# 1. Detach from all users and groups first
# aws iam list-entities-for-policy --policy-arn "$POLICY_ARN"

# 2. Delete non-default versions
# for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
#     --query "Versions[?IsDefaultVersion==\`false\`].VersionId" --output text); do
#     aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v"
# done

# 3. Delete the policy
# aws iam delete-policy --policy-arn "$POLICY_ARN"
