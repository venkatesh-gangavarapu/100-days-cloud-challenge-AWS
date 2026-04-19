#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 03: Creating a Subnet in AWS VPC
# ============================================================

# Replace placeholders: <VPC_ID>, <SUBNET_ID>, <IGW_ID>, <RT_ID>

# ============================================================
# LOOKUP REQUIRED VALUES
# ============================================================

# Get default VPC ID
aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text

# List Availability Zones in your region
aws ec2 describe-availability-zones \
    --query "AvailabilityZones[*].ZoneName" \
    --output table

# ============================================================
# CREATE SUBNETS
# ============================================================

# Public subnet — AZ-a
aws ec2 create-subnet \
    --vpc-id <VPC_ID> \
    --cidr-block 10.0.1.0/24 \
    --availability-zone us-east-1a \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-subnet-1a},{Key=Type,Value=Public}]'

# Private subnet — AZ-a
aws ec2 create-subnet \
    --vpc-id <VPC_ID> \
    --cidr-block 10.0.11.0/24 \
    --availability-zone us-east-1a \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-subnet-1a},{Key=Type,Value=Private}]'

# Public subnet — AZ-b
aws ec2 create-subnet \
    --vpc-id <VPC_ID> \
    --cidr-block 10.0.2.0/24 \
    --availability-zone us-east-1b \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-subnet-1b},{Key=Type,Value=Public}]'

# Private subnet — AZ-b
aws ec2 create-subnet \
    --vpc-id <VPC_ID> \
    --cidr-block 10.0.12.0/24 \
    --availability-zone us-east-1b \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-subnet-1b},{Key=Type,Value=Private}]'

# ============================================================
# ENABLE AUTO-ASSIGN PUBLIC IP ON PUBLIC SUBNETS
# ============================================================

aws ec2 modify-subnet-attribute \
    --subnet-id <PUBLIC_SUBNET_1A_ID> \
    --map-public-ip-on-launch

aws ec2 modify-subnet-attribute \
    --subnet-id <PUBLIC_SUBNET_1B_ID> \
    --map-public-ip-on-launch

# ============================================================
# INTERNET GATEWAY — Required for public subnets
# ============================================================

# Create Internet Gateway
aws ec2 create-internet-gateway \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=my-igw}]'

# Attach IGW to VPC
aws ec2 attach-internet-gateway \
    --internet-gateway-id <IGW_ID> \
    --vpc-id <VPC_ID>

# ============================================================
# ROUTE TABLE — Wire public subnets to the IGW
# ============================================================

# Create public route table
aws ec2 create-route-table \
    --vpc-id <VPC_ID> \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=public-rt}]'

# Add default route to IGW
aws ec2 create-route \
    --route-table-id <RT_ID> \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id <IGW_ID>

# Associate public subnets with the public route table
aws ec2 associate-route-table \
    --route-table-id <RT_ID> \
    --subnet-id <PUBLIC_SUBNET_1A_ID>

aws ec2 associate-route-table \
    --route-table-id <RT_ID> \
    --subnet-id <PUBLIC_SUBNET_1B_ID>

# ============================================================
# VERIFY
# ============================================================

# List all subnets in VPC with key details
aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=<VPC_ID>" \
    --query "Subnets[*].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,Name:Tags[?Key=='Name']|[0].Value,PublicIP:MapPublicIpOnLaunch}" \
    --output table

# Verify route table associations
aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=<VPC_ID>" \
    --query "RouteTables[*].{ID:RouteTableId,Routes:Routes,Associations:Associations}" \
    --output json

# ============================================================
# OPTIONAL — EKS subnet tags (required if using EKS later)
# ============================================================

# Tag public subnets for external load balancers
aws ec2 create-tags \
    --resources <PUBLIC_SUBNET_1A_ID> <PUBLIC_SUBNET_1B_ID> \
    --tags Key=kubernetes.io/role/elb,Value=1

# Tag private subnets for internal load balancers
aws ec2 create-tags \
    --resources <PRIVATE_SUBNET_1A_ID> <PRIVATE_SUBNET_1B_ID> \
    --tags Key=kubernetes.io/role/internal-elb,Value=1

# ============================================================
# CLEANUP
# ============================================================

# Delete subnet (must have no running resources)
aws ec2 delete-subnet --subnet-id <SUBNET_ID>

# Detach and delete IGW
aws ec2 detach-internet-gateway \
    --internet-gateway-id <IGW_ID> --vpc-id <VPC_ID>
aws ec2 delete-internet-gateway --internet-gateway-id <IGW_ID>

# Delete route table (must disassociate subnets first)
aws ec2 delete-route-table --route-table-id <RT_ID>
