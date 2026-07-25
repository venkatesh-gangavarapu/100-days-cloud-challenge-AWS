# Day 43 — Amazon EKS: Private Kubernetes Cluster Provisioning

> **#100DaysOfCloud | Day 43 of 100**

---

## 📌 The Task

> *Create a private EKS cluster (`xfusion-eks`) on the latest stable Kubernetes version, using a custom IAM role, default VPC subnets across three AZs, with EKS Auto Mode disabled and a private-only API endpoint.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Cluster name | `xfusion-eks` |
| Configuration type | Custom configuration |
| IAM role | `eksClusterRole` |
| Kubernetes version | Latest stable |
| EKS Auto Mode | **Disabled** |
| Endpoint access | **Private only** (public off) |
| VPC | Default VPC |
| Availability Zones | `us-east-1a`, `us-east-1b`, `us-east-1c` |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### What Is Amazon EKS?

**Amazon Elastic Kubernetes Service (EKS)** is a fully managed Kubernetes control plane. AWS manages the Kubernetes API server, etcd, and control plane components across multiple AZs — you never see or patch those nodes. You're responsible for the worker nodes (EC2 instances or Fargate) that run your pods.

EKS integrates natively with IAM, VPC networking, ALB, CloudWatch, ECR, and other AWS services, making Kubernetes workloads behave like native AWS resources.

### EKS Auto Mode vs Custom Configuration

EKS introduced **Auto Mode** as a "fully automatic" cluster configuration where EKS also manages the worker node infrastructure, scaling, and compute provisioning automatically. This task explicitly requires **disabling** Auto Mode to maintain full control over compute and configuration choices.

**Custom configuration** is the traditional approach where you:
- Control which AZs and subnets the cluster spans
- Choose the endpoint access model
- Manage node groups manually after cluster creation

### Private vs Public Endpoint Access

The EKS cluster API endpoint controls how `kubectl` and worker nodes reach the Kubernetes control plane:

| Mode | `endpointPublicAccess` | `endpointPrivateAccess` | Who can reach the API |
|------|----------------------|------------------------|----------------------|
| **Public** | `true` | `false` | Anyone with the right credentials, over the internet |
| **Public + Private** | `true` | `true` | Internet access + VPC-internal access |
| **Private only** | `false` | `true` | Only resources inside the VPC |

This task requires **Private only** (`endpointPublicAccess=false`, `endpointPrivateAccess=true`). This means:
- `kubectl` must be run from inside the VPC (or via VPN/Direct Connect)
- Worker nodes communicate with the control plane over the VPC's private network
- The Kubernetes API endpoint has no internet-facing exposure

### The eksClusterRole — Two Separate Roles

EKS requires two distinct IAM roles (one of which is this task's requirement):

| Role | Used by | Policy required |
|------|---------|-----------------|
| **Cluster role** (`eksClusterRole`) | EKS control plane | `AmazonEKSClusterPolicy` |
| **Node role** | EC2 worker nodes | `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy` |

Today's task only creates the cluster itself (no node groups yet), so only the cluster role is needed.

### Multi-AZ Subnet Requirement

EKS requires subnets in at least two AZs for high availability. Subnets in `us-east-1a`, `us-east-1b`, and `us-east-1c` mean the control plane communicates with nodes across all three — pod scheduling and service routing can spread across AZs automatically, tolerating a single AZ failure.

### How Long Does Cluster Creation Take?

Creating an EKS cluster takes **10–15 minutes** regardless of method. This time is spent:
- AWS provisioning the control plane Kubernetes nodes in multiple AZs
- Setting up etcd
- Configuring VPC networking (ENIs, security groups)
- Enabling the API endpoint (private or public)

There's no way to speed this up — use `aws eks wait cluster-active` to block until it's done.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

#### Part 1 — Create the IAM Cluster Role (if not existing)

1. **IAM Console → Roles → Create role**
2. Trusted entity: **AWS service** | Use case: **EKS** → **EKS - Cluster** → Next
3. `AmazonEKSClusterPolicy` is pre-attached → Next
4. Role name: `eksClusterRole` → **Create role**

#### Part 2 — Create the EKS Cluster

1. **EKS Console → Clusters → Create cluster**
2. Select **Custom configuration** (not Quick configuration)
3. Fill in:
   - Cluster name: `xfusion-eks`
   - Kubernetes version: select **latest** (1.32 or highest available)
   - Cluster IAM role: `eksClusterRole`
   - **EKS Auto Mode:** toggle to **Disabled** / Off
4. Click **Next**

#### Part 3 — Configure Networking

1. VPC: select the **default VPC**
2. Subnets: select the default subnets for **us-east-1a**, **us-east-1b**, **us-east-1c**
3. Security groups: leave the default
4. **Cluster endpoint access:**
   - Public access: ❌ **Off**
   - Private access: ✅ **On**
5. Click **Next**

#### Part 4 — Configure Observability → Next (defaults)

#### Part 5 — Select Add-Ons → Next (defaults)

#### Part 6 — Review and Create

Confirm settings:
- Name: `xfusion-eks`
- Role: `eksClusterRole`
- Auto Mode: Disabled
- Endpoint: Private
- Subnets: 3 AZs

Click **Create** → ⏳ Wait 10–15 minutes for **Active**

---

### Method 2 — AWS CLI

```bash
#!/bin/bash
set -e
REGION="us-east-1"
CLUSTER_NAME="xfusion-eks"

# ============================================================
# STEP 1: Create eksClusterRole if it doesn't exist
# ============================================================

echo "=== Step 1: Ensuring eksClusterRole exists ==="

if aws iam get-role --role-name eksClusterRole >/dev/null 2>&1; then
    echo "Role already exists"
else
    cat > /tmp/eks-trust-policy.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": { "Service": "eks.amazonaws.com" },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

    aws iam create-role \
        --role-name eksClusterRole \
        --assume-role-policy-document file:///tmp/eks-trust-policy.json \
        --description "EKS cluster control plane role"

    aws iam attach-role-policy \
        --role-name eksClusterRole \
        --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

    echo "Role created"
    sleep 10
fi

ROLE_ARN=$(aws iam get-role --role-name eksClusterRole --query "Role.Arn" --output text)
echo "Role ARN: $ROLE_ARN"

# ============================================================
# STEP 2: Resolve default VPC and subnets (us-east-1a/b/c)
# ============================================================

echo ""
echo "=== Step 2: Resolving VPC and subnets ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

# Get subnet IDs for us-east-1a, b, c only
SUBNETS=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
    --query "Subnets[?AvailabilityZone=='us-east-1a' || AvailabilityZone=='us-east-1b' || AvailabilityZone=='us-east-1c'].SubnetId" \
    --output text | tr '\t' ' ')

DEFAULT_SG=$(aws ec2 describe-security-groups --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text)

echo "VPC: $VPC_ID"
echo "Subnets: $SUBNETS"
echo "Default SG: $DEFAULT_SG"

# Format subnets as comma-separated string for the CLI
SUBNET_CSV=$(echo $SUBNETS | tr ' ' ',')

# ============================================================
# STEP 3: Create the EKS cluster
# endpointPublicAccess=false → private only
# endpointPrivateAccess=true → VPC-internal access enabled
# ============================================================

echo ""
echo "=== Step 3: Creating EKS cluster '$CLUSTER_NAME' ==="

aws eks create-cluster \
    --region $REGION \
    --name $CLUSTER_NAME \
    --role-arn $ROLE_ARN \
    --resources-vpc-config subnetIds=$SUBNET_CSV,securityGroupIds=$DEFAULT_SG,endpointPublicAccess=false,endpointPrivateAccess=true \
    --tags Name=$CLUSTER_NAME,ManagedBy=CLI

echo "Cluster creation initiated — waiting for ACTIVE (10-15 min)..."

aws eks wait cluster-active \
    --name $CLUSTER_NAME \
    --region $REGION

echo "Cluster is ACTIVE"

# ============================================================
# STEP 4: Verify the cluster configuration
# ============================================================

echo ""
echo "=== Step 4: Verification ==="

aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
    --query "cluster.{
        Name:name,
        Status:status,
        Version:version,
        Role:roleArn,
        PrivateEndpoint:resourcesVpcConfig.endpointPrivateAccess,
        PublicEndpoint:resourcesVpcConfig.endpointPublicAccess,
        Subnets:resourcesVpcConfig.subnetIds
    }" --output table

echo ""
echo "============================================"
echo "  Cluster:         $CLUSTER_NAME"
echo "  Status:          ACTIVE"
echo "  IAM Role:        eksClusterRole"
echo "  Endpoint:        Private only ✅"
echo "  EKS Auto Mode:   Disabled ✅"
echo "  AZs:             us-east-1a, b, c"
echo "============================================"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CREATE CLUSTER ROLE ---
aws iam create-role --role-name eksClusterRole \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name eksClusterRole \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

# --- CREATE EKS CLUSTER ---
aws eks create-cluster --name xfusion-eks \
    --role-arn $ROLE_ARN --region $REGION \
    --resources-vpc-config subnetIds=$SUBNET_CSV,securityGroupIds=$SG,\
endpointPublicAccess=false,endpointPrivateAccess=true

# --- WAIT ---
aws eks wait cluster-active --name xfusion-eks --region $REGION

# --- VERIFY ---
aws eks describe-cluster --name xfusion-eks --region $REGION \
    --query "cluster.{Status:status,PrivateEndpoint:resourcesVpcConfig.endpointPrivateAccess,PublicEndpoint:resourcesVpcConfig.endpointPublicAccess}"

# --- LIST CLUSTERS ---
aws eks list-clusters --region $REGION

# --- GET KUBECONFIG (only works when in the VPC — private endpoint) ---
aws eks update-kubeconfig --name xfusion-eks --region $REGION

# --- DELETE CLUSTER ---
aws eks delete-cluster --name xfusion-eks --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Not creating eksClusterRole before attempting cluster creation**
The cluster creation fails immediately if the named IAM role doesn't exist or doesn't have `eks.amazonaws.com` in its trust policy. The role must be created separately — it's not auto-created by EKS. The role also needs `AmazonEKSClusterPolicy` attached; without it, the cluster creation may succeed but the control plane won't function correctly.

**2. Selecting only one subnet / one AZ**
EKS recommends subnets in at least two AZs. Selecting only `us-east-1a` creates a cluster with no AZ redundancy for the control plane-to-node communication path. The task specifically requires all three (a, b, c).

**3. Leaving EKS Auto Mode enabled when the task requires it disabled**
In the console, Auto Mode is the default or prominently positioned option. The task explicitly requires disabling it. Look for the toggle in the cluster configuration section and ensure it's set to Off/Disabled before proceeding.

**4. Confusing the cluster endpoint with the node API endpoint**
Setting endpoint access to private makes the Kubernetes API endpoint private. This means `kubectl` commands from outside the VPC (including from `aws-client` if it's not in the VPC) will fail after cluster creation. You'd need to be inside the VPC, or use an SSM bastion / VPN to access a private endpoint cluster. For this task, creation and verification via the EKS API (`aws eks describe-cluster`) still works from anywhere since that's the AWS management API — only the Kubernetes API endpoint (`kubectl`) requires VPC access.

**5. Attempting to use the cluster immediately before it's ACTIVE**
EKS cluster creation takes 10–15 minutes. Trying to create node groups or run `kubectl` commands while the status is `CREATING` will fail. Always wait for `ACTIVE` status before any further cluster operations.

**6. Not knowing the difference between the cluster IAM role and the node IAM role**
The cluster role (`eksClusterRole`) is for the EKS control plane — it's what EKS uses to make AWS API calls on your behalf (ENI management, CloudWatch Logs, etc.). Worker node groups need a separate node role (`AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy`) — without the node role, nodes can't join the cluster or pull images from ECR.

---

## 🌍 Real-World Context

**Why private endpoints in production:** Exposing the Kubernetes API server to the public internet creates a significant attack surface — it's a high-value target for credential theft, unauthorized API access, and privilege escalation. Private-only endpoints mean the API is only reachable from within the VPC — operators connect via VPN, Direct Connect, or a bastion host. Most enterprise security standards mandate private endpoints for production EKS clusters.

**EKS vs ECS Fargate:** ECS Fargate (Day 38) and EKS both run containers on AWS, but at different levels of abstraction. ECS is simpler and tightly AWS-integrated — ideal when you want AWS to manage the container orchestration layer. EKS is Kubernetes-native — ideal when you have existing Kubernetes expertise, need ecosystem tooling (Helm, ArgoCD, Istio, Prometheus), or need portability across cloud providers. EKS costs more (hourly cluster fee + node costs) and has more operational surface area.

**What comes after this:** A cluster alone can't run workloads. The next steps in a real deployment would be: add node groups (EC2 managed node groups or Fargate profiles), configure the AWS Load Balancer Controller (for ALB integration), set up the EBS/EFS CSI driver (for persistent storage), configure IRSA (IAM Roles for Service Accounts — the Kubernetes equivalent of EC2 instance profiles), and optionally enable cluster autoscaler or Karpenter for dynamic node scaling.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. What is the difference between EKS Auto Mode and standard EKS?**
> EKS Auto Mode is a newer managed mode where AWS also takes responsibility for the worker node infrastructure — node provisioning, scaling, AMI updates, and compute management are handled automatically by EKS, removing the need to manage node groups explicitly. Standard EKS (Custom configuration) gives you full control: you create and manage node groups yourself, choose instance types, AMIs, scaling policies, and launch configurations. Auto Mode is ideal for teams that want to focus entirely on application deployment and avoid infrastructure management; Custom configuration is for teams with specific compute requirements, cost optimization strategies, or compliance requirements around node configuration.

**Q2. Why does EKS cluster creation require an IAM role with the `eks.amazonaws.com` principal in its trust policy?**
> The EKS cluster role is assumed by the EKS service (`eks.amazonaws.com`) to make AWS API calls on behalf of the cluster. These calls include creating and managing Elastic Network Interfaces (ENIs) in your VPC for communication between the control plane and worker nodes, writing control plane logs to CloudWatch Logs if enabled, and integrating with other AWS services. Without the `eks.amazonaws.com` principal in the trust policy, the EKS service cannot assume the role, and cluster creation fails. The `AmazonEKSClusterPolicy` permission set gives the assumed role exactly the permissions it needs — no more.

**Q3. What's the difference between the EKS cluster endpoint access modes (public, private, both)?**
> The cluster endpoint is the Kubernetes API server URL that `kubectl` and worker nodes use to communicate with the control plane. Public mode exposes this endpoint on the internet — anyone with valid credentials can reach the API from anywhere. Private mode restricts the endpoint to the VPC — only resources inside the VPC (worker nodes, internal tooling, VPN-connected clients) can reach the Kubernetes API. Public + Private mode enables both paths simultaneously. In production, private-only is the most secure choice; it eliminates internet-facing exposure of the Kubernetes API but requires that operators access the cluster from within the VPC. The trade-off: private endpoints require VPN or bastion infrastructure to operate, while public endpoints are operationally simpler but expose more attack surface.

**Q4. What IAM policies are required for EKS worker nodes and why are they different from the cluster role?**
> Worker nodes need three policies. `AmazonEKSWorkerNodePolicy` allows nodes to register with the cluster, report health, and receive scheduling instructions. `AmazonEC2ContainerRegistryReadOnly` allows nodes to pull container images from ECR — without this, pods fail to start if their images are in ECR. `AmazonEKS_CNI_Policy` allows the VPC CNI plugin (`aws-node` DaemonSet) to manage ENIs and IP addresses on worker nodes — this is how Kubernetes pods get VPC IP addresses in EKS. The cluster role is for the control plane operations (ENI creation at the cluster level, CloudWatch logging); the node role is for node-level operations (joining the cluster, pulling images, managing pod networking).

**Q5. Why must an EKS cluster span multiple AZs, and what happens if one AZ goes down?**
> EKS runs the Kubernetes control plane (API server, etcd, controller manager) across multiple AZs internally for high availability — you never manage this directly. For worker nodes, multi-AZ subnets mean pods can be scheduled across AZs, and Kubernetes services can route traffic to healthy pods regardless of which AZ they're in. If one AZ fails: pods in that AZ become unreachable, the scheduler places new pods in the remaining AZs, and an appropriately configured Horizontal Pod Autoscaler (HPA) may scale up to compensate. For stateful workloads with persistent volumes, AZ failure requires that volumes be replicated across AZs (EFS supports this natively; EBS is AZ-scoped and requires cross-AZ replication or planned failover).

**Q6. How do you securely give a Kubernetes pod access to AWS services (like S3 or DynamoDB) without hardcoding credentials?**
> Use **IRSA (IAM Roles for Service Accounts)**. This is the Kubernetes equivalent of EC2 instance profiles. You create an IAM role with the necessary permissions (e.g., `s3:GetObject` on a specific bucket), configure the EKS OIDC provider to allow Kubernetes service accounts from your cluster to assume roles, annotate the Kubernetes service account with the IAM role ARN, and associate that service account with your pod. The pod's AWS SDK automatically discovers and uses temporary credentials from the projected service account token — no access keys, no secrets in environment variables, no secrets in Kubernetes secrets. Full audit trail in CloudTrail per-pod. This is the mandatory approach for any production EKS workload accessing AWS services.

**Q7. You've created a private-endpoint EKS cluster. How do you now run `kubectl` commands against it?**
> Since the Kubernetes API endpoint is only reachable from within the VPC, you have several options. SSM Session Manager with port forwarding: an EC2 instance in the VPC can proxy `kubectl` traffic through an SSM session — `aws ssm start-session --target bastion-id --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host=cluster-endpoint,portNumber=443,localPortNumber=8443`. VPN/Direct Connect: if your laptop is connected to the VPC via Client VPN or a corporate Direct Connect, you can run `kubectl` locally — `aws eks update-kubeconfig` generates the kubeconfig, and the VPN provides the network path. A jump host/bastion EC2: SSH into an EC2 instance inside the VPC and run `kubectl` there. AWS Cloud9: an IDE instance in the VPC can run `kubectl` directly. For CI/CD pipelines, running the pipeline runner (CodeBuild, GitHub Actions self-hosted runner) inside the VPC is the standard approach for private clusters.

---

---

## 📍 Proof of Work

This learning is documented and shared on LinkedIn:
- [View on LinkedIn](https://www.linkedin.com/posts/venkatesh-gangavarapu_100daysofcloud-aws-eks-share-7483841336224407552-PU8h/)

## 📚 Resources

- [AWS Docs — Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html)
- [EKS Cluster IAM Role](https://docs.aws.amazon.com/eks/latest/userguide/service_IAM_role.html)
- [EKS Endpoint Access](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html)
- [IRSA — IAM Roles for Service Accounts](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
