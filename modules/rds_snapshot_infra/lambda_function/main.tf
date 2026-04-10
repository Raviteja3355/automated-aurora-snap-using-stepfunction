data "archive_file" "zip" {
  type        = "zip"
  source_file = var.source_file
  output_path = "${path.root}/${var.function_name}.zip"
}

resource "aws_lambda_function" "lambda" {
  function_name    = var.function_name
  role             = var.role_arn
  handler          = var.handler
  runtime          = var.runtime
  filename         = data.archive_file.zip.output_path
  source_code_hash = data.archive_file.zip.output_base64sha256
  timeout          = var.timeout
  memory_size      = var.memory_size

  environment { variables = var.env_vars }

  dynamic "dead_letter_config" {
    for_each = var.dlq_arn != "" ? [var.dlq_arn] : []
    content {
      target_arn = dead_letter_config.value
    }
  }
}
