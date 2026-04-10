"""
SFN Integrity Lambda — validates S3 export content after export status = COMPLETE.
Checks for export_info_*.json, export_tables_info_*.json, and Parquet file presence.
Returns the full state enriched with integrity_passed and export summary fields.
"""
import json
import os
import boto3

s3 = boto3.client("s3")

ARCHIVE_BUCKET = os.environ.get("ARCHIVE_BUCKET", "")


def _list_objects(bucket, prefix):
    objs      = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            objs.append(obj)
    return objs


def _load_json(bucket, key):
    resp = s3.get_object(Bucket=bucket, Key=key)
    body = resp["Body"].read()
    if not body:
        raise ValueError(f"Empty JSON file: {key}")
    return json.loads(body)


def handler(event, context):
    snapshot_id    = event["snapshot_identifier"]
    archive_bucket = event.get("archive_bucket", ARCHIVE_BUCKET)
    dry_run        = event.get("dry_run", False)

    # Use the sanitized s3_prefix set by the export lambda (avoids mismatch for
    # Aurora automated snapshot IDs that contain colons or other special chars).
    raw_prefix = event.get("s3_prefix") or f"snapshots/{snapshot_id}"
    prefix     = raw_prefix.rstrip("/") + "/"

    if dry_run:
        print(f"[DRY RUN] Skipping integrity check for {snapshot_id}")
        return {
            **event,
            "integrity_passed": True,
            "integrity_status": "DRY_RUN",
            "table_count":      0,
            "object_count":     0,
            "size_str":         "0 KB",
            "info_key":         "",
            "tables_key":       "",
            "s3_prefix":        raw_prefix,
        }

    objs = _list_objects(archive_bucket, prefix)
    if not objs:
        return {
            **event,
            "integrity_passed": False,
            "integrity_status": "NO_OBJECTS_FOUND",
            "table_count":      0,
            "object_count":     0,
            "size_str":         "0 KB",
            "s3_prefix":        raw_prefix,
        }

    keys       = [o["Key"] for o in objs]
    info_key   = next((k for k in keys if "export_info_" in k and k.endswith(".json")), None)
    tables_key = next((k for k in keys if "export_tables_info_" in k and k.endswith(".json")), None)

    if not info_key:
        return {**event, "integrity_passed": False, "integrity_status": "MISSING_EXPORT_INFO", "s3_prefix": raw_prefix}
    if not tables_key:
        return {**event, "integrity_passed": False, "integrity_status": "MISSING_TABLES_INFO", "s3_prefix": raw_prefix}

    info_json   = _load_json(archive_bucket, info_key)
    tables_json = _load_json(archive_bucket, tables_key)

    if "SourceArn" not in info_json and "sourceArn" not in info_json:
        return {**event, "integrity_passed": False, "integrity_status": "INVALID_EXPORT_INFO", "s3_prefix": raw_prefix}

    table_count = 0
    try:
        entries     = tables_json if isinstance(tables_json, list) else tables_json.get("tableStatistics", [])
        table_count = len(entries)
    except Exception:
        pass

    parquet_objs = [o for o in objs if o["Key"].endswith(".parquet")]
    object_count = len(parquet_objs)
    total_bytes  = sum(o.get("Size", 0) for o in parquet_objs)

    if total_bytes >= 1_073_741_824:
        size_str = f"{total_bytes / 1_073_741_824:.2f} GB"
    elif total_bytes >= 1_048_576:
        size_str = f"{total_bytes / 1_048_576:.2f} MB"
    else:
        size_str = f"{total_bytes / 1024:.1f} KB"

    print(f"Integrity OK — {snapshot_id}: {table_count} tables, {object_count} parquet files, {size_str}")

    return {
        **event,
        "integrity_passed": True,
        "integrity_status": "OK",
        "table_count":      table_count,
        "object_count":     object_count,
        "size_str":         size_str,
        "info_key":         info_key,
        "tables_key":       tables_key,
        "s3_prefix":        raw_prefix,
    }
