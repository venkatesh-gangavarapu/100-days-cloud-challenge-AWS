#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 47: CloudFormation — Priority Queuing with SQS, SNS, Lambda
# Stack: nautilus-priority-stack | Region: us-east-1
# Template: /root/nautilus-priority-stack.yml
#
# Lambda (index.py) confirmed behaviour:
#   - Env vars: high_priority_queue, low_priority_queue (lowercase)
#   - Pull model: polls SQS directly via sqs.receive_message
#   - Invoked manually — no event source mapping
#   - High queue first; low queue only if high is empty
#
# IAM constraint encountered in this lab:
#   - iam:PutRolePolicy is BLOCKED (inline Policies: block fails)
#   - iam:AttachRolePolicy is ALLOWED (ManagedPolicyArns works)
#   - Fix: use managed policy ARNs only, no inline Policies: block
# ============================================================

set -e
REGION="us-east-1"
STACK_NAME="nautilus-priority-stack"
TEMPLATE_FILE="/root/nautilus-priority-stack.yml"

# ============================================================
# STEP 0 (IF NEEDED): DELETE FAILED STACK BEFORE RETRYING
# ============================================================

STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME --region $REGION \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [[ "$STACK_STATUS" == *"FAILED"* ]] || [[ "$STACK_STATUS" == *"ROLLBACK"*  ]]; then
    echo "=== Deleting failed stack (status: $STACK_STATUS) ==="
    aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
    aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION
    echo "Stack deleted"
fi

# ============================================================
# STEP 1: CONFIRM index.py AND GENERATE TEMPLATE
# ============================================================

echo "=== Step 1: Confirming index.py ==="
cat /root/index.py

echo ""
echo "=== Generating CloudFormation template ==="

cat > $TEMPLATE_FILE << YAMLEOF
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  nautilus-priority-stack: SQS priority queuing via SNS filter policies.
  Lambda polls high_priority_queue first, low_priority_queue only if high is empty.
  Uses AWS managed policies only — avoids iam:PutRolePolicy restriction.

Resources:

  HighPriorityQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: nautilus-High-Priority-Queue
      VisibilityTimeout: 60
      MessageRetentionPeriod: 86400

  LowPriorityQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: nautilus-Low-Priority-Queue
      VisibilityTimeout: 60
      MessageRetentionPeriod: 86400

  PriorityTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: nautilus-Priority-Queues-Topic

  HighPriorityQueuePolicy:
    Type: AWS::SQS::QueuePolicy
    Properties:
      Queues:
        - !Ref HighPriorityQueue
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: sns.amazonaws.com
            Action: sqs:SendMessage
            Resource: !GetAtt HighPriorityQueue.Arn
            Condition:
              ArnEquals:
                aws:SourceArn: !Ref PriorityTopic

  LowPriorityQueuePolicy:
    Type: AWS::SQS::QueuePolicy
    Properties:
      Queues:
        - !Ref LowPriorityQueue
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: sns.amazonaws.com
            Action: sqs:SendMessage
            Resource: !GetAtt LowPriorityQueue.Arn
            Condition:
              ArnEquals:
                aws:SourceArn: !Ref PriorityTopic

  HighPrioritySubscription:
    Type: AWS::SNS::Subscription
    DependsOn: HighPriorityQueuePolicy
    Properties:
      TopicArn: !Ref PriorityTopic
      Protocol: sqs
      Endpoint: !GetAtt HighPriorityQueue.Arn
      FilterPolicy:
        priority:
          - high
      RawMessageDelivery: false

  LowPrioritySubscription:
    Type: AWS::SNS::Subscription
    DependsOn: LowPriorityQueuePolicy
    Properties:
      TopicArn: !Ref PriorityTopic
      Protocol: sqs
      Endpoint: !GetAtt LowPriorityQueue.Arn
      FilterPolicy:
        priority:
          - low
      RawMessageDelivery: false

  # IMPORTANT: No Policies: block here — iam:PutRolePolicy is blocked in this lab.
  # ManagedPolicyArns uses iam:AttachRolePolicy which IS allowed.
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
        - arn:aws:iam::aws:policy/AmazonSQSFullAccess
        - arn:aws:iam::aws:policy/AmazonSNSFullAccess

  PriorityQueueFunction:
    Type: AWS::Lambda::Function
    DependsOn: LambdaExecutionRole
    Properties:
      FunctionName: nautilus-priorities-queue-function
      Runtime: python3.12
      Role: !GetAtt LambdaExecutionRole.Arn
      Handler: index.lambda_handler
      Timeout: 30
      MemorySize: 128
      Environment:
        Variables:
          high_priority_queue: !Ref HighPriorityQueue
          low_priority_queue: !Ref LowPriorityQueue
      Code:
        ZipFile: |
$(cat /root/index.py | sed 's/^/          /')

Outputs:
  SNSTopicArn:
    Value: !Ref PriorityTopic
  HighQueueURL:
    Value: !Ref HighPriorityQueue
  LowQueueURL:
    Value: !Ref LowPriorityQueue
  LambdaFunction:
    Value: !Ref PriorityQueueFunction
YAMLEOF

echo "Template written: $TEMPLATE_FILE ($(wc -l < $TEMPLATE_FILE) lines)"

# ============================================================
# STEP 2: VALIDATE
# ============================================================

echo ""
echo "=== Step 2: Validating template ==="
aws cloudformation validate-template \
    --template-body file://${TEMPLATE_FILE} \
    --region $REGION && echo "Template is valid ✅"

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
aws cloudformation describe-stacks \
    --stack-name $STACK_NAME --region $REGION \
    --query "Stacks[0].{Status:StackStatus}" --output table

echo ""
echo "=== Stack outputs ==="
aws cloudformation describe-stacks \
    --stack-name $STACK_NAME --region $REGION \
    --query "Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}" \
    --output table

# ============================================================
# STEP 4: PUBLISH TEST MESSAGES
# ============================================================

echo ""
echo "=== Step 4: Publishing test messages ==="

topicarn=$(aws sns list-topics --region $REGION \
    --query "Topics[?contains(TopicArn, 'nautilus-Priority-Queues-Topic')].TopicArn" \
    --output text)
echo "Topic: $topicarn"

for msg in "High Priority message 1:high" "High Priority message 2:high" \
           "Low Priority message 1:low" "Low Priority message 2:low"; do
    TEXT="${msg%%:*}"
    PRIO="${msg##*:}"
    aws sns publish --topic-arn $topicarn --region $REGION \
        --message "$TEXT" \
        --message-attributes "{\"priority\":{\"DataType\":\"String\",\"StringValue\":\"$PRIO\"}}" > /dev/null
    echo "  Sent [$PRIO]: $TEXT"
done

echo "Waiting 5s for SNS → SQS delivery..."
sleep 5

HIGH_URL=$(aws sqs get-queue-url --queue-name nautilus-High-Priority-Queue \
    --region $REGION --query "QueueUrl" --output text)
LOW_URL=$(aws sqs get-queue-url --queue-name nautilus-Low-Priority-Queue \
    --region $REGION --query "QueueUrl" --output text)

echo ""
echo "--- Queue depths before invocation ---"
echo "  High: $(aws sqs get-queue-attributes --queue-url $HIGH_URL --region $REGION \
    --attribute-names ApproximateNumberOfMessages \
    --query "Attributes.ApproximateNumberOfMessages" --output text) messages"
echo "  Low:  $(aws sqs get-queue-attributes --queue-url $LOW_URL --region $REGION \
    --attribute-names ApproximateNumberOfMessages \
    --query "Attributes.ApproximateNumberOfMessages" --output text) messages"

# ============================================================
# STEP 5: INVOKE LAMBDA 4 TIMES
# ============================================================

echo ""
echo "=== Step 5: Invoking Lambda 4 times — observe priority order ==="

for i in 1 2 3 4; do
    printf "  Invocation %d: " $i
    aws lambda invoke \
        --function-name nautilus-priorities-queue-function \
        --region $REGION \
        --payload '{}' \
        --cli-binary-format raw-in-base64-out \
        /tmp/out-${i}.json > /dev/null 2>&1
    cat /tmp/out-${i}.json
    sleep 2
done

echo ""
echo ""
echo "--- Queue depths after all invocations ---"
echo "  High: $(aws sqs get-queue-attributes --queue-url $HIGH_URL --region $REGION \
    --attribute-names ApproximateNumberOfMessages \
    --query "Attributes.ApproximateNumberOfMessages" --output text) messages"
echo "  Low:  $(aws sqs get-queue-attributes --queue-url $LOW_URL --region $REGION \
    --attribute-names ApproximateNumberOfMessages \
    --query "Attributes.ApproximateNumberOfMessages" --output text) messages"

echo ""
echo "============================================"
echo "  Expected order:"
echo "  1: Message 'High Priority message 1' deleted"
echo "  2: Message 'High Priority message 2' deleted"
echo "  3: Message 'Low Priority message 1' deleted"
echo "  4: Message 'Low Priority message 2' deleted"
echo "============================================"

# ============================================================
# DEBUGGING
# ============================================================

# --- If stack creation failed ---
# aws cloudformation describe-stack-events \
#     --stack-name $STACK_NAME --region $REGION \
#     --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].{Resource:LogicalResourceId,Reason:ResourceStatusReason}" \
#     --output table

# --- Lambda logs ---
# aws logs tail /aws/lambda/nautilus-priorities-queue-function \
#     --region $REGION --since 10m

# ============================================================
# CLEANUP
# ============================================================

# aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
# aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION
