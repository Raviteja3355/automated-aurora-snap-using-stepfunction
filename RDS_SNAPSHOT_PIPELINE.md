# RDS Snapshot Export Pipeline — Complete Process Document

## Overview

This document describes the end-to-end RDS snapshot export pipeline built on AWS using
Terragrunt/Terraform. The pipeline automatically discovers RDS snapshots, exports them to
S3 in Parquet format, validates exported content, sends notifications to Google Chat and Microsoft
Teams, and optionally deletes the source snapshot after a configurable grace period.
Failed exports are automatically retried up to 5 times before a final failure notification
is sent.

---

## Architecture

```
EventBridge (daily)
        │
        ▼
Discovery Lambda
  • Lists manual RDS + Aurora snapshots older than retention_days
  • Respects max_export_concurrency cap
  • Shuffles eligible list for fairness
  • Invokes Export Lambda asynchronously (one per snapshot)
        │
        ▼ (async, fire-and-forget)
Export Lambda
  • Checks for existing active/complete export (idempotency)
  • Calls rds:StartExportTask → exports snapshot to S3 as Parquet
  • Failed async invocations → SQS Dead-Letter Queue → CloudWatch Alarm
        │
        ▼
EventBridge (every 15 minutes)
        │
        ▼
Status Lambda
  • Scans export tasks for this pipeline's S3 bucket
  • COMPLETE  → content validation → success notification → schedule/execute deletion
  • FAILED / CANCELED / INTEGRITY_FAILED → retry (up to 5x) → failure notification
  • Uses DynamoDB to prevent duplicate notifications across 15-min runs
        │
        ├──▶ Google Chat (4 dedicated spaces)
        └──▶ Microsoft Teams (4 dedicated channels)
```

---

## AWS Resources Created

| Resource | Name (dev) | Purpose |
|---|---|---|
| S3 Bucket | `snapshot-export-deeparchive-dev` | Stores exported Parquet files |
| KMS Key | `60b3af54-...` | Encrypts S3 objects and export tasks |
| IAM Role | `dev-rds-export-role` | Assumed by RDS export service |
| IAM Role | `dev-snapshot-discovery-role` | Discovery Lambda execution role |
| IAM Role | `dev-snapshot-export-role` | Export Lambda execution role |
| IAM Role | `dev-export-status-role` | Status Lambda execution role |
| Lambda | `dev-snapshot-discovery` | Discovers eligible snapshots daily |
| Lambda | `dev-snapshot-export` | Starts RDS export tasks |
| Lambda | `dev-export-status` | Monitors tasks and sends notifications |
| DynamoDB | `dev-snapshot-export-processed-tasks` | Deduplication state tracking |
| SQS | `dev-snapshot-export-dlq` | Dead-letter queue for failed async invocations |
| SNS | `dev-snapshot-export-topic` | Target for CloudWatch alarms |
| EventBridge | `dev-snapshot-discovery-schedule` | Triggers discovery daily |
| EventBridge | `dev-export-status-schedule` | Triggers status check every 15 min |
| CloudWatch Alarms | (4 alarms) | Lambda errors, throttles, DLQ messages |

---

## Repository Structure

```
terragrunt/
├── poc/
│   ├── terragrunt.hcl              # Root config: S3 remote state + DynamoDB lock
│   ├── dev/
│   │   ├── terragrunt.hcl          # Dev environment inputs
│   │   └── lambdas/
│   │       ├── discovery_lambda.py
│   │       ├── export_lambda.py
│   │       └── status_lambda.py
│   ├── test/
│   │   └── terragrunt.hcl
│   └── prod/
│       └── terragrunt.hcl
├── modules/
│   └── rds_snapshot_infra/
│       ├── main.tf                 # Root module — wires all submodules
│       ├── variables.tf
│       ├── outputs.tf
│       ├── s3_bucket/
│       ├── iam_rds_export_role/
│       ├── iam_lambda_role/
│       ├── lambda_function/
│       ├── sns_notifications/
│       └── eventbridge_rule/
└── CHANGES.md
```

---

## Environment Configuration (`poc/dev/terragrunt.hcl`)

### Key Parameters

| Parameter | Dev Value | Production Recommendation |
|---|---|---|
| `retention_days` | `0` | `730` |
| `deep_archive_days` | `30` | `30` |
| `dry_run_mode` | `false` | `false` |
| `delete_source_after_export` | `true` | `true` |
| `delete_delay_days` | `1` | `7–30` |
| `max_export_concurrency` | `8` | `5` (AWS default limit) |
| `max_retries` | `5` | `5` |
| `export_task_lookback_days` | `90` | `90` |

### IAM Policies Required

**Export Lambda (`dev-snapshot-export-role`):**
- `rds:StartExportTask`, `rds:DescribeExportTasks`
- `iam:PassRole` on `dev-rds-export-role`
- `kms:DescribeKey`, `kms:Decrypt`, `kms:GenerateDataKey*` on export KMS key

**Status Lambda (`dev-export-status-role`):**
- `rds:DescribeExportTasks`
- `rds:DeleteDBSnapshot`, `rds:DeleteDBClusterSnapshot`
- `backup:DeleteRecoveryPoint`
- `s3:ListBucket`, `s3:GetObject` on archive bucket
- `kms:Decrypt`, `kms:DescribeKey`, `kms:GenerateDataKey*` on export KMS key

**RDS Export Role (`dev-rds-export-role`):**
- `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject`, `s3:GetBucketLocation`
- `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey*`, `kms:DescribeKey`, `kms:CreateGrant` on `*`
- Trust policy: `rds.amazonaws.com` AND `export.rds.amazonaws.com`

---

## Lambda Functions

### 1. Discovery Lambda (`discovery_lambda.py`)

**Trigger:** EventBridge — `rate(1 day)`

**What it does:**
1. Calculates cutoff date: `now - retention_days`
2. Lists all manual RDS instance snapshots (`describe_db_snapshots`)
3. Lists all manual Aurora cluster snapshots (`describe_db_cluster_snapshots`)
4. Filters by `TARGET_CLUSTER_IDENTIFIERS` and `SNAPSHOT_NAME_PATTERN` if set
5. Counts in-progress exports for this bucket to enforce `MAX_EXPORT_CONCURRENCY`
6. Shuffles eligible list (prevents same snapshots always consuming the budget)
7. Invokes Export Lambda asynchronously for each snapshot in the batch

**Response example:**
```json
{
  "eligible_count": 8,
  "in_progress_count": 0,
  "available_slots": 5,
  "invoked_count": 5,
  "invoked_snapshots": ["snap-1", "snap-2", "snap-3", "snap-4", "snap-5"],
  "errors": []
}
```

---

### 2. Export Lambda (`export_lambda.py`)

**Trigger:** Invoked asynchronously by Discovery Lambda

**What it does:**
1. Checks if an active/complete export already exists for this snapshot ARN
2. Generates unique export task ID: `exp-{sanitized_snapshot_id}-{YYYYMMDDHHmmss}`
3. Calls `rds:StartExportTask` with the S3 bucket, prefix, IAM role, and KMS key
4. Handles race condition: catches `ExportTaskAlreadyExistsFault` gracefully

**Input payload:**
```json
{
  "snapshot_identifier": "my-snapshot",
  "snapshot_arn": "arn:aws:rds:ap-south-1:123456789:snapshot:my-snapshot"
}
```

**S3 export path:** `s3://{bucket}/snapshots/{snapshot_id}/`

---

### 3. Status Lambda (`status_lambda.py`)

**Trigger:** EventBridge — `rate(15 minutes)`

**What it does:**
1. Lists all export tasks for this pipeline's S3 bucket within the lookback window
2. For each `COMPLETE` task:
   - Runs content validation (see below)
   - Sends success notification (once, via DynamoDB deduplication)
   - Evaluates deletion: pending / deleted / skipped
3. For `FAILED` / `CANCELED` / `INTEGRITY_FAILED`:
   - Checks retry counter in DynamoDB
   - If retries remaining → triggers retry, sends retry notification to failure channel
   - If max retries exhausted → sends final failure notification, marks terminal

**Content Validation (`check_integrity_for_export`):**

The pipeline validates exported content by inspecting the S3 objects written by RDS.
The following checks are performed — note that **no checksum validation is implemented**;
all checks are structural and content-based:

| Check | Type | Pass / Fail |
|---|---|---|
| At least one object exists under `snapshots/{snapshot_id}/` | Presence | Fail if missing |
| `export_info_*.json` file exists | Presence | Fail if missing |
| `export_tables_info_*.json` file exists | Presence | Fail if missing |
| `export_info` JSON is readable and contains `SourceArn` field | Content | Fail if missing |
| `export_tables_info` JSON is a valid `dict` or `list` | Structure | Fail if invalid |
| Table count extracted from `export_tables_info` | Informational | Never fails |
| Parquet file count and total size under the prefix | Informational | Never fails |

If any **Fail** check fails, the task is marked `INTEGRITY_FAILED` and the retry flow begins.

**DynamoDB Key Scheme:**

| Key | Meaning |
|---|---|
| `export:{export_id}` | Task fully resolved — skip on all future runs |
| `notif:{export_id}` | Success/failure notification already sent |
| `pending:{export_id}` | Pending-deletion notification already sent |
| `retry:{snapshot_arn}` | Retry attempt counter (atomic increment) |

---

## Notification Channels

### Google Chat — 4 Dedicated Spaces

| Space | Fires when |
|---|---|
| Success | Export COMPLETE + content validation passed |
| Failure | Export FAILED, CANCELED, INTEGRITY_FAILED (after all retries exhausted) + each retry attempt |
| Pending Deletion | Snapshot export done, deletion scheduled (sent once per task) |
| Deleted | Source snapshot physically deleted after grace period |

### Microsoft Teams — 4 Dedicated Channels

Same 4 channels as Google Chat. Uses `MessageCard` format with color-coded theme:

| Channel | Color |
|---|---|
| Success | Green (`00C853`) |
| Failure / Retry | Red (`D50000`) / Orange (`FF6D00`) |
| Pending Deletion | Orange (`FF6D00`) |
| Deleted | Grey (`9E9E9E`) |

### Notification Content

**Success notification includes:**
- Snapshot ID, Source Type, Source ARN
- Task ID, Tables scope, KMS key
- Started, Finished, Duration, Progress %
- Tables exported, Parquet file count, Data size
- S3 Bucket and Prefix
- Validation status and metadata file paths
- Upcoming deletion in X days

**Retry notification includes:**
- Failed task details (ID, started, ended)
- Failure status and error detail
- Current attempt number (e.g. `2 of 5`)
- Remaining attempts
- Confirmation that new export has been triggered

**Final failure notification includes:**
- All failure details
- Retry summary: attempts tried, total allowed, `0 remaining (exhausted)`
- Action required note

**Pending deletion includes:**
- Snapshot details
- Days remaining, exact scheduled deletion date, grace period setting

**Deleted includes:**
- Snapshot details
- Deletion timestamp, grace period elapsed confirmation

---

## Retry Logic

```
On FAILED / CANCELED / INTEGRITY_FAILED:
  retry_count = DynamoDB get retry:{snapshot_arn}
  if retry_count < MAX_RETRIES (5):
      attempt = atomic increment retry:{snapshot_arn}
      invoke export_lambda async (new export task created)
      send retry notification to failure channel
      mark old task terminal in DynamoDB
  else:
      send final failure notification (with full retry summary)
      mark terminal in DynamoDB (no further processing)
```

- Retry counter stored in DynamoDB with 90-day TTL
- New export task gets a new unique ID with current timestamp
- The status lambda picks up the new task on the next 15-minute run
- Success on any retry → normal success notification, retry counter left to expire

---

## Terraform / Terragrunt — How to Deploy

### First-time setup

**1. Create remote state resources (one-time):**
```bash
aws s3api create-bucket --bucket tfstate-rds-snapshot-320042238069 \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1

aws s3api put-bucket-versioning \
  --bucket tfstate-rds-snapshot-320042238069 \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name tfstate-rds-snapshot-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-south-1
```

**2. Deploy dev environment:**
```bash
cd poc/dev
terragrunt init
terragrunt apply
```

> **Note:** Terraform automatically builds Lambda ZIPs from the `.py` source files using the
> `archive_file` data source. No manual zipping is required. Any change to a `.py` file is
> automatically detected on the next `terragrunt apply`.

### Updating Lambda code

Just edit the `.py` file and run:
```bash
cd poc/dev && terragrunt apply
```

Terraform detects the source file hash change and redeploys the Lambda automatically.

---

## Manual Operations

### Trigger discovery manually
```bash
aws lambda invoke \
  --function-name dev-snapshot-discovery \
  --region ap-south-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{}' response.json && cat response.json
```

### Trigger status check manually
```bash
aws lambda invoke \
  --function-name dev-export-status \
  --region ap-south-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{}' response.json && cat response.json
```

### Trigger export for a specific snapshot
```bash
aws lambda invoke \
  --function-name dev-snapshot-export \
  --region ap-south-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"snapshot_identifier": "my-snap", "snapshot_arn": "arn:aws:rds:..."}' \
  response.json && cat response.json
```

### Monitor export task progress
```bash
aws rds describe-export-tasks \
  --region ap-south-1 \
  --query "ExportTasks[*].{ID:ExportTaskIdentifier,Status:Status,Progress:PercentProgress}" \
  --output table
```

### View DynamoDB state
```bash
aws dynamodb scan \
  --table-name dev-snapshot-export-processed-tasks \
  --region ap-south-1 \
  --query "Items[*].task_id.S" \
  --output table
```

### Delete a DynamoDB entry to re-trigger notification
```bash
aws dynamodb delete-item \
  --table-name dev-snapshot-export-processed-tasks \
  --region ap-south-1 \
  --key '{"task_id": {"S": "notif:exp-my-snapshot-20260401120000"}}'
```

### Check S3 export contents
```bash
aws s3 ls s3://snapshot-export-deeparchive-dev/snapshots/ \
  --recursive --region ap-south-1
```

---

## KMS Key Policy Requirements

The KMS key (`60b3af54-...`) must allow the following principals:

| Principal | Actions | Purpose |
|---|---|---|
| Root account | `kms:*` | Break-glass admin access |
| `dev-rds-export-role` | Encrypt, Decrypt, GenerateDataKey*, DescribeKey, CreateGrant | RDS writes export to S3 |
| `dev-snapshot-export-role` | Encrypt, Decrypt, GenerateDataKey*, DescribeKey, CreateGrant | Lambda calls StartExportTask |
| `dev-export-status-role` | Decrypt, DescribeKey, GenerateDataKey* | Lambda reads KMS-encrypted S3 export files |
| `rds.amazonaws.com` | Encrypt, Decrypt, GenerateDataKey*, DescribeKey, CreateGrant | RDS service (ViaService condition) |
| `export.rds.amazonaws.com` | Encrypt, Decrypt, GenerateDataKey*, DescribeKey, CreateGrant | Export service (ViaService condition) |

> **Important:** The RDS export role trust policy must include **both**
> `rds.amazonaws.com` and `export.rds.amazonaws.com`. Missing the latter causes
> `KMSKeyNotAccessibleFault` on every export.

---

## S3 Export Structure

After a successful export, objects are stored as:

```
s3://snapshot-export-deeparchive-dev/
└── snapshots/
    └── {snapshot_id}/
        ├── export_info_{uuid}.json          ← Export metadata
        ├── export_tables_info_{uuid}.json   ← Table-level statistics
        └── {schema}.{tablename}/
            ├── 1.parquet
            └── 2.parquet (if large table)
```

### Verify export with Python
```python
import pandas as pd
df = pd.read_parquet("1.parquet")
print(df)
```

### Query with AWS Athena
```sql
CREATE EXTERNAL TABLE customers_export (
    id         INT,
    name       STRING,
    email      STRING,
    created_at TIMESTAMP
)
STORED AS PARQUET
LOCATION 's3://snapshot-export-deeparchive-dev/snapshots/{snapshot_id}/{dbname}/public.customers/'
TBLPROPERTIES ("parquet.compress"="SNAPPY");

SELECT * FROM customers_export LIMIT 10;
```

---

## S3 Lifecycle — Deep Archive

Objects transition to S3 Glacier Deep Archive after `deep_archive_days` (default: 30).
Deep Archive has an 12-hour retrieval time. To restore an object:

```bash
aws s3api restore-object \
  --bucket snapshot-export-deeparchive-dev \
  --key "snapshots/{snapshot_id}/{schema}.{table}/1.parquet" \
  --restore-request '{"Days": 7, "GlacierJobParameters": {"Tier": "Standard"}}'
```

---

## Troubleshooting

### No notifications received
1. Check DynamoDB — task may already have a `notif:` entry from a previous run:
   ```bash
   aws dynamodb scan --table-name dev-snapshot-export-processed-tasks \
     --region ap-south-1 --query "Items[*].task_id.S" --output table
   ```
2. Delete the relevant `notif:` entries and re-invoke the status lambda.

### Export task stuck in STARTING/IN_PROGRESS
- Check CloudWatch logs for the export lambda
- Verify `dev-rds-export-role` has correct KMS and S3 permissions
- Verify KMS key policy allows `export.rds.amazonaws.com`

### KMSKeyNotAccessibleFault
- Export role trust policy must include both `rds.amazonaws.com` and `export.rds.amazonaws.com`
- KMS key policy must explicitly allow the export role and service principals
- IAM policy on the calling Lambda must include `kms:DescribeKey`, `kms:Decrypt`, `kms:GenerateDataKey*`

### INTEGRITY_FAILED
- Export completed in RDS but metadata files missing from S3
- Usually caused by KMS permission issue during the export write phase
- Pipeline will auto-retry up to 5 times
- Check CloudWatch logs for `FailureCause` on the RDS export task

### terragrunt apply shows 0 changes after code edit
- Terraform uses `archive_file` data source to hash the `.py` source file directly
- If hash is not detected, force redeploy:
  ```bash
  terragrunt apply -replace="module.status_lambda.aws_lambda_function.lambda"
  ```

### archive provider missing on first init after module update
```bash
terragrunt init -upgrade && terragrunt apply
```

---

## Environment Differences

| Setting | Dev | Test | Prod |
|---|---|---|---|
| `retention_days` | `0` | `1` | `730` |
| `dry_run_mode` | `false` | `true` | `false` |
| `delete_delay_days` | `1` | `7` | `30` |
| `max_export_concurrency` | `8` | `3` | `5` |
| KMS Key | shared dev key | dedicated test key | dedicated prod key |

---

## Production Checklist

Before deploying to production:

- [ ] Set `retention_days = 730`
- [ ] Set `delete_delay_days = 30`
- [ ] Set `dry_run_mode = false`
- [ ] Replace KMS key ARN with production-dedicated key
- [ ] Update all IAM resource ARNs to prod account
- [ ] Replace all `dev-` resource name prefixes with `prod-`
- [ ] Confirm AWS account export task concurrency limit (default 5)
- [ ] Verify KMS key policy includes all required principals
- [ ] Test with a single snapshot before enabling daily schedule
- [ ] Set up Teams/Google Chat webhook URLs for prod channels
