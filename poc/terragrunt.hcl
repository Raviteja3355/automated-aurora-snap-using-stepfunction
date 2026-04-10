# =============================================================================
# ROOT TERRAGRUNT CONFIGURATION
# Inherited by all child environments (dev / test / prod) via:
#   include "root" { path = find_in_parent_folders() }
#
# Prerequisites — create these once before first `terragrunt apply`:
#   aws s3api create-bucket \
#     --bucket tfstate-rds-snapshot-<ACCOUNT_ID> \
#     --region ap-south-1 \
#     --create-bucket-configuration LocationConstraint=ap-south-1
#
#   aws s3api put-bucket-versioning \
#     --bucket tfstate-rds-snapshot-<ACCOUNT_ID> \
#     --versioning-configuration Status=Enabled
#
#   aws dynamodb create-table \
#     --table-name tfstate-rds-snapshot-lock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST \
#     --region ap-south-1
# =============================================================================

locals {
  region = "ap-south-1"
}

remote_state {
  backend = "s3"

  # Terragrunt auto-generates backend.tf in the working directory so the
  # child module source does not need a backend block.
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket         = "step-fun-rds-snap-s3"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.region
    encrypt        = true
    use_lockfile   = true
  }
}
