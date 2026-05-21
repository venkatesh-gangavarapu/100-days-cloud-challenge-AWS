#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 29: VPC Peering — Default VPC ↔ datacenter-private-vpc
# Peering: datacenter-vpc-peering | Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"

# ============================================================
# STEP 1: DISCOVER ALL EXISTING RESOURCE IDs
# ============================================================

echo "=== Step 1: Discovering existing resources ==="

# --- Default (Public) VPC ---
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

DEFAULT_VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$DEFAULT_VPC_ID" \
    --region "$REGION" \
    --query "Vpcs[0].CidrBlock" --output text)

echo "Default VPC: $DEFAULT_VPC_ID | CIDR: $DEFAULT_VPC_CIDR"

# --- Private VPC ---
PRIVATE_VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=datacenter-private-vpc" \
    --query "Vpcs[0].VpcId" --output text)

PRIVATE_VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$PRIVATE_VPC_ID" \
    --region "$REGION" \
    --query "Vpcs[0].CidrBlock" --output text)

echo "Private VPC: $PRIVATE_VPC_ID | CIDR: $PRIVATE_VPC_CIDR"

# --- Public EC2 ---
PUBLIC_EC2_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters \
        "Name=tag:Name,Values=datacenter-public-ec2" \
        "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

PUBLIC_EC2_IP=$(aws ec2 describe-instances \
    --instance-ids "$PUBLIC_EC2_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

PUBLIC_EC2_PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids "$PUBLIC_EC2_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)

PUBLIC_EC2_SG=$(aws ec2 describe-instances \
    --instance-ids "$PUBLIC_EC2_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

echo "Public EC2: $PUBLIC_EC2_ID | Public: $PUBLIC_EC2_IP | Private: $PUBLIC_EC2_PRIVATE_IP | SG: $PUBLIC_EC2_SG"

# --- Private EC2 ---
PRIVATE_EC2_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters \
        "Name=tag:Name,Values=datacenter-private-ec2" \
        "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

PRIVATE_EC2_IP=$(aws ec2 describe-instances \
    --instance-ids "$PRIVATE_EC2_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)

PRIVATE_EC2_SG=$(aws ec2 describe-instances \
    --instance-ids "$PRIVATE_EC2_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

echo "Private EC2: $PRIVATE_EC2_ID | Private IP: $PRIVATE_EC2_IP | SG: $PRIVATE_EC2_SG"

echo ""
echo "--- Resource Summary ---"
echo "  Default VPC:     $DEFAULT_VPC_ID ($DEFAULT_VPC_CIDR)"
echo "  Private VPC:     $PRIVATE_VPC_ID ($PRIVATE_VPC_CIDR)"
echo "  Public EC2:      $PUBLIC_EC2_ID ($PUBLIC_EC2_IP)"
echo "  Private EC2:     $PRIVATE_EC2_ID ($PRIVATE_EC2_IP)"

# ============================================================
# STEP 2: CREATE VPC PEERING CONNECTION
# Requester: Default VPC | Accepter: Private VPC
# ============================================================

echo ""
echo "=== Step 2: Creating VPC Peering Connection 'datacenter-vpc-peering' ==="

PCX_ID=$(aws ec2 create-vpc-peering-connection \
    --region "$REGION" \
    --vpc-id "$DEFAULT_VPC_ID" \
    --peer-vpc-id "$PRIVATE_VPC_ID" \
    --tag-specifications \
        'ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=datacenter-vpc-peering}]' \
    --query "VpcPeeringConnection.VpcPeeringConnectionId" \
    --output text)

echo "Peering Connection: $PCX_ID (status: pending-acceptance)"

# ============================================================
# STEP 3: ACCEPT THE PEERING CONNECTION
# Same account — can accept immediately
# ============================================================

echo ""
echo "=== Step 3: Accepting Peering Connection ==="

aws ec2 accept-vpc-peering-connection \
    --vpc-peering-connection-id "$PCX_ID" \
    --region "$REGION"

echo "Peering connection accepted"

# Poll until active
echo "Waiting for peering to become active..."
for i in 1 2 3 4 5; do
    STATUS=$(aws ec2 describe-vpc-peering-connections \
        --vpc-peering-connection-ids "$PCX_ID" --region "$REGION" \
        --query "VpcPeeringConnections[0].Status.Code" --output text)
    echo "  Status: $STATUS"
    [ "$STATUS" == "active" ] && break
    sleep 5
done

# Verify
aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids "$PCX_ID" --region "$REGION" \
    --query "VpcPeeringConnections[0].{Name:Tags[?Key=='Name']|[0].Value,ID:VpcPeeringConnectionId,Status:Status.Code,RequesterCIDR:RequesterVpcInfo.CidrBlock,AccepterCIDR:AccepterVpcInfo.CidrBlock}" \
    --output table

# ============================================================
# STEP 4: UPDATE DEFAULT VPC ROUTE TABLE
# Add: private VPC CIDR → peering connection
# ============================================================

echo ""
echo "=== Step 4: Updating Default VPC route table ==="

DEFAULT_RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters \
        "Name=vpc-id,Values=${DEFAULT_VPC_ID}" \
        "Name=association.main,Values=true" \
    --query "RouteTables[0].RouteTableId" --output text)

echo "Default VPC main RT: $DEFAULT_RT_ID"

aws ec2 create-route \
    --route-table-id "$DEFAULT_RT_ID" \
    --destination-cidr-block "$PRIVATE_VPC_CIDR" \
    --vpc-peering-connection-id "$PCX_ID" \
    --region "$REGION"

echo "Route added: $PRIVATE_VPC_CIDR → $PCX_ID"

# ============================================================
# STEP 5: UPDATE PRIVATE VPC ROUTE TABLE
# Add: default VPC CIDR → peering connection
# ============================================================

echo ""
echo "=== Step 5: Updating Private VPC route table ==="

# Check main route table first
PRIVATE_RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters \
        "Name=vpc-id,Values=${PRIVATE_VPC_ID}" \
        "Name=association.main,Values=true" \
    --query "RouteTables[0].RouteTableId" --output text)

# Also check if private subnet has its own route table
PRIVATE_SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=tag:Name,Values=datacenter-private-subnet" \
    --query "Subnets[0].SubnetId" --output text)

SUBNET_RT=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=association.subnet-id,Values=${PRIVATE_SUBNET_ID}" \
    --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || echo "None")

# Use subnet-specific RT if it exists, otherwise use main RT
if [ "$SUBNET_RT" != "None" ] && [ -n "$SUBNET_RT" ]; then
    EFFECTIVE_PRIVATE_RT="$SUBNET_RT"
    echo "Private subnet has its own route table: $SUBNET_RT"
else
    EFFECTIVE_PRIVATE_RT="$PRIVATE_RT_ID"
    echo "Private subnet uses main route table: $PRIVATE_RT_ID"
fi

aws ec2 create-route \
    --route-table-id "$EFFECTIVE_PRIVATE_RT" \
    --destination-cidr-block "$DEFAULT_VPC_CIDR" \
    --vpc-peering-connection-id "$PCX_ID" \
    --region "$REGION"

echo "Route added: $DEFAULT_VPC_CIDR → $PCX_ID"

# ============================================================
# STEP 6: UPDATE PRIVATE EC2 SECURITY GROUP
# Allow ICMP (ping) from default VPC CIDR
# ============================================================

echo ""
echo "=== Step 6: Updating private EC2 SG to allow ICMP from default VPC ==="

aws ec2 authorize-security-group-ingress \
    --group-id "$PRIVATE_EC2_SG" \
    --region "$REGION" \
    --protocol icmp \
    --port -1 \
    --cidr "$DEFAULT_VPC_CIDR"

echo "ICMP allowed from $DEFAULT_VPC_CIDR on private EC2 SG ($PRIVATE_EC2_SG)"

# ============================================================
# STEP 7: INJECT SSH PUBLIC KEY INTO PUBLIC EC2
# ============================================================

echo ""
echo "=== Step 7: Setting up SSH access to public EC2 ==="

# Ensure SSH key exists on aws-client
if [ ! -f /root/.ssh/id_rsa ]; then
    echo "Generating SSH key..."
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -C "root@aws-client"
fi
chmod 600 /root/.ssh/id_rsa

PUB_KEY=$(cat /root/.ssh/id_rsa.pub)

# Ensure port 22 is open on public EC2's security group
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "Adding SSH rule for $MY_IP/32 on public EC2 SG ($PUBLIC_EC2_SG)..."
aws ec2 authorize-security-group-ingress \
    --group-id "$PUBLIC_EC2_SG" \
    --protocol tcp --port 22 --cidr "${MY_IP}/32" \
    --region "$REGION" 2>/dev/null || echo "SSH rule may already exist"

# Inject public key via SSM (if SSM agent is running)
echo "Injecting public key via SSM Run Command..."
COMMAND_ID=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$PUBLIC_EC2_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[
        'mkdir -p /home/ec2-user/.ssh',
        'chmod 700 /home/ec2-user/.ssh',
        'grep -qF \"${PUB_KEY}\" /home/ec2-user/.ssh/authorized_keys 2>/dev/null || echo \"${PUB_KEY}\" >> /home/ec2-user/.ssh/authorized_keys',
        'chmod 600 /home/ec2-user/.ssh/authorized_keys',
        'chown -R ec2-user:ec2-user /home/ec2-user/.ssh'
    ]" \
    --query "Command.CommandId" \
    --output text)

echo "SSM Command ID: $COMMAND_ID"

# Wait for command to complete
sleep 10
aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$PUBLIC_EC2_ID" \
    --region "$REGION" \
    --query "{Status:Status,Output:StandardOutputContent}" \
    --output table 2>/dev/null || echo "SSM invocation check skipped"

# ============================================================
# STEP 8: FINAL VERIFICATION
# ============================================================

echo ""
echo "=== Step 8: Route Table Verification ==="

echo "--- Default VPC peering routes ---"
aws ec2 describe-route-tables \
    --route-table-ids "$DEFAULT_RT_ID" --region "$REGION" \
    --query "RouteTables[0].Routes[?VpcPeeringConnectionId!=null].{Destination:DestinationCidrBlock,PCX:VpcPeeringConnectionId,State:State}" \
    --output table

echo ""
echo "--- Private VPC peering routes ---"
aws ec2 describe-route-tables \
    --route-table-ids "$EFFECTIVE_PRIVATE_RT" --region "$REGION" \
    --query "RouteTables[0].Routes[?VpcPeeringConnectionId!=null].{Destination:DestinationCidrBlock,PCX:VpcPeeringConnectionId,State:State}" \
    --output table

echo ""
echo "============================================"
echo "  Peering: datacenter-vpc-peering ($PCX_ID) — active"
echo "  Default VPC:  $DEFAULT_VPC_ID ($DEFAULT_VPC_CIDR)"
echo "  Private VPC:  $PRIVATE_VPC_ID ($PRIVATE_VPC_CIDR)"
echo "  Public EC2:   $PUBLIC_EC2_IP"
echo "  Private EC2:  $PRIVATE_EC2_IP"
echo ""
echo "  Step 1: SSH to public EC2:"
echo "    ssh -i /root/.ssh/id_rsa ec2-user@$PUBLIC_EC2_IP"
echo ""
echo "  Step 2: Ping private EC2 from public EC2:"
echo "    ping -c 4 $PRIVATE_EC2_IP"
echo "============================================"

# ============================================================
# STEP 9: END-TO-END TEST
# ============================================================

echo ""
echo "=== Step 9: End-to-end connectivity test ==="
sleep 15

ssh -i /root/.ssh/id_rsa \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=20 \
    ec2-user@"$PUBLIC_EC2_IP" \
    "echo 'SSH to public EC2: SUCCESS' && ping -c 4 $PRIVATE_EC2_IP && echo 'Ping to private EC2: SUCCESS'" \
    && echo "✅ End-to-end connectivity VERIFIED" \
    || echo "⚠️  Test failed — review route tables and security groups above"
