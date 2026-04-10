# ---------------------------------------------------------
# OUTPUTS
# ---------------------------------------------------------
output "bucket_id"       { value = module.archive_bucket.bucket_id }
output "bucket_arn"      { value = module.archive_bucket.bucket_arn }
output "rds_export_role" { value = module.rds_export_role.role_arn }
output "sns_topic_arn"   { value = module.sns_notifications.topic_arn }
