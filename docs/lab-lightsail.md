# `lab-lightsail` 브라우저 원클릭 파일럿

이 문서는 AWS 웹 콘솔만으로 QFieldCloud 단일 서버 파일럿을 설치하고 삭제하는 절차를 설명합니다. 이 저장소는 QFieldCloud 공식 프로젝트가 아닌 독립적인 비공식 배포 프로젝트입니다.

> [!CAUTION]
> 현재 릴리스별 CloudFormation 템플릿이 S3에 아직 게시되지 않았으므로 실제 `Launch QFieldCloud on AWS` 버튼은 활성화할 수 없습니다. 저장소의 원본 템플릿에는 게시 과정에서 교체할 표식이 있어 직접 실행하는 파일이 아닙니다. 게시와 checksum 검증이 끝나기 전에는 이 문서를 따라 AWS 자원을 만들지 마세요.

## 현재 상태

확인 기준일은 **2026-08-24**입니다.

- 기존 로컬 Git·PowerShell·AWS CLI 설치 흐름과 별도 설치자 역할은 기본 경로에서 제거했습니다.
- 새 기본 경로는 현재 AWS 콘솔에 로그인한 주체가 CloudFormation Quick Create 화면을 여는 방식입니다.
- 릴리스별 S3 객체 게시와 실제 Quick Create URL 생성은 아직 수행하지 않았습니다.
- 단순화한 템플릿을 이용한 실제 AWS 생성·완료·삭제 종단 간 시험도 아직 수행하지 않았습니다.
- 코드에 구현되어 있다는 사실과 실제 AWS에서 검증했다는 사실을 구분해야 합니다.

## 한눈에 보기

| 항목 | 파일럿 기본값 |
|---|---|
| AWS 리전 | 서울 `ap-northeast-2` |
| 스택 이름 | `qfieldcloud-pilot` |
| Lightsail 인스턴스 이름 | `qfieldcloud-pilot` |
| 서버 상품 | Linux 4GB RAM, 2 vCPU, 80GB SSD, 월 4TB 전송량 포함 |
| 서버 안 구성 | QFieldCloud, Nginx, QGIS 3 worker, 전용 PostgreSQL/PostGIS, 로컬 S3 호환 객체 저장소 |
| 네트워크 | HTTP 80, HTTPS 443 공개; SSH 22는 Lightsail 브라우저 SSH 경로로 제한 |
| 경보 | 가벼운 상태검사 경보 한 개, 알림 수신자는 자동 설정하지 않음 |
| 자동 snapshot | 만들지 않음 |
| 애플리케이션 백업·복원 | 제공하지 않음 |
| 설치 대기 상한 | CloudFormation은 완료 신호를 최대 150분 기다림 |
| 기존 식물이력관리 DB | 주소나 인증정보를 받지 않으며 접근하지 않음 |

QFieldCloud는 공식 릴리스 `v26.25`와 고정 Git commit, `linux/amd64` 컨테이너 이미지 digest를 사용합니다. 자세한 값과 한계는 [버전 고정 정책](version-policy.md)을 참고하세요.

## 비용

[AWS Lightsail 공식 가격표](https://aws.amazon.com/lightsail/pricing/) 기준으로 이 서버 상품은 월 **US$24**입니다.

- 인스턴스에 연결된 static IP(고정 IP)는 추가 요금이 없습니다.
- static IP가 인스턴스에서 분리된 채 남으면 **시간당 US$0.005**가 과금될 수 있습니다.
- 자동 snapshot은 만들지 않으므로 snapshot 비용을 기본 견적에 포함하지 않습니다.
- 세금, 환율, 포함량을 넘는 데이터 전송, 사용자가 별도로 만든 디스크·snapshot·기타 AWS 자원은 별도입니다.
- 인스턴스를 정지하거나 브라우저 창을 닫는 것만으로 비용이 끝나지 않습니다. 사용을 마치면 CloudFormation 스택을 삭제하고 잔존 자원을 확인해야 합니다.

세부 비용과 실패 시 과금 중단 방법은 [비용 문서](costs.md)를 참고하세요.

## 반드시 이해할 위험

> [!WARNING]
> 이 파일럿에는 백업, 복원 작업, 자동 snapshot이 없습니다. 스택·인스턴스·디스크를 삭제하거나 디스크가 손상되면 QFieldCloud DB, 프로젝트 파일과 관리자 상태를 복구할 수 없습니다.

- 앱, DB, 객체 저장소가 한 서버에 있으므로 서버 한 대의 장애가 전체 서비스 중단으로 이어집니다.
- 4GB RAM, 2 vCPU와 worker 한 개는 공식 최소사양이 아니라 작은 파일럿을 위한 검증 가정입니다.
- worker와 작업 스케줄러가 사용하는 Docker socket은 서버 관리자 권한에 가까운 위험을 가집니다.
- 설치 실패 뒤 CloudFormation 또는 Lightsail 자원이 남으면 삭제할 때까지 비용이 계속될 수 있습니다.
- 중요 데이터, 장기 운영 또는 복구가 필요한 업무에는 이 구성을 사용하면 안 됩니다.

## AWS 로그인과 권한

별도 IAM 사용자나 역할, 로컬 AWS 프로필 또는 Access Key를 만들지 않습니다. 현재 AWS 웹 콘솔에 로그인한 주체를 그대로 사용합니다.

허용되는 로그인 예시는 다음과 같습니다.

- MFA(다중 인증)가 설정된 AWS 루트 사용자
- 필요한 CloudFormation·Lightsail 권한이 있는 IAM 사용자
- 필요한 권한이 있는 IAM 역할
- IAM Identity Center 세션

루트 사용자도 설치를 시작할 수 있지만 다음 네 가지를 지켜야 합니다.

1. 루트 계정에 MFA를 설정합니다.
2. 루트 Access Key를 만들지 않습니다.
3. 이 설치가 AWS 자원과 비용을 만든다는 점을 확인합니다.
4. 릴리스별로 게시되고 checksum이 검증된 템플릿만 실행합니다.

현재 로그인 주체에 CloudFormation과 필요한 Lightsail 생성·조회·삭제 권한이 없으면 AWS가 권한 오류를 표시합니다. 이 프로젝트는 권한이 없는 사용자를 우회하거나 자동으로 관리자 권한으로 올리지 않습니다.

## Launch 버튼이 활성화되기 위한 조건

Quick Create 링크는 다음 조건이 모두 충족된 뒤에만 공개합니다.

1. 저장소 템플릿에서 릴리스용 배포 artifact를 생성합니다.
2. artifact의 SHA-256 checksum을 생성하고 기록합니다.
3. `releases/<고정 버전>/...`처럼 변경되지 않는 S3 객체 경로에 게시합니다.
4. 게시된 객체와 저장소에서 생성한 artifact의 checksum이 같은지 다시 확인합니다.
5. Quick Create URL이 서울 리전, `qfieldcloud-pilot` 스택 이름과 고정된 입력값을 포함하는지 정적 검사합니다.
6. URL이나 템플릿이 `main`, `master`, `latest` 같은 변동 참조 또는 만료되는 서명 URL을 사용하지 않는지 확인합니다.

S3 버킷이나 객체를 실제로 만들고 게시하는 일은 AWS 상태와 비용을 바꿀 수 있으므로 사용자 승인 전에는 실행하지 않습니다.

## 게시 후 사용자가 누르는 순서

현재는 S3 미게시 상태이므로 아래 절차를 실행할 수 없습니다. 버튼이 활성화된 릴리스에서만 사용합니다.

1. AWS 웹 콘솔에 로그인합니다.
2. 저장소 첫 화면의 **Launch QFieldCloud on AWS** 버튼을 누릅니다.
3. CloudFormation Quick Create 화면 오른쪽 위 리전이 **Asia Pacific (Seoul) / `ap-northeast-2`**인지 확인합니다.
4. **Stack name**이 `qfieldcloud-pilot`인지 확인합니다.
5. 템플릿 URL이 안내된 릴리스 버전의 S3 HTTPS 주소인지 확인합니다. `main`, `latest` 또는 알 수 없는 주소이면 중단합니다.
6. 4GB Lightsail 서버, static IP, 방화벽과 상태 경보가 생성된다는 설명을 읽습니다.
7. 월 US$24, 무백업 영구손실, 실패 시 잔존 자원 과금 경고를 확인합니다.
8. 미리 설정된 값은 검증 근거 없이 바꾸지 않습니다.
9. 화면 아래의 **Create stack**을 누릅니다.
10. CloudFormation **Events** 탭에서 진행 상태를 확인하고 `CREATE_COMPLETE`가 될 때까지 기다립니다.

기본 설치에는 Git 설치, 저장소 clone, PowerShell, AWS CLI, 계정 ID·ARN 입력, 역할 전환 또는 명령 실행이 없습니다.

## CloudFormation이 자동으로 수행하는 작업

사용자가 **Create stack**을 누른 뒤에는 다음 작업이 자동으로 진행됩니다.

1. Lightsail 인스턴스와 static IP 생성·연결
2. HTTP, HTTPS와 브라우저 SSH용 방화벽 규칙 적용
3. Docker와 고정된 실행 구성 설치
4. 공식 QFieldCloud 고정 릴리스와 QGIS 3 worker 준비
5. QFieldCloud 전용 PostgreSQL/PostGIS와 로컬 객체 저장소 준비
6. Nginx와 선택된 HTTPS 인증서 모드 구성
7. 데이터베이스 migration과 정적 파일 준비
8. 초기 관리자 계정과 root 전용 자격증명 파일 생성
9. 상태 endpoint와 QGIS 3 worker 최소 기능 시험
10. CloudFormation 완료 신호 전송

설치 중 기존 식물이력관리 PostgreSQL/PostGIS에는 연결하지 않습니다. 관리자 비밀번호, DB 비밀번호와 암호화 키는 CloudFormation Outputs, UserData 평문, GitHub 또는 일반 로그에 출력하지 않습니다.

## 설치 완료 뒤 확인

CloudFormation → **Stacks** → `qfieldcloud-pilot` → **Outputs**에서 다음 값을 확인합니다.

| Output | 의미 |
|---|---|
| `HttpsUrl` | QFieldCloud 접속 주소 |
| `InstanceName` | Lightsail 인스턴스 이름 |
| `InstallationStatus` | `CREATE_COMPLETE`에서 자동 설치와 필수 검사가 끝났음을 나타내는 상태 |
| `AdministratorCredentials` | 관리자 정보를 안전하게 확인할 브라우저 SSH 명령 |
| `DeleteInstructions` | 같은 릴리스에 고정된 삭제 안내 |
| `DataProtectionWarning` | 백업이 없고 삭제 시 데이터가 영구 손실된다는 경고 |

Outputs에 `HttpsUrl`이 있어도 스택 상태가 `CREATE_COMPLETE`가 아니면 설치 완료로 판단하지 않습니다.

### 관리자 계정 확인

로컬 프로그램은 필요하지 않습니다.

1. AWS 콘솔에서 **Lightsail → Instances → `qfieldcloud-pilot`**을 엽니다.
2. **Connect using SSH**를 누릅니다.
3. 열린 브라우저 터미널에 다음 한 줄을 붙여 넣습니다.

```bash
sudo /opt/qfieldcloud/bin/show-admin-credentials.sh
```

이 명령은 대화형 터미널이 아닐 때 비밀번호 표시를 거부합니다. 출력을 파일, 채팅, 화면공유, GitHub 이슈 또는 로그에 복사하지 말고 신뢰할 수 있는 비밀번호 관리자에 직접 옮깁니다.

Secrets Manager는 별도 비용과 IAM 설계가 필요하고, Lightsail 서버에서 안전하게 쓰려면 추가 자격증명 전달 경로가 필요합니다. 이 파일럿은 비밀정보를 CloudFormation에 전달하지 않기 위해 root 전용 서버 파일과 브라우저 SSH 한 줄 방식을 사용합니다.

### 선택적인 서버 상태 확인

문제 조사나 고급 검증이 필요할 때만 같은 브라우저 SSH에서 실행합니다.

```bash
sudo /opt/qfieldcloud/bin/health-check.sh
```

`overall`은 `ok`, `worker_validation`은 `passed`여야 합니다. 설치 출처, 고정 이미지, 보호 파일 권한, DB, 객체 저장소, Nginx, 인증서와 worker를 함께 검사합니다. 데이터 복구 가능 여부는 검사하지 않습니다.

## 설치 실패 시

1. CloudFormation → **Stacks → `qfieldcloud-pilot` → Events**에서 가장 먼저 실패한 자원과 오류를 확인합니다.
2. 전체 UserData, 환경변수 또는 Secret 파일을 출력하지 않습니다.
3. 권한 오류이면 현재 로그인 주체에 CloudFormation과 Lightsail 권한이 있는지 계정 관리자에게 확인합니다.
4. 실패한 스택이 자동으로 사라졌다고 가정하지 않습니다.
5. 아래 삭제 절차로 스택을 삭제한 뒤 Lightsail 자원이 남았는지 확인합니다.

실패한 인스턴스, 디스크 또는 분리된 static IP가 남으면 비용이 계속될 수 있습니다. 원인을 모른 채 같은 이름으로 반복 생성하지 마세요.

## 웹 콘솔에서 완전히 삭제

삭제하면 복구할 수 없으므로 먼저 `qfieldcloud-pilot`의 모든 데이터가 영구적으로 사라져도 되는지 확인합니다.

1. AWS 콘솔 오른쪽 위 리전을 **Asia Pacific (Seoul) / `ap-northeast-2`**로 바꿉니다.
2. **CloudFormation → Stacks**를 엽니다.
3. `qfieldcloud-pilot`을 선택합니다.
4. **Stack actions → Edit termination protection**이 보이고 현재 Enabled이면 **Disable → Save**를 누릅니다. 이미 Disabled이면 건너뜁니다.
5. **Delete** 또는 **Delete stack**을 누릅니다.
6. 대상 이름이 `qfieldcloud-pilot`인지 다시 확인하고 삭제를 승인합니다.
7. `DELETE_COMPLETE`가 될 때까지 **Events**를 확인합니다.
8. **Lightsail → Instances**에서 `qfieldcloud-pilot`이 없는지 확인합니다.
9. **Lightsail → Networking**에서 `qfieldcloud-pilot-ip` 또는 분리된 static IP가 없는지 확인합니다.
10. **Lightsail → Storage/Disks**와 **Snapshots**에서 사용자가 별도로 만든 디스크·수동 snapshot이 남지 않았는지 확인합니다.
11. Lightsail 경보 목록에서 이 스택의 상태 경보가 남지 않았는지 확인합니다.
12. **Billing and Cost Management → Bills** 또는 **Cost Explorer**에서 Lightsail 사용량이 더 늘지 않는지 확인합니다.

`DELETE_FAILED`이면 강제 삭제나 retain을 먼저 선택하지 마세요. **Events**와 **Resources**에 표시된 실제 자원 이름을 기록하고 남은 자원을 확인합니다. 연결이 끊긴 static IP는 시간당 US$0.005가 과금될 수 있습니다.

현재 원클릭 템플릿은 별도 IAM 사용자·역할·정책을 만들지 않으므로 정상 삭제 뒤 제거할 전용 IAM 자원도 없어야 합니다.

자세한 화면 설명은 [삭제 실행서](runbooks/uninstall.md)를 참고하세요.

## 실제 AWS에서 아직 검증하지 않은 항목

- 릴리스별 S3 artifact 게시와 공개 접근
- 실제 Quick Create URL의 브라우저 동작
- 현재 로그인한 루트·IAM 사용자·IAM 역할·Identity Center 세션 각각의 종단 간 생성
- 단순화한 경로의 설치 시간과 `CREATE_COMPLETE`
- 관리자 자격증명 확인, 외부 HTTPS와 QGIS 3 worker의 새 경로 재검증
- 실패 rollback과 스택 삭제 뒤 잔존 자원 없음
- 선택한 공인 인증서 모드의 최초 발급과 시간 경과 갱신

이 항목들은 AWS 비용이 발생할 수 있으므로 대상 자원, 예상 비용, 최대 실행시간과 삭제 절차를 먼저 설명하고 승인받은 뒤에만 시험합니다.

## 관련 문서

- [아키텍처](architecture.md)
- [비용](costs.md)
- [보안 모델](security-model.md)
- [스크립트 구조](diagrams/lab-lightsail-script-structure.md)
- [버전 고정 정책](version-policy.md)
- [문제 해결](troubleshooting.md)
- [운영 실행서](runbooks/)
