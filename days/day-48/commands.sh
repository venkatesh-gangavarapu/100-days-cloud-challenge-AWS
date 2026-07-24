#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 48: CloudFormation — Lambda Function Deployment
# Stack: datacenter-lambda-app | Region: us-east-1
# Template: /root/datacenter-lambda.yml
#
# Lessons from Day 47 applied:
#   - No Policies: block (iam:PutRolePolicy blocked in this lab)
#   - Use ManagedPolicyArns only (iam:AttachRolePolicy is allowed)
#   - ZipFile handler must be index.lambda_handler
# ============================================================

set -e
REGION="us-east-1"
STACK_NAME="datacenter-lambda-app"
TEMPLATE_FILE="/root/datacenter-lambda.yml"

# ============================================================
# STEP 1: GENERATE TEMPLATE
# ============================================================

echo "=== Step 1: Generating template '$TEMPLATE_FILE' ==="

cat > $TEMPLATE_FILE << 'YAMLEOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  datacenter-lambda-app: Lambda function returning 200 + "Welcome to KKE AWS Labs!"

Resources:

  # IAM role — ManagedPolicyArns only (iam:PutRolePolicy blocked in this environment)
  LambdaExecutionRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: lambda_execution_role
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

  DatacenterLambda:
    Type: AWS::Lambda::Function
    DependsOn: LambdaExecutionRole
    Properties:
      FunctionName: datacenter-lambda
      Runtime: python3.12
      Role: !GetAtt LambdaExecutionRole.Arn
      Handler: index.lambda_handler
      Timeout: 30
      MemorySize: 128
      Code:
        ZipFile: |
          def lambda_handler(event, context):
              return {
                  'statusCode': 200,
                  'body': 'Welcome to KKE AWS Labs!'
              }

Outputs:
  LambdaFunctionName:
    Description: Lambda function name
    Value: !Ref DatacenterLambda
  LambdaFunctionArn:
    Description: Lambda function ARN
    Value: !GetAtt DatacenterLambda.Arn
  LambdaRoleArn:
    Description: IAM role ARN
    Value: !GetAtt LambdaExecutionRole.Arn
YAMLEOF

echo "Template written ($(wc -l < $TEMPLATE_FILE) lines)"
cat $TEMPLATE_FILE

# ============================================================
# STEP 2: VALIDATE
# ============================================================

echo ""
echo "=== Step 2: Validating template ==="
aws cloudformation validate-template \
    --template-body file://${TEMPLATE_FILE} \
    --region $REGION && echo "Valid ✅"

# ============================================================
# STEP 3: DEPLOY
# ============================================================

echo ""
echo "=== Step 3: Deploying stack '$STACK_NAME' ==="
aws cloudformation deploy \
    --region $REGION \
    --template-file $TEMPLATE_FILE \
    --stack-name $STACK_NAME \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset

echo ""
echo "--- Stack status ---"
aws cloudformation describe-stacks \
    --stack-name $STACK_NAME --region $REGION \
    --query "Stacks[0].{Status:StackStatus,Reason:StackStatusReason}" \
    --output table

echo ""
echo "--- Stack outputs ---"
aws cloudformation describe-stacks \
    --stack-name $STACK_NAME --region $REGION \
    --query "Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}" \
    --output table

# ============================================================
# STEP 4: TEST
# ============================================================

echo ""
echo "=== Step 4: Invoking Lambda ==="

aws lambda invoke \
    --function-name datacenter-lambda \
    --region $REGION \
    --payload '{}' \
    --cli-binary-format raw-in-base64-out \
    /tmp/datacenter-lambda-response.json

echo "Raw response:"
cat /tmp/datacenter-lambda-response.json

echo ""
STATUS_CODE=$(python3 -c "import json; r=json.load(open('/tmp/datacenter-lambda-response.json')); print(r.get('statusCode',''))")
BODY=$(python3 -c "import json; r=json.load(open('/tmp/datacenter-lambda-response.json')); print(r.get('body',''))")

echo "============================================"
echo "  statusCode: $STATUS_CODE"
echo "  body:       $BODY"
echo ""
if [ "$STATUS_CODE" = "200" ] && [ "$BODY" = "Welcome to KKE AWS Labs!" ]; then
    echo "  ✅ VERIFIED: Status 200, correct body"
else
    echo "  ❌ MISMATCH — check the values above"
fi
echo "============================================"

# ============================================================
# DEBUGGING
# ============================================================

# --- If stack creation fails ---
# aws cloudformation describe-stack-events \
#     --stack-name $STACK_NAME --region $REGION \
#     --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].{Resource:LogicalResourceId,Reason:ResourceStatusReason}" \
#     --output table

# --- Lambda CloudWatch logs ---
# aws logs tail /aws/lambda/datacenter-lambda --region $REGION --since 10m

# ============================================================
# CLEANUP
# ============================================================

# aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
# aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION
