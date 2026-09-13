# Terraform 구조 이해 가이드

> 이 문서는 Terraform을 처음 접하는 사람이 이 프로젝트의 인프라 코드가 어떻게 구성되고 동작하는지 이해하기 위한 안내서다.
> 대상: `poc-eks-incident-infra/`

---

## 1. Terraform이 하는 일 (30초 요약)

Terraform은 "내가 원하는 인프라 상태"를 코드로 적어두면, 실제 AWS에 그 상태를 만들어주는 도구다.

- 코드에 "VPC 1개, EKS 클러스터 1개, 노드 2대"라고 적으면
- Terraform이 AWS API를 호출해서 실제로 그것들을 만든다
- 이미 만든 게 있으면 건드리지 않고, 코드와 실제가 다른 부분만 맞춘다

핵심은 **선언형**이라는 점이다. "어떻게 만들어라(명령형)"가 아니라 "이런 상태였으면 좋겠다(선언형)"고 적으면, 현재 상태와 비교해서 필요한 작업만 알아서 한다.

---

## 2. 3가지 핵심 명령어

실제로 쓰는 명령은 사실상 이 3개다.

| 명령어 | 하는 일 | 언제 |
|--------|---------|------|
| `terraform init` | 백엔드 연결 + 필요한 플러그인(provider) 다운로드 | 최초 1회, 또는 모듈/백엔드 바뀔 때 |
| `terraform plan` | 지금 코드대로 하면 뭐가 바뀌는지 미리보기 (실제 변경 없음) | apply 전에 항상 |
| `terraform apply` | plan 내용을 실제 AWS에 반영 | 진짜 만들 때 |
| `terraform destroy` | 만든 걸 전부 삭제 | 정리할 때 |

`plan`은 읽기 전용이라 마음껏 돌려도 안전하다. 실제 과금이나 변경은 `apply`에서만 일어난다.

---

## 3. 파일과 폴더 구조 이해

### 3.1 파일 확장자

- `.tf` — Terraform 코드 파일. 한 폴더 안의 모든 `.tf`는 이름과 상관없이 합쳐져서 하나로 취급된다. `main.tf`, `variables.tf`로 나누는 건 순전히 사람이 읽기 편하려는 관례다.
- `.tfvars` — 변수에 넣을 실제 값. 코드와 값을 분리하는 용도.

### 3.2 파일 이름 관례

| 파일 | 역할 |
|------|------|
| `main.tf` | 실제 리소스 정의 (VPC, EKS 등) |
| `variables.tf` | 입력 변수 선언 ("이런 값을 받는다") |
| `outputs.tf` | 출력값 선언 ("이 값을 밖으로 내보낸다") |
| `terraform.tfvars` | 변수의 실제 값 |
| `backend.tf` | state를 어디에 저장할지 |

### 3.3 이 프로젝트의 폴더 구조

```
poc-eks-incident-infra/
├── envs/poc/          ← 진입점. 여기서 terraform 명령을 실행한다
│   ├── main.tf        ← 모듈들을 불러와 조립
│   ├── variables.tf   ← 조절 가능한 값들의 선언
│   ├── terraform.tfvars ← 실제 값 (리전, 노드 개수 등)
│   ├── outputs.tf     ← 완성 후 알려줄 정보 (클러스터명 등)
│   └── backend.tf     ← state를 S3에 저장하도록 설정
│
└── modules/           ← 재사용 가능한 부품들
    ├── network/       ← VPC, 서브넷, NAT
    ├── eks/           ← EKS 클러스터, 노드
    ├── operator-iam/  ← Operator 권한
    ├── storage/       ← S3, CloudWatch
    ├── registry/      ← ECR
    └── crew-host/     ← Crew EC2
```

**중요**: `terraform` 명령은 항상 `envs/poc`에서 실행한다. `modules/`는 직접 실행하는 게 아니라 `envs/poc/main.tf`가 불러다 쓰는 부품이다.

---

## 4. 모듈이란? (왜 폴더를 나눴나)

모듈은 그냥 **관련된 리소스를 묶은 폴더**다. 함수랑 비슷하다.

- 함수: 입력(인자)을 받아서 → 처리하고 → 결과(리턴)를 준다
- 모듈: 입력(variables)을 받아서 → 리소스를 만들고 → 결과(outputs)를 준다

### 4.1 모듈 호출 예시

`envs/poc/main.tf`에서 network 모듈을 이렇게 부른다:

```hcl
module "network" {
  source  = "../../modules/network"   # 어느 폴더의 모듈인지
  project = var.project               # 입력값 전달
  region  = var.aws_region
}
```

- `source`: 이 모듈 코드가 어디 있는지
- `project`, `region`: 모듈의 `variables.tf`에 선언된 입력 변수에 값을 넘김

그러면 network 모듈은 결과를 output으로 돌려준다:

```hcl
# modules/network/outputs.tf
output "vpc_id" { value = aws_vpc.main.id }
```

이 값을 다른 모듈에서 `module.network.vpc_id`로 가져다 쓴다.

### 4.2 왜 나누나

한 파일에 다 몰아넣어도 동작은 한다. 그런데 나누면:

- **재사용**: eks 모듈을 다른 프로젝트에서도 씀
- **가독성**: "네트워크 고칠 일 있으면 network 폴더만 보면 된다"
- **격리**: 한 모듈 수정이 다른 모듈에 영향을 주는지 명확

---

## 5. 이 프로젝트의 데이터 흐름 (핵심)

모듈들은 서로 값을 주고받으며 연결된다. 한 모듈의 output이 다른 모듈의 input이 되는 식이다.

```
                  ┌─────────────┐
                  │   network   │  VPC, 서브넷을 만든다
                  └──────┬──────┘
          vpc_id,        │        private_subnet_ids
          worker_subnet  │
          ┌──────────────┼──────────────┐
          ▼              ▼               ▼
     ┌─────────┐                   ┌───────────┐
     │   eks   │                   │ crew-host │
     └────┬────┘                   └───────────┘
          │ cluster_name                 ▲
          │                              │ cluster_name
          ▼                              │
     ┌──────────────┐                    │
     │ operator-iam │                    │
     └──────────────┘                    │
          ▲                              │
          │        ┌─────────┐           │
          └────────┤ storage ├───────────┘
   artifact_bucket │         │ artifact_bucket_arn
   _arn,           └─────────┘ log_group_arn
   log_group_arn

     ┌──────────┐
     │ registry │  ECR (독립적, 다른 모듈에 의존 안 함)
     └──────────┘
```

### 5.1 흐름을 말로 풀면

1. **network**가 먼저 실행돼서 VPC와 서브넷을 만든다.
2. **eks**는 network가 만든 `vpc_id`와 `worker_subnet_ids`를 받아 그 안에 클러스터를 세운다.
3. **storage**는 S3 버킷과 CloudWatch 로그그룹을 만들고 그 ARN(고유 식별자)을 내보낸다.
4. **operator-iam**은 eks의 `cluster_name`과 storage의 ARN들을 받아, "이 클러스터의 Operator가 이 버킷에만 쓸 수 있다"는 권한을 만든다.
5. **crew-host**도 비슷하게 cluster_name과 storage ARN을 받아 Crew EC2와 권한을 만든다.
6. **registry**는 아무에게도 의존하지 않으므로 아무 때나 만들어진다.

### 5.2 Terraform은 순서를 어떻게 아나

여기서 신기한 점: 우리는 "network 먼저, 그다음 eks"라고 순서를 **직접 적지 않았다**.

Terraform이 자동으로 파악한다. `module.eks`가 `module.network.vpc_id`를 참조하는 걸 보고, "아 eks는 network가 끝나야 하는구나"를 스스로 안다. 이걸 **암묵적 의존성**이라 한다.

그래서 코드에 값이 서로 참조되는 관계 = 실행 순서가 된다. 이게 Terraform의 핵심 동작 원리다.

---

## 6. 변수(variable)와 값(tfvars)의 관계

변수는 "받을 자리"를 선언하고, 값은 그 자리에 넣을 실제 데이터다.

**선언** (`envs/poc/variables.tf`):
```hcl
variable "node_desired_size" {
  description = "워커 노드 개수"
  default     = 2          # 값을 안 주면 이걸 씀
}
```

**값 주입** (`envs/poc/terraform.tfvars`):
```hcl
node_desired_size = 2
```

**사용** (`envs/poc/main.tf`):
```hcl
module "eks" {
  node_desired_size = var.node_desired_size   # var.<변수명>으로 참조
}
```

### 6.1 왜 이렇게 나누나 — 비용 통제 실전 예시

이 구조 덕에 코드를 안 고치고 값만 바꿔서 동작을 조절할 수 있다.

노드를 꺼서 비용을 아끼고 싶을 때:
```bash
terraform apply -var="node_desired_size=0"
```

`-var`로 그때만 값을 덮어쓴다. 다시 켜려면 `=2`로 apply. 코드는 그대로 두고 값만 바꾸는 것이다.

---

## 7. State — Terraform의 기억장치

Terraform은 "내가 뭘 만들었는지"를 **state 파일**에 기록한다. 이게 없으면 다음번 실행 때 뭐가 이미 있는지 몰라서 중복 생성하거나 오작동한다.

### 7.1 이 프로젝트의 state 설정

`backend.tf`:
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

state를 로컬이 아니라 **S3 버킷에 저장**한다. 이게 중요한 이유:

- **여러 PC에서 작업 가능**: 집 PC에서 apply → state가 S3에 저장 → 회사 PC에서 init하면 같은 state를 읽음. 그래서 어디서든 이어서 작업할 수 있다.
- **`use_lockfile = true`**: 두 곳에서 동시에 apply하면 서로 덮어써서 state가 깨진다. 락을 걸어 한 번에 하나만 실행되게 막는다.
- **`encrypt = true`**: state 안에는 민감 정보가 평문으로 들어갈 수 있어서 암호화 저장한다.

### 7.2 주의 — state 파일은 절대 손으로 고치지 않는다

state는 Terraform이 관리하는 파일이다. 직접 편집하면 실제 인프라와 어긋나서 문제가 생긴다. `.gitignore`에 `*.tfstate`가 들어있는 이유도 이것 때문이다 (S3에만 두고 git에는 안 올림).

---

## 8. 실제 작업 흐름 (이 프로젝트 기준)

### 8.1 처음 시작할 때
```bash
cd poc-eks-incident-infra/envs/poc
terraform init      # S3 백엔드 연결 + provider 설치
terraform plan      # 뭐가 만들어질지 확인
terraform apply     # 실제 생성 (yes 입력 or -auto-approve)
```

### 8.2 다른 PC에서 이어서 할 때
```bash
git clone <레포>
cd poc-eks-incident-infra/envs/poc
terraform init      # S3에서 기존 state를 읽어옴
terraform plan      # "변경 없음"이 나오면 동기화된 것
```

### 8.3 비용 아끼려 노드만 끌 때
```bash
terraform apply -var="node_desired_size=0"   # 노드 0대
terraform apply -var="node_desired_size=2"   # 다시 2대
```

### 8.4 전부 정리할 때
```bash
terraform destroy   # 만든 리소스 전체 삭제
```

---

## 9. 자주 나오는 용어 정리

| 용어 | 뜻 |
|------|-----|
| provider | AWS 같은 대상 플랫폼과 통신하는 플러그인 |
| resource | 실제로 만들 대상 하나 (VPC, EC2 등). `resource "aws_vpc" "main"` 형태 |
| module | 리소스를 묶은 폴더 (재사용 단위) |
| variable | 모듈/설정에 넘기는 입력값 |
| output | 모듈/설정이 내보내는 결과값 |
| state | 만든 것을 기록한 파일 (S3에 저장) |
| plan | 변경 미리보기 (실제 변경 없음) |
| apply | 실제 반영 |
| `var.X` | 변수 X 참조 |
| `module.X.Y` | 모듈 X의 output Y 참조 |

---

## 10. 이 프로젝트에서 파일을 읽는 추천 순서

Terraform이 처음이라면 이 순서로 읽으면 흐름이 잡힌다.

1. `envs/poc/main.tf` — 전체 조립도. 어떤 모듈들이 어떻게 연결되는지
2. `envs/poc/variables.tf` + `terraform.tfvars` — 어떤 값들을 조절할 수 있는지
3. `modules/network/main.tf` — 가장 기초가 되는 네트워크부터
4. `modules/eks/main.tf` — 그 위에 올라가는 클러스터
5. 나머지 모듈 (storage → operator-iam → crew-host → registry)
6. `envs/poc/outputs.tf` — 다 만들고 나면 뭘 알려주는지

---

## 11. (부록) 문서는 왜 여러 개로 나누나

이건 Terraform 얘기는 아니지만, 이 프로젝트의 `docs/` 폴더가 왜 파일 여러 개로 나뉘어 있는지 궁금할 수 있어서 정리해둔다.

### 11.1 정답이 있는 건 아니다

"문서를 반드시 나눠라" 같은 규칙은 없다. 작은 프로젝트는 `README.md` 하나에 다 넣기도 한다. 나누느냐 합치느냐는 **"찾기 편한가"** 하나로 판단하면 된다.

### 11.2 나누는 기준 — 목적과 수명이 다르면 나눈다

이 프로젝트의 문서들을 보면 성격이 제각각이다.

| 문서 | 목적 | 언제 보나 | 바뀌는 빈도 |
|------|------|----------|------------|
| `01-architecture.md` | 왜 이렇게 설계했나 | 의사결정할 때 | 거의 안 바뀜 (확정본) |
| `02-checklist.md` | 지금 뭘 해야 하나 | 매일 작업할 때 | 자주 바뀜 (체크 표시) |
| `03-terraform-guide.md` | Terraform 학습 | 처음, 막힐 때 | 거의 안 봄 (참고용) |

이렇게 성격이 다른 걸 한 파일에 합치면:

- 매일 보는 체크리스트에 들어갔는데 안 바뀌는 설계 설명이 스크롤을 잡아먹는다
- 설계 결정을 다시 보고 싶은데 진행 체크박스와 섞여 있어 찾기 힘들다
- 파일이 수백 줄이 되면 원하는 부분을 찾는 데 시간이 든다

그래서 **목적이 다르면 파일을 나눈다**가 일반적인 관례다.

### 11.3 파일 앞의 번호 (`01`, `02`, `03`)

파일명 앞 숫자는 **읽는 순서를 암시**하는 흔한 방식이다. 파일 탐색기에서 이름순 정렬하면 01 → 02 → 03 순으로 보이니, "이 순서로 읽으면 된다"는 힌트가 된다. 기능적 의미는 없고 순전히 사람 편의용이다.

### 11.4 합치는 게 나은 경우

반대로 이럴 땐 굳이 안 나눈다:

- 프로젝트가 작아서 전체가 한 화면에 들어올 때
- 내용이 서로 강하게 얽혀서 따로 보면 이해가 안 될 때
- 문서를 보는 사람이 한 곳만 보고 싶어 할 때

### 11.5 한 줄 요약

> 파일을 나누는 이유는 "관심사 분리(separation of concerns)" 때문이다.
> 코드에서 기능별로 모듈을 나누는 것과 똑같은 원리를, 문서에도 적용한 것뿐이다.

실제로 이 프로젝트의 Terraform 코드도 network / eks / storage처럼 관심사별로 모듈을 나눴다(5장 참고). 문서를 나누는 사고방식과 코드를 모듈로 나누는 사고방식은 완전히 같다.
