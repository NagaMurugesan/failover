##########################
# Providers
##########################

provider "aws" {
  region = "us-east-1"  # default provider
}

provider "aws" {
  alias  = "primary"
  region = "us-east-1"
}

provider "aws" {
  alias  = "secondary"
  region = "us-west-2"
}

provider "aws" {
  alias  = "central"
  region = "us-east-2"
}

##########################
# Variables
##########################

variable "domain_name" { default = "example.com" }
variable "record_name" { default = "www" }
variable "sns_email" { default = "ops@example.com" }

variable "primary_alb_dns" {}
variable "primary_alb_zone_id" {}
variable "secondary_alb_dns" {}
variable "secondary_alb_zone_id" {}
variable "heartbeat_interval_sec" { default = 60 }

##########################
# SNS Topic
##########################

resource "aws_sns_topic" "failover_alerts" {
  provider = aws.central
  name = "failover-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  provider = aws.central
  topic_arn = aws_sns_topic.failover_alerts.arn
  protocol  = "email"
  endpoint  = var.sns_email
}

##########################
# SSM Parameters
##########################

resource "aws_ssm_parameter" "primary_alb_dns" {
  provider = aws.central
  name  = "/failover/primary_alb_dns"
  type  = "String"
  value = var.primary_alb_dns
}

resource "aws_ssm_parameter" "primary_alb_zone" {
  provider = aws.central
  name  = "/failover/primary_alb_zone"
  type  = "String"
  value = var.primary_alb_zone_id
}

resource "aws_ssm_parameter" "secondary_alb_dns" {
  provider = aws.central
  name  = "/failover/secondary_alb_dns"
  type  = "String"
  value = var.secondary_alb_dns
}

resource "aws_ssm_parameter" "secondary_alb_zone" {
  provider = aws.central
  name  = "/failover/secondary_alb_zone"
  type  = "String"
  value = var.secondary_alb_zone_id
}

resource "aws_ssm_parameter" "manual_switch" {
  provider = aws.central
  name  = "/failover/manual_switch"
  type  = "String"
  value = "AUTO" # PRIMARY, SECONDARY, AUTO
}

##########################
# Heartbeat Lambda IAM Role + Policy
##########################

data "aws_iam_policy_document" "heartbeat_lambda" {
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "heartbeat_lambda_role" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  name = "heartbeat-lambda-role"
}

resource "aws_iam_role_policy" "heartbeat_lambda_policy" {
  role   = aws_iam_role.heartbeat_lambda_role.id
  policy = data.aws_iam_policy_document.heartbeat_lambda.json
}

##########################
# Heartbeat Lambda - Primary
##########################

resource "aws_lambda_function" "heartbeat_primary" {
  provider = aws.primary
  function_name = "heartbeat-primary"
  handler       = "heartbeat.lambda_handler"
  runtime       = "python3.11"
  role          = aws_iam_role.heartbeat_lambda_role.arn
  filename      = "heartbeat.zip"
  environment {
    variables = {
      REGION      = "us-east-1"
      METRIC_NAME = "RegionHealth"
      NAMESPACE   = "Failover"
    }
  }
}

resource "aws_cloudwatch_event_rule" "heartbeat_rule_primary" {
  provider = aws.primary
  name                = "heartbeat-rule-primary"
  schedule_expression = "rate(${var.heartbeat_interval_sec} seconds)"
}

resource "aws_cloudwatch_event_target" "heartbeat_target_primary" {
  provider = aws.primary
  rule      = aws_cloudwatch_event_rule.heartbeat_rule_primary.name
  target_id = "heartbeat-lambda"
  arn       = aws_lambda_function.heartbeat_primary.arn
}

resource "aws_lambda_permission" "allow_eventbridge_primary" {
  provider = aws.primary
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.heartbeat_primary.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.heartbeat_rule_primary.arn
}

##########################
# Heartbeat Lambda - Secondary
##########################

resource "aws_lambda_function" "heartbeat_secondary" {
  provider = aws.secondary
  function_name = "heartbeat-secondary"
  handler       = "heartbeat.lambda_handler"
  runtime       = "python3.11"
  role          = aws_iam_role.heartbeat_lambda_role.arn
  filename      = "heartbeat.zip"
  environment {
    variables = {
      REGION      = "us-west-2"
      METRIC_NAME = "RegionHealth"
      NAMESPACE   = "Failover"
    }
  }
}

resource "aws_cloudwatch_event_rule" "heartbeat_rule_secondary" {
  provider = aws.secondary
  name                = "heartbeat-rule-secondary"
  schedule_expression = "rate(${var.heartbeat_interval_sec} seconds)"
}

resource "aws_cloudwatch_event_target" "heartbeat_target_secondary" {
  provider = aws.secondary
  rule      = aws_cloudwatch_event_rule.heartbeat_rule_secondary.name
  target_id = "heartbeat-lambda"
  arn       = aws_lambda_function.heartbeat_secondary.arn
}

resource "aws_lambda_permission" "allow_eventbridge_secondary" {
  provider = aws.secondary
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.heartbeat_secondary.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.heartbeat_rule_secondary.arn
}

##########################
# CloudWatch Alarm - Primary Region
##########################

resource "aws_cloudwatch_metric_alarm" "primary_down" {
  provider = aws.central
  alarm_name          = "PrimaryRegionDown"
  alarm_description   = "Triggers if primary region heartbeat metric missing"
  namespace           = "Failover"
  metric_name         = "RegionHealth"
  dimensions          = { Region = "us-east-1" }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.failover_alerts.arn]
}

##########################
# Failover Lambda IAM Role + Policy
##########################

resource "aws_iam_role" "failover_lambda_role" {
  provider = aws.central
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "failover_basic" {
  provider   = aws.central
  role       = aws_iam_role.failover_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "failover_policy" {
  provider = aws.central
  role = aws_iam_role.failover_lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = ["route53:ChangeResourceRecordSets","ssm:GetParameter"], Resource = "*" },
      { Effect = "Allow", Action = ["logs:*"], Resource = "*" }
    ]
  })
}

##########################
# Failover Lambda
##########################

resource "aws_lambda_function" "failover" {
  provider = aws.central
  function_name = "failover-controller"
  handler       = "failover.lambda_handler"
  runtime       = "python3.11"
  role          = aws_iam_role.failover_lambda_role.arn
  filename      = "failover.zip"
  environment {
    variables = {
      HOSTED_ZONE_ID      = aws_ssm_parameter.primary_alb_zone.value
      PRIMARY_ALB_DNS     = aws_ssm_parameter.primary_alb_dns.value
      SECONDARY_ALB_DNS   = aws_ssm_parameter.secondary_alb_dns.value
      MANUAL_SWITCH_PARAM = aws_ssm_parameter.manual_switch.name
      RECORD_NAME         = "${var.record_name}.${var.domain_name}"
    }
  }
}

resource "aws_lambda_permission" "allow_sns" {
  provider = aws.central
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.failover_alerts.arn
}

##########################
# Route53 Hosted Zone + Failover Records
##########################

resource "aws_route53_zone" "main" {
  name = var.domain_name
}

resource "aws_route53_record" "www_primary" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "${var.record_name}.${var.domain_name}"
  type    = "A"
  set_identifier = "primary"
  #failover = "PRIMARY"
  alias {
    name                   = var.primary_alb_dns
    zone_id                = var.primary_alb_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www_secondary" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "${var.record_name}.${var.domain_name}"
  type    = "A"
  set_identifier = "secondary"
  #failover = "SECONDARY"
  alias {
    name                   = var.secondary_alb_dns
    zone_id                = var.secondary_alb_zone_id
    evaluate_target_health = false
  }
}
