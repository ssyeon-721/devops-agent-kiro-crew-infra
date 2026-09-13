#!/usr/bin/env bash
# 시나리오 1 — 애플리케이션 코드 메모리 누수
#
# 정답: 코드 레벨 메모리 누수 (커밋 추가 후 배포)
# 결정적 신호: dmesg OOM killer + GitHub 커밋 diff
#
# !! 반드시 실제 커밋으로 누수 코드를 추가한 뒤 이미지를 빌드/푸시해야 한다.
#    처음부터 누수 코드가 있는 이미지를 쓰면 H3 검증이 불가능하다.
#
# 실행 방법:
#   LEAK_IMAGE_TAG=<누수 코드가 들어있는 커밋 SHA> ./inject-01-code-leak.sh
set -euo pipefail

NAMESPACE="poc"
DEPLOYMENT="web-poc"
ECR_URL="${ECR_URL:?ECR_URL 환경변수를 설정하세요}"
LEAK_IMAGE_TAG="${LEAK_IMAGE_TAG:?LEAK_IMAGE_TAG 환경변수를 설정하세요 (누수 커밋 SHA)}"
RUN_ID="${RUN_ID:-S01-$(date +%Y%m%dT%H%M%S)}"

echo "=== [${RUN_ID}] 시나리오 1 주입 시작 ==="
echo "  주입 시각: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  이미지 태그: ${LEAK_IMAGE_TAG}"
echo "  ground_truth: app code memory leak (commit ${LEAK_IMAGE_TAG})"

# 누수 코드가 포함된 이미지로 교체
kubectl -n "$NAMESPACE" set image "deployment/$DEPLOYMENT" \
  "web-poc=${ECR_URL}:${LEAK_IMAGE_TAG}"

kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=60s

# /leak 엔드포인트 반복 호출로 메모리 누적
POD=$(kubectl -n "$NAMESPACE" get pod -l app=web-poc -o jsonpath='{.items[0].metadata.name}')
echo "  대상 Pod: $POD"
echo "  /leak 반복 호출 시작 (OOMKilled까지 대기)"

for i in $(seq 1 30); do
  kubectl -n "$NAMESPACE" exec "$POD" -- \
    wget -qO- "http://localhost:8000/leak?mb=50" 2>/dev/null || true
  echo "  호출 ${i}/30 완료"
  sleep 2
done

echo "=== [${RUN_ID}] 주입 완료 — Operator 감지 대기 ==="
echo "  채점 기록:"
echo "    run_id: ${RUN_ID}"
echo "    injected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "    ground_truth: app code memory leak (commit ${LEAK_IMAGE_TAG})"
