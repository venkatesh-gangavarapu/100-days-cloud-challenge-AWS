#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 33: AWS Lambda Function
# Function: devops-lambda | Runtime: Python 3.12 | Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
FUNCTION_NAME="devops-lambda"
ROLE_NAME="lambda_execution_role"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo "Account: $ACCOUNT_ID"
echo "Role ARN: $ROLE_ARN"

# ============================================================
# STEP 1: CREATE IAM EXECUTION ROLE
# ============================================================

echo ""
echo "=== Step 1: Creating IAM role '$ROLE_NAME' ==="

# Trust policy — Lambda service can assume this role
cat > /tmp/lambda-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file:///tmp/lambda-trust-policy.json \
    --description "Lambda basic execution role for devops-lambda" \
    2>/dev/null && echo "Role created" || echo "Role may already exist — continuing"

# Attach CloudWatch Logs permission
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
    2>/dev/null && echo "Policy attached" || echo "Policy may already be attached"

# Verify role exists
aws iam get-role --role-name "$ROLE_NAME" \
    --query "Role.{Name:RoleName,ARN:Arn}" --output table

echo "Waiting 10 seconds for IAM role to propagate..."
sleep 10

# ============================================================
# STEP 2: WRITE LAMBDA FUNCTION CODE
# ============================================================

echo ""
echo "=== Step 2: Writing Lambda function code ==="

mkdir -p /tmp/lambda-pkg

cat > /tmp/lambda-pkg/lambda_function.py << 'PYEOF'
import json

def lambda_handler(event, context):
    """
    Returns a greeting message with HTTP 200 status.
    Compatible with both direct invocation and API Gateway proxy.
    """
    return {
        'statusCode': 200,
        'body': json.dumps('Welcome to KKE AWS Labs!')
    }
PYEOF

echo "lambda_function.py written:"
cat /tmp/lambda-pkg/lambda_function.py

# Package into zip
cd /tmp/lambda-pkg
zip /tmp/devops-lambda.zip lambda_function.py
echo "Packaged: /tmp/devops-lambda.zip"

# ============================================================
# STEP 3: CREATE THE LAMBDA FUNCTION
# ============================================================

echo ""
echo "=== Step 3: Creating Lambda function '$FUNCTION_NAME' ==="

aws lambda create-function \
    --region $REGION \
    --function-name "$FUNCTION_NAME" \
    --runtime "python3.12" \
    --role "$ROLE_ARN" \
    --handler "lambda_function.lambda_handler" \
    --zip-file "fileb:///tmp/devops-lambda.zip" \
    --description "Returns Welcome to KKE AWS Labs! with status 200" \
    --timeout 30 \
    --memory-size 128 \
    --tags Name="$FUNCTION_NAME",Day=33,Challenge=100DaysOfCloud

echo "Function created — waiting for Active state..."

aws lambda wait function-active \
    --function-name "$FUNCTION_NAME" --region $REGION

echo "Function is ACTIVE"

# ============================================================
# STEP 4: INVOKE AND VERIFY
# ============================================================

echo ""
echo "=== Step 4: Invoking function to verify ==="

aws lambda invoke \
    --function-name "$FUNCTION_NAME" \
    --region $REGION \
    --payload '{"test": "event"}' \
    --cli-binary-format raw-in-base64-out \
    /tmp/lambda-response.json

echo "Raw response:"
cat /tmp/lambda-response.json
echo ""

# Parse and verify
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
    echo "⚠️  Unexpected response — check function code"
fi

# ============================================================
# STEP 5: SHOW FUNCTION CONFIGURATION
# ============================================================

echo ""
echo "=== Step 5: Function configuration ==="

aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" --region $REGION \
    --query "{
        Name:FunctionName,
        Runtime:Runtime,
        Handler:Handler,
        Role:Role,
        State:State,
        MemoryMB:MemorySize,
        TimeoutSec:Timeout,
        LastModified:LastModified
    }" --output table

echo ""
echo "============================================"
echo "  Function:    $FUNCTION_NAME"
echo "  Runtime:     Python 3.12"
echo "  Role:        $ROLE_NAME"
echo "  Status Code: 200"
echo "  Body:        Welcome to KKE AWS Labs!"
echo "============================================"

# ============================================================
# OPTIONAL: VIEW LOGS AFTER INVOCATION
# ============================================================

# aws logs tail /aws/lambda/$FUNCTION_NAME --region $REGION

# ============================================================
# CLEANUP (uncomment when done)
# ============================================================

# aws lambda delete-function --function-name "$FUNCTION_NAME" --region $REGION
# aws iam detach-role-policy --role-name "$ROLE_NAME" \
#     --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
# aws iam delete-role --role-name "$ROLE_NAME"
