# Day 39 — S3 Static Website Hosting

> **#100DaysOfCloud | Day 39 of 100**

---

## 📌 The Task

> *Create an S3 bucket, enable static website hosting, configure public read access via a bucket policy, upload index.html, and verify the site is publicly accessible via the S3 website URL.*

**Requirements:**
| Parameter | Value |
|-----------|-------|
| Bucket name | `xfusion-web-76531611` |
| Static website hosting | Enabled, index document: `index.html` |
| Public access | Allowed (bucket policy: `s3:GetObject` to `Principal: *`) |
| File to upload | `/root/index.html` from `aws-client` |
| Verification | Website URL returns the page content |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### S3 as a Web Server

S3's static website hosting feature turns a bucket into a basic HTTP server. Unlike regular S3 object access (which uses the S3 API endpoint and requires authentication), the **website endpoint** serves content over plain HTTP with no auth — just like a CDN or traditional web server. It supports:

- Custom index documents (which file to serve for `/`)
- Custom error documents (which file to serve on 404)
- Redirect rules

What it does **not** support:
- HTTPS (need CloudFront for that)
- Server-side logic (no PHP, Python, Node — purely static)
- Custom domains directly (need Route 53 alias + CloudFront or classic S3 website setup)

### Two Different S3 URL Types

| URL Type | Format | Behaviour |
|---------|--------|-----------|
| **S3 API endpoint** | `https://xfusion-web-76531611.s3.amazonaws.com/index.html` | Returns raw object; requires auth or object-level public ACL |
| **Website endpoint** | `http://xfusion-web-76531611.s3-website-us-east-1.amazonaws.com` | Serves index document; respects website routing rules |

The website endpoint URL is what this task requires. It's only accessible after static website hosting is enabled. Critically, it only supports **HTTP** (not HTTPS) — for HTTPS, you need CloudFront with an ACM certificate in front.

### The Three Layers of Public Access Control

S3 has multiple overlapping mechanisms for controlling public access — understanding all three is important:

```
1. Block Public Access settings (account/bucket-level guardrail)
        ↓ must be OFF (or specifically allow public policies)
2. Bucket policy (who can access which objects)
        ↓ must allow s3:GetObject from Principal: *
3. Object ACL (per-object access control)
        ↓ not needed if bucket policy covers it
```

**Block Public Access** is the outer guardrail — it overrides bucket policies and ACLs. Even if your bucket policy grants public access, if Block Public Access is ON, the policy is effectively nullified. For a public static website, Block Public Access must be turned off.

**Bucket policy** is where you actually grant the access. `Principal: "*"` means "everyone, including unauthenticated users." `s3:GetObject` allows reading the object content. Applied to `arn:aws:s3:::bucket-name/*`, this grants public read on every object in the bucket.

### Why Not Use `s3:GetObject` on the Bucket ARN (Without `/*`)

`s3:GetObject` is an object-level operation — it targets `arn:aws:s3:::bucket/*`, not `arn:aws:s3:::bucket`. Setting the resource to just the bucket ARN (no wildcard) would grant no object access at all — objects live at the sub-resource level. Always use `bucket-name/*` for object operations in S3 policies.

### S3 Website URL Format by Region

The website endpoint URL follows a predictable format:
```
http://<bucket-name>.s3-website-<region>.amazonaws.com
```

For `us-east-1`:
```
http://xfusion-web-76531611.s3-website-us-east-1.amazonaws.com
```

Note: some regions use a dash (`s3-website-us-east-1`) and some use a dot (`s3-website.ap-southeast-1.amazonaws.com`). The CLI and console will give you the exact URL.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Step 1 — Create the Bucket (with public access allowed)**
1. S3 → Create bucket
2. Name: `xfusion-web-76531611` | Region: `us-east-1`
3. Block Public Access: ❌ uncheck "Block all public access" → ✅ acknowledge the warning
4. Create bucket

**Step 2 — Enable Static Website Hosting**
1. Click bucket → **Properties** tab → Static website hosting → Edit
2. Enable | Index document: `index.html`
3. Save changes → note the **Bucket website endpoint**

**Step 3 — Add Public Read Bucket Policy**
1. **Permissions** tab → Bucket policy → Edit
2. Paste:
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "PublicReadGetObject",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::xfusion-web-76531611/*"
        }
    ]
}
```
3. Save changes

**Step 4 — Upload index.html**
1. **Objects** tab → Upload → Add files → select `index.html` → Upload

**Step 5 — Verify**
- Open: `http://xfusion-web-76531611.s3-website-us-east-1.amazonaws.com`

---

### Method 2 — AWS CLI

```bash
#!/bin/bash
set -e
[OREGION="us-east-1"
BUCKET="xfusion-web-76531611"
WEBSITE_URL="http://${BUCKET}.s3-website-${REGION}.amazonaws.com"

# ============================================================
# STEP 1: Create the S3 bucket
# NOTE: us-east-1 does NOT use --create-bucket-configuration
# ============================================================

echo "=== Step 1: Creating S3 bucket '$BUCKET' ==="

aws s3api create-bucket \
    --bucket $BUCKET \
    --region $REGION

echo "Bucket created: $BUCKET"

# ============================================================
# STEP 2: Disable Block Public Access
# Required before a public bucket policy can take effect
# ============================================================

echo ""
echo "=== Step 2: Disabling Block Public Access ==="

aws s3api put-public-access-block \
[I    --bucket $BUCKET \
    --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

echo "Block Public Access disabled"

# ============================================================
# STEP 3: Enable static website hosting
# ============================================================

echo ""
echo "=== Step 3: Enabling static website hosting ==="

aws s3api put-bucket-website \
    --bucket $BUCKET \
    --website-configuration '{
        "IndexDocument": {"Suffix": "index.html"},
        "ErrorDocument": {"Key": "index.html"}
    }'
[O
echo "Static website hosting enabled (index.html)"

# Confirm and get the website endpoint
aws s3api get-bucket-website --bucket $BUCKET --output table

# ============================================================
# STEP 4: Apply public read bucket policy
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

aws s3api put-bucket-policy \
    --bucket $BUCKET \
    --policy file:///tmp/public-read-policy.json

echo "Bucket policy applied"

# Verify policy
aws s3api get-bucket-policy \
    --bucket $BUCKET \
    --query "Policy" --output text | python3 -m json.tool

# ============================================================
# STEP 5: Upload index.html
# ============================================================

echo ""
echo "=== Step 5: Uploading index.html ==="

if [ ! -f /root/index.html ]; then
    echo "ERROR: /root/index.html not found on aws-client"
    exit 1
fi

echo "Content of index.html:"
cat /root/index.html

aws s3 cp /root/index.html s3://${BUCKET}/index.html \
    --content-type "text/html"

echo "Uploaded index.html to s3://$BUCKET/"

# ============================================================
# STEP 6: Verify the upload
# ============================================================

echo ""
echo "=== Step 6: Verifying upload ==="

aws s3 ls s3://$BUCKET/

# ============================================================
# STEP 7: Test the website URL
# ============================================================

echo ""
echo "=== Step 7: Testing website URL ==="
echo "Website URL: $WEBSITE_URL"

sleep 5  # Brief pause for propagation

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$WEBSITE_URL")
echo "HTTP Status: $HTTP_STATUS"

if [ "$HTTP_STATUS" == "200" ]; then
    echo "✅ Website is publicly accessible"
    echo ""
    echo "--- Page content preview ---"
    curl -s "$WEBSITE_URL" | head -20
else
    echo "⚠️  Got HTTP $HTTP_STATUS — check bucket policy and website hosting config"
fi

echo ""
echo "============================================"
echo "  Bucket:      $BUCKET"
echo "  Website URL: $WEBSITE_URL"
echo "  Index doc:   index.html"
echo "============================================"
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"
BUCKET="xfusion-web-76531611"

# --- CREATE BUCKET (no LocationConstraint for us-east-1) ---
aws s3api create-bucket --bucket $BUCKET --region $REGION

# --- DISABLE BLOCK PUBLIC ACCESS ---
aws s3api put-public-access-block --bucket $BUCKET \
    --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# --- ENABLE STATIC WEBSITE HOSTING ---
aws s3api put-bucket-website --bucket $BUCKET \
    --website-configuration '{"IndexDocument":{"Suffix":"index.html"}}'

# --- APPLY PUBLIC READ POLICY ---
aws s3api put-bucket-policy --bucket $BUCKET \
    --policy '{"Version":"2012-10-17","Statement":[{"Sid":"PublicRead","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::BUCKET_NAME/*"}]}'

# --- UPLOAD index.html ---
aws s3 cp /root/index.html s3://$BUCKET/index.html --content-type "text/html"

# --- GET WEBSITE URL ---
echo "http://${BUCKET}.s3-website-${REGION}.amazonaws.com"

# --- TEST ---
curl http://${BUCKET}.s3-website-${REGION}.amazonaws.com

# --- LIST OBJECTS ---
aws s3 ls s3://$BUCKET/

# --- GET BUCKET WEBSITE CONFIG ---
aws s3api get-bucket-website --bucket $BUCKET

# --- GET BUCKET POLICY ---
aws s3api get-bucket-policy --bucket $BUCKET --query "Policy" --output text

# --- CLEANUP ---
aws s3 rm s3://$BUCKET/index.html
aws s3api delete-bucket --bucket $BUCKET --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Forgetting to disable Block Public Access before adding the public bucket policy**
Block Public Access is the outer security guardrail — it overrides bucket policies. If it's left ON with `BlockPublicPolicy=true`, the bucket policy granting `Principal: *` access is silently ignored and all requests return 403 Access Denied. Always disable the relevant Block Public Access settings before applying a public-read policy. In the console, you'll get an explicit error; in the CLI, the `put-bucket-policy` command may succeed but the policy will be ineffective.

**2. Using the S3 API endpoint instead of the website endpoint URL**
`https://xfusion-web-76531611.s3.amazonaws.com/index.html` is the **API endpoint** — it returns the raw object and requires proper authentication or public object ACLs. `http://xfusion-web-76531611.s3-website-us-east-1.amazonaws.com` is the **website endpoint** — it serves the index document, respects routing rules, and returns friendly 403/404 pages. Static website hosting must be enabled for the website URL to work at all; it won't resolve before that.

**3. Applying the bucket policy to the bucket ARN instead of `bucket/*`**
`s3:GetObject` is an object-level operation. The resource must be `arn:aws:s3:::xfusion-web-76531611/*` (with `/*` for all objects). Using just `arn:aws:s3:::xfusion-web-76531611` (without `/*`) applies the policy to the bucket itself — not its contents — and `GetObject` calls still return 403. The `/*` wildcard is required.

**4. Uploading index.html without setting the correct Content-Type**
The `--content-type "text/html"` flag on `aws s3 cp` ensures S3 serves the file with the correct `Content-Type: text/html` response header. Without it, some browsers may download the file instead of rendering it, or display it as plaintext. S3 usually infers the content type from the file extension, but setting it explicitly is best practice for web-hosted files.

**5. Expecting HTTPS on the S3 website endpoint**
The S3 static website endpoint (`s3-website-*.amazonaws.com`) only supports HTTP, never HTTPS. Attempting to access it via `https://` returns an SSL error. For HTTPS static website hosting on S3, you need CloudFront with an ACM certificate as the HTTPS termination layer, with the S3 website endpoint (or S3 origin) as the origin. The task only requires HTTP, so this isn't an issue here — but it's important to know for real deployments.

**6. Uploading to the wrong path**
The index document is `index.html`, which means S3 looks for an object with the key `index.html` in the bucket root. Uploading to `s3://bucket/files/index.html` would require browsing to `/files/` for the page to render — the root URL would return a 403. Always upload to `s3://bucket/index.html` (root of the bucket) for the index document to work.

---

## 🌍 Real-World Context

S3 static website hosting is one of AWS's most cost-effective services for appropriate use cases:

**SPA deployments:** Single-page applications (React, Vue, Angular) built with `npm run build` produce pure static files — HTML, JS, CSS, images. Upload the build output to S3, enable static website hosting, and the app is deployed. No EC2 instance, no server to maintain, bills in cents per month for moderate traffic.

**CloudFront + S3 for production:** The S3 website endpoint uses HTTP only. For production, CloudFront sits in front:
```
Browser (HTTPS)
    → CloudFront distribution (HTTPS termination, ACM certificate, custom domain)
    → S3 website origin (HTTP, or S3 API origin with OAC)
```
This gives HTTPS, global CDN caching (drastically reduces latency for global users), custom domain, WAF integration, and Lambda@Edge for edge-side request manipulation — none of which the bare S3 website endpoint provides.

**Comparison with EC2-hosted static sites:** A t2.micro EC2 running Nginx costs ~$8/month at minimum plus maintenance overhead. An S3 bucket serving the same files costs a fraction of a cent per month for storage plus tiny transfer charges. For purely static content, S3 is almost always the right answer — the only reason to use EC2 is if you need server-side rendering or dynamic content generation.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. What is the difference between the S3 API endpoint and the S3 website endpoint?**
> The S3 API endpoint (`bucket.s3.amazonaws.com`) is the standard object storage interface — it requires authentication or specific public ACLs, doesn't serve index documents, and returns raw S3 errors for missing objects. The website endpoint (`bucket.s3-website-region.amazonaws.com`) is a purpose-built HTTP server — it serves the configured index document for the root path, returns the configured error document for 404s, supports redirect routing rules, and is accessible without any auth when a public-read bucket policy is applied. Website hosting must be explicitly enabled in the bucket configuration for the website endpoint to function. The API endpoint always exists; the website endpoint is opt-in.

**Q2. Why does Block Public Access need to be disabled for a static website, and what's the risk?**
> Block Public Access is a VPC-level safety net that overrides any bucket policy or object ACL that would otherwise make content publicly accessible. For a static website, you need a bucket policy granting `s3:GetObject` to `Principal: *` — and that policy only takes effect once the relevant Block Public Access settings are disabled. The risk is accidental exposure: once you disable BPA and add the public policy, any object you upload to the bucket becomes immediately publicly accessible, not just `index.html`. This is appropriate for a public website bucket where everything should be public, but would be dangerous if applied to a bucket also containing sensitive data. Best practice is to use a dedicated bucket for the public website, separate from any buckets holding private data.

**Q3. How would you add HTTPS to this S3 static website setup?**
> Create a CloudFront distribution with the S3 website endpoint as the origin. Provision an ACM certificate in `us-east-1` (CloudFront requires this region regardless of where the S3 bucket is) for your custom domain. Configure the CloudFront distribution to use that certificate for HTTPS. Point your domain's DNS to the CloudFront distribution (CNAME or Route 53 alias record). The browser hits CloudFront over HTTPS; CloudFront fetches from S3 over HTTP internally. Additionally, you can configure a CloudFront function or Lambda@Edge to redirect HTTP to HTTPS, and restrict the S3 bucket to only accept requests from CloudFront (using Origin Access Control) so the S3 website URL itself isn't directly accessible.

**Q4. A file was uploaded to S3 but the website shows a 403 Forbidden error. What do you check?**
> Three places in order. First, verify Block Public Access settings: `aws s3api get-public-access-block --bucket bucket-name` — all four values should be `false` for a public static website. Second, verify the bucket policy exists and covers the right resource: `aws s3api get-bucket-policy --bucket bucket-name` — confirm `Principal: "*"`, `Action: "s3:GetObject"`, and `Resource: "arn:aws:s3:::bucket-name/*"` (with `/*`). Third, confirm static website hosting is enabled: `aws s3api get-bucket-website --bucket bucket-name`. If all three are correct and you still get 403, check whether the specific file has a restrictive object ACL overriding the bucket policy.

**Q5. How does S3 static website hosting handle routing for a single-page application (SPA)?**
> SPAs use client-side routing — the browser navigates to paths like `/products/123` that don't correspond to actual files in S3. When a user directly accesses `http://bucket-url/products/123`, S3 looks for an object with that key, doesn't find it, and returns 403 or 404. The standard workaround for SPAs on S3 is to set the error document to `index.html` — so all 404s serve the SPA's main file, and the SPA's JavaScript router takes over and handles the path client-side. In the S3 website configuration: `ErrorDocument: {Key: "index.html"}`. Behind CloudFront, you can configure custom error responses to serve `index.html` with a 200 instead of a 404, which is cleaner but requires the CloudFront layer.

**Q6. What are the cost components of hosting a static website on S3?**
> Three components. Storage: $0.023 per GB per month for Standard storage — a typical SPA is a few MB, making storage effectively free. GET requests: $0.0004 per 1,000 requests — at 100,000 page views per month with ~10 objects per page load, that's about $0.40. Data transfer out: $0.09 per GB after the first GB free — at 1 MB per page load and 100,000 views, that's about $9. For comparison, adding CloudFront shifts the GET request cost to $0.0075 per 10,000 HTTPS requests (higher per-request cost) but caches aggressively, reducing the number of origin requests to S3 dramatically for repeated content. At scale, CloudFront often reduces total cost while adding HTTPS and global edge caching.

**Q7. How would you automate deploying updated website files to S3 without full re-uploads?**
> Use `aws s3 sync` instead of `aws s3 cp`. `sync` compares local files against S3 objects and only uploads new or changed files, skipping unchanged ones — `aws s3 sync ./build s3://bucket-name/ --delete`. The `--delete` flag removes objects from S3 that no longer exist locally (useful for cleaning up old bundles from previous builds). For CI/CD integration, add this to the deploy step of your pipeline after `npm run build`. If CloudFront is in front of the bucket, also run `aws cloudfront create-invalidation --distribution-id DIST_ID --paths "/*"` after the sync to purge the CDN cache, ensuring users get the new files immediately rather than cached old ones.

---

## 📚 Resources

- [AWS Docs — S3 Static Website Hosting](https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteHosting.html)
- [S3 Website Endpoints](https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteEndpoints.html)
- [Bucket Policy for Public Website](https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteAccessPermissionsReqd.html)
- [CloudFront + S3 Static Website](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/getting-started-secure-static-website-cloudformation-template.html)
- [Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
