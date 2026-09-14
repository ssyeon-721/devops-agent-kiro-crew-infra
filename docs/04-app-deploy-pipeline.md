# 앱 배포 파이프라인 이해 가이드

> 이 문서는 테스트 워크로드(web-poc)를 EKS에 배포하기 위해 왜 Docker, ECR, GitHub Actions CI, OIDC 같은 것들이 필요한지를 설명한다.
> "코드를 짰는데 왜 바로 클러스터에 안 올라가고 이 많은 단계를 거치지?"에 대한 답이다.

---

## 1. 큰 그림 — 코드가 클러스터까지 가는 길

우리가 짠 Python 코드(`app/main.py`)가 EKS에서 실행되기까지는 이런 여정을 거친다.

```
소스 코드            컨테이너 이미지        이미지 저장소         쿠버네티스
(main.py)   ──빌드──►  (Docker image)  ──푸시──►  (ECR)   ──배포──►  (EKS Pod)
```

각 단계가 왜 필요한지 하나씩 보자.

---

## 2. 왜 Docker 이미지로 만드나

EKS(쿠버네티스)는 "소스 코드"를 실행하지 않는다. **컨테이너 이미지**를 실행한다.

- 소스 코드만 있으면: Python 버전은? 설치된 라이브러리는? OS는? — 실행 환경이 불확실하다
- 컨테이너 이미지: 코드 + 파이썬 + 라이브러리 + OS를 통째로 하나로 묶은 것. 어디서 실행하든 똑같이 동작한다

우리 `Dockerfile`이 하는 일이 바로 이 포장이다:
```dockerfile
FROM python:3.12-slim        # 파이썬 3.12가 깔린 OS 베이스
COPY app/requirements.txt .
RUN pip install ...          # 라이브러리 설치
COPY app/ .                  # 우리 코드 복사
CMD ["uvicorn", "main:app"]  # 실행 명령
```

즉 "이 코드가 돌아갈 환경을 통째로 박제한다"고 보면 된다.

---

## 3. 왜 ECR이 필요한가

이미지를 만들었으면, EKS가 그걸 가져갈 수 있는 곳에 둬야 한다. 그 창고가 **ECR(Elastic Container Registry)**다.

- 내 노트북에만 이미지가 있으면 EKS가 못 가져간다
- ECR에 올려두면(push) EKS 노드가 거기서 이미지를 내려받아(pull) Pod로 띄운다

우리는 Terraform으로 ECR 레포 2개를 이미 만들었다:
- `poc-eks-incident-app` — 테스트 워크로드용
- `poc-eks-incident-operator` — Operator용

그래서 흐름은: **로컬/CI에서 빌드 → ECR에 push → EKS가 pull**.

---

## 4. 여기서 문제가 생겼다 — 왜 로컬 빌드를 못 했나

원래 계획은 내 맥에서 `docker build` 해서 ECR에 올리는 거였다. 그런데 막혔다.

### 4.1 아키텍처(CPU) 불일치 문제

- 내 맥: **Apple Silicon (arm64)** CPU
- EKS 노드: **x86_64 (amd64)** CPU

arm64에서 만든 이미지는 amd64 노드에서 안 돈다. 크로스 빌드가 필요한데, 이건 Docker의 에뮬레이션(QEMU/Rosetta) 기능에 의존한다.

### 4.2 Rosetta 설치 실패

그 에뮬레이션에 필요한 Rosetta 설치가 이 맥에서 실패했다:
```
Failed to install Rosetta. (VZErrorDomain Code=1)
```
그래서 Docker 데몬 자체가 제대로 안 떴고, 로컬 빌드 경로가 막혔다.

### 4.3 그래서 CI로 우회했다

**GitHub Actions**의 실행 환경(러너)은 원래 amd64 리눅스다. 거기서 빌드하면:
- 내 맥의 arm64 문제와 무관
- Rosetta 같은 에뮬레이션 불필요
- 커밋할 때마다 자동으로 빌드/푸시됨

즉 로컬 환경 문제를 근본적으로 우회하는 셈이다. 게다가 원래 설계(§8.2)에서도 app은 CI로 빌드하기로 돼 있었으니, 결과적으로 제 갈 길을 간 것이다.

---

## 5. CI가 AWS에 접근해야 한다 — 여기서 OIDC가 등장

GitHub Actions(CI)가 ECR에 이미지를 push하려면 **AWS 접근 권한**이 필요하다. GitHub는 외부 서비스인데, 어떻게 우리 AWS 계정에 안전하게 접근시킬까?

### 5.1 나쁜 방법 — 액세스 키를 GitHub에 저장

가장 쉬운 방법은 AWS 액세스 키(비밀번호 같은 것)를 GitHub Secrets에 넣는 것이다. 하지만:

- 키가 유출되면 계정이 통째로 위험하다
- 키는 만료가 없어서 한번 새면 계속 위험하다
- 누가 언제 만든 키인지 관리가 어렵다

### 5.2 좋은 방법 — OIDC 페더레이션

**OIDC(OpenID Connect)**는 "키 없이" 신뢰 관계로 접근을 허용하는 방식이다.

비유하면:
- 나쁜 방법 = GitHub에게 집 열쇠 복사본을 그냥 준다 (잃어버리면 큰일)
- OIDC = "GitHub의 이 레포에서 온 요청이면, 그때그때 15분짜리 임시 출입증을 발급한다"

동작 원리:
```
1. GitHub Actions가 실행되면 GitHub가 "이건 ssyeon-721/poc-eks-incident-app 레포의
   워크플로우다"라는 신분증(토큰)을 발급한다.

2. 그 토큰을 들고 AWS에 "나 이 역할 좀 쓸게" 요청한다 (AssumeRole).

3. AWS는 미리 등록해둔 신뢰 관계를 확인한다:
   "token.actions.githubusercontent.com에서 왔고, 지정된 레포가 맞네" → 허용

4. AWS가 15분~1시간짜리 임시 자격증명을 내준다. 그걸로 ECR에 push.

5. 작업 끝나면 자격증명은 자동 만료. 저장된 영구 키가 없다.
```

### 5.3 우리가 Terraform으로 만든 것

이 신뢰 관계를 세우려고 `modules/github-oidc`에서 두 가지를 만들었다:

| 리소스 | 역할 |
|--------|------|
| OIDC Provider | "GitHub Actions 토큰을 신뢰한다"고 AWS에 등록 |
| IAM Role `github-actions-terraform` | GitHub Actions가 빌려 쓸 역할. ECR push 권한만 최소로 부여 |

신뢰 정책에는 **지정한 레포에서 온 요청만** 허용하도록 조건을 걸었다:
```
"token.actions.githubusercontent.com:sub" = "repo:ssyeon-721/poc-eks-incident-app:*"
```
그래서 아무 GitHub 레포나 이 역할을 못 쓴다. 우리 레포만 쓸 수 있다.

---

## 6. gh CLI는 왜 썼나

`gh`는 GitHub 공식 명령줄 도구다. GitHub 웹사이트에서 클릭으로 하던 걸 터미널 명령으로 한다.

git과 다르다:
- **git**: 코드 버전 관리 (커밋, 푸시)
- **gh**: GitHub 서비스 조작 (레포 생성, Actions Secrets 설정 등)

여기서 gh가 필요한 이유:
- app을 **별도 레포로 분리**해야 한다 (CI 워크플로우는 레포 루트의 `.github/`에서만 동작하므로)
- 그 레포에 **Secrets 2개**를 넣어야 한다 (`AWS_ACCOUNT_ID`, `ECR_REPO`) — CI가 어느 계정, 어느 ECR에 올릴지 알아야 하니까

이 작업들을 웹에서 일일이 클릭하는 대신, gh 명령으로 자동화한다.

---

## 7. 전체 조립 — 최종 흐름

지금까지 등장한 것들이 어떻게 하나로 이어지는지:

```
[개발자]
   │ git push (app 레포)
   ▼
[GitHub 레포: poc-eks-incident-app]
   │ push 이벤트가 CI를 트리거
   ▼
[GitHub Actions CI]  ── amd64 러너에서 docker build
   │
   │ OIDC로 AWS에 임시 자격증명 요청 (키 없음)
   ▼
[AWS: github-actions-terraform 역할]  ── ECR push 권한 부여
   │
   │ docker push
   ▼
[ECR: poc-eks-incident-app]
   │
   │ kubectl apply → EKS가 이미지 pull
   ▼
[EKS: web-poc Pod 실행]
```

정리하면, 우리가 한 세팅은 이 파이프라인을 한 번 깔아두는 작업이었다. 한번 만들어두면 앞으로는 **코드 커밋 → 자동 빌드 → 자동 푸시**가 손 안 대고 굴러간다.

---

## 8. 왜 이렇게까지 하나 (한 줄 정리)

> "코드를 클러스터에서 실행하려면 컨테이너로 포장(Docker)하고, 창고에 넣고(ECR), 자동으로 나르는 컨베이어(CI)를 깔아야 한다.
> 그 컨베이어가 창고에 접근하려면 열쇠가 필요한데, 영구 열쇠(액세스 키)는 위험하니 그때그때 임시 출입증(OIDC)을 쓴다."

로컬에서 한 번 빌드해서 올리는 것보다 초기 세팅은 번거롭지만, 재현 가능하고 안전하고 자동화된다는 이점이 있다. 특히 이 PoC는 이미지를 여러 번 다시 빌드(시나리오 1의 누수 커밋 등)하므로 자동 파이프라인의 가치가 크다.

---

## 9. Operator는 어떻게 배포되나 (Phase 2)

테스트 워크로드(app)와 흐름은 같지만, Operator는 **우리가 짠 코드가 아니라 외부 오픈소스**라는 점이 다르다. 그래서 "소스를 우리 레포로 가져오는" 단계가 하나 더 붙는다.

### 9.1 전체 흐름

```
[1] GitHub 오픈소스 (aws-samples 모노레포)
    kr-tech-blog-sample-code/containers/devops-agent-operator/
        │  이 하위 폴더의 소스만 가져옴
        ▼
[2] 우리 GitHub 레포 (poc-eks-incident-operator, 새로 생성)
        │  가져온 소스를 넣고 push
        ▼
[3] GitHub Actions CI  ← EKS 안이 아니라 GitHub의 amd64 러너에서 빌드
        │  docker build 로 컨테이너 이미지 생성
        │  OIDC 로 AWS 임시 자격증명 획득
        ▼
[4] ECR (poc-eks-incident-operator)  ← 코드가 아니라 "이미지"를 저장
        │
        │  kubectl apply → EKS 가 이미지 pull
        ▼
[5] EKS: Operator Pod 실행
```

### 9.2 자주 헷갈리는 두 가지

**(1) 빌드는 EKS 안에서 하지 않는다.**
빌드는 GitHub Actions 러너(GitHub이 제공하는 임시 리눅스 서버)에서 한다. EKS는 다 만들어진 이미지를 *받아서 실행*만 한다.
- 왜 CI에서 빌드하나: 이 맥은 arm64인데 EKS 노드는 amd64라 로컬 빌드가 막혔다(§4, Rosetta 설치 실패). GitHub Actions 러너는 amd64라 이 문제가 없다. app 이미지도 같은 이유로 CI에서 빌드했다.

**(2) ECR에 저장되는 건 코드가 아니라 이미지다.**
- 코드(Go 소스) → **GitHub 레포**에 저장
- 이미지(코드를 컨테이너로 포장한 결과물) → **ECR**에 저장

Dockerfile이 하는 일이 "Go 코드 + 실행 환경"을 하나의 이미지로 굽는 것이다. EKS는 소스코드를 실행할 수 없고 이미지만 실행할 수 있어서 이 포장 단계가 필요하다.

### 9.3 왜 굳이 우리 레포로 옮기나

남의 모노레포 하위 폴더를 그대로 쓸 수 없는 이유가 두 가지다.
- GitHub Actions CI는 **레포 루트의 `.github/`** 에서만 동작한다. 우리가 제어하는 레포가 필요하다.
- OIDC로 ECR에 push하려면 그 레포가 **AWS 신뢰정책(`modules/github-oidc`)에 등록**돼야 한다. 그래서 새 레포를 만들면 OIDC 정책에 레포를 추가하는 terraform apply가 따라온다.

### 9.4 app과의 차이 한눈에

| 구분 | app (web-poc) | Operator |
|------|---------------|----------|
| 코드 출처 | 우리가 직접 작성 | 외부 오픈소스(aws-samples)를 가져옴 |
| GitHub 레포 | `poc-eks-incident-app` | `poc-eks-incident-operator` (신규) |
| ECR 레포 | `poc-eks-incident-app` | `poc-eks-incident-operator` |
| 빌드 위치 | GitHub Actions (amd64) | 동일 |
| 배포 방식 | kubectl apply | 동일 (RBAC/ConfigMap/Deployment) |
