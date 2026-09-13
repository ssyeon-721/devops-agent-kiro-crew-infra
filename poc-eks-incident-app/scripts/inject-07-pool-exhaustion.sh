#!/usr/bin/env bash
# 시나리오 7 — 커넥션풀 고갈 (보조 경로 검증용)
#
# 정답: DB 커넥션풀 고갈 (DB_POOL_SIZE=5 + 동시 /slow 호출)
# 결정적 신호: 5xx 응답률 상승, Pod는 죽지 않고 느려짐
# !! Operator는 이 장애를 감지하지 못한다 — 정상 동작
#    보조 경로(CloudWatch → SNS → Lambda → Crew)가 잡아야 한다
set -euo pipefail

NAMESPACE="poc"
DEPLOYMENT="web-poc"
RUN_ID="${RUN_ID:-S07-$(date +%Y%m%dT%H%M%S)}"
SMALL_POOL=5
CONCURRENT=10

echo "=== [${RUN_ID}] 시나리오 7 주입 시작 ==="
echo "  주입 시각: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  ground_truth: connection pool exhaustion (DB_POOL_SIZE=${SMALL_POOL})"
echo "  !! Operator 미감지가 정상 — 보조 경로 검증 시나리오"

# DB_POOL_SIZE를 5로 축소
kubectl -n "$NAMESPACE" set env "deployment/$DEPLOYMENT" \
  "DB_POOL_SIZE=${SMALL_POOL}"

kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=60s

# 동시 /slow 호출로 커넥션풀 고갈
POD=$(kubectl -n "$NAMESPACE" get pod -l app=web-poc -o jsonpath='{.items[0].metadata.name}')
echo "  대상 Pod: $POD"
echo "  동시 ${CONCURRENT}개 /slow?sec=30 호출 시작"

for i in $(seq 1 "$CONCURRENT"); do
  kubectl -n "$NAMESPACE" exec "$POD" -- \
    wget -qO- "http://localhost:8000/slow?sec=30" 2>/dev/null &
done

echo "  부하 주입 완료. Pod 상태 (죽지 않아야 정상):"
sleep 5
kubectl -n "$NAMESPACE" get pods -l app=web-poc

echo "  채점 기록:"
echo "    run_id: ${RUN_ID}"
echo "    injected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "    ground_truth: connection pool exhaustion (pool_size=${SMALL_POOL}, concurrent=${CONCURRENT})"
echo "    expected_operator_detected: false  # 정상 동작"
