"""
SFN S3 Cleanup Lambda — deletes partial export files from S3 when an export
task fails (status FAILED or CANCELED).

RDS exports that fail mid-way can leave behind partial Parquet files, metadata
JSON files, and manifest files under snapshots/{snapshot_id}/. This Lambda
removes all of them so the prefix is clean for any future retry.

Called by Step Functions between HandleExportFailed and NotifyExportFailed.
Uses S3 delete_objects (batch up to 1000) to minimise API calls.
Dry-run mode logs the objects that would be deleted without removing them.
"""
import os
import boto3

s3 = boto3.client("s3")

ARCHIVE_BUCKET = os.environ.get("ARCHIVE_BUCKET", "")


def _list_keys(bucket, prefix):
    keys      = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            keys.append(obj["Key"])
    return keys


def _batch_delete(bucket, keys):
    """Delete up to 1000 objects per S3 API call. Returns count of deleted objects."""
    deleted = 0
    for i in range(0, len(keys), 1000):
        batch = keys[i:i + 1000]
        resp  = s3.delete_objects(
            Bucket=bucket,
            Delete={"Objects": [{"Key": k} for k in batch], "Quiet": True},
        )
        errors = resp.get("Errors", [])
        for err in errors:
            print(f"  Failed to delete {err['Key']}: {err['Code']} — {err['Message']}")
        deleted += len(batch) - len(errors)
    return deleted


def handler(event, context):
    snapshot_id    = event.get("snapshot_identifier", "unknown")
    archive_bucket = event.get("archive_bucket", ARCHIVE_BUCKET)
    dry_run        = event.get("dry_run", False)
    # Use the sanitized s3_prefix from export lambda to match Aurora snapshot IDs with special chars
    raw_prefix     = event.get("s3_prefix") or f"snapshots/{snapshot_id}"
    prefix         = raw_prefix.rstrip("/") + "/"

    print(f"S3 cleanup for failed export — scanning s3://{archive_bucket}/{prefix}")

    keys = _list_keys(archive_bucket, prefix)

    if not keys:
        print("  No partial files found — nothing to clean up")
        return {
            **event,
            "s3_cleanup": {
                "prefix":  prefix,
                "deleted": 0,
                "found":   0,
            },
        }

    print(f"  Found {len(keys)} object(s) to remove")

    if dry_run:
        for k in keys[:10]:          # Log first 10 to avoid noisy output
            print(f"  [DRY RUN] Would delete: {k}")
        if len(keys) > 10:
            print(f"  [DRY RUN] ... and {len(keys) - 10} more")
        return {
            **event,
            "s3_cleanup": {
                "prefix":       prefix,
                "deleted":      0,
                "found":        len(keys),
                "dry_run":      True,
                "would_delete": len(keys),
            },
        }

    deleted = _batch_delete(archive_bucket, keys)
    print(f"  Deleted {deleted}/{len(keys)} partial file(s) from s3://{archive_bucket}/{prefix}")

    return {
        **event,
        "s3_cleanup": {
            "prefix":  prefix,
            "deleted": deleted,
            "found":   len(keys),
        },
    }
