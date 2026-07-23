# Day 47 — CloudFormation: Priority Queuing with SQS, SNS, and Lambda

> **#100DaysOfCloud | Day 47 of 100**

---

## 📌 The Task

> *Use CloudFormation to deploy a priority queuing system — two SQS queues, an SNS topic with filter policies routing by priority attribute, and a Lambda function that polls the high-priority queue first — all deployed as a single atomic stack.*

**Stack name:** `nautilus-priority-stack`
**Template:** `/root/nautilus-priority-stack.yml`

**Resources in the stack:**

| Resource | Name |
|----------|------|
| SQS queue | `nautilus-High-Priority-Queue` |
| SQS queue | `nautilus-Low-Priority-Queue` |
| SNS topic | `nautilus-Priority-Queues-Topic` |
| Lambda function | `nautilus-priorities-queue-function` |
| IAM role | `lambda_execution_role` |

---

## Architecture

```
aws sns publish --message-attributes '{"priority":{"StringValue":"high"}}'
    │
    ▼
nautilus-Priority-Queues-Topic (SNS)
    │
    ├── FilterPolicy: priority=high ──► nautilus-High-Priority-Queue (SQS)
    │
    └── FilterPolicy: priority=low  ──► nautilus-Low-Priority-Queue  (SQS)
                                              ▲
aws lambda invoke ────────────────────────────┤
    │                                         │
    ▼                                         │
nautilus-priorities-queue-function            │
    polls high_priority_queue first ──────────┘
    only checks low_priority_queue if high is empty
```

**Key design detail:** The Lambda is **invoked directly** (not via SQS event source mapping). Each invocation processes exactly one message, high queue first.

---

## The Lambda Code (index.py)

```python
import boto3
import os

sqs = boto3.client('sqs')

def delete_message(queue_url, receipt_handle, message):
    response = sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt_handle)
    return "Message " + "'" + message + "'" + " deleted"

def poll_messages(queue_url):
    response = sqs.receive_message(
        QueueUrl=queue_url,
        AttributeNames=[],
        MaxNumberOfMessages=1,
        MessageAttributeNames=['All'],
        WaitTimeSeconds=3
    )
    if "Messages" in response:
        receipt_handle = response['Messages'][0]['ReceiptHandle']
        message = response['Messages'][0]['Body']
        delete_response = delete_message(queue_url, receipt_handle, message)
        return delete_response
    else:
        return "No more messages to poll"

def lambda_handler(event, context):
    response = poll_messages(os.environ['high_priority_queue'])
    if response == "No more messages to poll":
        response = poll_messages(os.environ['low_priority_queue'])
    return response
```

**Three critical details from reading the code:**

1. **Environment variables are lowercase**: `high_priority_queue` and `low_priority_queue` — must match exactly in the CloudFormation template
2. **Lambda polls SQS directly** — uses `sqs.receive_message`, not an event source mapping
3. **One message per invocation** — high queue first; low queue only if high is empty

---

## Core Concepts

### CloudFormation — Infrastructure as Code

CloudFormation deploys this as a single atomic unit: 7 inter-dependent resources created in the correct order without manual ARN tracking. `!Ref` and `!GetAtt` intrinsic functions wire resources together:

- `!Ref HighPriorityQueue` → queue URL (used in Lambda env var and SNS subscription endpoint)
- `!GetAtt HighPriorityQueue.Arn` → queue ARN (used in IAM policy and SQS queue policy)

If any resource fails during creation, CloudFormation rolls back the entire stack automatically.

### SNS Filter Policies

Filter policies evaluate the publisher's `MessageAttributes` at delivery time:

```yaml
FilterPolicy:
[O  priority:
    - high    # deliver only if message attribute "priority" == "high"
```

Without filter policies, both queues would receive every message. Messages published without the `priority` attribute (or with an unrecognized value) are silently dropped.

### SQS Queue Policy — Required for SNS Delivery

This is the most commonly missed piece. SNS cannot write to an SQS queue without the queue's explicit permission:

```yaml
Principal:
  Service: sns.amazonaws.com
Action: sqs:SendMessage
Condition:
  ArnEquals:
    aws:SourceArn: !Ref PriorityTopic  # scope to this specific topic
```

Without this, SNS publishes successfully but messages never arrive in the queue — no error is raised.

### Why No Event Source Mapping

The Lambda polls queues manually inside `poll_messages()` using `sqs.receive_message`. An event source mapping would invoke Lambda automatically when messages arrive — a push model. This function uses a pull model: it's invoked externally and actively reads from the queue. This is why there are no `AWS::Lambda::EventSourceMapping` resources in the template.

---

## Step-by-Step Solution

### Step 1 — Read index.py and Generate the Template

```bash
cat /root/index.py   # confirm handler and env var names

# Generate template embedding index.py inline
# Key: env vars must be 'high_priority_queue' and 'low_priority_queue' (lowercase)
cat > /root/nautilus-priority-stack.yml << 'YAML'
# ... see full template in commands.sh
YAML
```

### Step 2 — Validate and Deploy

```bash
aws cloudformation validate-template \
    --template-body file:///root/nautilus-priority-stack.yml \
    --region us-east-1

aws cloudformation deploy \
    --template-file /root/nautilus-priority-stack.yml \
    --stack-name nautilus-priority-stack \
    --capabilities CAPABILITY_NAMED_IAM \
    --region us-east-1
```

### Step 3 — Publish Messages to SNS

```bash
topicarn=$(aws sns list-topics --region us-east-1 \
    --query "Topics[?contains(TopicArn,'nautilus-Priority-Queues-Topic')].TopicArn" \
    --output text)

aws sns publish --topic-arn $topicarn \
    --message 'High Priority message 1' \
    --message-attributes '{"priority":{"DataType":"String","StringValue":"high"}}'

aws sns publish --topic-arn $topicarn \
    --message 'High Priority message 2' \
    --message-attributes '{"priority":{"DataType":"String","StringValue":"high"}}'

aws sns publish --topic-arn $topicarn \
    --message 'Low Priority message 1' \
    --message-attributes '{"priority":{"DataType":"String","StringValue":"low"}}'

aws sns publish --topic-arn $topicarn \
    --message 'Low Priority message 2' \
    --message-attributes '{"priority":{"DataType":"String","StringValue":"low"}}'
```

### Step 4 — Invoke Lambda 4 Times and Observe Order

```bash
# Each invocation processes ONE message — high queue always checked first
for i in 1 2 3 4; do
    echo "--- Invocation $i ---"
    aws lambda invoke \
        --function-name nautilus-priorities-queue-function \
        --region us-east-1 \
        --payload '{}' \
        --cli-binary-format raw-in-base64-out \
        /tmp/output-$i.json
    cat /tmp/output-$i.json
    echo ""
    sleep 2
done
```

**Expected output order:**
```
Invocation 1: "Message 'High Priority message 1' deleted"
Invocation 2: "Message 'High Priority message 2' deleted"
Invocation 3: "Message 'Low Priority message 1' deleted"   ← high queue now empty
Invocation 4: "Message 'Low Priority message 2' deleted"
```

---

## Commands Reference

```bash
REGION="us-east-1"
STACK="nautilus-priority-stack"

# --- VALIDATE ---
aws cloudformation validate-template \
    --template-body file:///root/nautilus-priority-stack.yml --region $REGION

# --- DEPLOY ---
aws cloudformation deploy \
    --template-file /root/nautilus-priority-stack.yml \
    --stack-name $STACK --capabilities CAPABILITY_NAMED_IAM --region $REGION

# --- DEBUG FAILURES ---
aws cloudformation describe-stack-events --stack-name $STACK --region $REGION \
    --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].{Res:LogicalResourceId,Reason:ResourceStatusReason}" \
    --output table

# --- CHECK STACK OUTPUTS ---
aws cloudformation describe-stacks --stack-name $STACK --region $REGION \
    --query "Stacks[0].Outputs" --output table

# --- CHECK QUEUE DEPTHS ---
aws sqs get-queue-attributes --region $REGION \
    --queue-url $(aws sqs get-queue-url --queue-name nautilus-High-Priority-Queue \
        --region $REGION --query "QueueUrl" --output text) \
    --attribute-names ApproximateNumberOfMessages

# --- INVOKE LAMBDA ---
aws lambda invoke --function-name nautilus-priorities-queue-function \
    --region $REGION --payload '{}' \
    --cli-binary-format raw-in-base64-out /tmp/out.json && cat /tmp/out.json

# --- VIEW LOGS ---
aws logs tail /aws/lambda/nautilus-priorities-queue-function \
    --region $REGION --since 10m

# --- CLEANUP ---
aws cloudformation delete-stack --stack-name $STACK --region $REGION
aws cloudformation wait stack-delete-complete --stack-name $STACK --region $REGION
```

---

## Common Mistakes

**1. Wrong environment variable case in the CloudFormation template**
The Lambda code uses `os.environ['high_priority_queue']` and `os.environ['low_priority_queue']` — all lowercase. If the template defines `HIGH_PRIORITY_QUEUE_URL` (uppercase), the Lambda function raises `KeyError: 'high_priority_queue'` on every invocation. Python environment variable lookups are case-sensitive. Always read the Lambda code before writing the CloudFormation template.

**2. Adding SQS event source mappings when the Lambda polls manually**
Because `index.py` uses `sqs.receive_message` directly (pull model), adding `AWS::Lambda::EventSourceMapping` would cause both patterns to compete — the event source mapping automatically invokes Lambda when messages arrive AND the manual invocation also polls. This creates duplicate processing and confusing behaviour. This Lambda is designed to be invoked directly; no event source mapping is needed.

**3. Missing SQS queue policy — SNS messages silently dropped**
The `AWS::SQS::QueuePolicy` allowing `sns.amazonaws.com` to call `sqs:SendMessage` is required before messages flow from SNS to SQS. Without it, `sns publish` returns HTTP 200 (SNS accepted the message) but nothing arrives in the queues. Always deploy the queue policy before testing the subscription.

**4. Missing `CAPABILITY_NAMED_IAM`**
`lambda_execution_role` is an explicitly named IAM resource. CloudFormation requires acknowledgement via `--capabilities CAPABILITY_NAMED_IAM`. Omitting it causes `InsufficientCapabilitiesException`.

**5. SNS subscription created before SQS queue policy**
CloudFormation sometimes attempts to create `AWS::SNS::Subscription` before `AWS::SQS::QueuePolicy`, causing an access denied error. The `DependsOn: HighPriorityQueuePolicy` attribute on each subscription forces correct ordering.

**6. Testing by only publishing to SNS without invoking Lambda**
Publishing messages to the SNS topic routes them to the queues but does not invoke Lambda — there is no event source mapping. The invocation is manual: `aws lambda invoke`. If you only publish and then look in the queues, messages will be sitting there unprocessed. Always invoke Lambda explicitly after publishing.

**7. Using inline policies when the lab user lacks `iam:PutRolePolicy`**
CloudFormation implements the `Policies:` block inside `AWS::IAM::Role` using `iam:PutRolePolicy`. In restricted lab environments, this action is often denied — the stack creation fails at the `LambdaExecutionRole` resource with `User is not authorized to perform: iam:PutRolePolicy`. The fix: remove the `Policies:` block entirely and use only `ManagedPolicyArns`. CloudFormation implements managed policy attachments via `iam:AttachRolePolicy`, which is typically allowed even when `iam:PutRolePolicy` is not.

```yaml
# FAILS in restricted environments (uses iam:PutRolePolicy):
Policies:
  - PolicyName: CustomPolicy
    PolicyDocument: { ... }

# WORKS — uses iam:AttachRolePolicy instead:
ManagedPolicyArns:
  - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  - arn:aws:iam::aws:policy/AmazonSQSFullAccess
  - arn:aws:iam::aws:policy/AmazonSNSFullAccess
```

This grants broader permissions than a scoped custom policy, but it is necessary when the environment restricts inline policy creation. In production with full IAM access, a scoped custom policy is always preferred for least privilege.

---

## Real-World Context

**Pull vs push Lambda invocation:** This task uses pull (Lambda polls SQS directly). In production, the push model (event source mapping) is more common for SQS→Lambda because it scales automatically and doesn't require an external scheduler. The pull model is useful when you need explicit control over when Lambda reads from a queue — for example, in a workflow where you want to drain the high-priority queue completely before touching the low-priority one, which is exactly the logic here.

**Priority queuing patterns in production:** This architecture appears in customer support ticket routing (enterprise SLA vs. standard), payment processing (retry failed transactions before processing new ones), CI/CD job queues (hot-fix builds jump ahead of feature builds), and alert systems (critical vs. informational alerts). The SNS→SQS fan-out with filter policies is cleaner than a single queue with priority field because each tier can have independent dead-letter queues, retention periods, and processing concurrency.

**CloudFormation `DependsOn` vs implicit ordering:** CloudFormation automatically infers dependencies from `!Ref` and `!GetAtt` — if Resource A references Resource B, CloudFormation creates B before A. Explicit `DependsOn` is only needed for dependencies that aren't expressed through intrinsic functions, such as the queue policy needing to exist before the SNS subscription uses the queue.

---

## Interview Q&A

**Q1. What is the difference between SNS push delivery and SQS pull polling?**
> SNS is a push service — it delivers messages to subscribers (HTTP endpoints, Lambda, SQS, email) immediately when published, without the subscriber doing anything. SQS is a pull service — messages sit in the queue until a consumer explicitly calls `receive_message` to retrieve them. In this architecture, SNS pushes to SQS (SNS actively writes to the queue), and then Lambda pulls from SQS (Lambda actively reads from the queue via `receive_message`). The event source mapping model sits between these: it's a managed poller that AWS runs on your behalf, calling `receive_message` in a loop and invoking Lambda when messages are found — removing the need for `receive_message` in the Lambda code.

**Q2. Why does reading `os.environ['high_priority_queue']` in Python fail if the template defines `HIGH_PRIORITY_QUEUE_URL`?**
> Python's `os.environ` is a dictionary of environment variable names as strings. Environment variable lookups are case-sensitive on Linux (where Lambda runs). `os.environ['high_priority_queue']` looks for the key `high_priority_queue` exactly — it won't find `HIGH_PRIORITY_QUEUE_URL` because the names are different in both case and suffix. This is a common trap when the Lambda developer chose lowercase names and the infrastructure person (or template generator) used uppercase. The fix is to read the code first and match the CloudFormation template's `Environment.Variables` keys exactly to what the code expects.

**Q3. What does `WaitTimeSeconds=3` in `sqs.receive_message` do?**
> This enables **long polling**. Without it (or with `WaitTimeSeconds=0`), SQS returns immediately even if the queue is empty — which costs more API calls and can cause Lambda to report "No more messages" before all SNS-delivered messages have actually arrived. With `WaitTimeSeconds=3`, SQS waits up to 3 seconds for a message to arrive before returning an empty response. This reduces empty responses and API costs. The maximum is 20 seconds. In production, 20 seconds is standard unless you have strict latency requirements.

**Q4. What does `CAPABILITY_NAMED_IAM` mean and when is `CAPABILITY_IAM` sufficient?**
> Both acknowledge that the template creates IAM resources. `CAPABILITY_IAM` is sufficient for IAM resources with auto-generated names (like inline policies or anonymous roles). `CAPABILITY_NAMED_IAM` is required when any IAM resource specifies an explicit `RoleName`, `PolicyName`, or `GroupName` — as `lambda_execution_role` does here. AWS requires this to prevent accidentally creating or modifying named IAM resources that might conflict with existing ones in the account.

**Q5. How would you modify this architecture to automatically process messages without manual invocation?**
> Replace the pull model with a push model: add `AWS::Lambda::EventSourceMapping` resources pointing at each SQS queue with `Enabled: true`. Remove the manual `sqs.receive_message` calls from `index.py` — instead, read from `event['Records']` which Lambda provides automatically. The event source mapping creates an AWS-managed poller that invokes Lambda whenever messages are available, eliminating the need for external invocation. However, this changes the priority logic: with two event source mappings, Lambda processes messages from both queues concurrently rather than strictly draining high before touching low. True priority with event source mappings requires additional logic, such as disabling the low-priority mapping while the high queue has messages.

**Q6. What happens if the Lambda function fails to delete the SQS message?**
> If `sqs.delete_message` fails (or the function throws an exception before reaching it), the message becomes visible in the queue again after the visibility timeout (60 seconds in this template). The next invocation will re-read and re-process the same message. Without a Dead Letter Queue (DLQ) configured on the SQS queue, a persistently failing message will be retried indefinitely until the message retention period expires. In production, configure a DLQ with `RedrivePolicy: {deadLetterTargetArn: ..., maxReceiveCount: 3}` so messages that fail repeatedly are moved aside rather than blocking processing.

**Q7. Why does CloudFormation need `DependsOn: HighPriorityQueuePolicy` on the SNS subscription?**
> CloudFormation infers creation order from `!Ref` and `!GetAtt` references. The `HighPrioritySubscription` references `!GetAtt HighPriorityQueue.Arn` (which creates an implicit dependency on the queue), but it doesn't reference the queue *policy*. CloudFormation might therefore create the SNS subscription before the queue policy exists — and when SNS attempts to verify it can write to the queue during subscription creation, it fails with an access denied error. The explicit `DependsOn: HighPriorityQueuePolicy` tells CloudFormation to create the queue policy before attempting the subscription, guaranteeing the permission is in place.

---

## Resources

- [CloudFormation Template Reference](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-template-resource-type-ref.html)
- [SNS Filter Policies](https://docs.aws.amazon.com/sns/latest/dg/sns-subscription-filter-policies.html)
- [SQS Long Polling](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-short-and-long-polling.html)
- [Lambda Execution Environment](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-context.html)
- [CloudFormation DependsOn](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-dependson.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
