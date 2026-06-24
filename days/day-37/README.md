# Day 37 — EC2 IAM Role for S3 Access

> **#100DaysOfCloud | Day 37 of 100**

---

## 📌 The Task

> *Create a private S3 bucket, build an IAM policy with scoped S3 permissions, attach it to an IAM role, associate that role with an existing EC2 instance, and verify the instance can upload and list objects in the bucket without any hardcoded credentials.*

**Requirements:**
| Resource | Detail |
|----------|--------|
| EC2 Instance | `datacenter-ec2` (existing) |
| S3 Bucket | `datacenter-s3-683588789756` — private |
| IAM Policy | `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` on the bucket |
| IAM Role | `datacenter-role` — EC2 service principal |
| Test | Upload a file from EC2 → S3, then list it |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### Why IAM Roles for EC2, Not Access Keys

The old approach to giving an EC2 instance AWS credentials was to create an IAM user, generate access keys, and paste them into `~/.aws/credentials` on the instance. This is a serious security anti-pattern:

- Credentials are static — they never expire unless you manually rotate them
- Credentials sit in plaintext on the instance's filesystem
- If the instance is compromised, the attacker has persistent AWS access
- Key rotation requires touching every instance that has them

**IAM roles for EC2 solve all of this.** The EC2 service fetches short-lived credentials (valid 1 hour) from the Instance Metadata Service (IMDS) on behalf of the role and rotates them automatically. The application (the AWS CLI, SDK) retrieves these credentials transparently — no configuration needed on the instance.

```
EC2 Instance
    │
    │  GET http://169.254.169.254/latest/meta-data/iam/security-credentials/datacenter-role
    ▼
Instance Metadata Service (IMDS)
    │  returns: { AccessKeyId, SecretAccessKey, Token, Expiration }
    ▼
AWS CLI / SDK uses these credentials automatically
    │
    ▼
S3 API call — authenticated
```

The credentials at `169.254.169.254` are refreshed every hour and are only accessible from within the instance. An attacker with API-level access cannot retrieve them without first compromising the instance itself.

### IAM Role Components — Three Separate Things

This is where people get confused:

| Component | What it is | Created by |
|-----------|-----------|-----------|
| **IAM Role** | The identity — defines *who* can assume it (trust policy) | `aws iam create-role` |
| **IAM Policy** | The permissions — defines *what* the role can do | `aws iam create-policy` |
| **Instance Profile** | The container that links a role to an EC2 instance | `aws iam create-instance-profile` |

You can't attach an IAM role directly to an EC2 instance — you attach an **instance profile** which wraps the role. The console creates the instance profile automatically when you create a role for EC2. The CLI requires creating it manually as a separate step.

### The Two Resource ARNs in the S3 Policy

```json
"Resource": [
    "arn:aws:s3:::datacenter-s3-683588789756",
    "arn:aws:s3:::datacenter-s3-683588789756/*"
]
```

Two ARNs are required because S3 operations work at two levels:
- `s3:ListBucket` acts on the **bucket itself** → `arn:aws:s3:::bucket-name`
- `s3:GetObject` and `s3:PutObject` act on **objects inside the bucket** → `arn:aws:s3:::bucket-name/*`

Specifying only `arn:aws:s3:::bucket-name/*` means `ListBucket` fails (access denied on the bucket resource). Specifying only `arn:aws:s3:::bucket-name` means `GetObject` and `PutObject` fail (access denied on the objects). Both ARNs are required for this set of operations.

### Trust Policy — The Other Half of an IAM Role

A role has two policy documents:
1. **Trust policy** (who can assume this role) — attached at creation
2. **Permission policies** (what the role can do) — attached afterward

For EC2 instance roles, the trust policy must include `ec2.amazonaws.com` as the principal:

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "ec2.amazonaws.com" },
  "Action": "sts:AssumeRole"
}
```

Without this, the EC2 service cannot assume the role on behalf of the instance and the credentials would never be issued.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

#### Part 1 — SSH Key Setup (aws-client terminal)

```bash
# Generate if not exists
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
fi
cat /root/.ssh/id_rsa.pub   # copy this output
```

#### Part 2 — Inject Key into datacenter-ec2

1. EC2 Console → `datacenter-ec2` → **Connect → EC2 Instance Connect → Connect**
2. In the browser terminal:
```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "PASTE_PUBLIC_KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

#### Part 3 — Create Private S3 Bucket

1. **S3 Console → Create bucket**
2. Bucket name: `datacenter-s3-683588789756` | Region: `us-east-1`
3. Block Public Access: ✅ all four options checked (default)
4. Create bucket

#### Part 4 — Create IAM Policy

1. **IAM Console → Policies → Create policy**
2. Switch to **JSON** tab and paste:
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::datacenter-s3-683588789756",
                "arn:aws:s3:::datacenter-s3-683588789756/*"
            ]
        }
    ]
}
```
3. Next → Policy name: `datacenter-s3-policy` → **Create policy**

#### Part 5 — Create IAM Role

1. **IAM Console → Roles → Create role**
2. Trusted entity: **AWS service** | Use case: **EC2** → Next
3. Search and attach `datacenter-s3-policy` → Next
4. Role name: `datacenter-role` → **Create role**

#### Part 6 — Attach Role to datacenter-ec2

1. **EC2 Console → Instances → datacenter-ec2**
2. **Actions → Security → Modify IAM role**
3. Select `datacenter-role` → **Update IAM role**

#### Part 7 — Test from EC2

Get the public IP from the console, then:
```bash
# From aws-client
ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no root@<EC2_PUBLIC_IP>

# Inside EC2
echo "test file from $(hostname) - $(date)" > /tmp/testfile.txt
aws s3 cp /tmp/testfile.txt s3://datacenter-s3-683588789756/
aws s3 ls s3://datacenter-s3-683588789756/
```

---

### Method 2 — AWS CLI

```bash
#!/bin/bash
set -e
REGION="us-east-1"
BUCKET="datacenter-s3-683588789756"
POLICY_NAME="datacenter-s3-policy"
ROLE_NAME="datacenter-role"

[O# ============================================================
# STEP 1: SSH KEY SETUP
# ============================================================

echo "=== Step 1: SSH key ==="
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -C "root@aws-client"
    echo "Key generated"
else
    echo "Key already exists"
fi
chmod 600 /root/.ssh/id_rsa
PUB_KEY=$(cat /root/.ssh/id_rsa.pub)
echo "Public key ready"

# ============================================================
# STEP 2: CREATE PRIVATE S3 BUCKET
# ============================================================

echo ""
echo "=== Step 2: Creating private S3 bucket ==="

[I# us-east-1 does NOT accept --create-bucket-configuration
aws s3api create-bucket --bucket $BUCKET --region $REGION

aws s3api put-public-access-block --bucket $BUCKET \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "Bucket created and locked private: $BUCKET"

# Verify
aws s3api head-bucket --bucket $BUCKET && echo "Bucket confirmed"

# ============================================================
# STEP 3: CREATE IAM POLICY (scoped to the specific bucket)
# Two resource ARNs required: bucket-level + object-level
[O# ============================================================

echo ""
echo "=== Step 3: Creating IAM policy '$POLICY_NAME' ==="

cat > /tmp/s3-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListBucketAccess",
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::${BUCKET}"
        },
        {
            "Sid": "ObjectAccess",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject"
            ],
            "Resource": "arn:aws:s3:::${BUCKET}/*"
        }
    ]
}
EOF

POLICY_ARN=$(aws iam create-policy \
    --policy-name $POLICY_NAME \
    --policy-document file:///tmp/s3-policy.json \
    --description "Allow PutObject, GetObject, ListBucket on $BUCKET" \
    --query "Policy.Arn" --output text)

echo "Policy ARN: $POLICY_ARN"

# ============================================================
# STEP 4: CREATE IAM ROLE WITH EC2 TRUST POLICY
# ============================================================

echo ""
echo "=== Step 4: Creating IAM role '$ROLE_NAME' ==="

cat > /tmp/ec2-trust.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

aws iam create-role \
    --role-name $ROLE_NAME \
    --assume-role-policy-document file:///tmp/ec2-trust.json \
    --description "IAM role for datacenter-ec2 S3 access"

# Attach the policy to the role
aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn $POLICY_ARN

echo "Policy attached to role"

# ============================================================
# STEP 5: CREATE INSTANCE PROFILE AND LINK ROLE
# (Console does this automatically; CLI requires manual creation)
# ============================================================

echo ""
echo "=== Step 5: Creating instance profile ==="

aws iam create-instance-profile \
    --instance-profile-name $ROLE_NAME \
    2>/dev/null && echo "Instance profile created" || echo "Already exists"

aws iam add-role-to-instance-profile \
    --instance-profile-name $ROLE_NAME \
    --role-name $ROLE_NAME \
    2>/dev/null && echo "Role added to profile" || echo "Already linked"

echo "Waiting for IAM propagation..."
sleep 15

# ============================================================
# STEP 6: ATTACH INSTANCE PROFILE TO datacenter-ec2
# ============================================================

echo ""
echo "=== Step 6: Attaching role to datacenter-ec2 ==="

INSTANCE_ID=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=datacenter-ec2" \
               "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

EC2_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "Instance: $INSTANCE_ID  IP: $EC2_IP"

# Check if a role is already attached
EXISTING=$(aws ec2 describe-iam-instance-profile-associations --region $REGION \
    --filters "Name=instance-id,Values=$INSTANCE_ID" \
    --query "IamInstanceProfileAssociations[0].AssociationId" --output text)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
    echo "Replacing existing role association..."
    aws ec2 replace-iam-instance-profile-association \
        --association-id $EXISTING \
        --iam-instance-profile Name=$ROLE_NAME \
        --region $REGION
else
    aws ec2 associate-iam-instance-profile \
        --region $REGION \
        --instance-id $INSTANCE_ID \
        --iam-instance-profile Name=$ROLE_NAME
fi

echo "IAM role attached"

# Verify
aws ec2 describe-iam-instance-profile-associations --region $REGION \
    --filters "Name=instance-id,Values=$INSTANCE_ID" \
    --query "IamInstanceProfileAssociations[0].{Profile:IamInstanceProfile.Arn,State:State}" \
    --output table

# ============================================================
# STEP 7: INJECT SSH KEY INTO EC2
# ============================================================

echo ""
echo "=== Step 7: Injecting SSH key via SSM ==="

MY_IP=$(curl -s https://checkip.amazonaws.com)
EC2_SG=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $EC2_SG --protocol tcp --port 22 \
    --cidr "${MY_IP}/32" --region $REGION 2>/dev/null || true

CMD_ID=$(aws ssm send-command \
    --region $REGION \
    --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[
        'mkdir -p /root/.ssh && chmod 700 /root/.ssh',
        'grep -qF \"${PUB_KEY}\" /root/.ssh/authorized_keys 2>/dev/null || echo \"${PUB_KEY}\" >> /root/.ssh/authorized_keys',
        'chmod 600 /root/.ssh/authorized_keys'
    ]" \
    --query "Command.CommandId" --output text)

sleep 10
echo "SSM injection complete"

# ============================================================
# STEP 8: TEST — UPLOAD AND LIST FROM EC2
# ============================================================

echo ""
echo "=== Step 8: Testing S3 access from EC2 ==="

sleep 10  # Wait for SSM key injection to complete

ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 root@$EC2_IP << REMOTE
echo "=== Inside datacenter-ec2 ==="

# Create test file
echo "Test from datacenter-ec2 - \$(date)" > /tmp/testfile.txt
echo "testfile.txt contents: \$(cat /tmp/testfile.txt)"

# Upload to S3
echo "Uploading to S3..."
aws s3 cp /tmp/testfile.txt s3://datacenter-s3-683588789756/

# List the bucket
echo "Listing S3 bucket..."
aws s3 ls s3://datacenter-s3-683588789756/

echo "=== S3 access test COMPLETE ==="
REMOTE

echo ""
echo "============================================"
echo "  Bucket:     $BUCKET"
echo "  Policy:     $POLICY_NAME"
echo "  Role:       $ROLE_NAME"
echo "  Instance:   $INSTANCE_ID ($EC2_IP)"
echo "============================================"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"
BUCKET="datacenter-s3-683588789756"

# --- CREATE PRIVATE BUCKET ---
aws s3api create-bucket --bucket $BUCKET --region $REGION
aws s3api put-public-access-block --bucket $BUCKET \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# --- CREATE POLICY ---
aws iam create-policy --policy-name datacenter-s3-policy \
    --policy-document file:///tmp/s3-policy.json \
    --query "Policy.Arn" --output text

# --- CREATE ROLE ---
aws iam create-role --role-name datacenter-role \
    --assume-role-policy-document file:///tmp/ec2-trust.json

aws iam attach-role-policy --role-name datacenter-role \
    --policy-arn $POLICY_ARN

# --- INSTANCE PROFILE (CLI only — console auto-creates this) ---
aws iam create-instance-profile --instance-profile-name datacenter-role
aws iam add-role-to-instance-profile \
    --instance-profile-name datacenter-role --role-name datacenter-role

# --- ATTACH TO EC2 ---
aws ec2 associate-iam-instance-profile \
    --instance-id $INSTANCE_ID \
    --iam-instance-profile Name=datacenter-role --region $REGION

# --- VERIFY ROLE ON INSTANCE ---
aws ec2 describe-iam-instance-profile-associations --region $REGION \
    --filters "Name=instance-id,Values=$INSTANCE_ID"

# --- TEST FROM EC2 ---
aws s3 cp /tmp/testfile.txt s3://datacenter-s3-683588789756/
aws s3 ls s3://datacenter-s3-683588789756/
```

---

## ⚠️ Common Mistakes

**1. Forgetting to create the Instance Profile when using the CLI**
The AWS Console creates an instance profile automatically when you create an EC2 role. The CLI does not — `create-role` and `create-instance-profile` are separate operations. Skipping `create-instance-profile` followed by `add-role-to-instance-profile` means `associate-iam-instance-profile` will fail because there's nothing to attach.

**2. Using only one Resource ARN in the S3 policy**
`s3:ListBucket` requires the bucket ARN (`arn:aws:s3:::bucket-name`). `s3:GetObject` and `s3:PutObject` require the object ARN (`arn:aws:s3:::bucket-name/*`). Specifying only one of the two causes access denied errors on whichever operations target the level that's missing. Both ARNs are required.

**3. Running the test from aws-client instead of from inside the EC2 instance**
The task specifically requires testing from within `datacenter-ec2` because that's the instance with the role attached. Running `aws s3 cp` from `aws-client` uses the aws-client's own credentials (not the EC2 role) and would succeed even if the EC2 instance had no permissions at all — making the test meaningless for validation purposes.

**4. IAM propagation delay causing `UnauthorizedAccess` right after role attachment**
IAM changes are eventually consistent and can take 15–30 seconds to propagate. Immediately running the S3 test after `associate-iam-instance-profile` may still fail. A brief sleep or explicit retry resolves this.

**5. Trying to attach a role to an already-profiled instance without replacing**
If `datacenter-ec2` already has an IAM role attached, `associate-iam-instance-profile` fails with a conflict. The correct operation is `replace-iam-instance-profile-association` using the existing association ID from `describe-iam-instance-profile-associations`.

---

## 🌍 Real-World Context

The EC2-role-to-S3 pattern is one of the most fundamental access patterns in AWS and the building block for dozens of common architectures:

**Application data storage:** Web application EC2 instances use a role scoped to their bucket for uploads (user profile images, documents, exports). The role's permissions are defined once in IAM and apply to every instance in the fleet — no per-instance credential management.

**Log shipping:** EC2 instances running application workloads ship logs to a central S3 bucket using a role that only has `s3:PutObject` on the logging bucket — no read, no list. Least privilege: the instance can write its own logs but can't read anyone else's.

**Auto Scaling integration:** When an ASG launches a new instance, that instance automatically inherits the role from the launch template's instance profile. No manual credential injection needed — every instance in the fleet gets the same S3 access from the moment it boots.

**Principle of least privilege in practice:** This task's policy grants exactly three actions on exactly one bucket. A common mistake in production is attaching `AmazonS3FullAccess` (the AWS managed policy) — which grants full read/write access to every S3 bucket in the account. Scoping to specific actions on a specific bucket ensures a compromise of this instance can't be used to read data from unrelated buckets.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. Why should EC2 instances use IAM roles instead of access keys for AWS API access?**
> IAM roles for EC2 deliver temporary, automatically-rotated credentials via the Instance Metadata Service (IMDS). The EC2 service fetches new credentials every hour and makes them available at `169.254.169.254/latest/meta-data/iam/security-credentials/<role-name>` — the AWS CLI and SDK read them transparently with no configuration. Access keys, by contrast, are long-lived static credentials that must be manually rotated, are stored in plaintext on the filesystem, and if leaked provide persistent access until explicitly revoked. Roles also allow centralized permission management via IAM — changing the role's policies immediately affects all instances using it, without touching any instance's configuration.

**Q2. Why does an S3 policy for `ListBucket`, `GetObject`, and `PutObject` need two different Resource ARNs?**
> S3 has two resource levels: the bucket itself and objects within it. `s3:ListBucket` is a bucket-level operation — it lists the contents of `arn:aws:s3:::bucket-name`. `s3:GetObject` and `s3:PutObject` are object-level operations — they act on individual objects at `arn:aws:s3:::bucket-name/*`. IAM policy evaluation is strict about resource matching: a statement with only `bucket-name/*` will deny `ListBucket` (which targets the bucket, not objects), and a statement with only `bucket-name` will deny `GetObject` and `PutObject` (which target objects). Both ARNs are required in the same policy to cover all three operations.

**Q3. What is the difference between an IAM role and an instance profile?**
> An IAM role is the identity construct — it defines a trust policy (who can assume it) and has permission policies attached to it. An instance profile is the mechanism that delivers the role to an EC2 instance — it's a container that holds exactly one IAM role and can be associated with an EC2 instance. The EC2 service uses the instance profile to call `sts:AssumeRole` on behalf of the instance and deliver temporary credentials via IMDS. The AWS Console creates the instance profile automatically when you create an EC2-type IAM role. The CLI requires creating them separately — `aws iam create-instance-profile` followed by `aws iam add-role-to-instance-profile`. They always have the same name in console-created setups, which is why the distinction is easy to miss until you hit the error doing it manually.

**Q4. How does the IMDS deliver credentials to the application running on the EC2 instance?**
> The Instance Metadata Service runs at the link-local address `169.254.169.254`, accessible only from within the instance. The AWS CLI and SDKs check this endpoint automatically as one of their credential resolution steps. When an instance profile is attached, `GET http://169.254.169.254/latest/meta-data/iam/security-credentials/` returns the role name, and `GET .../security-credentials/<role-name>` returns a JSON object with `AccessKeyId`, `SecretAccessKey`, `Token`, and `Expiration`. The SDK caches these and refreshes them when close to expiry. The application code needs zero credential configuration — it just calls the S3 API and the SDK handles authentication transparently. IMDSv2 (the current default) requires a session token for this flow, providing protection against SSRF attacks that try to exfiltrate the credentials.

**Q5. How would you verify that the role attached to an EC2 instance has the correct permissions before deploying the application?**
> Use `aws iam simulate-principal-policy` to test the role's permissions against specific actions and resources without making actual API calls. First retrieve the role's policies, then run the simulation: `aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::ACCOUNT:role/datacenter-role --action-names s3:PutObject s3:ListBucket s3:GetObject --resource-arns arn:aws:s3:::datacenter-s3-683588789756 arn:aws:s3:::datacenter-s3-683588789756/*`. The output shows `allowed` or `implicitDeny`/`explicitDeny` for each action/resource combination. Alternatively, from within the EC2 instance itself, run the `aws s3 cp` and `aws s3 ls` commands directly — if they succeed, the permissions are correct.

**Q6. What would happen if you ran the S3 test commands on aws-client instead of inside datacenter-ec2?**
> The test would use aws-client's own configured AWS credentials (from the CLI config or environment variables), not the datacenter-ec2 instance role. If aws-client's credentials have S3 access, the upload and list would succeed — but that doesn't validate that the EC2 instance has the correct permissions at all. The EC2 instance could have zero IAM configuration and the aws-client test would still pass. Always run the validation from inside the instance using the instance's own metadata-service credentials — this is the only way to confirm the role is correctly attached and has the right permissions.

**Q7. How would you restrict an EC2 instance so it can only write to S3 but never read from it, even accidentally?**
> Remove `s3:GetObject` from the policy, leaving only `s3:PutObject` and `s3:ListBucket`. With only `PutObject`, the instance can upload new files but cannot download any object content — `GetObject` would return `Access Denied`. If even `ListBucket` shouldn't be allowed (to prevent the instance from knowing what files exist), remove that too and keep only `PutObject`. This pattern is used for log shipping: an application instance can write its own logs to S3, but cannot read other logs — reducing the blast radius if the instance is compromised. The key principle is to grant only the minimum set of actions the application actually needs, verified by reading the application code to understand what API calls it makes.

---

## 📚 Resources

- [AWS Docs — IAM Roles for EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html)
- [IAM Policy Simulator](https://policysim.aws.amazon.com/)
- [S3 Actions Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazons3.html)
- [IMDS and Instance Credentials](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html)
- [IMDSv2 Security](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
