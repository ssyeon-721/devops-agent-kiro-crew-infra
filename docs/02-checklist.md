# 작업 체크리스트

> 상태 표기: ⬜ 미착수 / 🔄 진행중 / ✅ 완료 / ⛔ 중단/블로킹

---

## Phase 1 — 검증 환경 구축

### 1-1. 사전 준비 (수동)

- [x] AWS 검증 계정 분리 확인 (계정 084828589246, 유저 kiro)
- [x] ap-northeast-2 리전 기본 한도 확인 (EKS, EC2, EIP 등)
- [x] state용 S3 버킷 수동 생성
  ```bash
  aws s3api create-bucket \
    --bucket poc-eks-incident-tfstate \
    --region ap-northeast-2 \
    --create-bucket-configuration LocationConstraint=ap-northeast-2

  aws s3api put-bucket-versioning \
    --bucket poc-eks-incident-tfstate \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket poc-eks-incident-tfstate \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  ```
- [x] GitHub 레포 2개 생성
  - `devops-agent-kiro-crew-infra` (인프라 + docs, Terraform)
  - `poc-eks-incident-app` (테스트 워크로드)
- [x] GitHub OIDC 신뢰 역할 구성 (`modules/github-oidc`로 IaC 관리)
  - OIDC Provider `token.actions.githubusercontent.com` 등록
  - `github-actions-terraform` 역할 생성, 신뢰 정책에 두 레포 한정
  - 개인 계정 토큰 sub 포맷(`owner@id/repo@id`) 대응 와일드카드 반영

### 1-2. Terraform 모듈 구성

- [x] `backend.tf` 작성 및 `terraform init` (S3 백엔드 연결)
- [x] `modules/network` apply
  - VPC, 퍼블릭/프라이빗 서브넷
  - **워커 노드 서브넷: /28** (시나리오 6 IP 고갈 필수 조건)
  - NAT Gateway, 라우팅 테이블
- [x] `modules/eks` apply
  - EKS 1.31, 관리형 노드그룹 2대 (t3.large) — 노드 2대 Ready
  - EKS Pod Identity Agent 애드온
  - `kubectl` 접속 확인 (클러스터 생성자 admin access entry 추가)
- [x] `modules/operator-iam` apply
  - `devops-agent-operator-policy` 생성
  - `devops-agent-operator-role` 생성 + Pod Identity Association
- [x] `modules/storage` apply
  - 인시던트 S3 버킷 (버전관리, 30일 라이프사이클)
  - CloudWatch 로그그룹 `cw-log-group-devops-agent-operator` (14일 보존)
- [x] `modules/registry` apply
  - ECR 레포: `poc-eks-incident-operator`, `poc-eks-incident-app`
  - 라이프사이클 정책 (이미지 30개 보관)
- [x] `modules/crew-host` apply
  - EC2 t3a.medium, AL2023 (`i-03d7e0868fb975158`)
  - 보안그룹 (인바운드 0, SSM 접속용) — 설명 ASCII 제약으로 영문화
  - `kirocrew-triage-reader` / `kirocrew-triage-operator` IAM 역할
  - **인스턴스는 stopped 상태로 유지 — Crew 설치는 Phase 5**

### 1-3. 테스트 워크로드 (poc-eks-incident-app)

- [x] FastAPI 앱 작성 (`web-poc`)
  - `GET /healthz` — 정상 헬스체크
  - `GET /leak?mb=10` — 메모리 누수 (시나리오 1)
  - `GET /slow?sec=30` — 커넥션 점유 (시나리오 7)
  - `GET /error` — 5xx 반환 (시나리오 7)
  - ENV: `DB_HOST`, `DB_POOL_SIZE`
- [x] Dockerfile 작성
- [x] GitHub Actions 빌드 CI 구성 (app 레포)
  - main 푸시: ECR 푸시 (`latest` + 커밋 SHA 태그)
  - OIDC로 AssumeRole (액세스 키 미사용)
- [x] 정상 상태 Kubernetes 매니페스트 작성
  - Deployment (requests/limits 정상값)
  - Service
  - readinessProbe: `/healthz`
- [x] ECR 푸시 확인, 클러스터에 정상 배포 확인 (Pod 2대 Running)

### 1-4. 스크립트 준비 (poc-eks-incident-app/scripts/)

- [x] `reset.sh` 작성 및 동작 확인
  - 정상 이미지 태그로 롤백
  - limit/request 정상값 복원
  - probe 경로 정상값 복원
  - env 정상값 복원
  - Pod 재시작 대기 + 정상 확인 (`/healthz` 200 확인 완료)
  - slim 이미지에 wget 없어 python urllib로 헬스체크 (inject 01/02/07도 동일 수정)
- [x] 주입 스크립트 뼈대 작성 (Phase 2에서 실행)
  - `inject-01-code-leak.sh`
  - `inject-02-limit-shrink.sh`
  - `inject-03-bad-dbhost.sh`
  - `inject-04-bad-image-tag.sh`
  - `inject-05-bad-probe.sh`
  - `inject-06-ip-exhaustion.sh`
  - `inject-07-pool-exhaustion.sh`

### 1-5. Phase 1 종료 조건

- [x] `kubectl get nodes` → 2대 Ready
- [x] 테스트 워크로드 Pod Running 확인
- [x] `GET /healthz` 200 응답 확인
- [x] `reset.sh` 실행 후 정상 상태 복원 확인
- [ ] H5 조사 착수 (§6.1 연결 방식 A/B/C 검토)

---

## Phase 2 — Operator 단독 검증

### 2-1. Operator 배포

- [ ] DevOps Agent Operator 소스 코드 클론
- [ ] Dockerfile 빌드 → ECR (`poc-operator`) 푸시
- [ ] K8s RBAC 매니페스트 적용
  - ClusterRole: pods, pods/log, events, nodes, deployments, replicasets (get/list/watch)
  - ClusterRoleBinding
- [ ] ConfigMap 설정
  - `EXCLUDE_NAMESPACES`
  - `ENABLE_SSM_COLLECTION=true`
  - 리전, S3 버킷명
- [ ] Operator Deployment 배포
- [ ] Operator Pod 로그로 정상 기동 확인

### 2-2. 시나리오 주입 (각 3회)

> 주입 전 체크: Operator Pod Running 확인, `reset.sh` 실행으로 초기 상태 확인

- [ ] 시나리오 1 — 코드 메모리 누수 (3회)
  - 누수 코드를 실제 커밋으로 추가 후 배포 필수
- [ ] 시나리오 2 — limit 축소 (3회)
- [ ] 시나리오 3 — 잘못된 DB_HOST (3회)
- [ ] 시나리오 4 — 잘못된 이미지 태그 (3회)

### 2-3. 검증

- [ ] S3 아티팩트 12종 완전성 검증 (12건 × 4시나리오 × 3회)
- [ ] 누락 아티팩트 있으면 IAM/SSM 설정 재점검

### 2-4. Phase 2 종료 조건

- [ ] 감지율 100% (12/12회)
- [ ] 수집 완전성 12/12
- [ ] 결과 간단 정리 (다음 Phase 전 끊어서 기록)

**중단 기준**: 감지율 100% 미달이고 원인이 설정 문제가 아닌 경우 → Phase 3 진행 안 함

---

## Phase 3 — DevOps Agent 연동 ★

### 3-1. DevOps Agent 설정 (콘솔 수동)

- [ ] Agent Space 생성 (**도쿄 `ap-northeast-1`** — 서울 미지원, §3.1)
  - 크로스 리전으로 서울 EKS 조사 (사전 검증 완료)
- [ ] Generic Webhook 발급
  - **HMAC Secret: CSV 즉시 다운로드 (재조회 불가)**
  - Secrets Manager에 저장
- [ ] GitHub Pipeline 연동 (app 레포만)
- [ ] Slack Communication 연동 (`#eks-poc` 채널, 앱 초대 확인)
- [ ] Operator 환경변수에 Webhook URL 주입, 재배포

### 3-2. 시나리오 주입 (각 3회)

- [ ] 시나리오 1 (3회) — 코드 메모리 누수
- [ ] 시나리오 2 (3회) — limit 축소
- [ ] 시나리오 3 (3회) — 잘못된 DB_HOST
- [ ] 시나리오 4 (3회) — 잘못된 이미지 태그
- [ ] 시나리오 5 (3회) — 잘못된 probe 경로
- [ ] 시나리오 6 (3회) — IP 고갈

### 3-3. 채점

- [ ] 전 건 채점 양식으로 기록 (18건)
- [ ] Investigation Timeline 전수 분석
- [ ] 시나리오 1 vs 2 구분 정확도 별도 집계

### 3-4. Phase 3 종료 조건

- [ ] 원인 적중률 집계
- [ ] 결과 기록

**중단 기준**: 원인 적중률 4/7 미만 → Phase 4 진행 안 함

---

## Phase 4 — Runbook 최적화

### 4-1. 분석

- [ ] 오답·부분정답 건의 Investigation Timeline 분석
- [ ] 실패 패턴 분류

### 4-2. Runbook 작성

- [ ] OOMKilled 유형: 코드 vs 설정 분기 로직 작성
- [ ] 기타 오답 유형 Runbook 보완

### 4-3. 재주입 (각 3회)

- [ ] 시나리오 1~6 재주입 (18회)
- [ ] 전 건 채점

### 4-4. Phase 4 종료 조건

- [ ] 최적화 전후 적중률 비교
- [ ] 개선폭 측정

**중단 기준**: 개선폭 1건 이하 → Phase 5 진행 안 함

---

## Phase 5 — Kiro Crew 조치 레이어

### 5-1. Crew 설치

- [ ] Crew EC2 인스턴스 기동
- [ ] `kirocrew service install` → systemd 등록
- [ ] Slack 토큰 연결 (`~/.kiro/crew/.env`)
- [ ] `kirocrew doctor` 통과
- [ ] read-only kubeconfig 주입
- [ ] Slack DM에서 수동 질의로 권한 검증

### 5-2. H5 연결 방식 확정 (§6.1)

- [ ] A안 검증: DevOps Agent → Generic Webhook → Crew
- [ ] 불가 시 B안: Slack 채널 observe 모드 + 파싱 폴백 구현

### 5-3. Tier 2 승인 플로우 구현

- [ ] Slack Block Kit 승인 버튼 구현
- [ ] 승인 후 `kirocrew-triage-operator` AssumeRole (세션 15분)
- [ ] `rollout undo` 실행 → 결과 Slack 회신
- [ ] 시나리오 1, 2로 왕복 검증

### 5-4. 포스트모템 초안 생성

- [ ] 포스트모템 스킬 작성
- [ ] 검증

### 5-5. Phase 5 종료 조건

- [ ] H5 연결 안정성 확인
- [ ] 승인 → 조치 → 회신 왕복 성공

**중단 기준**: H5 A/B/C 모든 연결 방식 실패

---

## Phase 6 — 보조 경로

### 6-1. alt-path 모듈 apply

- [ ] `modules/alt-path` apply
  - CloudWatch 알람 (5xx 비율, p99 레이턴시)
  - SNS 토픽
  - Lambda 브리지 (15분 중복 억제 포함)
- [ ] Crew 웹훅 연결

### 6-2. 시나리오 7 주입 (3회)

- [ ] `inject-07-pool-exhaustion.sh` 실행 (3회)
- [ ] Operator 미감지 확인 (정상 동작)
- [ ] 보조 경로 → Crew 트리아지 동작 확인

### 6-3. 평가

- [ ] Crew 1차 트리아지 품질 평가
- [ ] 중복 억제 동작 확인

---

## Phase 7 — 결과 정리

- [ ] 시나리오별 채점 결과 전수 취합
- [ ] 실패 유형 분석 및 원인 추정 문서화
- [ ] 아키텍처 한계 정리
- [ ] 프로덕션 도입 전제 조건 정리
- [ ] 테스트 하네스 정리 및 공개 준비
- [ ] 기술 블로그 초안 작성

---

## 공통 체크 — 주입 전 매번 확인

```
□ Operator Pod Running
□ reset.sh 실행 → 정상 상태 확인
□ 이전 S3 아티팩트 경로 정리 (run_id 기록)
□ 채점 양식 run_id 채번
```

## 비용 통제

```bash
# 야간 노드그룹 스케일다운
terraform apply -var="node_desired_size=0"

# 재개
terraform apply -var="node_desired_size=2"
```
