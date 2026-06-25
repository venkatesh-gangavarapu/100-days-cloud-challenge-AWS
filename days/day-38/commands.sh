#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 38: ECR + ECS Fargate Containerized App Deployment
# ECR: devops-ecr | Cluster: devops-cluster | Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
REPO_NAME="devops-ecr"
CLUSTER_NAME="devops-cluster"
TASK_DEF_NAME="devops-taskdefinition"
SERVICE_NAME="devops-service"
CONTAINER_NAME="devops-container"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"
EXEC_ROLE_NAME="ecsTaskExecutionRole"

echo "Account ID:  $ACCOUNT_ID"
echo "Region:      $REGION"
echo "ECR URI:     ${ECR_URI}:latest"

# ============================================================
# STEP 1: CREATE PRIVATE ECR REPOSITORY
# ============================================================

echo ""
echo "=== Step 1: Creating ECR repository '$REPO_NAME' ==="

aws ecr create-repository \
    --repository-name $REPO_NAME \
    --region $REGION \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE \
    --tags Key=Name,Value=$REPO_NAME

REPO_URI=$(aws ecr describe-repositories \
    --repository-names $REPO_NAME --region $REGION \
    --query "repositories[0].repositoryUri" --output text)

echo "Repository URI: $REPO_URI"

# ============================================================
# STEP 2: READ DOCKERFILE — DETECT CONTAINER PORT
# ============================================================

echo ""
echo "=== Step 2: Inspecting Dockerfile ==="

if [ ! -f /root/pyapp/Dockerfile ]; then
    echo "ERROR: /root/pyapp/Dockerfile not found"
    exit 1
fi

echo "--- Dockerfile contents ---"
cat /root/pyapp/Dockerfile
echo "---"

CONTAINER_PORT=$(grep -iE "^EXPOSE" /root/pyapp/Dockerfile | awk '{print $2}' | head -1)
CONTAINER_PORT=${CONTAINER_PORT:-5000}
echo "Container port: $CONTAINER_PORT"

# ============================================================
# STEP 3: BUILD + TAG + PUSH DOCKER IMAGE TO ECR
# ============================================================

echo ""
echo "=== Step 3: Building Docker image ==="

cd /root/pyapp
docker build -t ${REPO_NAME}:latest .
echo "Build complete"

docker tag ${REPO_NAME}:latest ${ECR_URI}:latest
echo "Tagged: ${ECR_URI}:latest"

echo "Authenticating to ECR..."
aws ecr get-login-password --region $REGION | \
    docker login --username AWS --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Pushing image..."
docker push ${ECR_URI}:latest
echo "Push complete"

# Verify image is in ECR
echo ""
echo "=== ECR Image Verification ==="
aws ecr describe-images --repository-name $REPO_NAME --region $REGION \
    --query "imageDetails[*].{Tag:imageTags[0],Pushed:imagePushedAt,SizeBytes:imageSizeInBytes}" \
    --output table

# ============================================================
# STEP 4: ENSURE ECS TASK EXECUTION ROLE EXISTS
# This role allows ECS to pull from ECR + write CloudWatch Logs
# ============================================================

echo ""
echo "=== Step 4: Checking ECS task execution role ==="

if aws iam get-role --role-name $EXEC_ROLE_NAME >/dev/null 2>&1; then
    echo "Role '$EXEC_ROLE_NAME' already exists"
else
    echo "Creating '$EXEC_ROLE_NAME'..."

    aws iam create-role \
        --role-name $EXEC_ROLE_NAME \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        --description "Allows ECS tasks to pull ECR images and write CloudWatch logs"

    aws iam attach-role-policy \
        --role-name $EXEC_ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

    echo "Waiting for role propagation..."
    sleep 15
fi

EXEC_ROLE_ARN=$(aws iam get-role --role-name $EXEC_ROLE_NAME \
    --query "Role.Arn" --output text)
echo "Execution role ARN: $EXEC_ROLE_ARN"

# ============================================================
# STEP 5: CREATE CLOUDWATCH LOG GROUP FOR CONTAINER LOGS
# ============================================================

echo ""
echo "=== Step 5: Creating CloudWatch log group ==="

aws logs create-log-group \
    --log-group-name "/ecs/${TASK_DEF_NAME}" --region $REGION \
    2>/dev/null && echo "Log group created" || echo "Already exists"

# ============================================================
# STEP 6: REGISTER ECS TASK DEFINITION (FARGATE)
# networkMode MUST be awsvpc for Fargate
# cpu/memory MUST be at task level (not just container level)
# ============================================================

echo ""
echo "=== Step 6: Registering task definition '$TASK_DEF_NAME' ==="

cat > /tmp/task-definition.json << EOF
{
    "family": "${TASK_DEF_NAME}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "512",
    "memory": "1024",
    "executionRoleArn": "${EXEC_ROLE_ARN}",
    "containerDefinitions": [
        {
            "name": "${CONTAINER_NAME}",
            "image": "${ECR_URI}:latest",
            "essential": true,
            "portMappings": [
                {
                    "containerPort": ${CONTAINER_PORT},
                    "hostPort": ${CONTAINER_PORT},
                    "protocol": "tcp"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/${TASK_DEF_NAME}",
                    "awslogs-region": "${REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ]
}
EOF

echo "Task definition JSON:"
cat /tmp/task-definition.json

TASK_DEF_ARN=$(aws ecs register-task-definition \
    --region $REGION \
    --cli-input-json file:///tmp/task-definition.json \
    --query "taskDefinition.taskDefinitionArn" --output text)

echo "Task Definition ARN: $TASK_DEF_ARN"

# ============================================================
# STEP 7: CREATE ECS CLUSTER (FARGATE)
# ============================================================

echo ""
echo "=== Step 7: Creating ECS cluster '$CLUSTER_NAME' ==="

aws ecs create-cluster \
    --cluster-name $CLUSTER_NAME \
    --capacity-providers FARGATE \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
    --region $REGION \
    --tags key=Name,value=$CLUSTER_NAME

echo "Cluster created: $CLUSTER_NAME"

aws ecs describe-clusters --clusters $CLUSTER_NAME --region $REGION \
    --query "clusters[0].{Name:clusterName,Status:status}" --output table

# ============================================================
# STEP 8: GET NETWORKING RESOURCES FOR ECS SERVICE
# ============================================================

echo ""
echo "=== Step 8: Resolving networking for ECS service ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

SUBNET_ID=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" --output text)

DEFAULT_SG=$(aws ec2 describe-security-groups --region $REGION \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text)

echo "VPC: $VPC_ID | Subnet: $SUBNET_ID | SG: $DEFAULT_SG"

# Open the container port on the security group
aws ec2 authorize-security-group-ingress \
    --group-id $DEFAULT_SG --protocol tcp \
    --port $CONTAINER_PORT --cidr 0.0.0.0/0 \
    --region $REGION \
    2>/dev/null && echo "Port $CONTAINER_PORT opened on SG" \
    || echo "Port rule may already exist"

# ============================================================
# STEP 9: CREATE ECS SERVICE
# ============================================================

echo ""
echo "=== Step 9: Creating ECS service '$SERVICE_NAME' ==="

aws ecs create-service \
    --region $REGION \
    --cluster $CLUSTER_NAME \
    --service-name $SERVICE_NAME \
    --task-definition $TASK_DEF_NAME \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={
        subnets=[${SUBNET_ID}],
        securityGroups=[${DEFAULT_SG}],
        assignPublicIp=ENABLED
    }" \
    --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200" \
    --tags key=Name,value=$SERVICE_NAME

echo "Service created: $SERVICE_NAME"

# ============================================================
# STEP 10: WAIT FOR SERVICE TO STABILISE
# ============================================================

echo ""
echo "=== Step 10: Waiting for service to stabilise (2-5 min) ==="

aws ecs wait services-stable \
    --cluster $CLUSTER_NAME \
    --services $SERVICE_NAME \
    --region $REGION

echo "Service is stable"

# ============================================================
# STEP 11: VERIFY RUNNING TASK AND GET TASK IP
# ============================================================

echo ""
echo "=== Step 11: Verification ==="

echo "--- Service Status ---"
aws ecs describe-services \
    --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $REGION \
    --query "services[0].{Status:status,Running:runningCount,Desired:desiredCount,Pending:pendingCount}" \
    --output table

TASK_ARN=$(aws ecs list-tasks \
    --cluster $CLUSTER_NAME --service-name $SERVICE_NAME \
    --region $REGION --query "taskArns[0]" --output text)

echo ""
echo "--- Running Task ---"
aws ecs describe-tasks \
    --cluster $CLUSTER_NAME --tasks $TASK_ARN --region $REGION \
    --query "tasks[0].{Status:lastStatus,DesiredStatus:desiredStatus,StartedAt:startedAt}" \
    --output table

# Get the task's public IP
TASK_ENI=$(aws ecs describe-tasks \
    --cluster $CLUSTER_NAME --tasks $TASK_ARN --region $REGION \
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
    --output text 2>/dev/null)

TASK_IP=$(aws ec2 describe-network-interfaces \
    --network-interface-ids $TASK_ENI --region $REGION \
    --query "NetworkInterfaces[0].Association.PublicIp" \
    --output text 2>/dev/null || echo "N/A")

echo ""
echo "============================================"
echo "  ECR Repository: devops-ecr"
echo "  Image URI:       ${ECR_URI}:latest"
echo "  ECS Cluster:     $CLUSTER_NAME"
echo "  Task Definition: $TASK_DEF_NAME"
echo "  ECS Service:     $SERVICE_NAME"
echo "  Running Task:    $TASK_ARN"
echo "  Task Public IP:  $TASK_IP"
echo ""
echo "  Test URL: http://$TASK_IP:$CONTAINER_PORT"
echo "  Logs: aws logs tail /ecs/$TASK_DEF_NAME --region $REGION"
echo "============================================"

# ============================================================
# CLEANUP (run only when tearing down)
# ============================================================

# # Scale down and delete service first
# aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME \
#     --desired-count 0 --region $REGION
# aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME \
#     --force --region $REGION

# # Deregister task definition
# aws ecs deregister-task-definition --task-definition ${TASK_DEF_NAME}:1 --region $REGION

# # Delete cluster
# aws ecs delete-cluster --cluster $CLUSTER_NAME --region $REGION

# # Delete ECR repo and images
# aws ecr delete-repository --repository-name $REPO_NAME --force --region $REGION
