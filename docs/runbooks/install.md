# 설치 실행서

이 문서는 AWS 웹 콘솔에서 `qfieldcloud-pilot` 스택을 만드는 순서입니다.

> 현재 S3에 릴리스별 템플릿이 게시되지 않았으므로 실제 `Launch QFieldCloud on AWS` 버튼은 사용할 수 없습니다. 저장소의 원본 `infra/lab-lightsail/template.yaml`에는 릴리스 게시 때 교체할 표식이 있어 직접 업로드하거나 실행하면 안 됩니다. 실제 AWS 원클릭 설치도 아직 검증하지 않았습니다.

## 1. 시작 전에 확인

### AWS 로그인

- 현재 AWS 웹 콘솔에 로그인한 주체가 CloudFormation 스택과 템플릿에 정의된 Lightsail 인스턴스, 고정 IP, 네트워크 규칙, 상태 알람을 만들고 조회하고 삭제할 권한을 이미 가지고 있어야 합니다.
- 이 프로젝트를 위해 별도 IAM 사용자나 역할, 로컬 AWS 프로필, Access Key를 만들지 않습니다.
- AWS 계정의 root 사용자로 로그인해야만 하는 상황이면 먼저 다중 인증(MFA)을 켭니다.
- root 사용자용 Access Key는 만들지 않습니다.
- 권한 오류가 나면 권한 범위를 임의로 넓히지 말고 조직의 AWS 관리자에게 현재 로그인 주체에 필요한 작업만 요청합니다.

### 비용과 데이터

화면에서 다음 조건을 이해한 뒤에만 **Create stack**을 누릅니다.

| 항목 | 값 |
|---|---|
| 리전 | Asia Pacific (Seoul), `ap-northeast-2` |
| 스택 이름 | `qfieldcloud-pilot` |
| Lightsail 인스턴스 이름 | `qfieldcloud-pilot` |
| 사양 | 4GB 메모리, 2 vCPU, 80GB SSD, 월 4TB 전송량 |
| 기본 가격 | 월 US$24 |
| 고정 IP | 연결 중 무료, 미연결 시 시간당 US$0.005 |
| 데이터 보호 | 자동 스냅샷 없음, 애플리케이션 백업 없음 |

스택, 인스턴스 또는 디스크를 삭제하면 QFieldCloud 데이터는 복구할 수 없습니다. 설치 실패 중에도 자원이 남아 비용이 발생할 수 있습니다.

## 2. 게시 뒤 웹 콘솔에서 누르는 순서

현재는 게시 전이므로 아래 순서를 실행할 수 없습니다. 프로젝트가 릴리스별 S3 URL과 checksum을 검증하고 버튼을 활성화한 뒤에만 사용합니다.

1. 프로젝트 첫 화면에서 **Launch QFieldCloud on AWS**를 누릅니다.
2. AWS 로그인 화면이 나오면 위에서 확인한 주체로 로그인합니다.
3. 콘솔 오른쪽 위 리전 선택기에서 **Asia Pacific (Seoul) ap-northeast-2**를 선택합니다.
4. **CloudFormation → Stacks → Quick create stack** 화면이 열렸는지 확인합니다.
5. **Template URL**이 프로젝트가 안내한 버전 고정 S3 HTTPS 주소인지 확인합니다. URL에 S3 객체 `versionId`가 없거나 `main`, `master`, `latest` 같은 변동 참조가 있으면 중단합니다.
6. **Stack name**에 `qfieldcloud-pilot`이 입력되어 있는지 확인합니다.
7. **Parameters**에서 다음 값을 확인합니다.
   - **AWS Region**: `ap-northeast-2`
   - **Lightsail Availability Zone**: `ap-northeast-2a` 등 서울 가용 영역
   - **Lightsail instance name**: `qfieldcloud-pilot`
   - **TLS certificate mode**: 릴리스 안내와 같은 값
   - 공인 인증서 모드를 선택했다면 Let’s Encrypt 가입자 약관을 직접 읽고 동의한 경우에만 동의 값을 `true`로 선택
8. 화면에 표시된 생성 자원과 비용 경고를 다시 읽습니다.
9. **Create stack**을 한 번만 누릅니다. 기다리는 동안 같은 이름으로 다시 만들지 않습니다.

이 템플릿은 IAM 자원을 만들지 않으므로 IAM 기능 생성 승인 확인란을 요구해서는 안 됩니다. 예상하지 못한 IAM 승인 화면이 보이면 중단하고 템플릿 URL을 다시 확인합니다.

## 3. 자동으로 수행되는 작업

CloudFormation은 다음 작업을 수행하도록 설계되어 있습니다.

1. Ubuntu 24.04 Lightsail 인스턴스를 만듭니다.
2. 고정 IPv4를 만들고 인스턴스에 연결합니다.
3. HTTP, HTTPS와 AWS 브라우저 SSH에 필요한 제한된 네트워크 규칙을 적용합니다.
4. 릴리스에 고정된 설치 파일의 SHA-256을 확인한 뒤 실행합니다.
5. QFieldCloud, 전용 PostgreSQL/PostGIS, 로컬 S3 호환 객체 저장소와 QGIS 3 worker를 한 서버에 설치합니다.
6. 서비스 상태, 데이터베이스 migration과 작은 worker 시험이 모두 통과한 경우에만 완료 신호를 보냅니다.

CloudFormation 대기 시간은 최대 약 150분으로 설정되어 있습니다. 브라우저를 닫아도 스택 작업은 계속될 수 있으므로 새 설치를 시작하지 말고 같은 스택의 **Events**를 확인합니다.

## 4. 완료 확인

1. **CloudFormation → Stacks → qfieldcloud-pilot**을 엽니다.
2. **Stack info**에서 상태가 `CREATE_COMPLETE`인지 확인합니다.
3. **Outputs** 탭에서 `InstallationStatus`가 `installation-complete`인지 확인합니다.
4. `InstanceName`이 `qfieldcloud-pilot`이고 `DeployedRegion`이 `ap-northeast-2`인지 확인합니다.
5. `HttpsUrl`을 새 탭에서 열고, 인증서 모드별 안내를 따릅니다.
6. 관리자 정보는 `AdministratorCredentials`에 표시된 절차를 따라 Lightsail 브라우저 SSH에서만 확인합니다.
7. 이어서 [상태 확인](status.md)을 수행합니다.

비밀번호나 토큰은 CloudFormation Outputs, 채팅, 문제 보고서에 복사하지 않습니다.

## 5. 실패한 경우

`CREATE_FAILED`, `ROLLBACK_FAILED` 또는 오래 지속되는 `*_IN_PROGRESS`는 성공이 아닙니다.

1. 스택의 **Events** 탭에서 첫 번째 실패 원인을 확인합니다.
2. 같은 이름으로 새 스택을 만들거나 실패한 설치를 무작정 반복하지 않습니다.
3. **CloudFormation**과 **Lightsail** 양쪽에서 인스턴스, 고정 IP와 알람이 남았는지 확인합니다.
4. 더 이상 조사하지 않을 경우 [삭제 실행서](uninstall.md)에 따라 잔존 자원을 제거합니다.

설치 실패 뒤에도 남은 고정 IP가 인스턴스와 분리되면 시간당 US$0.005가 청구될 수 있습니다.
