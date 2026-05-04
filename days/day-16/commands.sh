#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 16: Creating an IAM User
# Username: iamuser_jim
# NOTE: IAM is a global service — no --region required for most commands
# ============================================================

USERNAME="iamuser_jim"

# ============================================================
# STEP 1: CREATE THE IAM USER
# ============================================================

aws iam create-user \
    --user-name "$USERNAME" \
    --tags Key=Name,Value="$USERNAME" Key=ManagedBy,Value=cli

# Output includes:
# UserName, UserId, Arn, Path, CreateDate

# ============================================================
# STEP 2: VERIFY THE USER WAS CREATED
# ============================================================

echo "=== IAM User Details ==="
aws iam get-user --user-name "$USERNAME"

# List all users in the account
echo "=== All IAM Users ==="
aws iam list-users \
    --query "Users[*].{Username:UserName,UserID:UserId,ARN:Arn,Created:CreateDate}" \
    --output table

# ============================================================
# OPTIONAL: ADD CONSOLE ACCESS (login profile)
# ============================================================

# aws iam create-login-profile \
#     --user-name "$USERNAME" \
#     --password "TempP@ssw0rd!" \
#     --password-reset-required

# Verify login profile exists
# aws iam get-login-profile --user-name "$USERNAME"

# ============================================================
# OPTIONAL: CREATE ACCESS KEYS (CLI/API access)
# ============================================================

# CAUTION: SecretAccessKey is shown ONLY ONCE — store securely immediately
# aws iam create-access-key --user-name "$USERNAME"

# List access keys (shows KeyId and status, NOT the secret)
# aws iam list-access-keys --user-name "$USERNAME"

# ============================================================
# OPTIONAL: ATTACH A MANAGED POLICY DIRECTLY
# ============================================================

# aws iam attach-user-policy \
#     --user-name "$USERNAME" \
#     --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

# List all attached policies
# aws iam list-attached-user-policies --user-name "$USERNAME"

# ============================================================
# OPTIONAL: ADD USER TO A GROUP
# ============================================================

# Create group (if needed)
# aws iam create-group --group-name Developers

# Attach policy to group
# aws iam attach-group-policy \
#     --group-name Developers \
#     --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

# Add user to group
# aws iam add-user-to-group \
#     --user-name "$USERNAME" \
#     --group-name Developers

# Verify group membership
# aws iam list-groups-for-user --user-name "$USERNAME"

# ============================================================
# OPTIONAL: ENABLE MFA (virtual MFA device)
# ============================================================

# Create virtual MFA device
# aws iam create-virtual-mfa-device \
#     --virtual-mfa-device-name "${USERNAME}-mfa" \
#     --outfile /tmp/qrcode.png \
#     --bootstrap-method QRCodePNG

# Enable MFA (requires two consecutive TOTP codes from the device)
# aws iam enable-mfa-device \
#     --user-name "$USERNAME" \
#     --serial-number arn:aws:iam::ACCOUNT_ID:mfa/${USERNAME}-mfa \
#     --authentication-code1 123456 \
#     --authentication-code2 789012

# List MFA devices for user
# aws iam list-mfa-devices --user-name "$USERNAME"

# ============================================================
# SECURITY AUDIT: IAM Credential Report
# ============================================================

# Generate credential report (covers all users in account)
# aws iam generate-credential-report

# Download and decode the report
# aws iam get-credential-report \
#     --query "Content" --output text | base64 -d > credential-report.csv

# cat credential-report.csv

# ============================================================
# CLEANUP: DELETE USER (full sequence — order matters)
# ============================================================

# 1. Remove from all groups
# for group in $(aws iam list-groups-for-user --user-name "$USERNAME" \
#     --query "Groups[*].GroupName" --output text); do
#     aws iam remove-user-from-group --user-name "$USERNAME" --group-name "$group"
# done

# 2. Detach all user policies
# for policy in $(aws iam list-attached-user-policies --user-name "$USERNAME" \
#     --query "AttachedPolicies[*].PolicyArn" --output text); do
#     aws iam detach-user-policy --user-name "$USERNAME" --policy-arn "$policy"
# done

# 3. Delete access keys
# for key in $(aws iam list-access-keys --user-name "$USERNAME" \
#     --query "AccessKeyMetadata[*].AccessKeyId" --output text); do
#     aws iam delete-access-key --user-name "$USERNAME" --access-key-id "$key"
# done

# 4. Delete login profile (if exists)
# aws iam delete-login-profile --user-name "$USERNAME" 2>/dev/null || true

# 5. Deactivate and delete MFA devices
# for mfa in $(aws iam list-mfa-devices --user-name "$USERNAME" \
#     --query "MFADevices[*].SerialNumber" --output text); do
#     aws iam deactivate-mfa-device --user-name "$USERNAME" --serial-number "$mfa"
#     aws iam delete-virtual-mfa-device --serial-number "$mfa"
# done

# 6. Delete the user
# aws iam delete-user --user-name "$USERNAME"
