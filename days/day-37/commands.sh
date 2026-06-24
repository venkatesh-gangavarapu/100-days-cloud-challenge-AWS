#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 37: EC2 IAM Role for S3 Access
# S3: datacenter-s3-683588789756 | Role: datacenter-role
# EC2: datacenter-ec2 | Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
BUCKET="datacenter-s3-683588789756"
POLICY_NAME="datacenter-s3-policy"
ROLE_NAME="datacenter-role"

# ============================================================
# STEP 1: SSH KEY GENERATION
# ============================================================

echo "=== Step 1: SSH Key Setup ==="

if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -C "root@aws-client"
    echo "New SSH key generated"
else
    echo "Key already exists at /root/.ssh/id_rsa"
fi

chmod 600 /root/.ssh/id_rsa
chmod 644 /root/.ssh/id_rsa.pub
PUB_KEY=$(cat /root/.ssh/id_rsa.pub)
echo "Public key ready"

# ============================================================
# STEP 2: CREATE PRIVATE S3 BUCKET
# NOTE: us-east-1 does NOT accept --create-bucket-configuration
# ============================================================

echo ""
echo "=== Step 2: Creating private S3 bucket '$BUCKET' ==="

aws s3api create-bucket \
    --bucket $BUCKET \
    --region $REGION

aws s3api put-public-access-block \
    --bucket $BUCKET \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api head-bucket --bucket $BUCKET && echo "Bucket confirmed: $BUCKET"

# Verify block public access
aws s3api get-public-access-block --bucket $BUCKET \
    --query "PublicAccessBlockConfiguration" --output table

# ============================================================
# STEP 3: CREATE IAM POLICY
# TWO resource ARNs required:
#   bucket-level  → s3:ListBucket
#   object-level  → s3:GetObject, s3:PutObject
# ============================================================

echo ""
echo "=== Step 3: Creating IAM policy '$POLICY_NAME' ==="

cat > /tmp/s3-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListBucketAccess",
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::${BUCKET}"
        },
        {
            "Sid": "ObjectAccess",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject"
            ],
            "Resource": "arn:aws:s3:::${BUCKET}/*"
        }
    ]
}
EOF

echo "Policy document:"
cat /tmp/s3-policy.json

POLICY_ARN=$(aws iam create-policy \
    --policy-name $POLICY_NAME \
    --policy-document file:///tmp/s3-policy.json \
    --description "S3 access policy for datacenter-ec2" \
    --query "Policy.Arn" --output text)

echo "Policy ARN: $POLICY_ARN"

# ============================================================
# STEP 4: CREATE IAM ROLE WITH EC2 TRUST POLICY
# ============================================================

echo ""
echo "=== Step 4: Creating IAM role '$ROLE_NAME' ==="

cat > /tmp/ec2-trust.json << 'EOF'
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

aws iam create-role \
    --role-name $ROLE_NAME \
    --assume-role-policy-document file:///tmp/ec2-trust.json \
    --description "IAM role for datacenter-ec2 S3 access"

aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn $POLICY_ARN

echo "Policy '$POLICY_NAME' attached to role '$ROLE_NAME'"

# Verify role
aws iam get-role --role-name $ROLE_NAME \
    --query "Role.{Name:RoleName,ARN:Arn}" --output table

aws iam list-attached-role-policies --role-name $ROLE_NAME \
    --query "AttachedPolicies[*].{Name:PolicyName,ARN:PolicyArn}" --output table

# ============================================================
# STEP 5: CREATE INSTANCE PROFILE
# Console creates this automatically; CLI requires it manually
# ============================================================

echo ""
echo "=== Step 5: Creating instance profile ==="

aws iam create-instance-profile \
    --instance-profile-name $ROLE_NAME \
    2>/dev/null && echo "Instance profile created" \
    || echo "Instance profile already exists — continuing"

aws iam add-role-to-instance-profile \
    --instance-profile-name $ROLE_NAME \
    --role-name $ROLE_NAME \
    2>/dev/null && echo "Role added to instance profile" \
    || echo "Role already linked — continuing"

echo "Waiting 15s for IAM propagation..."
sleep 15

# ============================================================
# STEP 6: GET datacenter-ec2 DETAILS
# ============================================================

echo ""
echo "=== Step 6: Resolving datacenter-ec2 ==="

INSTANCE_ID=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=datacenter-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

EC2_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

EC2_SG=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

echo "Instance: $INSTANCE_ID  IP: $EC2_IP  SG: $EC2_SG"

# ============================================================
# STEP 7: ATTACH INSTANCE PROFILE TO datacenter-ec2
# Handle case where instance already has a role attached
# ============================================================

echo ""
echo "=== Step 7: Attaching IAM role to datacenter-ec2 ==="

EXISTING_ASSOC=$(aws ec2 describe-iam-instance-profile-associations \
    --region $REGION \
    --filters "Name=instance-id,Values=$INSTANCE_ID" \
    --query "IamInstanceProfileAssociations[0].AssociationId" --output text)

if [ "$EXISTING_ASSOC" != "None" ] && [ -n "$EXISTING_ASSOC" ]; then
    echo "Replacing existing association: $EXISTING_ASSOC"
    aws ec2 replace-iam-instance-profile-association \
        --association-id $EXISTING_ASSOC \
        --iam-instance-profile Name=$ROLE_NAME \
        --region $REGION
else
    aws ec2 associate-iam-instance-profile \
        --region $REGION \
        --instance-id $INSTANCE_ID \
        --iam-instance-profile Name=$ROLE_NAME
fi

echo "IAM role '$ROLE_NAME' attached to $INSTANCE_ID"

# Verify
aws ec2 describe-iam-instance-profile-associations --region $REGION \
    --filters "Name=instance-id,Values=$INSTANCE_ID" \
    --query "IamInstanceProfileAssociations[0].{Profile:IamInstanceProfile.Arn,State:State}" \
    --output table

# ============================================================
# STEP 8: INJECT SSH KEY (allow SSH from aws-client)
# ============================================================

echo ""
echo "=== Step 8: Setting up SSH access ==="

MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --group-id $EC2_SG --protocol tcp --port 22 \
    --cidr "${MY_IP}/32" --region $REGION \
    2>/dev/null || echo "SSH rule may already exist"

CMD_ID=$(aws ssm send-command \
    --region $REGION \
    --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[
        'mkdir -p /root/.ssh && chmod 700 /root/.ssh',
        'grep -qF \"${PUB_KEY}\" /root/.ssh/authorized_keys 2>/dev/null || echo \"${PUB_KEY}\" >> /root/.ssh/authorized_keys',
        'chmod 600 /root/.ssh/authorized_keys'
    ]" \
    --query "Command.CommandId" --output text 2>/dev/null)

if [ -n "$CMD_ID" ]; then
    sleep 10
    echo "SSM key injection complete (Command: $CMD_ID)"
else
    echo "SSM unavailable — inject key manually via EC2 Instance Connect"
fi

# ============================================================
# STEP 9: TEST S3 ACCESS FROM WITHIN EC2
# ============================================================

echo ""
echo "=== Step 9: Testing S3 access from datacenter-ec2 ==="

sleep 10

ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no \
    -o ConnectTimeout=20 root@$EC2_IP << REMOTE
echo "=== Connected to: \$(hostname) ==="

# Create test file
echo "Uploaded from datacenter-ec2 at \$(date)" > /tmp/testfile.txt
echo "Test file contents: \$(cat /tmp/testfile.txt)"

# Upload
echo ""
echo "--- Uploading to S3 ---"
aws s3 cp /tmp/testfile.txt s3://datacenter-s3-683588789756/

# List
echo ""
echo "--- Listing S3 bucket ---"
aws s3 ls s3://datacenter-s3-683588789756/

echo ""
echo "=== S3 access test COMPLETE ==="
REMOTE

echo ""
echo "============================================"
echo "  S3 Bucket:  $BUCKET"
echo "  IAM Policy: $POLICY_NAME"
echo "  IAM Role:   $ROLE_NAME"
echo "  EC2:        datacenter-ec2 ($INSTANCE_ID)"
echo "  EC2 IP:     $EC2_IP"
echo "============================================"
