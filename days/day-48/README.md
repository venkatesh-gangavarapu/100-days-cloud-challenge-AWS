# Day 48 — CloudFormation: Lambda Function Deployment

> **#100DaysOfCloud | Day 48 of 100**

---

## 📌 The Task

> *Write a CloudFormation template that deploys a Lambda function returning a 200 response with a fixed message body, using a named IAM role.*

**Stack name:** `datacenter-lambda-app`
**Template:** `/root/datacenter-lambda.yml`

| Resource | Name | Detail |
|----------|------|--------|
| Lambda function | `datacenter-lambda` | Python, returns 200 + body |
| IAM role | `lambda_execution_role` | Lambda execution role |
| Response body | `Welcome to KKE AWS Labs!` | statusCode 200 |

---

## 🧠 Core Concepts

### CloudFormation Lambda Inline Code (ZipFile)

For small functions, CloudFormation supports embedding Python code directly in the template via `Code.ZipFile`. No S3 bucket, no zip file, no separate upload step:

```yaml
Code:
  ZipFile: |
    def lambda_handler(event, context):
        return {
            'statusCode': 200,
            'body': 'Welcome to KKE AWS Labs!'
        }
```

Constraints: the function must be self-contained (no external dependencies beyond the standard library and boto3), and the ZipFile content must be consistently indented as a YAML literal block.

### Lambda Return Format

A Lambda function returning an HTTP-style response uses:
```python
return {
    'statusCode': 200,
    'body': 'Welcome to KKE AWS Labs!'
}
```

`statusCode` is the HTTP status code (used by API Gateway if fronting Lambda). `body` is the response content. When invoked directly (not via API Gateway), the entire dict is the return value — both fields appear in the invocation response.

### IAM Role — Managed Policies Only

This lab environment blocks `iam:PutRolePolicy` (inline policies). The template uses only `ManagedPolicyArns` which CloudFormation implements via `iam:AttachRolePolicy` (allowed):

```yaml
ManagedPolicyArns:
  - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

`AWSLambdaBasicExecutionRole` grants Lambda permission to write logs to CloudWatch — the minimum required for any Lambda function.

### DependsOn — Role Before Function

The `DatacenterLambda` resource has `DependsOn: LambdaExecutionRole` to ensure CloudFormation creates the IAM role before attempting to create the Lambda function. Without this, CloudFormation might try to create the Lambda while the role ARN is still resolving, causing a `ResourceNotFoundException`.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Console

**Step 1 — Write the template on aws-client**
```bash
cat > /root/datacenter-lambda.yml << 'YAML'
# ... see full template in commands.sh
YAML
```

**Step 2 — Deploy via Console**
CloudFormation → Create stack → Upload template → Stack name: `datacenter-lambda-app` → Check CAPABILITY_NAMED_IAM → Create

**Step 3 — Test Lambda**
Lambda console → `datacenter-lambda` → Test → Create test event (empty JSON `{}`) → Test → verify response body

### Method 2 — AWS CLI

```bash
# Validate
aws cloudformation validate-template \
    --template-body file:///root/datacenter-lambda.yml --region us-east-1

# Deploy
aws cloudformation deploy \
    --template-file /root/datacenter-lambda.yml \
    --stack-name datacenter-lambda-app \
    --capabilities CAPABILITY_NAMED_IAM \
    --region us-east-1

# Test
aws lambda invoke \
    --function-name datacenter-lambda \
    --payload '{}' \
    --cli-binary-format raw-in-base64-out \
    --region us-east-1 \
    /tmp/response.json && cat /tmp/response.json
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- DEPLOY ---
aws cloudformation deploy \
    --template-file /root/datacenter-lambda.yml \
    --stack-name datacenter-lambda-app \
    --capabilities CAPABILITY_NAMED_IAM --region $REGION

# --- CHECK STACK ---
aws cloudformation describe-stacks \
    --stack-name datacenter-lambda-app --region $REGION \
    --query "Stacks[0].{Status:StackStatus}" --output table

# --- TEST LAMBDA ---
aws lambda invoke \
    --function-name datacenter-lambda --region $REGION \
    --payload '{}' --cli-binary-format raw-in-base64-out \
    /tmp/out.json && cat /tmp/out.json

# --- DEBUG FAILURES ---
aws cloudformation describe-stack-events \
    --stack-name datacenter-lambda-app --region $REGION \
    --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].{Resource:LogicalResourceId,Reason:ResourceStatusReason}" \
    --output table

# --- CLEANUP ---
aws cloudformation delete-stack --stack-name datacenter-lambda-app --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Using inline `Policies:` block instead of `ManagedPolicyArns`**
This environment blocks `iam:PutRolePolicy` (confirmed on Day 47). Any `Policies:` block inside `AWS::IAM::Role` fails with `AccessDenied`. Always use `ManagedPolicyArns` in this lab environment.

**2. Wrong Python indentation in ZipFile block**
The YAML `ZipFile: |` literal block requires consistent indentation for the Python code. If the `def` line is at a different indent level than the `return` block, Python raises an `IndentationError` at runtime. Keep all code at a uniform indent level relative to the `ZipFile` key.

**3. Missing `--capabilities CAPABILITY_NAMED_IAM`**
`lambda_execution_role` is an explicitly named IAM resource. Without this flag: `InsufficientCapabilitiesException`.

**4. Handler string doesn't match ZipFile content**
`Handler: index.lambda_handler` means: module `index`, function `lambda_handler`. With `ZipFile`, CloudFormation always uses `index` as the module name — the file is stored internally as `index.py`. Using `Handler: lambda_function.lambda_handler` or any other prefix will cause a runtime error.

**5. Not waiting for `CREATE_COMPLETE` before testing**
`cloudformation deploy` blocks until the stack reaches a terminal state, but calling `lambda invoke` immediately after may occasionally hit a race condition while Lambda's execution environment initializes. If the invocation fails with `ResourceNotFoundException`, wait 10 seconds and retry.

---

## 🌍 Real-World Context

**CloudFormation inline Lambda vs S3-deployed:** ZipFile inline code is appropriate for small utility functions (health checks, custom resources, simple transformers). For anything with external dependencies, the workflow is: `pip install -r requirements.txt -t ./package` → `zip -r function.zip ./package` → `aws s3 cp function.zip s3://deploy-bucket/` → CloudFormation references `S3Bucket` and `S3Key` in the `Code` block. AWS SAM (Serverless Application Model) and CDK automate this packaging step.

**CloudFormation custom resources:** Lambda functions are often used as CloudFormation custom resources — letting you extend CloudFormation to manage resources it doesn't natively support. The function receives a `CREATE`, `UPDATE`, or `DELETE` event from CloudFormation and responds with a success/failure signal. The same deployment pattern (inline or S3-deployed Lambda + IAM role in CFN) applies.

---

## ❓ Interview Q&A

**Q1. What is the ZipFile property in a CloudFormation Lambda resource?**
> `ZipFile` allows embedding Lambda function code directly in the CloudFormation template as a YAML literal string. CloudFormation packages the string into a zip file and deploys it as the function's code package. It's limited to single-file functions with no external dependencies (only the standard library and boto3, which are pre-installed in Lambda's execution environment). For multi-file functions or functions with pip dependencies, use `S3Bucket` and `S3Key` to reference a pre-uploaded zip.

**Q2. Why is `Handler: index.lambda_handler` always correct for ZipFile deployments?**
> When CloudFormation deploys a `ZipFile`, it stores the code internally as a file named `index.py`. The Lambda handler format is `<module>.<function>` — so `index.lambda_handler` means "the `lambda_handler` function in the `index` module (index.py)." This is fixed by CloudFormation's ZipFile implementation and cannot be changed. Specifying any other module prefix (like `main.lambda_handler` or `function.handler`) causes a `Runtime.ImportModuleError` because the underlying file is always `index.py`.

**Q3. What is `AWSLambdaBasicExecutionRole` and what does it grant?**
> It's an AWS managed policy that grants Lambda the minimum permissions needed to write execution logs to CloudWatch Logs: `logs:CreateLogGroup`, `logs:CreateLogStream`, and `logs:PutLogEvents`. Every Lambda function should have this policy (or equivalent) on its role — without it, CloudWatch receives no logs, making debugging nearly impossible. When Lambda throws an unhandled exception, the stack trace only appears in CloudWatch Logs — so losing log permissions effectively makes runtime errors invisible.

**Q4. What's the difference between `iam:PutRolePolicy` and `iam:AttachRolePolicy`?**
> `iam:PutRolePolicy` creates or updates an **inline policy** embedded directly in the role — it's part of the role definition and deleted when the role is deleted. `iam:AttachRolePolicy` attaches a **managed policy** (an independent IAM resource) to the role — the policy exists separately and can be attached to multiple roles. CloudFormation uses `PutRolePolicy` to implement the `Policies:` block and `AttachRolePolicy` for `ManagedPolicyArns`. In restricted lab environments, `PutRolePolicy` is often blocked while `AttachRolePolicy` is permitted — requiring the `ManagedPolicyArns` approach.

**Q5. How would you add environment variables to this Lambda via CloudFormation?**
> Add an `Environment` block under the Lambda's `Properties`:
> ```yaml
> Environment:
>   Variables:
>     GREETING: "Welcome to KKE AWS Labs!"
>     STAGE: "production"
> ```
> Then reference them in the function: `os.environ['GREETING']`. Environment variables are useful for separating configuration from code — the same function code can behave differently across dev/staging/prod stacks by changing the template's variable values, without modifying the function itself.

---

## 📚 Resources

- [AWS::Lambda::Function](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-lambda-function.html)
- [Lambda ZipFile Property](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-lambda-function-code.html)
- [AWSLambdaBasicExecutionRole](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSLambdaBasicExecutionRole.html)
- [Day 33 — Lambda Basics](../days/day-33/README.md)
- [Day 47 — CloudFormation Priority Queuing](../days/day-47/README.md)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
