terraform {
  source = "../../modules/rds_snapshot_infra"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  region             = "ap-south-1"
  bucket_name        = "snapshot-export-deeparchive-prod"
  # TODO: Replace with a prod-dedicated KMS key ARN.
  # Using a separate key per environment ensures prod key policy changes
  # do not affect dev/test and limits blast radius if a key is compromised.
  kms_key_arn        = "arn:aws:kms:ap-south-1:320042238069:key/REPLACE-WITH-PROD-KEY"
  notification_email = ""  # SNS email subscription disabled — Teams channels are used instead
  sns_topic_name     = "prod-snapshot-export-topic"

  retention_days    = 730
  deep_archive_days = 1

  # Safety defaults — keep deletion disabled until the workflow has been
  # validated in dev/test; increase delete_delay_days for extra buffer in prod
  dry_run_mode               = false
  delete_source_after_export = false
  delete_delay_days          = 30

  # Execution control
  max_export_concurrency = 5

  # Snapshot filtering — leave empty to process all manual snapshots
  target_cluster_identifiers = ""
  snapshot_name_pattern      = ""

  # AWS Backup Vault — source of recovery points to export
  backup_vault_name = "Default"

  # IAM Role Names
  rds_export_role_name = "prod-rds-export-role"

  # ===========================================================================
  # STEP FUNCTIONS PIPELINE
  # ===========================================================================

  # Single Google Chat webhook — all SFN pipeline events go here
  # google_chat_webhook_url = ""  # TODO: set prod webhook URL

  # Step Functions config
  sfn_state_machine_name              = "prod-aurora-snapshot-pipeline"
  sfn_execution_role_name             = "prod-sfn-execution-role"
  sfn_eventbridge_rule_name           = "prod-sfn-snapshot-trigger"
  sfn_eventbridge_schedule_expression = "rate(1 day)"
  sfn_eventbridge_role_name           = "prod-sfn-eventbridge-role"

  # SFN Lambda names
  sfn_discovery_lambda_name    = "prod-sfn-snapshot-discovery"
  sfn_export_lambda_name       = "prod-sfn-snapshot-export"
  sfn_check_status_lambda_name = "prod-sfn-check-export-status"
  sfn_integrity_lambda_name    = "prod-sfn-integrity-check"
  sfn_notify_lambda_name       = "prod-sfn-notify"
  sfn_check_delete_lambda_name = "prod-sfn-check-deletion"
  sfn_delete_lambda_name       = "prod-sfn-delete-snapshot"
  sfn_s3_cleanup_lambda_name   = "prod-sfn-s3-cleanup"

  # SFN Lambda IAM role names
  sfn_discovery_lambda_role_name    = "prod-sfn-discovery-role"
  sfn_export_lambda_role_name       = "prod-sfn-export-role"
  sfn_check_status_lambda_role_name = "prod-sfn-check-status-role"
  sfn_integrity_lambda_role_name    = "prod-sfn-integrity-role"
  sfn_notify_lambda_role_name       = "prod-sfn-notify-role"
  sfn_check_delete_lambda_role_name = "prod-sfn-check-delete-role"
  sfn_delete_lambda_role_name       = "prod-sfn-delete-role"
  sfn_s3_cleanup_lambda_role_name   = "prod-sfn-s3-cleanup-role"

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
