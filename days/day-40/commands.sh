#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 40: Troubleshooting VPC Internet Connectivity
# VPC: datacenter-vpc | EC2: datacenter-ec2 | Region: us-east-1
# Diagnoses and fixes: missing IGW, missing route, missing public IP,
# restrictive NACL — the layers above the (already-correct) security group
# ============================================================

set -e
REGION="us-east-1"

# ============================================================
# STEP 1: RESOLVE VPC, INSTANCE, AND SUBNET
# ============================================================

echo "=== Step 1: Resolving resources ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=tag:Name,Values=datacenter-vpc" \
    --query "Vpcs[0].VpcId" --output text)

INSTANCE_ID=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=datacenter-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

SUBNET_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
    --query "Reservations[0].Instances[0].SubnetId" --output text)

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "VPC:        $VPC_ID"
echo "Instance:   $INSTANCE_ID"
echo "Subnet:     $SUBNET_ID"
echo "Public IP:  $PUBLIC_IP"

# ============================================================
# STEP 2: DIAGNOSTIC + FIX — Internet Gateway
# ============================================================

echo ""
echo "=== Step 2: Checking Internet Gateway attachment ==="

IGW_ID=$(aws ec2 describe-internet-gateways --region $REGION \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query "InternetGateways[0].InternetGatewayId" --output text)

if [ -z "$IGW_ID" ] || [ "$IGW_ID" == "None" ]; then
    echo "❌ ISSUE FOUND: No Internet Gateway attached to $VPC_ID"
    echo "Creating and attaching a new IGW..."

    IGW_ID=$(aws ec2 create-internet-gateway --region $REGION \
        --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=datacenter-igw}]' \
        --query "InternetGateway.InternetGatewayId" --output text)

    aws ec2 attach-internet-gateway \
        --internet-gateway-id $IGW_ID \
        --vpc-id $VPC_ID --region $REGION

    echo "✅ FIXED: $IGW_ID created and attached to $VPC_ID"
else
    # Confirm it's actually attached (not just existing somewhere)
    ATTACH_STATE=$(aws ec2 describe-internet-gateways --internet-gateway-ids $IGW_ID --region $REGION \
        --query "InternetGateways[0].Attachments[0].State" --output text)
    echo "✅ IGW found: $IGW_ID (state: $ATTACH_STATE)"
fi

# ============================================================
# STEP 3: DIAGNOSTIC + FIX — Route Table
# ============================================================

echo ""
echo "=== Step 3: Checking route table for IGW route ==="

# Check for explicit subnet association first
RT_ID=$(aws ec2 describe-route-tables --region $REGION \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query "RouteTables[0].RouteTableId" --output text)

if [ -z "$RT_ID" ] || [ "$RT_ID" == "None" ]; then
    echo "Subnet has no explicit association — checking VPC main route table"
    RT_ID=$(aws ec2 describe-route-tables --region $REGION \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
        --query "RouteTables[0].RouteTableId" --output text)
fi

echo "Route table in effect for this subnet: $RT_ID"

echo "Current routes:"
aws ec2 describe-route-tables --route-table-ids $RT_ID --region $REGION \
    --query "RouteTables[0].Routes[*].{Dest:DestinationCidrBlock,Target:GatewayId,State:State}" \
    --output table

HAS_IGW_ROUTE=$(aws ec2 describe-route-tables --route-table-ids $RT_ID --region $REGION \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && GatewayId=='${IGW_ID}'].State" \
    --output text)

if [ -z "$HAS_IGW_ROUTE" ]; then
    echo "❌ ISSUE FOUND: No 0.0.0.0/0 → $IGW_ID route in $RT_ID"
    echo "Adding the missing route..."

    aws ec2 create-route \
        --route-table-id $RT_ID \
        --destination-cidr-block 0.0.0.0/0 \
        --gateway-id $IGW_ID \
        --region $REGION

    echo "✅ FIXED: Added 0.0.0.0/0 → $IGW_ID to $RT_ID"
else
    echo "✅ Route already present: 0.0.0.0/0 → $IGW_ID (state: $HAS_IGW_ROUTE)"
fi

# ============================================================
# STEP 4: DIAGNOSTIC + FIX — Public IP Assignment
# ============================================================

echo ""
echo "=== Step 4: Checking public IP assignment ==="

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" == "None" ]; then
    echo "❌ ISSUE FOUND: Instance has no public IP"
    echo "Allocating and associating an Elastic IP..."

    ALLOC_ID=$(aws ec2 allocate-address --domain vpc --region $REGION \
        --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=datacenter-ec2-eip}]' \
        --query "AllocationId" --output text)

    aws ec2 associate-address \
        --instance-id $INSTANCE_ID \
        --allocation-id $ALLOC_ID \
        --region $REGION

    sleep 5
    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
        --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

    echo "✅ FIXED: Elastic IP $PUBLIC_IP associated with $INSTANCE_ID"
else
    echo "✅ Instance already has public IP: $PUBLIC_IP"
fi

# ============================================================
# STEP 5: DIAGNOSTIC — Network ACL (manual review required)
# NACLs are stateless — both inbound AND outbound rules matter
# ============================================================

echo ""
echo "=== Step 5: Reviewing Network ACL ==="

NACL_ID=$(aws ec2 describe-network-acls --region $REGION \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query "NetworkAcls[0].NetworkAclId" --output text)

echo "NACL associated with subnet: $NACL_ID"

echo ""
echo "--- Inbound rules ---"
aws ec2 describe-network-acls --network-acl-ids $NACL_ID --region $REGION \
    --query "NetworkAcls[0].Entries[?Egress==\`false\`].{Rule:RuleNumber,Protocol:Protocol,Port:PortRange,CIDR:CidrBlock,Action:RuleAction}" \
    --output table

echo "--- Outbound rules ---"
aws ec2 describe-network-acls --network-acl-ids $NACL_ID --region $REGION \
    --query "NetworkAcls[0].Entries[?Egress==\`true\`].{Rule:RuleNumber,Protocol:Protocol,Port:PortRange,CIDR:CidrBlock,Action:RuleAction}" \
    --output table

echo ""
echo "⚠️  MANUAL CHECK: confirm inbound allows port 80 from 0.0.0.0/0"
echo "⚠️  MANUAL CHECK: confirm outbound allows ephemeral ports 1024-65535 to 0.0.0.0/0"
echo "    (the default NACL allows all traffic both ways — flag if this is a custom NACL"
echo "     missing the outbound ephemeral port range, which silently drops return traffic)"

# ============================================================
# STEP 6: SANITY CHECK — Security Group (already confirmed OK per task)
# ============================================================

echo ""
echo "=== Step 6: Confirming security group (sanity check only) ==="

SG_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

echo "Security group: $SG_ID"
aws ec2 describe-security-groups --group-ids $SG_ID --region $REGION \
    --query "SecurityGroups[0].IpPermissions[?ToPort==\`80\`]" --output table

# ============================================================
# STEP 7: VERIFY NGINX IS RUNNING (via SSM, no SSH needed)
# ============================================================

echo ""
echo "=== Step 7: Verifying Nginx is running ==="

CMD_ID=$(aws ssm send-command --region $REGION \
    --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["systemctl is-active nginx || echo NOT_RUNNING","curl -s -o /dev/null -w \"local-curl:%{http_code}\n\" http://localhost"]' \
    --query "Command.CommandId" --output text 2>/dev/null || echo "")

if [ -n "$CMD_ID" ]; then
    sleep 10
    aws ssm get-command-invocation \
        --command-id $CMD_ID --instance-id $INSTANCE_ID --region $REGION \
        --query "StandardOutputContent" --output text 2>/dev/null || echo "Could not retrieve SSM output"
else
    echo "SSM unavailable — verify manually via EC2 Instance Connect:"
    echo "  systemctl status nginx"
fi

# ============================================================
# STEP 8: FINAL VERIFICATION — Test from outside the VPC
# ============================================================

echo ""
echo "=== Step 8: Testing external connectivity ==="

sleep 5
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://$PUBLIC_IP" 2>/dev/null || echo "000")

echo "HTTP Status from http://$PUBLIC_IP : $HTTP_STATUS"

if [ "$HTTP_STATUS" == "200" ]; then
    echo ""
    echo "✅✅✅ SUCCESS: datacenter-ec2 is now reachable from the internet on port 80"
else
    echo ""
    echo "⚠️  Still not reachable (HTTP $HTTP_STATUS). Remaining things to check manually:"
    echo "    - NACL outbound ephemeral port range (1024-65535)"
    echo "    - Is Nginx actually running? (see Step 7 output)"
    echo "    - Try: aws ec2 describe-network-interfaces --filters Name=attachment.instance-id,Values=$INSTANCE_ID"
fi

echo ""
echo "============================================"
echo "  VPC:          $VPC_ID"
echo "  IGW:          $IGW_ID"
echo "  Route Table:  $RT_ID"
echo "  Instance:     $INSTANCE_ID"
echo "  Public IP:    $PUBLIC_IP"
echo "  NACL:         $NACL_ID"
echo "  Test URL:     http://$PUBLIC_IP"
echo "============================================"
