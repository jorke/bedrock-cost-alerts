# Infra for bedrock_cost_guard.py (place this file next to the script):
#   - Scope: services "Amazon Bedrock" and "Amazon Bedrock Service", charge
#     type Usage only (credits, refunds, tax excluded), unblended cost
#   - SNS topic (+ policy for Budgets / Cost Anomaly Detection) and email subscription
#   - Daily AWS Budget filtered on that scope
#   - Cost Anomaly Detection monitor on cost category "bedrock-usage" (same scope)
#   - Lambda + EventBridge schedule that runs the script daily to retune
#     both thresholds to 1.5x the median of the last 7 days of usage
#
# Terraform owns the resources; the script owns the threshold values, hence
# the ignore_changes blocks.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.40" }
    archive = { source = "hashicorp/archive", version = ">= 2.4" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "alert_email" {
  type        = string
  description = "Email that receives budget and anomaly alerts."
}

variable "initial_daily_budget" {
  type = number
  # default     = 1
  description = "Starting daily limit (USD). The Lambda retunes it after the first run."
}

variable "bedrock_services" {
  type        = list(string)
  default     = ["Amazon Bedrock", "Amazon Bedrock Service"]
  description = "Cost Explorer SERVICE names. Used by the budget and the script."
}

variable "bedrock_service_codes" {
  type = list(string)
  # Codes for the same services as bedrock_services. The anomaly monitor's
  # cost category can only match on SERVICE_CODE.
  default     = ["AmazonBedrock", "AmazonBedrockService"]
  description = "Service codes for the anomaly monitor's cost category."
}

variable "initial_anomaly_impact" {
  type        = number
  default     = 20
  description = "Starting anomaly impact threshold (USD). Retuned by the Lambda."
}

variable "lookback_days" {
  type    = number
  default = 7
}

variable "multiplier" {
  type        = number
  default     = 1.5
  description = "Alert when a day exceeds this multiple of the median daily usage."
}

variable "max_change_per_run" {
  type    = number
  default = 0.5
}

variable "schedule_expression" {
  type        = string
  default     = "cron(0 20 * * ? *)" # 20:00 UTC = 07:00 Sydney (AEDT)
  description = "EventBridge schedule for threshold retuning."
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  cost_category       = "bedrock-usage"
  cost_category_value = "bedrock"
  budget_name         = "bedrock-daily-spend"
  subscription_name   = "bedrock-spend-anomaly-alerts"
}

# --------------------------------------------------------------------------- #
# Cost category for the anomaly monitor: Bedrock services, usage charges only
# --------------------------------------------------------------------------- #
resource "aws_ce_cost_category" "bedrock" {
  name          = local.cost_category
  rule_version  = "CostCategoryExpression.v1"
  default_value = "other"

  rule {
    value = local.cost_category_value
    rule {
      and {
        dimension {
          key           = "SERVICE_CODE"
          values        = var.bedrock_service_codes
          match_options = ["EQUALS"] # SERVICE_CODE doesn't support CONTAINS
        }
      }
      and {
        dimension {
          key           = "RECORD_TYPE"
          values        = ["Usage"]
          match_options = ["EQUALS"]
        }
      }
    }
  }
}

# --------------------------------------------------------------------------- #
# SNS
# --------------------------------------------------------------------------- #
resource "aws_sns_topic" "alerts" {
  name = "bedrock-cost-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "sns_publish" {
  statement {
    sid       = "AllowBudgetsAndCostAnomaly"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com", "costalerts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns_publish.json
}

# --------------------------------------------------------------------------- #
# Daily budget
# --------------------------------------------------------------------------- #
resource "aws_budgets_budget" "bedrock_daily" {
  name         = local.budget_name
  budget_type  = "COST"
  time_unit    = "DAILY"
  limit_amount = tostring(var.initial_daily_budget)
  limit_unit   = "USD"
  metrics      = ["UnblendedCost"]

  # Same scope as the Cost Explorer view: Bedrock services, usage charges only.
  filter_expression {
    and {
      dimensions {
        key           = "SERVICE"
        values        = var.bedrock_services
        match_options = ["EQUALS"]
      }
    }
    and {
      dimensions {
        key           = "RECORD_TYPE"
        values        = ["Usage"]
        match_options = ["EQUALS"]
      }
    }
  }

  # DAILY budgets only support ACTUAL notifications.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  # The Lambda retunes the limit.
  lifecycle {
    ignore_changes = [limit_amount]
  }

  depends_on = [aws_sns_topic_policy.alerts]
}

# --------------------------------------------------------------------------- #
# Cost Anomaly Detection
# --------------------------------------------------------------------------- #
resource "aws_ce_anomaly_monitor" "bedrock" {
  name         = "bedrock-spend-monitor"
  monitor_type = "CUSTOM"

  # Custom monitors can't filter on SERVICE; scope through the cost category.
  monitor_specification = jsonencode({
    CostCategories = {
      Key    = aws_ce_cost_category.bedrock.name
      Values = [local.cost_category_value]
    }
  })
}

resource "aws_ce_anomaly_subscription" "bedrock" {
  name             = local.subscription_name
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.bedrock.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.initial_anomaly_impact)]
    }
  }

  # The Lambda retunes the threshold.
  lifecycle {
    ignore_changes = [threshold_expression]
  }

  depends_on = [aws_sns_topic_policy.alerts]
}

# --------------------------------------------------------------------------- #
# Lambda that runs bedrock_cost_guard.py on a schedule
# --------------------------------------------------------------------------- #
data "archive_file" "lambda" {
  type        = "zip"
  output_path = "${path.module}/.build/bedrock_cost_guard.zip"

  source {
    content  = file("${path.module}/bedrock_cost_guard.py")
    filename = "bedrock_cost_guard.py"
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "bedrock-cost-guard-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    sid       = "ReadCosts"
    actions   = ["ce:GetCostAndUsage", "ce:GetAnomalySubscriptions"]
    resources = ["*"]
  }

  statement {
    sid       = "TuneAnomalyAlert"
    actions   = ["ce:UpdateAnomalySubscription"]
    resources = [aws_ce_anomaly_subscription.bedrock.arn]
  }

  statement {
    sid       = "TuneBudget"
    actions   = ["budgets:ViewBudget", "budgets:ModifyBudget"]
    resources = [aws_budgets_budget.bedrock_daily.arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "bedrock-cost-guard"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/bedrock-cost-guard"
  retention_in_days = 30
}

resource "aws_lambda_function" "guard" {
  function_name    = "bedrock-cost-guard"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "bedrock_cost_guard.handler"
  timeout          = 120
  memory_size      = 256
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      LOOKBACK_DAYS       = tostring(var.lookback_days)
      MULTIPLIER          = tostring(var.multiplier)
      MAX_CHANGE          = tostring(var.max_change_per_run)
      BEDROCK_SERVICES    = join(",", var.bedrock_services)
      BUDGET_NAME         = aws_budgets_budget.bedrock_daily.name
      SUBSCRIPTION_NAME   = aws_ce_anomaly_subscription.bedrock.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]
}

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "bedrock-cost-guard-schedule"
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.schedule.name
  arn  = aws_lambda_function.guard.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.guard.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}

# --------------------------------------------------------------------------- #
output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "lambda_name" {
  value = aws_lambda_function.guard.function_name
}
