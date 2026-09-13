#!/usr/bin/env bash
# reset.sh — 정상 상태 복원
# 주입 전·후 매번 실행해서 채점 환경을 초기화한다
set -euo pipefail

NAMESPACE="poc"
DEPLOYMENT="web-poc"
NORMAL_IMAGE_TAG="${NORMAL_IMAGE_TAG:-latest}"   # 환경변수로 오버라이드 가능
ECR_URL="${ECR_URL:?ECR_URL 환경변수를 설정하세요}"  # e.g. 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/poc-eks-incident-app

echo "=== reset: 정상 상태 복원 시작 ==="

# 이미지 태그 정상값 복원
kubectl -n "$NAMESPACE" set image "deployment/$DEPLOYMENT" \
  "web-poc=${ECR_URL}:${NORMAL_IMAGE_TAG}"

# 리소스 limit 정상값 복원 (시나리오 2 복원)
kubectl -n "$NAMESPACE" patch deployment "$DEPLOYMENT" --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"512Mi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"128Mi"}
]'

# readinessProbe 경로 정상값 복원 (시나리오 5 복원)
kubectl -n "$NAMESPACE" patch deployment "$DEPLOYMENT" --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/healthz"}
]'

# 환경변수 정상값 복원 (시나리오 3, 7 복원)
kubectl -n "$NAMESPACE" set env "deployment/$DEPLOYMENT" \
  DB_HOST=db.internal \
  DB_POOL_SIZE=20

# 레플리카 정상값 복원 (시나리오 6 복원)
kubectl -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas=2

# rollout 완료 대기
echo "=== rollout 완료 대기 ==="
kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=120s

# 상태 확인
echo "=== Pod 상태 ==="
kubectl -n "$NAMESPACE" get pods -l app=web-poc

# healthz 확인
POD=$(kubectl -n "$NAMESPACE" get pod -l app=web-poc -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NAMESPACE" exec "$POD" -- wget -qO- http://localhost:8000/healthz

echo "=== reset 완료 ==="
