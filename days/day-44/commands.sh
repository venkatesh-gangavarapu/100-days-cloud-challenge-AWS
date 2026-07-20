#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 44: ASG + ALB + Nginx — Highly Available Web Stack
# Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"

# ============================================================
# STEP 1: RESOLVE DEFAULT VPC AND SUBNETS
# ============================================================

echo "=== Step 1: Resolving default VPC and subnets ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

SUBNET_IDS=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
    --query "Subnets[*].SubnetId" --output text | tr '\t' ',')

SUBNET_ARRAY=$(echo $SUBNET_IDS | tr ',' ' ')
SUBNET_COUNT=$(echo $SUBNET_IDS | tr ',' ' ' | wc -w)

echo "VPC: $VPC_ID"
echo "Subnets ($SUBNET_COUNT): $SUBNET_IDS"

if [ "$SUBNET_COUNT" -lt 2 ]; then
    echo "ERROR: ALB requires at least 2 subnets in different AZs"
    exit 1
fi

# ============================================================
# STEP 2: CREATE SECURITY GROUP — PORT 80 FROM INTERNET
# ============================================================

echo ""
echo "=== Step 2: Creating security group 'datacenter-sg' ==="

SG_ID=$(aws ec2 create-security-group \
    --region $REGION \
    --group-name datacenter-sg \
    --description "datacenter web allow HTTP port 80" \
    --vpc-id $VPC_ID \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=datacenter-sg}]' \
    --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID --protocol tcp --port 80 \
    --cidr 0.0.0.0/0 --region $REGION

echo "Security group: $SG_ID (port 80 open to 0.0.0.0/0)"

# ============================================================
# STEP 3: RESOLVE AMAZON LINUX 2 AMI
# NOTE: Task requires Amazon Linux 2, NOT Amazon Linux 2023
# AL2 uses 'yum'; AL2023 uses 'dnf' — do not mix them
# ============================================================

echo ""
echo "=== Step 3: Resolving Amazon Linux 2 AMI ==="

AL2_AMI=$(aws ec2 describe-images \
    --region $REGION \
    --owners amazon \
    --filters \
        "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "Amazon Linux 2 AMI: $AL2_AMI"

# ============================================================
# STEP 4: CREATE LAUNCH TEMPLATE
# User Data installs and enables Nginx via yum (AL2 package manager)
# Base64-encode the user data for the launch template
# ============================================================

echo ""
echo "=== Step 4: Creating launch template 'datacenter-launch-template' ==="

# Write user data script
cat > /tmp/user-data.sh << 'UDEOF'
#!/bin/bash
yum update -y
yum install -y nginx
systemctl start nginx
systemctl enable nginx
UDEOF

# Base64 encode (required for launch template data)
USER_DATA_B64=$(base64 -w 0 /tmp/user-data.sh)

LT_ID=$(aws ec2 create-launch-template \
    --region $REGION \
    --launch-template-name datacenter-launch-template \
    --version-description "v1-nginx-amazon-linux-2" \
    --launch-template-data "{
        \"ImageId\": \"${AL2_AMI}\",
        \"InstanceType\": \"t2.micro\",
        \"SecurityGroupIds\": [\"${SG_ID}\"],
        \"UserData\": \"${USER_DATA_B64}\",
        \"TagSpecifications\": [
            {
                \"ResourceType\": \"instance\",
                \"Tags\": [{\"Key\": \"Name\", \"Value\": \"datacenter-nginx-instance\"}]
            }
        ],
        \"Monitoring\": {\"Enabled\": true}
    }" \
    --query "LaunchTemplate.LaunchTemplateId" \
    --output text)

echo "Launch template: $LT_ID (datacenter-launch-template)"

# Verify
aws ec2 describe-launch-templates \
    --launch-template-ids $LT_ID --region $REGION \
    --query "LaunchTemplates[0].{Name:LaunchTemplateName,ID:LaunchTemplateId,Version:LatestVersionNumber}" \
    --output table

# ============================================================
# STEP 5: CREATE TARGET GROUP
# ============================================================

echo ""
echo "=== Step 5: Creating target group 'datacenter-tg' ==="

TG_ARN=$(aws elbv2 create-target-group \
    --region $REGION \
    --name datacenter-tg \
    --protocol HTTP \
    --port 80 \
    --vpc-id $VPC_ID \
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

echo "Target group: $TG_ARN"

# ============================================================
# STEP 6: CREATE APPLICATION LOAD BALANCER
# ============================================================

echo ""
echo "=== Step 6: Creating ALB 'datacenter-alb' ==="

ALB_ARN=$(aws elbv2 create-load-balancer \
    --region $REGION \
    --name datacenter-alb \
    --type application \
    --scheme internet-facing \
    --ip-address-type ipv4 \
    --subnets $SUBNET_ARRAY \
    --security-groups $SG_ID \
    --tags Key=Name,Value=datacenter-alb \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text)

echo "ALB ARN: $ALB_ARN"

# Create HTTP listener — forward port 80 traffic to target group
aws elbv2 create-listener \
    --region $REGION \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN \
    --query "Listeners[0].ListenerArn" \
    --output text > /dev/null

echo "Listener created: HTTP 80 → datacenter-tg"

# Wait for ALB to become active before creating ASG
echo "Waiting for ALB to become active..."
aws elbv2 wait load-balancer-available \
    --load-balancer-arns $ALB_ARN --region $REGION

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN --region $REGION \
    --query "LoadBalancers[0].DNSName" --output text)

echo "ALB DNS: $ALB_DNS"

# ============================================================
# STEP 7: CREATE AUTO SCALING GROUP
# Attached to target group = ASG auto-registers/deregisters instances
# health-check-type ELB = instance replaced if Nginx fails health check
# health-check-grace-period 120 = 120s for yum install nginx to complete
# ============================================================

echo ""
echo "=== Step 7: Creating Auto Scaling Group 'datacenter-asg' ==="

aws autoscaling create-auto-scaling-group \
    --region $REGION \
    --auto-scaling-group-name datacenter-asg \
    --launch-template "LaunchTemplateName=datacenter-launch-template,Version=\$Latest" \
    --min-size 1 \
    --desired-capacity 1 \
    --max-size 2 \
    --target-group-arns $TG_ARN \
    --health-check-type ELB \
    --health-check-grace-period 120 \
    --vpc-zone-identifier $SUBNET_IDS \
    --tags \
        Key=Name,Value=datacenter-asg,PropagateAtLaunch=false \
        Key=Environment,Value=Production,PropagateAtLaunch=true

echo "ASG created: datacenter-asg (min=1, desired=1, max=2)"

# ============================================================
# STEP 8: ADD TARGET TRACKING SCALING POLICY (CPU 50%)
# ============================================================

echo ""
echo "=== Step 8: Adding CPU target tracking policy (50%) ==="

POLICY_ARN=$(aws autoscaling put-scaling-policy \
    --region $REGION \
    --auto-scaling-group-name datacenter-asg \
    --policy-name datacenter-cpu-scaling-policy \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration '{
        "PredefinedMetricSpecification": {
            "PredefinedMetricType": "ASGAverageCPUUtilization"
        },
        "TargetValue": 50.0,
        "DisableScaleIn": false
    }' \
    --query "PolicyARN" --output text)

echo "Scaling policy ARN: $POLICY_ARN"
echo "Target tracking: ASGAverageCPUUtilization = 50%"

# ============================================================
# STEP 9: WAIT FOR INSTANCE TO LAUNCH AND BECOME HEALTHY
# Full timeline: launch → user data (90s) → grace period (120s) → health checks
# ============================================================

echo ""
echo "=== Step 9: Waiting for instance launch and health checks (3-4 min) ==="

echo "Checking ASG instances (launched by ASG)..."
sleep 60

aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names datacenter-asg --region $REGION \
    --query "AutoScalingGroups[0].{Min:MinSize,Desired:DesiredCapacity,Max:MaxSize,Instances:Instances[*].{ID:InstanceId,State:LifecycleState,Health:HealthStatus}}" \
    --output json

echo ""
echo "Waiting for health checks to pass (additional 2 min)..."
sleep 120

echo ""
echo "=== Step 10: Final verification ==="

echo "--- ASG Status ---"
aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names datacenter-asg --region $REGION \
    --query "AutoScalingGroups[0].{Min:MinSize,Desired:DesiredCapacity,Max:MaxSize,HealthCheckType:HealthCheckType,HealthCheckGracePeriod:HealthCheckGracePeriod}" \
    --output table

echo ""
echo "--- Target Health ---"
aws elbv2 describe-target-health \
    --target-group-arn $TG_ARN --region $REGION \
    --query "TargetHealthDescriptions[*].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}" \
    --output table

echo ""
echo "--- HTTP Test ---"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 15 "http://$ALB_DNS" 2>/dev/null || echo "000")

echo "HTTP Status from ALB: $HTTP_STATUS"

if [ "$HTTP_STATUS" == "200" ]; then
    echo "✅ SUCCESS: Nginx default page serving via ALB"
else
    echo "⚠️  Got $HTTP_STATUS — may need more time or debug health checks"
fi

echo ""
echo "============================================"
echo "  Security Group:  datacenter-sg ($SG_ID)"
echo "  Launch Template: datacenter-launch-template"
echo "  AMI:             Amazon Linux 2 ($AL2_AMI)"
echo "  ASG:             datacenter-asg (min=1, desired=1, max=2)"
echo "  CPU Policy:      50% target tracking"
echo "  Target Group:    datacenter-tg"
echo "  ALB:             datacenter-alb"
echo "  ALB DNS:         http://$ALB_DNS"
echo "============================================"

# ============================================================
# TROUBLESHOOTING: 502 BAD GATEWAY + UNHEALTHY TARGETS
# Run these if the ALB returns 502 and targets show unhealthy.
# 502 = ALB reaches instance but gets no HTTP response on port 80.
# Most common cause: Nginx not installed (User Data failed silently).
# ============================================================

# --- STEP A: Diagnose via SSM (no SSH needed) ---
# REGION="us-east-1"
# ASG_NAME="devops-asg"   # or datacenter-asg
#
# INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
#     --auto-scaling-group-names $ASG_NAME --region $REGION \
#     --query "AutoScalingGroups[0].Instances[0].InstanceId" --output text)
#
# CMD_ID=$(aws ssm send-command --region $REGION \
#     --instance-ids $INSTANCE_ID \
#     --document-name "AWS-RunShellScript" \
#     --parameters 'commands=[
#         "systemctl status nginx --no-pager 2>&1 || echo NOT_RUNNING",
#         "ss -tlnp | grep :80 || echo NOTHING_ON_PORT_80",
#         "tail -20 /var/log/cloud-init-output.log"
#     ]' \
#     --query "Command.CommandId" --output text)
#
# sleep 15
# aws ssm get-command-invocation --command-id $CMD_ID \
#     --instance-id $INSTANCE_ID --region $REGION \
#     --query "StandardOutputContent" --output text

# --- STEP B: Fix immediately via SSM (no relaunch needed) ---
# aws ssm send-command --region $REGION \
#     --instance-ids $INSTANCE_ID \
#     --document-name "AWS-RunShellScript" \
#     --parameters 'commands=[
#         "yum install -y nginx",
#         "systemctl start nginx",
#         "systemctl enable nginx",
#         "curl -s -o /dev/null -w \"local: %{http_code}\" http://localhost"
#     ]' \
#     --query "Command.CommandId" --output text

# --- STEP C: If SSM unavailable — new LT version + terminate instance ---
# AL2_AMI=$(aws ec2 describe-images --region $REGION --owners amazon \
#     --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" \
#     --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)
# SG_ID=$(aws ec2 describe-security-groups --region $REGION \
#     --filters "Name=group-name,Values=devops-sg" \
#     --query "SecurityGroups[0].GroupId" --output text)
# USER_DATA_B64=$(printf '#!/bin/bash\nyum update -y\nyum install -y nginx\nsystemctl start nginx\nsystemctl enable nginx' | base64 -w 0)
#
# aws ec2 create-launch-template-version \
#     --region $REGION \
#     --launch-template-name devops-launch-template \
#     --version-description "v2-nginx-fixed" \
#     --launch-template-data "{\"ImageId\":\"${AL2_AMI}\",\"InstanceType\":\"t2.micro\",\"SecurityGroupIds\":[\"${SG_ID}\"],\"UserData\":\"${USER_DATA_B64}\"}"
#
# aws autoscaling terminate-instance-in-auto-scaling-group \
#     --instance-id $INSTANCE_ID \
#     --should-decrement-desired-capacity false \
#     --region $REGION
# echo "ASG will relaunch with fixed template — wait 5 min then check health"

# ============================================================
# CLEANUP (strict order — comment out to preserve resources)
# ============================================================

# 1. Delete ASG (force-delete terminates instances immediately)
# aws autoscaling delete-auto-scaling-group \
#     --auto-scaling-group-name datacenter-asg --force-delete --region $REGION

# 2. Delete ALB and target group
# aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN --region $REGION
# aws elbv2 wait load-balancers-deleted --load-balancer-arns $ALB_ARN --region $REGION
# aws elbv2 delete-target-group --target-group-arn $TG_ARN --region $REGION

# 3. Delete launch template and security group
# aws ec2 delete-launch-template --launch-template-id $LT_ID --region $REGION
# aws ec2 delete-security-group --group-id $SG_ID --region $REGION
