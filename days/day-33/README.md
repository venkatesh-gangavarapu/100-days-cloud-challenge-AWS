# Day 33 — Deploy a Serverless Lambda Function

> **#100DaysOfCloud | Day 33 of 100**

---

## 📌 The Task

> *Create a Lambda function that returns a custom greeting with HTTP status 200 — demonstrating serverless deployment, IAM roles for Lambda, and function testing.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Function name | `devops-lambda` |
| Runtime | Python (3.12) |
| Response body | `Welcome to KKE AWS Labs!` |
| Status code | `200` |
| IAM Role | `lambda_execution_role` |
| Method | AWS Console |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### What Is AWS Lambda?

**AWS Lambda** is a serverless compute service — you upload code and Lambda runs it on demand without you managing any servers. Key characteristics:

| Property | Detail |
|----------|--------|
| **Billing** | Per invocation + duration (millisecond granularity) |
| **Idle cost** | Zero — pay only when code runs |
| **Scaling** | Automatic — up to 1,000 concurrent by default |
| **Max duration** | 15 minutes per invocation |
| **Runtime** | Python, Node.js, Java, Go, Ruby, .NET, custom |
| **Trigger** | API Gateway, S3, DynamoDB, SQS, EventBridge, etc. |

The free tier gives **1 million invocations/month** — this function will stay free indefinitely for low-volume use.

### Lambda Execution Model

```
Trigger (API call, event, schedule)
        │
        ▼
Lambda Service receives event
        │
        ▼
Cold start (if no warm container):
    ├── Provision execution environment
    ├── Download deployment package
    ├── Initialize runtime (Python)
    └── Run initialization code (imports, globals)
        │
        ▼
Handler function called with (event, context)
        │
        ▼
Return value → caller
        │
        ▼
Container stays warm for ~15 min (reused for next invocation)
```

### The `lambda_handler` Function Signature

Every Lambda function has an **entry point** — a handler function with a specific signature:

```python
def lambda_handler(event, context):
    # event  = dict containing the trigger payload
    # context = runtime info (function name, timeout, request ID)
    return response
```

The handler name (`lambda_handler`) is configured in Lambda settings as `lambda_function.lambda_handler` — meaning "in the file `lambda_function.py`, call the function `lambda_handler`".

### The Response Format

For Lambda functions invoked directly (not via API Gateway), you can return any JSON-serializable value. The format used in this task:

```python
return {
    'statusCode': 200,
    'body': json.dumps('Welcome to KKE AWS Labs!')
}
```

This follows the **API Gateway Lambda proxy integration format** — a convention that makes the function compatible with API Gateway without changes:

| Key | Purpose |
|-----|---------|
| `statusCode` | HTTP status code (200, 404, 500, etc.) |
| `body` | Response body — must be a **string** (hence `json.dumps`) |
| `headers` | Optional — HTTP headers to return |

`json.dumps('Welcome to KKE AWS Labs!')` serializes the string to a JSON string: `"Welcome to KKE AWS Labs!"` (with escaped quotes). This is correct — `body` must be a string, not a dict.

### IAM Role for Lambda — Why It's Needed

Lambda needs permission to **write logs to CloudWatch**. Without an execution role, the function runs but produces no logs — making debugging impossible. The `AWSLambdaBasicExecutionRole` managed policy grants exactly what's needed:

```json
{
  "Effect": "Allow",
  "Action": [
    "logs:CreateLogGroup",
    "logs:CreateLogStream",
    "logs:PutLogEvents"
  ],
  "Resource": "arn:aws:logs:*:*:*"
}
```

For functions that access other AWS services (S3, DynamoDB, SQS), additional policies are attached to this same role.

### Cold Start vs Warm Start

- **Cold start**: first invocation, or after a period of inactivity (~15 min). Lambda provisions a new execution environment. Adds 100ms–1s latency depending on runtime and package size.
- **Warm start**: subsequent invocations while the container is still active. The handler is called directly — no provisioning overhead. Much faster.

For Python with no dependencies, cold starts are typically under 100ms — negligible for most use cases.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Step 1 — Create IAM Execution Role**
1. IAM → Roles → Create role
2. AWS service → Lambda → Next
3. Attach: `AWSLambdaBasicExecutionRole` → Next
4. Role name: `lambda_execution_role` → Create role

**Step 2 — Create Lambda Function**
1. Lambda → Functions → Create function → Author from scratch
2. Name: `devops-lambda` | Runtime: Python 3.12
3. Permissions: Use existing role → `lambda_execution_role`
4. Create function

**Step 3 — Write and Deploy Code**

Replace `lambda_function.py` content with:
```python
import json

def lambda_handler(event, context):
    return {
        'statusCode': 200,
        'body': json.dumps('Welcome to KKE AWS Labs!')
    }
```
Click **Deploy**

**Step 4 — Test**
1. Test tab → Create new event → name: `test-event` → Save → Test
2. Expected response:
```json
{
  "statusCode": 200,
  "body": "\"Welcome to KKE AWS Labs!\""
}
```

---

### Method 2 — AWS CLI

```bash
REGION="us-east-1"
FUNCTION_NAME="devops-lambda"
ROLE_NAME="lambda_execution_role"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# ============================================================
# STEP 1: Create the IAM execution role
# ============================================================

echo "=== Step 1: Creating IAM role '$ROLE_NAME' ==="

# Trust policy — allows Lambda service to assume this role
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
    --description "Lambda basic execution role"

# Attach the basic execution policy (CloudWatch Logs access)
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

echo "Role created: $ROLE_NAME"

# Wait for IAM role to propagate
sleep 10

# ============================================================
# STEP 2: Write the Lambda function code
# ============================================================

echo ""
echo "=== Step 2: Preparing function code ==="

mkdir -p /tmp/lambda-package
cat > /tmp/lambda-package/lambda_function.py << 'EOF'
import json

def lambda_handler(event, context):
    return {
        'statusCode': 200,
        'body': json.dumps('Welcome to KKE AWS Labs!')
    }
EOF

# Package into zip
cd /tmp/lambda-package && zip ../devops-lambda.zip lambda_function.py
echo "Code packaged: /tmp/devops-lambda.zip"

# ============================================================
# STEP 3: Create the Lambda function
# ============================================================

echo ""
echo "=== Step 3: Creating Lambda function '$FUNCTION_NAME' ==="

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

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
    --tags Name="$FUNCTION_NAME"

echo "Function created"

# Wait for function to be active
aws lambda wait function-active \
    --function-name "$FUNCTION_NAME" --region $REGION

echo "Function is ACTIVE"

# ============================================================
# STEP 4: Invoke and verify
# ============================================================

echo ""
echo "=== Step 4: Invoking function ==="

aws lambda invoke \
    --function-name "$FUNCTION_NAME" \
    --region $REGION \
    --payload '{}' \
    --cli-binary-format raw-in-base64-out \
    /tmp/lambda-response.json

echo "Response:"
cat /tmp/lambda-response.json
echo ""

# Verify status code and body
RESPONSE=$(cat /tmp/lambda-response.json)
STATUS=$(echo $RESPONSE | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['statusCode'])")
BODY=$(echo $RESPONSE | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.loads(d['body']))")

echo "Status Code: $STATUS"
echo "Body:        $BODY"

if [ "$STATUS" == "200" ] && [ "$BODY" == "Welcome to KKE AWS Labs!" ]; then
    echo "✅ Function verified successfully"
else
    echo "⚠️  Unexpected response"
fi

# ============================================================
# STEP 5: Show function details
# ============================================================

echo ""
echo "=== Function Details ==="

aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" --region $REGION \
    --query "{
        Name:FunctionName,
        Runtime:Runtime,
        Handler:Handler,
        Role:Role,
        Status:State,
        LastModified:LastModified,
        MemoryMB:MemorySize,
        TimeoutSec:Timeout
    }" --output table
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CREATE IAM ROLE ---
aws iam create-role --role-name lambda_execution_role \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name lambda_execution_role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# --- CREATE FUNCTION ---
aws lambda create-function --function-name devops-lambda \
    --runtime python3.12 --handler lambda_function.lambda_handler \
    --role arn:aws:iam::ACCOUNT_ID:role/lambda_execution_role \
    --zip-file fileb://devops-lambda.zip --region $REGION

# --- INVOKE FUNCTION ---
aws lambda invoke --function-name devops-lambda \
    --payload '{}' --cli-binary-format raw-in-base64-out \
    response.json --region $REGION
cat response.json

# --- UPDATE FUNCTION CODE ---
aws lambda update-function-code --function-name devops-lambda \
    --zip-file fileb://devops-lambda.zip --region $REGION

# --- LIST FUNCTIONS ---
aws lambda list-functions --region $REGION \
    --query "Functions[*].{Name:FunctionName,Runtime:Runtime,State:State}" \
    --output table

# --- VIEW LOGS ---
aws logs tail /aws/lambda/devops-lambda --follow --region $REGION

# --- DELETE FUNCTION ---
aws lambda delete-function --function-name devops-lambda --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Not using `json.dumps()` on the body**
The `body` field in the Lambda response must be a **string**, not a dict or any other type. Returning `'body': 'Welcome to KKE AWS Labs!'` works for simple strings, but for JSON objects you need `json.dumps({'message': '...'})`. Returning a raw dict in `body` causes API Gateway to return a 502 error. Always stringify the body.

**2. Clicking Test before clicking Deploy**
The Test button runs whatever code is currently deployed — not what's in the editor. If you edit the code and click Test without clicking Deploy first, the old code runs. The Deploy button is easy to miss. Always Deploy → then Test.

**3. IAM role not having Lambda as trusted entity**
The role's trust policy must include `"Service": "lambda.amazonaws.com"`. Creating an EC2 role and trying to attach it to Lambda fails because Lambda can't assume EC2 roles. Always create the role with Lambda as the trusted service.

**4. Handler path mismatch**
Lambda's handler setting must match `filename.function_name`. Default is `lambda_function.lambda_handler` — meaning `lambda_function.py` contains a function called `lambda_handler`. If you rename the file or the function, update the handler setting under Configuration → General configuration.

**5. IAM role propagation delay**
After creating an IAM role via CLI, there's a 5–15 second propagation delay before Lambda can use it. Creating the function immediately after `create-role` may fail with "The role defined for the function cannot be assumed by Lambda." Adding `sleep 10` after role creation prevents this.

---

## 🌍 Real-World Context

**Lambda in production patterns:**

**API Backend:** Lambda + API Gateway = a fully serverless REST API. Each endpoint maps to a Lambda function. No servers to patch, scales from 0 to millions of requests automatically. Cost is near-zero for low-traffic services.

**Event processing:** S3 event → Lambda (process uploaded file, resize image, extract text). SQS queue → Lambda (process messages, send notifications). DynamoDB Streams → Lambda (react to DB changes, sync to Elasticsearch).

**Scheduled tasks:** EventBridge cron rule → Lambda replaces traditional cron jobs. Database cleanup, report generation, health checks — all run serverless on a schedule with no EC2 instance sitting idle.

**Lambda Layers:** Shared libraries (pandas, requests, custom utilities) packaged as layers and attached to multiple functions. Keeps deployment packages small and library versions consistent across the team.

**Lambda@Edge / CloudFront Functions:** Run code at CloudFront edge locations — request/response manipulation, A/B testing, authentication checks — without adding latency from a centralised Lambda region.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. What is a Lambda cold start and how do you mitigate it?**
> A cold start occurs when Lambda provisions a new execution environment for a function that has no warm container available — typically the first invocation or after 15+ minutes of inactivity. It involves downloading the deployment package, initialising the runtime, and running initialisation code (imports, global variables). Duration ranges from 100ms for Python with no dependencies to 2–5 seconds for Java or large packages. Mitigations: keep deployment packages small (only import what you need), use **Provisioned Concurrency** (pre-warms a set number of execution environments at a fixed cost — eliminates cold starts for those instances), prefer Python/Node.js over Java for latency-sensitive functions, and move expensive initialisation outside the handler (database connections, SDK clients) so they're reused across warm invocations.

**Q2. What is the difference between synchronous and asynchronous Lambda invocation?**
> **Synchronous** (RequestResponse): the caller waits for the function to complete and receives the return value. API Gateway integrations, direct SDK calls, and CLI invocations are synchronous. If the function errors, the caller receives the error. **Asynchronous** (Event): the caller sends the event to an internal Lambda queue and immediately gets a 202 Accepted response without waiting. Lambda retries failed asynchronous invocations up to 2 times with delays. Used with S3 events, SNS, EventBridge — where the trigger doesn't need to wait for completion. For failed asynchronous invocations after all retries, you configure a Dead Letter Queue (SQS or SNS) to capture failed events for investigation.

**Q3. How do you pass configuration (database URLs, API keys) to a Lambda function securely?**
> Never hardcode secrets in function code. Three options in order of security. **Environment variables**: store non-sensitive config (table names, region, log level) as Lambda environment variables — accessible via `os.environ['VAR_NAME']`. For sensitive values, enable encryption with a KMS key. **AWS Systems Manager Parameter Store**: store secrets as SecureString parameters (KMS-encrypted), fetch at runtime with `ssm.get_parameter(Name='/myapp/db-password', WithDecryption=True)`. Cache the value after the first fetch to avoid per-invocation SSM costs. **AWS Secrets Manager**: purpose-built for credentials — auto-rotation, audit trails, native RDS integration. Secrets Manager fetches use `secretsmanager.get_secret_value()`. Lambda execution role needs `ssm:GetParameter` or `secretsmanager:GetSecretValue` permissions accordingly.

**Q4. What is Lambda concurrency and how does it work?**
> Lambda concurrency is the number of function instances running simultaneously. Each invocation occupies one concurrency unit while it's executing. Default regional limit is 1,000 concurrent executions across all functions. Two concurrency controls: **Reserved concurrency** — guarantees a function always has N units available (other functions can't consume them) and caps the function at N (throttles above it). Useful for preventing a function from overwhelming a downstream database. **Provisioned concurrency** — pre-initialises N execution environments so they're always warm, eliminating cold starts. Costs money even when idle. Throttled invocations return a 429 TooManyRequests error for synchronous, or are retried for asynchronous. Monitor with the `Throttles` CloudWatch metric.

**Q5. How would you deploy a Lambda function that needs third-party libraries (e.g., `requests`, `pandas`)?**
> Three approaches. **Deployment package with dependencies**: `pip install requests -t ./package`, copy `lambda_function.py` into `./package`, zip the whole directory — Lambda runs from the zip. Works for small dependency sets. **Lambda Layer**: package dependencies separately as a layer (`zip -r layer.zip python/`), publish the layer, and attach it to one or many functions. Functions share the layer; deployment packages stay small. **Container image**: package the function as a Docker image (up to 10 GB) using the Lambda base image (`public.ecr.aws/lambda/python:3.12`). Best for large dependencies (ML models, complex data processing). Container images are pushed to ECR and referenced in the Lambda function configuration.

**Q6. What is Lambda function versioning and how does it enable safe deployments?**
> Lambda supports publishing **immutable versions** of a function. Each `publish-version` call creates a numbered version (1, 2, 3...) that captures the code, configuration, and environment variables at that point — it never changes. `$LATEST` is the mutable pointer to the most recent deployment. **Aliases** are named pointers to specific versions (e.g., `prod` → v5, `staging` → v6). This enables: **traffic shifting** — a weighted alias can split traffic between two versions (e.g., `prod` sends 90% to v5, 10% to v6 for canary testing); **safe rollback** — if v6 has issues, update the `prod` alias back to v5 instantly. Blue/green deployments with CodeDeploy Lambda deployments automate canary → full rollout with automatic rollback on CloudWatch alarm triggers.

**Q7. How do you monitor and debug a Lambda function in production?**
> Four tools. **CloudWatch Logs**: every invocation writes to `/aws/lambda/function-name`. Log groups auto-created. Use `aws logs tail /aws/lambda/devops-lambda --follow` for live tailing. Add structured logging (JSON) to make logs queryable with CloudWatch Log Insights. **CloudWatch Metrics**: Lambda publishes Invocations, Duration, Errors, Throttles, ConcurrentExecutions metrics. Create alarms on Error rate (> 1% triggers alert) and Duration (approaching 15-min timeout). **X-Ray tracing**: enable active tracing on the function — X-Ray traces the full execution path including downstream AWS service calls (DynamoDB reads, S3 puts). Visualise latency breakdown in the X-Ray console. **Lambda Insights**: enhanced monitoring extension that captures memory usage, CPU time, and cold start frequency as CloudWatch metrics — installed as a Lambda Layer.

---

## 📚 Resources

- [AWS Docs — Lambda Getting Started](https://docs.aws.amazon.com/lambda/latest/dg/getting-started.html)
- [Lambda Execution Role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html)
- [Lambda Programming Model](https://docs.aws.amazon.com/lambda/latest/dg/python-handler.html)
- [Lambda Concurrency](https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html)
- [Lambda Layers](https://docs.aws.amazon.com/lambda/latest/dg/configuration-layers.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
