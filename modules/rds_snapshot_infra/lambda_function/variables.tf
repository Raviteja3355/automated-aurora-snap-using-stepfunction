variable "function_name" { type = string }
variable "role_arn"      { type = string }
variable "handler"       { type = string }
variable "runtime" {
  type    = string
  default = "python3.11"
}
variable "source_file" { type = string }
variable "env_vars" {
  type    = map(string)
  default = {}
}
variable "timeout" {
  type    = number
  default = 120
  description = "Lambda function timeout in seconds"
}
variable "memory_size" {
  type    = number
  default = 256
  description = "Lambda function memory in MB"
}
variable "dlq_arn" {
  type    = string
  default = ""
  description = "SQS ARN for the dead-letter queue; empty disables DLQ"
}
