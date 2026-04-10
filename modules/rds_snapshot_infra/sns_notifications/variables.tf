variable "topic_name" { type = string }

variable "notification_email" {
  type        = string
  default     = ""
  description = "Email address for SNS alarm notifications. Leave empty to disable email subscription (Teams channels are used instead)."
}
