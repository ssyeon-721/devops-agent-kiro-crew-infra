#!/usr/bin/env bash
# 시나리오 6 — ENI/IP 고갈 (/28 서브넷에서 Pod 40개로 스케일)
#
# 정답: ENI/IP 고갈 (워커 서브넷 /28)
# 결정적 신호: ipamd 로그의 IP 할당 실패 + introspection API
# 난이도: 상 — 사전 환경 조건(/28 서브넷)이 맞아야 재현됨
#
# 전제: modules/network의 worker 서브넷이 /28로 구성되어 있어야 한다
set -euo pipefail

NAMESPACE="poc"
DEPLOYMENT="web-poc"
RUN_ID="${RUN_ID:-S06-$(date +%Y%m%dT%H%M%S)}"
TARGET_REPLICAS=40

echo "=== [${RUN_ID}] 시나리오 6 주입 시작 ==="
echo "  주입 시각: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  ground_truth: ENI/IP exhaustion on /28 worker subnet"
echo "  목표 레플리카: ${TARGET_REPLICAS}"

# 현재 IP 가용성 확인 (ipamd introspection)
NODE=$(kubectl get node -o jsonpath='{.items[0].metadata.name}')
NODE_IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "  워커 노드 IP: ${NODE_IP}"
echo "  ipamd introspection 확인:"
kubectl -n kube-system exec -it \
  "$(kubectl -n kube-system get pod -l k8s-app=aws-node -o jsonpath='{.items[0].metadata.name}')" \
  -- curl -s http://localhost:61679/v1/networkutils-env-settings 2>/dev/null | head -20 || true

# Pod 40개로 스케일
kubectl -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas="$TARGET_REPLICAS"

echo "=== [${RUN_ID}] 스케일 요청 완료 — Pending Pod 대기 ==="
sleep 30
kubectl -n "$NAMESPACE" get pods -l app=web-poc | grep -E "Pending|ContainerCreating" | head -20 || true

echo "  채점 기록:"
echo "    run_id: ${RUN_ID}"
echo "    injected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "    ground_truth: ENI/IP exhaustion (/28 subnet, scale to ${TARGET_REPLICAS} replicas)"
