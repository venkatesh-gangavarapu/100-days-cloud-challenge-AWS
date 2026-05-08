#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 19: Attaching an IAM Policy to an IAM User
# User: IAMANITHA | Policy: IAMANITA
# NOTE: IAM is global — no --region flag required
# ============================================================

USER_NAME="IAMANITHA"
POLICY_NAME="IAMANITA"

# ============================================================
# STEP 1: CONFIRM USER EXISTS
# ============================================================

echo "=== Verifying IAM User: $USER_NAME ==="
aws iam get-user \
    --user-name "$USER_NAME" \
    --query "User.{Username:UserName,UserID:UserId,ARN:Arn,Created:CreateDate}" \
    --output table

# ============================================================
# STEP 2: RESOLVE POLICY ARN
# ============================================================

# Search in customer managed policies first
POLICY_ARN=$(aws iam list-policies \
    --scope Local \
    --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" \
    --output text)

# Fall back to AWS managed policies if not found
if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" == "None" ]; then
    echo "Not found in customer managed — checking AWS managed policies..."
    POLICY_ARN=$(aws iam list-policies \
        --scope AWS \
        --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" \
        --output text)
fi

if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" == "None" ]; then
    echo "ERROR: Policy '$POLICY_NAME' not found in this account"
    exit 1
fi

echo "Policy ARN: $POLICY_ARN"

# Show policy details
echo "=== Policy Details ==="
aws iam get-policy \
    --policy-arn "$POLICY_ARN" \
    --query "Policy.{Name:PolicyName,ARN:Arn,Description:Description,AttachCount:AttachmentCount}" \
    --output table

# ============================================================
# STEP 3: CHECK CURRENT POLICIES ON USER (before)
# ============================================================

echo "=== Policies on $USER_NAME (BEFORE attachment) ==="
aws iam list-attached-user-policies \
    --user-name "$USER_NAME" \
    --query "AttachedPolicies[*].{PolicyName:PolicyName,ARN:PolicyArn}" \
    --output table

# ============================================================
# STEP 4: ATTACH THE POLICY
# ============================================================

echo "Attaching policy '$POLICY_NAME' to user '$USER_NAME'..."

aws iam attach-user-policy \
    --user-name "$USER_NAME" \
    --policy-arn "$POLICY_ARN"

echo "Attachment complete"

# ============================================================
# STEP 5: VERIFY FROM USER SIDE
# ============================================================

echo "=== Policies on $USER_NAME (AFTER attachment) ==="
aws iam list-attached-user-policies \
    --user-name "$USER_NAME" \
    --query "AttachedPolicies[*].{PolicyName:PolicyName,ARN:PolicyArn}" \
    --output table

# ============================================================
# STEP 6: VERIFY FROM POLICY SIDE (who is using this policy)
# ============================================================

echo "=== Entities using policy '$POLICY_NAME' ==="
aws iam list-entities-for-policy \
    --policy-arn "$POLICY_ARN" \
    --query "{Users:PolicyUsers[*].UserName,Groups:PolicyGroups[*].GroupName,Roles:PolicyRoles[*].RoleName}" \
    --output table

# ============================================================
# OPTIONAL: SIMULATE EFFECTIVE PERMISSIONS
# ============================================================

# Replace ACCOUNT_ID with your actual AWS account ID
# ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# aws iam simulate-principal-policy \
#     --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/${USER_NAME}" \
#     --action-names ec2:DescribeInstances ec2:TerminateInstances s3:ListBuckets \
#     --resource-arns "*" \
#     --query "EvaluationResults[*].{Action:EvalActionName,Decision:EvalDecision}" \
#     --output table

# ============================================================
# OPTIONAL: ALSO ADD USER TO GROUP (preferred at scale)
# ============================================================

# aws iam add-user-to-group \
#     --user-name "$USER_NAME" \
#     --group-name iamgroup_mark

# aws iam list-groups-for-user --user-name "$USER_NAME" --output table

# ============================================================
# DETACH POLICY (when needed)
# ============================================================

# aws iam detach-user-policy \
#     --user-name "$USER_NAME" \
#     --policy-arn "$POLICY_ARN"

# echo "Policy detached"

# Verify detachment
# aws iam list-attached-user-policies \
#     --user-name "$USER_NAME" --output table
