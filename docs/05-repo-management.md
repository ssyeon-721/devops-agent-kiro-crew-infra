# 레포지토리 관리 방식

> 이 문서는 워크스페이스와 GitHub 레포가 어떻게 연결되어 있고, 코드를 어떻게 커밋/푸시하는지를 설명한다.
> 특히 app 코드와 infra 코드가 서로 다른 레포로 나가는 구조를 다룬다.

---

## 1. 왜 레포를 둘로 나눴나

이 프로젝트는 GitHub 레포가 **2개**다.

| GitHub 레포 | 담는 것 |
|-------------|---------|
| `devops-agent-kiro-crew-infra` | Terraform 인프라 코드 + 문서(docs) |
| `poc-eks-incident-app` | 테스트 워크로드(app) 코드만 |

나눈 이유(아키텍처 문서 §8.2):
- Phase 3에서 DevOps Agent Pipeline에 연동하는 레포는 **app 하나뿐이어야** 한다.
- app 레포의 커밋 이력을 Agent가 분석해서 "이 OOM이 코드 변경(시나리오1) 때문인지, 설정 실수(시나리오2)인지"를 판단한다.
- 여기에 인프라 커밋이 섞이면 그 판단이 오염된다.

즉 레포 분리는 검증 정확성을 위한 설계다.

---

## 2. 워크스페이스는 하나, 레포는 둘

로컬에서 편집하는 워크스페이스는 하나지만, 그 안의 폴더가 각각 다른 GitHub 레포로 나간다.

```
워크스페이스 (로컬 작업 공간)
│
├── docs/                     ─┐
├── poc-eks-incident-infra/   ─┼──► [GitHub] devops-agent-kiro-crew-infra
│                              ─┘
│
└── poc-eks-incident-app/     ────► [GitHub] poc-eks-incident-app
    (자체 .git 보유)
```

핵심:
- **워크스페이스 루트**는 `devops-agent-kiro-crew-infra` 레포에 연결돼 있다.
- **`poc-eks-incident-app/` 폴더**는 그 안에 자체 `.git`을 가지고 `poc-eks-incident-app` 레포에 직접 연결돼 있다.
- 루트 레포는 `poc-eks-incident-app/`을 `.gitignore`로 무시한다. 그래서 두 레포가 서로 안 겹친다.

이 방식의 장점: 모든 코드를 **한 워크스페이스에서 편집**하면서, 커밋만 각자의 레포로 보낸다. 예전처럼 임시 복사본(/tmp)을 만들 필요가 없다.

---

## 3. 커밋/푸시하는 법

### 3.1 인프라나 문서를 수정했을 때

워크스페이스 루트에서 작업한다.

```bash
# 루트에서 (poc-eks-incident-app 폴더 밖)
git add -A
git commit -m "수정 내용"
git push          # → devops-agent-kiro-crew-infra 레포로 나감
```

`poc-eks-incident-app/`은 gitignore돼 있으므로 이 커밋에 안 딸려온다.

### 3.2 app 코드를 수정했을 때

`poc-eks-incident-app/` 폴더 안에서 작업한다.

```bash
cd poc-eks-incident-app
git add -A
git commit -m "수정 내용"
git push          # → poc-eks-incident-app 레포로 나감
```

app 레포에 푸시되면 **CI가 자동으로 이미지를 빌드해서 ECR에 올린다**(docs/04 참고).

### 3.3 헷갈리지 않는 법

"지금 내가 어느 레포에 커밋하는 거지?"가 헷갈리면 확인:

```bash
git remote -v      # 현재 폴더가 어느 레포에 연결됐는지 보여준다
```

- 루트에서 실행 → `devops-agent-kiro-crew-infra`
- `poc-eks-incident-app/`에서 실행 → `poc-eks-incident-app`

---

## 4. 왜 이 방식을 택했나 (다른 선택지와 비교)

app 폴더를 관리하는 방법은 세 가지가 있었다.

| 방식 | 설명 | 채택? |
|------|------|-------|
| infra 레포에서 app 폴더 삭제 | app을 워크스페이스에서 빼고 별도 클론 | ✗ 한 워크스페이스에서 다 못 봄 |
| 임시 복사본(/tmp) 경유 | 편집은 워크스페이스, 푸시는 복사본에서 | ✗ 이중 관리, 매번 복사 필요 |
| **폴더에 자체 .git 연결** | 워크스페이스에서 편집, 폴더에서 직접 푸시 | ✓ 채택 |

채택한 방식은 "한 워크스페이스에서 전부 편집하되, 최종 코드만 각 레포로 올린다"는 요구에 맞는다. 임시 복사본 없이 폴더에서 바로 푸시되므로 관리 지점이 하나로 유지된다.

---

## 5. 주의사항

- **중첩 git(nested repo)**: `poc-eks-incident-app/`은 루트 레포 안에 있으면서 자체 git을 가진다. 루트 `.gitignore`에 `poc-eks-incident-app/`이 있어야 두 git이 충돌하지 않는다. 이 줄을 지우면 안 된다.
- **app 수정 시 위치 확인**: app 파일을 고친 뒤 루트에서 커밋하면 무시된다(gitignore). 반드시 `poc-eks-incident-app/` 안에서 커밋해야 app 레포로 나간다.
- **두 PC에서 작업할 때**: 회사 PC에서 클론하면 app 폴더는 gitignore돼 있어 안 딸려온다. app 레포를 그 폴더 위치에 따로 클론해야 동일 구조가 된다.
