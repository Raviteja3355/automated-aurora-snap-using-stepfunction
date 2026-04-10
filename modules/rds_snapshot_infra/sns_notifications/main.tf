resource "aws_sns_topic" "topic" {
  name = var.topic_name
}

# Email subscription is optional — only created when notification_email is non-empty.
# The SNS topic itself is always created because CloudWatch alarms use it for alarm_actions.
resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.topic.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
