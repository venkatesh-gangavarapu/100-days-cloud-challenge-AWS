# Day 34 — Deploy Lambda Function from a Zip Package via CLI

> **#100DaysOfCloud | Day 34 of 100**

---

## 📌 The Task

> *Write a Python Lambda handler, package it as a zip file, and deploy it as a Lambda function entirely through the AWS CLI — reusing an existing IAM execution role.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Script file | `lambda_function.py` |
| Package file | `function.zip` |
| Function name | `datacenter-lambda-cli` |
| Runtime | Python |
| Response body | `Welcome to KKE AWS Labs!` |
| Status code | `200` |
| IAM Role | `lambda_execution_role` |
| Method | AWS CLI |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### Two Ways to Deploy Lambda Code

| Method | How |
|--------|-----|
| **Console inline editor** | Paste code directly in the browser — Lambda zips it server-side on Deploy |
| **CLI with zip package** | You build the zip locally, then upload it via `--zip-file` |

This task uses the second method — the one production CI/CD pipelines actually use. The console inline editor is a convenience for tiny functions; any real deployment pipeline builds and ships a zip (or container image).

### Why Zip the Code at All?

Lambda's deployment unit is a **package** — a zip archive (or container image) containing your handler code and any dependencies. AWS doesn't accept raw `.py` files directly; it needs a self-contained, deployable artifact. For a single-file function with no external dependencies, the zip contains exactly one file:

```
function.zip
└── lambda_function.py
```

For functions with dependencies (`requests`, `boto3` extras, etc.), the zip would also contain a `site-packages`-style directory tree with the installed libraries alongside the handler file.

### The Zip Structure Matters

```bash
zip function.zip lambda_function.py
```

This creates a zip where `lambda_function.py` sits at the **root** of the archive — not inside a subfolder. Lambda's handler setting (`lambda_function.lambda_handler`) expects to find `lambda_function.py` at the root. If you zip a parent directory (`zip function.zip lambda-pkg/`), the file ends up at `lambda-pkg/lambda_function.py` instead, and the handler lookup fails with `Unable to import module 'lambda_function'`.

**Correct way to build the zip:**
```bash
cd lambda-pkg/              # cd into the directory FIRST
zip function.zip lambda_function.py   # then zip just the file
```

### CLI Deployment Flow

```
Write lambda_function.py
        │
        ▼
zip function.zip lambda_function.py
        │
        ▼
aws lambda create-function --zip-file fileb://function.zip
        │
        ▼
Lambda uploads the package, provisions the function
        │
        ▼
aws lambda invoke → verify response
```

### `fileb://` vs `file://`

The CLI distinguishes binary and text file references:
- `file://path` — reads the file as text/UTF-8
- `fileb://path` — reads the file as raw bytes (**required for zip files**)

Using `file://` instead of `fileb://` for a zip file causes the upload to fail or corrupt the package, since zip is binary data and `file://` attempts text encoding.

### Reusing an Existing IAM Role

Since `lambda_execution_role` was already created on Day 33, this task reuses it rather than recreating it. In CLI scripting, this means checking for existence first:

```bash
if aws iam get-role --role-name lambda_execution_role >/dev/null 2>&1; then
    echo "exists — reuse"
else
    echo "create it"
fi
```

This idempotency pattern — check before create — is standard practice in any CLI-driven infrastructure script, preventing `EntityAlreadyExists` errors on re-runs.

---

## 🔧 Step-by-Step Solution

### Full Script — Run on `aws-client`

```bash
#!/bin/bash
set -e
REGION="us-east-1"
FUNCTION_NAME="datacenter-lambda-cli"
ROLE_NAME="lambda_execution_role"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# ============================================================
# STEP 1: Create the Python script
# ============================================================
mkdir -p /root/lambda-pkg
cd /root/lambda-pkg

cat > lambda_function.py << 'EOF'
import json

def lambda_handler(event, context):
    return {
        'statusCode': 200,
        'body': json.dumps('Welcome to KKE AWS Labs!')
    }
EOF

echo "lambda_function.py created"
cat lambda_function.py

# ============================================================
# STEP 2: Zip the script (file at root of archive, not in a subfolder)
# ============================================================
zip function.zip lambda_function.py
echo "function.zip created:"
unzip -l function.zip

# ============================================================
# STEP 3: Verify/create the IAM execution role
# ============================================================
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "Role '$ROLE_NAME' already exists — reusing"
else
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
        --assume-role-policy-document file:///tmp/lambda-trust-policy.json
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
    sleep 10
fi

# ============================================================
# STEP 4: Create the Lambda function from the zip package
# ============================================================
aws lambda create-function \
    --region $REGION \
    --function-name "$FUNCTION_NAME" \
    --runtime "python3.12" \
    --role "$ROLE_ARN" \
    --handler "lambda_function.lambda_handler" \
    --zip-file "fileb:///root/lambda-pkg/function.zip" \
    --description "Returns Welcome to KKE AWS Labs! with status 200" \
    --timeout 30 \
    --memory-size 128

aws lambda wait function-active \
    --function-name "$FUNCTION_NAME" --region $REGION

echo "Function is ACTIVE"

# ============================================================
# STEP 5: Invoke and verify
# ============================================================
aws lambda invoke \
    --function-name "$FUNCTION_NAME" \
    --region $REGION \
    --payload '{}' \
    --cli-binary-format raw-in-base64-out \
    /tmp/response.json

cat /tmp/response.json
```

---

### Verifying the Deployment

```bash
# Confirm function exists and is Active
aws lambda get-function --function-name datacenter-lambda-cli --region us-east-1 \
    --query "Configuration.{Name:FunctionName,State:State,Runtime:Runtime,Handler:Handler}" \
    --output table

# Invoke and parse the response
aws lambda invoke --function-name datacenter-lambda-cli --region us-east-1 \
    --payload '{}' --cli-binary-format raw-in-base64-out /tmp/out.json
python3 -c "import json; d=json.load(open('/tmp/out.json')); print('Status:', d['statusCode']); print('Body:', json.loads(d['body']))"

# Check logs
aws logs tail /aws/lambda/datacenter-lambda-cli --region us-east-1
```

---

### Updating the Function Code Later

```bash
# Edit lambda_function.py, then re-zip and update
cd /root/lambda-pkg
zip function.zip lambda_function.py

aws lambda update-function-code \
    --function-name datacenter-lambda-cli \
    --zip-file fileb://function.zip \
    --region us-east-1
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- WRITE SCRIPT ---
cat > lambda_function.py << 'EOF'
import json
def lambda_handler(event, context):
    return {'statusCode': 200, 'body': json.dumps('Welcome to KKE AWS Labs!')}
EOF

# --- ZIP IT (file at root, not in subfolder) ---
zip function.zip lambda_function.py

# --- CREATE FUNCTION FROM ZIP ---
aws lambda create-function \
    --function-name datacenter-lambda-cli \
    --runtime python3.12 \
    --role arn:aws:iam::ACCOUNT_ID:role/lambda_execution_role \
    --handler lambda_function.lambda_handler \
    --zip-file fileb://function.zip \
    --region $REGION

# --- INVOKE ---
aws lambda invoke --function-name datacenter-lambda-cli \
    --payload '{}' --cli-binary-format raw-in-base64-out \
    response.json --region $REGION
cat response.json

# --- UPDATE CODE ---
aws lambda update-function-code \
    --function-name datacenter-lambda-cli \
    --zip-file fileb://function.zip --region $REGION

# --- VIEW LOGS ---
aws logs tail /aws/lambda/datacenter-lambda-cli --region $REGION

# --- DELETE ---
aws lambda delete-function --function-name datacenter-lambda-cli --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Zipping the parent directory instead of just the file**
`zip function.zip lambda-pkg/` puts the file at `lambda-pkg/lambda_function.py` inside the archive. Lambda looks for `lambda_function.py` at the **root**. The fix: `cd` into the directory first, then zip just the file: `cd lambda-pkg && zip function.zip lambda_function.py`.

**2. Using `file://` instead of `fileb://` for the zip upload**
`file://` reads content as text/UTF-8; zip files are binary. Using the wrong prefix corrupts the upload or fails outright with a decode error. Always use `fileb://` for any binary file (zip, image, etc.) in CLI commands.

**3. Creating the function before the IAM role finishes propagating**
IAM is eventually consistent — a role created seconds ago may not yet be visible to the Lambda service in all cases. This produces: `InvalidParameterValueException: The role defined for the function cannot be assumed by Lambda.` A `sleep 10` after role creation resolves this reliably.

**4. Mismatched handler string**
The `--handler` value must be `<filename-without-.py>.<function-name>`. If the file is `lambda_function.py` and the function inside is `lambda_handler`, the handler string is `lambda_function.lambda_handler`. A typo here (e.g., `lambda_function.handler`) causes `Runtime.HandlerNotFound` on invocation.

**5. Not verifying the zip contents before uploading**
`unzip -l function.zip` shows exactly what's inside and at what path — a 5-second sanity check that catches the subfolder issue (Mistake #1) before wasting a deploy cycle.

**6. Forgetting `--cli-binary-format raw-in-base64-out` on invoke**
AWS CLI v2 changed the default binary handling for `invoke`. Without this flag, you may get an error about the payload not being valid base64, or unexpected encoding behavior. Always include it when invoking via CLI v2.

---

## 🌍 Real-World Context

This zip-and-deploy pattern is exactly what CI/CD pipelines automate:

```
GitHub push
    → CodeBuild/GitHub Actions runner
    → pip install -r requirements.txt -t ./package
    → cp lambda_function.py ./package/
    → cd package && zip -r ../function.zip .
    → aws lambda update-function-code --zip-file fileb://function.zip
    → aws lambda publish-version (create immutable version)
    → update alias (prod/staging) to point to new version
```

**Infrastructure as Code equivalent:** In Terraform, this whole flow is captured declaratively:
```hcl
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "lambda_function.py"
  output_path = "function.zip"
}

resource "aws_lambda_function" "this" {
  function_name = "datacenter-lambda-cli"
  filename       = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler        = "lambda_function.lambda_handler"
  runtime        = "python3.12"
  role           = aws_iam_role.lambda_exec.arn
}
```

The `source_code_hash` ensures Terraform only redeploys when the actual code changes — same principle as checking zip contents before deployment.

**S3-based deployment for large packages:** Lambda's direct zip upload via CLI is capped at 50 MB (compressed). For larger packages (ML dependencies, large libraries), the zip is first uploaded to S3, then referenced: `aws lambda create-function --code S3Bucket=my-bucket,S3Key=function.zip`. This is also how most CI/CD pipelines deploy regardless of size, since it decouples the build artifact from the deploy step.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. What's the difference between deploying Lambda code via the console editor vs CLI with a zip file?**
> The console inline editor is for quick edits to simple, dependency-free functions — you type code directly in the browser and Lambda packages it server-side when you click Deploy. It has a size limit (3 MB for the inline editor) and doesn't support adding external libraries directly. The CLI with a zip file is the production-grade approach: you build the deployment package locally (or in CI), including any dependencies, and upload the complete artifact. This is scriptable, repeatable, version-controllable, and works for packages up to 50 MB (or unlimited via S3). Any real deployment pipeline uses the zip/container approach — the console editor is essentially a convenience tool for experimentation.

**Q2. Why does Lambda say "Unable to import module 'lambda_function'" even though the zip clearly contains the file?**
> This almost always means the file is nested inside a folder within the zip rather than sitting at the root. Lambda's import mechanism looks for the module at the top level of the deployment package — if `lambda_function.py` is at `mypackage/lambda_function.py` inside the zip, Python's import system can't find `lambda_function` as a top-level module. The fix is to `cd` into the directory containing the file before running `zip`, so the file is added at the root of the archive: `cd dir && zip out.zip file.py` — not `zip out.zip dir/file.py`. Running `unzip -l function.zip` before upload immediately reveals the actual internal path structure.

**Q3. What's the maximum size for a Lambda deployment package and how do you work around it?**
> Direct upload via console or CLI `--zip-file` is capped at 50 MB compressed (250 MB uncompressed). For larger packages, you upload the zip to S3 first and reference it: `aws lambda create-function --code S3Bucket=mybucket,S3Key=function.zip` — S3-based deployment supports the full 250 MB uncompressed limit. For packages exceeding that (large ML models, extensive native dependencies), the solution is **container images** — Lambda supports OCI/Docker images up to 10 GB, built from an AWS base image and pushed to ECR. This is increasingly the standard for Python functions with heavy dependencies like pandas, numpy, or PyTorch.

**Q4. How would you handle a Lambda function that needs a library not included in the base Python runtime (e.g., `requests`)?**
> Install the library into the same directory as your handler before zipping: `pip install requests -t ./package`, copy `lambda_function.py` into `./package`, then zip the entire directory contents (not the directory itself) so all files sit at the zip root. Alternatively, package the dependency as a **Lambda Layer** — a separate zip containing only the library, uploaded once and attached to one or many functions via `--layers`. Layers keep your function's deployment package small and let multiple functions share the same dependency set without duplicating it in every package.

**Q5. What does `--cli-binary-format raw-in-base64-out` do and why is it needed for `lambda invoke`?**
> AWS CLI v2 changed how it handles binary parameters and binary output compared to v1. By default, v2 expects binary input/output to be base64-encoded in certain contexts. The `raw-in-base64-out` setting tells the CLI: accept the `--payload` as raw JSON text (not pre-base64-encoded) on input, and write the response body as base64-encoded text in cases where the API itself returns binary. For `lambda invoke`, omitting this flag with a plain JSON payload like `'{}'` can produce a "Invalid base64" error in CLI v2, since the default expects already-encoded input. Including the flag restores the more intuitive v1-style behavior.

**Q6. Once a function is deployed, how do you redeploy updated code without recreating the function?**
> Use `update-function-code`, not `create-function`. Rebuild the zip with your changes, then: `aws lambda update-function-code --function-name datacenter-lambda-cli --zip-file fileb://function.zip`. This replaces the code while preserving the function's configuration (role, environment variables, triggers, aliases). `create-function` would fail with `ResourceConflictException` if the function already exists — it's strictly for first-time creation. For configuration changes (memory, timeout, environment variables) without a code change, use `update-function-configuration` instead.

**Q7. How would you verify a Lambda deployment succeeded before considering the task complete?**
> A layered verification, not just "no error returned." First, check the function reaches `Active` state: `aws lambda get-function --function-name X --query Configuration.State` — `Pending` means it's still provisioning. Second, actually invoke it and inspect the real response: `aws lambda invoke ... response.json && cat response.json` — confirm both the status code and body match expectations, not just that the invoke command itself succeeded (a function that runs but returns the wrong thing still gets HTTP 200 from the invoke API call itself). Third, check CloudWatch Logs for the invocation — confirms no runtime errors were silently swallowed. "The CLI command didn't error" and "the function works correctly" are different claims; only the second one matters for a real deployment.

---

## 📚 Resources

- [AWS CLI Reference — lambda create-function](https://docs.aws.amazon.com/cli/latest/reference/lambda/create-function.html)
- [Lambda Deployment Packages](https://docs.aws.amazon.com/lambda/latest/dg/python-package.html)
- [Lambda Container Images](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html)
- [Lambda Layers](https://docs.aws.amazon.com/lambda/latest/dg/configuration-layers.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
