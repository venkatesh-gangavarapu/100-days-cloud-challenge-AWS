#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 22: SSH Key Setup + Passwordless EC2 Root Access via User Data
# Instance: devops-ec2 | Key: /root/.ssh/id_rsa | Region: us-east-1
# Run this script on the aws-client host
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="devops-ec2"
KEY_PATH="/root/.ssh/id_rsa"

# ============================================================
# STEP 1: GENERATE SSH KEY ON AWS-CLIENT (if not exists)
# ============================================================

echo "=== Step 1: SSH Key Generation ==="

if [ ! -f "$KEY_PATH" ]; then
    echo "No key found at $KEY_PATH — generating new RSA key..."

    # Ensure the .ssh directory exists with correct permissions
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # Generate 4096-bit RSA key with no passphrase
    ssh-keygen -t rsa -b 4096 \
        -f "$KEY_PATH" \
        -N "" \
        -C "root@aws-client"

    echo "Key generated at $KEY_PATH"
else
    echo "Key already exists at $KEY_PATH — skipping generation"
fi

# Enforce correct permissions
chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.pub"

# Display the public key
echo "=== Public Key ==="
cat "${KEY_PATH}.pub"

# Capture public key content for embedding in User Data
PUB_KEY=$(cat "${KEY_PATH}.pub")

if [ -z "$PUB_KEY" ]; then
    echo "ERROR: Public key is empty. Key generation may have failed."
    exit 1
fi

# ============================================================
# STEP 2: RESOLVE LATEST AMAZON LINUX 2023 AMI
# ============================================================

echo ""
echo "=== Step 2: Resolving AMI ==="

AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners amazon \
    --filters \
        "Name=name,Values=al2023-ami-2023*-x86_64" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "AMI: $AMI_ID"

# ============================================================
# STEP 3: RESOLVE DEFAULT NETWORKING
# ============================================================

echo ""
echo "=== Step 3: Resolving Default Network Resources ==="

VPC_ID=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" --output text)

DEFAULT_SG=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text)

echo "VPC: $VPC_ID | Subnet: $SUBNET_ID | SG: $DEFAULT_SG"

# Ensure SSH (port 22) is allowed in the security group
MY_IP=$(curl -s https://checkip.amazonaws.com 2>/dev/null || echo "0.0.0.0")
echo "Adding SSH rule for $MY_IP/32 (or 0.0.0.0/0 as fallback)..."

aws ec2 authorize-security-group-ingress \
    --group-id "$DEFAULT_SG" \
    --protocol tcp \
    --port 22 \
    --cidr "${MY_IP}/32" \
    --region "$REGION" 2>/dev/null || echo "SSH rule may already exist — continuing"

# ============================================================
# STEP 4: BUILD USER DATA SCRIPT
# This script runs on the EC2 instance at first boot as root
# It injects the aws-client's public key into root's authorized_keys
# ============================================================

echo ""
echo "=== Step 4: Building User Data Script ==="

USER_DATA=$(cat <<USERDATA
#!/bin/bash
set -e

# Log file for debugging
exec >> /var/log/user-data.log 2>&1
echo "=== User Data started at \$(date) ==="

# Create /root/.ssh with correct permissions
mkdir -p /root/.ssh
chmod 700 /root/.ssh
chown root:root /root/.ssh

# Inject the aws-client public key into root's authorized_keys
echo "${PUB_KEY}" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys

echo "Public key injected into /root/.ssh/authorized_keys"

# Enable root SSH login via key (no password)
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin without-password/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Also allow empty passwords to be disabled (belt and suspenders)
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

echo "sshd_config updated"

# Restart SSH daemon to apply changes
systemctl restart sshd
echo "sshd restarted"

echo "=== User Data completed at \$(date) ==="
USERDATA
)

echo "User Data script built"

# ============================================================
# STEP 5: LAUNCH THE EC2 INSTANCE
# ============================================================

echo ""
echo "=== Step 5: Launching EC2 Instance ==="

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$DEFAULT_SG" \
    --associate-public-ip-address \
    --user-data "$USER_DATA" \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Instance launched: $INSTANCE_ID"

# ============================================================
# STEP 6: WAIT FOR RUNNING + STATUS CHECKS PASS
# ============================================================

echo ""
echo "=== Step 6: Waiting for Instance Initialization ==="

echo "Waiting for running state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"
echo "Instance is running"

echo "Waiting for status checks (2/2)..."
aws ec2 wait instance-status-ok \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"
echo "Status checks passed"

# ============================================================
# STEP 7: GET PUBLIC IP
# ============================================================

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

echo ""
echo "============================================"
echo "  Instance:  $INSTANCE_NAME ($INSTANCE_ID)"
echo "  Public IP: $PUBLIC_IP"
echo "  SSH:       ssh -i $KEY_PATH root@$PUBLIC_IP"
echo "============================================"

# ============================================================
# STEP 8: WAIT FOR USER DATA COMPLETION + TEST SSH
# ============================================================

echo ""
echo "=== Step 8: Waiting for User Data to complete (30s) ==="
sleep 30

echo "=== Testing passwordless SSH to root@$PUBLIC_IP ==="

ssh -i "$KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o BatchMode=yes \
    root@"$PUBLIC_IP" \
    "echo '✅ SSH SUCCESS | hostname: \$(hostname) | user: \$(whoami) | date: \$(date)'"

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Passwordless root SSH access CONFIRMED for $PUBLIC_IP"
else
    echo ""
    echo "⚠️  SSH test failed. User Data may still be running."
    echo "    Retry: ssh -i $KEY_PATH root@$PUBLIC_IP"
    echo "    Debug: aws ec2 get-console-output --instance-id $INSTANCE_ID --region $REGION"
fi

# ============================================================
# POST-VERIFICATION COMMANDS (run after SSH is working)
# ============================================================

# Check what User Data actually did:
# ssh -i $KEY_PATH root@$PUBLIC_IP "cat /var/log/user-data.log"

# Verify authorized_keys content:
# ssh -i $KEY_PATH root@$PUBLIC_IP "cat /root/.ssh/authorized_keys"

# Check sshd config:
# ssh -i $KEY_PATH root@$PUBLIC_IP "grep -E 'PermitRootLogin|PubkeyAuthentication|PasswordAuthentication' /etc/ssh/sshd_config"

# Verify cloud-init full log:
# ssh -i $KEY_PATH root@$PUBLIC_IP "tail -50 /var/log/cloud-init-output.log"
