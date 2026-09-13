#!/usr/bin/env bash
# 시나리오 4 — 존재하지 않는 이미지 태그 (ImagePullBackOff)
#
# 정답: 존재하지 않는 이미지 태그 지정
# 결정적 신호: Events 타임라인의 ImagePullBackOff / ErrImagePull
set -euo pipefail

NAMESPACE="poc"
DEPLOYMENT="web-poc"
ECR_URL="${ECR_URL:?ECR_URL 환경변수를 설정하세요}"
RUN_ID="${RUN_ID:-S04-$(date +%Y%m%dT%H%M%S)}"
BAD_TAG="nonexistent-tag-99999"

echo "=== [${RUN_ID}] 시나리오 4 주입 시작 ==="
echo "  주입 시각: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  ground_truth: ImagePullBackOff (tag=${BAD_TAG})"

kubectl -n "$NAMESPACE" set image "deployment/$DEPLOYMENT" \
  "web-poc=${ECR_URL}:${BAD_TAG}"

echo "=== [${RUN_ID}] 주입 완료 — ImagePullBackOff 대기 ==="
kubectl -n "$NAMESPACE" get events --sort-by='.lastTimestamp' | tail -10

echo "  채점 기록:"
echo "    run_id: ${RUN_ID}"
echo "    injected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "    ground_truth: ImagePullBackOff (image tag ${BAD_TAG} does not exist)"
