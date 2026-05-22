#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 30: NAT Instance for Private Subnet Internet Access
# VPC: xfusion-priv-vpc | NAT: xfusion-nat-instance | Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
S3_BUCKET="xfusion-nat-16441"

# ============================================================
# STEP 1: DISCOVER EXISTING RESOURCES
# ============================================================

echo "=== Step 1: Discovering existing resources ==="

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=xfusion-priv-vpc" \
    --query "Vpcs[0].VpcId" --output text)
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
    --query "Vpcs[0].CidrBlock" --output text)

PRIV_SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=tag:Name,Values=xfusion-priv-subnet" \
    --query "Subnets[0].SubnetId" --output text)
PRIV_SUBNET_CIDR=$(aws ec2 describe-subnets --subnet-ids "$PRIV_SUBNET_ID" \
    --region "$REGION" --query "Subnets[0].CidrBlock" --output text)
PRIV_SUBNET_AZ=$(aws ec2 describe-subnets --subnet-ids "$PRIV_SUBNET_ID" \
    --region "$REGION" --query "Subnets[0].AvailabilityZone" --output text)

PRIV_EC2_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=xfusion-priv-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)
PRIV_EC2_IP=$(aws ec2 describe-instances --instance-ids "$PRIV_EC2_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)

echo "VPC:            $VPC_ID ($VPC_CIDR)"
echo "Private Subnet: $PRIV_SUBNET_ID ($PRIV_SUBNET_CIDR) in $PRIV_SUBNET_AZ"
echo "Private EC2:    $PRIV_EC2_ID ($PRIV_EC2_IP)"

# ============================================================
# STEP 2: CHECK FOR INTERNET GATEWAY (create if missing)
# ============================================================

echo ""
echo "=== Step 2: Checking Internet Gateway ==="

IGW_ID=$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query "InternetGateways[0].InternetGatewayId" --output text)

if [ -z "$IGW_ID" ] || [ "$IGW_ID" == "None" ]; then
    echo "Creating Internet Gateway..."
    IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
        --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=xfusion-igw}]' \
        --query "InternetGateway.InternetGatewayId" --output text)
    aws ec2 attach-internet-gateway \
        --internet-gateway-id "$IGW_ID" \
        --vpc-id "$VPC_ID" --region "$REGION"
    echo "IGW created and attached: $IGW_ID"
else
    echo "Existing IGW found: $IGW_ID"
fi

# ============================================================
# STEP 3: CREATE PUBLIC SUBNET (xfusion-pub-subnet)
# Use a different /24 block from the private subnet
# ============================================================

echo ""
echo "=== Step 3: Creating public subnet 'xfusion-pub-subnet' ==="

# Auto-derive public CIDR: replace .1. with .2. in private CIDR
PUB_SUBNET_CIDR=$(echo "$PRIV_SUBNET_CIDR" | awk -F'.' '{print $1"."$2".2."$4}')

PUB_SUBNET_ID=$(aws ec2 create-subnet \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --cidr-block "$PUB_SUBNET_CIDR" \
    --availability-zone "$PRIV_SUBNET_AZ" \
    --tag-specifications \
        'ResourceType=subnet,Tags=[{Key=Name,Value=xfusion-pub-subnet},{Key=Type,Value=Public}]' \
    --query "Subnet.SubnetId" --output text)

echo "Public subnet: $PUB_SUBNET_ID ($PUB_SUBNET_CIDR)"

aws ec2 modify-subnet-attribute \
    --subnet-id "$PUB_SUBNET_ID" \
    --map-public-ip-on-launch --region "$REGION"
echo "Auto-assign public IP enabled"

# ============================================================
# STEP 4: CREATE PUBLIC ROUTE TABLE AND ASSOCIATE
# ============================================================

echo ""
echo "=== Step 4: Creating public route table with IGW route ==="

PUB_RT_ID=$(aws ec2 create-route-table \
    --region "$REGION" --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=xfusion-pub-rt}]' \
    --query "RouteTable.RouteTableId" --output text)

aws ec2 create-route \
    --route-table-id "$PUB_RT_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$IGW_ID" --region "$REGION"

aws ec2 associate-route-table \
    --route-table-id "$PUB_RT_ID" \
    --subnet-id "$PUB_SUBNET_ID" --region "$REGION"

echo "Public route table: $PUB_RT_ID (0.0.0.0/0 → $IGW_ID)"

# ============================================================
# STEP 5: CREATE NAT INSTANCE SECURITY GROUP
# Must allow all traffic from private subnet + SSH for management
# ============================================================

echo ""
echo "=== Step 5: Creating NAT security group 'xfusion-nat-sg' ==="

NAT_SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name xfusion-nat-sg \
    --description "xfusion-nat-instance — forwarded traffic from private subnet" \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=xfusion-nat-sg}]' \
    --query "GroupId" --output text)

echo "NAT SG: $NAT_SG_ID"

# Allow all traffic from private subnet (TCP/UDP/ICMP for all forwarded packets)
aws ec2 authorize-security-group-ingress \
    --group-id "$NAT_SG_ID" --protocol -1 --port -1 \
    --cidr "$PRIV_SUBNET_CIDR" --region "$REGION"

# Allow SSH for management
MY_IP=$(curl -s https://checkip.amazonaws.com 2>/dev/null || echo "0.0.0.0")
aws ec2 authorize-security-group-ingress \
    --group-id "$NAT_SG_ID" --protocol tcp --port 22 \
    --cidr "${MY_IP}/32" --region "$REGION"

echo "Inbound: all from $PRIV_SUBNET_CIDR | SSH from $MY_IP/32"

# ============================================================
# STEP 6: RESOLVE AMAZON LINUX 2023 AMI
# ============================================================

echo ""
echo "=== Step 6: Resolving Amazon Linux 2023 AMI ==="

AL2023_AMI=$(aws ec2 describe-images \
    --region "$REGION" --owners amazon \
    --filters \
        "Name=name,Values=al2023-ami-2023*-x86_64" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "AL2023 AMI: $AL2023_AMI"

# ============================================================
# STEP 7: BUILD NAT USER DATA SCRIPT
# Key steps:
#   1. Install iptables (not default on AL2023)
#   2. Enable IP forwarding (kernel + sysctl)
#   3. Configure MASQUERADE rule on eth0
#   4. Persist rules and enable service
# ============================================================

NAT_USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
exec >> /var/log/nat-setup.log 2>&1
echo "=== NAT Instance setup started: $(date) ==="

# Step A: Install iptables (AL2023 uses nftables by default — must install explicitly)
echo "[1/4] Installing iptables and iptables-services..."
dnf install -y iptables iptables-services
echo "iptables installed"

# Step B: Enable IP forwarding immediately
echo "[2/4] Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward
# Persist across reboots
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ip-forward.conf
sysctl -p /etc/sysctl.d/99-ip-forward.conf
echo "IP forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"

# Step C: Configure iptables NAT rules
echo "[3/4] Configuring iptables NAT rules..."

# MASQUERADE: rewrite source IP of outgoing packets to NAT instance's public IP
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Allow forwarding of established connections (return traffic to private instances)
iptables -A FORWARD -i eth0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Allow all forwarding from private subnet
iptables -A FORWARD -i eth0 -j ACCEPT

echo "iptables rules configured"

# Step D: Save rules and enable service for persistence
echo "[4/4] Saving iptables rules and enabling service..."
service iptables save
systemctl enable iptables
systemctl start iptables

# Verification output
echo "=== NAT Setup Verification ==="
echo "IP forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"
echo "NAT rules:"
iptables -t nat -L POSTROUTING -v --line-numbers
echo "FORWARD rules:"
iptables -L FORWARD -v --line-numbers

echo "=== NAT Instance setup COMPLETE: $(date) ==="
USERDATA
)

# ============================================================
# STEP 8: LAUNCH NAT INSTANCE IN PUBLIC SUBNET
# ============================================================

echo ""
echo "=== Step 8: Launching NAT instance 'xfusion-nat-instance' ==="

NAT_INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AL2023_AMI" \
    --instance-type t2.micro \
    --subnet-id "$PUB_SUBNET_ID" \
    --security-group-ids "$NAT_SG_ID" \
    --associate-public-ip-address \
    --user-data "$NAT_USER_DATA" \
    --tag-specifications \
        'ResourceType=instance,Tags=[{Key=Name,Value=xfusion-nat-instance}]' \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "NAT instance launched: $NAT_INSTANCE_ID"

# ============================================================
# STEP 9: WAIT + DISABLE SOURCE/DESTINATION CHECK (CRITICAL)
# ============================================================

echo ""
echo "=== Step 9: Waiting for NAT instance — then disabling source/dest check ==="

aws ec2 wait instance-running \
    --instance-ids "$NAT_INSTANCE_ID" --region "$REGION"
echo "NAT instance is running"

# *** THIS IS THE CRITICAL STEP — NAT WILL NOT WORK WITHOUT THIS ***
aws ec2 modify-instance-attribute \
    --instance-id "$NAT_INSTANCE_ID" \
    --no-source-dest-check \
    --region "$REGION"

SDCHECK=$(aws ec2 describe-instances \
    --instance-ids "$NAT_INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].NetworkInterfaces[0].SourceDestCheck" \
    --output text)

echo "Source/Destination Check = $SDCHECK (must be False)"

NAT_PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$NAT_INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "NAT instance public IP: $NAT_PUBLIC_IP"

# ============================================================
# STEP 10: ADD DEFAULT ROUTE IN PRIVATE SUBNET → NAT INSTANCE
# ============================================================

echo ""
echo "=== Step 10: Updating private subnet route table ==="

# Find route table associated with private subnet (check explicit first, then main)
PRIV_RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=association.subnet-id,Values=${PRIV_SUBNET_ID}" \
    --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || echo "None")

if [ -z "$PRIV_RT_ID" ] || [ "$PRIV_RT_ID" == "None" ]; then
    PRIV_RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.main,Values=true" \
        --query "RouteTables[0].RouteTableId" --output text)
    echo "Using main route table: $PRIV_RT_ID"
else
    echo "Private subnet explicit route table: $PRIV_RT_ID"
fi

# Add default route pointing to NAT instance
aws ec2 create-route \
    --route-table-id "$PRIV_RT_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --instance-id "$NAT_INSTANCE_ID" \
    --region "$REGION"

echo "Route added: 0.0.0.0/0 → $NAT_INSTANCE_ID"

# ============================================================
# STEP 11: FULL VERIFICATION
# ============================================================

echo ""
echo "=== Step 11: Full Verification ==="

echo "--- Private subnet route table ---"
aws ec2 describe-route-tables \
    --route-table-ids "$PRIV_RT_ID" --region "$REGION" \
    --query "RouteTables[0].Routes[*].{Dest:DestinationCidrBlock,Target:InstanceId,GW:GatewayId,State:State}" \
    --output table

echo ""
echo "--- NAT Instance ---"
aws ec2 describe-instances \
    --instance-ids "$NAT_INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,State:State.Name,PublicIP:PublicIpAddress,SourceDestCheck:NetworkInterfaces[0].SourceDestCheck}" \
    --output table

echo ""
echo "============================================"
echo "  VPC:           xfusion-priv-vpc ($VPC_ID)"
echo "  Public Subnet: xfusion-pub-subnet ($PUB_SUBNET_ID)"
echo "  NAT Instance:  xfusion-nat-instance ($NAT_INSTANCE_ID)"
echo "  NAT Public IP: $NAT_PUBLIC_IP"
echo "  Source/Dest:   DISABLED ✅"
echo "  Private RT:    $PRIV_RT_ID"
echo "  Route:         0.0.0.0/0 → $NAT_INSTANCE_ID"
echo "============================================"

# ============================================================
# STEP 12: WAIT FOR S3 FILE (cron uploads every minute)
# ============================================================

echo ""
echo "=== Step 12: Waiting for xfusion-test.txt in s3://$S3_BUCKET ==="
echo "    (NAT User Data needs ~60s, cron runs every minute)"
echo "    Waiting 90 seconds before first check..."
sleep 90

FOUND=""
for i in 1 2 3 4 5 6; do
    echo "Check $i/6..."
    FOUND=$(aws s3 ls "s3://${S3_BUCKET}/" 2>/dev/null | grep "xfusion-test.txt" || echo "")
    if [ -n "$FOUND" ]; then
        echo "✅ SUCCESS: xfusion-test.txt found in S3!"
        echo "$FOUND"
        break
    fi
    echo "Not yet... waiting 30s"
    sleep 30
done

if [ -z "$FOUND" ]; then
    echo ""
    echo "⚠️  File not found. Debug commands:"
    echo "  NAT log:  ssh ec2-user@$NAT_PUBLIC_IP 'cat /var/log/nat-setup.log'"
    echo "  iptables: ssh ec2-user@$NAT_PUBLIC_IP 'sudo iptables -t nat -L -v'"
    echo "  ipfwd:    ssh ec2-user@$NAT_PUBLIC_IP 'cat /proc/sys/net/ipv4/ip_forward'"
    echo "  S3 list:  aws s3 ls s3://$S3_BUCKET"
fi
