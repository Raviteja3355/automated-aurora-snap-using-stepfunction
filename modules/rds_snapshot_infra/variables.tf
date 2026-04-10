# -----------------------------
# Global Settings
# -----------------------------
variable "region" {
  type        = string
  description = "AWS region to deploy resources"
}

variable "dry_run_mode" {
  type        = bool
  default     = false
  description = "When true, all lambdas log intended actions without making changes"
}

variable "max_export_concurrency" {
  type        = number
  default     = 5
  description = "Maximum concurrent export tasks across all runs (checked against in-progress tasks)"
}

variable "target_cluster_identifiers" {
  type        = string
  default     = ""
  description = "Comma-separated DB instance/cluster identifiers to target; empty = all"
}

variable "snapshot_name_pattern" {
  type        = string
  default     = ""
  description = "Regex pattern matched against snapshot identifier; empty = all"
}

variable "delete_source_after_export" {
  type        = bool
  default     = false
  description = "When true, source snapshots are deleted after successful export and delay"
}

variable "delete_delay_days" {
  type        = number
  default     = 7
  description = "Days to wait after export completion before deleting the source snapshot"
}

variable "backup_vault_name" {
  type        = string
  default     = ""
  description = "AWS Backup Vault name — only used by status lambda for deletion routing; leave empty when using manual snapshots"
}

# -----------------------------
# S3 / Storage
# -----------------------------
variable "bucket_name" {
  type        = string
  description = "Name of the S3 bucket for snapshot exports"
}

variable "kms_key_arn" {
  type        = string
  default     = ""
  description = "KMS key ARN used for S3 encryption and RDS export. Leave empty when create_kms_key = true."
}

variable "create_kms_key" {
  type        = bool
  default     = false
  description = "When true, a dedicated customer-managed KMS key is created by this module. Use for environment isolation."
}

variable "deep_archive_days" {
  type        = number
  description = "Number of days before moving objects to Deep Archive"
}

variable "force_destroy_bucket" {
    type        = bool
    default     = false
    description = "Allow Terraform to delete the S3 bucket even when it contains versioned objects. Set true for non-prod."
  }
# -----------------------------
# Notifications
# -----------------------------
variable "notification_email" {
  type        = string
  default     = ""
  description = "Email address for SNS alarm notifications. Leave empty to disable the email subscription (CloudWatch alarms still fire to the SNS topic)."
}

variable "retention_days" {
  type        = number
  description = "Retention period (days); snapshots older than this are eligible for export"
}

# -----------------------------
# IAM Role Names
# -----------------------------
variable "rds_export_role_name" {
  type        = string
  description = "IAM role name for RDS export"
}

# -----------------------------
# SNS Topic Name
# -----------------------------
variable "sns_topic_name" {
  type        = string
  description = "SNS topic name for notifications"
}

# =============================================================================
# STEP FUNCTIONS VARIABLES
# =============================================================================

# Single Google Chat webhook — all SFN pipeline events go here
variable "google_chat_webhook_url" {
  type        = string
  default     = ""
  description = "Google Chat webhook URL for all Step Functions pipeline notifications"
}

# Step Functions config
variable "sfn_state_machine_name" {
  type        = string
  description = "Name of the Step Functions state machine"
}

variable "sfn_execution_role_name" {
  type        = string
  description = "IAM role name for Step Functions execution"
}

variable "sfn_eventbridge_rule_name" {
  type        = string
  description = "EventBridge rule name that triggers the Step Functions pipeline"
}

variable "sfn_eventbridge_schedule_expression" {
  type        = string
  default     = "rate(1 day)"
  description = "EventBridge schedule expression for the Step Functions trigger"
}

variable "sfn_eventbridge_role_name" {
  type        = string
  description = "IAM role name for EventBridge to start Step Functions executions"
}

# SFN Lambda names
variable "sfn_discovery_lambda_name"    { type = string }
variable "sfn_export_lambda_name"       { type = string }
variable "sfn_check_status_lambda_name" { type = string }
variable "sfn_integrity_lambda_name"    { type = string }
variable "sfn_notify_lambda_name"       { type = string }
variable "sfn_check_delete_lambda_name" { type = string }
variable "sfn_delete_lambda_name"       { type = string }
variable "sfn_s3_cleanup_lambda_name"   { type = string }

# SFN Lambda IAM role names
variable "sfn_discovery_lambda_role_name"    { type = string }
variable "sfn_export_lambda_role_name"       { type = string }
variable "sfn_check_status_lambda_role_name" { type = string }
variable "sfn_integrity_lambda_role_name"    { type = string }
variable "sfn_notify_lambda_role_name"       { type = string }
variable "sfn_check_delete_lambda_role_name" { type = string }
variable "sfn_delete_lambda_role_name"       { type = string }
variable "sfn_s3_cleanup_lambda_role_name"   { type = string }

# SFN Lambda source files
variable "sfn_discovery_lambda_source_file"    { type = string }
variable "sfn_export_lambda_source_file"       { type = string }
variable "sfn_check_status_lambda_source_file" { type = string }
variable "sfn_integrity_lambda_source_file"    { type = string }
variable "sfn_notify_lambda_source_file"       { type = string }
variable "sfn_check_delete_lambda_source_file" { type = string }
variable "sfn_delete_lambda_source_file"       { type = string }
variable "sfn_s3_cleanup_lambda_source_file"   { type = string }

# SFN Lambda timeouts (seconds)
variable "sfn_discovery_lambda_timeout" {
  type    = number
  default = 120
}
variable "sfn_export_lambda_timeout" {
  type    = number
  default = 60
}
variable "sfn_check_status_lambda_timeout" {
  type    = number
  default = 30
}
variable "sfn_integrity_lambda_timeout" {
  type    = number
  default = 300
}
variable "sfn_notify_lambda_timeout" {
  type    = number
  default = 30
}
variable "sfn_check_delete_lambda_timeout" {
  type    = number
  default = 30
}
variable "sfn_delete_lambda_timeout" {
  type    = number
  default = 60
}
variable "sfn_s3_cleanup_lambda_timeout" {
  type    = number
  default = 300
}

# SFN Lambda memory (MB)
variable "sfn_discovery_lambda_memory_mb" {
  type    = number
  default = 256
}
variable "sfn_export_lambda_memory_mb" {
  type    = number
  default = 256
}
variable "sfn_check_status_lambda_memory_mb" {
  type    = number
  default = 128
}
variable "sfn_integrity_lambda_memory_mb" {
  type    = number
  default = 256
}
variable "sfn_notify_lambda_memory_mb" {
  type    = number
  default = 128
}
variable "sfn_check_delete_lambda_memory_mb" {
  type    = number
  default = 128
}
variable "sfn_delete_lambda_memory_mb" {
  type    = number
  default = 128
}
variable "sfn_s3_cleanup_lambda_memory_mb" {
  type    = number
  default = 128
}

# =============================================================================
# EXPORT RETRY
# =============================================================================
variable "max_export_retries" {
  type        = number
  default     = 2
  description = "Maximum number of times a failed export is retried before giving up and cleaning up partial S3 files"
}

# =============================================================================
# DEEP ARCHIVE NOTIFICATION LAMBDA
# =============================================================================
variable "sfn_deep_archive_notify_lambda_name" {
  type        = string
  description = "Lambda function name for Deep Archive transition notifications"
}

variable "sfn_deep_archive_notify_lambda_role_name" {
  type        = string
  description = "IAM role name for the Deep Archive notify Lambda"
}

variable "sfn_deep_archive_notify_lambda_source_file" {
  type        = string
  description = "Absolute path to sfn_deep_archive_notify_lambda.py source file"
}

variable "sfn_deep_archive_notify_lambda_timeout" {
  type    = number
  default = 30
}

variable "sfn_deep_archive_notify_lambda_memory_mb" {
  type    = number
  default = 128
}

variable "deep_archive_eventbridge_rule_name" {
  type        = string
  description = "EventBridge rule name that triggers Deep Archive notifications"
}
