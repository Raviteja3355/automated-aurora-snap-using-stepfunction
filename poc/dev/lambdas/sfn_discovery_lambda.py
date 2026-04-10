"""
SFN Discovery Lambda — finds eligible Aurora cluster snapshots (both manual
and automated) and returns them as a list for the Step Functions Map state.
Embeds all pipeline config into each snapshot item so the Map iterator is
fully self-contained.

In-progress export handling:
  - Snapshots that already have a STARTING or IN_PROGRESS export task in this
    pipeline's S3 bucket are excluded from the dispatched batch entirely.
    The existing Step Functions execution managing those exports is left to
    complete on its own — we never dispatch the same snapshot twice.
  - The concurrency cap (MAX_EXPORT_CONCURRENCY) still accounts for those
    in-progress tasks so we never exceed the AWS export task limit.
"""
import json
import os
import re
import random
import urllib.request
import boto3
from datetime import datetime, timezone, timedelta

rds = boto3.client("rds")

RETENTION_DAYS             = int(os.environ.get("RETENTION_DAYS", "730"))
ARCHIVE_BUCKET             = os.environ["ARCHIVE_BUCKET"]
DRY_RUN_MODE               = os.environ.get("DRY_RUN_MODE", "false").lower() == "true"
MAX_EXPORT_CONCURRENCY     = int(os.environ.get("MAX_EXPORT_CONCURRENCY", "5"))
TARGET_CLUSTER_IDENTIFIERS = [
    c.strip() for c in os.environ.get("TARGET_CLUSTER_IDENTIFIERS", "").split(",") if c.strip()
]
SNAPSHOT_NAME_PATTERN = os.environ.get("SNAPSHOT_NAME_PATTERN", "")
GCHAT_WEBHOOK_URL     = os.environ.get("GCHAT_WEBHOOK_URL", "")

# Pipeline-level config embedded into every snapshot item for the Map state
EXPORT_ROLE_ARN            = os.environ["EXPORT_ROLE_ARN"]
KMS_KEY_ARN                = os.environ["KMS_KEY_ARN"]
DELETE_SOURCE_AFTER_EXPORT = os.environ.get("DELETE_SOURCE_AFTER_EXPORT", "false").lower() == "true"
DELETE_DELAY_DAYS          = int(os.environ.get("DELETE_DELAY_DAYS", "7"))
MAX_EXPORT_RETRIES         = int(os.environ.get("MAX_EXPORT_RETRIES", "2"))


def _notify_discovery(dispatching, in_progress_count, eligible_count, available_slots):
    """Send a Google Chat notification summarising this discovery run."""
    if not GCHAT_WEBHOOK_URL:
        print("GCHAT_WEBHOOK_URL not set — skipping discovery notification")
        return

    if dispatching:
        snap_lines = "\n".join(
            f"   • `{s['snapshot_identifier']}`" for s in dispatching
        )
    else:
        snap_lines = "   _(none — all slots occupied or no eligible snapshots)_"

    text = (
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        "🔍  *AURORA SNAPSHOT DISCOVERY RUN*\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        "📊  *SUMMARY*\n"
        f"   • *Eligible Snapshots:*    {eligible_count}\n"
        f"   • *In-Progress (skipped):* {in_progress_count}\n"
        f"   • *Available Slots:*       {available_slots}\n"
        f"   • *Dispatching:*           {len(dispatching)}\n\n"
        "📦  *SNAPSHOTS BEING EXPORTED*\n"
        f"{snap_lines}\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    )

    payload = json.dumps({"text": text}).encode("utf-8")
    req = urllib.request.Request(
        GCHAT_WEBHOOK_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10):
            pass
        print("Discovery notification sent to Google Chat")
    except Exception as e:
        print(f"Discovery notification failed: {e}")


def _get_in_progress_export_info():
    """
    Scan all RDS export tasks and return:
      - count       : number of tasks currently STARTING or IN_PROGRESS for this bucket
      - source_arns : set of snapshot ARNs whose exports are actively in progress

    The ARN set is used by the discovery loop to skip snapshots that are already
    being exported by a running Step Functions execution.
    """
    count       = 0
    source_arns = set()
    paginator   = rds.get_paginator("describe_export_tasks")
    for page in paginator.paginate():
        for task in page["ExportTasks"]:
            if task.get("S3Bucket") == ARCHIVE_BUCKET and task["Status"] in ("STARTING", "IN_PROGRESS"):
                count += 1
                src_arn = task.get("SourceArn", "")
                if src_arn:
                    source_arns.add(src_arn)
    return count, source_arns


def _list_snapshots(cutoff, skip_arns):
    """
    Return eligible Aurora cluster snapshots, excluding:
      - snapshots not in 'available' status
      - snapshots created more recently than cutoff (when cutoff is not None)
      - snapshots whose ARN is in skip_arns (already being exported)
      - snapshots not matching TARGET_CLUSTER_IDENTIFIERS or SNAPSHOT_NAME_PATTERN
    """
    eligible  = []
    seen_arns = set()

    # Aurora cluster snapshots — both manual and automated
    paginator = rds.get_paginator("describe_db_cluster_snapshots")
    for snapshot_type in ("manual", "automated"):
        for page in paginator.paginate(SnapshotType=snapshot_type):
            for snap in page["DBClusterSnapshots"]:
                if snap.get("Status") != "available":
                    continue

                snapshot_arn = snap["DBClusterSnapshotArn"]
                if snapshot_arn in seen_arns:
                    continue

                # Skip snapshots already being exported by a running execution.
                if snapshot_arn in skip_arns:
                    print(f"Skipping {snap['DBClusterSnapshotIdentifier']} — export already in progress")
                    continue

                creation_time = snap["SnapshotCreateTime"]
                if creation_time.tzinfo is None:
                    creation_time = creation_time.replace(tzinfo=timezone.utc)
                # cutoff=None when RETENTION_DAYS=0 — no age filter, all snapshots eligible.
                if cutoff is not None and creation_time > cutoff:
                    continue

                snapshot_id = snap["DBClusterSnapshotIdentifier"]
                if TARGET_CLUSTER_IDENTIFIERS and snap["DBClusterIdentifier"] not in TARGET_CLUSTER_IDENTIFIERS:
                    continue
                if SNAPSHOT_NAME_PATTERN and not re.search(SNAPSHOT_NAME_PATTERN, snapshot_id):
                    continue

                seen_arns.add(snapshot_arn)
                eligible.append({
                    "snapshot_identifier": snapshot_id,
                    "snapshot_arn":        snapshot_arn,
                    "snapshot_type":       "cluster",
                })

    return eligible


def handler(event, context):
    # RETENTION_DAYS=0 → no age filter, all available snapshots are eligible.
    # For production, set RETENTION_DAYS=730 to only export snapshots older than 2 years.
    cutoff = None if RETENTION_DAYS == 0 else datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)

    # Get in-progress export info before listing snapshots so we can skip them.
    in_progress_count, in_progress_arns = _get_in_progress_export_info()

    # List eligible snapshots, excluding ones already being exported.
    eligible = _list_snapshots(cutoff, skip_arns=in_progress_arns)
    random.shuffle(eligible)

    # Respect the concurrency cap — in-progress tasks consume slots even though
    # their snapshots are not in the eligible list.
    available_slots = max(0, MAX_EXPORT_CONCURRENCY - in_progress_count)
    batch           = eligible[:available_slots]

    # Embed pipeline-level config into each snapshot item for the Map iterator.
    delete_delay_seconds = DELETE_DELAY_DAYS * 86400
    snapshots = [
        {
            **snap,
            "archive_bucket":             ARCHIVE_BUCKET,
            "export_role_arn":            EXPORT_ROLE_ARN,
            "kms_key_arn":                KMS_KEY_ARN,
            "delete_source_after_export": DELETE_SOURCE_AFTER_EXPORT,
            "delete_delay_seconds":       delete_delay_seconds,
            "dry_run":                    DRY_RUN_MODE,
            "retry_count":                0,
            "max_export_retries":         MAX_EXPORT_RETRIES,
        }
        for snap in batch
    ]

    print(
        f"Eligible: {len(eligible)}, "
        f"In-progress (skipped): {in_progress_count}, "
        f"Available slots: {available_slots}, "
        f"Dispatching: {len(snapshots)}"
    )

    # Notify Google Chat with the discovery summary and snapshot list.
    _notify_discovery(snapshots, in_progress_count, len(eligible), available_slots)

    return {
        "eligible_count":    len(eligible),
        "in_progress_count": in_progress_count,
        "available_slots":   available_slots,
        "snapshots":         snapshots,
    }
