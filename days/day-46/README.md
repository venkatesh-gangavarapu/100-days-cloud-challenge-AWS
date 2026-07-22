# Day 46 — Lambda-Triggered S3 File Copy with DynamoDB Logging

> **#100DaysOfCloud | Day 46 of 100**

---

## 📌 The Task

> *Build an event-driven file transfer pipeline: uploads to a public S3 bucket automatically trigger a Lambda function that copies the file to a private bucket and writes a structured log entry to DynamoDB.*

**Architecture:**
```
User uploads file
    │
    ▼ s3:ObjectCreated:* event
devops-public-205 (public S3 bucket)
    │
    ▼ S3 event notification triggers
devops-copyfunction (Lambda)
    │
    ├──► devops-private-26898 (private S3 bucket) — file copied here
    │
    └──► devops-S3CopyLogs (DynamoDB) — log: source, destination, key
```

**Resources:**
| Resource | Name | Detail |
|----------|------|--------|
| Public S3 bucket | `devops-public-205` | Upload trigger point |
| Private S3 bucket | `devops-private-26898` | Secure destination |
| Lambda function | `devops-copyfunction` | Copy logic, pre-written |
| IAM role | `lambda_execution_role` | S3 read/write + DynamoDB put |
| DynamoDB table | `devops-S3CopyLogs` | `LogID` (String) partition key |
| Test file | `/root/sample.zip` | Triggers the pipeline |

---

## 🧠 Core Concepts

### Event-Driven Architecture with S3 + Lambda

This task implements a serverless event-driven pipeline. Instead of a polling loop checking for new files, S3 publishes an event the moment an object is created, and Lambda consumes it immediately.

```
Traditional (polling):  worker checks S3 every 60s → copies → delay + idle cost
Event-driven (S3→Lambda): upload fires event → Lambda wakes, runs, completes in <1s
```

### The Trigger Chain — Three Required Pieces

1. **Lambda permission** — `lambda:InvokeFunction` granted to `s3.amazonaws.com` on the specific source bucket ARN. Without this, S3 cannot invoke Lambda even if the notification is configured.
2. **S3 notification configuration** — tells S3 which event type (`s3:ObjectCreated:*`) triggers which Lambda ARN.
3. **Lambda function** — reads the event payload containing bucket name and object key.

### The Lambda Event Payload

```json
{
  "Records": [{
    "s3": {
      "bucket": { "name": "devops-public-205" },
      "object": { "key": "sample.zip", "size": 1234 }
    }
  }]
}
```

### IAM Role — Four Permission Sets

| Permission | Action | Resource |
|-----------|--------|----------|
| Read source | `s3:GetObject`, `s3:ListBucket` | `devops-public-205` + `/*` |
| Write destination | `s3:PutObject` | `devops-private-26898/*` |
| Log to DynamoDB | `dynamodb:PutItem` | `devops-S3CopyLogs` table ARN |
| Write Lambda logs | via `AWSLambdaBasicExecutionRole` | CloudWatch Logs |

Missing any one causes a specific, identifiable failure in CloudWatch Logs.

---

## 🔧 Step-by-Step Solution

### Pre-Step — Patch lambda-function.py (Required First)

```bash
sed -i "s/REPLACE-WITH-YOUR-DYNAMODB-TABLE/devops-S3CopyLogs/g" /root/lambda-function.py
sed -i "s/REPLACE-WITH-YOUR-PRIVATE-BUCKET/devops-private-26898/g" /root/lambda-function.py
cat /root/lambda-function.py   # verify both replacements before packaging
```

### Method 1 — AWS Management Console

**Step 1 — Create Public S3 Bucket**
S3 → Create bucket → `devops-public-205` → us-east-1 → Uncheck all Block Public Access → Acknowledge → Create
→ Permissions → Bucket policy → paste `s3:GetObject` / `Principal: *` policy

**Step 2 — Create Private S3 Bucket**
S3 → Create bucket → `devops-private-26898` → Block Public Access all checked → Create

**Step 3 — Create DynamoDB Table**
DynamoDB → Create table → `devops-S3CopyLogs` → Partition key: `LogID` (String) → Default settings → Create

**Step 4 — Create IAM Role**
IAM → Roles → Create → AWS service → Lambda → Next → skip managed policies → Name: `lambda_execution_role` → Create
→ Add inline policy for S3 + DynamoDB permissions
→ Attach `AWSLambdaBasicExecutionRole` managed policy

**Step 5 — Create Lambda Function**
Lambda → Create function → Author from scratch → Name: `devops-copyfunction` → Python 3.12 → Role: `lambda_execution_role`
→ Upload zip of patched `lambda-function.py`
→ Handler: `lambda-function.lambda_handler`
→ Deploy

**Step 6 — Add S3 Trigger**
Lambda → `devops-copyfunction` → Add trigger → S3 → `devops-public-205` → All object create events → Add

**Step 7 — Test and Verify**
```bash
aws s3 cp /root/sample.zip s3://devops-public-205/
sleep 15
aws s3 ls s3://devops-private-26898/
aws dynamodb scan --table-name devops-S3CopyLogs --region us-east-1
```

---

### Method 2 — AWS CLI

[OSee `commands.sh` for the complete 9-step script.

---

## 💻 Commands Reference

```bash
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# --- PATCH LAMBDA FILE ---
sed -i "s/REPLACE-WITH-YOUR-DYNAMODB-TABLE/devops-S3CopyLogs/g" /root/lambda-function.py
sed -i "s/REPLACE-WITH-YOUR-PRIVATE-BUCKET/devops-private-26898/g" /root/lambda-function.py

# --- CREATE PUBLIC BUCKET ---
aws s3api create-bucket --bucket devops-public-205 --region $REGION
aws s3api put-public-access-block --bucket devops-public-205 \
    --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
aws s3api put-bucket-policy --bucket devops-public-205 \
    --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::devops-public-205/*"}]}'

# --- CREATE PRIVATE BUCKET ---
aws s3api create-bucket --bucket devops-private-26898 --region $REGION
aws s3api put-public-access-block --bucket devops-private-26898 \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# --- CREATE DYNAMODB TABLE ---
aws dynamodb create-table --table-name devops-S3CopyLogs --region $REGION \
    --attribute-definitions AttributeName=LogID,AttributeType=S \
    --key-schema AttributeName=LogID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
aws dynamodb wait table-exists --table-name devops-S3CopyLogs --region $REGION

# --- PACKAGE AND DEPLOY LAMBDA ---
cd /tmp && cp /root/lambda-function.py . && zip lambda-package.zip lambda-function.py
aws lambda create-function --function-name devops-copyfunction \
    --runtime python3.12 --role $ROLE_ARN \
    --handler lambda-function.lambda_handler \
    --zip-file fileb:///tmp/lambda-package.zip --region $REGION
aws lambda wait function-active --function-name devops-copyfunction --region $REGION

# --- ADD TRIGGER PERMISSION ---
aws lambda add-permission --function-name devops-copyfunction \
    --statement-id s3-trigger --action lambda:InvokeFunction \
    --principal s3.amazonaws.com \
    --source-arn arn:aws:s3:::devops-public-205 \
    --source-account $ACCOUNT_ID --region $REGION

# --- CONFIGURE S3 NOTIFICATION ---
aws s3api put-bucket-notification-configuration \
    --bucket devops-public-205 \
    --notification-configuration "{\"LambdaFunctionConfigurations\":[{\"LambdaFunctionArn\":\"arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:devops-copyfunction\",\"Events\":[\"s3:ObjectCreated:*\"]}]}"

# --- TEST ---
aws s3 cp /root/sample.zip s3://devops-public-205/
sleep 15
aws s3 ls s3://devops-private-26898/
aws dynamodb scan --table-name devops-S3CopyLogs --region $REGION --output table

# --- DEBUG IF NEEDED ---
aws logs tail /aws/lambda/devops-copyfunction --region $REGION --follow
```

---

## ⚠️ Common Mistakes

**1. Not patching lambda-function.py before packaging**
The placeholders must be replaced before zipping. Deploying with `REPLACE-WITH-YOUR-DYNAMODB-TABLE` intact means Lambda silently fails on every DynamoDB write. Check with `cat /root/lambda-function.py` after `sed -i`.

**2. Skipping `lambda add-permission` before the S3 notification**
The S3 notification configuration and the Lambda permission are two separate operations. Without the permission grant, S3 events are silently dropped — there's no error message, the Lambda is just never invoked.

**3. Wrong handler string**
If the file is `lambda-function.py`, handler is `lambda-function.lambda_handler`. If it's `lambda_function.py` (underscore), handler is `lambda_function.lambda_handler`. A mismatch causes a runtime error on every invocation.

**4. Missing `AWSLambdaBasicExecutionRole`**
Without CloudWatch Logs permissions, Lambda can't write execution logs. When the function fails, there's nothing to debug with.

**5. Uploading test file to the private bucket instead of the public one**
The trigger is only on `devops-public-205`. Uploading to `devops-private-26898` does nothing.

**6. IAM propagation delay**
After creating the role and attaching policies, wait 15+ seconds before deploying or invoking Lambda. The first invocation may fail with `AccessDeniedException` if the role hasn't propagated yet.

---

## 🌍 Real-World Context

**This pattern runs at scale in production for:** image thumbnail generation, document processing pipelines, security scanning on upload, data ingestion from CSV/JSON uploads, and cross-bucket replication with audit trails. The DynamoDB log gives a structured, queryable record of every file operation — useful for compliance, debugging, and cost attribution.

**Production enhancements:** Add SQS between S3 and Lambda for retry logic and ordered processing. Add a Lambda Dead Letter Queue (DLQ) for failed invocations. Use S3 Replication for simpler cross-region mirroring without Lambda. Add DynamoDB Streams on the log table to push alerts when errors are logged.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. How does the S3 → Lambda trigger work at the infrastructure level?**
> S3 event notifications are configured on the source bucket. When an object matching the event type is created, S3 directly invokes the Lambda function with the event payload — it's a synchronous invocation, not a message queue. S3 retries failed invocations twice. For Lambda to accept this, a resource-based permission must explicitly allow `s3.amazonaws.com` to call `lambda:InvokeFunction`, scoped to the specific source bucket ARN.

**Q2. What is the confused deputy problem, and how does `--source-account` fix it?**
> Without `--source-account`, any S3 bucket in any AWS account could trigger your Lambda by knowing its ARN. The `--source-account` constraint restricts invocations to buckets owned by your specific account. Combined with `--source-arn` for the specific bucket, this prevents cross-account abuse where a third party's bucket triggers your Lambda.

**Q3. The Lambda runs successfully but nothing appears in the private bucket. What do you check?**
> CloudWatch Logs first: `aws logs tail /aws/lambda/devops-copyfunction --follow`. Check for: placeholder strings not replaced in code; IAM role missing `s3:PutObject` on the private bucket; `copy_object` using the wrong bucket/key. If no invocation appears in logs at all, check the Lambda permission grant and S3 notification configuration.

**Q4. How would you make this pipeline resilient to failures?**
> Three additions: Lambda DLQ for failed invocations; structured error handling in code with error status written to DynamoDB; SQS buffer between S3 and Lambda for configurable retry with backoff and exactly-once processing guarantees.

**Q5. How does Lambda scale for thousands of simultaneous uploads?**
> Direct S3 → Lambda invocation automatically scales — one Lambda execution per S3 event, up to the account concurrency limit (default 1,000). No code changes needed for burst scaling. For workloads needing ordered processing or concurrency control, shift to S3 → SQS → Lambda with configurable `MaximumConcurrency`.

**Q6. What DynamoDB schema would you design for production logging?**
> `LogID` (UUID, partition key), `Timestamp` (sort key for time-range queries), GSI on `SourceBucket` + `Timestamp` for per-bucket history. Attributes: `DestinationBucket`, `ObjectKey`, `ObjectSize`, `Status` (success/error), `ErrorMessage`, `CopyDuration`. TTL attribute set to 90 days for automatic expiry.

**Q7. Console trigger vs CLI `put-bucket-notification-configuration` — what's the difference?**
> The Lambda console trigger does both steps: adds the Lambda permission AND configures the S3 notification. CLI requires both steps manually. When a trigger stops working, check both independently — the permission and the notification can be deleted or misconfigured separately with no visible connection between them.

---

## 📚 Resources

- [S3 Event Notifications](https://docs.aws.amazon.com/AmazonS3/latest/userguide/NotificationHowTo.html)
- [Lambda Resource-Based Policies](https://docs.aws.amazon.com/lambda/latest/dg/access-control-resource-based.html)
- [Lambda with S3 Tutorial](https://docs.aws.amazon.com/lambda/latest/dg/with-s3-example.html)
- [Day 33 — Lambda Basics](../day-33/README.md)
- [Day 42 — DynamoDB](../day-42/README.md)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
