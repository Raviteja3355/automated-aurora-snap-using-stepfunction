"""
SFN Notify Lambda — sends Google Chat notification for all pipeline events.
Single webhook URL for all event types.

Event types handled:
  EXPORT_STARTED        — export task has been submitted to RDS
  EXPORT_RETRY          — export failed, retrying (shows attempt # and retries left)
  EXPORT_FAILED         — export exhausted all retries, partial files cleaned up
  INTEGRITY_PASSED      — S3 export validated successfully (tables, files, size)
  EXPORT_SUCCESS        — full pipeline success summary (integrity + deletion info)
  INTEGRITY_FAILED      — S3 export failed integrity validation
  DELETION_SCHEDULED    — snapshot queued for deletion (delay period active)
  DELETED               — source snapshot permanently deleted
  PIPELINE_FAILED       — discovery step failed, no snapshots processed
  DEEP_ARCHIVE_SKIPPED  — snapshot already exported and moved to Glacier Deep Archive;
                          integrity check skipped (data not accessible without restore)
"""
import json
import os
import urllib.request

GCHAT_WEBHOOK_URL = os.environ.get("GCHAT_WEBHOOK_URL", "")
ARCHIVE_BUCKET    = os.environ.get("ARCHIVE_BUCKET", "")
DELETE_DELAY_DAYS = int(os.environ.get("DELETE_DELAY_DAYS", "7"))


def _post(text):
    if not GCHAT_WEBHOOK_URL:
        print("GCHAT_WEBHOOK_URL not set — skipping notification")
        return
    payload = json.dumps({"text": text}).encode("utf-8")
    req = urllib.request.Request(
        GCHAT_WEBHOOK_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10):
            pass
        print("Notification sent to Google Chat")
    except Exception as e:
        print(f"Google Chat notification failed: {e}")


def handler(event, context):
    event_type     = event.get("event_type", "UNKNOWN")
    snapshot_id    = event.get("snapshot_identifier", "unknown")
    snapshot_arn   = event.get("snapshot_arn", "")
    snapshot_type  = event.get("snapshot_type", "unknown")
    export_task_id = event.get("export_task_id", "N/A")
    status         = event.get("status", "")
    failure_cause  = event.get("failure_cause", "")

    # Integrity fields
    integrity_status = event.get("integrity_status", "")
    table_count      = event.get("table_count", 0)
    object_count     = event.get("object_count", 0)
    size_str         = event.get("size_str", "N/A")
    s3_prefix        = event.get("s3_prefix", "")
    total_data_gb    = event.get("total_data_gb")

    # Timing
    task_start = event.get("task_start_time", "N/A")
    task_end   = event.get("task_end_time", "N/A")

    # Deletion fields
    deleted_at     = event.get("deleted_at", "N/A")
    days_remaining = event.get("days_remaining", DELETE_DELAY_DAYS)
    scheduled_date = event.get("scheduled_deletion_date", "N/A")

    # Retry fields
    retry_count        = event.get("retry_count", 0)
    max_export_retries = event.get("max_export_retries", 2)
    retries_remaining  = max(0, max_export_retries - retry_count)

    # Error (from Step Functions Catch ResultPath)
    error_info  = event.get("error", {})
    error_code  = error_info.get("Error", "") if isinstance(error_info, dict) else str(error_info)
    error_cause = error_info.get("Cause", "") if isinstance(error_info, dict) else ""

    bucket   = event.get("archive_bucket", ARCHIVE_BUCKET)
    data_str = f"{total_data_gb:.2f} GB" if total_data_gb is not None else size_str

    # ── EXPORT_STARTED ──────────────────────────────────────────────────────────
    if event_type == "EXPORT_STARTED":
        snap_label = "Aurora Cluster" if snapshot_type == "cluster" else "RDS Instance"
        text = (
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"🚀  *{snap_label} SNAPSHOT EXPORT — STARTED*\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
            "📦  *SNAPSHOT DETAILS*\n"
            f"   • *Snapshot ID:*    `{snapshot_id}`\n"
            f"   • *Type:*           {snap_label}\n"
            f"   • *ARN:*            `{snapshot_arn}`\n\n"
            "⚙️  *EXPORT TASK*\n"
            f"   • *Task ID:*        `{export_task_id}`\n\n"
            "🪣  *DESTINATION*\n"
            f"   • *Bucket:*         `{bucket}`\n"
            f"   • *Prefix:*         `{s3_prefix}`\n\n"
            "⏳  Export is now in progress. You will be notified on completion.\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        )

    # ── EXPORT_RETRY ────────────────────────────────────────────────────────────
    elif event_type == "EXPORT_RETRY":
        attempt_num = retry_count  # already incremented before this notification
        snap_label  = "Aurora Cluster" if snapshot_type == "cluster" else "RDS Instance"
        text = (
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"🔄  *{snap_label} SNAPSHOT EXPORT — RETRYING*\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
            "📦  *SNAPSHOT DETAILS*\n"
            f"   • *Snapshot ID:*    `{snapshot_id}`\n"
            f"   • *Type:*           {snap_label}\n\n"
            "⚙️  *EXPORT TASK*\n"
            f"   • *Previous Task:*  `{export_task_id}`\n"
            f"   • *Status:*         {status}\n"
        )
        if failure_cause:
            text += f"   • *AWS Cause:*      {failure_cause}\n"
        text += (
            "\n"
            "🔁  *RETRY STATUS*\n"
            f"   • *Attempt:*        {attempt_num} of {max_export_retries}\n"
            f"   • *Retries Left:*   {retries_remaining}\n\n"
            "⏳  A new export task will be started shortly.\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        )

    # ── INTEGRITY_PASSED ────────────────────────────────────────────────────────
    elif event_type == "INTEGRITY_PASSED":
        snap_label = "Aurora Cluster" if snapshot_type == "cluster" else "RDS Instance"
        text = (
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"🔍  *{snap_label} SNAPSHOT — INTEGRITY CHECK PASSED*\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
            "📦  *SNAPSHOT DETAILS*\n"
            f"   • *Snapshot ID:*    `{snapshot_id}`\n"
            f"   • *Type:*           {snap_label}\n\n"
            "⚙️  *EXPORT TASK*\n"
            f"   • *Task ID:*        `{export_task_id}`\n\n"
            "✅  *INTEGRITY RESULTS*\n"
            f"   • *Status:*         PASSED\n"
            f"   • *Tables:*         {table_count}\n"
            f"   • *Parquet Files:*  {object_count}\n"
            f"   • *Data Size:*      {data_str}\n\n"
            "🪣  *S3 LOCATION*\n"
            f"   • *Bucket:*         `{bucket}`\n"
            f"   • *Prefix:*         `{s3_prefix}`\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        )

    # ── EXPORT_SUCCESS ──────────────────────────────────────────────────────────
    elif event_type == "EXPORT_SUCCESS":
        snap_label = "Aurora Cluster" if snapshot_type == "cluster" else "RDS Instance"
        text = (
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"✅  *{snap_label} SNAPSHOT EXPORT — COMPLETE*\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
            "📦  *SNAPSHOT DETAILS*\n"
            f"   • *Snapshot ID:*    `{snapshot_id}`\n"
            f"   • *Type:*           {snap_label}\n"
            f"   • *ARN:*            `{snapshot_arn}`\n\n"
            "⚙️  *EXPORT TASK*\n"
            f"   • *Task ID:*        `{export_task_id}`\n\n"
            "⏱️  *TIMING*\n"
            f"   • *Started:*        {task_start}\n"
            f"   • *Finished:*       {task_end}\n\n"
            "📊  *EXPORT SUMMARY*\n"
            f"   • *Tables:*         {table_count}\n"
            f"   • *Parquet Files:*  {object_count}\n"
            f"   • *Data Size:*      {data_str}\n\n"
            "🪣  *S3 DESTINATION*\n"
            f"   • *Bucket:*         `{bucket}`\n"
            f"   • *Prefix:*         `{s3_prefix}`\n\n"
            "✔️  *INTEGRITY CHECK:* PASSED\n\n"
            f"🗑️  *DELETION:* Scheduled in *{DELETE_DELAY_DAYS} day(s)*\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        )

    # ── EXPORT_FAILED ───────────────────────────────────────────────────────────
    elif event_type == "EXPORT_FAILED":
        snap_label = "Aurora Cluster" if snapshot_type == "cluster" else "RDS Instance"
        text = (
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"❌  *{snap_label} SNAPSHOT EXPORT — FAILED (ALL RETRIES EXHAUSTED)*\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
            "📦  *SNAPSHOT DETAILS*\n"
            f"   • *Snapshot ID:*   `{snapshot_id}`\n"
            f"   • *Type:*          {snap_label}\n"
            f"   • *ARN:*           `{snapshot_arn}`\n\n"
            "⚙️  *EXPORT TASK*\n"
            f"   • *Task ID:*       `{export_task_id}`\n"
            f"   • *Status:*        {status}\n"
        )
        if failure_cause:
            text += f"   • *AWS Cause:*     {failure_cause}\n"
        if error_code:
            text += f"   • *Error Code:*    {error_code}\n"
        if error_cause:
            text += f"   • *Error Detail:*  {error_cause[:300]}\n"
        text += (
            "\n"
            "🔁  *RETRIES*\n"
            f"   • *Attempts Made:*  {retry_count} of {max_export_retries}\n"
            "   • *Retries Left:*  0 — no further attempts will be made\n\n"
            "🧹  Partial export files have been cleaned up from S3.\n\n"
            "💡  *ACTION REQUIRED:* Check CloudWatch Logs for the export Lambda.\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        )

    # ── INTEGRITY_FAILED ────────────────────────────────────────────────────────
    elif event_type == "INTEGRITY_FAILED":
        snap_label = "Aurora Cluster" if snapshot_type == "cluster" else "RDS Instance"
        text = (
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"⚠️  *{snap_label} SNAPSHOT EXPORT — INTEGRITY FAILED*\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
            "📦  *SNAPSHOT DETAILS*\n"
            f"   • *Snapshot ID:*   `{snapshot_id}`\n"
            f"   • *Type:*          {snap_label}\n\n"
            "⚙️  *EXPORT TASK*\n"
            f"   • *Task ID:*       `{export_task_id}`\n\n"
            "🚨  *INTEGRITY RESULT*\n"
            f"   • *Status:*        FAILED\n"
            f"   • *Reason:*        {integrity_status}\n"
            f"   • *S3 Prefix:*     `{s3_prefix}`\n\n"
            "💡  *ACTION REQUIRED:* Inspect the S3 export path manually.\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        )

    # ── DELETION_SCHEDULED ──────────────────────────────────────────────────────
    elif event_type == "DELETION_SCHEDULED":
        snap_label = "Aurora Cluster" if snapshot_type == "cluster" else "RDS Instance"
        text = (
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"⏰  *{snap_label} SNAPSHOT — DELETION SCHEDULED*\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
            "📦  *SNAPSHOT DETAILS*\n"
            f"   • *Snapshot ID:*    `{snapshot_id}`\n"
            f"   • *Type:*           {snap_label}\n"
            f"   • *ARN:*            `{snapshot_arn}`\n\n"
            "⚙️  *EXPORT TASK*\n"
            f"   • *Task ID:*        `{export_task_id}`\n\n"
            "🗓️  *DELETION SCHEDULE*\n"
            f"   • *Days Remaining:* {days_remaining} day(s)\n"
            f"   • *Eligible After:* {scheduled_date}\n\n"
            "ℹ️  The source snapshot will be automatically deleted after the retention delay.\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        )

    # ── DELETED ─────────────────────────────────────────────────────────────────
    elif event_type == "DELETED":
        snap_label = "Aurora Cluster" if snapshot_type == "cluster" else "RDS Instance"
        text = (
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"🗑️  *{snap_label} SNAPSHOT — DELETED*\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
            "📦  *SNAPSHOT DETAILS*\n"
            f"   • *Snapshot ID:*   `{snapshot_id}`\n"
            f"   • *Type:*          {snap_label}\n"
            f"   • *ARN:*           `{snapshot_arn}`\n\n"
            f"   • *Export Task:*   `{export_task_id}`\n"
            f"   • *Deleted At:*    {deleted_at}\n\n"
            "✔️  Source snapshot permanently deleted from RDS.\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        )

    # ── DEEP_ARCHIVE_SKIPPED ────────────────────────────────────────────────────
    elif event_type == "DEEP_ARCHIVE_SKIPPED":
        text = (
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            "🧊  *AURORA SNAPSHOT — DEEP ARCHIVE (INTEGRITY SKIPPED)*\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
            "📦  *SNAPSHOT DETAILS*\n"
            f"   • *Snapshot ID:*   `{snapshot_id}`\n"
            f"   • *Type:*          Aurora Cluster\n"
            f"   • *ARN:*           `{snapshot_arn}`\n\n"
            "⚙️  *EXPORT TASK*\n"
            f"   • *Task ID:*       `{export_task_id}`\n\n"
            "🪣  *S3 LOCATION*\n"
            f"   • *Bucket:*        `{bucket}`\n"
            f"   • *Prefix:*        `{s3_prefix}`\n\n"
            "ℹ️  The exported data has transitioned to *Glacier Deep Archive*.\n"
            "   Integrity check was skipped — data is not directly accessible without a restore.\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        )

    # ── PIPELINE_FAILED ─────────────────────────────────────────────────────────
    elif event_type == "PIPELINE_FAILED":
        text = (
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            "🔥  *SNAPSHOT PIPELINE — FAILED*\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
            "🚨  The discovery step failed — no snapshots were processed.\n\n"
        )
        if error_code:
            text += f"   • *Error Code:*    {error_code}\n"
        if error_cause:
            text += f"   • *Error Detail:*  {error_cause[:400]}\n"
        text += (
            "\n💡  Check CloudWatch Logs for the discovery Lambda.\n"
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        )

    else:
        text = (
            f"*Pipeline Event:* `{event_type}`\n"
            f"*Snapshot:* `{snapshot_id}`\n"
            f"*Export Task:* `{export_task_id}`\n"
        )

    _post(text)
    return event
