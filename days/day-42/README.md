# Day 42 — DynamoDB: Create a Table, Insert Items, and Verify

> **#100DaysOfCloud | Day 42 of 100**

---

## 📌 The Task

> *Create a DynamoDB table for a To-Do application, insert two tasks with specific attributes and status values, then verify each item is stored correctly.*

**Requirements:**
| Resource | Detail |
|----------|--------|
| Table name | `devops-tasks` |
| Primary key | `taskId` (String) |
| Task 1 | `taskId: "1"`, `description: "Learn DynamoDB"`, `status: "completed"` |
| Task 2 | `taskId: "2"`, `description: "Build To-Do App"`, `status: "in-progress"` |
| Verification | Task 1 status = `completed`, Task 2 status = `in-progress` |
| Region | `us-east-1` |

---

## 🧠 Core Concepts

### What Is Amazon DynamoDB?

**DynamoDB** is AWS's fully managed NoSQL key-value and document database. It's serverless in the truest sense — no cluster to provision, no OS to patch, no connection pool to manage. It scales automatically, delivers single-digit millisecond latency at any scale, and offers two capacity modes:

| Capacity Mode | How It Works | Best For |
|---------------|-------------|---------|
| **On-Demand** (`PAY_PER_REQUEST`) | Auto-scales, pay per request | Unpredictable or new workloads |
| **Provisioned** | You set read/write capacity units | Predictable, high-volume workloads |

For development and tasks like this one, On-Demand eliminates the need to estimate or tune capacity.

### DynamoDB vs Relational Databases

| | DynamoDB | MySQL/PostgreSQL |
|--|----------|----------------|
| **Schema** | Schemaless (only keys defined) | Fixed schema, migrations required |
| **Queries** | By key or index | Full SQL, arbitrary queries |
| **Joins** | Not supported | Full join support |
| **Scaling** | Horizontal, automatic | Vertical first, then complex sharding |
| **Latency** | Single-digit ms at scale | Variable |
| **Use case** | High-throughput key-value, gaming, IoT, sessions | Complex relational queries, reporting |

### Primary Key Types

DynamoDB items are accessed by primary key. Two options:

| Type | Components | Access pattern |
|------|-----------|----------------|
| **Simple (Partition key only)** | Just `taskId` | Find by exact `taskId` |
| **Composite (Partition + Sort key)** | `userId` + `taskId` | Find by user, sort/range by task |

This task uses a **simple primary key** — just `taskId`. Every item is uniquely identified by its `taskId` value.

### DynamoDB Data Types

DynamoDB uses a typed attribute system. In the CLI JSON format:

| Code | Type | Example |
|------|------|---------|
| `S` | String | `{"S": "completed"}` |
| `N` | Number | `{"N": "42"}` |
| `BOOL` | Boolean | `{"BOOL": true}` |
| `L` | List | `{"L": [{"S": "a"}, {"S": "b"}]}` |
| `M` | Map (nested object) | `{"M": {"key": {"S": "val"}}}` |
| `SS` | String Set | `{"SS": ["a", "b", "c"]}` |
| `NULL` | Null | `{"NULL": true}` |

The CLI representation `{"S": "completed"}` is the **DynamoDB JSON format** — different from plain JSON. Some clients (SDKs, the console's JSON editor) handle this automatically; the CLI always uses this typed format.

### Schemaless Items

Unlike a SQL table where every row has the same columns, DynamoDB items in the same table can have completely different attributes. Only the primary key attribute (`taskId`) must be present in every item. An item could have 2 attributes or 200 — no schema change required. This is what "schemaless" means in practice.

### `get-item` vs `scan` vs `query`

| Operation | What it does | When to use |
|-----------|-------------|-------------|
| `get-item` | Retrieves one item by exact primary key | You know the exact key |
| `query` | Retrieves items matching a key condition | Partition key required; efficient |
| `scan` | Reads every item in the table (filtering optionally) | Last resort; expensive at scale |

For verification, `get-item` is the correct and efficient choice — you know the exact `taskId` values to check.

---

## 🔧 Step-by-Step Solution

### Method 1 — AWS Management Console

**Step 1 — Create the Table**
1. DynamoDB Console → Tables → Create table
2. Table name: `devops-tasks`
3. Partition key: `taskId` | Type: **String** (not Number)
4. Table settings: **Default settings**
5. Create table → wait for status **Active**

**Step 2 — Insert Task 1**
1. Tables → devops-tasks → **Explore table items** tab
2. **Create item**
3. Switch to **JSON view** and paste:
```json
{
  "taskId":      {"S": "1"},
  "description": {"S": "Learn DynamoDB"},
  "status":      {"S": "completed"}
}
```
4. Create item

**Step 3 — Insert Task 2**
1. Create item again
2. Paste:
```json
[O{
  "taskId":      {"S": "2"},
  "description": {"S": "Build To-Do App"},
  "status":      {"S": "in-progress"}
}
```
3. Create item

**Step 4 — Verify**
- Items appear in the table browser
- Click each item to confirm attribute values

---

### Method 2 — AWS CLI

```bash
#!/bin/bash
set -e
REGION="us-east-1"
TABLE="devops-tasks"

# ============================================================
# STEP 1: Create DynamoDB table with taskId as partition key
# billing-mode PAY_PER_REQUEST = on-demand, no capacity planning
# ============================================================

echo "=== Step 1: Creating table '$TABLE' ==="

aws dynamodb create-table \
    --region $REGION \
    --table-name $TABLE \
[I    --attribute-definitions \
        AttributeName=taskId,AttributeType=S \
    --key-schema \
        AttributeName=taskId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Name,Value=$TABLE

echo "Waiting for table to become ACTIVE..."
aws dynamodb wait table-exists --table-name $TABLE --region $REGION

aws dynamodb describe-table --table-name $TABLE --region $REGION \
    --query "Table.{Name:TableName,Status:TableStatus,Keys:KeySchema}" \
    --output table

# ============================================================
# STEP 2: Insert Task 1
# ============================================================

echo ""
echo "=== Step 2: Inserting Task 1 ==="

aws dynamodb put-item \
    --region $REGION \
    --table-name $TABLE \
    --item '{
        "taskId":      {"S": "1"},
[O        "description": {"S": "Learn DynamoDB"},
        "status":      {"S": "completed"}
    }'

echo "Task 1 inserted: taskId=1, status=completed"

# ============================================================
# STEP 3: Insert Task 2
# ============================================================

echo ""
echo "=== Step 3: Inserting Task 2 ==="

aws dynamodb put-item \
    --region $REGION \
    --table-name $TABLE \
    --item '{
        "taskId":      {"S": "2"},
        "description": {"S": "Build To-Do App"},
        "status":      {"S": "in-progress"}
    }'

echo "Task 2 inserted: taskId=2, status=in-progress"

# ============================================================
# STEP 4: Verify using get-item (exact key lookup — efficient)
# ============================================================

echo ""
echo "=== Step 4: Verification ==="

echo "--- Task 1 ---"
aws dynamodb get-item \
    --region $REGION \
    --table-name $TABLE \
    --key '{"taskId": {"S": "1"}}' \
    --query "Item.{taskId:taskId.S,description:description.S,status:status.S}" \
    --output table

echo "--- Task 2 ---"
aws dynamodb get-item \
    --region $REGION \
    --table-name $TABLE \
    --key '{"taskId": {"S": "2"}}' \
    --query "Item.{taskId:taskId.S,description:description.S,status:status.S}" \
    --output table

echo "--- Full table scan (all items) ---"
aws dynamodb scan \
    --region $REGION \
    --table-name $TABLE \
    --query "Items[*].{taskId:taskId.S,description:description.S,status:status.S}" \
    --output table

# Programmatic verification
STATUS1=$(aws dynamodb get-item \
    --region $REGION --table-name $TABLE \
    --key '{"taskId": {"S": "1"}}' \
    --query "Item.status.S" --output text)

STATUS2=$(aws dynamodb get-item \
    --region $REGION --table-name $TABLE \
    --key '{"taskId": {"S": "2"}}' \
    --query "Item.status.S" --output text)

echo ""
echo "Task 1 status: $STATUS1 (expected: completed)"
echo "Task 2 status: $STATUS2 (expected: in-progress)"

if [ "$STATUS1" == "completed" ] && [ "$STATUS2" == "in-progress" ]; then
    echo "✅ VERIFIED: Both tasks match the required status values"
else
    echo "❌ Verification failed"
    exit 1
fi
```

---

### Updating an Item

```bash
# Update Task 2 status to completed
aws dynamodb update-item \
    --region us-east-1 \
    --table-name devops-tasks \
    --key '{"taskId": {"S": "2"}}' \
    --update-expression "SET #s = :newstatus" \
    --expression-attribute-names '{"#s": "status"}' \
    --expression-attribute-values '{":newstatus": {"S": "completed"}}' \
    --return-values ALL_NEW \
    --query "Attributes.{taskId:taskId.S,status:status.S}" \
    --output table
```

### Deleting an Item

```bash
aws dynamodb delete-item \
    --region us-east-1 \
    --table-name devops-tasks \
    --key '{"taskId": {"S": "1"}}'
```

---

## 💻 Commands Reference

```bash
REGION="us-east-1"

# --- CREATE TABLE ---
aws dynamodb create-table \
    --table-name devops-tasks \
    --attribute-definitions AttributeName=taskId,AttributeType=S \
    --key-schema AttributeName=taskId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region $REGION

aws dynamodb wait table-exists --table-name devops-tasks --region $REGION

# --- PUT ITEM ---
aws dynamodb put-item --table-name devops-tasks --region $REGION \
    --item '{"taskId":{"S":"1"},"description":{"S":"Learn DynamoDB"},"status":{"S":"completed"}}'

# --- GET ITEM ---
aws dynamodb get-item --table-name devops-tasks --region $REGION \
    --key '{"taskId": {"S": "1"}}' \
    --query "Item.{taskId:taskId.S,status:status.S}" --output table

# --- SCAN (all items) ---
aws dynamodb scan --table-name devops-tasks --region $REGION \
    --query "Items[*].{taskId:taskId.S,description:description.S,status:status.S}" \
    --output table

# --- UPDATE ITEM ---
aws dynamodb update-item --table-name devops-tasks --region $REGION \
    --key '{"taskId": {"S": "2"}}' \
    --update-expression "SET #s = :val" \
    --expression-attribute-names '{"#s": "status"}' \
    --expression-attribute-values '{":val": {"S": "completed"}}'

# --- DELETE ITEM ---
aws dynamodb delete-item --table-name devops-tasks --region $REGION \
    --key '{"taskId": {"S": "1"}}'

# --- DELETE TABLE ---
aws dynamodb delete-table --table-name devops-tasks --region $REGION
```

---

## ⚠️ Common Mistakes

**1. Setting `taskId` partition key type to Number instead of String**
The task specifies `taskId` as a **string** (`"1"`, `"2"` — quoted). Setting the attribute type to `N` (Number) during table creation means the key schema expects numeric values. Inserting `{"taskId": {"S": "1"}}` against a Number-typed key fails. In DynamoDB, `"1"` (String) and `1` (Number) are different types and cannot be mixed. Always match the key type in `create-table` to the type used in `put-item`.

**2. Using plain JSON instead of DynamoDB JSON format in the CLI**
The AWS CLI uses a typed JSON format where every value is wrapped in a type descriptor: `{"S": "completed"}` not just `"completed"`. Passing plain JSON like `{"taskId": "1"}` in CLI commands fails with a validation error. The DynamoDB console's JSON editor handles this automatically — the CLI does not.

**3. Scanning instead of using `get-item` for verification**
`scan` reads every item in the table — it's useful here when the table has only two items, but it's an expensive anti-pattern at scale (reads all data, consumes capacity proportional to table size). For looking up a single item by its exact key, `get-item` is the right operation — O(1), uses no capacity proportional to table size.

**4. Forgetting that DynamoDB items are schemaless — only the key needs to be defined**
`create-table` only requires defining the key attribute(s) in `--attribute-definitions`. Non-key attributes (`description`, `status`) are not declared anywhere — they just exist on the item itself. You don't need to pre-define them like SQL columns. This means different items in the same table can have completely different non-key attributes.

**5. Not waiting for table ACTIVE state before inserting items**
`create-table` returns immediately but the table isn't ready for reads/writes until its status is `ACTIVE`. Inserting immediately can result in a `ResourceNotFoundException`. The `aws dynamodb wait table-exists` waiter handles this correctly.

---

## 🌍 Real-World Context

**Session stores:** DynamoDB is the standard AWS solution for storing user session data in serverless and container-based web applications. A session item has a `sessionId` (partition key) and TTL attribute — DynamoDB automatically deletes expired items with no cleanup job needed. At scale, thousands of Lambda functions writing sessions simultaneously is handled transparently.

**Event sourcing and streaming:** DynamoDB Streams captures every change (insert, update, delete) to a table as a stream of events, in order per partition key. Lambda functions triggered by DynamoDB Streams build read models, update Elasticsearch, send notifications, or replicate data to other systems — a fully managed event sourcing pattern with no Kafka or Kinesis required for many use cases.

**Game leaderboards:** A composite key (`gameId` partition + `score` sort key) with a Global Secondary Index lets you query top scores across the entire game globally in milliseconds. DynamoDB's `Query` with `ScanIndexForward=false` retrieves items in descending sort order — perfect for leaderboard pagination.

**Single-table design:** Advanced DynamoDB usage involves storing multiple entity types (users, orders, items) in a single table using composite keys and naming conventions. This reduces the number of tables, eliminates cross-table joins (which DynamoDB doesn't support anyway), and aligns the data model with actual access patterns rather than entity types. Rick Houlihan's work on single-table design is the canonical reference for this pattern.

---

## ❓ Interview Q&A — As a Real-World DevOps Engineer

**Q1. What is the difference between a partition key and a sort key in DynamoDB?**
> The partition key (also called the hash key) is the required primary identifier — DynamoDB uses it to distribute data across partitions using consistent hashing. Every item must have a unique partition key value in a simple primary key table. A sort key (range key) is optional and enables a composite primary key, where the combination of partition key + sort key uniquely identifies an item. Multiple items can share the same partition key as long as their sort keys differ. The sort key also enables range queries: `Query` operations can retrieve all items for a partition key where the sort key is between two values, starts with a prefix, greater than, etc. — something impossible with a simple partition-only key.

**Q2. When would you use DynamoDB over a relational database like RDS MySQL?**
> DynamoDB is the right choice when: you need predictable single-digit millisecond latency at any scale (millions of requests per second) with no tuning; your access patterns are known upfront and key-based (get by ID, query by user); you're building serverless or auto-scaling architectures where connection pooling would be a bottleneck; or you need truly serverless billing (pay per request, zero cost when idle). RDS MySQL is the right choice when: you need ad-hoc querying and complex joins across multiple entity types; you're migrating an existing relational workload; your team is more familiar with SQL; or your access patterns are exploratory and unpredictable. The key distinction is access pattern flexibility (SQL wins) vs performance and operational simplicity at massive scale (DynamoDB wins).

**Q3. What is a DynamoDB Global Secondary Index (GSI) and when do you need one?**
> A GSI is an additional index on a DynamoDB table that lets you query on non-primary-key attributes. In this task's `devops-tasks` table, you can efficiently look up items by `taskId` (the partition key) but not by `status` — finding all "in-progress" tasks requires a full table scan. Adding a GSI with `status` as the partition key (and optionally `taskId` as the sort key) creates an additional index maintained by DynamoDB, allowing `Query` operations that efficiently return all items with a given status. GSIs have their own read/write capacity (or share on-demand billing) and are eventually consistent. You need a GSI whenever your application needs to query on an attribute that isn't the table's primary key.

**Q4. What is DynamoDB on-demand (`PAY_PER_REQUEST`) vs provisioned capacity and when would you choose each?**
> On-demand mode automatically handles traffic at any level with no capacity planning — you pay per request (approximately $1.25 per million writes, $0.25 per million reads). It's ideal for: new tables where traffic patterns are unknown, bursty workloads, development environments, and any table where cost predictability matters less than simplicity. Provisioned mode requires setting read and write capacity units (RCUs/WCUs) upfront — you pay for reserved capacity whether you use it or not, but get a lower per-unit cost at sustained high volume. Provisioned mode with Auto Scaling bridges the gap — it adjusts capacity based on utilization, but with bounded min/max values. For most new workloads: start on-demand, switch to provisioned once traffic patterns are established and cost optimization matters.

**Q5. How does DynamoDB's `update-item` differ from `put-item`?**
> `put-item` replaces the entire item — if the item exists, all its attributes are overwritten with the new values; any attributes not included in the new item are deleted. `update-item` modifies specific attributes while leaving others unchanged — it uses an `--update-expression` syntax (`SET status = :val`) to declare exactly what changes to make. For the To-Do task scenario: if you use `put-item` to mark task 2 as completed but forget to include `description` in the item, the description is deleted. Using `update-item` with `SET status = :val` only touches the status, leaving description untouched. `update-item` is the safe, surgical choice for partial updates; `put-item` is simpler but requires sending the full item every time.

**Q6. What are DynamoDB Streams and how would you use them in a To-Do application?**
> DynamoDB Streams is a time-ordered log of every data modification (insert, update, delete) to a table. Each record contains the before and after state of the modified item. Streams are retained for 24 hours and can trigger Lambda functions. In a To-Do application, you could use streams to: send a notification when a task status changes to "completed" (Lambda reads the stream, detects `status` change, publishes to SNS/SES); sync completed tasks to an analytics store (Lambda writes to S3 or Redshift on every update); or maintain an audit log of all task changes. Streams deliver events in order per partition key — all changes to `taskId: "1"` arrive in sequence, but changes to `taskId: "1"` and `taskId: "2"` may arrive in any relative order.

**Q7. What is DynamoDB's TTL feature and how would you use it in a To-Do application?**
> Time To Live (TTL) is a DynamoDB feature that automatically deletes items when a specified epoch timestamp attribute passes. You designate one attribute as the TTL attribute (`aws dynamodb update-time-to-live --table-name ... --time-to-live-specification Enabled=true,AttributeName=expiresAt`), and DynamoDB periodically checks items and deletes those whose TTL attribute has expired — typically within 48 hours of expiry. In a To-Do application: set `expiresAt` to 30 days after completion date when marking a task as "completed", and DynamoDB automatically removes old completed tasks without a cleanup job. In session stores, TTL is the standard approach — each session item has `expiresAt = now + 24h`, and expired sessions vanish automatically with no Lambda or cron needed.

---

---

## 📍 Proof of Work

This learning is documented and shared on LinkedIn:
- [View on LinkedIn](https://www.linkedin.com/posts/venkatesh-gangavarapu_100daysofcloud-aws-dynamodb-share-7482470742106783744-TyVZ/)

## 📚 Resources

- [AWS Docs — Amazon DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html)
- [DynamoDB Core Components](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.CoreComponents.html)
- [DynamoDB CLI Reference — put-item](https://docs.aws.amazon.com/cli/latest/reference/dynamodb/put-item.html)
- [Best Practices for DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/best-practices.html)
- [Single-Table Design (Advanced)](https://www.alexdebrie.com/posts/dynamodb-single-table/)

---

*Part of my [#100DaysOfCloud](https://github.com/venkatesh-gangavarapu/100-days-cloud-challenge-AWS) public challenge.*
