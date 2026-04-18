#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 02: Creating an AWS Security Group
# ============================================================

# --- PREREQUISITES ---
# AWS CLI v2 installed and configured
# Replace placeholders: <YOUR_VPC_ID>, <SG_ID>, <YOUR_IP>

# ============================================================
# LOOKUP REQUIRED VALUES
# ============================================================

# Get your default VPC ID
aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text

# Get your current public IP
curl -s https://checkip.amazonaws.com

# ============================================================
# CREATE SECURITY GROUP
# ============================================================

aws ec2 create-security-group \
    --group-name web-server-sg \
    --description "Allow HTTP, HTTPS, and SSH for web servers" \
    --vpc-id <YOUR_VPC_ID> \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=web-server-sg}]'

# Note the GroupId from the output — e.g., sg-0abc1234def567890

# ============================================================
# ADD INBOUND RULES
# ============================================================

# SSH — restricted to your IP only (never open to 0.0.0.0/0)
aws ec2 authorize-security-group-ingress \
    --group-id <SG_ID> \
    --protocol tcp \
    --port 22 \
    --cidr <YOUR_IP>/32

# HTTP — public web traffic
aws ec2 authorize-security-group-ingress \
    --group-id <SG_ID> \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

# HTTPS — public HTTPS traffic
aws ec2 authorize-security-group-ingress \
    --group-id <SG_ID> \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0

# Custom app port (e.g., Node.js / Flask on 8080)
aws ec2 authorize-security-group-ingress \
    --group-id <SG_ID> \
    --protocol tcp \
    --port 8080 \
    --cidr 0.0.0.0/0

# Allow from another security group (e.g., DB allowing only app tier)
aws ec2 authorize-security-group-ingress \
    --group-id <DB_SG_ID> \
    --protocol tcp \
    --port 5432 \
    --source-group <APP_SG_ID>

# ============================================================
# VERIFY
# ============================================================

# Describe a specific security group and its rules
aws ec2 describe-security-groups --group-ids <SG_ID>

# List all security groups in the region (table view)
aws ec2 describe-security-groups \
    --query "SecurityGroups[*].{Name:GroupName,ID:GroupId,VPC:VpcId}" \
    --output table

# Filter by name
aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=web-server-sg"

# ============================================================
# SECURITY AUDIT — Find port 22 open to the world
# ============================================================

aws ec2 describe-security-groups \
    --filters "Name=ip-permission.from-port,Values=22" \
              "Name=ip-permission.to-port,Values=22" \
              "Name=ip-permission.cidr,Values=0.0.0.0/0" \
    --query "SecurityGroups[*].{Name:GroupName,ID:GroupId,VPC:VpcId}" \
    --output table

# ============================================================
# MODIFY RULES
# ============================================================

# Remove a specific inbound rule
aws ec2 revoke-security-group-ingress \
    --group-id <SG_ID> \
    --protocol tcp \
    --port 8080 \
    --cidr 0.0.0.0/0

# Safe way to restrict SSH (add new rule FIRST, then remove the open one)
# Step 1: Add restricted rule
aws ec2 authorize-security-group-ingress \
    --group-id <SG_ID> \
    --protocol tcp \
    --port 22 \
    --cidr <OFFICE_IP>/32

# Step 2: Remove the old open rule
aws ec2 revoke-security-group-ingress \
    --group-id <SG_ID> \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0

# ============================================================
# CLEANUP
# ============================================================

# Delete security group (must be detached from all instances first)
aws ec2 delete-security-group --group-id <SG_ID>
