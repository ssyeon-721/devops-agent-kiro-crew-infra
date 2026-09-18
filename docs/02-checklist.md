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
- [x] H5 조사 완료 (§6.1) — EventBridge 네이티브 연동(`Investigation Completed`)으로 해결. 실측은 Phase 5

---

## Phase 2 — Operator 단독 검증

### 2-1. Operator 배포

- [x] DevOps Agent Operator 소스 코드 확보
  - 소스 위치: `aws-samples/kr-tech-blog-sample-code`의 `containers/devops-agent-operator/` (전용 레포 아님, docs/01 참고자료 정정 완료)
  - sparse-checkout으로 해당 디렉터리만 받아 별도 레포 `poc-eks-incident-operator`로 분리 (app과 동일 원리, docs/04 §9 / docs/05)
- [x] Dockerfile 빌드 → ECR (`poc-eks-incident-operator`) 푸시
  - 로컬 arm64 빌드 불가(§docs04) → GitHub Actions CI(amd64)로 빌드, OIDC AssumeRole
  - OIDC 신뢰정책(`github_repos`)에 operator 레포 추가 → `terraform apply`
  - 이미지 태그: `latest` + 커밋 SHA
- [x] K8s RBAC 매니페스트 적용
  - ClusterRole: pods, pods/log, events, nodes (get/list/watch), pods patch(processed 마킹), batch/jobs, coordination/leases(leader election)
  - ClusterRoleBinding → SA `devops-agent-operator` (ns `devops-agent-operator-system`)
- [x] ConfigMap 설정
  - `EXCLUDE_NAMESPACES=kube-system,kube-public,kube-node-lease`
  - `ENABLE_SSM_COLLECTION=true`
  - `AWS_REGION=ap-northeast-2`, `S3_BUCKET=poc-eks-incident-artifacts-084828589246`, `CLOUDWATCH_LOG_GROUP=cw-log-group-devops-agent-operator`
- [x] Operator Deployment 배포
  - **Pod Identity 네임스페이스 버그 수정**: `operator-iam` 모듈의 association namespace가 `devops-agent-operator`로 잘못 지정돼 있었음(SA명과 혼동). 표준 매니페스트 네임스페이스 `devops-agent-operator-system`으로 정정 후 apply. 안 고쳤으면 IAM 권한 미주입으로 S3/SSM 수집 전부 실패했을 것.
  - **Phase 2 더미 webhook**: 코드가 webhook URL/secret을 필수 검증(`config.Validate`)하나, Agent 부재 시점이라 더미값 주입. `pod_controller.go` 확인 결과 webhook 전송은 S3/CloudWatch 저장 이후 실행되며 실패해도 무시되므로 수집 검증에 영향 없음. Phase 3에서 실제 값으로 교체.
- [x] Operator Pod 로그로 정상 기동 확인
  - Pod `1/1 Running`, Log/SSM/CloudWatch/S3 client 초기화 성공, leader lease 획득, Pod controller worker 기동 확인

### 2-2. 시나리오 주입 (각 3회)

> 주입 전 체크: Operator Pod Running 확인, `reset.sh` 실행으로 초기 상태 확인

- [x] 시나리오 1 — 코드 메모리 누수 (정식 3회 완료, 3/3 성공)
  - 누수 코드를 실제 커밋으로 추가 후 배포 필수
  - **베이스라인 확립**: app `main.py`에서 `/leak` 제거 → 정상 이미지(`a890513`) 빌드/배포. 이후 `/leak`을 별도 커밋(`08d9807`)으로 추가 = 시나리오 1의 ground_truth 커밋
  - **정식 결과** (SSM 권한 수정 후): 3회 모두 OOMKilled 감지 ✅ + S3 14종(파드 5 + 노드 9) 완전 수집 ✅
    - official-1: `incidents/2026-09-14T04-42-23Z/` (14종)
    - official-2: `incidents/2026-09-14T04-47-53Z/` (14종)
    - official-3: `incidents/2026-09-14T04-50-43Z/` (14종)
  - ⚠️ **발견/수정한 버그**: `operator-iam` 정책의 `ssm:GetCommandInvocation` 리소스 범위가 instance/document로 한정돼 있어 노드 로그 9종 전부 누락. `GetCommandInvocation`은 command invocation 리소스 대상이라 별도 statement(Resource="*")로 분리 후 apply → 해결 (파일럿 run1 5종 → run2/정식 14종)
  - ⚠️ **주입 시 주의**: inject 스크립트가 rollout 직후 Pod를 잡는데, 롤아웃 중 대상 Pod가 교체되면 누적 메모리가 날아가 OOM이 안 남. rollout 완료 대기 후 안정된 Pod에 `/leak?mb=50` 집중 호출해야 함. exec가 OOM으로 응답 없이 끊겨도 실제 OOM은 발생하므로 Pod RESTARTS/S3 결과로 판정
- [x] 시나리오 2 — limit 축소 (정식 3회 완료, 3/3 성공)
  - **베이스라인 재정의**: 시나리오 1의 `/leak`(누수)은 제거하고, 정상 처리 엔드포인트 `/work?mb=N`을 추가한 새 베이스라인 커밋(`163da4a`)으로 빌드.
    - `/work`는 요청 처리 중 임시로 메모리를 쓰고 반환하는 **정상 기능**(누수 아님). 커밋 이력상 누수 추가가 없으므로 시나리오 2의 "코드 변경 없음" 신호가 성립.
  - **주입 방식**: limit 512Mi→128Mi 축소 + `/work?mb=100` 호출. 앱 기본(~33MB)+100MB > 128Mi라 **정상 요청 하나로 OOMKilled**. 운영 현실("코드 정상, limit 설정 실수로 부하 시 OOM")과 일치.
  - **정식 결과**: 3회 모두 OOMKilled 감지 ✅ + S3 14종 완전 수집 ✅
    - official-1: `incidents/2026-09-14T05-20-04Z/` (14종)
    - official-2: `incidents/2026-09-14T05-22-34Z/` (14종)
    - official-3: `incidents/2026-09-14T05-24-11Z/` (14종)
  - ⚠️ **주의**: reset(512Mi)→patch(128Mi) 2회 스펙 변경이 롤아웃을 두 번 유발해, 롤아웃 완전 안정 후 Pod를 잡아야 함(아니면 대상 Pod가 교체돼 호출이 유실). inject-02 스크립트는 `/leak`→`/work?mb=100` 순차 호출로 수정.
  - ⚠️ **증상은 시나리오 1과 동일(OOMKilled/137)**, 차이는 원인(코드 누수 vs limit 축소). 이 구분이 H3 검증 대상.
- [x] 시나리오 3 — 잘못된 DB_HOST (정식 3회 완료, 3/3 성공)
  - **코드 수정 필요했음**: 기존 lifespan은 DNS 실패를 잡고 로그만 남겨 앱이 안 죽었음 → Operator가 감지 못 함(문서 의도와 불일치). DNS 실패 시 **fail-fast(예외 re-raise)**로 변경해 CrashLoop 유도.
  - **정상값도 함께 수정**: 기존 정상 `DB_HOST=db.internal`은 클러스터에서 DNS 해석이 안 됨 → fail-fast 코드 넣으면 정상 상태에서도 죽어 다른 시나리오 baseline이 깨짐. 정상값을 `kubernetes.default.svc.cluster.local`(항상 해석됨)로 변경. 베이스라인 커밋 `b77144e`.
  - **정식 결과**: 3회 모두 감지(ContainerTerminated/Error → CrashLoopBackOff) ✅ + S3 14종 완전 수집 ✅ + previous 로그에 결정적 신호 `DB_HOST DNS resolution FAILED: nonexistent-db.invalid` 확보 ✅
    - official-1: `incidents/2026-09-14T05-54-39Z/` (14종)
    - official-2: `incidents/2026-09-14T05-57-45Z/` (14종)
    - official-3: `incidents/2026-09-14T05-59-11Z/` (14종)
  - ⚠️ 감지 형태가 시나리오 1·2(OOMKilled)와 다름: 잘못된 설정으로 **기동 자체가 실패**(CrashLoopBackOff, exitCode 3). inject-03의 rollout timeout은 새 Pod가 Ready 안 되는 정상 결과.
- [x] 시나리오 4 — 잘못된 이미지 태그 (정식 3회 완료, 3/3 성공)
  - **코드 수정 불필요**: 존재하지 않는 이미지 태그(`nonexistent-tag-99999`)로 배포 → 이미지 pull 실패. 앱 코드와 무관.
  - **정식 결과**: 3회 모두 감지(ImagePullBackOff/ErrImagePull) ✅ + S3 13종 수집 ✅ + pod-describe Events에 결정적 신호 `ErrImagePull ... not found` 확보 ✅
    - official-1: `incidents/2026-09-14T06-13-09Z/` (13종)
    - official-2: `incidents/2026-09-14T06-15-19Z/` (13종)
    - official-3: `incidents/2026-09-14T06-16-30Z/` (13종)
  - ⚠️ 컨테이너가 한 번도 기동하지 못하므로 `logs/`(컨테이너 로그)가 없어 **13종**(파드 4 + 노드 9). 결정적 신호는 Events 타임라인. 로그 부재는 이 시나리오에서 정상.

### 2-3. 검증

- [x] S3 아티팩트 완전성 검증 (주입 12회 = 4시나리오 × 3회, 전부 확인 완료)
  - 실제 수집 파일(블로그/Operator README 기준):
    - 파드 레벨: `collected-data.json`, `failure-info.json`, `pod-manifest.yaml`, `pod-describe.yaml`, `logs/<container>.log`, `logs/<container>-previous.log`
    - 노드 레벨(SSM) 9종: `kubelet.log`, `containerd.log`, `dmesg.log`, `ipamd.log`, `ipamd-introspection.log`, `networking.txt`, `disk-usage.txt`, `inode-usage.txt`, `mem-usage.txt`
  - **시나리오별 실측 수집량**: 1·2·3번 = 14종(파드 5 + 노드 9), 4번 = 13종(파드 4 + 노드 9, 컨테이너 미기동으로 로그 없음). 모두 시나리오 특성상 기대되는 결정적 신호 포함 → 완전.
- [x] 누락 아티팩트 있으면 IAM/SSM 설정 재점검 → 노드 9종 누락 이슈는 SSM `GetCommandInvocation` 권한 수정으로 해결(2-1 기록)

### 2-4. Phase 2 종료 조건

- [x] 감지율 100% (주입 12회 전부 감지: 시나리오 1~4 각 3회)
- [x] 수집 완전성: 각 회차에서 시나리오별 기대 아티팩트 누락 없음
- [x] 결과 간단 정리 (아래 요약)

**Phase 2 결과 요약**
| 시나리오 | 원인 | 감지 형태 | 수집 | 결정적 신호 |
|----------|------|-----------|------|-------------|
| 1 코드 메모리 누수 | 코드 | OOMKilled | 14종 | dmesg OOM killer |
| 2 limit 축소 | 설정 | OOMKilled | 14종 | manifest limit 축소 |
| 3 잘못된 DB_HOST | 환경변수 | CrashLoop/Error | 14종 | previous 로그 DNS 실패 |
| 4 잘못된 이미지 태그 | 배포 | ImagePullBackOff | 13종 | Events ErrImagePull |

- **감지율 12/12 (100%)**, 수집 완전성 전부 충족 → H1·H2 실증 완료
- 시나리오 1 vs 2는 증상(OOMKilled) 동일, 원인만 다름 → H3(Agent 구분)의 검증 준비 완료
- **중단 기준 해당 없음** → Phase 3 진행 가능

**중단 기준**: 감지율 100% 미달이고 원인이 설정 문제가 아닌 경우 → Phase 3 진행 안 함

---

## Phase 3 — DevOps Agent 연동 ★

### 3-1. DevOps Agent 설정 (콘솔 수동)

- [x] Agent Space 생성 (**도쿄 `ap-northeast-1`** — 서울 미지원, §3.1)
  - 이름: `poc-eks-incident-agent`
  - 크로스 리전으로 서울 EKS 조사 (사전 검증 완료)
- [x] Generic Webhook 발급
  - **HMAC Secret: CSV 즉시 다운로드 (재조회 불가)** → 완료
  - Secrets Manager에 저장: `poc-devops-agent-incident-webhook` (ap-northeast-2, 키 `webhook-secret`)
  - Webhook URL: `https://event-ai.ap-northeast-1.api.aws/webhook/generic/8c52ce55-...` (도쿄, 크로스 리전)
- [x] GitHub Pipeline 연동 (app 레포 `poc-eks-incident-app`만 Source로 추가)
- [x] Slack Communication 연동 (`#devops-agent-kiro-crew` 채널, 앱 초대 확인)
- [x] Operator 환경변수에 Webhook URL 주입, 재배포
  - `05-deployment.yaml`의 `DEVOPS_AGENT_WEBHOOK_URL`을 실제 URL로 교체
  - HMAC Secret은 git에 커밋하지 않음: Secrets Manager에서 읽어 K8s Secret으로 주입(`kubectl create secret ... --dry-run | apply`). `06-webhook-secret.yaml`은 주입 명령 안내용 주석만 유지
  - 재배포 후 로그에서 실제 webhookURL 로드 확인 완료

- [x] **연결 검증 (end-to-end)**: 시나리오 4 1회 주입으로 전체 경로 확인
  - Operator webhook 전송 → **`status: 200`** (Phase 2 더미의 connection refused와 대비)
  - 도쿄 Agent가 서울 EKS 장애를 크로스 리전으로 수신 → `Investigation started: Pod ErrImagePull: poc/web-poc-557b67c77-qtq6h`
  - Slack `#devops-agent-kiro-crew`에 조사 시작 알림 수신 확인
  - 경로: 장애 → Operator 감지·수집(서울) → S3 저장 → webhook 200 → 도쿄 Agent 조사 시작 → Slack ✅
  - ⚠️ **첫 조사에서 Agent 권한 문제 3건 발견 (조사 결과 리포트로 드러남)** — 원인 진단(nonexistent 이미지 태그)은 ECR 조회로 정확히 맞혔으나, 아래 접근 실패로 "Investigation failed" 판정:
    1. **EKS API 접근 거부**: Agent 역할이 클러스터 access entry에 없었음 → `modules/eks`에 Agent 역할 access entry + `AmazonEKSViewPolicy`(읽기 전용) 추가
    2. **S3 아티팩트 AccessDenied**: Agent 역할이 인시던트 버킷 읽기 권한 없었음 → `modules/storage`에 Agent 역할 S3 GetObject/ListBucket 인라인 정책 추가
    3. **control-plane 로깅 off**(audit trail 부재): 활성화 시도했으나 워커 서브넷 /28(시나리오6용) IP 부족으로 EKS가 거부 → 보류(audit은 보조 신호, 원인 진단엔 지장 없음). 향후 넓은 서브넷 확보 시 재시도.
  - Agent 조사 역할: `DevOpsAgentRole-AgentSpace-6j8n9zaq` (콘솔 auto-create, tfvars에 기록). Agent Space 재생성 시 접미사 변경되므로 값 갱신 필요.
  - ⚠️ **진행 교훈**: Agent 조사가 끝나기 전에 reset하면 라이브 리소스 조회가 실패할 수 있음 → 조사 완료까지 대기 후 reset.

### 3-2. 시나리오 주입 (각 3회)

- [~] 시나리오 1 (3회) — 코드 메모리 누수 (1회차 완료·**정답**, 2·3회차 예정)
  - ground_truth: 코드 메모리 누수, 원인 커밋 `c1cfa31` (`/leak` 추가)
  - **P3-S01-1**: `incidents/2026-09-14T07-57-08Z/` — 판정: **정답(correct)**
    - 감지·수집: OOMKilled 감지 ✅, webhook 200 ✅, S3 14종 ✅, dmesg 커널 OOM killer 신호 확보 ✅
    - **Agent 조사 completed (failed 아님)** — EKS/S3 권한 수정 효과 확인
    - **Root cause 정확**: "누수 커밋 `c1cfa311` 배포로 `/leak` 재도입" — 코드 원인으로 진단
    - **원인 커밋 SHA 정확 명시** (`c1cfa311...`) + CI run #10 빌드 시각까지 추적 → GitHub 상관분석 작동 ✅
    - **dmesg 해석 정확**: cgroup 범위 OOM(노드는 5.3Gi 여유) → 노드 OOM 아닌 컨테이너 한도 초과로 구분
    - **H3 관점 핵심**: Agent가 스스로 "512Mi 한도는 정상값이며 이 커밋이 바꾸지 않았다"고 명시 → 시나리오 2(설정 원인)와의 구분 축을 이미 인지. blast radius(단일 파드 국한), 정확한 롤백 대상(revision 37, 잘못된 revision 36 회피)까지 제시.
    - Mitigation: 누수 이미지→정상(`b77144e4`) 롤백 + 주입 루프 중단 + `/leak` 영구 제거 권고
- [ ] 시나리오 1 나머지 2회 (2·3회차)
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

> **진행 방침 (2026-09-14 결정)**: Phase 3의 모든 시나리오를 다 채점하기 전에,
> "시나리오 1 진단 → Crew 조치"의 **end-to-end 한 줄기를 먼저 관통**한다.
> 이유: 이 PoC의 실질 목표는 "정확한 진단이 실제 조치로 이어지는 통합 흐름"이므로,
> 넓게(시나리오 확대)·깊게(3회 반복) 가기 전에 세로 축(진단→조치)을 먼저 증명하는 것이 가치가 크다.
> 시나리오 1은 이미 Agent 진단 정답(1회) 확인됨 → 이걸 조치까지 연결한다.

### 5-0. Crew 구축 실행 순서 (순서도)

```
[1] EC2 기동 + SSM 접속 확인            ← terraform으로 생성됨, 현재 stopped
      │   (인바운드 0, SSM Session Manager 전용)
      ▼
[2] Kiro Crew 소프트웨어 설치            ⚠️ 설치 소스/방법 확인 필요 (최대 불확실성)
      │   kirocrew service install / doctor
      ▼
[3] 연결 구성
      ├── read-only kubeconfig 주입 (reader 역할)
      └── Slack 토큰 연결 (~/.kiro/crew/.env)
      ▼
[4] H5 다리 구축 (terraform)             도쿄 Agent → 서울 Crew
      │   EventBridge(Investigation Completed) → SNS → Lambda → Crew 트리거
      ▼
[5] 조치 플로우 구현
      │   Slack 승인 버튼 → operator 역할 AssumeRole(15분) → rollout undo
      ▼
[6] end-to-end 테스트
          시나리오 1 주입 → Agent 진단 → Crew 조치(롤백) → 해결 확인
```

**현황 / 선행 조건**
- ✅ 이미 있음(terraform): Crew EC2(`i-03d7e0868fb975158`, stopped), IAM 3종(`crew-base-role`/`kirocrew-triage-reader`/`kirocrew-triage-operator`), 보안그룹(인바운드 0)
- ✅ **불확실성 1 해결 — Kiro Crew 소프트웨어 확인**: 공식 오픈소스 `github.com/kirodotdev/KiroCrew` (Apache 2.0), 문서 `kiro.dev/docs/crew`.
  - 설치(AL2023/x86_64): 원라인 `curl -fsSL https://download.crew.kiro.dev/cli.sh | sh` (SHA-256 검증 wheel + 자체 CPython 3.12, system Python 미변경, `kirocrew` PATH 등록)
  - 상주화: `kirocrew service install`(systemd) → `kirocrew doctor`
  - ⚠️ **추가 의존성/제약**: 내부적으로 `kiro-cli`로 모델 접근하며 **Kiro 계정 device-code 로그인 필요**(브라우저 인터랙티브 → SSM 자동화 불가, 사용자 수동 단계). 대시보드는 `localhost:5476`(loopback), Slack 등 메시징은 outbound 연결이라 포트 노출 불필요.
  - ⚠️ 네트워크: Crew EC2는 프라이빗 서브넷 + NAT 아웃바운드(egress all)라 CDN 다운로드 가능 예상 → 설치 시 확인.
- ✅ **불확실성 2 해결 — 조치용 EKS 접근**: `kirocrew-triage-operator` 역할에 EKS access entry(Edit, `poc` 네임스페이스 한정) 추가 완료. `crew-base-role`에 `eks:DescribeCluster` 부여. 5-1에서 kubeconfig/접근 검증까지 완료.
- ⚠️ **불확실성 3 — H5 실측**: EventBridge `Investigation Completed` 이벤트의 실제 페이로드/발생 여부는 미실측(설계만 확정). [4]에서 실측.

### 5-1. Crew 설치

- [x] Crew EC2 인스턴스 기동 (`poc-eks-incident-kiro-crew-host`, running, SSM Online 확인)
- [x] Kiro Crew 설치 — 원라인(`cli.sh`)으로 `kirocrew 0.6.0` 설치 완료 (SSM 경유, `HOME=/root` 지정 필요했음). `/root/.local/bin/kirocrew`, 관리형 CPython 3.12.13
- [x] `kirocrew doctor` 실행 확인 — config dir 생성됨. 남은 의존성 파악:
  - ⚠️ `kiro-cli` not found → **설치 + `kiro-cli login`(device-code, 브라우저 인터랙티브) 필요 — 사용자 수동**
  - ⚠️ `node` not found → 대시보드 프론트엔드에 Node 22+ 필요 (SSM 자동 설치 가능)
  - `kirocrew setup` 초기 설정 필요
- [~] `kiro-cli` 설치 + 로그인
  - [x] `kiro-cli` 설치 완료 (2.21.4, `curl -fsSL https://cli.kiro.dev/install | bash`, SSM 경유)
  - [x] Node.js 22 설치 완료 (AL2023 `dnf install nodejs22`, v22.23.2 — 대시보드 프론트엔드용)
  - ⚠️ **root 설치 → 전용 유저로 전환**: `kirocrew service install`이 "root로 agent 실행 거부"(보안 정책: gateway가 untrusted tool 실행). 전용 유저 `kirocrew`(uid 1001) 생성 후 그 유저 홈에 Crew/kiro-cli 재설치. 로그인은 device-flow(브라우저 자동 오픈 불가 → `kiro-cli login --use-device-flow`)로 진행.
  - [x] `kirocrew` 유저 생성 + Crew 0.6.0 / kiro-cli 2.21.4 재설치 + `setup --agent-only`(config 생성)
  - [ ] **`kiro-cli login` (사용자 수동, kirocrew 유저로)** — `sudo -u kirocrew -H bash -l` → `kiro-cli login --use-device-flow` → 브라우저 device 인증
- [x] systemd 서비스 등록 완료 (`kirocrew.service`, active + enabled)
  - ⚠️ **`kirocrew service install`이 sudo 비밀번호 요구** → 보안 판단: 서비스 계정에 NOPASSWD sudo 상시 부여(A)는 "untrusted tool 실행 계정의 권한 상승 경로"라 거부. 대신 **root로 unit 파일만 일회성 생성(B)** 채택 → `kirocrew` 유저는 sudo 없는 순수 일반 유저로 유지.
  - unit: `User=kirocrew`(비-root 실행), `ExecStart=/home/kirocrew/.local/bin/kirocrew gateway`, HOME/USER/PATH 환경 지정, `Restart=on-failure`, `WantedBy=multi-user.target`
  - gateway + kiro-cli ACP + OS 샌드박스(rlimit/oom) 정상 기동 확인. dashboard `localhost:5476`(loopback)
- [x] Slack 토큰 연결 (`~/.kiro/crew/.env`)
  - Secrets Manager `kiro-crew/slack-tokens`에서 SSM 경유로 주입 완료
  - `crew-base-role`에 `secretsmanager:GetSecretValue` 권한 추가 (kiro-crew/* 경로 한정)
  - `/home/kirocrew/.kiro/crew/.env` 최종 구성 (소유자 `kirocrew`, 권한 `600`):
    ```
    SLACK_BOT_TOKEN=xoxb-...
    SLACK_APP_TOKEN=xapp-...
    KIROCREW_OWNER_ID=U0BNZ6ZE8V7
    ```
  - `kirocrew setup --slack` 실행 완료 (workspace 경로, slash command `/kirocrew`, timezone `Asia/Seoul` 설정)
  - Slack 앱 설정 완료:
    - **Socket Mode**: 활성화
    - **Event Subscriptions**: 활성화 (Socket Mode 사용으로 Request URL 불필요)
    - **Subscribe to bot events**: `app_mention`, `app_home_opened`, `file_change`, `member_joined_channel`, `message.channels`, `message.groups`, `message.im`
    - **Bot Token Scopes**: `app_mentions:read`, `channels:history`, `channels:read`, `chat:write`, `commands`, `files:read`, `files:write`, `groups:history`, `groups:read`, `im:history`, `im:read`, `im:write`, `reactions:write`, `users:read`
    - **Interactivity**: 활성화 (승인 버튼용)
    - Reinstall to Workspace 완료
  - ⚠️ **Kiro 계정 크레딧 초과 → 해결**: 초기 로그인이 회사 계정(`ssyeon@megazone.com`, IAM Identity Center)으로 돼 있어 월간 한도 초과 발생. 개인 계정(`lsyeon721@gmail.com`, Google)으로 재로그인하여 해결.
    - `sudo -u kirocrew -H bash -l` → `kiro-cli logout` → `kiro-cli login --use-device-flow`
  - ✅ **Slack 연결 최종 확인 완료** — `@kiro-crew-bot 안녕` 멘션에 "안녕하세요! 무엇을 도와드릴까요?" 응답 확인 (2026-09-17)
- [x] read-only kubeconfig 주입 + EKS 접근 검증
  - crew-host 모듈: reader 역할 EKS access entry(View, 클러스터 전체) + operator 역할(Edit, `poc` 네임스페이스 한정) 추가
  - base 역할에 `eks:DescribeCluster` 추가(kubeconfig 생성용, 읽기 전용)
  - kubectl v1.31 설치, kirocrew 유저 홈에 kubeconfig 생성(reader 역할 AssumeRole, context `crew-reader`)
  - ⚠️ **네트워크 이슈 해결**: 클러스터 SG가 자기 SG 소속만 443 허용 → Crew(다른 SG)에서 i/o timeout. crew SG→클러스터 SG 443 인바운드 규칙 추가로 해결.
  - ✅ 검증: Crew에서 `kubectl get pods -n poc` 정상 조회 확인
- [x] Slack 연결 (`~/.kiro/crew/.env`) + DM 수동 질의로 권한 검증 ✅ 완료 (2026-09-17)

### 5-2. H5 연결 방식 실측 (§6.1 — D안 EventBridge 확정)

- [x] D안 실측: 도쿄 Agent `Investigation Completed` 이벤트 → EventBridge 규칙 매칭
  - 이벤트 패턴: `source: aws.aidevops`, `detail-type: Investigation Completed/Failed`, agent_space_id 필터
  - Agent Space ID: `0786d7f0-108f-48a6-8c42-b84c5d93cf3b` (도쿄 `poc-eks-incident-agent`)
- [x] `modules/h5-bridge` Terraform 모듈 구성 및 apply (리소스 10개)
  - [도쿄] EventBridge 규칙 `poc-eks-incident-investigation-completed`
  - [서울] SNS 토픽 `poc-eks-incident-h5-bridge`
  - [서울] Lambda `poc-eks-incident-h5-bridge` — SNS 수신 → Slack Bot API 직접 호출
  - Lambda가 Secrets Manager `kiro-crew/slack-tokens`에서 Bot Token 조회 후 `chat.postMessage`
  - Slack 채널: `#devops-agent-kiro-crew` (`C0C1EDPAEMR`)
- [x] **SNS → Lambda → Slack 왕복 확인** (test-h5-002, 2026-09-18)
  - `kiro-crew-bot`이 `#devops-agent-kiro-crew`에 조사 완료 메시지 수신 확인 ✅
  - ⚠️ **설계 변경**: 당초 `kirocrew chat` SSM 방식 → Lambda가 Slack API 직접 호출로 변경
    - 이유: `kirocrew chat`은 터미널 출력만 반환, Slack 발송 안 함
- [ ] 실제 DevOps Agent 조사 완료 이벤트로 왕복 확인 (Phase 3 시나리오 주입 시)

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
