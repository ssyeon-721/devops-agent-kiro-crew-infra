################################################################################
# H5 Bridge — DevOps Agent → Kiro Crew 연결
#
# 흐름:
#   [도쿄] EventBridge 규칙 (aws.aidevops, Investigation Completed/Failed)
#     → [서울] SNS 토픽
#     → Lambda (Crew EC2에 SSM SendCommand로 알림 전달)
#
# 크로스 리전 구성:
#   - EventBridge 규칙: 도쿄(ap-northeast-1) default 버스
#   - SNS / Lambda / IAM: 서울(ap-northeast-2)
################################################################################

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.50"
      configuration_aliases = [aws.tokyo]
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── 서울 SNS 토픽 (Lambda 트리거용) ─────────────────────────────────────────
resource "aws_sns_topic" "h5_bridge" {
  name = "${var.project}-h5-bridge"
}

# EventBridge(도쿄)가 서울 SNS에 Publish할 수 있도록 리소스 정책 추가
resource "aws_sns_topic_policy" "h5_bridge" {
  arn = aws_sns_topic.h5_bridge.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgeCrossRegion"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.h5_bridge.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:events:ap-northeast-1:${data.aws_caller_identity.current.account_id}:rule/*"
          }
        }
      }
    ]
  })
}

# ── Lambda 실행 역할 ─────────────────────────────────────────────────────────
resource "aws_iam_role" "h5_lambda" {
  name = "${var.project}-h5-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "h5_lambda_basic" {
  role       = aws_iam_role.h5_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "h5_lambda_ssm" {
  name = "ssm-send-command"
  role = aws_iam_role.h5_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMSendToCrewEC2"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
        ]
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${var.crew_instance_id}",
          "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript",
        ]
      },
      {
        # Slack Bot Token 조회
        Sid    = "SlackTokenRead"
        Effect = "Allow"
        Action = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:kiro-crew/*"
      }
    ]
  })
}

# ── Lambda 함수 ───────────────────────────────────────────────────────────────
# SNS 메시지(DevOps Agent 조사 결과)를 받아 Crew EC2에 SSM으로 전달
# Crew는 메시지를 받아 Slack으로 알림

data "archive_file" "h5_lambda" {
  type        = "zip"
  output_path = "${path.module}/lambda.zip"

  source {
    content  = <<-PYTHON
import json
import boto3
import os
import logging
import urllib.request
import urllib.parse

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION        = os.environ['AWS_REGION_NAME']
SLACK_SECRET  = os.environ['SLACK_SECRET_ID']
SLACK_CHANNEL = os.environ['SLACK_CHANNEL_ID']

def get_bot_token():
    client = boto3.client('secretsmanager', region_name=REGION)
    resp = client.get_secret_value(SecretId=SLACK_SECRET)
    secret = json.loads(resp['SecretString'])
    return secret['SLACK_BOT_TOKEN']

def post_to_slack(token, channel, text):
    payload = json.dumps({
        "channel": channel,
        "text": text,
        "unfurl_links": False,
    }).encode('utf-8')
    req = urllib.request.Request(
        'https://slack.com/api/chat.postMessage',
        data=payload,
        headers={
            'Content-Type': 'application/json; charset=utf-8',
            'Authorization': f'Bearer {token}',
        },
        method='POST',
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read())
    if not body.get('ok'):
        raise RuntimeError(f"Slack API error: {body.get('error')}")
    return body

def lambda_handler(event, context):
    logger.info("Received event: %s", json.dumps(event))

    token = get_bot_token()

    for record in event.get('Records', []):
        message_str = record['Sns']['Message']
        try:
            message = json.loads(message_str)
        except Exception:
            message = {"raw": message_str}

        detail_type      = message.get('detail-type', 'Unknown')
        detail           = message.get('detail', {})
        investigation_id = detail.get('metadata', {}).get('investigation_id', 'N/A')
        status           = detail.get('status', '')
        findings_summary = detail.get('findings', {}).get('summary', '')

        if detail_type == 'Investigation Completed':
            text = (
                f":white_check_mark: *DevOps Agent 조사 완료*\n"
                f">*Investigation ID:* `{investigation_id}`\n"
                f">*Status:* {status}\n"
                f">*Summary:* {findings_summary}"
            )
        elif detail_type == 'Investigation Failed':
            text = (
                f":x: *DevOps Agent 조사 실패*\n"
                f">*Investigation ID:* `{investigation_id}`\n"
                f">상세: {json.dumps(detail, ensure_ascii=False)[:400]}"
            )
        else:
            text = f":bell: *DevOps Agent 이벤트:* {detail_type}\n>{json.dumps(detail, ensure_ascii=False)[:400]}"

        result = post_to_slack(token, SLACK_CHANNEL, text)
        logger.info("Slack post result: %s", result)

    return {"statusCode": 200}
PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "h5_bridge" {
  function_name    = "${var.project}-h5-bridge"
  role             = aws_iam_role.h5_lambda.arn
  handler          = "index.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.h5_lambda.output_path
  source_code_hash = data.archive_file.h5_lambda.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      AWS_REGION_NAME  = data.aws_region.current.name
      SLACK_SECRET_ID  = var.slack_secret_id
      SLACK_CHANNEL_ID = var.slack_channel_id
    }
  }
}

# SNS → Lambda 트리거
resource "aws_sns_topic_subscription" "h5_lambda" {
  topic_arn = aws_sns_topic.h5_bridge.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.h5_bridge.arn
}

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.h5_bridge.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.h5_bridge.arn
}

# ── 도쿄 EventBridge 규칙 ─────────────────────────────────────────────────────
# 도쿄 리전에 규칙을 만들어야 하므로 별도 provider alias 사용
resource "aws_cloudwatch_event_rule" "investigation_completed" {
  provider    = aws.tokyo
  name        = "${var.project}-investigation-completed"
  description = "DevOps Agent 조사 완료/실패 이벤트를 서울 Crew로 전달"

  event_pattern = jsonencode({
    source      = ["aws.aidevops"]
    "detail-type" = ["Investigation Completed", "Investigation Failed"]
    detail = {
      metadata = {
        agent_space_id = [var.agent_space_id]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "to_seoul_sns" {
  provider  = aws.tokyo
  rule      = aws_cloudwatch_event_rule.investigation_completed.name
  target_id = "ToSeoulSNS"
  arn       = aws_sns_topic.h5_bridge.arn
}
