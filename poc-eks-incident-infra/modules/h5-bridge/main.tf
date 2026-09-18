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
        # Crew에게 "조사요약 조회+한국어 요약+send_message 채널 게시"를 SSM으로 지시
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
import base64

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION           = os.environ['AWS_REGION_NAME']
AGENT_REGION     = os.environ['AGENT_REGION']       # 도쿄
CREW_INSTANCE_ID = os.environ['CREW_INSTANCE_ID']
SLACK_CHANNEL    = os.environ['SLACK_CHANNEL_ID']

ssm = boto3.client('ssm', region_name=REGION)

def instruct_crew(prompt):
    """Crew에게 SSM으로 spawn 지시. Crew가 요약+send_message 채널 게시를 자율 수행."""
    b64 = base64.b64encode(prompt.encode('utf-8')).decode('ascii')
    cmd = (
        f"echo {b64} | base64 -d > /tmp/h5_prompt.txt && "
        f"chown kirocrew:kirocrew /tmp/h5_prompt.txt && "
        f"sudo -u kirocrew -H bash -l -c 'kirocrew spawn run --async \"$(cat /tmp/h5_prompt.txt)\"'"
    )
    resp = ssm.send_command(
        InstanceIds=[CREW_INSTANCE_ID],
        DocumentName='AWS-RunShellScript',
        Parameters={'commands': [cmd]},
        Comment='H5 investigation summary via Crew send_message',
    )
    return resp['Command']['CommandId']

def lambda_handler(event, context):
    logger.info("Received event: %s", json.dumps(event))

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
            prompt = (
                f"DevOps Agent 조사가 완료됐어(priority={priority}). 다음을 순서대로 해줘. "
                f"1) 조사 요약 조회: aws devops-agent list-journal-records --region {AGENT_REGION} "
                f"--agent-space-id {agent_space_id} --execution-id {execution_id} 를 실행하고, "
                f"결과 JSON에서 recordType이 'investigation_summary_md'인 레코드의 content가 핵심 요약이야. "
                f"2) 그 내용을 한국어로 '증상/원인/근본원인/권고' 4개 항목으로 각 1~2문장씩 자연스럽게 요약해. "
                f"각 항목은 마크다운 볼드(*증상* 등)로 표시하고 전체 700자 이내로 압축해. "
                f"3) 요약 맨 끝에 '롤백이 필요하면 @kiro-crew-bot 에게 web-poc 롤백해줘 라고 요청하세요.'를 덧붙여. "
                f"4) 완성한 한국어 요약을 send_message 도구로 Slack 채널 {SLACK_CHANNEL}에 게시해. "
                f"(curl이나 aws cli 말고 반드시 send_message 도구를 사용)"
            )
            cmd_id = instruct_crew(prompt)
            logger.info("Crew instructed(summary+send) cmd=%s exec=%s", cmd_id, execution_id)

        elif detail_type == 'Investigation Failed':
            prompt = (
                f"DevOps Agent 조사가 실패했어(status={status}, task_id={task_id}). "
                f"send_message 도구로 Slack 채널 {SLACK_CHANNEL}에 "
                f"'⚠️ DevOps Agent 조사 실패 - 수동 확인 필요 (task {task_id})'를 한국어로 게시해. "
                f"(반드시 send_message 도구 사용)"
            )
            cmd_id = instruct_crew(prompt)
            logger.info("Crew instructed(failure+send) cmd=%s", cmd_id)
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
      CREW_INSTANCE_ID = var.crew_instance_id
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
