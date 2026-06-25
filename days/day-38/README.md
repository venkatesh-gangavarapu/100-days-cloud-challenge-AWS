# Day 38 — Containerized App Deployment: ECR + ECS Fargate

> **#100DaysOfCloud | Day 38 of 100**

---

## 📌 The Task

> *Build a Docker image from an existing Dockerfile, push it to a private ECR repository, create an ECS Fargate cluster, define a task definition, and deploy it as a running ECS service.*

**Requirements:**
| Resource | Detail |
|----------|--------|
| ECR Repository | `devops-ecr` — private |
| Docker image | Built from `/root/pyapp/Dockerfile` on `aws-client` |
| Image tag | `latest` |
| ECS Cluster | `devops-cluster` — Fargate launch type |
| Task Definition | `devops-taskdefinition` — uses `devops-ecr` image |
| ECS Service | `devops-service` — at least 1 running task |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### ECS vs EC2 — What Fargate Changes

**Amazon ECS (Elastic Container Service)** is AWS's container orchestration service — it manages when and where containers run, handles scheduling, replacement of failed tasks, and scaling.

ECS supports two launch types:

| | **EC2 Launch Type** | **Fargate Launch Type** |
|--|--------------------|-----------------------|
| **Infrastructure** | You provision EC2 instances (ECS agents installed) | AWS provisions and manages the compute |
| **Cluster management** | You patch, scale, and maintain EC2 nodes | Fully managed — no instances to manage |
| **Billing** | Pay for EC2 instances regardless of utilisation | Pay per task (vCPU + memory per second) |
| **Networking** | EC2 networking rules | Each task gets its own ENI |
| **Use case** | Cost optimisation at scale, custom hardware | Simplicity, low-ops, burst workloads |

**Fargate** (the choice in this task) eliminates the EC2 layer entirely. You define what you want to run (the task definition) and Fargate provisions invisible compute on demand. No EC2 instances appear in your account.

### The Three Building Blocks of ECS

```
ECR (image registry)
    │  Docker image stored here
    ▼
Task Definition (blueprint)
    │  Defines: which image, how much CPU/memory, ports, env vars, log config
    ▼
ECS Service (runs and maintains tasks)
    │  Maintains N running tasks from the definition
    │  Restarts failed tasks automatically
    ▼
Running Task(s) — your container(s), actually executing
```

### Task Definition — What Goes In It

A task definition is the "recipe" for your container workload:
- **Container image URI** — the ECR image to pull
- **CPU and memory** — `0.5 vCPU` / `1 GB` for Fargate (or `256` cpu units / `512` MB)
- **Port mappings** — which container ports to expose
- **Environment variables** — runtime config passed to the container
- **Log configuration** — typically CloudWatch Logs via `awslogs` driver
- **Task execution role** — the IAM role that allows ECS to pull from ECR and write logs

### The Task Execution Role — Why It's Required

Fargate needs to pull your Docker image from ECR and send container logs to CloudWatch Logs. It does this using the **task execution role** (`ecsTaskExecutionRole`). Without this role, the task fails to start with an error about not being able to pull the image. The `AmazonECSTaskExecutionRolePolicy` managed policy grants exactly what's needed:

```json
{
  "ecr:GetAuthorizationToken",
  "ecr:BatchCheckLayerAvailability",
  "ecr:GetDownloadUrlForLayer",
  "ecr:BatchGetImage",
  "logs:CreateLogStream",
  "logs:PutLogEvents"
}
```

### ECS Service vs Running a Task Directly

You can run a task directly (`aws ecs run-task`) without a service — it starts once and stops. A **service** is the persistent operator: it declares that N copies of the task should always be running, replaces failed tasks automatically, integrates with ALBs for load balancing, and handles deployment rolling updates. For anything meant to stay running, use a service.

### Fargate Networking — ENI per Task

Each Fargate task gets its own Elastic Network Interface (ENI) with a private IP. If you enable "public IP," it also gets a public IP. This means security group rules apply per-task, and each task can be independently targeted by ALBs. Compare this to EC2 launch type where multiple tasks share the EC2 instance's network interface.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Console + CLI (Docker steps require CLI)

#### Part 1 — ECR + Docker Build + Push (aws-client terminal)

```bash
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
REPO_NAME="devops-ecr"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"

# Create ECR repository
aws ecr create-repository --repository-name $REPO_NAME \
    --region $REGION --image-scanning-configuration scanOnPush=true

# Build Docker image
cd /root/pyapp
docker build -t ${REPO_NAME}:latest .

# Tag for ECR
docker tag ${REPO_NAME}:latest ${ECR_URI}:latest

# Authenticate and push
aws ecr get-login-password --region $REGION | \
    docker login --username AWS --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

docker push ${ECR_URI}:latest

echo "Image URI: ${ECR_URI}:latest"
```

#### Part 2 — Create ECS Cluster (Console)

1. **ECS Console → Clusters → Create cluster**
2. Name: `devops-cluster`
3. Infrastructure: ✅ **AWS Fargate (serverless)** only
4. **Create**

#### Part 3 — Create Task Definition (Console)

1. **ECS Console → Task definitions → Create new task definition**
2. Family: `devops-taskdefinition`
3. Infrastructure: **AWS Fargate** | CPU: `.5 vCPU` | Memory: `1 GB`
4. Task execution role: `ecsTaskExecutionRole`
5. Container → name: `devops-container`
6. Image URI: `ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/devops-ecr:latest`
7. Container port: check the Dockerfile — `5000` for Flask, `80` for Nginx/Apache
8. **Create**

#### Part 4 — Create ECS Service (Console)

1. **ECS Console → Clusters → devops-cluster → Services → Create**
2. Launch type: **FARGATE** | Platform: **LATEST**
3. Task definition: `devops-taskdefinition` (LATEST revision)
4. Service name: `devops-service` | Desired tasks: `1`
5. Networking: default VPC, at least one subnet, Public IP: **On**
6. **Create**

#### Part 5 — Verify (Console)

- **Clusters → devops-cluster → Services → devops-service → Tasks tab**
- Wait for task status: **RUNNING**
- Click the task → check **Logs** tab

---

### Method 2 — Full AWS CLI Script

```bash
#!/bin/bash
set -e
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
REPO_NAME="devops-ecr"
CLUSTER_NAME="devops-cluster"
TASK_DEF_NAME="devops-taskdefinition"
SERVICE_NAME="devops-service"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"
CONTAINER_NAME="devops-container"

echo "Account: $ACCOUNT_ID"
echo "Image URI: ${ECR_URI}:latest"

# ============================================================
# STEP 1: Create ECR repository
# ============================================================

echo ""
echo "=== Step 1: Creating ECR repository '$REPO_NAME' ==="

aws ecr create-repository \
    --repository-name $REPO_NAME \
    --region $REGION \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE \
    --tags Key=Name,Value=$REPO_NAME

echo "Repository created: $ECR_URI"

# ============================================================
# STEP 2: Build, tag, and push the Docker image
# ============================================================

echo ""
echo "=== Step 2: Build + push Docker image ==="

# Check Dockerfile exists
if [ ! -f /root/pyapp/Dockerfile ]; then
    echo "ERROR: /root/pyapp/Dockerfile not found"
    exit 1
fi

echo "Dockerfile:"
cat /root/pyapp/Dockerfile

# Get the exposed port from Dockerfile
CONTAINER_PORT=$(grep -i "^EXPOSE" /root/pyapp/Dockerfile | awk '{print $2}' | head -1)
CONTAINER_PORT=${CONTAINER_PORT:-5000}  # Default to 5000 for Python apps
echo "Container port from Dockerfile: $CONTAINER_PORT"

cd /root/pyapp
docker build -t ${REPO_NAME}:latest .
docker tag ${REPO_NAME}:latest ${ECR_URI}:latest

# Authenticate and push
aws ecr get-login-password --region $REGION | \
    docker login --username AWS --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

docker push ${ECR_URI}:latest

# Verify image is in ECR
aws ecr describe-images --repository-name $REPO_NAME --region $REGION \
    --query "imageDetails[*].{Tag:imageTags[0],Pushed:imagePushedAt,Size:imageSizeInBytes}" \
    --output table

# ============================================================
# STEP 3: Create or get the ECS task execution role
# ============================================================

echo ""
echo "=== Step 3: Ensuring task execution role exists ==="

EXEC_ROLE_NAME="ecsTaskExecutionRole"

if aws iam get-role --role-name $EXEC_ROLE_NAME >/dev/null 2>&1; then
    echo "Task execution role already exists"
else
    echo "Creating $EXEC_ROLE_NAME..."
    aws iam create-role \
        --role-name $EXEC_ROLE_NAME \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

    aws iam attach-role-policy \
        --role-name $EXEC_ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

    sleep 10
fi

EXEC_ROLE_ARN=$(aws iam get-role --role-name $EXEC_ROLE_NAME \
    --query "Role.Arn" --output text)
echo "Execution role ARN: $EXEC_ROLE_ARN"

# ============================================================
# STEP 4: Create CloudWatch log group for container logs
# ============================================================

echo ""
echo "=== Step 4: Creating CloudWatch log group ==="

aws logs create-log-group \
    --log-group-name "/ecs/${TASK_DEF_NAME}" \
    --region $REGION \
    2>/dev/null && echo "Log group created" || echo "Log group already exists"

# ============================================================
# STEP 5: Register ECS task definition (Fargate)
# ============================================================

echo ""
echo "=== Step 5: Registering task definition '$TASK_DEF_NAME' ==="

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

TASK_DEF_ARN=$(aws ecs register-task-definition \
    --region $REGION \
    --cli-input-json file:///tmp/task-definition.json \
    --query "taskDefinition.taskDefinitionArn" --output text)

echo "Task definition ARN: $TASK_DEF_ARN"

# ============================================================
# STEP 6: Create ECS cluster (Fargate)
# ============================================================

echo ""
echo "=== Step 6: Creating ECS cluster '$CLUSTER_NAME' ==="

aws ecs create-cluster \
    --cluster-name $CLUSTER_NAME \
    --capacity-providers FARGATE \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
    --region $REGION \
    --tags key=Name,value=$CLUSTER_NAME

echo "Cluster created: $CLUSTER_NAME"

# ============================================================
# STEP 7: Resolve networking for the ECS service
# ============================================================

echo ""
echo "=== Step 7: Resolving networking ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

SUBNET_ID=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" --output text)

DEFAULT_SG=$(aws ec2 describe-security-groups --region $REGION \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text)

# Open the container port on the SG
aws ec2 authorize-security-group-ingress \
    --group-id $DEFAULT_SG --protocol tcp \
    --port $CONTAINER_PORT --cidr 0.0.0.0/0 \
    --region $REGION 2>/dev/null || true

echo "VPC: $VPC_ID | Subnet: $SUBNET_ID | SG: $DEFAULT_SG"

# ============================================================
# STEP 8: Create ECS service
# ============================================================

echo ""
echo "=== Step 8: Creating ECS service '$SERVICE_NAME' ==="

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
    --tags key=Name,value=$SERVICE_NAME

echo "Service created: $SERVICE_NAME"

# ============================================================
# STEP 9: WAIT FOR SERVICE TO STABILISE AND VERIFY
# ============================================================

echo ""
echo "=== Step 9: Waiting for service to stabilise ==="

echo "This can take 2-5 minutes..."
aws ecs wait services-stable \
    --cluster $CLUSTER_NAME \
    --services $SERVICE_NAME \
    --region $REGION

echo "Service is stable"

# Show running tasks
echo ""
echo "=== Running Tasks ==="
TASK_ARN=$(aws ecs list-tasks \
    --cluster $CLUSTER_NAME --service-name $SERVICE_NAME \
    --region $REGION \
    --query "taskArns[0]" --output text)

aws ecs describe-tasks \
    --cluster $CLUSTER_NAME --tasks $TASK_ARN \
    --region $REGION \
    --query "tasks[0].{Status:lastStatus,Health:healthStatus,StartedAt:startedAt,CPU:cpu,Memory:memory}" \
    --output table

# Get public IP of the running task
TASK_ENI=$(aws ecs describe-tasks \
    --cluster $CLUSTER_NAME --tasks $TASK_ARN --region $REGION \
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
    --output text)

TASK_IP=$(aws ec2 describe-network-interfaces \
    --network-interface-ids $TASK_ENI --region $REGION \
    --query "NetworkInterfaces[0].Association.PublicIp" \
    --output text 2>/dev/null || echo "N/A")

echo ""
echo "============================================"
echo "  ECR Repo:    devops-ecr"
echo "  Image URI:   ${ECR_URI}:latest"
echo "  Cluster:     $CLUSTER_NAME"
echo "  Task Def:    $TASK_DEF_NAME"
echo "  Service:     $SERVICE_NAME"
echo "  Task ARN:    $TASK_ARN"
echo "  Task IP:     $TASK_IP"
echo "============================================"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/devops-ecr"

# --- ECR: CREATE + BUILD + PUSH ---
aws ecr create-repository --repository-name devops-ecr --region $REGION

cd /root/pyapp
docker build -t devops-ecr:latest .
docker tag devops-ecr:latest ${ECR_URI}:latest
aws ecr get-login-password --region $REGION | \
    docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
docker push ${ECR_URI}:latest

# --- ECS: CLUSTER ---
aws ecs create-cluster --cluster-name devops-cluster \
    --capacity-providers FARGATE --region $REGION

# --- ECS: TASK DEFINITION ---
aws ecs register-task-definition \
    --cli-input-json file:///tmp/task-definition.json --region $REGION

# --- ECS: SERVICE ---
aws ecs create-service \
    --cluster devops-cluster --service-name devops-service \
    --task-definition devops-taskdefinition --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=ENABLED}" \
    --region $REGION

# --- VERIFY ---
aws ecs describe-services \
    --cluster devops-cluster --services devops-service --region $REGION \
    --query "services[0].{Status:status,Running:runningCount,Desired:desiredCount}" \
    --output table

aws ecs list-tasks --cluster devops-cluster --service-name devops-service --region $REGION

# --- VIEW LOGS ---
aws logs tail /ecs/devops-taskdefinition --region $REGION --follow
```

---

## ⚠️ Common Mistakes

**1. Forgetting `assignPublicIp=ENABLED` on the Fargate service**
Fargate tasks in a public subnet need a public IP to pull the Docker image from ECR — ECR is a public endpoint. Without `ENABLED`, the task starts, fails to pull the image (`CannotPullContainerError`), and stops immediately. Either enable `assignPublicIp` or use a VPC Endpoint for ECR (for private subnets).

**2. Missing the task execution role**
The task execution role is different from the task role. The task role is for application code to call AWS services. The **execution role** is for ECS itself to pull images from ECR and push logs to CloudWatch. Without `ecsTaskExecutionRole` with `AmazonECSTaskExecutionRolePolicy`, every task fails to pull the image.

**3. Container port mismatch**
The port mapping in the task definition must match the port the application actually listens on inside the container (defined by `EXPOSE` in the Dockerfile, or the application's bind port). A mismatch means the task runs but is unreachable — health checks fail, ALB returns 502, direct access times out.

**4. Using `EC2` launch type arguments on a Fargate task definition**
Fargate task definitions require `"networkMode": "awsvpc"` and `"requiresCompatibilities": ["FARGATE"]`. Fargate also requires `cpu` and `memory` at the task level (not just the container level). Omitting these causes the task definition registration to fail or tasks to be rejected by Fargate.

**5. Task definition CPU/memory values outside Fargate's valid combinations**
Fargate doesn't accept arbitrary CPU/memory values. Valid combinations: 0.25 vCPU (256) with 512 MB–2 GB; 0.5 vCPU (512) with 1–4 GB; 1 vCPU (1024) with 2–8 GB; 2 vCPU (2048) with 4–16 GB; 4 vCPU (4096) with 8–30 GB. Specifying 512 CPU with 512 MB fails immediately.

**6. Not waiting for the service to stabilise before testing**
ECS services go through `PENDING → ACTIVATING → RUNNING` states. The service may show "1 desired" while the task is still pulling the image or initialising. `aws ecs wait services-stable` blocks until the running count matches the desired count — always wait before testing connectivity.

---

## 🌍 Real-World Context

The ECR + ECS Fargate pattern is AWS's fully-managed container platform — the production choice when you want the operational simplicity of "just run my container" without managing Kubernetes or EC2 nodes:

**CI/CD pipeline integration:** Every merge to main triggers: `docker build` → `docker push` to ECR (tagging with git commit SHA) → `aws ecs update-service --force-new-deployment` which triggers a rolling deployment. ECS pulls the new image, starts new tasks, waits for them to be healthy, then stops the old ones. Zero-downtime deployments built in.

**When to choose EKS instead of ECS:** ECS is simpler and tightly AWS-integrated. EKS (managed Kubernetes) provides portability (same workloads run on-prem or other clouds), richer ecosystem (Helm, ArgoCD, Istio), and more advanced scheduling. For teams already invested in Kubernetes tooling or needing multi-cloud portability, EKS is the right choice. For teams that just want to run containers on AWS with minimal operational overhead, ECS Fargate is often better.

**ECS with ALB:** For production services, the ECS service is wired to an ALB target group. ECS automatically registers and deregisters task IPs as tasks start and stop. The ALB handles health checks and traffic routing. Combined with Application Auto Scaling (scale in/out based on CPU/request metrics), this is the full production serverless container platform.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. What is the difference between an ECS task and an ECS service?**
> A task is a single running instance of a task definition — one execution of your container(s) that starts, runs, and eventually stops. Running a task directly is fire-and-forget: if it fails, nothing restarts it. A service is the persistent layer that manages tasks on your behalf: it declares that N tasks should always be running, automatically replaces failed tasks, integrates with load balancers, and handles rolling deployments when you update the task definition. Think of the task as the unit of work and the service as the operator that keeps that work running continuously.

**Q2. What is the task execution role and how does it differ from the task role?**
> The task execution role is used by the ECS control plane itself — specifically to pull the Docker image from ECR and push log output to CloudWatch Logs. It's the "credentials ECS uses to set up your task." The task role is used by the application code running inside the container — if your app needs to call S3, DynamoDB, or any other AWS service, it uses the task role's credentials (delivered via IMDS). You can have a task with an execution role but no task role (the app doesn't call AWS), a task role but no execution role (would fail to pull the image), or both. Both are IAM roles but with different principals and different scopes of use.

**Q3. Why does Fargate require `assignPublicIp=ENABLED` in a public subnet?**
> Fargate tasks need to pull their Docker image from ECR when they start. ECR is a public AWS service endpoint — even your private ECR repository is accessed over the public internet endpoint by default (unless you've set up VPC endpoints). A Fargate task in a public subnet without a public IP has no internet access and cannot reach the ECR endpoint, causing the task to fail immediately with `CannotPullContainerError`. The fix is either `assignPublicIp=ENABLED` (task gets a public IP and routes out via the subnet's Internet Gateway) or configuring ECR and CloudWatch Logs VPC endpoints so private subnet tasks can reach these services without internet access.

**Q4. How does an ECS rolling deployment work?**
> When you update a service (new task definition revision, or `--force-new-deployment`), ECS follows the service's deployment configuration: by default, it maintains at least 100% healthy tasks (minimum healthy percent = 100, maximum percent = 200) during the rollout. It starts new tasks with the updated task definition, waits for them to pass health checks, then stops old tasks — one batch at a time. If the new tasks fail health checks, the deployment stalls and eventually rolls back automatically. You can configure the deployment with `--deployment-configuration minimumHealthyPercent=50,maximumPercent=200` to trade faster deployments against temporary capacity reduction.

**Q5. What is the difference between ECS on Fargate vs EC2 launch type, and when would you choose EC2?**
> Fargate eliminates the need to provision or manage EC2 instances — you specify CPU and memory at the task level, AWS handles the compute. EC2 launch type requires you to maintain a cluster of EC2 instances (capacity, patching, scaling). Choose EC2 when: you need specific instance types (GPU for ML inference, high memory for in-memory databases), you want to optimize costs at large scale (EC2 Spot instances via ECS capacity providers are significantly cheaper than Fargate), or you have compliance requirements around multi-tenancy (EC2 tasks are isolated at the OS level on instances you control, while Fargate uses AWS-managed compute). For most new workloads, Fargate is simpler and the right default; EC2 becomes advantageous at significant scale or specific hardware requirements.

**Q6. A Fargate task starts and immediately stops. How do you diagnose it?**
> Check the ECS service events and the task's stopped reason: `aws ecs describe-tasks --cluster devops-cluster --tasks TASK_ARN` — the `stoppedReason` field often tells you exactly what failed (image pull failed, container exited with code 1, etc.). Then check CloudWatch Logs at `/ecs/devops-taskdefinition` for the container's stdout/stderr output up to the point of failure. Common causes: `CannotPullContainerError` (missing public IP or execution role permissions on ECR), `Essential container exited` (the application itself crashed — check logs for the actual exception), `ResourceInitializationError` (execution role can't write to CloudWatch Logs). The CloudWatch log group may be empty if the task failed before the container even started — in that case, the `stoppedReason` in the ECS API is the primary diagnostic.

**Q7. How would you make a Fargate service highly available across multiple AZs?**
> Two changes. First, set desired count to at least 2 (or more for critical services) and add multiple subnets from different AZs in the service's network configuration. ECS distributes tasks across the provided subnets, and if you provide subnets in three AZs, ECS uses a balanced spread placement strategy that tries to put one task per AZ. Second, add an ALB with target group integration so traffic is load-balanced across the tasks in different AZs — if one AZ loses connectivity, the ALB health checks detect the failed tasks and routes traffic only to healthy tasks in other AZs. Auto Scaling based on CPU or request metrics extends this to handle variable load while maintaining multi-AZ distribution.

---

## 📚 Resources

- [AWS Docs — Amazon ECS on Fargate](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html)
- [ECS Task Definitions](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definitions.html)
- [Task Execution IAM Role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html)
- [ECS Rolling Deployments](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-ecs.html)
- [Day 28 — ECR: Build and Push](../day-28/README.md)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
