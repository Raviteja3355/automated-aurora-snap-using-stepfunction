data "aws_iam_policy_document" "assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com", "export.rds.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "role" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "policy" {
  statement {
    effect = "Allow"
    # AWS requires all five of these actions for RDS snapshot exports to succeed.
    # s3:GetBucketLocation, s3:GetObject, s3:DeleteObject are commonly missing
    # and cause export tasks to fail with AccessDenied.
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:DeleteObject",
      "s3:GetBucketLocation"
    ]
    resources = [var.s3_bucket_arn, "${var.s3_bucket_arn}/*"]
  }

  statement {
    effect  = "Allow"
    actions = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
    # "*" covers both the export S3 key and any source snapshot encryption keys
    resources = ["*"]
  }
}

resource "aws_iam_policy" "policy" {
  name   = "${var.role_name}-policy"
  policy = data.aws_iam_policy_document.policy.json
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.role.name
  policy_arn = aws_iam_policy.policy.arn
}

# KMS grants are not created here — the key policy already grants the necessary
# permissions to rds.amazonaws.com, export.rds.amazonaws.com, and the root account.
