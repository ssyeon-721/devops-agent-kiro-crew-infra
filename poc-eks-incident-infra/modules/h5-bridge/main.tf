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
        # 조사 요약 저널 레코드 조회 (도쿄 aidevops)
        Sid    = "DevOpsAgentJournalRead"
        Effect = "Allow"
        Action = [
          "aidevops:ListJournalRecords",
        ]
        Resource = "*"
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
AGENT_REGION  = os.environ['AGENT_REGION']   # 도쿄
SLACK_SECRET  = os.environ['SLACK_SECRET_ID']
SLACK_CHANNEL = os.environ['SLACK_CHANNEL_ID']

aidevops = boto3.client('devops-agent', region_name=AGENT_REGION)

def get_bot_token():
    client = boto3.client('secretsmanager', region_name=REGION)
    resp = client.get_secret_value(SecretId=SLACK_SECRET)
    return json.loads(resp['SecretString'])['SLACK_BOT_TOKEN']

def fetch_summary(agent_space_id, execution_id):
    """ListJournalRecords로 investigation_summary_md content 조회"""
    try:
        resp = aidevops.list_journal_records(
            agentSpaceId=agent_space_id,
            executionId=execution_id,
        )
    except Exception as e:
        logger.error("list_journal_records EXCEPTION: %s", e)
        return None
    records = resp.get('records', resp.get('journalRecords', []))
    logger.info("records count=%d, resp keys=%s", len(records), list(resp.keys()))
    for rec in records:
        # boto3 필드명이 recordType 또는 record_type일 수 있어 둘 다 확인
        rtype = rec.get('recordType') or rec.get('record_type', '')
        if rtype == 'investigation_summary_md':
            return rec.get('content', '')
    return None

def parse_summary(md):
    """investigation_summary_md에서 핵심 필드 추출 (Symptoms/Findings/Root Cause)"""
    if not md:
        return {}
    out = {}
    # 간단한 마크다운 헤더 기반 추출
    lines = md.split('\n')
    section = None
    buf = {}
    for ln in lines:
        s = ln.strip()
        if s.startswith('### Cause:') or s.startswith('### Root Cause:'):
            key = 'root_cause' if 'Root Cause' in s else 'cause'
            buf.setdefault(key, s.split(':', 1)[1].strip())
        elif s.startswith('### ') and 'stuck' in s.lower() or s.startswith('### web') :
            buf.setdefault('symptom', s.lstrip('# ').strip())
    return buf

def post_to_slack(token, text):
    payload = json.dumps({"channel": SLACK_CHANNEL, "text": text, "unfurl_links": False}).encode('utf-8')
    req = urllib.request.Request(
        'https://slack.com/api/chat.postMessage',
        data=payload,
        headers={'Content-Type': 'application/json; charset=utf-8', 'Authorization': f'Bearer {token}'},
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
        try:
            message = json.loads(record['Sns']['Message'])
        except Exception:
            logger.error("Failed to parse SNS message")
            continue

        detail_type = message.get('detail-type', 'Unknown')
        detail      = message.get('detail', {})
        metadata    = detail.get('metadata', {})
        data        = detail.get('data', {})

        agent_space_id = metadata.get('agent_space_id', '')
        execution_id   = metadata.get('execution_id', '')
        task_id        = metadata.get('task_id', '')
        status         = data.get('status', '')
        priority       = data.get('priority', '')

        if detail_type == 'Investigation Completed':
            summary_md = fetch_summary(agent_space_id, execution_id)
            if summary_md:
                # 요약 마크다운을 그대로 싣되 Slack 길이 제한 고려(3000자)
                body = summary_md.strip()
                if len(body) > 2500:
                    body = body[:2500] + "\n... (요약 일부 생략)"
                text = (
                    f":white_check_mark: *DevOps Agent 조사 완료* (priority: {priority})\n"
                    f"```{body}```\n"
                    f":point_right: 조치가 필요하면 봇에게 멘션으로 "
                    f"`@kiro-crew-bot web-poc 롤백해줘` 라고 요청하세요. "
                    f"승인 즉시 Crew가 `rollout undo`를 실행합니다."
                )
            else:
                text = (
                    f":white_check_mark: *DevOps Agent 조사 완료* (priority: {priority})\n"
                    f">조사 요약을 가져오지 못했습니다. task_id=`{task_id}`, execution_id=`{execution_id}`\n"
                    f">도쿄 콘솔에서 직접 확인하세요."
                )
            post_to_slack(token, text)
            logger.info("Posted summary to Slack for exec=%s", execution_id)

        elif detail_type == 'Investigation Failed':
            text = (
                f":x: *DevOps Agent 조사 실패* (status: {status})\n"
                f">task_id=`{task_id}` — 수동 확인이 필요합니다."
            )
            post_to_slack(token, text)
            logger.info("Posted failure to Slack task=%s", task_id)
        else:
            logger.info("Ignoring detail-type: %s", detail_type)

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
      AGENT_REGION     = "ap-northeast-1"
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
