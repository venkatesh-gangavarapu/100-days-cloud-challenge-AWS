#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 36: EC2 + Nginx Behind ALB (default SG reused for ALB)
# EC2: devops-ec2 | SG: devops-sg | ALB: devops-alb | TG: devops-tg
# Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"

# ============================================================
# STEP 1: RESOLVE DEFAULT VPC, SUBNETS, AND DEFAULT SG
# ============================================================

echo "=== Step 1: Resolving default networking ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

DEFAULT_SG=$(aws ec2 describe-security-groups --region $REGION \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text)

SUBNET_IDS=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query "Subnets[*].SubnetId" --output text | tr '\t' ' ')

SUBNET1=$(echo $SUBNET_IDS | awk '{print $1}')
SUBNET_COUNT=$(echo "$SUBNET_IDS" | wc -w)

echo "VPC:        $VPC_ID"
echo "Default SG: $DEFAULT_SG"
echo "Subnets ($SUBNET_COUNT AZs): $SUBNET_IDS"

if [ "$SUBNET_COUNT" -lt 2 ]; then
    echo "ERROR: ALB requires at least 2 subnets in different AZs"
    exit 1
fi

# ============================================================
# STEP 2: CREATE devops-sg — ATTACHED TO EC2
# Allow port 80 ONLY from the default SG (which the ALB will use)
# ============================================================

echo ""
echo "=== Step 2: Creating 'devops-sg' for the EC2 instance ==="

DEVOPS_SG=$(aws ec2 create-security-group \
    --region $REGION \
    --group-name devops-sg \
    --description "devops-ec2 — allow HTTP 80 from default SG (ALB) only" \
    --vpc-id $VPC_ID \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=devops-sg}]' \
    --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $DEVOPS_SG --protocol tcp --port 80 \
    --source-group $DEFAULT_SG --region $REGION

echo "devops-sg created: $DEVOPS_SG"
echo "  Inbound: TCP 80 from default SG ($DEFAULT_SG)"

# ============================================================
# STEP 3: ADJUST THE DEFAULT SG — OPEN PORT 80 TO THE INTERNET
# Required since the ALB will use this SG and needs public access
# ============================================================

echo ""
echo "=== Step 3: Opening port 80 on the default SG (for ALB) ==="

aws ec2 authorize-security-group-ingress \
    --group-id $DEFAULT_SG --protocol tcp --port 80 \
    --cidr 0.0.0.0/0 --region $REGION \
    2>/dev/null && echo "Port 80 opened on default SG" \
    || echo "Rule may already exist — continuing"

# ============================================================
# STEP 4: RESOLVE LATEST UBUNTU 22.04 AMI
# ============================================================

echo ""
echo "=== Step 4: Resolving Ubuntu 22.04 AMI ==="

AMI_ID=$(aws ec2 describe-images --region $REGION \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

echo "AMI: $AMI_ID"

# ============================================================
# STEP 5: LAUNCH devops-ec2 WITH NGINX USER DATA, devops-sg ATTACHED
# ============================================================

echo ""
echo "=== Step 5: Launching 'devops-ec2' ==="

USER_DATA=$(cat <<'EOF'
#!/bin/bash
set -e
exec >> /var/log/user-data.log 2>&1
echo "=== User Data started: $(date) ==="

apt-get update -y
apt-get install -y nginx
systemctl start nginx
systemctl enable nginx

echo "Nginx status:"
systemctl status nginx --no-pager
echo "=== User Data completed: $(date) ==="
EOF
)

INSTANCE_ID=$(aws ec2 run-instances \
    --region $REGION \
    --image-id $AMI_ID \
    --instance-type t2.micro \
    --subnet-id $SUBNET1 \
    --security-group-ids $DEVOPS_SG \
    --associate-public-ip-address \
    --user-data "$USER_DATA" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=devops-ec2}]' \
    --count 1 \
    --query "Instances[0].InstanceId" --output text)

echo "Instance launched: $INSTANCE_ID"

echo "Waiting for running state..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION

echo "Waiting for status checks (2/2)..."
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID --region $REGION

echo "devops-ec2 is running and healthy"

EC2_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
echo "Public IP: $EC2_PUBLIC_IP"

# ============================================================
# STEP 6: CREATE TARGET GROUP (devops-tg) AND REGISTER THE INSTANCE
# ============================================================

echo ""
echo "=== Step 6: Creating target group 'devops-tg' ==="

TG_ARN=$(aws elbv2 create-target-group \
    --region $REGION \
    --name devops-tg \
    --protocol HTTP --port 80 \
    --vpc-id $VPC_ID \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-port "80" \
    --health-check-path "/" \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --health-check-interval-seconds 30 \
    --matcher HttpCode=200 \
    --query "TargetGroups[0].TargetGroupArn" --output text)

echo "Target Group: $TG_ARN"

aws elbv2 register-targets \
    --region $REGION \
    --target-group-arn $TG_ARN \
    --targets Id=$INSTANCE_ID,Port=80

echo "Registered $INSTANCE_ID on port 80"

# ============================================================
# STEP 7: CREATE THE ALB (devops-alb) — USES THE DEFAULT SG
# ============================================================

echo ""
echo "=== Step 7: Creating ALB 'devops-alb' (using default SG) ==="

ALB_ARN=$(aws elbv2 create-load-balancer \
    --region $REGION \
    --name devops-alb \
    --type application \
    --scheme internet-facing \
    --ip-address-type ipv4 \
    --subnets $SUBNET_IDS \
    --security-groups $DEFAULT_SG \
    --tags Key=Name,Value=devops-alb \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)

echo "ALB: $ALB_ARN"
echo "ALB Security Group: $DEFAULT_SG (the default SG)"

# ============================================================
# STEP 8: CREATE LISTENER — PORT 80 → devops-tg
# ============================================================

echo ""
echo "=== Step 8: Creating listener (HTTP 80 → devops-tg) ==="

LISTENER_ARN=$(aws elbv2 create-listener \
    --region $REGION \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN \
    --query "Listeners[0].ListenerArn" --output text)

echo "Listener: $LISTENER_ARN"

# ============================================================
# STEP 9: WAIT FOR ALB ACTIVE
# ============================================================

echo ""
echo "=== Step 9: Waiting for ALB to become active ==="

aws elbv2 wait load-balancer-available \
    --load-balancer-arns $ALB_ARN --region $REGION

echo "ALB is active"

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN --region $REGION \
    --query "LoadBalancers[0].DNSName" --output text)

echo "ALB DNS: $ALB_DNS"

# ============================================================
# STEP 10: VERIFY TARGET HEALTH AND HTTP RESPONSE
# ============================================================

echo ""
echo "=== Step 10: Verification ==="

echo "Waiting 30s for first health check..."
sleep 30

echo ""
echo "--- Target Health ---"
aws elbv2 describe-target-health \
    --target-group-arn $TG_ARN --region $REGION \
    --query "TargetHealthDescriptions[*].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}" \
    --output table

echo ""
echo "--- ALB Summary ---"
aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN --region $REGION \
    --query "LoadBalancers[0].{Name:LoadBalancerName,State:State.Code,DNS:DNSName,SG:SecurityGroups[0]}" \
    --output table

echo ""
echo "--- HTTP Test via ALB DNS ---"
sleep 10
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://$ALB_DNS")
echo "HTTP Status: $HTTP_STATUS"

if [ "$HTTP_STATUS" == "200" ]; then
    echo "✅ SUCCESS: Nginx reachable via ALB DNS"
else
    echo "⚠️  Got HTTP $HTTP_STATUS — target may still be initializing. Retry in 30s."
fi

echo ""
echo "============================================"
echo "  EC2 Instance:   devops-ec2 ($INSTANCE_ID)"
echo "  EC2 SG:         devops-sg ($DEVOPS_SG)"
echo "  ALB:            devops-alb"
echo "  ALB SG:         default ($DEFAULT_SG)"
echo "  Target Group:   devops-tg"
echo "  ALB DNS:        http://$ALB_DNS"
echo "============================================"

# ============================================================
# CLEANUP (commented — run only when tearing down)
# ============================================================

# aws elbv2 delete-listener --listener-arn $LISTENER_ARN --region $REGION
# aws elbv2 deregister-targets --target-group-arn $TG_ARN --targets Id=$INSTANCE_ID --region $REGION
# aws elbv2 delete-target-group --target-group-arn $TG_ARN --region $REGION
# aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN --region $REGION
# aws elbv2 wait load-balancers-deleted --load-balancer-arns $ALB_ARN --region $REGION
# aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION
# aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID --region $REGION
# aws ec2 delete-security-group --group-id $DEVOPS_SG --region $REGION
