#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 25: EC2 + CloudWatch CPU Alarm + SNS Notification
# Instance: devops-ec2 | Alarm: devops-alarm | SNS: devops-sns-topic
# Region: us-east-1
# ============================================================

REGION="us-east-1"
INSTANCE_NAME="devops-ec2"
ALARM_NAME="devops-alarm"
SNS_TOPIC_NAME="devops-sns-topic"

# ============================================================
# STEP 1: RESOLVE LATEST UBUNTU 22.04 LTS AMI
# Canonical account ID: 099720109477
# ============================================================

echo "=== Step 1: Resolving Ubuntu 22.04 AMI ==="

AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "AMI: $AMI_ID"

# ============================================================
# STEP 2: RESOLVE DEFAULT NETWORKING RESOURCES
# ============================================================

echo ""
echo "=== Step 2: Resolving default network resources ==="

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
    --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" --output text)

DEFAULT_SG=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text)

echo "VPC: $VPC_ID | Subnet: $SUBNET_ID | SG: $DEFAULT_SG"

# ============================================================
# STEP 3: LAUNCH EC2 INSTANCE (devops-ec2)
# ============================================================

echo ""
echo "=== Step 3: Launching instance '$INSTANCE_NAME' ==="

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$DEFAULT_SG" \
    --associate-public-ip-address \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Instance launched: $INSTANCE_ID"

echo "Waiting for running state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

echo "Instance is running"

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)
echo "Public IP: $PUBLIC_IP"

# ============================================================
# STEP 4: RESOLVE SNS TOPIC ARN
# ============================================================

echo ""
echo "=== Step 4: Resolving SNS topic ARN ==="

SNS_TOPIC_ARN=$(aws sns list-topics \
    --region "$REGION" \
    --query "Topics[?ends_with(TopicArn, ':${SNS_TOPIC_NAME}')].TopicArn" \
    --output text)

if [ -z "$SNS_TOPIC_ARN" ] || [ "$SNS_TOPIC_ARN" == "None" ]; then
    echo "ERROR: SNS topic '${SNS_TOPIC_NAME}' not found in $REGION"
    exit 1
fi

echo "SNS Topic ARN: $SNS_TOPIC_ARN"

# ============================================================
# STEP 5: CREATE CLOUDWATCH ALARM (devops-alarm)
# Average CPUUtilization >= 90% for 1 consecutive 5-minute period
# ============================================================

echo ""
echo "=== Step 5: Creating CloudWatch alarm '$ALARM_NAME' ==="

aws cloudwatch put-metric-alarm \
    --region "$REGION" \
    --alarm-name "$ALARM_NAME" \
    --alarm-description "Alert: CPUUtilization >= 90% for 5 minutes on ${INSTANCE_NAME} (${INSTANCE_ID})" \
    --namespace "AWS/EC2" \
    --metric-name "CPUUtilization" \
    --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
    --statistic "Average" \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 90 \
    --comparison-operator "GreaterThanOrEqualToThreshold" \
    --alarm-actions "$SNS_TOPIC_ARN" \
    --ok-actions "$SNS_TOPIC_ARN" \
    --treat-missing-data "missing" \
    --unit "Percent"

echo "CloudWatch alarm '$ALARM_NAME' created"

# ============================================================
# STEP 6: VERIFY EVERYTHING
# ============================================================

echo ""
echo "=== Step 6: Verification ==="

echo ""
echo "--- EC2 Instance ---"
aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,State:State.Name,Type:InstanceType,PublicIP:PublicIpAddress}" \
    --output table

echo ""
echo "--- CloudWatch Alarm ---"
aws cloudwatch describe-alarms \
    --alarm-names "$ALARM_NAME" --region "$REGION" \
    --query "MetricAlarms[0].{Name:AlarmName,State:StateValue,Metric:MetricName,Threshold:Threshold,Period:Period,EvalPeriods:EvaluationPeriods,Statistic:Statistic,Operator:ComparisonOperator}" \
    --output table

echo ""
echo "--- Alarm Actions ---"
aws cloudwatch describe-alarms \
    --alarm-names "$ALARM_NAME" --region "$REGION" \
    --query "MetricAlarms[0].{AlarmActions:AlarmActions,OKActions:OKActions}" \
    --output json

echo ""
echo "============================================"
echo "  Instance:    $INSTANCE_NAME ($INSTANCE_ID)"
echo "  Alarm:       $ALARM_NAME"
echo "  SNS Topic:   $SNS_TOPIC_NAME"
echo "  Threshold:   CPUUtilization >= 90% for 1 x 5min"
echo "  Initial State: INSUFFICIENT_DATA (normal — wait 5 min)"
echo "============================================"

# ============================================================
# STEP 7: TEST THE ALARM (optional — forces SNS notification)
# ============================================================

echo ""
echo "=== Step 7: Testing alarm (force ALARM state) ==="

aws cloudwatch set-alarm-state \
    --alarm-name "$ALARM_NAME" \
    --state-value ALARM \
    --state-reason "Manual test — verifying SNS notification delivery" \
    --region "$REGION"

echo "Alarm forced to ALARM state — check SNS subscriber inbox"

sleep 5

# Verify state changed
aws cloudwatch describe-alarms \
    --alarm-names "$ALARM_NAME" --region "$REGION" \
    --query "MetricAlarms[0].{State:StateValue,Reason:StateReason}" \
    --output table

# Reset to OK
aws cloudwatch set-alarm-state \
    --alarm-name "$ALARM_NAME" \
    --state-value OK \
    --state-reason "Manual reset after notification test" \
    --region "$REGION"

echo "Alarm reset to OK"

# ============================================================
# OPTIONAL: VIEW CPU METRICS (available after ~5 min)
# ============================================================

# aws cloudwatch get-metric-statistics \
#     --namespace AWS/EC2 \
#     --metric-name CPUUtilization \
#     --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
#     --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
#     --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
#     --period 300 \
#     --statistics Average \
#     --region "$REGION" \
#     --query "sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,CPU:Average}" \
#     --output table

# ============================================================
# CLEANUP
# ============================================================

# aws cloudwatch delete-alarms --alarm-names "$ALARM_NAME" --region "$REGION"
# aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
# aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
