#!/usr/bin/env bash
# 시나리오 3 — 환경변수 오설정 (잘못된 DB_HOST)
#
# 정답: 환경변수 오설정 — DB_HOST DNS 해석 실패
# 결정적 신호: previous 로그의 "DB_HOST DNS resolution FAILED" 메시지
set -euo pipefail

NAMESPACE="poc"
DEPLOYMENT="web-poc"
RUN_ID="${RUN_ID:-S03-$(date +%Y%m%dT%H%M%S)}"
BAD_HOST="nonexistent-db.invalid"

echo "=== [${RUN_ID}] 시나리오 3 주입 시작 ==="
echo "  주입 시각: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  ground_truth: env misconfiguration DB_HOST=${BAD_HOST}"

kubectl -n "$NAMESPACE" set env "deployment/$DEPLOYMENT" \
  "DB_HOST=${BAD_HOST}"

kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=60s

echo "=== [${RUN_ID}] 주입 완료 — Pod CrashLoopBackOff 대기 ==="
echo "  채점 기록:"
echo "    run_id: ${RUN_ID}"
echo "    injected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "    ground_truth: env misconfiguration (DB_HOST=${BAD_HOST}, DNS resolution failure)"
