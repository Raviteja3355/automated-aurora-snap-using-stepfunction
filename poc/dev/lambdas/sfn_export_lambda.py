"""
SFN Export Lambda — starts an RDS/Aurora export task.
Receives the full snapshot item from Step Functions and returns it
enriched with export_task_id and s3_prefix for downstream states.

Idempotency behaviour:
  STARTING / IN_PROGRESS  → reuse the running task unconditionally (avoid duplicate)
  COMPLETE                → check S3 for existing data:
                              - data present in standard storage  → reuse (proceed to integrity check)
                              - data present in Deep Archive/Glacier → skip integrity, send DEEP_ARCHIVE_SKIPPED
                              - data absent   → start a fresh export (e.g. bucket was
                                               destroyed and recreated after terragrunt destroy)
  FAILED / CANCELED       → always start a fresh export
"""
import os
import re
import boto3
from botocore.exceptions import ClientError
from datetime import datetime, timezone

rds = boto3.client("rds")
s3  = boto3.client("s3")

DRY_RUN_MODE = os.environ.get("DRY_RUN_MODE", "false").lower() == "true"

# Only actively running tasks are reused unconditionally.
# COMPLETE is handled separately with an S3 data-presence check.
_ACTIVE_STATUSES = {"STARTING", "IN_PROGRESS"}

# S3 storage classes that indicate data is archived and not directly accessible.
_ARCHIVED_STORAGE_CLASSES = {"GLACIER", "DEEP_ARCHIVE"}


def _make_export_task_id(snapshot_id):
    clean     = re.sub(r"[^A-Za-z0-9-]", "-", snapshot_id)
    clean     = re.sub(r"-{2,}", "-", clean).strip("-")
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    raw       = f"exp-{clean}-{timestamp}"
    return raw[:60].rstrip("-")


def _check_s3_content(bucket, prefix):
    """
    Check what is under the S3 prefix and return one of:
      "empty"        — no objects found
      "deep_archive" — objects exist but are in Glacier/Deep Archive (not accessible)
      "has_content"  — objects exist in an accessible storage class
    """
    try:
        resp = s3.list_objects_v2(
            Bucket=bucket,
            Prefix=prefix.rstrip("/") + "/",
            MaxKeys=1,
        )
        if resp.get("KeyCount", 0) == 0:
            return "empty"
        obj = resp["Contents"][0]
        storage_class = obj.get("StorageClass", "STANDARD")
        if storage_class in _ARCHIVED_STORAGE_CLASSES:
            return "deep_archive"
        return "has_content"
    except ClientError as e:
        print(f"S3 check failed for s3://{bucket}/{prefix}: {e}")
        return "empty"


def _find_active_export(snapshot_arn, archive_bucket):
    """
    Scan RDS export task history for this snapshot ARN and decide what to do.

    Returns (task_id, s3_prefix, reason) or (None, None, None).

    Decision logic:
      1. If any task is STARTING or IN_PROGRESS → reuse it immediately (export is running).
      2. If the most recent COMPLETE task still has its S3 data:
           - accessible storage → reuse (proceed to integrity check)
           - deep archive       → reuse with deep_archive flag (skip integrity)
      3. If the most recent COMPLETE task has no S3 data → return None (start a fresh export).
      4. If no relevant task exists → return None (start a fresh export).
    """
    marker         = None
    completed_task = None   # most recent COMPLETE task found

    while True:
        kwargs = {"SourceArn": snapshot_arn}
        if marker:
            kwargs["Marker"] = marker
        resp = rds.describe_export_tasks(**kwargs)

        for task in resp.get("ExportTasks", []):
            status    = task["Status"]
            task_id   = task["ExportTaskIdentifier"]
            s3_prefix = task.get("S3Prefix", "")

            if status in _ACTIVE_STATUSES:
                # Export is actively running — reuse so we don't start a duplicate.
                print(f"Reusing in-progress export task {task_id} (status={status})")
                return task_id, s3_prefix, f"reused_{status.lower()}"

            if status == "COMPLETE" and completed_task is None:
                # Record the first (most recent) completed task for S3 verification below.
                completed_task = (task_id, s3_prefix)

        marker = resp.get("Marker")
        if not marker:
            break

    # No active task found — check whether a completed task still has its S3 data.
    if completed_task:
        task_id, s3_prefix = completed_task
        content_status = _check_s3_content(archive_bucket, s3_prefix)

        if content_status == "has_content":
            print(
                f"Reusing completed export task {task_id} — "
                f"S3 data verified at s3://{archive_bucket}/{s3_prefix}"
            )
            return task_id, s3_prefix, "reused_complete_s3_verified"

        elif content_status == "deep_archive":
            print(
                f"Reusing completed export task {task_id} — "
                f"S3 data is in Glacier/Deep Archive at s3://{archive_bucket}/{s3_prefix} "
                f"(integrity check will be skipped)"
            )
            return task_id, s3_prefix, "reused_complete_deep_archive"

        else:
            print(
                f"Completed export task {task_id} found but S3 is empty at "
                f"s3://{archive_bucket}/{s3_prefix} — starting a fresh export"
            )
            return None, None, None

    return None, None, None


def handler(event, context):
    snapshot_id    = event["snapshot_identifier"]
    snapshot_arn   = event["snapshot_arn"]
    archive_bucket = event["archive_bucket"]
    export_role    = event["export_role_arn"]
    kms_key        = event["kms_key_arn"]
    dry_run        = event.get("dry_run", DRY_RUN_MODE)

    # Idempotency: reuse in-progress task, or completed task if S3 data is present.
    existing_id, existing_prefix, reuse_reason = _find_active_export(snapshot_arn, archive_bucket)
    if existing_id:
        return {
            **event,
            "export_task_id":  existing_id,
            "s3_prefix":       existing_prefix,
            "reused_existing": True,
            "reuse_reason":    reuse_reason,
            "deep_archive":    reuse_reason == "reused_complete_deep_archive",
        }

    # No existing task to reuse — start a fresh export.
    export_task_id = _make_export_task_id(snapshot_id)
    safe_prefix    = re.sub(r"[^A-Za-z0-9\-_./]", "-", snapshot_id)
    s3_prefix      = f"snapshots/{safe_prefix}"

    if dry_run:
        print(f"[DRY RUN] Would start export '{export_task_id}' for {snapshot_id}")
        return {
            **event,
            "export_task_id":  export_task_id,
            "s3_prefix":       s3_prefix,
            "deep_archive":    False,
            "reused_existing": False,
            "reuse_reason":    "none",
        }

    try:
        rds.start_export_task(
            ExportTaskIdentifier=export_task_id,
            SourceArn=snapshot_arn,
            S3BucketName=archive_bucket,
            S3Prefix=s3_prefix,
            IamRoleArn=export_role,
            KmsKeyId=kms_key,
        )
        print(f"Started fresh export task {export_task_id} for {snapshot_id}")
    except ClientError as e:
        code = e.response["Error"]["Code"]

        if code == "ExportTaskAlreadyExistsFault":
            # Race condition between parallel Map branches — safe to ignore.
            print(f"Race condition: export task already exists for {snapshot_id}")

        elif code == "ExportTaskLimitReachedFault":
            # AWS account-level limit of 5 concurrent exports reached.
            # Re-raise so Step Functions native Retry (Lambda.AWSLambdaException,
            # 60s interval) retries automatically — do NOT consume an application retry.
            print(f"AWS concurrent export limit reached for {snapshot_id} — will retry: {e}")
            raise

        elif code in (
            "DBClusterSnapshotNotFoundFault",
            "DBSnapshotNotFound",
            "InvalidExportSourceStateFault",
        ):
            # Snapshot was deleted or is in a non-exportable state.
            # Raise so Step Functions routes to HandleExportFailed after retries.
            print(f"Snapshot {snapshot_id} is no longer available ({code}) — cannot export")
            raise

        else:
            raise

    return {
        **event,
        "export_task_id":  export_task_id,
        "s3_prefix":       s3_prefix,
        "deep_archive":    False,
        "reused_existing": False,
        "reuse_reason":    "none",
    }
