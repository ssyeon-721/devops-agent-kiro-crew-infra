#!/usr/bin/env bash
# 시나리오 2 — 리소스 limit 축소 (코드 변경 없음)
#
# 정답: 리소스 설정 실수 (limit 512Mi → 128Mi)
# 결정적 신호: manifest 비교에서 limit 변경 확인, 최근 커밋에 코드 변경 없음
# 공통 증상: OOMKilled, Exit Code 137 (시나리오 1과 동일)
set -euo pipefail

NAMESPACE="poc"
DEPLOYMENT="web-poc"
RUN_ID="${RUN_ID:-S02-$(date +%Y%m%dT%H%M%S)}"

echo "=== [${RUN_ID}] 시나리오 2 주입 시작 ==="
echo "  주입 시각: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  ground_truth: resource limit misconfiguration (512Mi → 128Mi)"

# limit만 128Mi로 축소 (코드/이미지 변경 없음)
kubectl -n "$NAMESPACE" patch deployment "$DEPLOYMENT" --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"128Mi"}
]'

kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=60s

# 메모리 사용을 유발해 128Mi limit을 초과시킴
POD=$(kubectl -n "$NAMESPACE" get pod -l app=web-poc -o jsonpath='{.items[0].metadata.name}')
echo "  대상 Pod: $POD"
echo "  메모리 압박 시작 (128Mi limit 초과 유도)"

for i in $(seq 1 10); do
  kubectl -n "$NAMESPACE" exec "$POD" -- \
    wget -qO- "http://localhost:8000/leak?mb=20" 2>/dev/null || true
  echo "  호출 ${i}/10 완료"
  sleep 3
done

echo "=== [${RUN_ID}] 주입 완료 ==="
echo "  채점 기록:"
echo "    run_id: ${RUN_ID}"
echo "    injected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "    ground_truth: resource limit misconfiguration (limit 512Mi→128Mi, no code change)"
