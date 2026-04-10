variable "role_name"              { type = string }
variable "extra_policy_statements" { 
  type = list(any) 
  default = [] 
}
variable "tags" {
  type    = map(string)
  default = {}
}
