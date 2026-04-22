#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 06: Launching an EC2 Instance
# Instance: devops-ec2 | Type: t2.micro | Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="devops-ec2"
KEY_NAME="devops-kp"
INSTANCE_TYPE="t2.micro"

# ============================================================
# STEP 1: CREATE RSA KEY PAIR
# ============================================================

aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --key-type rsa \
    --key-format pem \
    --region "$REGION" \
    --query "KeyMaterial" \
    --output text > ~/.ssh/${KEY_NAME}.pem

chmod 400 ~/.ssh/${KEY_NAME}.pem

# Verify
aws ec2 describe-key-pairs \
    --key-names "$KEY_NAME" \
    --region "$REGION"

# ============================================================
# STEP 2: RESOLVE LATEST AMAZON LINUX 2023 AMI ID
# ============================================================

AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners amazon \
    --filters \
        "Name=name,Values=al2023-ami-2023*-x86_64" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "Latest Amazon Linux 2023 AMI: $AMI_ID"

# Alternative: resolve via SSM Parameter Store (more stable for automation)
# AMI_ID=$(aws ssm get-parameter \
#     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
#     --region "$REGION" \
#     --query "Parameter.Value" \
#     --output text)

# ============================================================
# STEP 3: GET DEFAULT SECURITY GROUP ID
# ============================================================

DEFAULT_SG_ID=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" \
    --output text)

echo "Default Security Group: $DEFAULT_SG_ID"

# ============================================================
# STEP 4: GET DEFAULT SUBNET ID
# ============================================================

DEFAULT_SUBNET_ID=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" \
    --output text)

echo "Default Subnet: $DEFAULT_SUBNET_ID"

# ============================================================
# STEP 5: LAUNCH THE EC2 INSTANCE
# ============================================================

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$DEFAULT_SG_ID" \
    --subnet-id "$DEFAULT_SUBNET_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Launched instance: $INSTANCE_ID"

# ============================================================
# STEP 6: WAIT FOR RUNNING STATE
# ============================================================

echo "Waiting for instance to reach running state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Instance $INSTANCE_ID is now running"

# ============================================================
# STEP 7: VERIFY AND GET PUBLIC IP
# ============================================================

aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,PublicIP:PublicIpAddress,AMI:ImageId}" \
    --output table

PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

echo "Public IP: $PUBLIC_IP"
echo "SSH command: ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${PUBLIC_IP}"

# ============================================================
# SSH INTO THE INSTANCE
# ============================================================

# ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@"$PUBLIC_IP"

# Once inside — verify identity
# curl http://169.254.169.254/latest/meta-data/instance-id
# curl http://169.254.169.254/latest/meta-data/placement/availability-zone
# cat /etc/os-release

# ============================================================
# STOP / START / TERMINATE
# ============================================================

# Stop (preserves EBS, public IP will change on restart)
# aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION"

# Start
# aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION"

# Terminate (PERMANENT — deletes root EBS by default)
# aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
