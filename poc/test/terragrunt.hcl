terraform {
  source = "../../modules/rds_snapshot_infra"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  region             = "ap-south-1"
  bucket_name        = "snapshot-export-deeparchive-test"
  create_kms_key     = true   # Module creates a dedicated KMS key for test isolation
  kms_key_arn        = ""     # Unused when create_kms_key = true
  notification_email = ""     # SNS email subscription disabled
  sns_topic_name     = "test-snapshot-export-topic"

  retention_days    = 0
  deep_archive_days = 1

  dry_run_mode               = false
  delete_source_after_export = false
  delete_delay_days          = 7

  # Execution control — lower concurrency for test
  max_export_concurrency = 3

  # Snapshot filtering — leave empty to process all manual snapshots
  target_cluster_identifiers = ""
  snapshot_name_pattern      = ""

  # AWS Backup Vault — source of recovery points to export
  backup_vault_name = "Default"

  # IAM Role Names
  rds_export_role_name = "test-rds-export-role"

  # ===========================================================================
  # STEP FUNCTIONS PIPELINE
  # ===========================================================================

  # Single Google Chat webhook — all SFN pipeline events go here
  google_chat_webhook_url = "https://chat.googleapis.com/v1/spaces/AAQAWjpVDYA/messages?key=AIzaSyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHI&token=al1iUxs7nhc__YPpk8EVnSpU0N6YTfMYzXEkvKkYYTI"

  # Step Functions config
  sfn_state_machine_name              = "test-aurora-snapshot-pipeline"
  sfn_execution_role_name             = "test-sfn-execution-role"
  sfn_eventbridge_rule_name           = "test-sfn-snapshot-trigger"
  sfn_eventbridge_schedule_expression = "rate(1 day)"
  sfn_eventbridge_role_name           = "test-sfn-eventbridge-role"

  # SFN Lambda names
  sfn_discovery_lambda_name    = "test-sfn-snapshot-discovery"
  sfn_export_lambda_name       = "test-sfn-snapshot-export"
  sfn_check_status_lambda_name = "test-sfn-check-export-status"
  sfn_integrity_lambda_name    = "test-sfn-integrity-check"
  sfn_notify_lambda_name       = "test-sfn-notify"
  sfn_check_delete_lambda_name = "test-sfn-check-deletion"
  sfn_delete_lambda_name       = "test-sfn-delete-snapshot"
  sfn_s3_cleanup_lambda_name   = "test-sfn-s3-cleanup"

  # SFN Lambda IAM role names
  sfn_discovery_lambda_role_name    = "test-sfn-discovery-role"
  sfn_export_lambda_role_name       = "test-sfn-export-role"
  sfn_check_status_lambda_role_name = "test-sfn-check-status-role"
  sfn_integrity_lambda_role_name    = "test-sfn-integrity-role"
  sfn_notify_lambda_role_name       = "test-sfn-notify-role"
  sfn_check_delete_lambda_role_name = "test-sfn-check-delete-role"
  sfn_delete_lambda_role_name       = "test-sfn-delete-role"
  sfn_s3_cleanup_lambda_role_name   = "test-sfn-s3-cleanup-role"

  # SFN Lambda source files — reuse the same source files as dev
  sfn_discovery_lambda_source_file    = "${get_terragrunt_dir()}/../dev/lambdas/sfn_discovery_lambda.py"
  sfn_export_lambda_source_file       = "${get_terragrunt_dir()}/../dev/lambdas/sfn_export_lambda.py"
  sfn_check_status_lambda_source_file = "${get_terragrunt_dir()}/../dev/lambdas/sfn_check_status_lambda.py"
  sfn_integrity_lambda_source_file    = "${get_terragrunt_dir()}/../dev/lambdas/sfn_integrity_lambda.py"
  sfn_notify_lambda_source_file       = "${get_terragrunt_dir()}/../dev/lambdas/sfn_notify_lambda.py"
  sfn_check_delete_lambda_source_file = "${get_terragrunt_dir()}/../dev/lambdas/sfn_check_delete_lambda.py"
  sfn_delete_lambda_source_file       = "${get_terragrunt_dir()}/../dev/lambdas/sfn_delete_lambda.py"
  sfn_s3_cleanup_lambda_source_file   = "${get_terragrunt_dir()}/../dev/lambdas/sfn_s3_cleanup_lambda.py"
}
