#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 20: Creating an IAM Role for EC2
# Role: iamrole_kirsty | Policy: iampolicy_kirsty
# Entity type: AWS Service | Use case: EC2
# NOTE: IAM is global — no --region flag required
# ============================================================

ROLE_NAME="iamrole_kirsty"
POLICY_NAME="iampolicy_kirsty"
TRUST_POLICY_FILE="/tmp/ec2-trust-policy.json"

# ============================================================
# STEP 1: CREATE THE TRUST POLICY DOCUMENT
# Trust policy answers: WHO can assume this role?
# For EC2, the trusted service is ec2.amazonaws.com
# ============================================================

cat > "$TRUST_POLICY_FILE" << 'EOF'
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
cat "$TRUST_POLICY_FILE"

# ============================================================
# STEP 2: CREATE THE IAM ROLE
# ============================================================

aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://"$TRUST_POLICY_FILE" \
    --description "EC2 service role for kirsty workloads with iampolicy_kirsty" \
    --tags Key=Name,Value="$ROLE_NAME" \
           Key=UseCase,Value=EC2 \
           Key=ManagedBy,Value=cli

echo "Role '$ROLE_NAME' created"

# ============================================================
# STEP 3: RESOLVE THE POLICY ARN FOR iampolicy_kirsty
# ============================================================

# Check customer managed policies first
POLICY_ARN=$(aws iam list-policies \
    --scope Local \
    --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" \
    --output text)

# Fall back to AWS managed policies
if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" == "None" ]; then
    echo "Not in customer managed — checking AWS managed..."
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

# ============================================================
# STEP 4: ATTACH THE POLICY TO THE ROLE
# ============================================================

aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN"

echo "Policy '$POLICY_NAME' attached to role '$ROLE_NAME'"

# ============================================================
# STEP 5: CREATE INSTANCE PROFILE (required for EC2 attachment)
# NOTE: Console auto-creates this — CLI requires explicit creation
# ============================================================

aws iam create-instance-profile \
    --instance-profile-name "$ROLE_NAME"

aws iam add-role-to-instance-profile \
    --instance-profile-name "$ROLE_NAME" \
    --role-name "$ROLE_NAME"

echo "Instance profile '$ROLE_NAME' created and role added"

# ============================================================
# STEP 6: VERIFY ALL COMPONENTS
# ============================================================

echo ""
echo "=== Role Details ==="
aws iam get-role \
    --role-name "$ROLE_NAME" \
    --query "Role.{Name:RoleName,ARN:Arn,Created:CreateDate,Description:Description,MaxSession:MaxSessionDuration}" \
    --output table

echo ""
echo "=== Trust Policy (who can assume this role) ==="
aws iam get-role \
    --role-name "$ROLE_NAME" \
    --query "Role.AssumeRolePolicyDocument"

echo ""
echo "=== Attached Permission Policies ==="
aws iam list-attached-role-policies \
    --role-name "$ROLE_NAME" \
    --query "AttachedPolicies[*].{PolicyName:PolicyName,ARN:PolicyArn}" \
    --output table

echo ""
echo "=== Instance Profile ==="
aws iam get-instance-profile \
    --instance-profile-name "$ROLE_NAME" \
    --query "InstanceProfile.{Name:InstanceProfileName,ARN:Arn,Role:Roles[0].RoleName}" \
    --output table

# ============================================================
# OPTIONAL: ATTACH ROLE TO A RUNNING EC2 INSTANCE
# ============================================================

# aws ec2 associate-iam-instance-profile \
#     --instance-id <INSTANCE_ID> \
#     --iam-instance-profile Name="$ROLE_NAME"

# Verify association
# aws ec2 describe-iam-instance-profile-associations \
#     --filters "Name=instance-id,Values=<INSTANCE_ID>" \
#     --output table

# ============================================================
# OPTIONAL: VERIFY FROM INSIDE AN EC2 INSTANCE
# ============================================================
# (Run these from within the EC2 instance after attaching the profile)

# Check role is active via IMDS:
# curl http://169.254.169.254/latest/meta-data/iam/info

# Get the temporary credentials:
# curl http://169.254.169.254/latest/meta-data/iam/security-credentials/iamrole_kirsty

# Confirm caller identity (should show assumed-role ARN):
# aws sts get-caller-identity

# ============================================================
# OPTIONAL: UPDATE TRUST POLICY (add Lambda as trusted service)
# ============================================================

# cat > /tmp/multi-service-trust.json << 'EOF'
# {
#   "Version": "2012-10-17",
#   "Statement": [
#     {
#       "Effect": "Allow",
#       "Principal": {
#         "Service": [
#           "ec2.amazonaws.com",
#           "lambda.amazonaws.com"
#         ]
#       },
#       "Action": "sts:AssumeRole"
#     }
#   ]
# }
# EOF

# aws iam update-assume-role-policy \
#     --role-name "$ROLE_NAME" \
#     --policy-document file:///tmp/multi-service-trust.json

# ============================================================
# CLEANUP: DELETE ROLE (strict order required)
# ============================================================

# 1. Remove role from instance profile
# aws iam remove-role-from-instance-profile \
#     --instance-profile-name "$ROLE_NAME" \
#     --role-name "$ROLE_NAME"

# 2. Delete instance profile
# aws iam delete-instance-profile \
#     --instance-profile-name "$ROLE_NAME"

# 3. Detach all managed policies
# for policy in $(aws iam list-attached-role-policies \
#     --role-name "$ROLE_NAME" \
#     --query "AttachedPolicies[*].PolicyArn" --output text); do
#     aws iam detach-role-policy \
#         --role-name "$ROLE_NAME" --policy-arn "$policy"
# done

# 4. Delete all inline policies
# for policy in $(aws iam list-role-policies \
#     --role-name "$ROLE_NAME" \
#     --query "PolicyNames[*]" --output text); do
#     aws iam delete-role-policy \
#         --role-name "$ROLE_NAME" --policy-name "$policy"
# done

# 5. Delete the role
# aws iam delete-role --role-name "$ROLE_NAME"
# echo "Role $ROLE_NAME deleted"
