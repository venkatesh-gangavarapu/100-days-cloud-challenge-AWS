#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 17: Creating an IAM Group
# Group: iamgroup_mark
# NOTE: IAM is global — no --region flag required
# ============================================================

GROUP_NAME="iamgroup_mark"

# ============================================================
# STEP 1: CREATE THE IAM GROUP
# ============================================================

aws iam create-group --group-name "$GROUP_NAME"

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
# STEP 2: VERIFY THE GROUP WAS CREATED
# ============================================================

echo "=== IAM Group Details ==="
aws iam get-group --group-name "$GROUP_NAME"

echo "=== All IAM Groups in Account ==="
aws iam list-groups \
    --query "Groups[*].{Name:GroupName,ID:GroupId,ARN:Arn,Created:CreateDate}" \
    --output table

# ============================================================
# OPTIONAL: ADD USERS TO THE GROUP
# ============================================================

# Add a single user (assumes iamuser_jim exists from Day 16)
# aws iam add-user-to-group \
#     --group-name "$GROUP_NAME" \
#     --user-name iamuser_jim

# Add multiple users in a loop
# for user in iamuser_jim iamuser_alice; do
#     aws iam add-user-to-group \
#         --group-name "$GROUP_NAME" \
#         --user-name "$user"
#     echo "Added $user to $GROUP_NAME"
# done

# List group members
# aws iam get-group --group-name "$GROUP_NAME" \
#     --query "{Group:Group.GroupName,Members:Users[*].UserName}" \
#     --output table

# ============================================================
# OPTIONAL: ATTACH MANAGED POLICY TO GROUP
# ============================================================

# ReadOnlyAccess
# aws iam attach-group-policy \
#     --group-name "$GROUP_NAME" \
#     --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

# PowerUserAccess (all services except IAM)
# aws iam attach-group-policy \
#     --group-name "$GROUP_NAME" \
#     --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

# Verify attached policies
# aws iam list-attached-group-policies --group-name "$GROUP_NAME" \
#     --query "AttachedPolicies[*].{PolicyName:PolicyName,ARN:PolicyArn}" \
#     --output table

# ============================================================
# OPTIONAL: ATTACH INLINE POLICY TO GROUP
# ============================================================

# aws iam put-group-policy \
#     --group-name "$GROUP_NAME" \
#     --policy-name EC2ReadOnlyInline \
#     --policy-document '{
#         "Version": "2012-10-17",
#         "Statement": [
#             {
#                 "Effect": "Allow",
#                 "Action": [
#                     "ec2:Describe*"
#                 ],
#                 "Resource": "*"
#             }
#         ]
#     }'

# List inline policies
# aws iam list-group-policies --group-name "$GROUP_NAME"

# ============================================================
# OPTIONAL: REMOVE USER FROM GROUP
# ============================================================

# aws iam remove-user-from-group \
#     --group-name "$GROUP_NAME" \
#     --user-name iamuser_jim

# ============================================================
# CLEANUP: DELETE GROUP (strict order required)
# ============================================================

# 1. Remove all users from the group
# for user in $(aws iam get-group --group-name "$GROUP_NAME" \
#     --query "Users[*].UserName" --output text); do
#     aws iam remove-user-from-group \
#         --group-name "$GROUP_NAME" --user-name "$user"
#     echo "Removed $user"
# done

# 2. Detach all managed policies
# for policy in $(aws iam list-attached-group-policies \
#     --group-name "$GROUP_NAME" \
#     --query "AttachedPolicies[*].PolicyArn" --output text); do
#     aws iam detach-group-policy \
#         --group-name "$GROUP_NAME" --policy-arn "$policy"
#     echo "Detached $policy"
# done

# 3. Delete all inline policies
# for policy in $(aws iam list-group-policies \
#     --group-name "$GROUP_NAME" \
#     --query "PolicyNames[*]" --output text); do
#     aws iam delete-group-policy \
#         --group-name "$GROUP_NAME" --policy-name "$policy"
#     echo "Deleted inline policy: $policy"
# done

# 4. Delete the group
# aws iam delete-group --group-name "$GROUP_NAME"
# echo "Group $GROUP_NAME deleted"
