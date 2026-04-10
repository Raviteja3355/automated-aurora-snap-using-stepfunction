variable "state_machine_name" {
  type = string
}

variable "sfn_role_arn" {
  type = string
}

variable "max_export_concurrency" {
  type    = number
  default = 5
}

variable "max_export_retries" {
  type    = number
  default = 2
  description = "Maximum number of times a failed export task is retried before giving up"
}

variable "sfn_discovery_lambda_arn" {
  type = string
}

variable "sfn_export_lambda_arn" {
  type = string
}

variable "sfn_check_status_lambda_arn" {
  type = string
}

variable "sfn_integrity_lambda_arn" {
  type = string
}

variable "sfn_notify_lambda_arn" {
  type = string
}

variable "sfn_check_delete_lambda_arn" {
  type = string
}

variable "sfn_delete_lambda_arn" {
  type = string
}

variable "sfn_s3_cleanup_lambda_arn" {
  type = string
}
