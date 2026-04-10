"""
SFN Delete Lambda — deletes the source RDS instance or Aurora cluster snapshot.
Also handles AWS Backup recovery points.
Treats NotFound errors as idempotent success.
"""
import os
import boto3
from botocore.exceptions import ClientError
from datetime import datetime, timezone

rds           = boto3.client("rds")
backup_client = boto3.client("backup")

DRY_RUN_MODE      = os.environ.get("DRY_RUN_MODE", "false").lower() == "true"
BACKUP_VAULT_NAME = os.environ.get("BACKUP_VAULT_NAME", "")


def _is_cluster_snapshot(snapshot_arn):
    return ":cluster-snapshot:" in snapshot_arn


def _is_backup_recovery_point(snapshot_arn):
    return "awsbackup" in snapshot_arn.split(":")[-1].lower()


def _extract_snapshot_id(snapshot_arn):
    if _is_cluster_snapshot(snapshot_arn):
        return snapshot_arn.split(":cluster-snapshot:")[-1]
    return snapshot_arn.split(":snapshot:")[-1]


def handler(event, context):
    snapshot_arn = event["snapshot_arn"]
    snapshot_id  = _extract_snapshot_id(snapshot_arn)
    dry_run      = event.get("dry_run", DRY_RUN_MODE)
    backup_vault = event.get("backup_vault_name", BACKUP_VAULT_NAME)

    if dry_run:
        print(f"[DRY RUN] Would delete {snapshot_id}")
        return {**event, "deleted": False, "delete_reason": "dry_run"}

    deleted_at = datetime.now(timezone.utc).isoformat()

    try:
        if _is_backup_recovery_point(snapshot_arn):
            backup_client.delete_recovery_point(
                BackupVaultName=backup_vault,
                RecoveryPointArn=snapshot_arn,
            )
        elif _is_cluster_snapshot(snapshot_arn):
            rds.delete_db_cluster_snapshot(DBClusterSnapshotIdentifier=snapshot_id)
        else:
            rds.delete_db_snapshot(DBSnapshotIdentifier=snapshot_id)

        print(f"Deleted snapshot {snapshot_id}")
        return {**event, "deleted": True, "deleted_at": deleted_at}

    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("DBSnapshotNotFound", "DBClusterSnapshotNotFoundFault", "RecoveryPointDeleted"):
            print(f"{snapshot_id} already deleted — treating as success")
            return {**event, "deleted": True, "deleted_at": deleted_at, "note": "already_deleted"}
        raise
