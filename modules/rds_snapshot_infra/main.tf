terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------
# KMS KEY (optional — created when create_kms_key = true)
# Use for environment isolation instead of a shared key.
# ---------------------------------------------------------
resource "aws_kms_key" "managed" {
  count                   = var.create_kms_key ? 1 : 0
  description             = "KMS key for ${var.bucket_name} snapshot export pipeline"
  deletion_window_in_days = 14
  enable_key_rotation     = true
  tags                    = { Name = "${var.bucket_name}-kms-key" }
}

resource "aws_kms_alias" "managed" {
  count         = var.create_kms_key ? 1 : 0
  name          = "alias/${var.bucket_name}-key"
  target_key_id = aws_kms_key.managed[0].key_id
}

locals {
  # Resolves to the module-created key or the externally provided ARN
  kms_key_arn = var.create_kms_key ? aws_kms_key.managed[0].arn : var.kms_key_arn
}

# ---------------------------------------------------------
# S3 BUCKET
# ---------------------------------------------------------
module "archive_bucket" {
  source            = "./s3_bucket"
  bucket_name       = var.bucket_name
  kms_key_arn       = local.kms_key_arn
  deep_archive_days = var.deep_archive_days
  force_destroy     = var.force_destroy_bucket
}

# ---------------------------------------------------------
# RDS EXPORT ROLE (includes KMS grants and all S3 permissions)
# ---------------------------------------------------------
module "rds_export_role" {
  source        = "./iam_rds_export_role"
  role_name     = var.rds_export_role_name
  s3_bucket_arn = module.archive_bucket.bucket_arn
  kms_key_arn   = local.kms_key_arn
}

# ---------------------------------------------------------
# SNS NOTIFICATIONS
# ---------------------------------------------------------
module "sns_notifications" {
  source             = "./sns_notifications"
  topic_name         = var.sns_topic_name
  notification_email = var.notification_email
}

# =============================================================================
# STEP FUNCTIONS PIPELINE — 8 focused Lambdas + State Machine + EventBridge
# =============================================================================

# ---------------------------------------------------------
# SFN LAMBDA ROLES
# ---------------------------------------------------------
module "sfn_discovery_lambda_role" {
  source    = "./iam_lambda_role"
  role_name = var.sfn_discovery_lambda_role_name
  extra_policy_statements = [
    { actions = ["rds:DescribeDBSnapshots", "rds:DescribeDBClusterSnapshots", "rds:DescribeExportTasks"], resources = ["*"] }
  ]
}

module "sfn_export_lambda_role" {
  source    = "./iam_lambda_role"
  role_name = var.sfn_export_lambda_role_name
  extra_policy_statements = [
    { actions = ["rds:StartExportTask", "rds:DescribeExportTasks"], resources = ["*"] },
    { actions = ["iam:PassRole"],                                    resources = [module.rds_export_role.role_arn] },
    { actions = ["kms:DescribeKey", "kms:Decrypt", "kms:GenerateDataKey*", "kms:CreateGrant"], resources = [local.kms_key_arn] },
    # Needed to verify whether S3 data is present before reusing a completed export task
    { actions = ["s3:ListBucket"], resources = [module.archive_bucket.bucket_arn] }
  ]
}

module "sfn_check_status_lambda_role" {
  source    = "./iam_lambda_role"
  role_name = var.sfn_check_status_lambda_role_name
  extra_policy_statements = [
    { actions = ["rds:DescribeExportTasks"], resources = ["*"] }
  ]
}

module "sfn_integrity_lambda_role" {
  source    = "./iam_lambda_role"
  role_name = var.sfn_integrity_lambda_role_name
  extra_policy_statements = [
    { actions = ["s3:ListBucket"],  resources = [module.archive_bucket.bucket_arn] },
    { actions = ["s3:GetObject"],   resources = ["${module.archive_bucket.bucket_arn}/*"] },
    { actions = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"], resources = [local.kms_key_arn] }
  ]
}

module "sfn_notify_lambda_role" {
  source                  = "./iam_lambda_role"
  role_name               = var.sfn_notify_lambda_role_name
  extra_policy_statements = []
}

module "sfn_check_delete_lambda_role" {
  source                  = "./iam_lambda_role"
  role_name               = var.sfn_check_delete_lambda_role_name
  extra_policy_statements = []
}

module "sfn_delete_lambda_role" {
  source    = "./iam_lambda_role"
  role_name = var.sfn_delete_lambda_role_name
  extra_policy_statements = [
    { actions = ["rds:DeleteDBSnapshot", "rds:DeleteDBClusterSnapshot"], resources = ["*"] },
    { actions = ["backup:DeleteRecoveryPoint"],                          resources = ["*"] }
  ]
}

module "sfn_s3_cleanup_lambda_role" {
  source    = "./iam_lambda_role"
  role_name = var.sfn_s3_cleanup_lambda_role_name
  extra_policy_statements = [
    { actions = ["s3:ListBucket"],                          resources = [module.archive_bucket.bucket_arn] },
    { actions = ["s3:DeleteObject", "s3:DeleteObjectVersion"], resources = ["${module.archive_bucket.bucket_arn}/*"] }
  ]
}

# ---------------------------------------------------------
# SFN LAMBDA FUNCTIONS (7)
# ---------------------------------------------------------
module "sfn_discovery_lambda" {
  source        = "./lambda_function"
  function_name = var.sfn_discovery_lambda_name
  role_arn      = module.sfn_discovery_lambda_role.role_arn
  handler       = "sfn_discovery_lambda.handler"
  source_file   = var.sfn_discovery_lambda_source_file
  timeout       = var.sfn_discovery_lambda_timeout
  memory_size   = var.sfn_discovery_lambda_memory_mb
  env_vars = {
    RETENTION_DAYS             = tostring(var.retention_days)
    ARCHIVE_BUCKET             = module.archive_bucket.bucket_id
    DRY_RUN_MODE               = tostring(var.dry_run_mode)
    MAX_EXPORT_CONCURRENCY     = tostring(var.max_export_concurrency)
    TARGET_CLUSTER_IDENTIFIERS = var.target_cluster_identifiers
    SNAPSHOT_NAME_PATTERN      = var.snapshot_name_pattern
    EXPORT_ROLE_ARN            = module.rds_export_role.role_arn
    KMS_KEY_ARN                = local.kms_key_arn
    DELETE_SOURCE_AFTER_EXPORT = tostring(var.delete_source_after_export)
    DELETE_DELAY_DAYS          = tostring(var.delete_delay_days)
    MAX_EXPORT_RETRIES         = tostring(var.max_export_retries)
    GCHAT_WEBHOOK_URL          = var.google_chat_webhook_url
  }
}

module "sfn_export_lambda" {
  source        = "./lambda_function"
  function_name = var.sfn_export_lambda_name
  role_arn      = module.sfn_export_lambda_role.role_arn
  handler       = "sfn_export_lambda.handler"
  source_file   = var.sfn_export_lambda_source_file
  timeout       = var.sfn_export_lambda_timeout
  memory_size   = var.sfn_export_lambda_memory_mb
  env_vars      = { DRY_RUN_MODE = tostring(var.dry_run_mode) }
}

module "sfn_check_status_lambda" {
  source        = "./lambda_function"
  function_name = var.sfn_check_status_lambda_name
  role_arn      = module.sfn_check_status_lambda_role.role_arn
  handler       = "sfn_check_status_lambda.handler"
  source_file   = var.sfn_check_status_lambda_source_file
  timeout       = var.sfn_check_status_lambda_timeout
  memory_size   = var.sfn_check_status_lambda_memory_mb
  env_vars      = {}
}

module "sfn_integrity_lambda" {
  source        = "./lambda_function"
  function_name = var.sfn_integrity_lambda_name
  role_arn      = module.sfn_integrity_lambda_role.role_arn
  handler       = "sfn_integrity_lambda.handler"
  source_file   = var.sfn_integrity_lambda_source_file
  timeout       = var.sfn_integrity_lambda_timeout
  memory_size   = var.sfn_integrity_lambda_memory_mb
  env_vars      = { ARCHIVE_BUCKET = module.archive_bucket.bucket_id }
}

module "sfn_notify_lambda" {
  source        = "./lambda_function"
  function_name = var.sfn_notify_lambda_name
  role_arn      = module.sfn_notify_lambda_role.role_arn
  handler       = "sfn_notify_lambda.handler"
  source_file   = var.sfn_notify_lambda_source_file
  timeout       = var.sfn_notify_lambda_timeout
  memory_size   = var.sfn_notify_lambda_memory_mb
  env_vars = {
    GCHAT_WEBHOOK_URL = var.google_chat_webhook_url
    ARCHIVE_BUCKET    = module.archive_bucket.bucket_id
    DELETE_DELAY_DAYS = tostring(var.delete_delay_days)
  }
}

module "sfn_check_delete_lambda" {
  source        = "./lambda_function"
  function_name = var.sfn_check_delete_lambda_name
  role_arn      = module.sfn_check_delete_lambda_role.role_arn
  handler       = "sfn_check_delete_lambda.handler"
  source_file   = var.sfn_check_delete_lambda_source_file
  timeout       = var.sfn_check_delete_lambda_timeout
  memory_size   = var.sfn_check_delete_lambda_memory_mb
  env_vars = {
    DELETE_SOURCE_AFTER_EXPORT = tostring(var.delete_source_after_export)
    DELETE_DELAY_DAYS          = tostring(var.delete_delay_days)
    DRY_RUN_MODE               = tostring(var.dry_run_mode)
  }
}

module "sfn_delete_lambda" {
  source        = "./lambda_function"
  function_name = var.sfn_delete_lambda_name
  role_arn      = module.sfn_delete_lambda_role.role_arn
  handler       = "sfn_delete_lambda.handler"
  source_file   = var.sfn_delete_lambda_source_file
  timeout       = var.sfn_delete_lambda_timeout
  memory_size   = var.sfn_delete_lambda_memory_mb
  env_vars = {
    DRY_RUN_MODE      = tostring(var.dry_run_mode)
    BACKUP_VAULT_NAME = var.backup_vault_name
  }
}

module "sfn_s3_cleanup_lambda" {
  source        = "./lambda_function"
  function_name = var.sfn_s3_cleanup_lambda_name
  role_arn      = module.sfn_s3_cleanup_lambda_role.role_arn
  handler       = "sfn_s3_cleanup_lambda.handler"
  source_file   = var.sfn_s3_cleanup_lambda_source_file
  timeout       = var.sfn_s3_cleanup_lambda_timeout
  memory_size   = var.sfn_s3_cleanup_lambda_memory_mb
  env_vars      = { ARCHIVE_BUCKET = module.archive_bucket.bucket_id }
}

module "sfn_deep_archive_notify_lambda_role" {
  source                  = "./iam_lambda_role"
  role_name               = var.sfn_deep_archive_notify_lambda_role_name
  extra_policy_statements = []
}

module "sfn_deep_archive_notify_lambda" {
  source        = "./lambda_function"
  function_name = var.sfn_deep_archive_notify_lambda_name
  role_arn      = module.sfn_deep_archive_notify_lambda_role.role_arn
  handler       = "sfn_deep_archive_notify_lambda.handler"
  source_file   = var.sfn_deep_archive_notify_lambda_source_file
  timeout       = var.sfn_deep_archive_notify_lambda_timeout
  memory_size   = var.sfn_deep_archive_notify_lambda_memory_mb
  env_vars = {
    GCHAT_WEBHOOK_URL = var.google_chat_webhook_url
    ARCHIVE_BUCKET    = module.archive_bucket.bucket_id
  }
}

# ---------------------------------------------------------
# STEP FUNCTIONS EXECUTION ROLE
# ---------------------------------------------------------
resource "aws_iam_role" "sfn_execution" {
  name = var.sfn_execution_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_execution" {
  name = "sfn-invoke-lambdas-and-logging"
  role = aws_iam_role.sfn_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeLambdas"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = flatten([
          for fn in [
            module.sfn_discovery_lambda,
            module.sfn_export_lambda,
            module.sfn_check_status_lambda,
            module.sfn_integrity_lambda,
            module.sfn_notify_lambda,
            module.sfn_check_delete_lambda,
            module.sfn_delete_lambda,
            module.sfn_s3_cleanup_lambda,
          ] : [fn.function_arn, "${fn.function_arn}:*"]
        ])
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid      = "XRay"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------
# STEP FUNCTIONS STATE MACHINE
# ---------------------------------------------------------
module "step_functions" {
  source                      = "./step_functions"
  state_machine_name          = var.sfn_state_machine_name
  sfn_role_arn                = aws_iam_role.sfn_execution.arn
  max_export_concurrency      = var.max_export_concurrency
  sfn_discovery_lambda_arn    = module.sfn_discovery_lambda.function_arn
  sfn_export_lambda_arn       = module.sfn_export_lambda.function_arn
  sfn_check_status_lambda_arn = module.sfn_check_status_lambda.function_arn
  sfn_integrity_lambda_arn    = module.sfn_integrity_lambda.function_arn
  sfn_notify_lambda_arn       = module.sfn_notify_lambda.function_arn
  sfn_check_delete_lambda_arn = module.sfn_check_delete_lambda.function_arn
  sfn_delete_lambda_arn       = module.sfn_delete_lambda.function_arn
  sfn_s3_cleanup_lambda_arn   = module.sfn_s3_cleanup_lambda.function_arn
}

# ---------------------------------------------------------
# EVENTBRIDGE → STEP FUNCTIONS (daily trigger)
# ---------------------------------------------------------
resource "aws_iam_role" "eventbridge_sfn" {
  name = var.sfn_eventbridge_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_sfn" {
  name = "start-sfn-execution"
  role = aws_iam_role.eventbridge_sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = module.step_functions.state_machine_arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "sfn_trigger" {
  name                = var.sfn_eventbridge_rule_name
  schedule_expression = var.sfn_eventbridge_schedule_expression
  state               = "ENABLED"
  description         = "Daily trigger for the Step Functions Aurora/RDS snapshot export pipeline"
}

resource "aws_cloudwatch_event_target" "sfn_trigger" {
  rule      = aws_cloudwatch_event_rule.sfn_trigger.name
  target_id = "aurora-snapshot-sfn-pipeline"
  arn       = module.step_functions.state_machine_arn
  role_arn  = aws_iam_role.eventbridge_sfn.arn
}

# ---------------------------------------------------------
# EVENTBRIDGE → DEEP ARCHIVE NOTIFY LAMBDA
# Fires when the export_tables_info JSON file transitions to
# DEEP_ARCHIVE — exactly one event per snapshot export.
# ---------------------------------------------------------
resource "aws_cloudwatch_event_rule" "deep_archive_transition" {
  name        = var.deep_archive_eventbridge_rule_name
  description = "Triggers GChat notification when a snapshot export metadata file moves to S3 Deep Archive"
  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Storage Class Changed"]
    detail = {
      bucket = {
        name = [module.archive_bucket.bucket_id]
      }
      destination-storage-class = ["DEEP_ARCHIVE"]
      object = {
        key = [{ wildcard = "snapshots/*/export_tables_info_*.json" }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "deep_archive_transition" {
  rule      = aws_cloudwatch_event_rule.deep_archive_transition.name
  target_id = "deep-archive-notify"
  arn       = module.sfn_deep_archive_notify_lambda.function_arn
}

resource "aws_lambda_permission" "deep_archive_eventbridge" {
  statement_id  = "AllowEventBridgeInvokeDeepArchiveNotify"
  action        = "lambda:InvokeFunction"
  function_name = module.sfn_deep_archive_notify_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.deep_archive_transition.arn
}
