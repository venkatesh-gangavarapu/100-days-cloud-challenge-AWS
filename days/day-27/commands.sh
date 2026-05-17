#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 27: Custom Public VPC + Subnet + EC2 Instance
# VPC: devops-pub-vpc | Subnet: devops-pub-subnet | EC2: devops-pub-ec2
# Region: us-east-1
# ============================================================

REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
SUBNET_AZ="us-east-1a"

# ============================================================
# STEP 1: CREATE THE VPC
# ============================================================

echo "=== Step 1: Creating VPC 'devops-pub-vpc' ==="

VPC_ID=$(aws ec2 create-vpc \
    --region "$REGION" \
    --cidr-block "$VPC_CIDR" \
    --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=devops-pub-vpc}]' \
    --query "Vpc.VpcId" \
    --output text)

echo "VPC created: $VPC_ID"

# Enable DNS hostnames so instances get public DNS names
aws ec2 modify-vpc-attribute \
    --vpc-id "$VPC_ID" \
    --enable-dns-hostnames \
    --region "$REGION"

# Enable DNS support (required for DNS resolution within VPC)
aws ec2 modify-vpc-attribute \
    --vpc-id "$VPC_ID" \
    --enable-dns-support \
    --region "$REGION"

echo "DNS hostnames and DNS support enabled"

# Verify VPC state
aws ec2 describe-vpcs \
    --vpc-ids "$VPC_ID" --region "$REGION" \
    --query "Vpcs[0].{CIDR:CidrBlock,State:State,ID:VpcId}" \
    --output table

# ============================================================
# STEP 2: CREATE THE PUBLIC SUBNET
# ============================================================

echo ""
echo "=== Step 2: Creating subnet 'devops-pub-subnet' ==="

SUBNET_ID=$(aws ec2 create-subnet \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --cidr-block "$SUBNET_CIDR" \
    --availability-zone "$SUBNET_AZ" \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=devops-pub-subnet},{Key=Type,Value=Public}]' \
    --query "Subnet.SubnetId" \
    --output text)

echo "Subnet created: $SUBNET_ID"

# ============================================================
# STEP 3: ENABLE AUTO-ASSIGN PUBLIC IP ON THE SUBNET
# ============================================================

echo ""
echo "=== Step 3: Enabling auto-assign public IP ==="

aws ec2 modify-subnet-attribute \
    --subnet-id "$SUBNET_ID" \
    --map-public-ip-on-launch \
    --region "$REGION"

echo "Auto-assign public IP enabled on $SUBNET_ID"

# Verify auto-assign is on
aws ec2 describe-subnets \
    --subnet-ids "$SUBNET_ID" --region "$REGION" \
    --query "Subnets[0].{CIDR:CidrBlock,AZ:AvailabilityZone,AutoAssignIP:MapPublicIpOnLaunch,ID:SubnetId}" \
    --output table

# ============================================================
# STEP 4: CREATE INTERNET GATEWAY
# ============================================================

echo ""
echo "=== Step 4: Creating Internet Gateway ==="

IGW_ID=$(aws ec2 create-internet-gateway \
    --region "$REGION" \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=devops-pub-igw}]' \
    --query "InternetGateway.InternetGatewayId" \
    --output text)

echo "Internet Gateway created: $IGW_ID"

# ============================================================
# STEP 5: ATTACH IGW TO THE VPC
# ============================================================

echo ""
echo "=== Step 5: Attaching IGW to VPC ==="

aws ec2 attach-internet-gateway \
    --region "$REGION" \
    --internet-gateway-id "$IGW_ID" \
    --vpc-id "$VPC_ID"

echo "IGW $IGW_ID attached to VPC $VPC_ID"

# Verify IGW is attached
aws ec2 describe-internet-gateways \
    --internet-gateway-ids "$IGW_ID" --region "$REGION" \
    --query "InternetGateways[0].{ID:InternetGatewayId,VPC:Attachments[0].VpcId,State:Attachments[0].State}" \
    --output table

# ============================================================
# STEP 6: CREATE A PUBLIC ROUTE TABLE
# ============================================================

echo ""
echo "=== Step 6: Creating public route table ==="

RT_ID=$(aws ec2 create-route-table \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=devops-pub-rt}]' \
    --query "RouteTable.RouteTableId" \
    --output text)

echo "Route Table created: $RT_ID"

# ============================================================
# STEP 7: ADD DEFAULT ROUTE — 0.0.0.0/0 → IGW
# ============================================================

echo ""
echo "=== Step 7: Adding internet route to route table ==="

aws ec2 create-route \
    --region "$REGION" \
    --route-table-id "$RT_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$IGW_ID"

echo "Route 0.0.0.0/0 → $IGW_ID added to $RT_ID"

# ============================================================
# STEP 8: ASSOCIATE THE PUBLIC SUBNET WITH THE ROUTE TABLE
# ============================================================

echo ""
echo "=== Step 8: Associating subnet with public route table ==="

ASSOC_ID=$(aws ec2 associate-route-table \
    --region "$REGION" \
    --route-table-id "$RT_ID" \
    --subnet-id "$SUBNET_ID" \
    --query "AssociationId" \
    --output text)

echo "Association ID: $ASSOC_ID"

# Verify the route table has the correct routes
echo "=== Route Table Routes ==="
aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" --region "$REGION" \
    --query "RouteTables[0].Routes[*].{Destination:DestinationCidrBlock,Target:GatewayId,State:State}" \
    --output table

# ============================================================
# STEP 9: CREATE SECURITY GROUP — SSH PORT 22 FROM INTERNET
# ============================================================

echo ""
echo "=== Step 9: Creating security group with SSH access ==="

SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name devops-pub-sg \
    --description "devops-pub-ec2 — allow SSH port 22 from internet" \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=devops-pub-sg}]' \
    --query "GroupId" \
    --output text)

echo "Security Group created: $SG_ID"

# Allow SSH inbound from internet
aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0

echo "Inbound rule: TCP port 22 from 0.0.0.0/0 added"

# ============================================================
# STEP 10: RESOLVE LATEST UBUNTU 22.04 AMI
# ============================================================

echo ""
echo "=== Step 10: Resolving Ubuntu 22.04 AMI ==="

AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "Ubuntu 22.04 AMI: $AMI_ID"

# ============================================================
# STEP 11: LAUNCH THE EC2 INSTANCE IN THE CUSTOM VPC
# ============================================================

echo ""
echo "=== Step 11: Launching 'devops-pub-ec2' ==="

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --tag-specifications \
        'ResourceType=instance,Tags=[{Key=Name,Value=devops-pub-ec2}]' \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Instance launched: $INSTANCE_ID"

# ============================================================
# STEP 12: WAIT AND VERIFY
# ============================================================

echo ""
echo "=== Step 12: Waiting for instance to be running ==="

aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Instance is running"

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

PUBLIC_DNS=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicDnsName" \
    --output text)

echo ""
echo "=== Full Stack Summary ==="
echo ""
echo "--- VPC ---"
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
    --query "Vpcs[0].{Name:Tags[?Key=='Name']|[0].Value,CIDR:CidrBlock,ID:VpcId,State:State}" \
    --output table

echo ""
echo "--- Subnet ---"
aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --region "$REGION" \
    --query "Subnets[0].{Name:Tags[?Key=='Name']|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone,AutoIP:MapPublicIpOnLaunch}" \
    --output table

echo ""
echo "--- EC2 Instance ---"
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,State:State.Name,Type:InstanceType,PublicIP:PublicIpAddress,VPC:VpcId,Subnet:SubnetId}" \
    --output table

echo ""
echo "============================================"
echo "  VPC:         devops-pub-vpc  ($VPC_ID)"
echo "  Subnet:      devops-pub-subnet ($SUBNET_ID)"
echo "  IGW:         devops-pub-igw  ($IGW_ID)"
echo "  Route Table: devops-pub-rt   ($RT_ID)"
echo "  SG:          devops-pub-sg   ($SG_ID)"
echo "  Instance:    devops-pub-ec2  ($INSTANCE_ID)"
echo "  Public IP:   $PUBLIC_IP"
echo "  Public DNS:  $PUBLIC_DNS"
echo "  SSH:         ssh ubuntu@$PUBLIC_IP"
echo "============================================"

# Test SSH port reachability
echo ""
echo "=== Port 22 reachability check ==="
nc -zvw5 "$PUBLIC_IP" 22 \
    && echo "✅ Port 22 is open on $PUBLIC_IP" \
    || echo "⚠️  Port 22 check failed — instance may still be initializing"

# ============================================================
# CLEANUP (strict order — comment out to preserve resources)
# ============================================================

# echo "=== Cleanup ==="
# aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
# aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
# aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION"
# aws ec2 delete-route-table --route-table-id "$RT_ID" --region "$REGION"
# aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
# aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION"
# aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$REGION"
# aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
# echo "All resources deleted"
