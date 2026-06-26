#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 39: S3 Static Website Hosting
# Bucket: xfusion-web-76531611 | Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
BUCKET="xfusion-web-76531611"
WEBSITE_URL="http://${BUCKET}.s3-website-${REGION}.amazonaws.com"

echo "Bucket: $BUCKET"
echo "Website URL: $WEBSITE_URL"

# ============================================================
# STEP 1: CREATE THE S3 BUCKET
# NOTE: us-east-1 does NOT accept --create-bucket-configuration
# All other regions require: --create-bucket-configuration LocationConstraint=<region>
# ============================================================

echo ""
echo "=== Step 1: Creating S3 bucket ==="

aws s3api create-bucket \
    --bucket $BUCKET \
    --region $REGION

aws s3api head-bucket --bucket $BUCKET \
    && echo "Bucket confirmed: $BUCKET"

# ============================================================
# STEP 2: DISABLE BLOCK PUBLIC ACCESS
# This MUST come before the public bucket policy
# BPA overrides policies — if BPA is ON, the public policy is nullified
# ============================================================

echo ""
echo "=== Step 2: Disabling Block Public Access ==="

aws s3api put-public-access-block \
    --bucket $BUCKET \
    --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# Verify all four are false
echo "Block Public Access settings:"
aws s3api get-public-access-block --bucket $BUCKET --output table

# ============================================================
# STEP 3: ENABLE STATIC WEBSITE HOSTING
# Configures the website endpoint and sets the index document
# ============================================================

echo ""
echo "=== Step 3: Enabling static website hosting ==="

aws s3api put-bucket-website \
    --bucket $BUCKET \
    --website-configuration '{
        "IndexDocument": {
            "Suffix": "index.html"
        },
        "ErrorDocument": {
            "Key": "index.html"
        }
    }'

echo "Static website hosting enabled"

# Confirm configuration
echo "Website configuration:"
aws s3api get-bucket-website --bucket $BUCKET --output table

# ============================================================
# STEP 4: APPLY PUBLIC READ BUCKET POLICY
# Principal: "*" + s3:GetObject on bucket/* = public read on all objects
# CRITICAL: Resource must be "bucket/*" not just "bucket"
# ============================================================

echo ""
echo "=== Step 4: Applying public read bucket policy ==="

cat > /tmp/public-read-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "PublicReadGetObject",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::${BUCKET}/*"
        }
    ]
}
EOF

echo "Policy document:"
cat /tmp/public-read-policy.json

aws s3api put-bucket-policy \
    --bucket $BUCKET \
    --policy file:///tmp/public-read-policy.json

echo "Bucket policy applied"

# Verify policy was accepted
echo ""
echo "Active bucket policy:"
aws s3api get-bucket-policy \
    --bucket $BUCKET \
    --query "Policy" --output text | python3 -m json.tool

# ============================================================
# STEP 5: UPLOAD index.html
# ============================================================

echo ""
echo "=== Step 5: Uploading index.html ==="

if [ ! -f /root/index.html ]; then
    echo "ERROR: /root/index.html not found"
    exit 1
fi

echo "File to upload:"
cat /root/index.html
echo ""

aws s3 cp /root/index.html "s3://${BUCKET}/index.html" \
    --content-type "text/html" \
    --region $REGION

echo "Upload complete"

# List the bucket contents
echo ""
echo "Bucket contents:"
aws s3 ls s3://$BUCKET/

# ============================================================
# STEP 6: VERIFY PUBLIC WEBSITE ACCESS
# ============================================================

echo ""
echo "=== Step 6: Verifying website accessibility ==="
echo "Website URL: $WEBSITE_URL"

sleep 3  # Brief propagation pause

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 "$WEBSITE_URL")

echo "HTTP Status: $HTTP_STATUS"

if [ "$HTTP_STATUS" == "200" ]; then
    echo ""
    echo "✅ SUCCESS: Website is publicly accessible"
    echo ""
    echo "--- Page content ---"
    curl -s "$WEBSITE_URL"
else
    echo ""
    echo "⚠️  Got HTTP $HTTP_STATUS"
    echo "Debug checklist:"
    echo "  1. Block Public Access disabled?"
    echo "     aws s3api get-public-access-block --bucket $BUCKET"
    echo "  2. Bucket policy applied?"
    echo "     aws s3api get-bucket-policy --bucket $BUCKET"
    echo "  3. Static hosting enabled?"
    echo "     aws s3api get-bucket-website --bucket $BUCKET"
    echo "  4. index.html uploaded?"
    echo "     aws s3 ls s3://$BUCKET/"
fi

echo ""
echo "============================================"
echo "  Bucket:      $BUCKET"
echo "  Website URL: $WEBSITE_URL"
echo "  Region:      $REGION"
echo "============================================"

# ============================================================
# OPTIONAL: UPLOAD ADDITIONAL STATIC FILES
# ============================================================

# Sync a local directory to S3 (useful for full SPA deployments):
# aws s3 sync ./build s3://$BUCKET/ --delete

# ============================================================
# CLEANUP (commented — run to tear down)
# ============================================================

# aws s3 rm s3://$BUCKET/index.html
# aws s3api delete-bucket-policy --bucket $BUCKET
# aws s3api delete-bucket-website --bucket $BUCKET
# aws s3api delete-bucket --bucket $BUCKET --region $REGION
