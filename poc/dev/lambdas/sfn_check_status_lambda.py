"""
SFN Check Status Lambda — polls a single RDS export task status.
Returns the full state enriched with status, timing, and progress fields.
The Step Functions IsExportComplete Choice state reads $.status to branch:
  COMPLETE   → IntegrityCheck
  FAILED     → HandleExportFailed
  CANCELED   → HandleExportFailed
  (default)  → WaitBeforeStatusCheck (loop)
"""
import boto3
from datetime import datetime, timezone

rds = boto3.client("rds")


def handler(event, context):
    export_task_id = event["export_task_id"]
    dry_run        = event.get("dry_run", False)

    if dry_run:
        print(f"[DRY RUN] Returning synthetic COMPLETE for {export_task_id}")
        return {
            **event,
            "status":           "COMPLETE",
            "percent_progress": 100,
            "failure_cause":    "",
            "task_start_time":  datetime.now(timezone.utc).isoformat(),
            "task_end_time":    datetime.now(timezone.utc).isoformat(),
            "total_data_gb":    0,
            "kms_key_id":       event.get("kms_key_arn", ""),
        }

    resp  = rds.describe_export_tasks(ExportTaskIdentifier=export_task_id)
    tasks = resp.get("ExportTasks", [])
    if not tasks:
        raise ValueError(f"Export task not found: {export_task_id}")

    task          = tasks[0]
    status        = task["Status"]
    percent       = task.get("PercentProgress", 0)
    failure_cause = task.get("FailureCause") or ""
    task_end      = task.get("TaskEndTime")
    task_start    = task.get("TaskStartTime")

    if task_end and task_end.tzinfo is None:
        task_end = task_end.replace(tzinfo=timezone.utc)
    if task_start and task_start.tzinfo is None:
        task_start = task_start.replace(tzinfo=timezone.utc)

    print(f"Export task {export_task_id}: status={status} progress={percent}%")

    return {
        **event,
        "status":           status,
        "percent_progress": percent,
        "failure_cause":    failure_cause,
        "task_start_time":  task_start.isoformat() if task_start else None,
        "task_end_time":    task_end.isoformat() if task_end else None,
        "total_data_gb":    task.get("TotalExtractedDataInGB"),
        "kms_key_id":       task.get("KmsKeyId", ""),
    }
