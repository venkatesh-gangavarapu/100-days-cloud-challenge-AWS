#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 01: Creating an AWS EC2 Key Pair
# ============================================================

# --- PREREQUISITES ---
# AWS CLI v2 installed and configured
# aws configure  →  Access Key, Secret Key, Region, Output format

# Verify you're authenticated as the correct IAM user (not root)
aws sts get-caller-identity

# ============================================================
# CREATE KEY PAIR — AWS CLI
# ============================================================

# Create ED25519 key pair and save private key to .pem file
aws ec2 create-key-pair \
    --key-name my-aws-keypair \
    --key-type ed25519 \
    --key-format pem \
    --query "KeyMaterial" \
    --output text > ~/.ssh/my-aws-keypair.pem

# Set correct permissions on the private key (mandatory for SSH)
chmod 400 ~/.ssh/my-aws-keypair.pem

# ============================================================
# VERIFY
# ============================================================

# List all key pairs in the current region
aws ec2 describe-key-pairs

# Describe a specific key pair
aws ec2 describe-key-pairs --key-names my-aws-keypair

# Check the fingerprint of the local private key file
ssh-keygen -l -f ~/.ssh/my-aws-keypair.pem

# Confirm file permissions are set correctly
ls -l ~/.ssh/my-aws-keypair.pem
# Expected: -r-------- (400)

# ============================================================
# SSH INTO AN EC2 INSTANCE (once one is launched)
# ============================================================

# Replace <PUBLIC_IP> with your instance's public IP address
# Amazon Linux 2 / Amazon Linux 2023
ssh -i ~/.ssh/my-aws-keypair.pem ec2-user@<PUBLIC_IP>

# Ubuntu
# ssh -i ~/.ssh/my-aws-keypair.pem ubuntu@<PUBLIC_IP>

# RHEL / CentOS
# ssh -i ~/.ssh/my-aws-keypair.pem ec2-user@<PUBLIC_IP>

# ============================================================
# CLEANUP (run only when done with the key pair)
# ============================================================

# Delete the key pair from AWS
aws ec2 delete-key-pair --key-name my-aws-keypair

# Remove the local private key
rm ~/.ssh/my-aws-keypair.pem
