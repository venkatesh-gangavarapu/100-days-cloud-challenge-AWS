# Day 28 — Create ECR Repository, Build Docker Image, and Push

> **#100DaysOfCloud | Day 28 of 100**

---

## 📌 The Task

> *Create a private ECR repository, build a Docker image from an existing Dockerfile, and push it to the registry with the `latest` tag.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| ECR Repository | `xfusion-ecr` (private) |
| Dockerfile location | `/root/pyapp/` on `aws-client` host |
| Image tag | `latest` |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### What Is Amazon ECR?

**Amazon Elastic Container Registry (ECR)** is a fully managed Docker container image registry. It's the AWS-native alternative to Docker Hub for storing, managing, and deploying container images — tightly integrated with ECS, EKS, Lambda, and CodePipeline.

| Feature | ECR | Docker Hub |
|---------|-----|------------|
| **Integration** | Native AWS IAM, ECS, EKS | Requires separate auth |
| **Privacy** | Private by default | Public by default |
| **Scanning** | Built-in vulnerability scanning | Paid feature |
| **Bandwidth** | Free within same region | Charges may apply |
| **Auth** | IAM-managed | Username/password |

### Private vs Public ECR Repositories

| Type | Use Case |
|------|---------|
| **Private** | Internal application images, proprietary code — requires IAM authentication |
| **Public** | Open-source images, public base images — accessible without credentials |

This task creates a **private** repository — the default and most common choice for application workloads.

### The ECR Authentication Flow

ECR uses **token-based authentication**. Docker doesn't natively know how to authenticate against ECR — you must first obtain a temporary auth token (valid 12 hours) using the AWS CLI, then pass it to Docker.

```
aws ecr get-login-password → (token) → docker login
        ↓
Docker stores the token for the ECR registry endpoint
        ↓
docker push → authenticated against ECR
```

The `get-login-password` command returns a 12-hour token. Piping it to `docker login` configures Docker to use that token for the ECR endpoint automatically.

### ECR Image URI Format

Every ECR image has a structured URI:

```
<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<REPOSITORY_NAME>:<TAG>

Example:
203777982394.dkr.ecr.us-east-1.amazonaws.com/xfusion-ecr:latest
```

You must tag your Docker image with this full URI before pushing — Docker uses the registry prefix to know where to push.

### The Docker Image Lifecycle in This Task

```
Dockerfile (/root/pyapp/)
        │
        ▼ docker build
Local image: xfusion-ecr:latest
        │
        ▼ docker tag
Tagged image: 203777982394.dkr.ecr.us-east-1.amazonaws.com/xfusion-ecr:latest
        │
        ▼ aws ecr get-login-password | docker login
Authentication configured for ECR endpoint
        │
        ▼ docker push
ECR repository: xfusion-ecr — image: latest
```

### ECR Lifecycle Policies

By default, ECR stores every image pushed — costs accumulate as images pile up. **Lifecycle Policies** automate cleanup: for example, keep only the 10 most recent images, or delete untagged images older than 7 days. This is a production necessity that's often overlooked on initial setup.

---

## 🔧 Step-by-Step Solution

### Full Script — Run on `aws-client`

```bash
#!/bin/bash
set -e

REGION="us-east-1"
REPO_NAME="xfusion-ecr"
IMAGE_TAG="latest"
DOCKERFILE_DIR="/root/pyapp"

# ============================================================
# STEP 1: Get AWS Account ID
# ============================================================
ACCOUNT_ID=$(aws sts get-caller-identity \
    --query "Account" \
    --output text)

echo "Account ID: $ACCOUNT_ID"
echo "Region: $REGION"

# Full ECR image URI
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:${IMAGE_TAG}"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "ECR URI: $ECR_URI"

# ============================================================
# STEP 2: Create the private ECR repository
# ============================================================
echo ""
echo "=== Step 2: Creating ECR repository '$REPO_NAME' ==="

aws ecr create-repository \
    --repository-name "$REPO_NAME" \
    --region "$REGION" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE \
    --tags Key=Name,Value="$REPO_NAME" \
           Key=ManagedBy,Value=cli

echo "Repository '$REPO_NAME' created"

# Get and display repository URI
REPO_URI=$(aws ecr describe-repositories \
    --repository-names "$REPO_NAME" \
    --region "$REGION" \
    --query "repositories[0].repositoryUri" \
    --output text)

echo "Repository URI: $REPO_URI"

# ============================================================
# STEP 3: Verify the Dockerfile exists
# ============================================================
echo ""
echo "=== Step 3: Verifying Dockerfile at $DOCKERFILE_DIR ==="

if [ ! -f "${DOCKERFILE_DIR}/Dockerfile" ]; then
    echo "ERROR: Dockerfile not found at ${DOCKERFILE_DIR}/Dockerfile"
    exit 1
fi

echo "Dockerfile found:"
cat "${DOCKERFILE_DIR}/Dockerfile"

# ============================================================
# STEP 4: Build the Docker image
# ============================================================
echo ""
echo "=== Step 4: Building Docker image ==="

docker build \
    --tag "${REPO_NAME}:${IMAGE_TAG}" \
    --file "${DOCKERFILE_DIR}/Dockerfile" \
    "${DOCKERFILE_DIR}"

echo "Docker image built: ${REPO_NAME}:${IMAGE_TAG}"

# Verify the image exists locally
docker images "${REPO_NAME}"

# ============================================================
# STEP 5: Tag the image with the full ECR URI
# ============================================================
echo ""
echo "=== Step 5: Tagging image with ECR URI ==="

docker tag \
    "${REPO_NAME}:${IMAGE_TAG}" \
    "${REPO_URI}:${IMAGE_TAG}"

echo "Image tagged: ${REPO_URI}:${IMAGE_TAG}"

# ============================================================
# STEP 6: Authenticate Docker to ECR
# (Token valid for 12 hours)
# ============================================================
echo ""
echo "=== Step 6: Authenticating Docker to ECR ==="

aws ecr get-login-password \
    --region "$REGION" | \
docker login \
    --username AWS \
    --password-stdin \
    "${ECR_REGISTRY}"

echo "Docker authenticated to $ECR_REGISTRY"

# ============================================================
# STEP 7: Push the image to ECR
# ============================================================
echo ""
echo "=== Step 7: Pushing image to ECR ==="

docker push "${REPO_URI}:${IMAGE_TAG}"

echo "Image pushed to ECR: ${REPO_URI}:${IMAGE_TAG}"

# ============================================================
# STEP 8: Verify the image is in ECR
# ============================================================
echo ""
echo "=== Step 8: Verification ==="

echo "--- Repository details ---"
aws ecr describe-repositories \
    --repository-names "$REPO_NAME" \
    --region "$REGION" \
    --query "repositories[0].{Name:repositoryName,URI:repositoryUri,Scan:imageScanningConfiguration.scanOnPush,Created:createdAt}" \
    --output table

echo ""
echo "--- Images in repository ---"
aws ecr describe-images \
    --repository-name "$REPO_NAME" \
    --region "$REGION" \
    --query "imageDetails[*].{Tag:imageTags[0],Digest:imageDigest,Size:imageSizeInBytes,Pushed:imagePushedAt}" \
    --output table

echo ""
echo "============================================"
echo "  Repository: $REPO_NAME"
echo "  URI:        $REPO_URI"
echo "  Image:      ${REPO_URI}:${IMAGE_TAG}"
echo "  Region:     $REGION"
echo "============================================"
```

---

### Verifying the Image in ECR

```bash
# List all images in the repository
aws ecr list-images \
    --repository-name xfusion-ecr \
    --region us-east-1 \
    --query "imageIds[*].{Tag:imageTag,Digest:imageDigest}" \
    --output table

# Get image details including size and scan status
aws ecr describe-images \
    --repository-name xfusion-ecr \
    --region us-east-1 \
    --query "imageDetails[*].{Tag:imageTags[0],SizeMB:imageSizeInBytes,Pushed:imagePushedAt,ScanStatus:imageScanStatus.status}" \
    --output table

# Pull the image back down to verify it's correct
docker pull 203777982394.dkr.ecr.us-east-1.amazonaws.com/xfusion-ecr:latest

# Run the image locally to test
docker run --rm 203777982394.dkr.ecr.us-east-1.amazonaws.com/xfusion-ecr:latest
```

---

### Adding a Lifecycle Policy (Production Best Practice)

```bash
# Keep only the 10 most recent images; delete untagged images after 1 day
aws ecr put-lifecycle-policy \
    --repository-name xfusion-ecr \
    --region us-east-1 \
    --lifecycle-policy-text '{
        "rules": [
            {
                "rulePriority": 1,
                "description": "Remove untagged images after 1 day",
                "selection": {
                    "tagStatus": "untagged",
                    "countType": "sinceImagePushed",
                    "countUnit": "days",
                    "countNumber": 1
                },
                "action": {"type": "expire"}
            },
            {
                "rulePriority": 2,
                "description": "Keep only 10 most recent tagged images",
                "selection": {
                    "tagStatus": "tagged",
                    "tagPrefixList": ["latest", "v"],
[O                    "countType": "imageCountMoreThan",
                    "countNumber": 10
                },
                "action": {"type": "expire"}
            }
        ]
    }'
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
REPO_NAME="xfusion-ecr"
REPO_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"

# --- CREATE ECR REPO ---
aws ecr create-repository \
    --repository-name "$REPO_NAME" \
    --region "$REGION" \
    --image-scanning-configuration scanOnPush=true

# --- BUILD IMAGE ---
docker build -t "${REPO_NAME}:latest" /root/pyapp/

# --- TAG FOR ECR ---
docker tag "${REPO_NAME}:latest" "${REPO_URI}:latest"

# --- AUTHENTICATE TO ECR ---
aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# --- PUSH ---
docker push "${REPO_URI}:latest"

# --- VERIFY ---
aws ecr describe-images --repository-name "$REPO_NAME" --region "$REGION" \
    --query "imageDetails[*].{Tag:imageTags[0],Pushed:imagePushedAt}" \
    --output table

# --- LIST REPOS ---
aws ecr describe-repositories --region "$REGION" \
    --query "repositories[*].{Name:repositoryName,URI:repositoryUri}" \
    --output table

# --- DELETE IMAGE ---
aws ecr batch-delete-image --repository-name "$REPO_NAME" \
    --image-ids imageTag=latest --region "$REGION"

# --- DELETE REPO ---
aws ecr delete-repository --repository-name "$REPO_NAME" \
    --force --region "$REGION"
```

---

## ⚠️ Common Mistakes

**1. Not running `aws ecr get-login-password` before `docker push`**
Docker doesn't know how to authenticate against ECR by default. Without the login step, `docker push` fails with `no basic auth credentials` or `unauthorized: authentication required`. The ECR token is valid for 12 hours — you need to re-authenticate after that.

**2. Using the wrong ECR endpoint for `docker login`**
The `docker login` endpoint must be the registry root — `<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com` — not the full image URI. A common mistake is including the repository name in the login endpoint, which causes authentication to fail for all repositories.

**3. Forgetting to tag the image with the full ECR URI before pushing**
`docker push xfusion-ecr:latest` fails because Docker doesn't know which registry to push to without the full URI prefix. The tag must be `<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/xfusion-ecr:latest` for Docker to route the push to ECR.

**4. Building the image with the wrong architecture for the target runtime**
If the build machine is ARM (Apple M-series Mac) and the deployment target is x86_64 (ECS, EKS), the image architecture won't match and containers will fail to start with `exec format error`. Use `docker buildx build --platform linux/amd64` for cross-platform builds.

**5. No lifecycle policy = unbounded storage costs**
Every `docker push latest` to ECR creates a new image layer (and moves the `latest` tag). The old image layers become untagged but remain in the repository. Without a lifecycle policy deleting untagged images, storage accumulates indefinitely. Add a lifecycle policy immediately after creating the repository.

**6. Not enabling image scanning**
ECR's built-in vulnerability scanner (`scanOnPush=true`) runs an OS and package vulnerability scan on each pushed image. Without it, you're pushing images to production without any security baseline check. Enable it at repository creation and check the scan results after each push.

---

## 🌍 Real-World Context

ECR + Docker is the foundation of container-based CI/CD in AWS. The workflow in production:

**CI/CD Pipeline integration:**
```
Code Push (GitHub/CodeCommit)
    → CodeBuild / GitHub Actions
    → docker build (using Dockerfile in repo)
    → aws ecr get-login-password | docker login
    → docker push <ECR_URI>:<git-commit-sha>
    → docker push <ECR_URI>:latest
    → Trigger ECS Service update / EKS rollout
```

**Image tagging strategy:**
Production teams almost never rely solely on `latest` — it's ambiguous (which version is "latest"?). Common strategies:
- **Git commit SHA**: `$ECR_URI:a3f8bc2` — immutable, traceable to exact code
- **Semantic version**: `$ECR_URI:1.2.3` — human-readable releases
- **Both**: push with commit SHA, then tag that same image as `latest`

Using only `latest` means you can't roll back to a previous version without rebuilding it.

**ECR replication for multi-region deployments:**
ECR supports cross-region and cross-account replication. When an image is pushed to the source registry, it's automatically replicated to target regions. This ensures container deployments in `ap-south-1` don't pull images across the Pacific from `us-east-1` — reducing latency and egress costs.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

---

**Q1. What is Amazon ECR and how does its authentication work?**

> ECR is AWS's fully managed Docker container registry — a private, highly available place to store, manage, and deploy Docker images, tightly integrated with ECS, EKS, Lambda, and CodePipeline. Authentication works via AWS IAM: you call `aws ecr get-login-password` which returns a 12-hour temporary auth token, then pipe that token to `docker login` with the ECR registry endpoint as the server. Docker stores the token and uses it for all subsequent push/pull operations to that registry. The token is temporary and scoped to ECR — there are no long-lived credentials in Docker's credential store. IAM policies control which accounts and roles can push to or pull from specific repositories.

---

**Q2. Walk me through the full workflow to build and push a Docker image to ECR from scratch.**

> Five steps. First, create the ECR repository: `aws ecr create-repository --repository-name myapp`. Second, get your account ID and construct the image URI: `ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/myapp:latest`. Third, build the Docker image locally: `docker build -t myapp:latest .`. Fourth, tag the image with the full ECR URI: `docker tag myapp:latest ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/myapp:latest`. Fifth, authenticate Docker to ECR and push: `aws ecr get-login-password --region REGION | docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com && docker push ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/myapp:latest`. The build and tag steps can happen in either order as long as both complete before the push.

---

**Q3. What is the difference between `MUTABLE` and `IMMUTABLE` image tag mutability in ECR?**

> With `MUTABLE` tag mutability (the default), the same tag can be pushed multiple times — each push overwrites the previous image at that tag. Pushing `latest` ten times overwrites the `latest` pointer each time. With `IMMUTABLE`, once a tag is pushed, it cannot be reassigned — any attempt to push the same tag again fails with an error. Immutable tags prevent accidental overwrites and ensure a given tag always refers to the exact same image. This is important for reproducibility and auditability in production: if `v1.2.3` is deployed, it should be the same image forever. Many teams use immutable tags for version releases and mutable tags only for `latest` (a convenience tag, not a deployment reference).

---

**Q4. An ECS task fails to pull its container image from ECR. What are the possible causes?**

> Several layers to check. First, **IAM permissions** — the ECS task's execution role needs `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, and `ecr:BatchGetImage`. Without these, the pull fails with an authorization error. Second, **network connectivity** — the ECS task (or the EC2 instance hosting it) must be able to reach the ECR endpoint. For tasks in private subnets, this requires either a VPC endpoint for ECR (`com.amazonaws.region.ecr.api` and `com.amazonaws.region.ecr.dkr`) or a NAT Gateway for internet-routed access. Third, **the image tag doesn't exist** — verify the exact tag being requested is in the repository via `describe-images`. Fourth, **ECR token expiry** — if the task is long-lived and the auth token expired (12-hour TTL), the daemon needs to re-authenticate.

---

**Q5. What is an ECR lifecycle policy and why should you always configure one?**

> An ECR lifecycle policy is a set of rules that automatically expire and delete images based on age, count, or tag status. Without one, every image pushed accumulates in the repository indefinitely. Storage is billed per GB-month, and in active CI/CD pipelines that push new images on every commit, an unmanaged repository can accumulate thousands of images and gigabytes of storage cost within weeks. Common lifecycle policy rules: delete untagged images after 1 day (every `latest` push orphans the previous image as untagged), keep only the 10 most recent tagged images for rollback capability, delete images older than 90 days. Lifecycle policies should be added immediately after repository creation — not after the storage bill arrives.

---

**Q6. How would you set up a CI/CD pipeline that builds and pushes a Docker image to ECR on every code push?**

> The standard pattern in AWS: CodePipeline (or GitHub Actions) triggers on a push to the main branch. The build stage uses CodeBuild (or a GitHub Actions runner with the AWS CLI and Docker). The buildspec (or workflow file) calls: `aws ecr get-login-password | docker login`, then `docker build -t $ECR_URI:$CODEBUILD_RESOLVED_SOURCE_VERSION .` (using the git commit SHA as the image tag), then `docker tag` and `docker push`. The CodeBuild service role needs the ECR push permissions. After the push, a deployment stage triggers an ECS service update or EKS rollout using the new image tag. The key security practice: the build environment uses an IAM role (not hardcoded credentials) for ECR authentication, the ECR token is fetched at build time, and the commit SHA is used as the image tag for traceability.

---

**Q7. What is ECR image scanning and what does it scan for?**

> ECR's built-in image scanning uses Clair (for basic scanning) or Amazon Inspector (for enhanced scanning) to check pushed images against a database of known CVEs (Common Vulnerabilities and Exposures). Basic scanning (`scanOnPush=true`) scans the OS packages in the container image layers when the image is pushed and reports vulnerabilities with severity levels (CRITICAL, HIGH, MEDIUM, LOW, INFORMATIONAL). Enhanced scanning (requires Amazon Inspector activation) additionally scans programming language package manifests (npm, pip, Maven, etc.) and runs continuously — re-scanning images when new CVEs are published, not just at push time. In CI/CD pipelines, you'd fail the build if the scan returns any CRITICAL vulnerabilities: `aws ecr describe-image-scan-findings --query "imageScanFindings.findingSeverityCounts.CRITICAL"` — if non-zero, block the deployment.

---

## 📚 Resources

- [AWS Docs — Amazon ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html)
- [AWS CLI Reference — create-repository](https://docs.aws.amazon.com/cli/latest/reference/ecr/create-repository.html)
- [ECR Authentication](https://docs.aws.amazon.com/AmazonECR/latest/userguide/registry_auth.html)
- [ECR Lifecycle Policies](https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html)
- [ECR Image Scanning](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge. Follow along on [LinkedIn](https://www.linkedin.com/in/venkatesh-gangavarapu).*
