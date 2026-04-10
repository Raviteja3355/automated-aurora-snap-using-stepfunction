"""
SFN Deep Archive Notify Lambda — triggered by EventBridge when S3 objects
transition to DEEP_ARCHIVE storage class.

EventBridge fires one event per object, so the rule is scoped to match only
the export_tables_info_*.json metadata file (one per snapshot export), giving
exactly one notification per snapshot that moves to Deep Archive.

Event structure received from EventBridge:
  {
    "source": "aws.s3",
    "detail-type": "Object Storage Class Changed",
    "detail": {
      "bucket": {"name": "..."},
      "object": {"key": "snapshots/<snap-id>/export_tables_info_*.json", "size": ...},
      "destination-storage-class": "DEEP_ARCHIVE",
      "source-storage-class": "STANDARD"
    }
  }
"""
import json
import os
import urllib.request

GCHAT_WEBHOOK_URL = os.environ.get("GCHAT_WEBHOOK_URL", "")
ARCHIVE_BUCKET    = os.environ.get("ARCHIVE_BUCKET", "")


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
        print("Deep Archive notification sent to Google Chat")
    except Exception as e:
        print(f"Google Chat notification failed: {e}")


def handler(event, context):
    detail = event.get("detail", {})
    bucket = detail.get("bucket", {}).get("name", ARCHIVE_BUCKET)
    obj    = detail.get("object", {})
    key    = obj.get("key", "unknown")
    size   = obj.get("size", 0)
    src_class  = detail.get("source-storage-class", "STANDARD")
    dest_class = detail.get("destination-storage-class", "DEEP_ARCHIVE")

    print(f"Storage class change: s3://{bucket}/{key} — {src_class} → {dest_class}")

    if dest_class != "DEEP_ARCHIVE":
        print(f"Not a Deep Archive transition ({dest_class}) — skipping")
        return

    # Extract snapshot ID from key path: "snapshots/<snapshot_id>/..."
    parts       = key.split("/")
    snapshot_id = parts[1] if len(parts) > 1 else "unknown"

    if size >= 1_073_741_824:
        size_str = f"{size / 1_073_741_824:.2f} GB"
    elif size >= 1_048_576:
        size_str = f"{size / 1_048_576:.2f} MB"
    else:
        size_str = f"{size / 1024:.1f} KB"

    text = (
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        "🧊  *SNAPSHOT EXPORT — MOVED TO DEEP ARCHIVE*\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        "📦  *SNAPSHOT*\n"
        f"   • *Snapshot ID:*    `{snapshot_id}`\n\n"
        "🪣  *S3 LOCATION*\n"
        f"   • *Bucket:*         `{bucket}`\n"
        f"   • *Prefix:*         `snapshots/{snapshot_id}/`\n\n"
        "📊  *METADATA FILE SIZE*\n"
        f"   • *File:*           `{key.split('/')[-1]}`\n"
        f"   • *Size:*           {size_str}\n\n"
        f"   *Storage Class:*   {src_class}  →  DEEP_ARCHIVE\n\n"
        "ℹ️  All export objects for this snapshot have been transitioned to\n"
        "   S3 Glacier Deep Archive. Retrieval will require a restore request.\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    )

    _post(text)
