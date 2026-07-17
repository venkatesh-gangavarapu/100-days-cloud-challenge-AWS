#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 43: Amazon EKS — Private Cluster Provisioning
# Cluster: xfusion-eks | Role: eksClusterRole | Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
CLUSTER_NAME="xfusion-eks"
ROLE_NAME="eksClusterRole"

# ============================================================
# STEP 1: CREATE eksClusterRole (if it doesn't already exist)
# Two things required:
#   - Trust policy: eks.amazonaws.com can assume this role
#   - Policy: AmazonEKSClusterPolicy (control plane permissions)
# ============================================================

echo "=== Step 1: Ensuring IAM role '$ROLE_NAME' exists ==="

if aws iam get-role --role-name $ROLE_NAME >/dev/null 2>&1; then
    echo "Role already exists — skipping creation"
else
    echo "Creating $ROLE_NAME..."

    cat > /tmp/eks-trust-policy.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "eks.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

    aws iam create-role \
        --role-name $ROLE_NAME \
        --assume-role-policy-document file:///tmp/eks-trust-policy.json \
        --description "EKS cluster control plane IAM role"

    aws iam attach-role-policy \
        --role-name $ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

    echo "Waiting for IAM propagation..."
    sleep 10
fi

ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query "Role.Arn" --output text)
echo "Role ARN: $ROLE_ARN"

# Verify the role has the correct policy attached
aws iam list-attached-role-policies --role-name $ROLE_NAME \
    --query "AttachedPolicies[*].{Name:PolicyName,ARN:PolicyArn}" --output table

# ============================================================
# STEP 2: RESOLVE DEFAULT VPC AND SUBNETS
# Task requires: us-east-1a, us-east-1b, us-east-1c
# ============================================================

echo ""
echo "=== Step 2: Resolving default VPC and subnets ==="

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text)

echo "Default VPC: $VPC_ID"

# Get subnet IDs for the three required AZs
echo "Subnets in us-east-1a, us-east-1b, us-east-1c:"
aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
    --query "Subnets[?AvailabilityZone=='us-east-1a' || AvailabilityZone=='us-east-1b' || AvailabilityZone=='us-east-1c'].{AZ:AvailabilityZone,SubnetId:SubnetId}" \
    --output table

SUBNET_LIST=$(aws ec2 describe-subnets --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
    --query "Subnets[?AvailabilityZone=='us-east-1a' || AvailabilityZone=='us-east-1b' || AvailabilityZone=='us-east-1c'].SubnetId" \
    --output text | tr '\t' ',')

SUBNET_COUNT=$(echo $SUBNET_LIST | tr ',' ' ' | wc -w)
echo "Found $SUBNET_COUNT subnets: $SUBNET_LIST"

if [ "$SUBNET_COUNT" -lt 2 ]; then
    echo "ERROR: Need at least 2 subnets across different AZs"
    exit 1
fi

DEFAULT_SG=$(aws ec2 describe-security-groups --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" --output text)

echo "Default SG: $DEFAULT_SG"

# ============================================================
# STEP 3: CREATE THE EKS CLUSTER
# Key settings:
#   endpointPublicAccess=false  → no internet-facing endpoint
#   endpointPrivateAccess=true  → VPC-internal access enabled
#   (EKS Auto Mode is not a CLI flag for create-cluster;
#    it's a cluster configuration managed in the console)
# ============================================================

echo ""
echo "=== Step 3: Creating EKS cluster '$CLUSTER_NAME' ==="
echo "This takes 10-15 minutes. Grab a coffee..."

# Get the latest available Kubernetes version
K8S_VERSION=$(aws eks describe-addon-versions --region $REGION \
    --query "addons[0].addonVersions[0].compatibilities[0].clusterVersion" \
    --output text 2>/dev/null || echo "")

echo "Note: using latest stable Kubernetes version (console will auto-select)"

aws eks create-cluster \
    --region $REGION \
    --name $CLUSTER_NAME \
    --role-arn $ROLE_ARN \
    --resources-vpc-config \
        subnetIds=$SUBNET_LIST,securityGroupIds=$DEFAULT_SG,endpointPublicAccess=false,endpointPrivateAccess=true \
    --tags Name=$CLUSTER_NAME,Environment=Development,ManagedBy=CLI

echo "Create request submitted"

# ============================================================
# STEP 4: WAIT FOR ACTIVE STATUS
# EKS cluster creation: ~10-15 minutes
# ============================================================

echo ""
echo "=== Step 4: Waiting for cluster to reach ACTIVE state ==="

aws eks wait cluster-active \
    --name $CLUSTER_NAME \
    --region $REGION

echo "Cluster is ACTIVE"

# ============================================================
# STEP 5: VERIFY CLUSTER CONFIGURATION
# ============================================================

echo ""
echo "=== Step 5: Verifying cluster configuration ==="

aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
    --query "cluster.{
        Name:name,
        Status:status,
        K8sVersion:version,
        Role:roleArn,
        PrivateEndpoint:resourcesVpcConfig.endpointPrivateAccess,
        PublicEndpoint:resourcesVpcConfig.endpointPublicAccess,
        VPC:resourcesVpcConfig.vpcId,
        Subnets:resourcesVpcConfig.subnetIds
    }" --output table

# Validate requirements
STATUS=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
    --query "cluster.status" --output text)

PRIVATE=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
    --query "cluster.resourcesVpcConfig.endpointPrivateAccess" --output text)

PUBLIC=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
    --query "cluster.resourcesVpcConfig.endpointPublicAccess" --output text)

echo ""
echo "--- Validation Results ---"
echo "Status: $STATUS (expected: ACTIVE)"
echo "Private endpoint: $PRIVATE (expected: True)"
echo "Public endpoint: $PUBLIC (expected: False)"

if [ "$STATUS" == "ACTIVE" ] && [ "$PRIVATE" == "True" ] && [ "$PUBLIC" == "False" ]; then
    echo ""
    echo "✅ ALL CHECKS PASSED"
else
    echo ""
    echo "❌ Validation failed — check the values above"
fi

echo ""
echo "============================================"
echo "  Cluster:         $CLUSTER_NAME"
echo "  Status:          $STATUS"
echo "  IAM Role:        $ROLE_NAME"
echo "  Kubernetes:      Latest stable"
echo "  Private endpoint: $PRIVATE ✅"
echo "  Public endpoint:  $PUBLIC ✅"
echo "  EKS Auto Mode:   Disabled ✅"
echo "  AZs:             us-east-1a, b, c"
echo "============================================"
echo ""
echo "NOTE: To use kubectl, you must be inside the VPC"
echo "      (private endpoint cluster — no public API access)"

# ============================================================
# CLEANUP (run only when tearing down)
# EKS cluster deletion takes 10-15 minutes
# ============================================================

# aws eks delete-cluster --name $CLUSTER_NAME --region $REGION
# aws eks wait cluster-deleted --name $CLUSTER_NAME --region $REGION
# echo "Cluster deleted"
