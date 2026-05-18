#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 28: Create ECR Repository, Build Docker Image, Push to ECR
# Repository: xfusion-ecr | Tag: latest | Region: us-east-1
# Run this script on the aws-client host
# ============================================================

set -e   # Exit immediately on any error

REGION="us-east-1"
REPO_NAME="xfusion-ecr"
IMAGE_TAG="latest"
DOCKERFILE_DIR="/root/pyapp"

# ============================================================
# STEP 1: CONFIRM IDENTITY AND RESOLVE ACCOUNT ID
# ============================================================

echo "=== Step 1: Confirming AWS identity ==="

aws sts get-caller-identity \
    --query "{Account:Account,ARN:Arn}" \
    --output table

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query "Account" \
    --output text)

echo "Account ID: $ACCOUNT_ID"
echo "Region:     $REGION"

# Construct the ECR registry endpoint and full image URI
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
FULL_IMAGE_URI="${ECR_REGISTRY}/${REPO_NAME}:${IMAGE_TAG}"

echo "ECR Registry: $ECR_REGISTRY"
echo "Full Image URI: $FULL_IMAGE_URI"

# ============================================================
# STEP 2: CREATE THE PRIVATE ECR REPOSITORY
# ============================================================

echo ""
echo "=== Step 2: Creating private ECR repository '$REPO_NAME' ==="

aws ecr create-repository \
    --repository-name "$REPO_NAME" \
    --region "$REGION" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE \
    --tags Key=Name,Value="$REPO_NAME" \
           Key=Purpose,Value=PyApp

echo "Repository '$REPO_NAME' created"

# Retrieve and display repository details
REPO_URI=$(aws ecr describe-repositories \
    --repository-names "$REPO_NAME" \
    --region "$REGION" \
    --query "repositories[0].repositoryUri" \
    --output text)

echo "Repository URI: $REPO_URI"

echo ""
echo "=== Repository Details ==="
aws ecr describe-repositories \
    --repository-names "$REPO_NAME" \
    --region "$REGION" \
    --query "repositories[0].{Name:repositoryName,URI:repositoryUri,Scan:imageScanningConfiguration.scanOnPush,TagMutability:imageTagMutability,Created:createdAt}" \
    --output table

# ============================================================
# STEP 3: VERIFY DOCKERFILE EXISTS
# ============================================================

echo ""
echo "=== Step 3: Verifying Dockerfile at $DOCKERFILE_DIR ==="

if [ ! -d "$DOCKERFILE_DIR" ]; then
    echo "ERROR: Directory $DOCKERFILE_DIR does not exist"
    exit 1
fi

if [ ! -f "${DOCKERFILE_DIR}/Dockerfile" ]; then
    echo "ERROR: Dockerfile not found at ${DOCKERFILE_DIR}/Dockerfile"
    ls -la "$DOCKERFILE_DIR"
    exit 1
fi

echo "Dockerfile found. Contents:"
echo "---"
cat "${DOCKERFILE_DIR}/Dockerfile"
echo "---"

# List all files in the build context
echo ""
echo "Build context files:"
ls -la "$DOCKERFILE_DIR"

# ============================================================
# STEP 4: BUILD THE DOCKER IMAGE
# ============================================================

echo ""
echo "=== Step 4: Building Docker image '${REPO_NAME}:${IMAGE_TAG}' ==="

docker build \
    --tag "${REPO_NAME}:${IMAGE_TAG}" \
    --file "${DOCKERFILE_DIR}/Dockerfile" \
    "${DOCKERFILE_DIR}"

echo "Build complete"

# Verify image exists locally
echo ""
echo "=== Local images ==="
docker images "${REPO_NAME}"

# ============================================================
# STEP 5: TAG THE IMAGE WITH THE FULL ECR URI
# ============================================================

echo ""
echo "=== Step 5: Tagging image for ECR ==="

docker tag \
    "${REPO_NAME}:${IMAGE_TAG}" \
    "${FULL_IMAGE_URI}"

echo "Tagged: ${FULL_IMAGE_URI}"

# Show both tags
echo ""
echo "=== All tags for this image ==="
docker images | grep -E "REPOSITORY|${REPO_NAME}"

# ============================================================
# STEP 6: AUTHENTICATE DOCKER TO ECR
# Token is valid for 12 hours
# ============================================================

echo ""
echo "=== Step 6: Authenticating Docker to ECR registry ==="

aws ecr get-login-password \
    --region "$REGION" | \
docker login \
    --username AWS \
    --password-stdin \
    "${ECR_REGISTRY}"

echo "Docker authenticated to $ECR_REGISTRY"

# ============================================================
# STEP 7: PUSH THE IMAGE TO ECR
# ============================================================

echo ""
echo "=== Step 7: Pushing image to ECR ==="

docker push "${FULL_IMAGE_URI}"

echo "Push complete: ${FULL_IMAGE_URI}"

# ============================================================
# STEP 8: VERIFY IMAGE IS IN ECR
# ============================================================

echo ""
echo "=== Step 8: Verifying image in ECR ==="

echo "--- Images in repository '$REPO_NAME' ---"
aws ecr describe-images \
    --repository-name "$REPO_NAME" \
    --region "$REGION" \
    --query "imageDetails[*].{Tag:imageTags[0],DigestShort:imageDigest,SizeBytes:imageSizeInBytes,Pushed:imagePushedAt,ScanStatus:imageScanStatus.status}" \
    --output table

echo ""
echo "--- Full image list ---"
aws ecr list-images \
    --repository-name "$REPO_NAME" \
    --region "$REGION" \
    --query "imageIds[*].{Tag:imageTag,Digest:imageDigest}" \
    --output table

echo ""
echo "============================================"
echo "  ECR Repository: $REPO_NAME"
echo "  Repository URI: $REPO_URI"
echo "  Image URI:      $FULL_IMAGE_URI"
echo "  Region:         $REGION"
echo "  Account:        $ACCOUNT_ID"
echo ""
echo "  Pull command:"
echo "  docker pull $FULL_IMAGE_URI"
echo "============================================"

# ============================================================
# OPTIONAL: PULL AND TEST THE IMAGE FROM ECR
# ============================================================

# Verify the pushed image can be pulled back
# docker pull "$FULL_IMAGE_URI"
# docker run --rm "$FULL_IMAGE_URI"

# ============================================================
# OPTIONAL: ADD A LIFECYCLE POLICY
# (Keeps costs under control in production)
# ============================================================

# aws ecr put-lifecycle-policy \
#     --repository-name "$REPO_NAME" \
#     --region "$REGION" \
#     --lifecycle-policy-text '{
#         "rules": [
#             {
#                 "rulePriority": 1,
#                 "description": "Remove untagged images after 1 day",
#                 "selection": {
#                     "tagStatus": "untagged",
#                     "countType": "sinceImagePushed",
#                     "countUnit": "days",
#                     "countNumber": 1
#                 },
#                 "action": {"type": "expire"}
#             }
#         ]
#     }'

# ============================================================
# CLEANUP
# ============================================================

# Remove local images
# docker rmi "${REPO_NAME}:${IMAGE_TAG}" "${FULL_IMAGE_URI}" 2>/dev/null || true

# Delete all images from ECR repo
# aws ecr batch-delete-image \
#     --repository-name "$REPO_NAME" \
#     --region "$REGION" \
#     --image-ids imageTag=latest

# Delete the ECR repository (--force removes all images first)
# aws ecr delete-repository \
#     --repository-name "$REPO_NAME" \
#     --region "$REGION" \
#     --force
# echo "Repository '$REPO_NAME' deleted"
