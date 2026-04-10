variable "role_name"     { type = string }
variable "s3_bucket_arn" { type = string }
variable "kms_key_arn"   { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}