# EKS 인시던트 대응 자동화 검증 PoC

- 문서 버전: v2.1
- 작성일: 2026-09-13
- 최종 업데이트: 2026-09-15
- 성격: 기술 검증 (운영 개선 프로젝트 아님)
- 상태: Phase 5 진행 중 (H1·H2 실증 완료, H3 부분 진행, H5 구축 중)

---

## 0. v1.0과의 차이

v1.0은 실운영 워크로드 도입을 전제로 작성했다. v2.0은 아키텍처 작동 여부와 한계를 규명하는 검증 PoC로 성격을 바꾼다.

| 항목 | v1.0 (운영 도입) | v2.0 (검증 PoC) |
|------|-----------------|-----------------|
| 목적 | MTTR 단축 | 아키텍처 작동 여부 및 한계 규명 |
| 장애 소스 | 실제 발생 장애 | 의도적 주입 |
| 핵심 지표 | MTTD / MTTI / MTTR | 원인 적중률 |
| 베이스라인 | 사전 2주 실측 (Phase 0) | 불필요 — 제거 |
| Tier 1 자동조치 | Phase 4에서 개방 | 범위에서 제외 |
| 중단 기준 | 장애 빈도가 낮으면 중단 | 원인 적중률 미달 시 중단 |
| 산출물 | 운영 파이프라인 | 검증 리포트 + 재사용 가능한 테스트 하네스 |

**핵심 차이**: 장애를 직접 심으면 정답을 알고 채점할 수 있다. 실운영 장애는 진짜 원인을 아무도 모르므로 Agent가 틀려도 검증할 방법이 없다. 정답지의 존재가 이 PoC의 가장 큰 가치다.

---

## 1. 검증 대상 아키텍처

### 1.1 구조

```
═══════════ 서울 ap-northeast-2 ═══════════
┌─────────────── EKS 검증 클러스터 ────────────────┐
│                                                  │
│  [테스트 워크로드]  ← 의도적 장애 주입           │
│       │                                          │
│       ▼                                          │
│  [DevOps Agent Operator]                         │
│       │  Informer로 Pod 상태 변화 감지           │
│       ├── kubectl 레벨 수집                      │
│       └── SSM으로 노드 레벨 수집                 │
└───────┬──────────────────────────────────────────┘
        ├──────────► [S3] 아티팩트 원본
        ├──────────► [CloudWatch Logs] 조사용 참조
        │
        ▼ HMAC-SHA256 Generic Webhook (크로스 리전)
╌╌╌╌╌╌╌╌╌╌╌ 도쿄 ap-northeast-1 ╌╌╌╌╌╌╌╌╌╌╌
  ┌──────────────────────────────┐
  │     AWS DevOps Agent         │
  │  Runbook 자동 조사           │  ← 서울 S3/CW를
  │  GitHub 배포·코드 상관분석   │    크로스 리전 조사
  └────┬────────────────┬────────┘
       ▼ Slack          ▼ Investigation Completed
       │                  (EventBridge, source: aws.aidevops)
═══════════ 서울 ap-northeast-2 ═══════════
  ┌────────────────────────┐   ┌────────────────────────┐
  │ #devops-agent-kiro-crew │◄─┤ Kiro Crew (EC2 상주)   │
  └────────────────────────┘   │ 승인 버튼 / 조치 실행  │
                               │ 포스트모템 초안        │
                               └────────────────────────┘
                 ▲ EventBridge 규칙 → SNS/Lambda → Crew

[보조 경로 검증용] (서울)
CloudWatch 알람 → SNS → Lambda → Crew 직접 트리아지
```

### 1.2 검증 가설

| # | 가설 | 검증 Phase | 상태 |
|---|------|-----------|------|
| H1 | Operator는 Pod 장애를 놓치지 않고 감지한다 | Phase 2 | ✅ 실증 완료 (12/12 감지) |
| H2 | 수집된 컨텍스트는 원인 분석에 충분하다 | Phase 2 | ✅ 실증 완료 (아티팩트 완전 수집) |
| H3 | DevOps Agent는 증상이 같고 원인이 다른 장애를 구분한다 | Phase 3 ★ | 🔄 진행 중 (S1 1회차 정답 확인) |
| H4 | Runbook 최적화로 적중률을 유의미하게 올릴 수 있다 | Phase 4 | ⬜ 미착수 |
| H5 | DevOps Agent → Crew 연결이 안정적으로 구성 가능하다 | Phase 5 | 🔄 Crew 구축 중 (EKS 접근 검증 완료) |

**H3가 중심이다.** 여기서 실패하면 아키텍처 전체의 가치가 사라진다.

### 1.3 설계 원칙

**원칙 1 — 승인 게이트는 조사가 아니라 조치에 둔다**
조사는 읽기 전용이므로 게이트가 불필요하다. 조사에 승인을 걸면 야간 대응 시간이 그대로 사람 응답 시간이 된다.

**원칙 2 — 감지는 클러스터 내부에서 한다**
CloudWatch 알람을 경유하면 알람 평가 주기만큼 늦어지고, 그 사이 Pod가 재시작되면 이전 로그가 소실된다. Kubernetes Events는 약 1시간만 보관되고 Pod 재시작 시 이전 컨테이너 로그는 사라진다.

**원칙 3 — 도구마다 잘하는 일만 시킨다**

| 도구 | 역할 |
|------|------|
| Operator | 감지 + 증거 보존 |
| DevOps Agent | 근본원인 분석 |
| Kiro Crew | 조치 실행 + 사후 정리 |

Crew에게 수집을 시키지 않는 이유: 원칙 2.
Operator에게 조치를 시키지 않는 이유: 컨트롤 루프 특성상 조치 실패 시 무한 재시도에 빠진다.

---

## 2. 성공 지표

### 2.1 핵심 지표

| 지표 | 정의 | 목표 | 미달 시 |
|------|------|------|---------|
| 감지율 | 주입 장애 중 Operator가 감지한 비율 | 100% | Phase 2 재작업 |
| 수집 완전성 | 시나리오별 기대 아티팩트(파드 6종 + 노드 SSM 9종) 누락 여부 | 누락 0 | IAM·SSM 설정 재점검 |
| 원인 적중률 | 심은 원인을 Agent가 정확히 짚은 비율 | 6/7 이상 | Phase 5 중단 |
| 구분 정확도 | 시나리오 1과 2를 다르게 진단한 비율 | 3/3 | Runbook 재설계 |
| 재현 일관성 | 동일 장애 3회 반복 시 동일 진단 비율 | 3/3 | 결과 자체가 산출물 |

### 2.2 측정하지 않는 것

- **MTTD / MTTI / MTTR** — 부하 없는 클러스터에서 나온 시간 수치는 실운영을 대변하지 못한다. 기록은 하되 성과 지표로 쓰지 않는다.
- **비용 절감** — 절감 대상이 없다.
- **온콜 부담 감소** — 온콜이 없다.

### 2.3 중단 기준

아래 중 하나라도 해당하면 다음 Phase로 진행하지 않는다.

- Phase 2 종료 시 감지율 100% 미달이고 원인이 설정 문제가 아닌 경우
- Phase 3 종료 시 원인 적중률 4/7 미만
- Phase 4 종료 시 Runbook 최적화 후에도 적중률 개선폭 1건 이하
- Phase 5에서 H5의 3가지 연결 방식이 모두 실패

> 중단은 실패가 아니라 결과다. "이 조합은 현 시점에서 프로덕션에 쓰기 이르다"는 결론도 충분한 산출물이며, 오히려 공개 콘텐츠로서의 가치는 더 높다.

---

## 3. 검증 환경

### 3.1 인프라

| 구성요소 | 사양 | 비고 |
|----------|------|------|
| EKS 클러스터 | 1.31+, 관리형 노드그룹 2대 (t3.large) | 별도 검증 계정 |
| 워커 노드 서브넷 | 의도적으로 /28 | 시나리오 6 IP 고갈용 |
| Kiro Crew 호스트 | EC2 t3a.medium, AL2023, Python 3.12 | 프라이빗 서브넷 |
| S3 버킷 | 인시던트 아티팩트 전용 | 30일 라이프사이클 |
| CloudWatch 로그그룹 | cw-log-group-devops-agent-operator | 14일 보존 |
| ECR | Operator 이미지 + 테스트 워크로드 이미지 | |
| GitHub 레포 | 테스트 워크로드 소스 + 빌드 CI | Pipeline 연동 필수 |

서브넷을 /28로 잡는 이유: 시나리오 6(IP 고갈)은 사후에 환경을 바꾸기 어려우므로 처음부터 반영해야 한다.

**리전 아키텍처 (크로스 리전 구성)**

| 구성요소 | 리전 | 이유 |
|----------|------|------|
| EKS 클러스터, 네트워크, S3, ECR, Crew EC2 등 모든 인프라 | 서울 `ap-northeast-2` | Terraform 관리 대상 전체 |
| DevOps Agent Space | 도쿄 `ap-northeast-1` | 서울 미지원. 지원 리전 중 실운영 관점 최적 |

DevOps Agent는 서울 리전을 지원하지 않는다(GA 기준 지원 11개 리전에 서울 미포함). 지원 리전 중 도쿄를 선택한 이유는 실제 인하우스 데브옵스 운영 관점에서 최적이기 때문이다.

- **레이턴시**: 서울↔도쿄 RTT ~30ms로 지원 리전 중 최단. Agent가 조사 과정에서 서울 S3·CloudWatch를 반복 조회할 때 왕복 지연이 누적되는데, 버지니아(~180ms) 대비 압도적으로 유리하다.
- **경로 안정성**: 물리적으로 가까워 크로스 리전 데이터 경로의 홉이 적다.
- **데이터 주권**: 로그·아티팩트가 같은 아시아 리전에 머무른다.
- **운영 편의**: 온콜 팀이 아시아 타임존일 때 콘솔 운영이 일관된다.

DevOps Agent는 Agent Space가 어느 지원 리전에 있든 계정 내 모든 리전의 리소스를 탐색·조사한다(공식 지원, Cross-Region resource monitoring). 따라서 도쿄 Agent Space에서 서울 EKS를 조사하는 구성이 성립한다. 크로스 리전 동작은 사전에 별도 검증을 완료했다.

### 3.2 테스트 워크로드 (web-poc, Python/FastAPI)

```
GET  /healthz          정상 헬스체크 (시나리오 5용)
GET  /leak?mb=10       전역 리스트에 데이터 누적 (시나리오 1용)
GET  /slow?sec=30      DB 커넥션 점유 후 대기 (시나리오 7용)
GET  /error            의도적 5xx 반환 (시나리오 7용)
ENV  DB_HOST           외부 주입 (시나리오 3용)
ENV  DB_POOL_SIZE      외부 주입 (시나리오 7용)
```

GitHub 연동이 필수인 이유: DevOps Agent의 차별점은 최근 배포 이력과 코드 변경 사항을 함께 분석하는 것이다. 시나리오 1은 반드시 실제 커밋으로 누수 코드를 추가한 뒤 배포해야 하며, 처음부터 누수 코드가 들어있는 이미지를 쓰면 안 된다.

### 3.3 필요 권한

**Operator (EKS Pod Identity)**
```
IAM: devops-agent-operator-policy
  - ssm:SendCommand, ssm:GetCommandInvocation
  - s3:PutObject (인시던트 버킷 한정)
  - logs:CreateLogStream, logs:PutLogEvents (전용 로그그룹 한정)

K8s RBAC: 읽기 전용
  - pods, pods/log, events, nodes, deployments, replicasets
  - verbs: get, list, watch
  (exec/delete/patch 없음)
```

**Kiro Crew — 역할 분리**

| 역할 | 권한 | 부여 시점 |
|------|------|----------|
| kirocrew-triage-reader | EKS Describe*, Logs FilterLogEvents, EC2 Describe*, K8s 읽기 | 상시 |
| kirocrew-triage-operator | deployments/rollback, deployments/scale (네임스페이스 한정) | 승인 후 AssumeRole, 세션 15분 |

조치용 역할은 Crew 인스턴스 롤에 상시 연결하지 않는다.

---

## 4. 장애 주입 시나리오

### 4.1 시나리오 목록

| # | 주입 방법 | 심은 원인 (정답) | 난이도 | 기대 감지 경로 | Agent가 봐야 할 결정적 신호 |
|---|-----------|-----------------|--------|---------------|---------------------------|
| 1 | /leak 반복 호출 (누수 코드를 커밋으로 추가 후 배포) | 애플리케이션 코드 메모리 누수 | 하 | Operator | dmesg 커널 OOM killer + GitHub 커밋 diff |
| 2 | limit만 128Mi로 축소, 코드 무변경 | 리소스 설정 실수 | 하 | Operator | manifest 비교, 코드 변경 없음 |
| 3 | DB_HOST를 없는 호스트명으로 배포 | 환경변수 오설정 | 중 | Operator | previous 로그의 DNS 해석 실패 |
| 4 | 존재하지 않는 이미지 태그 지정 | ImagePullBackOff | 하 | Operator | Events 타임라인 |
| 5 | readinessProbe 경로를 /health로 오기 | 헬스체크 설정 오류 | 중 | Operator | probe 실패 이벤트 |
| 6 | /28 서브넷에서 Pod 40개로 스케일 | ENI/IP 고갈 | 상 | Operator | ipamd 로그 + introspection |
| 7 | DB_POOL_SIZE=5로 축소 후 /slow 부하 | 커넥션풀 고갈 | 상 | 보조 경로 | Pod가 죽지 않음 |

각 시나리오는 3회씩 반복 주입. **총 21회.**

### 4.2 시나리오 1 vs 2 — 이 PoC의 핵심 판별식

두 시나리오는 겉으로 드러나는 증상이 완전히 동일하다.

**공통 증상**
- Pod 상태: OOMKilled
- Exit Code: 137
- dmesg: 커널 OOM killer 로그 존재
- restartCount 증가

**차이는 하나뿐이다**

| | 시나리오 1 | 시나리오 2 |
|--|-----------|-----------|
| 최근 커밋 | 누수 코드 추가됨 | 없음 |
| manifest 변경 | 없음 | limit 512Mi → 128Mi |
| 올바른 조치 | 코드 수정 | limit 원복 |
| 잘못된 조치의 결과 | limit만 올리면 재발 | 코드 뒤지느라 시간 낭비 |

Agent가 둘 다 "메모리 누수입니다"로 뭉뚱그리면, 실전에서도 똑같이 뭉뚱그린다는 뜻이다. 이 구분에 실패하면 GitHub 상관분석 기능이 실질적으로 작동하지 않는 것이므로 DevOps Agent를 쓸 이유의 상당 부분이 사라진다.

**채점 기준**

| 판정 | 기준 |
|------|------|
| 정답 | 시나리오 1을 코드 원인으로, 2를 설정 원인으로 각각 정확히 진단 |
| 부분 정답 | 원인은 맞췄으나 근거로 제시한 신호가 틀림 |
| 오답 | 둘을 같은 원인으로 진단하거나 원인을 반대로 진단 |

### 4.3 시나리오 7 — 의도적 실패 케이스

Operator는 현재 Pod 리소스만 감시한다. 시나리오 7에서는 Pod가 죽지 않고 느려지기만 하므로 Operator가 감지하지 못하는 것이 **정상 동작**이다.

이 시나리오의 목적:
1. Operator의 커버리지 한계를 실증적으로 확인
2. 보조 경로(CloudWatch → SNS → Lambda → Crew)의 필요성 검증

### 4.4 채점 기록 양식

```yaml
run_id: S01-R2                      # 시나리오1, 2회차
injected_at: 2026-10-14T03:12:00Z
ground_truth: "app code memory leak (commit abc1234)"

operator:
  detected: true
  detected_at: 2026-10-14T03:12:03Z
  artifacts_collected: 12/12
  missing: []

devops_agent:
  investigation_started_at: 2026-10-14T03:12:10Z
  completed_at: 2026-10-14T03:15:40Z
  runbook_used: "OOMKilled"
  root_cause_stated: "..."
  verdict: correct | partial | wrong
  evidence_cited: [dmesg, github_commit, cw_metrics]
  evidence_correct: true

notes: |
  GitHub 커밋을 인용했으나 라인 번호는 부정확
```

`verdict`와 `evidence_correct`를 분리하는 이유: 원인은 맞췄는데 근거가 엉뚱한 경우를 구분하기 위해서다. 이 패턴이 반복되면 정답을 추론한 게 아니라 흔한 원인을 찍은 것일 가능성이 있다.

---

## 5. 진행 계획

| Phase | 내용 | 검증 가설 | 상태 |
|-------|------|----------|------|
| 1 | 검증 환경 + 테스트 워크로드 구축 | | ✅ 완료 |
| 2 | Operator 배포 → 시나리오 1~4 주입 | H1, H2 | ✅ 완료 (감지율 100%, 수집 완전성 100%) |
| 3 | DevOps Agent 연동 → 시나리오 1~6 주입 | H3 ★ 중단 판정 | 🔄 진행 중 (S1 1회차 정답, 나머지 시나리오 대기) |
| 4 | Runbook 최적화 → 시나리오 1~6 재주입 | H4 | ⬜ 미착수 |
| 5 | Kiro Crew 조치 레이어 (Tier 2만) | H5 | 🔄 진행 중 (Crew 설치·EKS 접근 완료, Slack·H5 실측 대기) |
| 6 | 보조 경로 구성 → 시나리오 7 주입 | | ⬜ 미착수 |
| 7 | 결과 정리 및 리포트 작성 | | ⬜ 미착수 |

---

## 6. 미검증 구간 및 리스크

### 6.1 H5 — DevOps Agent → Crew 연결

**조사 결과 (2026-09-13, GA 기준): EventBridge 네이티브 연동으로 해결됨.**

당초 이 연결은 "공식 문서로 보장되지 않는 유일한 구간"으로 최대 리스크였으나, GA 이후 DevOps Agent가 **조사·완화 생애주기 이벤트를 Amazon EventBridge로 자동 전송**하는 것이 공식 지원됨을 확인했다. 이로써 H5는 미검증 구간에서 **공식 지원 구간**으로 격하된다.

**채택: D안 — EventBridge 조사 완료 이벤트**

DevOps Agent는 `aws.aidevops` 소스로 default 이벤트 버스에 이벤트를 보낸다. 우리가 쓸 핵심 이벤트:

| detail-type | 의미 | 용도 |
|-------------|------|------|
| `Investigation Completed` | 조사가 findings와 함께 성공 완료 | Crew 트리거 (핵심) |
| `Investigation Failed` | 조사 실패 | 사람에게 알림 폴백 |
| `Mitigation Completed` | 완화 조치 완료 | 조치 결과 회신 |

연결 흐름 (크로스 리전 포함):
```
[도쿄] DevOps Agent 조사 완료
   → default 이벤트 버스에 "Investigation Completed" 발생 (source: aws.aidevops)
   → EventBridge 규칙이 매칭
   → 타겟(SNS/Lambda 등)으로 라우팅
   → [서울] Kiro Crew 트리거
```

특정 Agent Space만 필터링하는 이벤트 패턴도 지원한다:
```json
{
  "source": ["aws.aidevops"],
  "detail-type": ["Investigation Completed", "Investigation Failed"],
  "detail": { "metadata": { "agent_space_id": ["<our-agent-space-id>"] } }
}
```

> Agent Space 이름은 `poc-eks-incident-agent` (도쿄 `ap-northeast-1`)로 생성됨.
> 단, `agent_space_id`는 **이름이 아니라 콘솔이 발급하는 고유 ID**이므로, Phase 3에서 콘솔에서 실제 ID를 확인해 `<our-agent-space-id>`를 교체해야 한다.

**의의**
- 원래 A안(Webhook 재발급)의 "조사 완료를 내보내는지 불확실" 문제, B안(Slack 파싱)의 "포맷 변경 취약" 문제를 모두 우회한다.
- Phase 6 보조 경로(EventBridge→SNS→Lambda→Crew)와 **동일한 구조**라 아키텍처 일관성이 높다.
- DevOps Agent가 추가 권한 없이 default 버스로 자동 전송하므로 설정 부담도 낮다.

**대안 (D안 불가 시 폴백)**

| 안 | 방식 | 단점 |
|----|------|------|
| B | Crew를 Slack 채널 observe 모드로 붙여 결과 파싱 | 텍스트 파싱이라 포맷 변경에 취약. 폴백 시 원문을 스레드에 올려 사람이 판단 |
| C | S3 이벤트 알림 폴링 | 조사 결과가 S3에 안 떨어지면 불가 |

D안이 크로스 리전 EventBridge로 실제 동작하는지는 Phase 5에서 실측한다(이벤트 발생 → 규칙 매칭 → Crew 수신까지 왕복). 다만 각 구간이 공식 지원되므로 성공 가능성이 높다.

### 6.2 제약 사항

| # | 제약 | 대응 |
|---|------|------|
| C1 | DevOps Agent가 서울 리전 미지원 | Agent Space는 도쿄(`ap-northeast-1`)에 구성. 서울 EKS를 크로스 리전으로 조사 (§3.1) |
| C2 | Operator 컨테이너 이미지 미제공 | ✅ 해결(Phase 2-1). GitHub Actions(amd64)로 Dockerfile 빌드 → ECR `poc-eks-incident-operator` 푸시. 소스는 `kr-tech-blog-sample-code` 모노레포 하위에서 분리. **C5 추가 발견**: Kiro Crew `kirocrew service install`이 root 실행 거부(보안 정책) → 전용 `kirocrew` 유저 생성 후 비-root로 실행(Phase 5-1 해결) |
| C3 | Operator가 Pod 리소스만 감시 | 시나리오 7로 한계 실증. Job/Deployment 확장은 포크 필요 |
| C4 | Crew Slack 게이트웨이가 오너 1명에 잠김 | PoC는 단일 오너로 충분. 팀 운영은 채널 observe + 멘션 |
| C5 | Crew Strict 샌드박스가 .aws/.ssh/.kube를 숨김 | Auto 모드 사용. Off 금지 |
| C6 | Crew에 민감/규제 데이터 입력 금지 경고 | PoC 워크로드에 실데이터 미사용. 고객사 전개 시 마스킹 레이어 필수 |
| C7 | HMAC Secret 재조회 불가 | 발급 즉시 CSV 다운로드 → Secrets Manager |

### 6.3 리스크

| # | 리스크 | 영향 | 완화 |
|---|--------|------|------|
| R1 | 주입한 장애가 실제 장애와 성격이 달라 결과가 과대평가됨 | 높음 | 시나리오 2·6·7 같은 비전형 케이스 포함. 결과에 "합성 장애 기반" 한계 명시 |
| R2 | Agent가 정답을 추론이 아니라 확률로 찍음 | 중간 | evidence_correct를 별도 채점. 3회 반복으로 일관성 확인. S1-1회차에서 원인 커밋 SHA·dmesg 해석 정확히 제시 → 추론 근거 확인됨 |
| R3 | GA 이후 사양·기능 업데이트로 동작이 달라짐 | 낮음 | 각 Phase 결과에 실행 일자 기록 |
| R4 | 검증 환경 비용 누적 | 낮음 | 야간 노드그룹 스케일다운, Crew EC2 스케줄 정지 |
| R5 | Operator 자체 장애로 감지 누락 | 중간 | Operator Pod 헬스 확인을 주입 전 체크리스트에 포함 |
| R6 | 토큰/크레딧 소모 | 중간 | 주입 21회 + 재주입 18회 기준 사전 산정. 보조 경로 중복 억제 |
| R7 | Crew EC2에서 `kiro-cli login` 브라우저 인터랙티브 필요 | 중간 | `kiro-cli login --use-device-flow`로 device 코드 발급 → 브라우저에서 수동 인증. SSM 자동화 불가하나 1회성 수동 작업으로 해소 |

---

## 7. 예상 결과

### 7.1 확실하게 나올 것

- **감지·수집의 구조적 우위 실증**: Operator가 Informer로 상태 변화를 즉시 잡고, kubectl 레벨과 노드 레벨(kubelet, containerd, ipamd, dmesg, 디스크·메모리) 데이터를 한 번에 확보하는 것은 사람이 재현할 수 없다.
- **Operator 커버리지 경계**: 시나리오 7에서 미감지가 확인되면, 이 아키텍처 단독으로는 부족하고 보조 경로가 필수라는 결론이 명확해진다.

### 7.2 불확실한 것 — 실제로 해봐야 아는 것

- **시나리오 1 vs 2 구분 능력 (H3)**: 이 PoC를 하는 이유 자체.
- **시나리오 6(IP 고갈) 적중률**: ipamd introspection 데이터를 Agent가 실제로 해석하는지. 난이도가 가장 높다.
- **Runbook 최적화의 효과 크기**: 개선이 1건인지 4건인지에 따라 "조직 지식 반영" 주장의 설득력이 달라진다.
- **재현 일관성**: 같은 입력에 같은 답이 나오지 않으면, 그 사실 자체가 프로덕션 도입의 가장 큰 장애물이다.

### 7.3 기대하지 말아야 할 것

- **신규·복합 장애 대응**: Runbook에 없는 유형은 여전히 사람의 몫이다.
- **조치 계획의 완결성**: 근본 원인이 애플리케이션 코드 로직인 경우, 원인은 짚어도 명확한 조치 계획은 제시하지 못할 수 있다. 시나리오 1이 여기에 해당한다.
- **실운영 성능 예측**: 부하 없는 클러스터의 결과를 실운영 MTTR로 환산하지 않는다.

### 7.4 산출물

| # | 산출물 | 활용 |
|---|--------|------|
| 1 | 시나리오별 채점 결과 전수 | 내부 도입 판단 근거 |
| 2 | 실패 유형 분석 | Runbook 설계 가이드 |
| 3 | 재사용 가능한 장애 주입 하네스 | 향후 타 도구 비교 검증 |
| 4 | 커스텀 Runbook 세트 | 고객사 전개 시 자산 |
| 5 | 기술 블로그 / 발표 자료 | 대외 콘텐츠 |

블로그 방향: AWS 공식 블로그가 이미 성공 사례를 다뤘으므로, 한계를 짚은 검증기가 차별화된다. "7개 유형 중 N개에서 원인을 정확히 짚었고, 못 짚은 유형은 이것들이며 이유는 이렇다"가 이 PoC의 결론 형태다.

---

## 8. IaC 구성

### 8.1 방침

AWS 리소스는 Terraform으로 구성하고 코드는 GitHub에 보관한다. PoC 성격상 환경을 여러 번 부수고 다시 만들게 되므로 IaC가 선택이 아니라 전제다.

### 8.2 레포지토리 구성

```
poc-eks-incident-infra/     인프라 (Terraform)
poc-eks-incident-app/       테스트 워크로드 (애플리케이션 코드)
```

분리가 필수인 이유: DevOps Agent Pipeline에 연동하는 레포는 app 하나뿐이어야 한다. 인프라 커밋이 섞이면 시나리오 1(코드 누수)과 2(설정 실수) 구분 검증이 오염된다.

### 8.3 Terraform 디렉터리 구조

```
poc-eks-incident-infra/
├── .github/workflows/
│   ├── plan.yml                 PR 시 terraform plan
│   └── apply.yml                main 머지 시 apply (수동 승인)
├── envs/
│   └── poc/
│       ├── main.tf
│       ├── variables.tf
│       ├── terraform.tfvars
│       └── backend.tf
├── modules/
│   ├── network/                 VPC, 서브넷 (워커 /28)
│   ├── eks/                     클러스터, 노드그룹, Pod Identity
│   ├── operator-iam/            Operator용 IAM Policy/Role
│   ├── storage/                 S3 버킷, CloudWatch 로그그룹
│   ├── registry/                ECR (operator, app)
│   ├── crew-host/               Crew용 EC2, SG, 인스턴스 롤
│   └── alt-path/                CloudWatch 알람, SNS, Lambda (Phase 6)
└── README.md
```

### 8.4 Terraform 관리 범위

**관리한다**

| 모듈 | 리소스 |
|------|--------|
| network | VPC, 퍼블릭/프라이빗 서브넷, 워커 서브넷 /28, NAT, 라우팅 |
| eks | EKS 클러스터, 관리형 노드그룹, EKS Pod Identity Agent 애드온, Pod Identity Association |
| operator_iam | devops-agent-operator-policy, devops-agent-operator-role, 신뢰 정책 |
| storage | 인시던트 S3 버킷(버전관리·30일 라이프사이클), CloudWatch 로그그룹(14일) |
| registry | ECR 레포 2개 + 라이프사이클 정책 |
| crew_host | EC2, 보안그룹(인바운드 0), SSM 접속용 인스턴스 프로파일, kirocrew-triage-reader / kirocrew-triage-operator 역할 |
| alt_path | CloudWatch 알람, SNS 토픽, Lambda 브리지(중복 억제 포함) |

**관리하지 않는다**

| 대상 | 이유 | 대안 |
|------|------|------|
| DevOps Agent Space | 도쿄 리전 구성, Terraform 리소스 미제공 | 콘솔 수동 구성. 설정값을 README에 기록 |
| Generic Webhook / HMAC Secret | 콘솔에서만 발급, 재조회 불가 | 발급 후 Secrets Manager에 수동 저장 → Terraform은 data 소스로 참조 |
| Slack App 토큰 | Slack 측 발급 | 동일 |
| Kiro Crew 설치·설정 | EC2 내부 작업 | user_data 최소화 후 SSM으로 수동 구성 |
| Operator / 워크로드 매니페스트 | K8s 리소스 | kubectl apply 또는 별도 Helm |
| **장애 주입** | 의도적으로 깨진 상태 | kubectl 또는 스크립트 |

장애 주입을 Terraform 바깥에서 하는 이유: 시나리오 2(limit 축소)나 4(잘못된 이미지 태그)를 Terraform으로 적용하면 깨진 상태가 정상 state로 기록된다. 이후 plan이 계속 드리프트를 보고하고, 의도된 파괴와 실제 드리프트를 구분할 수 없게 된다.

### 8.5 State 관리

```hcl
terraform {
  backend "s3" {
    bucket       = "poc-eks-incident-tfstate"
    key          = "poc/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
```

State 백엔드용 S3 버킷은 부트스트랩 문제가 있으므로 콘솔 또는 CLI로 수동 생성하고 Terraform 관리 대상에서 제외한다. 버킷에 버전 관리를 켜서 state 손상 시 복구 가능하게 한다.

### 8.6 시크릿 취급

`tfstate`는 평문이다. Terraform 변수로 넣은 시크릿은 state 파일에 그대로 들어간다.

| 시크릿 | 취급 |
|--------|------|
| HMAC Secret | 콘솔 발급 → CSV 즉시 다운로드 → Secrets Manager에 CLI로 수동 저장 |
| Slack App/Bot 토큰 | Secrets Manager에 수동 저장. Crew는 `~/.kiro/crew/.env`에서 읽음 |
| Terraform 참조 방식 | `data "aws_secretsmanager_secret_version"` — 값을 리소스로 생성하지 않음 |

Terraform은 시크릿의 ARN만 알고 값은 모르는 상태를 유지한다.

### 8.7 GitHub Actions

```yaml
# .github/workflows/plan.yml (핵심 부분)
permissions:
  id-token: write        # OIDC
  contents: read
  pull-requests: write   # plan 결과 코멘트

- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::<ACCOUNT>:role/github-actions-terraform
    aws-region: ap-northeast-2
```

장기 액세스 키를 GitHub Secrets에 넣지 않는다. OIDC 페더레이션으로 AssumeRole하고, 신뢰 정책에서 레포·브랜치를 한정한다.

- `plan.yml`: PR 오픈/갱신 시 실행, plan 결과를 PR 코멘트로
- `apply.yml`: main 머지 시 실행, Environment protection rule로 수동 승인

apply에 승인 게이트를 두는 이유: 검증 도중 클러스터가 갈아엎어지면 진행 중인 주입 회차가 통째로 날아가기 때문이다.

### 8.8 비용 통제

- EKS 노드그룹: 미사용 시간 `desired_size = 0` (변수로 노출)
- Crew EC2: EventBridge Scheduler + Lambda로 야간 정지 (alt-path 모듈에 포함)
- `terraform destroy`로 전체 철거 가능하도록 유지
- Phase 중간에 destroy하지 않는다 — 노드 인스턴스 ID, ENI 구성이 바뀌어 시나리오 6의 조건이 달라진다.

### 8.9 Phase 1 작업 순서

1. state용 S3 버킷 수동 생성
2. GitHub 레포 2개 생성, OIDC 신뢰 역할 구성
3. `modules/network` → `modules/eks` 순으로 apply, 클러스터 접속 확인
4. `operator-iam`, `storage`, `registry` apply
5. `crew-host` apply (Crew 설치는 Phase 5까지 보류, 인스턴스는 정지 상태 유지)
6. 테스트 워크로드 개발 → app 레포 → 빌드 CI → ECR 푸시
7. 정상 배포 확인 후 `reset.sh` 작성
8. `alt-path` 모듈은 Phase 6까지 apply하지 않는다.

---

## 9. 결론

이 PoC는 MTTR을 줄이기 위한 것이 아니라, 이 아키텍처가 어디까지 작동하고 어디서 깨지는지를 정답지를 가지고 확인하기 위한 것이다.

**핵심 세 가지:**

1. **정답을 알고 채점한다.** 실운영에서는 불가능한 검증이며, 이 PoC의 가장 큰 자산이다.
2. **H3(증상 동일·원인 상이 구분)가 중심 가설이다.** 여기서 실패하면 나머지가 다 되어도 프로덕션에 쓸 수 없다.
3. **중단 기준을 먼저 정해둔다.** Phase 3에서 적중률 4/7 미만이면 멈춘다. 이미 투자했으니 계속한다는 판단을 피하기 위해 착수 전에 명문화한다.

H5 연결 방식은 Phase 1에서 조사 완료했다(§6.1). GA 이후 도입된 EventBridge 네이티브 연동(`Investigation Completed` 이벤트)으로 해결되어, 당초 최대 리스크였던 이 구간이 공식 지원 구간으로 격하됐다. 실제 크로스 리전 왕복 동작은 Phase 5에서 실측한다.

---

## 참고 자료

- [Agent로 최적화하는 EKS 운영: AWS DevOps Agent + K8s Operator로 MTTR 줄이기](https://aws.amazon.com/ko/blogs/tech/aws-devops-agent-k8s-operator/)
- [DevOps Agent Operator 소스 코드](https://github.com/aws-samples/kr-tech-blog-sample-code/tree/main/containers/devops-agent-operator) — aws-samples 모노레포(`kr-tech-blog-sample-code`)의 `containers/devops-agent-operator/` 하위 경로. 전용 레포가 아님. 컨테이너 이미지는 미제공이라 Dockerfile로 직접 빌드해야 함(Phase 2 첫 작업)
- [AWS DevOps Agent 공식 페이지](https://aws.amazon.com/devops-agent/)
- [DevOps Agent Runbook 가이드](https://docs.aws.amazon.com/devops-agent/latest/userguide/runbooks.html)
- [AWS DevOps Agent + Amazon EventBridge 통합 (H5 해결 근거)](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-integrations-and-knowledge-integrating-devops-agent-into-event-driven-applications-using-amazon-eventbridge-index.html)
- [AWS DevOps Agent 지원 리전](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent-supported-regions.html)
- [Best Practices for Deploying AWS DevOps Agent in Production](https://docs.aws.amazon.com/devops-agent/latest/userguide/best-practices.html)
- [Kiro Crew — Running 24/7](https://kiro.dev/docs/crew/running-24-7)
- [Kiro Crew — Slack 인터페이스](https://kiro.dev/docs/crew/slack)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [terraform-aws-modules/eks](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest)
- [GitHub Actions에서 AWS OIDC로 인증하기](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
