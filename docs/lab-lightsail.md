# `lab-lightsail` 파일럿 안내서

이 문서는 현재 구현된 단일 서버 파일럿을 처음 검토하는 사람을 위한 안내서입니다. 이 저장소는 QFieldCloud 공식 프로젝트가 아닌 **독립적인 비공식 배포 프로젝트**입니다.

## 먼저 확인할 상태

확인 기준일은 **2026-08-23**입니다.

- **완료:** 템플릿, PowerShell과 Bash 문법, 고정 버전, Docker Compose 구성 및 민감정보 노출 여부를 포함한 정적 검증. 실제 AWS 생성 실패를 재현했고, 가장 최근 실패는 고정 QGIS 이미지에 없는 `python` 명령을 검증에 사용해 종료코드 127이 발생한 것으로 확인함. 같은 이미지의 `/usr/bin/python3`으로 고정 버전 `3.44.13-Solothurn`을 직접 확인하고 검증 명령과 실패 진단을 수정함. 재배포 전 검토에서 worker 연쇄 작업의 경합, 공인 IP 재시도, 유지보수 잠금과 강제 종료 복구 표식도 보완함
- **완료:** 비루트 관리자 권한 준비와 분리된 설치자의 1시간 배포 역할 흐름에 대한 로컬 계약 검사, 실제 AWS CloudFormation 템플릿 문법 검증
- **미완료:** 최신 수정본의 실제 AWS 재배포, 새 계정에서 권한 준비부터 역할 전환까지의 종단 간 시험, 실제 브라우저·QField 접속, 부하, 장애와 삭제 시험

따라서 현재 상태는 **“가장 최근 AWS 생성 실패 원인까지 확인·수정, 최신 수정안 재배포 전”**입니다. 실제 AWS에서 실행하지 않은 기능을 성공했다고 보지 않습니다.

> [!NOTE]
> `docs/runbooks/`는 자동화 구현 전에 작성한 Phase 1 설계 기준이라 “아직 도구가 없음” 또는 장래의 더 넓은 완료기준을 기록한 부분이 있습니다. 현재 구현된 `lab-lightsail`의 명령, 자동 완료 조건과 복원시험 범위는 이 문서를 우선합니다. Phase 1 실행서를 실제 명령서로 사용하지 마세요.

## 무엇을 만드는가

CloudFormation(AWS 자원 묶음 관리 서비스) 스택의 기본 이름은 `qfieldcloud-lab-pilot`이며 서울 리전 `ap-northeast-2`만 허용합니다.

| 자원 | 기본 구성 |
|---|---|
| Lightsail 인스턴스 | Ubuntu 24.04, `medium_3_0`, 4GB RAM, 2 vCPU, 80GB SSD |
| 고정 IP | 인스턴스에 연결한 IPv4 한 개 |
| 방화벽 | HTTP 80과 HTTPS 443 공개, SSH 22는 기본적으로 Lightsail 브라우저 SSH에서만 허용 |
| 자동 snapshot(디스크 시점 사본) | 기본 활성화, 매일 18:00 UTC(한국 다음 날 03:00)에 시작 |
| 경보 | 상태검사 실패와 CPU 80% 경보, 알림 수신자는 자동 설정하지 않음 |
| 설치 완료 대기 | bootstrap 본 작업은 최대 80분이며 제한 도달 시 안전한 종료·서비스 복구에 최대 10분을 추가로 허용함. CloudFormation 완료 신호 대기값은 알려진 초기화 실행기 최대 시간에 15분 이상 여유를 둔 130분이며, 로컬 배포 스크립트는 전체 스택 상태를 약 150분까지 감시함 |
| 삭제 방지 | 생성 시작부터 CloudFormation termination protection 활성화 |
| 업데이트 방지 | 생성 시 stack policy로 모든 CloudFormation 업데이트 거부 |

서버 안에는 QFieldCloud app·Nginx·worker wrapper, QFieldCloud 전용 PostGIS, RustFS 객체 저장소, 메모리 캐시, 시험용 메일 수신기와 작업 스케줄러가 Docker Compose로 함께 실행됩니다. 기존 식물이력관리 PostGIS에는 연결하지 않습니다.

공식 QFieldCloud `v26.25`와 [공식 Git commit(소스 저장 시점) `c32bc110f8291b2a32e318528ee46689771630d6`](https://github.com/opengisch/QFieldCloud/commit/c32bc110f8291b2a32e318528ee46689771630d6), `linux/amd64` 이미지 digest(이미지 내용 고유 식별자)를 사용합니다. QGIS 3 버전 `3.44.13`만 검증하고, QGIS 4는 검증된 공식 이미지가 없으므로 실행을 거부합니다. 자세한 근거는 [버전 정책](version-policy.md)에 있습니다.

## 비용을 먼저 이해하기

[AWS Lightsail 공식 가격표](https://aws.amazon.com/lightsail/pricing/)를 2026-08-23에 확인한 계산입니다.

| 항목 | 계산 | 월 추정 |
|---|---:|---:|
| 4GB Linux 인스턴스 | 4GB RAM, 2 vCPU, 80GB SSD, 4TB 전송량 포함 | US$24 |
| 자동 snapshot 보수적 상한 | 80GB × 7개 × US$0.05/GB-월 | US$28 |
| 합계 | 모든 자동 snapshot이 매일 80GB만큼 완전히 달라진다고 가정 | **약 US$52** |

AWS snapshot은 실제로 변경된 저장 블록에 따라 더 작을 수 있습니다. 위 계산은 최신 자동 snapshot 7개가 각각 80GB를 모두 차지한다고 본 보수적인 상한입니다. **세금, 환율, 포함량을 넘은 외부 전송, 수동·복사 snapshot과 별도 자원은 추가**입니다. AWS는 최신 자동 snapshot 7개를 보관하며 snapshot 저장량에 과금합니다. 자세한 동작은 [Lightsail snapshot 공식 문서](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-snapshots-in-amazon-lightsail.html)를 참고하세요.

인스턴스를 단순히 정지하거나 설치 창을 닫는 것은 비용 종료 절차가 아닙니다. 설치에 실패해도 남은 자원을 삭제할 때까지 요금이 생길 수 있습니다.

## 1. 안전한 설치 전제

설치는 Windows의 PowerShell 7에서 실행하는 것을 기준으로 합니다. 다음 항목이 필요합니다.

1. Git과 PowerShell 7
2. [AWS CLI 버전 2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html). Windows용 공식 MSI 설치 절차를 따르고, 인터넷 스크립트를 `curl | bash`처럼 즉시 실행하지 않음
3. 브라우저에서 임시 자격증명을 받는 비루트 AWS 계정: 기존 조직의 IAM Identity Center 역할 또는 콘솔 전용 IAM 사용자
4. [배포 권한 준비와 유지관리](access-bootstrap.md)로 만든 서울 리전·고정 파일럿 전용 배포 역할. 삭제 권한은 평소 연결하지 않음
5. 공개 GitHub에 Push되어 누구나 내려받을 수 있는 정확한 설치 commit

초기 배포 정책은 [서울 리전·고정 파일럿 전용 배포 정책](../infra/lab-lightsail/deployer-policy.json)에 있습니다. 권장 구조는 [권한 준비 템플릿](../infra/lab-lightsail/access-bootstrap.yaml)이 이 정책을 고정 역할에 연결하고 같은 정책을 permissions boundary(권한 상한선)로도 적용하는 방식입니다. 이 정책은 스택 이름 `qfieldcloud-lab-pilot`, 다섯 CloudFormation 자원 형식과 파일럿에 필요한 작업만 허용합니다. 자원 생성·태그·방화벽·고정 IP·경보·삭제 같은 Lightsail 쓰기는 CloudFormation이 전달한 요청에서만 허용하고, 사용자의 직접 작업은 네 개의 고정 태그가 있는 파일럿 인스턴스의 시작·중지·재시작·브라우저 SSH로 한정합니다. Lightsail 콘솔이 브라우저 SSH 화면을 열 때 함께 조회하는 서울 리전의 디스크·키 쌍·인스턴스 스냅샷·로드밸런서 메타데이터는 같은 계정 전체를 볼 수 있습니다. 키 쌍 조회에는 개인키가 아니라 이름과 지문 같은 메타데이터만 포함됩니다. 전역 CDN 배포 조회 API는 버지니아 북부 리전에서만 동작하므로 `us-east-1`의 `GetDistributions` 한 가지 읽기만 별도로 허용하며 생성·변경·삭제 권한은 허용하지 않습니다. CloudFormation은 서울 밖에서 거부하고, Lightsail은 서울과 이 단일 콘솔 조회 예외 밖에서 거부하며 Lightsail 서비스 연결 역할 권한도 포함하지 않습니다. 권한 판정에 영향을 주지 않는 `Sid`는 필요한 문단에만 짧게 사용하고, 정적 테스트가 IAM 고객 관리형 정책의 6,144자 제한과 추가 유지보수 여유를 검사합니다. 스택 삭제와 삭제 방지 해제 권한은 평소 정책에서 제외하고 [삭제 전용 정책](../infra/lab-lightsail/cleanup-policy.json)으로 분리했습니다.

AWS IAM은 `CreateStack`에 전달한 `TemplateBody`의 파일 checksum, Lightsail 자원 개수나 bundle 값을 검사할 조건을 제공하지 않습니다. 따라서 이 정책도 악의적으로 바꾼 CloudFormation 템플릿까지 막는 완전한 방어는 아닙니다. 반드시 공개 GitHub에 Push된 검토 완료 commit의 설치 도구만 사용하고 배포 역할에 다른 AWS 권한을 추가하지 마세요. **AWS 루트 사용자로 배포하지 마세요.** 배포 도구는 루트와 장기 접근키 기반 IAM 사용자를 거부하고, IAM Identity Center 또는 `aws login`으로 받은 임시 브라우저 자격증명에서 고정 배포 역할을 맡는 경로를 권장합니다.

### 접근키를 만들지 않는 브라우저 로그인

이 프로젝트나 지원자에게 AWS Access Key ID, Secret Access Key, 비밀번호 또는 일회용 코드를 보내지 마세요. 장기 접근키를 새로 만들지 않습니다. 아래 두 방법 중 계정 상태에 맞는 하나를 사용합니다.

#### 이미 AWS Organizations와 IAM Identity Center가 있는 조직 계정

계정 관리자가 알려 준 SSO 시작 URL, SSO 리전, 계정과 설치자 permission set을 준비한 뒤 자신의 PC에서만 다음을 실행합니다. `qfc-installer`는 이 안내서의 권장 원본 프로필 이름입니다.

```powershell
aws configure sso --profile qfc-installer
aws sso login --profile qfc-installer
```

`aws configure sso`에서 `SSO region`에는 관리자가 알려 준 Identity Center 홈 리전을 입력하고, 별도 질문인 `CLI default client Region`에는 반드시 서울 `ap-northeast-2`를 입력합니다. 출력 형식은 `json` 또는 빈칸을 선택할 수 있습니다. 홈 리전과 배포 리전은 서로 다를 수 있습니다. 두 번째 명령이 기본 브라우저를 열면 자신의 AWS 계정에서 승인합니다. 터미널이나 브라우저에 표시된 코드, 계정 번호와 ARN도 채팅이나 GitHub 이슈에 붙여 넣지 않습니다. 로그인이 끝나면 역할 전환 설치의 `-SourceProfile qfc-installer`를 사용합니다.

#### 기존 시험 계정의 직접 IAM 사용자 경로(신규 설치에는 권장하지 않음)

IAM Identity Center 활성화 화면이 무료 플랜 종료나 크레딧 만료를 경고하면 **활성화를 취소**합니다. 단일 리전 선택은 KMS 비용만 피할 뿐, Organizations 생성에 따른 계정 플랜 영향까지 없애지는 않습니다.

다음 수동 절차는 이미 `qfc-lab-deployer`를 만든 기존 시험 계정의 호환 경로입니다. 신규 외부 사용자는 이 정책을 사용자에게 영구 연결하지 말고 다음 절의 역할 기반 권한 준비를 사용하세요.

1. IAM → **Policies** → **Create policy** → **JSON**에서 `infra/lab-lightsail/deployer-policy.json` 내용을 붙여 넣고 `QFieldCloudLabDeployer`라는 고객 관리형 정책을 만듭니다.
2. IAM → **Users** → **Create user**에서 `qfc-lab-deployer`를 만들고 콘솔 접근만 허용합니다. Access key는 만들지 않습니다.
3. 사용자에게 방금 만든 `QFieldCloudLabDeployer`와 AWS 관리형 `SignInLocalDevelopmentAccess` 정책을 연결합니다.
4. 사용자의 **Security credentials**에서 MFA(다중 인증)를 등록합니다.
5. 관리자 콘솔에서 로그아웃하고 IAM 사용자 전용 로그인 주소로 다시 로그인합니다.

정책 파일을 이미 만들었는데 저장소의 JSON이 바뀌었다면 다음 AWS 작업 전에 비루트 관리자 콘솔에서 **IAM → Policies → QFieldCloudLabDeployer → Policy versions → Create version**으로 새 JSON 버전을 만들고 기본 버전으로 지정합니다. 기존 사용자 연결과 현재 임시 로그인은 그대로 유지되지만, 새 기본 버전이 적용되기 전에는 배포하지 않습니다.

AWS CLI `2.32.0` 이상에서 다음 명령을 실행하고, 열린 브라우저에서 반드시 `qfc-lab-deployer` 콘솔 세션을 선택합니다. 루트 세션을 선택하지 않습니다.

```powershell
$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws) {
  $aws = "$env:LOCALAPPDATA\Programs\Amazon\AWSCLIV2\aws.exe"
}
& $aws login --profile qfc-lab --region ap-northeast-2
```

첫 줄에서 PATH(명령 검색 경로)에 등록된 AWS CLI를 찾고, 없으면 Windows 사용자별 기본 설치 경로를 사용합니다. AWS는 이 로그인으로 최대 12시간 동안 자동 갱신되는 임시 자격증명을 제공합니다. 작업을 마치면 `& $aws logout --profile qfc-lab`으로 종료합니다. 자세한 동작은 [AWS CLI 콘솔 자격증명 로그인 공식 문서](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)를 따릅니다.

### 권장: 관리자와 설치자를 분리하고, 설치에는 1시간 배포 역할

신규 설치는 [AWS 배포 권한 준비와 유지관리](access-bootstrap.md)를 먼저 수행합니다. 권한 준비 스택은 IAM 사용자·비밀번호·접근키를 만들지 않고, 고정 배포 역할과 정책 두 개만 만듭니다. 비루트 관리자가 별도 설치자를 신뢰하도록 준비하면 `Install-QFieldCloudPilot.ps1`이 설치자 브라우저 임시 로그인, 비밀값 없는 로컬 역할 프로필, 1시간 역할 전환과 배포 계획을 한 흐름으로 처리합니다. 한 사람이 관리자 프로필을 계속 쓰는 간편 경로는 가능하지만 원본 관리자 권한은 사라지지 않습니다.

## 2. 로컬 소스 확인

배포 도구는 다음 조건을 모두 확인하고 하나라도 다르면 중단합니다.

- 현재 폴더가 Git 저장소임
- `origin`이 정확히 `https://github.com/jusubkim94/qfieldcloud-self-hosting-for-arboreta.git`임
- 작업 폴더에 수정·추가 파일이 하나도 없음
- 현재 commit의 `bootstrap.sh`가 공개 GitHub에 Push되어 있음
- GitHub 파일과 로컬 파일의 SHA-256 checksum이 같음

저장소 루트의 PowerShell에서 확인합니다.

```powershell
pwsh -NoProfile -File .\scripts\lab-lightsail\Test-IamPolicies.ps1
pwsh -NoProfile -File .\scripts\lab-lightsail\Test-AccessBootstrap.ps1
pwsh -NoProfile -File .\scripts\lab-lightsail\Test-Onboarding.ps1
git remote get-url origin
git status --short
git log -1 --format=%H
```

앞의 세 시험 명령은 AWS API를 호출하지 않고 배포·삭제 정책, 권한 준비, 역할 프로필, 고정 스택 이름과 템플릿 자원 형식의 안전 계약을 검사합니다. `git status --short`는 아무것도 출력하지 않아야 합니다. 수정사항이 있거나 아직 Push하지 않은 작업이라면 배포하지 말고 정상적인 Pull Request 검토와 병합 절차를 먼저 끝냅니다.

## 3. 먼저 계획만 확인하기

다음 명령에는 `-Execute`가 없습니다. 원본 프로필의 브라우저 로그인을 갱신하고 로컬 AWS config에 비밀값 없는 역할 프로필을 만들거나 복구할 수 있습니다. 그 뒤 AWS에서는 로그인 주체, 서울 리전의 Lightsail 상품·가용 영역, 템플릿, 기존 스택과 공개 GitHub 파일을 **읽기 전용으로 확인**하며 과금 자원을 만들거나 바꾸지 않습니다.

`<12자리 계정 ID>`에는 AWS 콘솔 오른쪽 위 계정 메뉴에 표시되는 자신의 계정 ID를 입력합니다. 채팅이나 GitHub에는 붙여 넣지 않습니다. 도구는 이 값을 출력하지 않고, 선택한 프로필 및 실제 임시 세션의 계정과 모두 같은지만 확인합니다.

```powershell
pwsh -NoProfile -File .\scripts\lab-lightsail\Install-QFieldCloudPilot.ps1 `
  -SourceProfile qfc-installer `
  -RoleProfile qfc-lab-role `
  -ExpectedAccountId '<12자리 계정 ID>'
```

출력에서 최소한 다음을 확인합니다.

- `Action`이 `plan-only`
- `Region`이 `ap-northeast-2`
- `PrincipalType`이 `temporary-assumed-deployment-role`
- `AccountBinding`이 `expected-account-verified`
- `ExistingStack`이 `False`
- `ExistingInstanceName`, `ExistingStaticIpName`, `ExistingAlarmName`이 모두 `False`
- `Bundle`이 `medium_3_0`
- `EstimatedMonthlyLowUsd`와 `EstimatedMonthlyHighUsd`
- `FailureRollback`이 `disabled-resources-preserved-and-billable`
- `TerminationProtection`이 `enabled-at-create`
- `StackUpdatePolicy`가 `deny-all-updates`
- `CloudFormationResourceTypes`에 WaitCondition 두 형식과 Lightsail Instance·StaticIp·Alarm만 있음
- `ExistingArboretumDatabaseScope`가 `not-accessed`
- `BootstrapRevision`이 검토해 Push한 commit과 같음
- `ApprovalPlanSha256`이 64자리이며, 도구가 마지막에 표시한 `QFC_APPROVAL_RECEIPT_V1`의 첫 값과 같음
- `UpstreamDhparams`가 `official-commit-bytes-verified`

기존 스택 또는 세 Lightsail 이름 항목 중 하나라도 `True`이면 중단하세요. 이 도구는 기존 데이터가 있는 인스턴스를 뜻하지 않게 교체하거나 기존 고정 IP·알람을 임의로 채택하지 않습니다.

## 4. 명시적으로 생성하기

아래 명령은 **실제로 AWS 자원을 만들고 즉시 과금을 시작할 수 있습니다.** 계획의 계정, 리전, 월 비용, 단일 서버 위험과 마지막 삭제 절차를 사용자가 검토하고 승인한 경우에만 `-Execute`를 추가합니다.

```powershell
pwsh -NoProfile -File .\scripts\lab-lightsail\Install-QFieldCloudPilot.ps1 `
  -SourceProfile qfc-installer `
  -RoleProfile qfc-lab-role `
  -ExpectedAccountId '<12자리 계정 ID>' `
  -Execute
```

첫 계획과 확인 문구 사이에 Git commit, 계정, 가격, 옵션 또는 기존 자원 상태가 바뀌면 승인 SHA-256이 달라져 생성 전에 중단합니다. 기본값은 서울 `ap-northeast-2a`, 자동 snapshot과 경보 활성화, 브라우저 SSH만 허용입니다. 설치 과정은 Docker, 고정 이미지, QFieldCloud 전용 DB 구조, 좌표 변환 격자(PROJ-data), 자체서명 인증서와 로컬 관리자를 준비한 뒤 작은 시험 프로젝트로 QGIS 3 worker(백그라운드 작업)를 자동 검증합니다.

Lightsail은 시작 스크립트를 root 권한의 명령 목록으로 실행합니다. 이번 파일럿에서 실제 생성된 Ubuntu 인스턴스에는 앞에 `/bin/sh` 래퍼가 추가된 것도 확인했습니다. 따라서 템플릿은 내부 Bash shebang(실행기 지정 줄)에 의존하지 않고, POSIX `sh`로 파일 권한 기본값과 명령 검색 경로를 먼저 고정한 다음 첫 본 작업으로 Bash를 명시 실행해 나머지 본문을 전달합니다. 이 순서는 정적 회귀 테스트로 고정되어 있습니다. [AWS Lightsail 시작 스크립트 공식 예제](https://docs.aws.amazon.com/lightsail/latest/userguide/lightsail-how-to-configure-server-additional-data-shell-script.html)도 shebang 대신 root로 실행할 명령을 입력하는 방식을 안내합니다.

자동 worker smoke test(최소 기능 시험)는 프로젝트 생성 작업, 이어서 자동 생성되는 프로젝트 파일 분석 작업, 패키지 생성 작업과 각 임시 worker 컨테이너 정리를 차례로 확인합니다. 세 작업의 대기 시간은 합쳐서 최대 20분이며, 분석이 끝나 프로젝트가 준비된 뒤에만 패키지를 만듭니다. 시험에는 관리자 비밀번호나 기존 로그인 세션을 사용하지 않습니다. 서버 내부에서 이 시험 전용 1시간 토큰을 만들고, 완료 전에 정확히 그 토큰만 폐기합니다. 성공하려면 `installer-worker-smoke` 시험 프로젝트와 그 작업, 임시 worker 컨테이너와 시험 토큰이 모두 정리되어야 합니다.

서버 전원 차단이나 `SIGKILL`처럼 정리 절차가 실행될 수 없는 강제 종료가 일어나면 root만 읽을 수 있는 시험용 임시 토큰 파일이 남을 수 있습니다. 토큰은 생성 후 1시간이 지나면 만료되고 다음 시험은 같은 용도의 기존 DB 토큰을 먼저 폐기하지만, 남은 파일 자체는 운영자가 점검해야 합니다.

worker 시험 뒤에는 최초 root(서버 최고관리자) 전용 로컬 백업을 만들고, 그 최신 백업을 격리된 임시 DB·객체 저장소에 복원해 DB 구조와 저장 데이터의 무결성을 검사합니다. 복원시험 중에는 메모리 부족을 막기 위해 운영 컨테이너 전체를 잠시 중지하고, 시험 자원을 정리한 뒤 다시 시작해 상태를 확인합니다. 마지막 전체 상태까지 정상이어야 CloudFormation 완료 신호를 보냅니다. 이는 별도 호스트에서 worker까지 검증하는 종단 간 재해 복구 연습은 아닙니다.

`create-stack` 요청은 CloudFormation **termination protection(삭제 방지)**을 생성 시작부터 켜고, stack policy(스택 업데이트 안전 정책)로 모든 업데이트를 거부합니다. 성공과 실패 스택 모두 보호될 수 있습니다. 모든 완료 조건이 통과하면 배포 도구는 스택 상태와 인증서 SHA-256 fingerprint(인증서 지문)를 다시 검증합니다. 출력의 `BootstrapStatus`가 `verified-by-wait-condition`, `CertificateSha256`이 64자리, `TerminationProtection`이 `enabled`인지 확인합니다.

### 실패하면 자동 삭제하지 않음

이 배포는 실패 원인을 조사할 수 있도록 CloudFormation 자동 롤백을 끕니다. 따라서 설치, worker, 최초 백업 또는 격리 복원시험이 실패해 `CREATE_FAILED`가 되면 인스턴스, 고정 IP 또는 snapshot이 남아 **즉시 계속 과금**될 수 있습니다. 삭제 방지도 생성 시작부터 켜져 있으므로 터미널을 닫거나 일반 삭제를 한 번 누르는 것만으로 없어지지 않습니다. 배포 스크립트도 실패한 자원을 자동 삭제하지 않습니다.

1. CloudFormation 콘솔에서 리전을 **아시아 태평양(서울)**로 확인합니다.
2. `qfieldcloud-lab-pilot` 스택의 **Events**에서 처음 실패한 자원을 확인합니다.
3. 같은 `-Execute` 명령을 반복하지 않습니다. 기존 스택이 있으면 도구도 재실행을 거부합니다.
4. 브라우저 SSH가 열리면 서버 안의 상태 확인 명령으로 범위를 좁힙니다.
5. 보존할 데이터와 비용을 판단한 뒤 수정 절차 또는 이 문서 마지막의 삭제 절차를 별도로 승인합니다.

[CloudFormation 스택 이벤트 공식 안내](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/view-stack-events.html)도 참고하세요. 로그를 공유할 때는 전체 환경변수, `secrets.env`, 인증 헤더, 비밀번호와 토큰을 출력하지 않습니다.

## 5. `sslip.io`와 자체서명 TLS 이해하기

기본 주소는 고정 IPv4를 넣은 `https://IP.sslip.io/`입니다. 예를 들어 IP가 `203.0.113.10`이면 호스트 이름은 `203.0.113.10.sslip.io`입니다. `sslip.io`는 AWS나 QFieldCloud가 운영하지 않는 제3자 wildcard DNS 서비스입니다.

설치기는 이 호스트 이름으로 365일짜리 **자체서명 TLS 인증서**를 만듭니다. 통신은 암호화되지만, 공인 인증기관이 서버 신원을 보증하지 않으므로 브라우저와 QField는 경고합니다. 상태 도구는 지문뿐 아니라 유효기간과 호스트 이름도 확인하며, 만료되면 실패합니다. 이 create-only 파일럿에는 인증서 지문을 안전하게 교체하는 자동 갱신 절차가 없으므로 만료 전에 데이터를 외부로 보존하고 새로 검토한 스택으로 교체하거나 파일럿을 삭제해야 합니다. 이 방식은 폐쇄된 단기 파일럿 전용이며 실제 공개 운영에는 공인 도메인과 공인 인증서가 필요합니다.

관리자 비밀번호를 입력하기 전에 인증서 fingerprint(지문)를 다른 경로로 비교합니다.

1. 설치자 콘솔 세션의 오른쪽 위 사용자 메뉴에서 **Switch role**을 선택합니다. 다중 세션 화면이면 **Add session → Switch role**을 선택합니다.
2. **Account**에는 자신의 12자리 계정 ID, **Role**에는 경로를 포함한 `qfieldcloud-lab/QFieldCloudLabDeployer`를 입력하고 **Switch Role**을 누릅니다. 루트 사용자는 역할 전환을 할 수 없습니다.
3. 오른쪽 위 표시가 전환한 역할인지 확인한 뒤 Lightsail → **Instances** → `qfieldcloud-lab-pilot` → **Connect using SSH**를 엽니다. 역할 경로 입력 방식은 [AWS 역할 전환 공식 안내](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-console.html), 브라우저 SSH는 [Lightsail 공식 안내](https://docs.aws.amazon.com/lightsail/latest/userguide/lightsail-how-to-connect-to-your-instance-virtual-private-server.html)를 따릅니다.
4. 서버 터미널에서 다음 명령을 실행합니다.

   ```bash
   sudo openssl x509 \
     -in /opt/qfieldcloud/state/certs/qfieldcloud.pem \
     -noout -subject -dates -fingerprint -sha256
   ```

5. 자신의 브라우저에서 파일럿 URL의 인증서 세부정보를 열고 SHA-256 fingerprint와 호스트 이름을 비교합니다.
6. 값이 정확히 같을 때만 파일럿 경고를 일시적으로 허용합니다. 다르면 로그인하지 말고 중단합니다.

브라우저 SSH가 호스트 키 불일치로 **Reset record**를 요구하는 예외 상황에서는 권장 배포 역할과 기존 호환 사용자 `qfc-lab-deployer` 모두 해당 기록을 지울 권한을 일부러 갖지 않습니다. 먼저 인스턴스 이름과 생성 시각이 파일럿과 일치하는지 확인하고, IAM 관리자에게 [AWS 공식 호스트 키 복구 절차](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-troubleshooting-browser-based-ssh-rdp-client-connection.html)를 요청합니다. 편의를 위해 배포 주체에 광범위한 Lightsail 권한을 추가하지 않습니다.

로컬 상태 도구는 자체서명 인증서를 무조건 허용하지 않습니다. 스택의 인증된 완료 신호에 담긴 SHA-256 fingerprint와 서버 인증서가 정확히 같을 때만 연결합니다. 사람이 직접 비교할 때도 값이 다르면 중단하세요. 민감하거나 실제 업무용 데이터를 이 공개 파일럿에 넣지 마세요.

## 6. 상태와 관리자 계정 확인

### 로컬 PC에서 생성 완료 조건과 상태 주소 확인

다음 명령은 스택이 `CREATE_COMPLETE`인지 확인하고, 설치 완료 신호에서 인증서 SHA-256 fingerprint를 가져와 실제 서버 인증서와 비교합니다. 이어서 Lightsail 실행 상태와 외부 HTTPS 상태 주소의 DB·객체 저장소 상태를 확인합니다.

```powershell
$accountId = '<12자리 계정 ID>'
$expectedRoleArn = "arn:aws:iam::$accountId`:role/qfieldcloud-lab/QFieldCloudLabDeployer"
$expectedRevision = (git rev-parse HEAD).Trim()
$expectedBootstrapSha256 = (Get-FileHash `
  -Algorithm SHA256 `
  -LiteralPath .\scripts\lab-lightsail\bootstrap.sh).Hash.ToLowerInvariant()
pwsh -NoProfile -File .\scripts\lab-lightsail\Test-QFieldCloudPilot.ps1 `
  -StackName qfieldcloud-lab-pilot `
  -Profile qfc-lab-role `
  -ExpectedAccountId $accountId `
  -ExpectedDeploymentRoleArn $expectedRoleArn `
  -ExpectedBootstrapRevision $expectedRevision `
  -ExpectedBootstrapSha256 $expectedBootstrapSha256
```

`BootstrapSource=expected-revision-and-sha256-matched`도 확인합니다. 스택 모드에서 성공하면 검토한 bootstrap commit·파일, 새 스택 생성 때 자동 worker 시험, 최초 로컬 백업, 최신 백업의 격리 schema·storage 복원시험과 전체 health가 완료 조건을 통과했고, 현재 고정 인증서·HTTPS·DB·storage가 응답함을 뜻합니다. 다만 worker와 복원을 그 순간 다시 실행한 결과는 아니므로 현재 전체 상태는 서버 안의 다음 명령으로 확인합니다.

### 서버 안에서 전체 상태 확인

Lightsail 브라우저 SSH에서 실행합니다.

```bash
sudo /opt/qfieldcloud/bin/health-check.sh
```

JSON 결과의 `overall`이 `ok`, `runtime_provenance`가 `verified-pinned-installer-files`, `runtime_images`가 `verified-pinned-image-objects`, `protected_state_permissions`가 `root-only`인지 먼저 확인합니다. `transformation_grids`는 `installed-and-verified`, `tls_certificate`는 `current-hostname-and-fingerprint-matched`, `restore_test_orphans`와 `maintenance_failures`는 `clear`여야 합니다. 이는 설치 commit의 원본 파일과 현재 실행 파일이 같고, 각 컨테이너가 manifest에 고정한 이미지 객체를 실제로 실행하며, 좌표 변환 격자·인증서 지문·복원시험 임시 자원·미해결 유지보수 실패 표식까지 다시 확인하고, Secret·개인키 파일이 서버 root만 읽도록 유지된다는 뜻입니다. DB·객체 저장소·SMTP·cache·app·Nginx·worker·작업 스케줄러도 모두 `running`이어야 합니다.

이어 `worker_validation`이 `passed`, `backup_validation`이 `passed-local-only`, `restore_validation`이 `schema-storage-integrity-passed`, `restore_matches_latest`가 `true`인지 확인합니다. 세 검증은 현재 고정 버전과 최신 백업에 연결되며 7일이 지나면 `stale`로 실패합니다. `last_worker_smoke_at`, `last_backup_at`, `last_restore_test_at`은 각 작업의 마지막 성공 시각을 보여 줍니다. 이 명령은 Secret 값을 출력하지 않습니다.

worker만 다시 시험해야 할 때는 다음을 실행합니다. 서비스에 시험 프로젝트와 작업을 만들며 최대 수십 분 걸릴 수 있습니다.

```bash
sudo /opt/qfieldcloud/bin/worker-smoke-test.sh
```

### 관리자 자격증명은 서버 터미널에서만 조회

초기 관리자 자격증명은 인스턴스의 root 전용 파일에 생성되며 CloudFormation 출력이나 설치 로그에 나타나지 않습니다. 브라우저 SSH의 현재 대화형 터미널에서만 다음을 실행합니다. 도구는 파이프나 파일로 출력이 재지정되면 비밀번호 표시를 거부합니다.

```bash
sudo /opt/qfieldcloud/bin/show-admin-credentials.sh
```

출력을 파일로 리디렉션하지 말고 채팅, 화면공유, 로그, GitHub 이슈에 붙여 넣지 않습니다. 신뢰할 수 있는 비밀번호 관리자에 직접 옮긴 뒤 터미널을 닫습니다. `sudo cat /opt/qfieldcloud/state/secrets.env`나 전체 환경변수 출력 명령은 사용하지 않습니다.

## 7. 로컬 백업과 격리 복원시험

### 애플리케이션 백업

```bash
sudo /opt/qfieldcloud/bin/backup.sh
```

이 명령은 Nginx와 작업 스케줄러를 먼저 멈춰 새 쓰기를 막고, 실행 중 worker를 최대 15분 기다린 뒤 app과 객체 저장소도 중지합니다. 백업이 끝나고 전체 서비스 복귀를 확인할 때까지 파일럿이 중단될 수 있으며, 데이터가 크면 수십 분 이상 걸릴 수 있습니다. 사용자 공지와 유지보수 시간을 먼저 확보한 뒤 다음을 `/var/backups/qfieldcloud/날짜-v26.25/`에 저장합니다.

- QFieldCloud 전용 PostgreSQL/PostGIS 논리 dump
- RustFS 객체와 media 파일
- 버전·Compose·호스트 정보
- 별도 root 전용 폴더의 Secret 사본
- SHA-256 checksum과 백업 범위 manifest

기존 식물이력관리 DB는 포함하지 않습니다. 완료 폴더를 덮어쓰거나 자동 삭제하지 않으므로 백업이 쌓이면 80GB 디스크가 가득 찰 수 있습니다. 백업에는 Secret 사본이 있고 파일 자체를 별도로 암호화하지 않으므로 접근 권한을 엄격히 제한해야 합니다.

고급 설정으로 `QFC_BACKUP_ROOT`를 바꿀 때는 대상의 바로 위 폴더를 먼저 root 소유로 만들고 그룹·다른 사용자의 쓰기 권한을 없애야 합니다. 최종 백업 폴더는 root 소유 `0700`이어야 하며, 부모가 없거나 이 권한 조건을 만족하지 않으면 경로 바꿔치기를 막기 위해 백업과 복원시험이 안전하게 중단됩니다. 일반 사용자는 기본 경로를 그대로 사용하면 됩니다.

백업이 실패하면 `/opt/qfieldcloud/state/last-backup-failure`에 `artifact_state`가 기록됩니다. `partial`은 미완성 폴더, `finalized-not-published`는 완성 폴더는 있지만 성공 표식이 기록되지 않은 상태, `not-created`는 폴더 생성 전 실패를 뜻합니다. `unexpected-`로 시작하면 예상 경로가 폴더가 아닌 형태이므로 더욱 주의해야 합니다. 스크립트는 어느 경로도 자동 삭제하지 않습니다. root로 표식과 해당 경로를 확인하고 별도 승인을 받은 뒤에만 정리하세요.

> [!WARNING]
> 이 백업은 같은 인스턴스 디스크에 있습니다. 인스턴스·디스크 손상이나 스택 삭제를 견디는 외부 백업이 아닙니다. 승인된 암호화 방식으로 서버 밖에 복사하고 그 사본도 시험하기 전에는 재해 복구 백업으로 믿지 마세요. 자동 snapshot도 애플리케이션 일관성 백업을 대신하지 않습니다.

### 최신 백업 격리 복원시험

```bash
sudo /opt/qfieldcloud/bin/restore-test.sh
```

이 명령은 가장 최근에 완성된 백업을 자동 선택합니다. checksum을 확인한 뒤 QFieldCloud 전용 PostgreSQL 컨테이너 안에 `qfc_restore_test_`로 시작하는 별도 임시 DB를 만들고, 운영 네트워크·운영 저장 볼륨과 분리된 내부 Docker 네트워크 및 임시 RustFS·media 볼륨을 만듭니다. DB/PostGIS, migration, 버전이 있는 객체 저장소와 media archive를 확인한 뒤 **이름이 제한된 임시 DB와 이 시험이 만든 label이 있는 임시 자원만** 삭제합니다.

운영 QFieldCloud DB, 운영 객체 저장소와 기존 식물이력관리 DB를 복원 대상으로 사용하지 않습니다. 임시 DB는 운영 QFieldCloud DB와 같은 PostgreSQL 프로세스를 사용하지만 이름을 엄격히 검사하고, 성공·실패와 관계없이 삭제 여부를 다시 확인합니다. 시험하는 동안 운영 파일럿 전체는 중단되며 종료 시 자동 복귀와 상태 확인을 시도합니다. 다만 같은 서버와 같은 PostgreSQL 프로세스 및 Docker 저장공간을 사용하므로 완전한 외부 재해 복구 시험은 아닙니다. 디스크는 대략 `DB 원본의 2배 + 객체 + media + 25%`를 요구하며, 여유분이 2GB보다 작으면 2GB를 사용합니다. 운영 중지 후 사용 가능한 실제 RAM도 2.5GB 이상이어야 합니다. 이전 실패에서 label이 붙은 임시 자원이나 이름이 제한된 임시 DB가 남으면 스크립트는 임의 삭제하지 않고 중단하므로 목록을 조사한 뒤 승인된 정리 절차를 수행합니다. 스크립트는 서비스를 멈추기 전에 root 전용 `state/recovery-required`를 먼저 만들고, 모든 서비스의 재시작과 상태 확인이 끝난 뒤에만 지웁니다. 이 파일이 남아 있으면 강제 종료가 있었거나 서비스 복귀가 확인되지 않은 상태이므로 신규 접속을 허용하기 전에 파일과 실제 상태를 확인합니다.

실패 시 `/opt/qfieldcloud/state/last-restore-test-failure`에 실패 단계, 제한된 원인, 선택한 백업과 임시 자원 정리 확인 결과를 root 전용으로 기록합니다. 원본 명령의 전체 환경변수나 인증정보는 기록하지 않습니다. 이 표식 또는 `state/recovery-required`가 있으면 재실행부터 하지 말고 [로그 실행서](runbooks/logs.md)에 따라 가린 진단본을 확인하세요.

권장 확인 순서는 다음과 같습니다.

```bash
sudo /opt/qfieldcloud/bin/backup.sh
sudo /opt/qfieldcloud/bin/restore-test.sh
sudo /opt/qfieldcloud/bin/health-check.sh
```

세 명령은 root만 접근할 수 있는 `/var/lib/qfieldcloud/locks`의 공통 maintenance lock(유지보수 잠금)을 사용합니다. 여러 터미널에서 동시에 실행하면 두 번째 명령은 안전하게 중단되므로, 첫 명령이 완전히 끝난 뒤 순서대로 실행하세요. 잠금 파일은 재실행과 재부팅 뒤에도 같은 안전 계약으로 재사용하며 자동 삭제하지 않습니다.

## 8. 반드시 받아들여야 하는 위험

- **단일 서버:** app, DB, 객체 저장소와 로컬 백업이 함께 중단되거나 손실될 수 있습니다.
- **Docker socket:** worker wrapper와 작업 스케줄러가 호스트 Docker daemon을 제어합니다. Ofelia의 socket에 붙인 `:ro`는 Docker API를 읽기 전용으로 제한하지 않습니다. 두 컨테이너 중 하나라도 침해되면 서버 전체를 장악할 수 있는 수준의 위험입니다.
- **공개 포트:** 80과 443은 인터넷 전체에 열립니다. SSH 22는 기본적으로 AWS Lightsail 브라우저 SSH 별칭으로만 제한되지만, 웹 서비스는 공개됩니다.
- **자체서명 TLS와 제3자 DNS:** 공인 서버 신원 보장이 없고 `sslip.io`의 가용성과 DNS 처리에 의존합니다.
- **인증서 자동 갱신 없음:** 365일 만료 전에 검토된 새 스택으로 교체하거나 파일럿을 삭제해야 합니다.
- **로컬 백업:** 서버 삭제와 함께 사라질 수 있고 root 전용 Secret 사본을 포함합니다.
- **유지보수 중단:** 애플리케이션 백업과 격리 복원시험 동안 전체 또는 일부 서비스가 중단됩니다.
- **작은 크기:** 4GB RAM, 2 vCPU, swap 4GB와 worker 1개는 공식 최소사양이 아니라 시험 가정입니다.
- **메일:** 로컬 `smtp4dev`는 시험 메일을 받기 위한 구성이지 외부 사용자에게 메일을 전달하는 운영 메일 서비스가 아닙니다.
- **OS 재현성 한계:** `ubuntu_24_04` Lightsail blueprint와 Ubuntu 기본 APT 저장소 내용은 시간이 지나며 바뀔 수 있습니다. 컨테이너와 Docker 패키지는 고정하지만 전체 OS를 byte 단위로 재현한다고 보장하지 않습니다.

중요 운영으로 전환하기 전에는 DB와 객체 저장소를 서버 밖으로 분리하는 `standard-aws`, 공인 TLS, 외부 백업, 최소 권한 IAM, 모니터링과 실제 장애 복구 시험이 필요합니다.

## 9. 업데이트는 자동으로 하지 않음

배포 도구는 같은 이름의 기존 스택을 자동 업데이트하지 않습니다. 생성 시 적용한 stack policy도 모든 CloudFormation 업데이트를 거부하여, 콘솔에서 실수로 상태 저장 서버나 고정 IP를 교체하는 일을 막습니다. 의도적인 업데이트에는 별도 검토와 임시 정책 override가 필요합니다. 설치된 QFieldCloud 릴리스와 다른 릴리스를 감지해도 자동 교체하지 않고 중단합니다. `latest`나 최신 branch로 몰래 바꾸지 않습니다.

업데이트는 다음 순서를 갖는 별도 변경 작업입니다.

1. 공식 릴리스, 정확한 commit과 `linux/amd64` 이미지 digest 조사
2. 라이선스와 QGIS worker 실제 내용 검증
3. 애플리케이션 백업과 격리 복원시험
4. 변경·비용·다운타임·되돌리기 방법 검토와 승인
5. 기능 브랜치와 Pull Request의 정적 검증
6. 별도의 명시적 업데이트 실행과 사후 worker 시험

현재 파일럿에는 검증 완료된 업데이트 자동화가 없습니다. 기존 스택에서 bootstrap만 수동 재실행하거나 Compose 이미지 문자열만 바꾸지 마세요.

## 10. 정확한 수동 제거 절차

이 저장소에는 자동 제거 스크립트가 없습니다. 삭제는 복구하기 어려운 작업이므로 기본 이름과 서울 리전을 다시 확인하고 사용자가 명시적으로 승인한 뒤 AWS 콘솔에서 수행합니다.

### 삭제 전에 결정할 것

1. 보존할 프로젝트가 없거나, 마지막 애플리케이션 백업과 격리 복원시험이 성공했는지 확인합니다.
2. 로컬 백업은 인스턴스와 함께 삭제됩니다. 보존이 필요하면 승인된 암호화 외부 사본을 만들거나 Lightsail 수동 snapshot을 별도로 만듭니다.
3. AWS는 원본 인스턴스를 삭제할 때 연결된 **자동 snapshot도 함께 삭제**합니다. 반대로 수동 snapshot과 자동 snapshot을 수동으로 보존한 사본은 남아 계속 과금됩니다.
4. 수동 snapshot에는 디스크의 QFieldCloud 데이터와 Secret도 들어 있음을 이해하고 접근자를 제한합니다.

### CloudFormation 스택 삭제

권장 역할 기반 설치의 `QFieldCloudLabDeployer`는 permissions boundary가 삭제 권한도 막으므로 cleanup 정책을 그 역할에 추가해도 삭제할 수 없습니다.

**권장 역할 경로:** 삭제 승인을 받은 뒤 비루트 계정 관리자로 로그인합니다. 관리자 자신이 정확한 고정 스택의 삭제를 수행하므로 배포 역할에 정책을 추가하지 않습니다. 루트로 일상 삭제를 수행하지 않습니다.

**기존 직접 IAM 사용자 호환 경로:** 비루트 관리자가 IAM → **Policies → Create policy → JSON**에서 `infra/lab-lightsail/cleanup-policy.json`으로 `QFieldCloudLabCleanup`을 만들고 기존 `qfc-lab-deployer`에 임시 연결합니다. 기존 `QFieldCloudLabDeployer`도 실제 자원 정리에 필요하므로 삭제 완료까지 유지합니다. 관리자는 로그아웃하고 해당 사용자로 다시 로그인합니다.

선택한 삭제 주체로 다음 공통 절차를 수행합니다.

1. 오른쪽 위 리전을 **Asia Pacific (Seoul) / `ap-northeast-2`**로 바꿉니다.
2. CloudFormation → **Stacks** → `qfieldcloud-lab-pilot`을 선택합니다. 현재 파일럿 정책과 스크립트는 안전 범위를 고정하기 위해 이 이름만 허용합니다.
3. **Resources** 탭에서 기본 인스턴스 `qfieldcloud-lab-pilot`, 고정 IP `qfieldcloud-lab-pilot-ip`, 선택적 경보가 이 스택 소유인지 확인합니다.
4. **Stack actions → Edit termination protection → Disable → Save**를 선택합니다. 성공·실패 모두 생성 요청 때 보호가 켜지므로, 이 보호 해제는 위의 백업·격리 복원시험과 삭제 승인이 모두 끝난 경우에만 합니다. 스택 정보에서 이미 `Disabled`임이 확인될 때만 이 단계를 건너뜁니다.
5. **Delete**를 누르고 대상 스택 이름을 다시 읽은 뒤 승인합니다. 삭제 시작 후에는 중지할 수 없습니다.
6. 상태가 `DELETE_COMPLETE`가 될 때까지 기다립니다. 공식 화면 순서는 [CloudFormation 삭제 방지 안내](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-protect-stacks.html)와 [스택 삭제 안내](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cfn-console-delete-stack.html)에 있습니다.
7. 기존 직접 IAM 사용자 경로였다면 비루트 관리자 세션에서 `qfc-lab-deployer`와 `QFieldCloudLabCleanup`의 연결을 즉시 해제합니다. 다시 쓸 이유가 없다면 연결되지 않은 cleanup 정책도 삭제합니다. 권장 관리자 경로는 임시 정책을 만들지 않았으므로 관리자 세션에서 로그아웃합니다.

`DELETE_FAILED`이면 강제 삭제부터 누르지 마세요. **Events**와 **Resources**에서 남은 물리 자원을 기록합니다. 강제 삭제나 `retain`은 자원을 계정에 남길 수 있으며 그 자원은 계속 과금될 수 있습니다. 원인을 해결한 뒤 일반 삭제를 다시 시도하고, 정말 보존할 자원만 이름과 월 비용을 기록해 남깁니다.

### 잔존 자원과 비용 확인

스택이 사라진 뒤 같은 서울 리전에서 다음을 하나씩 확인합니다.

- CloudFormation의 삭제된 스택 필터: 스택은 `DELETE_COMPLETE`; **Resources**에는 `DELETE_FAILED` 없음. `DELETE_SKIPPED`가 있으면 retain된 물리 자원으로 따로 기록하고 비용 확인
- Lightsail **Instances**: 기본 `qfieldcloud-lab-pilot` 없음
- Lightsail **Networking**: `qfieldcloud-lab-pilot-ip` 고정 IP 없음
- Lightsail **Snapshots**: 보존하기로 한 수동·복사 snapshot만 있음; 불필요한 snapshot은 명시적으로 삭제
- Lightsail **Disks**와 다른 리전: 수동 생성 또는 복사한 잔존 디스크·snapshot 없음
- Lightsail 경보: 이 스택 이름의 상태·CPU 경보 없음
- Billing and Cost Management의 **Bills/Cost Explorer**: Lightsail 사용량과 예상 비용을 다시 확인

자동 snapshot은 원본 삭제와 함께 없어지지만 수동 snapshot은 직접 삭제할 때까지 보관되고 과금됩니다. 자세한 내용은 [Lightsail snapshot 공식 문서](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-snapshots-in-amazon-lightsail.html)와 [불필요한 snapshot 삭제 안내](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-deleting-snapshots.html)를 참고하세요. 청구 화면 반영에는 시간이 걸릴 수 있으므로 삭제 직후 한 번으로 끝내지 말고 다음 청구 갱신 때 다시 확인합니다.

## 공식 참고자료

- [QFieldCloud `v26.25` 공식 릴리스](https://github.com/opengisch/QFieldCloud/releases/tag/v26.25)
- [QFieldCloud 고정 commit](https://github.com/opengisch/QFieldCloud/commit/c32bc110f8291b2a32e318528ee46689771630d6)
- [QFieldCloud self-hosting 공식 문서](https://docs.qfield.org/reference/qfieldcloud/self_hosted/)
- [QFieldCloud 공식 아키텍처](https://docs.qfield.org/reference/qfieldcloud/architecture/)
- [AWS IAM Identity Center CLI 로그인](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html)
- [AWS Lightsail 가격표](https://aws.amazon.com/lightsail/pricing/)
- [AWS Lightsail snapshot](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-snapshots-in-amazon-lightsail.html)
- [AWS CloudFormation 삭제 방지](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-protect-stacks.html)
- [AWS CloudFormation 스택 삭제](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cfn-console-delete-stack.html)
