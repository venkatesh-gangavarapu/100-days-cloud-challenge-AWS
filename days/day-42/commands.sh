#!/bin/bash
# ============================================================
# 100 Days of Cloud — AWS Challenge
# Day 42: DynamoDB Table Creation, Item Insertion, and Verification
# Table: devops-tasks | Region: us-east-1
# ============================================================

set -e
REGION="us-east-1"
TABLE="devops-tasks"

# ============================================================
# STEP 1: CREATE DYNAMODB TABLE
# Partition key: taskId (String)
# billing-mode PAY_PER_REQUEST = on-demand (no capacity planning needed)
# ============================================================

echo "=== Step 1: Creating DynamoDB table '$TABLE' ==="

aws dynamodb create-table \
    --region $REGION \
    --table-name $TABLE \
    --attribute-definitions \
        AttributeName=taskId,AttributeType=S \
    --key-schema \
        AttributeName=taskId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Name,Value=$TABLE Key=Project,Value=ToDo

echo "Table creation initiated"

# Wait for table to be ACTIVE before inserting items
echo "Waiting for table to become ACTIVE..."
aws dynamodb wait table-exists \
    --table-name $TABLE \
    --region $REGION

echo "Table is ACTIVE"

# Display table details
aws dynamodb describe-table \
    --table-name $TABLE \
    --region $REGION \
    --query "Table.{Name:TableName,Status:TableStatus,BillingMode:BillingModeSummary.BillingMode,Keys:KeySchema}" \
    --output table

# ============================================================
# STEP 2: INSERT TASK 1
# taskId: "1", description: "Learn DynamoDB", status: "completed"
#
# DynamoDB JSON format: every attribute value is wrapped in a type descriptor
# {"S": "value"} = String, {"N": "42"} = Number, {"BOOL": true} = Boolean
# ============================================================

echo ""
echo "=== Step 2: Inserting Task 1 ==="

aws dynamodb put-item \
    --region $REGION \
    --table-name $TABLE \
    --item '{
        "taskId":      {"S": "1"},
        "description": {"S": "Learn DynamoDB"},
        "status":      {"S": "completed"}
    }'

echo "Task 1 inserted: taskId=1, status=completed"

# ============================================================
# STEP 3: INSERT TASK 2
# taskId: "2", description: "Build To-Do App", status: "in-progress"
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
# STEP 4: VERIFY USING get-item (O(1) key lookup, not a scan)
# ============================================================

echo ""
echo "=== Step 4: Verification ==="

echo "--- Task 1 (get-item by taskId=1) ---"
aws dynamodb get-item \
    --region $REGION \
    --table-name $TABLE \
    --key '{"taskId": {"S": "1"}}' \
    --query "Item.{taskId:taskId.S,description:description.S,status:status.S}" \
    --output table

echo "--- Task 2 (get-item by taskId=2) ---"
aws dynamodb get-item \
    --region $REGION \
    --table-name $TABLE \
    --key '{"taskId": {"S": "2"}}' \
    --query "Item.{taskId:taskId.S,description:description.S,status:status.S}" \
    --output table

echo ""
echo "--- Full scan (all items in table) ---"
aws dynamodb scan \
    --region $REGION \
    --table-name $TABLE \
    --query "Items[*].{taskId:taskId.S,description:description.S,status:status.S}" \
    --output table

# ============================================================
# STEP 5: PROGRAMMATIC STATUS VALIDATION
# ============================================================

echo ""
echo "=== Step 5: Programmatic validation ==="

STATUS1=$(aws dynamodb get-item \
    --region $REGION \
    --table-name $TABLE \
    --key '{"taskId": {"S": "1"}}' \
    --query "Item.status.S" \
    --output text)

STATUS2=$(aws dynamodb get-item \
    --region $REGION \
    --table-name $TABLE \
    --key '{"taskId": {"S": "2"}}' \
    --query "Item.status.S" \
    --output text)

echo "Task 1 status: '$STATUS1' (expected: 'completed')"
echo "Task 2 status: '$STATUS2' (expected: 'in-progress')"

if [ "$STATUS1" == "completed" ] && [ "$STATUS2" == "in-progress" ]; then
    echo ""
    echo "✅ VERIFIED: Both tasks have the correct status values"
else
    echo ""
    echo "❌ Verification FAILED:"
    [ "$STATUS1" != "completed" ] && echo "  Task 1: got '$STATUS1', expected 'completed'"
    [ "$STATUS2" != "in-progress" ] && echo "  Task 2: got '$STATUS2', expected 'in-progress'"
    exit 1
fi

echo ""
echo "============================================"
echo "  Table:   $TABLE"
echo "  Region:  $REGION"
echo "  Items:   2"
echo "  Task 1:  taskId=1 | status=completed ✅"
echo "  Task 2:  taskId=2 | status=in-progress ✅"
echo "============================================"

# ============================================================
# ADDITIONAL OPERATIONS (reference)
# ============================================================

# Update a task status:
# aws dynamodb update-item --table-name $TABLE --region $REGION \
#     --key '{"taskId": {"S": "2"}}' \
#     --update-expression "SET #s = :val" \
#     --expression-attribute-names '{"#s": "status"}' \
#     --expression-attribute-values '{":val": {"S": "completed"}}' \
#     --return-values ALL_NEW

# Delete a task:
# aws dynamodb delete-item --table-name $TABLE --region $REGION \
#     --key '{"taskId": {"S": "1"}}'

# Query (if GSI by status existed):
# aws dynamodb query --table-name $TABLE --region $REGION \
#     --index-name status-index \
#     --key-condition-expression "#s = :val" \
#     --expression-attribute-names '{"#s": "status"}' \
#     --expression-attribute-values '{":val": {"S": "completed"}}'

# ============================================================
# CLEANUP
# ============================================================

# aws dynamodb delete-table --table-name $TABLE --region $REGION
# echo "Table deleted"
