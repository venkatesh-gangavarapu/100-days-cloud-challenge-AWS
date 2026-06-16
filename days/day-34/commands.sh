#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 34: Lambda Function from Zip Package via CLI
# Function: datacenter-lambda-cli | Region: us-east-1
# Run this script on the aws-client host
# ============================================================

set -e
REGION="us-east-1"
FUNCTION_NAME="datacenter-lambda-cli"
ROLE_NAME="lambda_execution_role"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo "Account: $ACCOUNT_ID"
echo "Role ARN: $ROLE_ARN"

# ============================================================
# STEP 1: CREATE THE PYTHON SCRIPT
# ============================================================

echo ""
echo "=== Step 1: Creating lambda_function.py ==="

mkdir -p /root/lambda-pkg
cd /root/lambda-pkg

cat > lambda_function.py << 'EOF'
import json

def lambda_handler(event, context):
    """
    Returns a greeting message with HTTP 200 status.
    """
    return {
        'statusCode': 200,
        'body': json.dumps('Welcome to KKE AWS Labs!')
    }
EOF

echo "Created lambda_function.py:"
cat lambda_function.py

# ============================================================
# STEP 2: ZIP THE SCRIPT
# Critical: cd into the directory FIRST so the file sits at
# the root of the zip, not nested inside a folder
# ============================================================

echo ""
echo "=== Step 2: Creating function.zip ==="

rm -f function.zip   # clean any stale package from a previous run
zip function.zip lambda_function.py

echo "function.zip created. Contents:"
unzip -l function.zip

# ============================================================
# STEP 3: VERIFY OR CREATE THE IAM EXECUTION ROLE
# Reuses lambda_execution_role from Day 33 if it already exists
# ============================================================

echo ""
echo "=== Step 3: Checking IAM role '$ROLE_NAME' ==="

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "Role already exists — reusing"
else
    echo "Role not found — creating it"

    cat > /tmp/lambda-trust-policy.json << 'TRUSTEOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
TRUSTEOF

    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document file:///tmp/lambda-trust-policy.json \
        --description "Lambda basic execution role"

    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

    echo "Waiting 10 seconds for IAM role to propagate..."
    sleep 10
fi

aws iam get-role --role-name "$ROLE_NAME" \
    --query "Role.{Name:RoleName,ARN:Arn,Created:CreateDate}" --output table

# ============================================================
# STEP 4: CREATE THE LAMBDA FUNCTION FROM THE ZIP PACKAGE
# Note: fileb:// (not file://) is required for binary zip uploads
# ============================================================

echo ""
echo "=== Step 4: Creating Lambda function '$FUNCTION_NAME' ==="

aws lambda create-function \
    --region $REGION \
    --function-name "$FUNCTION_NAME" \
    --runtime "python3.12" \
    --role "$ROLE_ARN" \
    --handler "lambda_function.lambda_handler" \
    --zip-file "fileb:///root/lambda-pkg/function.zip" \
    --description "Returns Welcome to KKE AWS Labs! with status 200 (deployed via CLI from zip)" \
    --timeout 30 \
    --memory-size 128 \
    --tags Name="$FUNCTION_NAME",Day=34,Challenge=100DaysOfCloud,DeployMethod=CLI-Zip

echo "Function creation initiated"

echo "Waiting for Active state..."
aws lambda wait function-active \
    --function-name "$FUNCTION_NAME" --region $REGION

echo "✅ Function is ACTIVE"

# ============================================================
# STEP 5: INVOKE AND VERIFY
# ============================================================

echo ""
echo "=== Step 5: Invoking function to verify ==="

aws lambda invoke \
    --function-name "$FUNCTION_NAME" \
    --region $REGION \
    --payload '{}' \
    --cli-binary-format raw-in-base64-out \
    /tmp/lambda-response.json

echo "Raw response:"
cat /tmp/lambda-response.json
echo ""

STATUS=$(python3 -c "
import json
with open('/tmp/lambda-response.json') as f:
    d = json.load(f)
print(d['statusCode'])
")

BODY=$(python3 -c "
import json
with open('/tmp/lambda-response.json') as f:
    d = json.load(f)
print(json.loads(d['body']))
")

echo "Status Code: $STATUS"
echo "Body:        $BODY"

if [ "$STATUS" == "200" ] && [ "$BODY" == "Welcome to KKE AWS Labs!" ]; then
    echo ""
    echo "✅ VERIFIED: Status 200 + correct body"
else
    echo "⚠️  Unexpected response — check function code and handler path"
fi

# ============================================================
# STEP 6: FINAL CONFIGURATION SUMMARY
# ============================================================

echo ""
echo "=== Step 6: Function configuration ==="

aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" --region $REGION \
    --query "{
        Name:FunctionName,
        Runtime:Runtime,
        Handler:Handler,
        Role:Role,
        State:State,
        CodeSizeBytes:CodeSize,
        MemoryMB:MemorySize,
        TimeoutSec:Timeout,
        LastModified:LastModified
    }" --output table

echo ""
echo "============================================"
echo "  Function:   $FUNCTION_NAME"
echo "  Package:    /root/lambda-pkg/function.zip"
echo "  Role:       $ROLE_NAME (reused if existing)"
echo "  Runtime:    python3.12"
echo "  Status Code: 200 ✅"
echo "  Body:        Welcome to KKE AWS Labs!"
echo "============================================"

# ============================================================
# OPTIONAL: VIEW LOGS
# ============================================================

# aws logs tail /aws/lambda/$FUNCTION_NAME --region $REGION --since 5m

# ============================================================
# OPTIONAL: UPDATE CODE LATER
# ============================================================

# cd /root/lambda-pkg
# zip function.zip lambda_function.py
# aws lambda update-function-code \
#     --function-name "$FUNCTION_NAME" \
#     --zip-file fileb://function.zip \
#     --region $REGION

# ============================================================
# CLEANUP (uncomment when done)
# ============================================================

# aws lambda delete-function --function-name "$FUNCTION_NAME" --region $REGION
# Note: lambda_execution_role is shared with Day 33's function —
# only delete it if no other functions depend on it:
# aws iam detach-role-policy --role-name "$ROLE_NAME" \
#     --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
# aws iam delete-role --role-name "$ROLE_NAME"
