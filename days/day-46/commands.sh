#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 46: Lambda S3 Copy Trigger + DynamoDB Logging
# Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
PUBLIC_BUCKET="devops-public-205"
PRIVATE_BUCKET="devops-private-26898"
LAMBDA_NAME="devops-copyfunction"
ROLE_NAME="lambda_execution_role"
DYNAMO_TABLE="devops-S3CopyLogs"
LAMBDA_FILE="/root/lambda-function.py"
SAMPLE_FILE="/root/sample.zip"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

echo "Account: $ACCOUNT_ID | Region: $REGION"

# ============================================================
# STEP 1: PATCH lambda-function.py
# Must be done BEFORE packaging — placeholders cause silent failures
# ============================================================

echo ""
echo "=== Step 1: Patching lambda-function.py ==="

sed -i "s/REPLACE-WITH-YOUR-DYNAMODB-TABLE/${DYNAMO_TABLE}/g" $LAMBDA_FILE
sed -i "s/REPLACE-WITH-YOUR-PRIVATE-BUCKET/${PRIVATE_BUCKET}/g" $LAMBDA_FILE

echo "Verifying replacements:"
grep -E "devops-" $LAMBDA_FILE || echo "WARNING: no devops- strings found — check file"
echo "Full file:"
cat $LAMBDA_FILE

# ============================================================
# STEP 2: CREATE PUBLIC S3 BUCKET
# ============================================================

echo ""
echo "=== Step 2: Creating public bucket '$PUBLIC_BUCKET' ==="

aws s3api create-bucket --bucket $PUBLIC_BUCKET --region $REGION

aws s3api put-public-access-block --bucket $PUBLIC_BUCKET \
    --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

aws s3api put-bucket-policy --bucket $PUBLIC_BUCKET \
    --policy "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
            \"Sid\": \"PublicRead\",
            \"Effect\": \"Allow\",
            \"Principal\": \"*\",
            \"Action\": \"s3:GetObject\",
            \"Resource\": \"arn:aws:s3:::${PUBLIC_BUCKET}/*\"
        }]
    }"

echo "Public bucket ready: s3://$PUBLIC_BUCKET"

# ============================================================
# STEP 3: CREATE PRIVATE S3 BUCKET
# ============================================================

echo ""
echo "=== Step 3: Creating private bucket '$PRIVATE_BUCKET' ==="

aws s3api create-bucket --bucket $PRIVATE_BUCKET --region $REGION

aws s3api put-public-access-block --bucket $PRIVATE_BUCKET \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "Private bucket ready: s3://$PRIVATE_BUCKET"

# ============================================================
# STEP 4: CREATE DYNAMODB TABLE
# Partition key: LogID (String)
# ============================================================

echo ""
echo "=== Step 4: Creating DynamoDB table '$DYNAMO_TABLE' ==="

aws dynamodb create-table \
    --region $REGION \
    --table-name $DYNAMO_TABLE \
    --attribute-definitions AttributeName=LogID,AttributeType=S \
    --key-schema AttributeName=LogID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Name,Value=$DYNAMO_TABLE

aws dynamodb wait table-exists --table-name $DYNAMO_TABLE --region $REGION
echo "DynamoDB table active: $DYNAMO_TABLE"

# ============================================================
# STEP 5: CREATE IAM ROLE AND POLICIES
# ============================================================

echo ""
echo "=== Step 5: Creating IAM role '$ROLE_NAME' ==="

aws iam create-role \
    --role-name $ROLE_NAME \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --description "Lambda execution role for S3 copy + DynamoDB logging"

# Custom policy: S3 read (public) + S3 write (private) + DynamoDB PutItem
cat > /tmp/lambda-custom-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ReadSourceBucket",
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:ListBucket"],
            "Resource": [
                "arn:aws:s3:::${PUBLIC_BUCKET}",
                "arn:aws:s3:::${PUBLIC_BUCKET}/*"
            ]
        },
        {
            "Sid": "WriteDestBucket",
            "Effect": "Allow",
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::${PRIVATE_BUCKET}/*"
        },
        {
            "Sid": "WriteDynamoLog",
            "Effect": "Allow",
            "Action": "dynamodb:PutItem",
            "Resource": "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${DYNAMO_TABLE}"
        }
    ]
}
EOF

CUSTOM_POLICY_ARN=$(aws iam create-policy \
    --policy-name devops-lambda-s3-dynamo-policy \
    --policy-document file:///tmp/lambda-custom-policy.json \
    --query "Policy.Arn" --output text)

aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $CUSTOM_POLICY_ARN
aws iam attach-role-policy --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

echo "Role ready: $ROLE_NAME"

ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query "Role.Arn" --output text)
echo "Role ARN: $ROLE_ARN"
echo "Waiting 15s for IAM propagation..."
sleep 15

# ============================================================
# STEP 6: PACKAGE AND DEPLOY LAMBDA FUNCTION
# ============================================================

echo ""
echo "=== Step 6: Deploying Lambda '$LAMBDA_NAME' ==="

cd /tmp
cp $LAMBDA_FILE /tmp/lambda-function.py
zip -j lambda-package.zip lambda-function.py

aws lambda create-function \
    --region $REGION \
    --function-name $LAMBDA_NAME \
    --runtime python3.12 \
    --role $ROLE_ARN \
    --handler lambda-function.lambda_handler \
    --zip-file fileb:///tmp/lambda-package.zip \
    --timeout 30 \
    --memory-size 128 \
    --description "S3 copy: $PUBLIC_BUCKET -> $PRIVATE_BUCKET, logs to DynamoDB"

aws lambda wait function-active --function-name $LAMBDA_NAME --region $REGION
echo "Lambda deployed: $LAMBDA_NAME"

# ============================================================
# STEP 7: GRANT S3 PERMISSION TO INVOKE LAMBDA
# Must come BEFORE put-bucket-notification-configuration
# source-account prevents confused deputy attacks
# ============================================================

echo ""
echo "=== Step 7: Granting S3 permission to invoke Lambda ==="

aws lambda add-permission \
    --function-name $LAMBDA_NAME \
    --statement-id s3-invoke-permission \
    --action lambda:InvokeFunction \
    --principal s3.amazonaws.com \
    --source-arn arn:aws:s3:::${PUBLIC_BUCKET} \
    --source-account $ACCOUNT_ID \
    --region $REGION

echo "Permission granted: s3.amazonaws.com can invoke $LAMBDA_NAME"

# ============================================================
# STEP 8: CONFIGURE S3 EVENT NOTIFICATION
# s3:ObjectCreated:* fires on PUT, POST, COPY, multipart complete
# ============================================================

echo ""
echo "=== Step 8: Configuring S3 event notification ==="

aws s3api put-bucket-notification-configuration \
    --bucket $PUBLIC_BUCKET \
    --notification-configuration "{
        \"LambdaFunctionConfigurations\": [{
            \"Id\": \"CopyToPrivateBucket\",
            \"LambdaFunctionArn\": \"arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${LAMBDA_NAME}\",
            \"Events\": [\"s3:ObjectCreated:*\"]
        }]
    }"

echo "Notification configured: $PUBLIC_BUCKET -> $LAMBDA_NAME"

# ============================================================
# STEP 9: UPLOAD TEST FILE AND VERIFY
# ============================================================

echo ""
echo "=== Step 9: Uploading test file to trigger Lambda ==="

if [ ! -f "$SAMPLE_FILE" ]; then
    echo "Warning: $SAMPLE_FILE not found — creating placeholder"
    echo "test" > /tmp/sample.zip
    SAMPLE_FILE="/tmp/sample.zip"
fi

aws s3 cp $SAMPLE_FILE s3://${PUBLIC_BUCKET}/sample.zip
echo "Uploaded sample.zip to s3://$PUBLIC_BUCKET/"

echo "Waiting 20s for Lambda to process..."
sleep 20

echo ""
echo "--- Private bucket contents ---"
aws s3 ls s3://$PRIVATE_BUCKET/ || echo "Empty or access denied"

echo ""
echo "--- DynamoDB log entries ---"
aws dynamodb scan \
    --table-name $DYNAMO_TABLE \
    --region $REGION \
    --query "Items[*]" \
    --output json

COPIED=$(aws s3 ls s3://$PRIVATE_BUCKET/ | grep "sample.zip" || true)
if [ -n "$COPIED" ]; then
    echo ""
    echo "✅ SUCCESS: sample.zip copied to private bucket"
else
    echo ""
    echo "⚠️  sample.zip not found in private bucket yet"
    echo "    Check Lambda logs: aws logs tail /aws/lambda/$LAMBDA_NAME --region $REGION"
fi

echo ""
echo "============================================"
echo "  Public Bucket:  $PUBLIC_BUCKET"
echo "  Private Bucket: $PRIVATE_BUCKET"
echo "  Lambda:         $LAMBDA_NAME"
echo "  IAM Role:       $ROLE_NAME"
echo "  DynamoDB:       $DYNAMO_TABLE"
echo "============================================"
