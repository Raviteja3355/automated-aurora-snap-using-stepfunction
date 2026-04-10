"""
SFN Check Delete Lambda — evaluates all 5 conditions before allowing deletion.
The Step Functions ShouldDelete Choice state reads $.should_delete to branch.
All conditions must pass for should_delete = True:
  1. delete_source_after_export flag enabled (env var)
  2. dry_run is False
  3. integrity_passed is True
  4. task_end_time is present
  5. delete_delay has elapsed since task_end_time
"""
import os
from datetime import datetime, timezone, timedelta

DELETE_SOURCE_AFTER_EXPORT = os.environ.get("DELETE_SOURCE_AFTER_EXPORT", "false").lower() == "true"
DELETE_DELAY_DAYS          = int(os.environ.get("DELETE_DELAY_DAYS", "7"))
DRY_RUN_MODE               = os.environ.get("DRY_RUN_MODE", "false").lower() == "true"


def handler(event, context):
    snapshot_id    = event.get("snapshot_identifier", "unknown")
    integrity_ok   = event.get("integrity_passed", False)
    task_end_time  = event.get("task_end_time")
    dry_run        = event.get("dry_run", DRY_RUN_MODE)
    # Use env var as authoritative source for deletion settings (safety gate)
    delete_enabled = DELETE_SOURCE_AFTER_EXPORT
    delay_days     = DELETE_DELAY_DAYS

    # 1. Deletion flag
    if not delete_enabled:
        print(f"[{snapshot_id}] delete_source_after_export=false — skipping")
        return {**event, "should_delete": False, "delete_reason": "flag_disabled"}

    # 2. Dry-run guard
    if dry_run:
        print(f"[{snapshot_id}] dry_run=true — skipping deletion")
        return {**event, "should_delete": False, "delete_reason": "dry_run"}

    # 3. Integrity check
    if not integrity_ok:
        print(f"[{snapshot_id}] integrity_passed=false — blocking deletion")
        return {**event, "should_delete": False, "delete_reason": "integrity_failed"}

    # 4. task_end_time present
    if not task_end_time:
        print(f"[{snapshot_id}] task_end_time missing")
        return {**event, "should_delete": False, "delete_reason": "no_end_time"}

    # 5. Delay elapsed
    if isinstance(task_end_time, str):
        task_end_time = datetime.fromisoformat(task_end_time.replace("Z", "+00:00"))

    eligible_after = task_end_time + timedelta(days=delay_days)
    now            = datetime.now(timezone.utc)

    if now < eligible_after:
        remaining_days = max(0, (eligible_after - now).days)
        print(f"[{snapshot_id}] Delay not met — {remaining_days} day(s) remaining")
        return {
            **event,
            "should_delete":           False,
            "delete_reason":           "delay_not_met",
            "days_remaining":          remaining_days,
            "scheduled_deletion_date": eligible_after.isoformat(),
        }

    print(f"[{snapshot_id}] All deletion conditions met")
    return {**event, "should_delete": True, "delete_reason": "all_conditions_met"}
