terraform {
  source = "../../modules/rds_snapshot_infra"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  region         = "ap-south-1"
  bucket_name    = "snapshot-export-deeparchive-dev-ravi"
  force_destroy_bucket = true
  kms_key_arn    = "arn:aws:kms:ap-south-1:320042238069:key/60b3af54-2c60-4350-a529-c248803f2dcb"
  sns_topic_name = "dev-stfs-snapshot-export-topic"
  # notification_email = ""  # No SNS email subscription — uncomment and set to enable

  # Set to 1 so snapshots created 2+ days ago are eligible for export (POC testing)
  # Revert to 730 for production use
  retention_days    = 0
  deep_archive_days = 1

  dry_run_mode               = false
  delete_source_after_export = true
  # Short delay for POC testing — all notification channels will fire.
  # Revert to 7 (or 30 for prod) before production use.
  delete_delay_days = 1

  max_export_concurrency = 5  # AWS hard limit: 5 concurrent RDS export tasks per account

  # Snapshot filtering — uncomment and set to restrict which snapshots are processed
  # target_cluster_identifiers = ""  # Comma-separated DB identifiers; empty = all
  # snapshot_name_pattern      = ""  # Regex against snapshot ID; empty = all

  # backup_vault_name = ""  # Not used — pipeline processes manual RDS snapshots

  # IAM Role Names
  rds_export_role_name = "dev-stfs-rds-export-role"

  # ===========================================================================
  # STEP FUNCTIONS PIPELINE
  # ===========================================================================

  # Single Google Chat webhook — all events (success, failure, integrity, deleted) go here
  google_chat_webhook_url = "https://chat.googleapis.com/v1/spaces/AAQAWjpVDYA/messages?key=AIzaSyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHI&token=al1iUxs7nhc__YPpk8EVnSpU0N6YTfMYzXEkvKkYYTI"

  # Step Functions config
  sfn_state_machine_name              = "dev-stfs-aurora-snapshot-pipeline"
  sfn_execution_role_name             = "dev-stfs-sfn-execution-role"
  sfn_eventbridge_rule_name           = "dev-stfs-sfn-snapshot-trigger"
  sfn_eventbridge_schedule_expression = "rate(1 day)"
  sfn_eventbridge_role_name           = "dev-stfs-sfn-eventbridge-role"

  # SFN Lambda names
  sfn_discovery_lambda_name    = "dev-stfs-sfn-snapshot-discovery"
  sfn_export_lambda_name       = "dev-stfs-sfn-snapshot-export"
  sfn_check_status_lambda_name = "dev-stfs-sfn-check-export-status"
  sfn_integrity_lambda_name    = "dev-stfs-sfn-integrity-check"
  sfn_notify_lambda_name       = "dev-stfs-sfn-notify"
  sfn_check_delete_lambda_name = "dev-stfs-sfn-check-deletion"
  sfn_delete_lambda_name       = "dev-stfs-sfn-delete-snapshot"
  sfn_s3_cleanup_lambda_name   = "dev-stfs-sfn-s3-cleanup"

  # Deep Archive notification Lambda
  sfn_deep_archive_notify_lambda_name      = "dev-stfs-sfn-deep-archive-notify"
  sfn_deep_archive_notify_lambda_role_name = "dev-stfs-sfn-deep-archive-notify-role"
  deep_archive_eventbridge_rule_name       = "dev-stfs-deep-archive-transition"

  # Export retry config (2 retries = 3 total attempts)
  max_export_retries = 3

  # SFN Lambda IAM role names
  sfn_discovery_lambda_role_name    = "dev-stfs-sfn-discovery-role"
  sfn_export_lambda_role_name       = "dev-stfs-sfn-export-role"
  sfn_check_status_lambda_role_name = "dev-stfs-sfn-check-status-role"
  sfn_integrity_lambda_role_name    = "dev-stfs-sfn-integrity-role"
  sfn_notify_lambda_role_name       = "dev-stfs-sfn-notify-role"
  sfn_check_delete_lambda_role_name = "dev-stfs-sfn-check-delete-role"
  sfn_delete_lambda_role_name       = "dev-stfs-sfn-delete-role"
  sfn_s3_cleanup_lambda_role_name   = "dev-stfs-sfn-s3-cleanup-role"

  # SFN Lambda IAM role names (deep archive)
  # (uses sfn_deep_archive_notify_lambda_role_name set above)

  # SFN Lambda source files (resolved at Terragrunt plan time — not affected by cache)
  sfn_discovery_lambda_source_file    = "${get_terragrunt_dir()}/lambdas/sfn_discovery_lambda.py"
  sfn_export_lambda_source_file       = "${get_terragrunt_dir()}/lambdas/sfn_export_lambda.py"
  sfn_check_status_lambda_source_file = "${get_terragrunt_dir()}/lambdas/sfn_check_status_lambda.py"
  sfn_integrity_lambda_source_file    = "${get_terragrunt_dir()}/lambdas/sfn_integrity_lambda.py"
  sfn_notify_lambda_source_file       = "${get_terragrunt_dir()}/lambdas/sfn_notify_lambda.py"
  sfn_check_delete_lambda_source_file = "${get_terragrunt_dir()}/lambdas/sfn_check_delete_lambda.py"
  sfn_delete_lambda_source_file       = "${get_terragrunt_dir()}/lambdas/sfn_delete_lambda.py"
  sfn_s3_cleanup_lambda_source_file   = "${get_terragrunt_dir()}/lambdas/sfn_s3_cleanup_lambda.py"

  # Deep Archive notification Lambda source file
  sfn_deep_archive_notify_lambda_source_file = "${get_terragrunt_dir()}/lambdas/sfn_deep_archive_notify_lambda.py"
}
