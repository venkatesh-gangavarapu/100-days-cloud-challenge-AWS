#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 26: Launch EC2 Web Server with Nginx via User Data
# Instance: xfusion-ec2 | AMI: Ubuntu 22.04 | Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="xfusion-ec2"
SG_NAME="xfusion-sg"

# ============================================================
# STEP 1: RESOLVE LATEST UBUNTU 22.04 LTS AMI
# Canonical's AWS Account ID: 099720109477
# ============================================================

echo "=== Step 1: Resolving Ubuntu 22.04 LTS AMI ==="

AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "Latest Ubuntu 22.04 AMI: $AMI_ID"

# ============================================================
# STEP 2: RESOLVE DEFAULT NETWORKING
# ============================================================

echo ""
echo "=== Step 2: Resolving default VPC and subnet ==="

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

echo "VPC: $VPC_ID | Subnet: $SUBNET_ID"

# ============================================================
# STEP 3: CREATE SECURITY GROUP — ALLOW HTTP PORT 80
# ============================================================

echo ""
echo "=== Step 3: Creating security group '$SG_NAME' ==="

SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "$SG_NAME" \
    --description "xfusion web server — allow HTTP port 80 from internet" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}}]" \
    --query "GroupId" \
    --output text)

echo "Security Group created: $SG_ID"

# Allow HTTP inbound from the internet
aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

echo "Inbound rule added: TCP port 80 from 0.0.0.0/0"

# ============================================================
# STEP 4: BUILD USER DATA SCRIPT
# Install Nginx, start service, enable on reboot, log everything
# ============================================================

echo ""
echo "=== Step 4: Building User Data script ==="

USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e

# Redirect all output to a log file for debugging
exec >> /var/log/user-data.log 2>&1
echo "=== User Data script started: $(date) ==="

# Update package index (mandatory before any apt install)
echo "Running apt-get update..."
apt-get update -y

# Install Nginx
echo "Installing Nginx..."
apt-get install -y nginx

# Start Nginx immediately
echo "Starting Nginx..."
systemctl start nginx

# Enable Nginx to start automatically on every reboot
echo "Enabling Nginx on boot..."
systemctl enable nginx

# Confirm Nginx is active and listening on port 80
echo "Nginx service status:"
systemctl status nginx --no-pager

echo "Ports in use:"
ss -tlnp | grep :80

echo "=== User Data script completed: $(date) ==="
USERDATA
)

echo "User Data script ready"

# ============================================================
# STEP 5: LAUNCH THE EC2 INSTANCE
# ============================================================

echo ""
echo "=== Step 5: Launching instance '$INSTANCE_NAME' ==="

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --user-data "$USER_DATA" \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Instance launched: $INSTANCE_ID"

# ============================================================
# STEP 6: WAIT FOR INSTANCE RUNNING + STATUS CHECKS
# ============================================================

echo ""
echo "=== Step 6: Waiting for instance initialization ==="

echo "Waiting for running state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"
echo "Instance is running"

echo "Waiting for status checks (2/2 passed)..."
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
echo "Public IP: $PUBLIC_IP"

# ============================================================
# STEP 8: VERIFY NGINX IS SERVING HTTP 200
# Wait for User Data to complete (runs after status checks)
# ============================================================

echo ""
echo "=== Step 8: Verifying Nginx (30s wait for User Data to finish) ==="
sleep 30

MAX_RETRIES=6
ATTEMPT=0
HTTP_STATUS=""

while [ $ATTEMPT -lt $MAX_RETRIES ]; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 \
        "http://$PUBLIC_IP" 2>/dev/null || echo "000")

    echo "Attempt $((ATTEMPT+1)): HTTP $HTTP_STATUS from http://$PUBLIC_IP"

    if [ "$HTTP_STATUS" == "200" ]; then
        break
    fi

    ATTEMPT=$((ATTEMPT+1))
    [ $ATTEMPT -lt $MAX_RETRIES ] && sleep 15
done

echo ""
echo "============================================"
echo "  Instance:     $INSTANCE_NAME ($INSTANCE_ID)"
echo "  Security SG:  $SG_NAME ($SG_ID)"
echo "  Public IP:    $PUBLIC_IP"
echo "  URL:          http://$PUBLIC_IP"
echo "  HTTP Status:  $HTTP_STATUS"
echo "============================================"

if [ "$HTTP_STATUS" == "200" ]; then
    echo "✅ SUCCESS: Nginx is serving at http://$PUBLIC_IP"
else
    echo "⚠️  Nginx may still be starting. Retry:"
    echo "    curl http://$PUBLIC_IP"
    echo "    Debug: ssh ubuntu@$PUBLIC_IP then: cat /var/log/user-data.log"
fi

# ============================================================
# POST-LAUNCH VERIFICATION COMMANDS (run after SSH access)
# ============================================================

# Verify Nginx service is active:
# sudo systemctl status nginx

# Verify Nginx starts on reboot:
# sudo systemctl is-enabled nginx   # should print: enabled

# Check Nginx is listening on port 80:
# ss -tlnp | grep :80

# Review User Data log for errors:
# cat /var/log/user-data.log

# Full cloud-init output:
# cat /var/log/cloud-init-output.log | tail -30

# Local HTTP test from inside instance:
# curl -s http://localhost | head -5

# ============================================================
# CLEANUP (run when done)
# ============================================================

# aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
# aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
# aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION"
