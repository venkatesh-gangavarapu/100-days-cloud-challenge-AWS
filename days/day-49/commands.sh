#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 49: Multi-VPC Log Aggregation — VPC Peering, EC2, S3, Cron
# Region: us-east-1
#
# Lessons from previous attempts baked in:
#   1. Both route tables explicitly verified after peering
#   2. No ProxyJump for SCP — deploy key from inside public EC2
#   3. No placeholder test upload — pull REAL boots.log from private EC2
#   4. Full paths (/usr/bin/scp, /usr/bin/aws) in all cron entries
#   5. ManagedPolicyArns only (iam:PutRolePolicy blocked in this lab)
# ============================================================

set -e
REGION="us-east-1"
S3_BUCKET="devops-s3-logs-9204"
ROLE_NAME="devops-s3-role"
KEY_FILE="/root/.ssh/devops-key.pem"
KEY_PAIR_NAME="devops-key"

chmod 400 $KEY_FILE

# ============================================================
# STEP 1: RESOLVE EXISTING PRIVATE VPC RESOURCES
# ============================================================

echo "=== Step 1: Resolving existing resources ==="

PRIV_VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=tag:Name,Values=devops-priv-vpc" \
    --query "Vpcs[0].VpcId" --output text)
PRIV_VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $PRIV_VPC_ID \
    --region $REGION --query "Vpcs[0].CidrBlock" --output text)

PRIV_SUBNET_ID=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=tag:Name,Values=devops-priv-subnet" \
    --query "Subnets[0].SubnetId" --output text)
PRIV_SUBNET_AZ=$(aws ec2 describe-subnets --subnet-ids $PRIV_SUBNET_ID \
    --region $REGION --query "Subnets[0].AvailabilityZone" --output text)

PRIV_RT_ID=$(aws ec2 describe-route-tables --region $REGION \
    --filters "Name=tag:Name,Values=devops-priv-rt" \
    --query "RouteTables[0].RouteTableId" --output text)

PRIV_EC2_ID=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=devops-priv-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)
PRIV_EC2_IP=$(aws ec2 describe-instances --instance-ids $PRIV_EC2_ID \
    --region $REGION \
    --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
PRIV_EC2_SG=$(aws ec2 describe-instances --instance-ids $PRIV_EC2_ID \
    --region $REGION \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

# Non-overlapping CIDR for public VPC
SECOND=$(echo $PRIV_VPC_CIDR | cut -d. -f2)
PUB_VPC_CIDR="10.$((SECOND + 1)).0.0/16"
PUB_SUBNET_CIDR="10.$((SECOND + 1)).1.0/24"

echo "Private VPC:   $PRIV_VPC_ID ($PRIV_VPC_CIDR)"
echo "Private RT:    $PRIV_RT_ID"
echo "Private EC2:   $PRIV_EC2_ID  IP=$PRIV_EC2_IP  SG=$PRIV_EC2_SG"
echo "Public VPC:    (will be) $PUB_VPC_CIDR"

# ============================================================
# STEP 2: CREATE PUBLIC VPC STACK
# ============================================================

echo ""
echo "=== Step 2: Creating devops-pub-vpc ==="

PUB_VPC_ID=$(aws ec2 create-vpc --region $REGION \
    --cidr-block $PUB_VPC_CIDR \
    --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=devops-pub-vpc}]' \
    --query "Vpc.VpcId" --output text)
aws ec2 modify-vpc-attribute \
    --vpc-id $PUB_VPC_ID --enable-dns-hostnames --region $REGION

PUB_SUBNET_ID=$(aws ec2 create-subnet --region $REGION \
    --vpc-id $PUB_VPC_ID --cidr-block $PUB_SUBNET_CIDR \
    --availability-zone $PRIV_SUBNET_AZ \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=devops-pub-subnet}]' \
    --query "Subnet.SubnetId" --output text)
aws ec2 modify-subnet-attribute \
    --subnet-id $PUB_SUBNET_ID --map-public-ip-on-launch --region $REGION

IGW_ID=$(aws ec2 create-internet-gateway --region $REGION \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=devops-pub-igw}]' \
    --query "InternetGateway.InternetGatewayId" --output text)
aws ec2 attach-internet-gateway \
    --internet-gateway-id $IGW_ID --vpc-id $PUB_VPC_ID --region $REGION

PUB_RT_ID=$(aws ec2 create-route-table --region $REGION \
    --vpc-id $PUB_VPC_ID \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=devops-pub-rt}]' \
    --query "RouteTable.RouteTableId" --output text)
aws ec2 create-route --route-table-id $PUB_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID --region $REGION
aws ec2 associate-route-table \
    --route-table-id $PUB_RT_ID \
    --subnet-id $PUB_SUBNET_ID --region $REGION

echo "VPC=$PUB_VPC_ID  Subnet=$PUB_SUBNET_ID  IGW=$IGW_ID  RT=$PUB_RT_ID"

# ============================================================
# STEP 3: SECURITY GROUPS
# ============================================================

echo ""
echo "=== Step 3: Security groups ==="

PUB_SG_ID=$(aws ec2 create-security-group --region $REGION \
    --group-name devops-pub-sg \
    --description "devops-pub-ec2: SSH + private VPC traffic" \
    --vpc-id $PUB_VPC_ID \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=devops-pub-sg}]' \
    --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress --group-id $PUB_SG_ID \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION
aws ec2 authorize-security-group-ingress --group-id $PUB_SG_ID \
    --protocol -1 --cidr $PRIV_VPC_CIDR --region $REGION
echo "Public SG: $PUB_SG_ID"

aws ec2 authorize-security-group-ingress --group-id $PRIV_EC2_SG \
    --protocol -1 --cidr $PUB_VPC_CIDR --region $REGION \
    2>/dev/null && echo "Private SG updated" || echo "Private SG rule exists"

# ============================================================
# STEP 4: LAUNCH devops-pub-ec2
# ============================================================

echo ""
echo "=== Step 4: Launching devops-pub-ec2 ==="

UBUNTU_AMI=$(aws ec2 describe-images --region $REGION \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

PUB_EC2_ID=$(aws ec2 run-instances --region $REGION \
    --image-id $UBUNTU_AMI --instance-type t2.micro \
    --key-name $KEY_PAIR_NAME \
    --subnet-id $PUB_SUBNET_ID \
    --security-group-ids $PUB_SG_ID \
    --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=devops-pub-ec2}]' \
    --query "Instances[0].InstanceId" --output text)

echo "Instance $PUB_EC2_ID — waiting for status OK..."
aws ec2 wait instance-running   --instance-ids $PUB_EC2_ID --region $REGION
aws ec2 wait instance-status-ok --instance-ids $PUB_EC2_ID --region $REGION

PUB_EC2_PUB_IP=$(aws ec2 describe-instances --instance-ids $PUB_EC2_ID \
    --region $REGION \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
PUB_EC2_PRIV_IP=$(aws ec2 describe-instances --instance-ids $PUB_EC2_ID \
    --region $REGION \
    --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
echo "devops-pub-ec2: pub=$PUB_EC2_PUB_IP  priv=$PUB_EC2_PRIV_IP"

# ============================================================
# STEP 5: PRIVATE S3 BUCKET
# ============================================================

echo ""
echo "=== Step 5: Private S3 bucket '$S3_BUCKET' ==="

aws s3api create-bucket --bucket $S3_BUCKET --region $REGION
aws s3api put-public-access-block --bucket $S3_BUCKET \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "Bucket ready: s3://$S3_BUCKET"

# ============================================================
# STEP 6: IAM ROLE → attach to public EC2
# ManagedPolicyArns only (iam:PutRolePolicy blocked in this lab)
# ============================================================

echo ""
echo "=== Step 6: IAM role '$ROLE_NAME' ==="

aws iam create-role --role-name $ROLE_NAME \
    --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam create-instance-profile \
    --instance-profile-name $ROLE_NAME 2>/dev/null || true
aws iam add-role-to-instance-profile \
    --instance-profile-name $ROLE_NAME --role-name $ROLE_NAME 2>/dev/null || true

echo "Waiting 15s for IAM propagation..."
sleep 15

aws ec2 associate-iam-instance-profile --region $REGION \
    --instance-id $PUB_EC2_ID \
    --iam-instance-profile Name=$ROLE_NAME
echo "IAM role attached to $PUB_EC2_ID"

# ============================================================
# STEP 7: VPC PEERING
# ============================================================

echo ""
echo "=== Step 7: VPC peering 'devops-vpc-peering' ==="

PEER_ID=$(aws ec2 create-vpc-peering-connection --region $REGION \
    --vpc-id $PRIV_VPC_ID --peer-vpc-id $PUB_VPC_ID \
    --tag-specifications 'ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=devops-vpc-peering}]' \
    --query "VpcPeeringConnection.VpcPeeringConnectionId" --output text)

aws ec2 accept-vpc-peering-connection \
    --vpc-peering-connection-id $PEER_ID --region $REGION > /dev/null

echo "Peering $PEER_ID — waiting 10s..."
sleep 10

aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids $PEER_ID --region $REGION \
    --query "VpcPeeringConnections[0].Status.Code" --output text

# ============================================================
# STEP 8: UPDATE BOTH ROUTE TABLES — verify before continuing
# ============================================================

echo ""
echo "=== Step 8: Updating BOTH route tables ==="

aws ec2 create-route --route-table-id $PRIV_RT_ID \
    --destination-cidr-block $PUB_VPC_CIDR \
    --vpc-peering-connection-id $PEER_ID --region $REGION \
    && echo "devops-priv-rt ✅: $PUB_VPC_CIDR → $PEER_ID" \
    || echo "devops-priv-rt: route may already exist"

aws ec2 create-route --route-table-id $PUB_RT_ID \
    --destination-cidr-block $PRIV_VPC_CIDR \
    --vpc-peering-connection-id $PEER_ID --region $REGION \
    && echo "devops-pub-rt  ✅: $PRIV_VPC_CIDR → $PEER_ID" \
    || echo "devops-pub-rt: route may already exist"

echo ""
echo "--- devops-priv-rt ---"
aws ec2 describe-route-tables --route-table-ids $PRIV_RT_ID --region $REGION \
    --query "RouteTables[0].Routes[*].{Dest:DestinationCidrBlock,Peer:VpcPeeringConnectionId,GW:GatewayId,State:State}" \
    --output table

echo "--- devops-pub-rt ---"
aws ec2 describe-route-tables --route-table-ids $PUB_RT_ID --region $REGION \
    --query "RouteTables[0].Routes[*].{Dest:DestinationCidrBlock,Peer:VpcPeeringConnectionId,GW:GatewayId,State:State}" \
    --output table

# ============================================================
# STEP 9: WAIT FOR SSH ON PUBLIC EC2
# ============================================================

echo ""
echo "=== Step 9: Waiting for SSH on $PUB_EC2_PUB_IP ==="

until ssh -i $KEY_FILE -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 ubuntu@$PUB_EC2_PUB_IP \
    "echo ready" 2>/dev/null; do
    echo "  retrying..."
    sleep 5
done
echo "SSH ready on devops-pub-ec2"

# ============================================================
# STEP 10: PREPARE PUBLIC EC2
# ============================================================

echo ""
echo "=== Step 10: Preparing devops-pub-ec2 ==="

scp -i $KEY_FILE -o StrictHostKeyChecking=no \
    $KEY_FILE ubuntu@${PUB_EC2_PUB_IP}:/home/ubuntu/.ssh/devops-key.pem

ssh -i $KEY_FILE -o StrictHostKeyChecking=no ubuntu@$PUB_EC2_PUB_IP << PUBSETUP
chmod 400 /home/ubuntu/.ssh/devops-key.pem
sudo apt-get update -y -q
sudo apt-get install -y -q awscli netcat-openbsd
aws --version
ssh-keyscan -H $PRIV_EC2_IP >> /home/ubuntu/.ssh/known_hosts 2>/dev/null
echo "Public EC2 setup complete"
PUBSETUP

# ============================================================
# STEP 11: FROM INSIDE PUBLIC EC2 — deploy key to private EC2
# Fix: no ProxyJump SCP — SSH in then SCP from inside
# ============================================================

echo ""
echo "=== Step 11: Deploying key to private EC2 from public EC2 ==="

ssh -i $KEY_FILE -o StrictHostKeyChecking=no ubuntu@$PUB_EC2_PUB_IP << JUMP
set -e

echo "Connectivity check to $PRIV_EC2_IP:22..."
nc -z -w5 $PRIV_EC2_IP 22 \
    && echo "Port 22 reachable ✅" \
    || { echo "❌ Port 22 NOT reachable — check peering routes and SG"; exit 1; }

scp -i /home/ubuntu/.ssh/devops-key.pem -o StrictHostKeyChecking=no \
    /home/ubuntu/.ssh/devops-key.pem \
    ubuntu@${PRIV_EC2_IP}:/home/ubuntu/.ssh/devops-key.pem

ssh -i /home/ubuntu/.ssh/devops-key.pem -o StrictHostKeyChecking=no \
    ubuntu@$PRIV_EC2_IP \
    "chmod 400 /home/ubuntu/.ssh/devops-key.pem && echo 'Key on private EC2 ✅'"
JUMP

# ============================================================
# STEP 12: CRON ON PRIVATE EC2
# Inner SSH runs from inside the public EC2
# ============================================================

echo ""
echo "=== Step 12: Cron on devops-priv-ec2 ==="

ssh -i $KEY_FILE -o StrictHostKeyChecking=no ubuntu@$PUB_EC2_PUB_IP << OUTER
ssh -i /home/ubuntu/.ssh/devops-key.pem -o StrictHostKeyChecking=no \
    ubuntu@$PRIV_EC2_IP << INNER
sudo touch /var/log/boots.log
sudo chmod 644 /var/log/boots.log

ssh-keyscan -H $PUB_EC2_PRIV_IP >> ~/.ssh/known_hosts 2>/dev/null

which cron >/dev/null 2>&1 || (sudo apt-get install -y cron -q \
    && sudo systemctl enable cron && sudo systemctl start cron)

CRON="* * * * * /usr/bin/scp -i /home/ubuntu/.ssh/devops-key.pem -o StrictHostKeyChecking=no /var/log/boots.log ubuntu@${PUB_EC2_PRIV_IP}:/home/ubuntu/boots.log >> /home/ubuntu/scp.log 2>&1"
( crontab -l 2>/dev/null | grep -v boots.log; echo "\$CRON" ) | crontab -
echo "Cron on private EC2:"
crontab -l
INNER
OUTER

# ============================================================
# STEP 13: CRON ON PUBLIC EC2
# ============================================================

echo ""
echo "=== Step 13: Cron on devops-pub-ec2 ==="

ssh -i $KEY_FILE -o StrictHostKeyChecking=no ubuntu@$PUB_EC2_PUB_IP << PUBCRON
touch /home/ubuntu/boots.log

CRON="* * * * * /usr/bin/aws s3 cp /home/ubuntu/boots.log s3://${S3_BUCKET}/devops-priv-vpc/boot/boots.log --region ${REGION} >> /home/ubuntu/s3-upload.log 2>&1"
( crontab -l 2>/dev/null | grep -v boots.log; echo "\$CRON" ) | crontab -
echo "Cron on public EC2:"
crontab -l
PUBCRON

# ============================================================
# STEP 14: FIRST UPLOAD — pull REAL boots.log from private EC2
# No placeholder strings — validator checks actual file content
# ============================================================

echo ""
echo "=== Step 14: First upload using REAL boots.log ==="

ssh -i $KEY_FILE -o StrictHostKeyChecking=no ubuntu@$PUB_EC2_PUB_IP << FIRSTUP
set -e

echo "Pulling /var/log/boots.log from private EC2..."
scp -i /home/ubuntu/.ssh/devops-key.pem -o StrictHostKeyChecking=no \
    ubuntu@${PRIV_EC2_IP}:/var/log/boots.log \
    /home/ubuntu/boots.log

echo "File pulled. Size: \$(wc -c < /home/ubuntu/boots.log) bytes"
echo "First line: \$(head -1 /home/ubuntu/boots.log)"

echo "Uploading to S3..."
/usr/bin/aws s3 cp /home/ubuntu/boots.log \
    s3://${S3_BUCKET}/devops-priv-vpc/boot/boots.log \
    --region ${REGION}
echo "S3 upload done ✅"
FIRSTUP

# ============================================================
# STEP 15: VERIFY
# ============================================================

echo ""
echo "=== Step 15: Verification ==="

aws s3 ls s3://${S3_BUCKET}/devops-priv-vpc/boot/ --region $REGION

FOUND=$(aws s3 ls \
    "s3://${S3_BUCKET}/devops-priv-vpc/boot/boots.log" \
    --region $REGION 2>/dev/null || true)

if [ -n "$FOUND" ]; then
    echo "✅ boots.log confirmed in S3: $FOUND"
    aws s3 cp "s3://${S3_BUCKET}/devops-priv-vpc/boot/boots.log" \
        /tmp/boots-check.log --region $REGION
    echo "Content preview:"
    head -5 /tmp/boots-check.log
else
    echo "⚠️  Not in S3 — check IAM role on public EC2"
fi

echo ""
echo "============================================"
echo "  Priv VPC:  devops-priv-vpc ($PRIV_VPC_ID, $PRIV_VPC_CIDR)"
echo "  Pub VPC:   devops-pub-vpc  ($PUB_VPC_ID, $PUB_VPC_CIDR)"
echo "  Peering:   devops-vpc-peering ($PEER_ID)"
echo "  Pub EC2:   $PUB_EC2_PUB_IP / $PUB_EC2_PRIV_IP"
echo "  Priv EC2:  $PRIV_EC2_IP"
echo "  S3:        s3://$S3_BUCKET/devops-priv-vpc/boot/boots.log"
echo "  IAM Role:  $ROLE_NAME"
echo ""
echo "  Cron pipeline (runs every minute):"
echo "  private-ec2 → scp → public-ec2 → aws s3 cp → S3"
echo "============================================"

# ============================================================
# TROUBLESHOOTING
# ============================================================

# Check peering status:
# aws ec2 describe-vpc-peering-connections \
#     --filters "Name=tag:Name,Values=devops-vpc-peering" --region us-east-1 \
#     --query "VpcPeeringConnections[0].Status.Code"

# Test port 22 reachability from public EC2 to private EC2:
# ssh -i $KEY_FILE ubuntu@$PUB_EC2_PUB_IP "nc -z -w5 $PRIV_EC2_IP 22 && echo ok"

# Check SCP cron log on private EC2:
# ssh -i $KEY_FILE ubuntu@$PUB_EC2_PUB_IP \
#     "ssh -i ~/.ssh/devops-key.pem ubuntu@$PRIV_EC2_IP 'cat ~/scp.log'"

# Check S3 upload log on public EC2:
# ssh -i $KEY_FILE ubuntu@$PUB_EC2_PUB_IP "cat ~/s3-upload.log"

# ============================================================
# CLEANUP
# ============================================================

# aws autoscaling delete-auto-scaling-group ... (if any)
# aws ec2 terminate-instances --instance-ids $PUB_EC2_ID --region $REGION
# aws s3 rm s3://$S3_BUCKET --recursive --region $REGION
# aws s3api delete-bucket --bucket $S3_BUCKET --region $REGION
# aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id $PEER_ID --region $REGION
# aws ec2 delete-route-table --route-table-id $PUB_RT_ID --region $REGION
# aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $PUB_VPC_ID --region $REGION
# aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION
# aws ec2 delete-subnet --subnet-id $PUB_SUBNET_ID --region $REGION
# aws ec2 delete-vpc --vpc-id $PUB_VPC_ID --region $REGION
