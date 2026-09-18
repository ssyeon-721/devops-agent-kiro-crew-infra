# Kiro Crew 재구축 플레이북

- 문서 버전: v1.0
- 작성일: 2026-09-18
- 목적: **Terraform으로 만든 Crew EC2 위에, Kiro Crew를 설치·설정해 "조사 요약 게시 + Tier 2 롤백"까지 동작시키는** 전 과정을 재현 가능하게 기록.
- 성격: 배포 스킬(`ec2-ssm-cdk-deploy`)과 같은 **반자동 플레이북**. SSM으로 자동화 가능한 건 전부 자동, 사람이 꼭 해야 하는 것(브라우저 로그인, Slack/AWS 콘솔)만 멈춰서 안내.

---

## 0. 전제 조건

이 플레이북은 **인프라(Terraform)가 이미 apply된 상태**를 전제로 한다. Terraform이 만드는 것:

- Crew EC2 (`t3a.large`, AL2023, 프라이빗 서브넷, 인바운드 0) — `modules/crew-host`
- IAM 역할 3종: `crew-base-role`(인스턴스 롤) / `kirocrew-triage-reader` / `kirocrew-triage-operator`
- `crew-base-role` 인라인 권한: SSM 접속, reader/operator AssumeRole, `eks:DescribeCluster`,
  `secretsmanager:GetSecretValue`(kiro-crew/*), `aidevops:ListJournalRecords`/`GetTask`/`ListTasks`
- EKS access entry: reader(View, 클러스터 전체) / operator(Edit, `poc` 네임스페이스)
- crew SG → 클러스터 SG 443 인바운드 규칙
- H5 Bridge (`modules/h5-bridge`): 도쿄 EventBridge → 서울 이벤트버스 → 규칙 → SNS → Lambda

> Terraform이 **관리하지 않는** 것(이 플레이북 + 콘솔 수동): Crew 소프트웨어 설치·설정, kiro-cli 로그인,
> Slack App, DevOps Agent Space/Webhook. (docs/01 §8.4 참조)

### 변수 (환경에 맞게 치환)

| 이름 | 이번 PoC 값 | 비고 |
|------|-------------|------|
| `INSTANCE_ID` | `i-03d7e0868fb975158` | Crew EC2. `terraform output crew_instance_id` |
| `REGION` | `ap-northeast-2` | 서울 |
| `AGENT_REGION` | `ap-northeast-1` | 도쿄 (DevOps Agent) |
| `CLUSTER` | `poc-eks-incident-cluster` | |
| `SLACK_SECRET` | `kiro-crew/slack-tokens` | Secrets Manager (SLACK_BOT_TOKEN, SLACK_APP_TOKEN) |
| `SLACK_CHANNEL` | `C0C1EDPAEMR` | `#devops-agent-kiro-crew` |
| `OWNER_ID` | `U0BNZ6ZE8V7` | Slack 멤버 ID |
| `AGENT_SPACE_ID` | `0786d7f0-108f-48a6-8c42-b84c5d93cf3b` | 도쿄 Agent Space |
| `OPERATOR_ROLE` | `arn:aws:iam::084828589246:role/kirocrew-triage-operator` | 롤백용 |

모든 SSM 명령은 아래 형식으로 실행한다:
```bash
aws ssm send-command --instance-ids <INSTANCE_ID> \
  --document-name AWS-RunShellScript --region <REGION> \
  --parameters '{"commands":["..."]}' \
  --output text --query "Command.CommandId"
# 그 후: aws ssm get-command-invocation --command-id <ID> --instance-id <INSTANCE_ID> --region <REGION>
```

---

## 1. 사전 준비 (사람 · 콘솔 작업) — 설치 전 미리 끝내둘 것

Crew 설치는 시간이 걸리므로, 아래 콘솔 작업을 먼저 해두면 흐름이 안 끊긴다.

### 1-1. Slack App 준비
1. [api.slack.com/apps](https://api.slack.com/apps) → **From scratch**로 앱 생성 (워크스페이스 선택)
2. **Socket Mode** → Enable (App Token `xapp-...` 발급, scope `connections:write`)
3. **OAuth & Permissions → Bot Token Scopes**에 아래 전부 추가:
   `app_mentions:read`, `channels:history`, `channels:read`, `chat:write`, `commands`,
   `files:read`, `files:write`, `groups:history`, `groups:read`, `im:history`, `im:read`,
   `im:write`, `reactions:write`, `users:read`
4. **Event Subscriptions** → Enable → **Subscribe to bot events**:
   `app_mention`, `app_home_opened`, `message.im`, `message.channels`, `message.groups`
5. **Interactivity & Shortcuts** → Enable (Socket Mode면 Request URL 불필요)
6. **Install to Workspace** → Bot Token `xoxb-...` 발급
7. 채널 `#devops-agent-kiro-crew`에 앱 초대, 채널 ID(`C...`) 확보
8. 본인 Slack 멤버 ID(`U...`) 확보 (프로필 → 더보기 → Copy member ID)

### 1-2. Secrets Manager에 Slack 토큰 저장
```bash
aws secretsmanager create-secret --name kiro-crew/slack-tokens --region <REGION> \
  --secret-string '{"SLACK_BOT_TOKEN":"xoxb-...","SLACK_APP_TOKEN":"xapp-..."}'
```
> 이미 있으면 `put-secret-value`로 갱신. **키 이름은 정확히 `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`.**

### 1-3. DevOps Agent Space / Webhook (도쿄 콘솔)
- Agent Space `poc-eks-incident-agent` 생성 (도쿄 `ap-northeast-1`), `agent_space_id` 확보
- Generic Webhook 발급 → HMAC Secret **즉시 CSV 다운로드**(재조회 불가) → Secrets Manager 저장
- GitHub Pipeline에 app 레포 연결, Slack Communication 연결
> 이 값들은 Operator 배포(별도)와 tfvars(`agent_space_id`)에 반영.

---

## 2. Crew 설치 (SSM 자동) — ⏱ 오래 걸림, 단계별 대기

> ⚠️ **설치는 은근 오래 걸린다.** 각 단계 후 `get-command-invocation`으로 `Success` 확인하고 다음으로.
> 다운로드(CDN)·컴파일 때문에 한 스텝이 30초~2분 걸릴 수 있다.

### 2-1. EC2 기동 + SSM Online 확인
```bash
aws ec2 start-instances --instance-ids <INSTANCE_ID> --region <REGION>
# PingStatus가 Online 될 때까지 (최대 2~3분)
aws ssm describe-instance-information --region <REGION> \
  --filters "Key=InstanceIds,Values=<INSTANCE_ID>" \
  --query 'InstanceInformationList[0].PingStatus' --output text
```

### 2-2. 전용 유저 `kirocrew` 생성 (⚠️ 비-root 필수)
> Crew gateway는 untrusted tool을 실행하므로 **root 실행을 거부**한다. 반드시 전용 일반 유저로 설치.
```bash
# SSM commands:
id kirocrew 2>/dev/null || useradd -m -s /bin/bash kirocrew
echo "kirocrew user ready"
```

### 2-3. 의존성 설치 (Node 22, AWS CLI 최신)
```bash
# SSM commands:
dnf install -y nodejs22 2>&1 | tail -2   # 대시보드 프론트엔드용
# AWS CLI를 최신으로 (devops-agent 서비스는 2.36+ 필요 — 2.33은 'Unknown service')
cd /tmp && curl -sSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
unzip -oq awscliv2.zip && ./aws/install --update
/usr/local/bin/aws --version
```
> ⚠️ **AWS CLI 버전 함정**: Lambda/EC2 기본 CLI가 구버전이면 `aws devops-agent list-journal-records`가
> `Unknown service: 'devops-agent'`로 실패한다. 반드시 2.36+ 로 업그레이드.

### 2-4. Crew + kiro-cli 설치 (kirocrew 유저로)
```bash
# SSM commands (kirocrew 유저 홈에 설치):
sudo -u kirocrew -H bash -l -c "curl -fsSL https://download.crew.kiro.dev/cli.sh | sh"
sudo -u kirocrew -H bash -l -c "curl -fsSL https://cli.kiro.dev/install | bash"
sudo -u kirocrew -H bash -l -c "kirocrew --version; kiro-cli --version"
```
> 설치본: `/home/kirocrew/.local/bin/{kirocrew,kiro-cli}`, 관리형 CPython 3.12.
> 이 스텝이 가장 오래 걸린다(wheel 다운로드 + 검증). `Success` 뜰 때까지 여유있게 대기.

### 2-5. Crew 초기 설정 (config 생성)
```bash
sudo -u kirocrew -H bash -l -c "kirocrew setup --agent-only"
```

---

## 3. kiro-cli 로그인 (🙋 사람 수동 — 자동화 불가)

> device-flow 브라우저 인증이라 SSM으로 자동화 못 한다. **개인 계정 권장**(회사 IAM Identity Center 계정은
> 월간 크레딧 한도 초과가 잘 남).

로컬 터미널에서:
```bash
aws ssm start-session --target <INSTANCE_ID> --region <REGION>
# 접속 후:
sudo -u kirocrew -H bash -l
kiro-cli login --use-device-flow
# 출력된 URL을 브라우저에서 열고 코드 입력 → 개인 계정으로 인증
kiro-cli whoami   # 로그인 계정 확인
```
> 확인 포인트: `whoami`가 의도한 계정인지. 회사 계정이면 `kiro-cli logout` 후 재로그인.

---

## 4. 자동 설정 (SSM 자동) — 이 플레이북의 핵심

### 4-1. Slack 토큰 + OWNER_ID를 .env에 주입
```bash
# SSM commands: Secrets Manager에서 토큰 읽어 .env 생성
SECRET=$(aws secretsmanager get-secret-value --secret-id kiro-crew/slack-tokens --region <REGION> --query SecretString --output text)
BOT=$(echo "$SECRET" | python3 -c "import sys,json;print(json.load(sys.stdin)['SLACK_BOT_TOKEN'])")
APP=$(echo "$SECRET" | python3 -c "import sys,json;print(json.load(sys.stdin)['SLACK_APP_TOKEN'])")
mkdir -p /home/kirocrew/.kiro/crew
printf "SLACK_BOT_TOKEN=%s\nSLACK_APP_TOKEN=%s\nKIROCREW_OWNER_ID=<OWNER_ID>\n" "$BOT" "$APP" > /home/kirocrew/.kiro/crew/.env
chown kirocrew:kirocrew /home/kirocrew/.kiro/crew/.env
chmod 600 /home/kirocrew/.kiro/crew/.env
```
> ⚠️ **`KIROCREW_OWNER_ID` 없으면** gateway 로그에 `Slack disabled for security`로 Slack이 통째로 비활성화된다.

### 4-2. Slack 세부 설정 (setup --slack, 인터랙티브)
> 이건 인터랙티브라 SSM 자동화가 까다롭다. `kiro-cli login`과 함께 SSM 세션에서 수동으로:
```bash
sudo -u kirocrew -H bash -l -c "kirocrew setup --slack"
# 프롬프트: App Token(.env값 자동인식) → Bot Token → Member ID → slash command(kirocrew)
#           → timezone(Asia/Seoul) → Dashboard URL(빈칸=localhost) → Run on AWS(N)
```

### 4-3. Crew config 3종 설정 (⚠️ 자율 실행 필수 조건)
```bash
# SSM commands:
sudo -u kirocrew -H bash -l -c "kirocrew config set --local agent.admission_gate false"
sudo -u kirocrew -H bash -l -c "kirocrew config set --local agent.dangerously_skip_permissions true"
sudo -u kirocrew -H bash -l -c "kirocrew config set --local slack.tracking_channels '[{\"channel_id\":\"<SLACK_CHANNEL>\"}]'"
```
| 설정 | 이유 |
|------|------|
| `admission_gate=false` | spawn 시작 시 대시보드 승인 요구 제거 |
| `dangerously_skip_permissions=true` | 도구 실행 승인 프롬프트 제거 (IAM으로 이미 권한 제한됨) |
| `slack.tracking_channels` | **미등록 시 `send_message`가 "not in tracked channels"로 거부** → 요약 게시 실패 |

### 4-4. 에이전트 스펙 allowedTools에 execute_bash 추가
```bash
# SSM commands:
python3 -c "import json;p='/home/kirocrew/.kiro/agents/kirocrew.json';d=json.load(open(p));at=d.get('allowedTools',[]);\
(at.append('execute_bash') if 'execute_bash' not in at else None);d['allowedTools']=at;json.dump(d,open(p,'w'),indent=2)"
chown kirocrew:kirocrew /home/kirocrew/.kiro/agents/kirocrew.json
```
> `execute_bash`가 있어야 Crew가 `aws devops-agent list-journal-records`(요약 조회)를 승인 없이 실행.
> **단, `curl`·`aws s3 cp` 같은 외부 쓰기는 이것과 무관하게 여전히 거부됨** → 외부 전송은 반드시
> Crew 내장 `send_message` 도구 사용(§6 참조).

### 4-5. systemd 서비스 등록 (root로 unit 파일만 생성)
> `kirocrew service install`은 sudo 비밀번호를 요구한다. `kirocrew` 유저에 sudo를 주지 않기 위해
> **root로 unit 파일만 직접 생성**한다.
```bash
# SSM commands (root):
cat > /etc/systemd/system/kirocrew.service <<'EOF'
[Unit]
Description=Kiro Crew Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kirocrew
Group=kirocrew
WorkingDirectory=/home/kirocrew
Environment=HOME=/home/kirocrew
Environment=USER=kirocrew
Environment=PATH=/home/kirocrew/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/kirocrew/.local/bin/kirocrew gateway
Restart=on-failure
RestartSec=5
EnvironmentFile=/home/kirocrew/.kiro/crew/.env

[Install]
WantedBy=multi-user.target
EOF
loginctl enable-linger kirocrew
systemctl daemon-reload
systemctl enable --now kirocrew
sleep 8
systemctl is-active kirocrew
```

### 4-6. kubeconfig 생성 (reader/operator 컨텍스트)
```bash
# SSM commands: kubectl 설치 + reader 컨텍스트 (조사용, 읽기)
sudo -u kirocrew -H bash -l -c "aws eks update-kubeconfig --name <CLUSTER> --region <REGION> --role-arn arn:aws:iam::<ACCT>:role/kirocrew-triage-reader --alias crew-reader"
# operator 컨텍스트 (롤백용, poc 네임스페이스 Edit)
sudo -u kirocrew -H bash -l -c "aws eks update-kubeconfig --name <CLUSTER> --region <REGION> --role-arn <OPERATOR_ROLE> --alias crew-operator"
```
> kubectl v1.31+ 필요. 클러스터 SG→crew SG 443 인바운드는 Terraform이 이미 열어둠(없으면 i/o timeout).

### 4-7. eks-rollback 스킬 배포
```bash
# 로컬의 poc-eks-incident-operator/skills/eks-rollback.md 를 base64로 전송
# SSM commands:
mkdir -p /home/kirocrew/.kiro/crew/skills/eks-rollback
echo "<base64>" | base64 -d > /home/kirocrew/.kiro/crew/skills/eks-rollback/SKILL.md
chown -R kirocrew:kirocrew /home/kirocrew/.kiro/crew/skills/eks-rollback
```
> 스킬 원본은 레포 `poc-eks-incident-operator/skills/eks-rollback.md`. SKILL.md는 YAML frontmatter
> (name/description/triggers) + 본문 형식.

### 4-8. 서비스 재시작 (설정 반영)
```bash
systemctl restart kirocrew && sleep 8 && systemctl is-active kirocrew
cat /home/kirocrew/.kiro/crew/gateway.log   # Slack 에러 없는지 확인
```

---

## 5. 검증 (완료 판정)

### 5-1. doctor
```bash
sudo -u kirocrew -H bash -l -c "kirocrew doctor 2>&1 | grep -iE 'slack|kiro login|gateway|tokens'"
# 기대: kiro login ✅, Slack tokens ✅ configured, owner ✅, gateway ✅ running
```

### 5-2. Slack 왕복 (사람)
- Slack에서 `@kiro-crew-bot 안녕` → 응답 오면 Slack 연결 OK

### 5-3. send_message 자율 게시 (spawn)
```bash
sudo -u kirocrew -H bash -l -c "kirocrew spawn run 'send_message 도구로 채널 <SLACK_CHANNEL>에 \"검증 테스트\" 게시해'"
# 기대: 승인 프롬프트 없이 채널에 메시지 게시 (ts=... 반환)
```

### 5-4. 조사요약 조회 권한
```bash
sudo -u kirocrew -H bash -l -c "aws devops-agent list-journal-records --region <AGENT_REGION> --agent-space-id <AGENT_SPACE_ID> --execution-id <임의 execution_id> --query 'length(records)'"
# 기대: 숫자 반환 (권한/CLI 버전 OK). AccessDenied면 base 역할 aidevops 권한 확인
```

### 5-5. 롤백 스킬 (선택, 노드 필요)
```bash
sudo -u kirocrew -H bash -l -c "kubectl --context crew-operator get deployment web-poc -n poc"
# Slack에서 "@kiro-crew-bot web-poc 롤백해줘" → eks-rollback 스킬 발동 확인
```

---

## 6. 핵심 함정 정리 (이번 구축에서 실제 겪은 것)

| # | 증상 | 원인 | 해결 |
|---|------|------|------|
| 1 | `kirocrew service install` 거부 | root/sudo 문제 | 전용 유저 + root로 unit 파일만 생성 (§4-5) |
| 2 | Slack `disabled for security` | `KIROCREW_OWNER_ID` 없음 | .env에 OWNER_ID 추가 (§4-1) |
| 3 | 봇이 멘션에 응답 없음 | Bot scope/이벤트 구독 누락 | Slack App scope·events 추가 후 Reinstall (§1-1) |
| 4 | 응답이 `usage limit reached` | 회사 IAM IdC 계정 크레딧 초과 | 개인 계정으로 재로그인 (§3) |
| 5 | `spawn refused: only 1.5GB` | t3a.medium(4GB) 메모리 부족 | **t3a.large(8GB)로 상향** (Terraform `crew_instance_type`) |
| 6 | spawn이 매번 승인 대기 | admission_gate / 도구 승인 | config 2종 (§4-3) |
| 7 | `send_message` "not in tracked channels" | 채널 미등록 | `slack.tracking_channels` 등록 (§4-3) |
| 8 | `curl`/`aws s3 cp` 계속 거부 | spawn 외부 쓰기 통제(config로 안 뚫림) | **외부 전송은 `send_message` 도구로** (§6 원칙) |
| 9 | `Unknown service: devops-agent` | AWS CLI 구버전 | CLI 2.36+ 업그레이드 (§2-3) |
| 10 | 크로스리전 이벤트 안 옴 | EventBridge가 타 리전 SNS 직접 타겟 불가 | 도쿄 규칙→서울 이벤트버스→규칙→SNS 2단 (Terraform h5-bridge) |

**핵심 원칙**: Crew의 외부 "쓰기/네트워크"(curl, s3 cp)는 승인 없이 못 한다. 하지만 Crew **내장 도구**
(`send_message` 등 @kirocrew-core)는 `allowedTools`에 있으면 무승인 통과한다. 그래서 **외부로 뭔가 보낼 땐
항상 Crew 내장 도구를 쓰도록 프롬프트를 설계**한다.

---

## 7. 비용/운영

- 미사용 시 정지: `aws ec2 stop-instances --instance-ids <INSTANCE_ID> --region <REGION>`
  (systemd라 재기동 시 자동 복구, 로그인·config 유지)
- 재기동: `aws ec2 start-instances ...` → 서비스 자동 기동
- 인스턴스 타입 변경은 **정지 상태에서** Terraform `crew_instance_type` 수정 후
  `terraform apply -target=module.crew_host.aws_instance.crew` (update in-place)
