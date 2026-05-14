#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 24: Application Load Balancer Setup
# ALB: xfusion-alb | TG: xfusion-tg | SG: xfusion-sg
# Instance: xfusion-ec2 | Region: us-east-1
# ============================================================

REGION="us-east-1"

# ============================================================
# STEP 0: RESOLVE EXISTING RESOURCES
# ============================================================

echo "=== Resolving existing resources ==="

# Get xfusion-ec2 instance details
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
        "Name=tag:Name,Values=xfusion-ec2" \
        "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "None" ]; then
    echo "ERROR: xfusion-ec2 instance not found or not running"
    exit 1
fi

INSTANCE_AZ=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].Placement.AvailabilityZone" \
    --output text)

INSTANCE_PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text)

# Get the security group currently on the instance
EC2_SG_ID=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
    --output text)

echo "Instance:    $INSTANCE_ID"
echo "Instance AZ: $INSTANCE_AZ"
echo "Instance IP: $INSTANCE_PRIVATE_IP"
echo "EC2 SG:      $EC2_SG_ID"

# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text)

echo "VPC: $VPC_ID"

# Get all default subnets (ALB needs at least 2 AZs)
SUBNET_IDS=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=default-for-az,Values=true" \
    --query "Subnets[*].SubnetId" \
    --output text | tr '\t' ' ')

SUBNET_COUNT=$(echo "$SUBNET_IDS" | wc -w)
echo "Subnets ($SUBNET_COUNT AZs): $SUBNET_IDS"

if [ "$SUBNET_COUNT" -lt 2 ]; then
    echo "ERROR: ALB requires at least 2 subnets in different AZs"
    exit 1
fi

# ============================================================
# STEP 1: CREATE ALB SECURITY GROUP (xfusion-sg)
# Opens port 80 to the public internet
# ============================================================

echo ""
echo "=== Step 1: Creating ALB security group 'xfusion-sg' ==="

ALB_SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name xfusion-sg \
    --description "xfusion ALB security group — allow HTTP port 80 from internet" \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=xfusion-sg}]' \
    --query "GroupId" \
    --output text)

echo "ALB SG created: $ALB_SG_ID"

# Allow port 80 inbound from the internet
aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$ALB_SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

echo "Inbound rule: TCP port 80 from 0.0.0.0/0 added to $ALB_SG_ID"

# ============================================================
# STEP 2: UPDATE EC2 SECURITY GROUP
# Allow port 80 ONLY from the ALB security group (not public internet)
# ============================================================

echo ""
echo "=== Step 2: Updating EC2 security group to allow traffic from ALB only ==="

aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$EC2_SG_ID" \
    --protocol tcp \
    --port 80 \
    --source-group "$ALB_SG_ID"

echo "Inbound rule: TCP port 80 from ALB SG ($ALB_SG_ID) added to EC2 SG ($EC2_SG_ID)"

# ============================================================
# STEP 3: CREATE TARGET GROUP (xfusion-tg)
# ============================================================

echo ""
echo "=== Step 3: Creating target group 'xfusion-tg' ==="

TG_ARN=$(aws elbv2 create-target-group \
    --region "$REGION" \
    --name xfusion-tg \
    --protocol HTTP \
    --port 80 \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-port "80" \
    --health-check-path "/" \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --matcher HttpCode=200 \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text)

echo "Target Group ARN: $TG_ARN"

# ============================================================
# STEP 4: REGISTER xfusion-ec2 AS A TARGET
# ============================================================

echo ""
echo "=== Step 4: Registering instance in target group ==="

aws elbv2 register-targets \
    --region "$REGION" \
    --target-group-arn "$TG_ARN" \
    --targets Id="$INSTANCE_ID",Port=80

echo "Instance $INSTANCE_ID registered on port 80"

# ============================================================
# STEP 5: CREATE THE APPLICATION LOAD BALANCER (xfusion-alb)
# ============================================================

echo ""
echo "=== Step 5: Creating ALB 'xfusion-alb' ==="

ALB_ARN=$(aws elbv2 create-load-balancer \
    --region "$REGION" \
    --name xfusion-alb \
    --type application \
    --scheme internet-facing \
    --ip-address-type ipv4 \
    --subnets $SUBNET_IDS \
    --security-groups "$ALB_SG_ID" \
    --tags Key=Name,Value=xfusion-alb \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text)

echo "ALB ARN: $ALB_ARN"

# ============================================================
# STEP 6: CREATE LISTENER (port 80 → xfusion-tg)
# ============================================================

echo ""
echo "=== Step 6: Creating listener (HTTP port 80 → xfusion-tg) ==="

LISTENER_ARN=$(aws elbv2 create-listener \
    --region "$REGION" \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
    --query "Listeners[0].ListenerArn" \
    --output text)

echo "Listener ARN: $LISTENER_ARN"

# ============================================================
# STEP 7: WAIT FOR ALB TO BECOME ACTIVE
# ============================================================

echo ""
echo "=== Step 7: Waiting for ALB to become active (may take 2-3 minutes) ==="

aws elbv2 wait load-balancer-available \
    --load-balancer-arns "$ALB_ARN" \
    --region "$REGION"

echo "ALB is active"

# ============================================================
# STEP 8: GET DNS NAME AND VERIFY
# ============================================================

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --region "$REGION" \
    --query "LoadBalancers[0].DNSName" \
    --output text)

echo ""
echo "=== Step 8: Verification ==="

echo ""
echo "--- ALB Summary ---"
aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" --region "$REGION" \
    --query "LoadBalancers[0].{Name:LoadBalancerName,State:State.Code,DNS:DNSName,AZs:AvailabilityZones[*].ZoneName}" \
    --output table

echo ""
echo "--- Target Health (allow 30s for first health check) ---"
sleep 15
aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --region "$REGION" \
    --query "TargetHealthDescriptions[*].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}" \
    --output table

echo ""
echo "============================================"
echo "  ALB Name:     xfusion-alb"
echo "  Target Group: xfusion-tg"
echo "  ALB SG:       xfusion-sg ($ALB_SG_ID)"
echo "  ALB DNS:      $ALB_DNS"
echo "  Test:         curl http://$ALB_DNS"
echo "============================================"

# Test HTTP response
echo ""
echo "=== HTTP Test ==="
sleep 30
curl -s -o /dev/null -w "HTTP Status from ALB: %{http_code}\n" "http://$ALB_DNS"

# ============================================================
# CLEANUP (commented — run only when tearing down)
# ============================================================

# 1. Delete listener
# aws elbv2 delete-listener --listener-arn "$LISTENER_ARN" --region "$REGION"

# 2. Deregister target
# aws elbv2 deregister-targets \
#     --target-group-arn "$TG_ARN" --targets Id="$INSTANCE_ID" --region "$REGION"

# 3. Delete target group
# aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$REGION"

# 4. Delete ALB
# aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$REGION"
# aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" --region "$REGION"

# 5. Delete ALB security group (after ALB is deleted)
# aws ec2 delete-security-group --group-id "$ALB_SG_ID" --region "$REGION"
