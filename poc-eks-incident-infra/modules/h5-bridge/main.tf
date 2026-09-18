################################################################################
# H5 Bridge — DevOps Agent → Kiro Crew 연결
#
# 흐름:
#   [도쿄] EventBridge 규칙 (aws.aidevops, Investigation Completed/Failed)
#     → [서울] SNS 토픽
#     → h5-notifier Lambda: Slack에 Block Kit 버튼 메시지 발송
#     → 사용자가 [승인] 클릭
#     → h5-approver Lambda (Function URL): rollout undo 실행 → Slack 결과 회신
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

# EventBridge(서울 규칙)가 서울 SNS에 Publish할 수 있도록 리소스 정책 추가
resource "aws_sns_topic_policy" "h5_bridge" {
  arn = aws_sns_topic.h5_bridge.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.h5_bridge.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rule/*"
          }
        }
      }
    ]
  })
}

# ── 공통 IAM 역할 ─────────────────────────────────────────────────────────────
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

resource "aws_iam_role_policy" "h5_lambda_permissions" {
  name = "h5-lambda-permissions"
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
        Sid    = "SlackTokenRead"
        Effect = "Allow"
        Action = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:kiro-crew/*"
      },
      {
        # Crew operator 역할 AssumeRole (rollout undo용, 세션 15분)
        Sid    = "AssumeCrewOperator"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = var.crew_operator_role_arn
      }
    ]
  })
}

# ── h5-notifier Lambda: SNS → Slack Block Kit 버튼 메시지 ────────────────────
data "archive_file" "h5_notifier" {
  type        = "zip"
  output_path = "${path.module}/notifier.zip"

  source {
    content  = <<-PYTHON
import json
import boto3
import os
import logging
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION        = os.environ['AWS_REGION_NAME']
SLACK_SECRET  = os.environ['SLACK_SECRET_ID']
SLACK_CHANNEL = os.environ['SLACK_CHANNEL_ID']

def get_bot_token():
    client = boto3.client('secretsmanager', region_name=REGION)
    resp = client.get_secret_value(SecretId=SLACK_SECRET)
    return json.loads(resp['SecretString'])['SLACK_BOT_TOKEN']

def post_to_slack(token, payload):
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(
        'https://slack.com/api/chat.postMessage',
        data=data,
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
        # 조치 정보 (DevOps Agent가 제안하는 remediation)
        remediation      = detail.get('findings', {}).get('remediation', '')
        namespace        = detail.get('metadata', {}).get('namespace', 'poc')
        deployment       = detail.get('metadata', {}).get('deployment_name', '')

        if detail_type == 'Investigation Completed':
            # Block Kit: 텍스트 + 승인 버튼
            action_value = json.dumps({
                "investigation_id": investigation_id,
                "namespace": namespace,
                "deployment": deployment,
                "channel": SLACK_CHANNEL,
            })
            blocks = [
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": (
                            f":white_check_mark: *DevOps Agent 조사 완료*\n"
                            f">*Investigation ID:* `{investigation_id}`\n"
                            f">*Status:* {status}\n"
                            f">*Summary:* {findings_summary}"
                            + (f"\n>*Remediation:* {remediation}" if remediation else "")
                        )
                    }
                },
            ]
            # deployment 정보가 있을 때만 승인 버튼 추가
            if deployment:
                blocks.append({
                    "type": "actions",
                    "elements": [
                        {
                            "type": "button",
                            "text": {"type": "plain_text", "text": f"✅ rollout undo ({deployment})"},
                            "style": "primary",
                            "action_id": "approve_rollback",
                            "value": action_value,
                            "confirm": {
                                "title": {"type": "plain_text", "text": "롤백 실행 확인"},
                                "text": {"type": "mrkdwn", "text": f"`kubectl rollout undo deployment/{deployment} -n {namespace}` 를 실행합니다."},
                                "confirm": {"type": "plain_text", "text": "실행"},
                                "deny": {"type": "plain_text", "text": "취소"},
                            }
                        },
                        {
                            "type": "button",
                            "text": {"type": "plain_text", "text": "❌ 무시"},
                            "action_id": "dismiss_action",
                            "value": investigation_id,
                        }
                    ]
                })
            payload = {"channel": SLACK_CHANNEL, "blocks": blocks, "text": f"DevOps Agent 조사 완료: {investigation_id}"}

        elif detail_type == 'Investigation Failed':
            payload = {
                "channel": SLACK_CHANNEL,
                "text": (
                    f":x: *DevOps Agent 조사 실패*\n"
                    f">*Investigation ID:* `{investigation_id}`\n"
                    f">상세: {json.dumps(detail, ensure_ascii=False)[:400]}"
                )
            }
        else:
            payload = {
                "channel": SLACK_CHANNEL,
                "text": f":bell: *DevOps Agent 이벤트:* {detail_type}\n>{json.dumps(detail, ensure_ascii=False)[:400]}"
            }

        result = post_to_slack(token, payload)
        logger.info("Slack post result ts=%s", result.get('ts'))

    return {"statusCode": 200}
PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "h5_notifier" {
  function_name    = "${var.project}-h5-bridge"  # 기존 이름 유지 (SNS subscription 변경 불필요)
  role             = aws_iam_role.h5_lambda.arn
  handler          = "index.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.h5_notifier.output_path
  source_code_hash = data.archive_file.h5_notifier.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      AWS_REGION_NAME  = data.aws_region.current.name
      SLACK_SECRET_ID  = var.slack_secret_id
      SLACK_CHANNEL_ID = var.slack_channel_id
    }
  }
}

# SNS → notifier Lambda 트리거
resource "aws_sns_topic_subscription" "h5_lambda" {
  topic_arn = aws_sns_topic.h5_bridge.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.h5_notifier.arn
}

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.h5_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.h5_bridge.arn
}

# ── 크로스 리전 EventBridge (도쿄 → 서울) ────────────────────────────────────
# EventBridge는 다른 리전의 SNS를 직접 타겟으로 지원하지 않는다.
# 크로스 리전은 "다른 리전의 이벤트 버스"로만 네이티브 전달 가능하므로,
# 도쿄 규칙 → 서울 default 버스 → 서울 규칙 → SNS 2단 구성으로 처리한다.
#
#   [도쿄] rule(aws.aidevops) → [서울] default event bus
#   [서울] rule(aws.aidevops) → SNS 토픽

# 서울 default 이벤트 버스 ARN
data "aws_cloudwatch_event_bus" "seoul_default" {
  name = "default"
}

# ── [도쿄] 규칙: aws.aidevops 이벤트를 서울 이벤트 버스로 전달 ───────────────
resource "aws_cloudwatch_event_rule" "tokyo_forward" {
  provider    = aws.tokyo
  name        = "${var.project}-investigation-forward"
  description = "DevOps Agent 조사 이벤트를 서울 이벤트 버스로 크로스 리전 전달"

  event_pattern = jsonencode({
    source        = ["aws.aidevops"]
    "detail-type" = ["Investigation Completed", "Investigation Failed"]
    detail = {
      metadata = {
        agent_space_id = [var.agent_space_id]
      }
    }
  })
}

# 크로스 리전 전달에는 EventBridge가 대상 버스에 PutEvents 할 IAM 역할이 필요
resource "aws_iam_role" "eventbridge_crossregion" {
  name = "${var.project}-eventbridge-crossregion"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_crossregion" {
  name = "put-events-seoul"
  role = aws_iam_role.eventbridge_crossregion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = data.aws_cloudwatch_event_bus.seoul_default.arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "tokyo_to_seoul_bus" {
  provider  = aws.tokyo
  rule      = aws_cloudwatch_event_rule.tokyo_forward.name
  target_id = "ToSeoulBus"
  arn       = data.aws_cloudwatch_event_bus.seoul_default.arn
  role_arn  = aws_iam_role.eventbridge_crossregion.arn
}

# ── [서울] 규칙: 전달받은 aws.aidevops 이벤트를 SNS로 라우팅 ──────────────────
resource "aws_cloudwatch_event_rule" "seoul_to_sns" {
  name        = "${var.project}-investigation-completed"
  description = "서울로 전달된 DevOps Agent 조사 이벤트를 SNS로 라우팅"

  event_pattern = jsonencode({
    source        = ["aws.aidevops"]
    "detail-type" = ["Investigation Completed", "Investigation Failed"]
    detail = {
      metadata = {
        agent_space_id = [var.agent_space_id]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "seoul_sns" {
  rule      = aws_cloudwatch_event_rule.seoul_to_sns.name
  target_id = "ToSNS"
  arn       = aws_sns_topic.h5_bridge.arn
}
