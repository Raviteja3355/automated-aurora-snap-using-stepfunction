variable "bucket_name"       { type = string }
variable "kms_key_arn"       { type = string }
variable "deep_archive_days" { type = number }
variable "tags" {
  type    = map(string)
  default = {}
}
variable "force_destroy" {
 type    = bool
 default = false
}


