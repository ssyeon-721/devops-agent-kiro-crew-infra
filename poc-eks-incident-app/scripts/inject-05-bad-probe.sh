#!/usr/bin/env bash
# 시나리오 5 — readinessProbe 경로 오기
#
# 정답: 헬스체크 설정 오류 (/healthz → /health)
# 결정적 신호: probe 실패 이벤트, Pod는 Running이지만 Ready=0
set -euo pipefail

NAMESPACE="poc"
DEPLOYMENT="web-poc"
RUN_ID="${RUN_ID:-S05-$(date +%Y%m%dT%H%M%S)}"

echo "=== [${RUN_ID}] 시나리오 5 주입 시작 ==="
echo "  주입 시각: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  ground_truth: readinessProbe misconfiguration (/healthz → /health)"

kubectl -n "$NAMESPACE" patch deployment "$DEPLOYMENT" --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health"}
]'

kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=60s || true

echo "=== [${RUN_ID}] 주입 완료 — probe 실패 이벤트 확인 ==="
sleep 15
kubectl -n "$NAMESPACE" get events --sort-by='.lastTimestamp' | grep -i probe | tail -5 || true

echo "  채점 기록:"
echo "    run_id: ${RUN_ID}"
echo "    injected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "    ground_truth: readinessProbe path misconfiguration (/healthz → /health)"
