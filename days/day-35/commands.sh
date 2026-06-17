#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 35: Private RDS + PHP App Connectivity from EC2
# RDS: devops-rds | EC2: devops-ec2 | Region: us-east-1
# Run this script on the aws-client host
# ============================================================

set -e
REGION="us-east-1"

DB_ID="devops-rds"
DB_PASSWORD="DevOps_Admin123!"   # Change to a strong password
DB_NAME="devops_db"
DB_USER="devops_admin"

# ============================================================
# STEP 1: RESOLVE VPC AND devops-ec2 DETAILS
# ============================================================

echo "=== Step 1: Resolving resources ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

EC2_ID=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=devops-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

EC2_SG=$(aws ec2 describe-instances --instance-ids $EC2_ID --region $REGION \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

EC2_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $EC2_ID --region $REGION \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "VPC:          $VPC_ID"
echo "devops-ec2:   $EC2_ID"
echo "EC2 SG:       $EC2_SG"
echo "EC2 Public IP: $EC2_PUBLIC_IP"

# ============================================================
# STEP 2: OPEN PORT 80 ON devops-ec2's SECURITY GROUP
# ============================================================

echo ""
echo "=== Step 2: Opening port 80 on devops-ec2 SG ==="

aws ec2 authorize-security-group-ingress \
    --group-id $EC2_SG --protocol tcp --port 80 \
    --cidr 0.0.0.0/0 --region $REGION \
    2>/dev/null && echo "Port 80 opened" || echo "Rule may already exist — continuing"

# ============================================================
# STEP 3: CREATE RDS SECURITY GROUP
# Allow 3306 ONLY from devops-ec2's security group (SG-as-source)
# ============================================================

echo ""
echo "=== Step 3: Creating RDS security group ==="

RDS_SG=$(aws ec2 create-security-group \
    --region $REGION \
    --group-name devops-rds-sg \
    --description "devops-rds — MySQL 3306 from devops-ec2 SG only" \
    --vpc-id $VPC_ID \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=devops-rds-sg}]' \
    --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $RDS_SG --protocol tcp --port 3306 \
    --source-group $EC2_SG --region $REGION

echo "RDS SG: $RDS_SG (port 3306 from $EC2_SG)"

# ============================================================
# STEP 4: CREATE THE RDS INSTANCE
# Sandbox-equivalent: single-AZ, db.t3.micro, gp2, 5 GiB
# Initial database 'devops_db' created automatically
# ============================================================

echo ""
echo "=== Step 4: Creating RDS instance '$DB_ID' ==="

aws rds create-db-instance \
    --region $REGION \
    --db-instance-identifier "$DB_ID" \
    --db-instance-class "db.t3.micro" \
    --engine "mysql" \
    --engine-version "8.4.5" \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASSWORD" \
    --db-name "$DB_NAME" \
    --allocated-storage 5 \
    --storage-type "gp2" \
    --no-publicly-accessible \
    --no-multi-az \
    --vpc-security-group-ids $RDS_SG \
    --backup-retention-period 1 \
    --no-deletion-protection \
    --tags Key=Name,Value="$DB_ID"

echo "RDS creation initiated — waiting for available (~10-15 minutes)..."

aws rds wait db-instance-available \
    --db-instance-identifier "$DB_ID" --region $REGION

RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_ID" --region $REGION \
    --query "DBInstances[0].Endpoint.Address" --output text)

echo "✅ RDS available"
echo "Endpoint: $RDS_ENDPOINT"

aws rds describe-db-instances \
    --db-instance-identifier "$DB_ID" --region $REGION \
    --query "DBInstances[0].{Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,Storage:AllocatedStorage,DBName:DBName,Public:PubliclyAccessible}" \
    --output table

# ============================================================
# STEP 5: SSH KEY GENERATION (if not exists)
# ============================================================

echo ""
echo "=== Step 5: SSH key setup ==="

if [ ! -f /root/.ssh/id_rsa ]; then
    echo "Generating new SSH key..."
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -C "root@aws-client"
else
    echo "SSH key already exists at /root/.ssh/id_rsa"
fi

chmod 600 /root/.ssh/id_rsa
chmod 644 /root/.ssh/id_rsa.pub
PUB_KEY=$(cat /root/.ssh/id_rsa.pub)

# Allow SSH from aws-client's IP
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --group-id $EC2_SG --protocol tcp --port 22 \
    --cidr "${MY_IP}/32" --region $REGION \
    2>/dev/null || echo "SSH rule may already exist"

# ============================================================
# STEP 6: INJECT PUBLIC KEY INTO devops-ec2 ROOT VIA SSM
# ============================================================

echo ""
echo "=== Step 6: Injecting SSH public key via SSM Run Command ==="

CMD_ID=$(aws ssm send-command \
    --region $REGION \
    --instance-ids "$EC2_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[
        'mkdir -p /root/.ssh',
        'chmod 700 /root/.ssh',
        'grep -qF \"${PUB_KEY}\" /root/.ssh/authorized_keys 2>/dev/null || echo \"${PUB_KEY}\" >> /root/.ssh/authorized_keys',
        'chmod 600 /root/.ssh/authorized_keys'
    ]" \
    --query "Command.CommandId" --output text)

echo "SSM Command ID: $CMD_ID"
sleep 10

SSM_STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$EC2_ID" --region $REGION \
    --query "Status" --output text 2>/dev/null || echo "Unknown")

echo "SSM status: $SSM_STATUS"

if [ "$SSM_STATUS" != "Success" ]; then
    echo "⚠️  SSM injection may have failed. Use EC2 Instance Connect from console as fallback:"
    echo "    EC2 Console → devops-ec2 → Connect → EC2 Instance Connect"
    echo "    Then manually run:"
    echo "    mkdir -p /root/.ssh && echo '$PUB_KEY' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
fi

# ============================================================
# STEP 7: TEST SSH AND COPY index.php
# ============================================================

echo ""
echo "=== Step 7: Testing SSH access ==="

ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    root@$EC2_PUBLIC_IP "echo 'SSH connection successful'"

echo ""
echo "Copying index.php to devops-ec2..."

if [ ! -f /root/index.php ]; then
    echo "ERROR: /root/index.php not found on aws-client"
    exit 1
fi

scp -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no \
    /root/index.php root@$EC2_PUBLIC_IP:/tmp/index.php

echo "File copied to /tmp/index.php on devops-ec2"

# ============================================================
# STEP 8: INSTALL WEB SERVER + PHP, CONFIGURE DB CONNECTION
# ============================================================

echo ""
echo "=== Step 8: Configuring devops-ec2 (web server + PHP + DB config) ==="

ssh -i /root/.ssh/id_rsa root@$EC2_PUBLIC_IP bash -s << REMOTESCRIPT
set -e

echo "Detecting package manager and installing web server + PHP..."

if command -v dnf >/dev/null 2>&1; then
    dnf install -y httpd php php-mysqlnd
    systemctl enable httpd
    systemctl start httpd
    WEB_SVC="httpd"
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y apache2 php libapache2-mod-php php-mysql
    systemctl enable apache2
    systemctl start apache2
    WEB_SVC="apache2"
fi

echo "Web server installed and started: \$WEB_SVC"

# Update DB connection variables in index.php
sed -i "s/\\\$servername.*/\\\$servername = \"$RDS_ENDPOINT\";/" /tmp/index.php
sed -i "s/\\\$username.*/\\\$username = \"$DB_USER\";/" /tmp/index.php
sed -i "s/\\\$password.*/\\\$password = \"$DB_PASSWORD\";/" /tmp/index.php
sed -i "s/\\\$dbname.*/\\\$dbname = \"$DB_NAME\";/" /tmp/index.php

# Deploy to web root
cp /tmp/index.php /var/www/html/index.php
chmod 644 /var/www/html/index.php

echo "=== Deployed index.php ==="
cat /var/www/html/index.php

systemctl restart \$WEB_SVC
echo "Web server restarted"
REMOTESCRIPT

echo "Remote configuration complete"

# ============================================================
# STEP 9: VERIFY "Connected successfully"
# ============================================================

echo ""
echo "=== Step 9: Verifying PHP-to-RDS connection ==="

sleep 5

RESPONSE=$(curl -s --connect-timeout 10 http://$EC2_PUBLIC_IP)
echo "HTTP Response:"
echo "$RESPONSE"
echo ""

if echo "$RESPONSE" | grep -qi "Connected successfully"; then
    echo "✅ SUCCESS: 'Connected successfully' confirmed"
else
    echo "⚠️  Expected message not found. Debug steps:"
    echo "  1. SSH in: ssh -i /root/.ssh/id_rsa root@$EC2_PUBLIC_IP"
    echo "  2. Check Apache error log:"
    echo "     tail -30 /var/log/httpd/error_log   (Amazon Linux)"
    echo "     tail -30 /var/log/apache2/error.log (Ubuntu)"
    echo "  3. Test direct MySQL connectivity:"
    echo "     mysql -h $RDS_ENDPOINT -u $DB_USER -p$DB_PASSWORD $DB_NAME -e 'SELECT 1;'"
fi

# ============================================================
# FINAL SUMMARY
# ============================================================

echo ""
echo "============================================"
echo "  RDS Instance:   $DB_ID"
echo "  RDS Endpoint:   $RDS_ENDPOINT"
echo "  Database:       $DB_NAME"
echo "  Master User:    $DB_USER"
echo "  EC2 Instance:   devops-ec2 ($EC2_PUBLIC_IP)"
echo "  Test URL:       http://$EC2_PUBLIC_IP"
echo "  SSH:            ssh -i /root/.ssh/id_rsa root@$EC2_PUBLIC_IP"
echo "============================================"
