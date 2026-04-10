# =============================================================================
# Step Functions — Aurora/RDS Snapshot Export Pipeline
#
# Flow per snapshot (Map iterator):
#   StartExport → CheckExportRouting
#     → deep_archive=true:             SetDeepArchiveSkippedEventType → NotifyDeepArchiveSkipped → SnapshotDone
#     → reused_complete_s3_verified:   RunIntegrityCheck (skip wait — already complete)
#     → reused_existing (in-progress): WaitBeforeStatusCheck (join running task)
#     → fresh export (default):        SetExportStartedEventType → NotifyExportStarted
#                                        → WaitBeforeStatusCheck → CheckExportStatus
#                                          → COMPLETE: RunIntegrityCheck
#                                              → PASSED: NotifyIntegrityPassed → NotifySuccess → WaitBeforeDeletion
#                                                        → CheckDeletion → ShouldDelete
#                                                          → YES:       DeleteSnapshot → NotifyDeleted → SnapshotDone
#                                                          → SCHEDULED: NotifyDeletionScheduled → SnapshotDone
#                                                          → NO:        SnapshotDone
#                                              → FAILED: NotifyIntegrityFailed → SnapshotDone
#                                          → FAILED/CANCELED: CheckRetryCount
#                                              → retries left: IncrementRetry → NotifyRetry → WaitBeforeRetry → StartExport
#                                              → exhausted:    CleanupPartialExport → NotifyExportFailed → SnapshotDone
#                                          → IN_PROGRESS: loop back to WaitBeforeStatusCheck
# =============================================================================

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${var.state_machine_name}"
  retention_in_days = 30
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = var.state_machine_name
  role_arn = var.sfn_role_arn
  type     = "STANDARD"

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  definition = jsonencode({
    Comment = "Aurora/RDS Snapshot Export Lifecycle Pipeline"
    StartAt = "DiscoverSnapshots"
    States = {

      # ── Top-level ─────────────────────────────────────────────────────────────

      "DiscoverSnapshots" = {
        Type     = "Task"
        Resource = var.sfn_discovery_lambda_arn
        Next     = "HasEligibleSnapshots"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
          MaxAttempts     = 2
          IntervalSeconds = 30
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "HandlePipelineFailed"
        }]
      }

      "HasEligibleSnapshots" = {
        Type = "Choice"
        Choices = [{
          Variable           = "$.eligible_count"
          NumericGreaterThan = 0
          Next               = "ProcessSnapshots"
        }]
        Default = "PipelineComplete"
      }

      "ProcessSnapshots" = {
        Type           = "Map"
        ItemsPath      = "$.snapshots"
        MaxConcurrency = var.max_export_concurrency
        Iterator = {
          StartAt = "StartExport"
          States = {

            # ── Export ──────────────────────────────────────────────────────────

            "StartExport" = {
              Type     = "Task"
              Resource = var.sfn_export_lambda_arn
              Next     = "CheckExportRouting"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 3
                IntervalSeconds = 60
                BackoffRate     = 2
              }]
              Catch = [{
                ErrorEquals = ["States.ALL"]
                ResultPath  = "$.error"
                Next        = "CheckRetryCount"
              }]
            }

            # Route based on what StartExport found:
            #   deep_archive=true              → skip integrity, notify Deep Archive
            #   reuse_reason=complete+s3 data  → skip wait, go straight to integrity
            #   reused_existing=true (running) → join in-progress task, normal wait loop
            #   default (fresh export)         → notify started, then wait loop
            "CheckExportRouting" = {
              Type = "Choice"
              Choices = [
                {
                  Variable      = "$.deep_archive"
                  BooleanEquals = true
                  Next          = "SetDeepArchiveSkippedEventType"
                },
                {
                  Variable     = "$.reuse_reason"
                  StringEquals = "reused_complete_s3_verified"
                  Next         = "RunIntegrityCheck"
                },
                {
                  Variable      = "$.reused_existing"
                  BooleanEquals = true
                  Next          = "WaitBeforeStatusCheck"
                }
              ]
              Default = "SetExportStartedEventType"
            }

            # ── Deep Archive path ────────────────────────────────────────────────

            "SetDeepArchiveSkippedEventType" = {
              Type       = "Pass"
              Result     = "DEEP_ARCHIVE_SKIPPED"
              ResultPath = "$.event_type"
              Next       = "NotifyDeepArchiveSkipped"
            }

            "NotifyDeepArchiveSkipped" = {
              Type     = "Task"
              Resource = var.sfn_notify_lambda_arn
              Next     = "SnapshotDone"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 10
                BackoffRate     = 1
              }]
            }

            "SetExportStartedEventType" = {
              Type       = "Pass"
              Result     = "EXPORT_STARTED"
              ResultPath = "$.event_type"
              Next       = "NotifyExportStarted"
            }

            "NotifyExportStarted" = {
              Type     = "Task"
              Resource = var.sfn_notify_lambda_arn
              Next     = "WaitBeforeStatusCheck"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 10
                BackoffRate     = 1
              }]
            }

            "WaitBeforeStatusCheck" = {
              Type    = "Wait"
              Seconds = 900
              Next    = "CheckExportStatus"
            }

            "CheckExportStatus" = {
              Type     = "Task"
              Resource = var.sfn_check_status_lambda_arn
              Next     = "IsExportComplete"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 3
                IntervalSeconds = 30
                BackoffRate     = 2
              }]
              Catch = [{
                ErrorEquals = ["States.ALL"]
                ResultPath  = "$.error"
                Next        = "CheckRetryCount"
              }]
            }

            "IsExportComplete" = {
              Type = "Choice"
              Choices = [
                {
                  Variable     = "$.status"
                  StringEquals = "COMPLETE"
                  Next         = "RunIntegrityCheck"
                },
                {
                  Variable     = "$.status"
                  StringEquals = "FAILED"
                  Next         = "CheckRetryCount"
                },
                {
                  Variable     = "$.status"
                  StringEquals = "CANCELED"
                  Next         = "CheckRetryCount"
                }
              ]
              Default = "WaitBeforeStatusCheck"
            }

            # ── Retry logic ──────────────────────────────────────────────────────

            # Compare retry_count against max_export_retries (both embedded in state)
            "CheckRetryCount" = {
              Type = "Choice"
              Choices = [{
                Variable            = "$.retry_count"
                NumericLessThanPath = "$.max_export_retries"
                Next                = "IncrementRetryTemp"
              }]
              Default = "HandleExportFailed"
            }

            # Step 1: compute new count into a temp field
            "IncrementRetryTemp" = {
              Type = "Pass"
              Parameters = {
                "new_count.$" = "States.MathAdd($.retry_count, 1)"
              }
              ResultPath = "$.retry_temp"
              Next       = "ApplyRetryIncrement"
            }

            # Step 2: promote temp value to $.retry_count
            "ApplyRetryIncrement" = {
              Type       = "Pass"
              InputPath  = "$.retry_temp.new_count"
              ResultPath = "$.retry_count"
              Next       = "SetRetryEventType"
            }

            "SetRetryEventType" = {
              Type       = "Pass"
              Result     = "EXPORT_RETRY"
              ResultPath = "$.event_type"
              Next       = "NotifyRetry"
            }

            "NotifyRetry" = {
              Type     = "Task"
              Resource = var.sfn_notify_lambda_arn
              Next     = "WaitBeforeRetry"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 10
                BackoffRate     = 1
              }]
            }

            # Wait 5 minutes before retrying the export task
            "WaitBeforeRetry" = {
              Type    = "Wait"
              Seconds = 300
              Next    = "StartExport"
            }

            # ── Integrity ────────────────────────────────────────────────────────

            "RunIntegrityCheck" = {
              Type     = "Task"
              Resource = var.sfn_integrity_lambda_arn
              Next     = "IsIntegrityPassed"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 30
                BackoffRate     = 2
              }]
              Catch = [{
                ErrorEquals = ["States.ALL"]
                ResultPath  = "$.error"
                Next        = "HandleIntegrityFailed"
              }]
            }

            "IsIntegrityPassed" = {
              Type = "Choice"
              Choices = [{
                Variable      = "$.integrity_passed"
                BooleanEquals = true
                Next          = "SetIntegrityPassedEventType"
              }]
              Default = "HandleIntegrityFailed"
            }

            # ── Integrity passed notification ────────────────────────────────────

            "SetIntegrityPassedEventType" = {
              Type       = "Pass"
              Result     = "INTEGRITY_PASSED"
              ResultPath = "$.event_type"
              Next       = "NotifyIntegrityPassed"
            }

            "NotifyIntegrityPassed" = {
              Type     = "Task"
              Resource = var.sfn_notify_lambda_arn
              Next     = "SetSuccessEventType"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 10
                BackoffRate     = 1
              }]
            }

            # ── Success notification + deletion flow ─────────────────────────────

            "SetSuccessEventType" = {
              Type       = "Pass"
              Result     = "EXPORT_SUCCESS"
              ResultPath = "$.event_type"
              Next       = "NotifySuccess"
            }

            "NotifySuccess" = {
              Type     = "Task"
              Resource = var.sfn_notify_lambda_arn
              Next     = "WaitBeforeDeletion"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 10
                BackoffRate     = 1
              }]
            }

            "WaitBeforeDeletion" = {
              Type        = "Wait"
              SecondsPath = "$.delete_delay_seconds"
              Next        = "CheckDeletion"
            }

            "CheckDeletion" = {
              Type     = "Task"
              Resource = var.sfn_check_delete_lambda_arn
              Next     = "ShouldDelete"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 30
                BackoffRate     = 2
              }]
            }

            "ShouldDelete" = {
              Type = "Choice"
              Choices = [
                {
                  Variable      = "$.should_delete"
                  BooleanEquals = true
                  Next          = "DeleteSnapshot"
                },
                {
                  Variable     = "$.delete_reason"
                  StringEquals = "delay_not_met"
                  Next         = "SetDeletionScheduledEventType"
                }
              ]
              Default = "SnapshotDone"
            }

            # ── Scheduled deletion notification ──────────────────────────────────

            "SetDeletionScheduledEventType" = {
              Type       = "Pass"
              Result     = "DELETION_SCHEDULED"
              ResultPath = "$.event_type"
              Next       = "NotifyDeletionScheduled"
            }

            "NotifyDeletionScheduled" = {
              Type     = "Task"
              Resource = var.sfn_notify_lambda_arn
              Next     = "SnapshotDone"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 10
                BackoffRate     = 1
              }]
            }

            # ── Delete + post-deletion notification ──────────────────────────────

            "DeleteSnapshot" = {
              Type     = "Task"
              Resource = var.sfn_delete_lambda_arn
              Next     = "SetDeletedEventType"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 30
                BackoffRate     = 2
              }]
              Catch = [{
                ErrorEquals = ["States.ALL"]
                ResultPath  = "$.error"
                Next        = "SnapshotDone"
              }]
            }

            "SetDeletedEventType" = {
              Type       = "Pass"
              Result     = "DELETED"
              ResultPath = "$.event_type"
              Next       = "NotifyDeleted"
            }

            "NotifyDeleted" = {
              Type     = "Task"
              Resource = var.sfn_notify_lambda_arn
              Next     = "SnapshotDone"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 10
                BackoffRate     = 1
              }]
            }

            # ── Failure handlers ─────────────────────────────────────────────────

            "HandleExportFailed" = {
              Type       = "Pass"
              Result     = "EXPORT_FAILED"
              ResultPath = "$.event_type"
              Next       = "CleanupPartialExport"
            }

            # Delete partial S3 files left behind by a failed/canceled export task
            "CleanupPartialExport" = {
              Type     = "Task"
              Resource = var.sfn_s3_cleanup_lambda_arn
              Next     = "NotifyExportFailed"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 30
                BackoffRate     = 2
              }]
              # If cleanup itself fails, still proceed to notify — don't lose the failure notification
              Catch = [{
                ErrorEquals = ["States.ALL"]
                ResultPath  = "$.cleanup_error"
                Next        = "NotifyExportFailed"
              }]
            }

            "NotifyExportFailed" = {
              Type     = "Task"
              Resource = var.sfn_notify_lambda_arn
              Next     = "SnapshotDone"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 10
                BackoffRate     = 1
              }]
            }

            "HandleIntegrityFailed" = {
              Type       = "Pass"
              Result     = "INTEGRITY_FAILED"
              ResultPath = "$.event_type"
              Next       = "NotifyIntegrityFailed"
            }

            "NotifyIntegrityFailed" = {
              Type     = "Task"
              Resource = var.sfn_notify_lambda_arn
              Next     = "SnapshotDone"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
                MaxAttempts     = 2
                IntervalSeconds = 10
                BackoffRate     = 1
              }]
            }

            "SnapshotDone" = {
              Type = "Succeed"
            }
          }
        }
        Next = "PipelineComplete"
      }

      # ── Pipeline-level failure ────────────────────────────────────────────────

      "HandlePipelineFailed" = {
        Type       = "Pass"
        Result     = "PIPELINE_FAILED"
        ResultPath = "$.event_type"
        Next       = "NotifyPipelineFailed"
      }

      "NotifyPipelineFailed" = {
        Type     = "Task"
        Resource = var.sfn_notify_lambda_arn
        Next     = "PipelineFailed"
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
          MaxAttempts     = 2
          IntervalSeconds = 10
          BackoffRate     = 1
        }]
      }

      "PipelineFailed" = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "Discovery step failed — check CloudWatch Logs"
      }

      "PipelineComplete" = {
        Type = "Succeed"
      }
    }
  })

  tags = { Name = var.state_machine_name }
}
