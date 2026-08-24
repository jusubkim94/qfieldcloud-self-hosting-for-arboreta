# 보안 모델

이 문서는 브라우저 수동 업로드 `lab-lightsail` 파일럿이 무엇을 보호하고 어떤 위험을 받아들이는지 설명합니다. 이 구성은 중요 운영용 보안 기준을 충족한다고 보장하지 않습니다.

## 현재 검증 상태

- 현재 `v0.1.4` CloudFormation artifact와 SHA-256은 저장소에 포함되어 있습니다. 과거 `v0.1.0`~`v0.1.3`도 변경 없이 보존합니다.
- `v0.1.3` 자체서명 경로는 실제 AWS `CREATE_COMPLETE`까지 통과했습니다. `v0.1.4` 기본 공인 인증서 경로와 성공 스택 삭제는 아직 재시험 전입니다.
- 따라서 아래 내용은 파일럿 설계와 검증 범위이며 운영 준비 완료나 장기 안정성 보장이 아닙니다.

## 보호 대상

- QFieldCloud 사용자 계정과 관리자 비밀번호
- QFieldCloud 전용 PostgreSQL/PostGIS 데이터
- 프로젝트 파일과 로컬 객체 저장소 인증정보
- 암호화 키, 작업용 임시 토큰과 TLS 개인키
- Let’s Encrypt 모드에서 사용하는 ACME 계정 상태
- AWS 계정과 생성된 Lightsail 자원

기존 식물이력관리 PostgreSQL/PostGIS는 별도 보안 경계입니다. 템플릿과 설치 스크립트는 그 주소나 인증정보를 받지 않고 네트워크 연결도 만들지 않습니다.

## AWS 로그인 주체

기본 설치는 현재 AWS 웹 콘솔에 로그인한 주체를 그대로 사용합니다. 별도 설치자 IAM 사용자, 고정 배포 역할, 로컬 AWS 프로필 또는 Access Key를 만들지 않습니다.

현재 주체는 다음 중 하나일 수 있습니다.

- MFA가 설정된 AWS 루트 사용자
- 필요한 권한이 있는 IAM 사용자
- 필요한 권한이 있는 IAM 역할
- IAM Identity Center 세션

루트 사용자를 기술적으로 차단하지는 않지만 다음 통제를 지켜야 합니다.

1. 루트 MFA를 반드시 설정합니다.
2. 루트 Access Key를 만들지 않습니다.
3. 평소 작업에는 가능한 한 비루트 관리 주체를 사용합니다.
4. AWS 자원과 비용이 생성됨을 확인합니다.
5. 릴리스 디렉터리의 checksum이 검증된 완성 템플릿만 실행합니다.

CloudFormation 또는 Lightsail 권한이 부족하면 AWS의 권한 오류로 설치가 중단됩니다. 이 프로젝트는 부족한 권한을 우회하거나 현재 사용자를 자동 승격하지 않습니다.

## 공급망과 배포 artifact

수동 업로드에 사용할 템플릿은 다음 조건을 만족해야 합니다.

- 버전별 릴리스 디렉터리에 커밋된 완성 파일
- `manifest.json`, `SHA256SUMS`와 템플릿의 SHA-256이 일치
- QFieldCloud 릴리스, Git commit과 `linux/amd64` 이미지 digest가 고정
- bootstrap 파일을 다운로드한 뒤 SHA-256을 확인하고 일치할 때만 실행
- 다운로드 주소에 인증정보를 포함하지 않음

원본 틀에는 자리표시자가 있으므로 사용자는 README가 가리키는 완성 릴리스 파일만 내려받아야 합니다.

## Secret 처리

- 템플릿 입력값이나 다운로드 URL에 비밀번호, 토큰, Access Key, 개인키 또는 DB 접속 문자열을 넣지 않습니다.
- 관리자 비밀번호와 서비스 Secret은 Lightsail 인스턴스 안에서 생성합니다.
- CloudFormation Outputs에는 비밀값 대신 브라우저 SSH에서 실행할 명령만 표시합니다.
- bootstrap 로그는 root 전용 파일에 기록하고 일반 CloudFormation 출력으로 보내지 않습니다.
- `show-admin-credentials.sh`는 대화형 터미널이 아니거나 출력이 재지정되면 비밀번호 표시를 거부합니다.
- Secret을 확인한 뒤에는 신뢰할 수 있는 비밀번호 관리자에 직접 옮기고 채팅·화면공유·GitHub 이슈에 붙여 넣지 않습니다.
- Secret이 노출되면 파일만 지우지 말고 해당 값을 폐기하고 교체합니다.

이 파일럿은 추가 IAM 전달 경로와 관리형 비밀 저장소 비용을 만들지 않기 위해 서버의 root 전용 파일과 Lightsail 브라우저 SSH를 사용합니다.

## 네트워크와 HTTPS

- HTTP 80과 HTTPS 443은 인터넷에 공개됩니다.
- SSH 22는 AWS가 관리하는 Lightsail 브라우저 SSH 별칭으로 제한합니다.
- PostgreSQL/PostGIS와 객체 저장소 관리 포트를 인터넷에 공개하지 않습니다.
- worker 전용 Nginx 8080은 고정 Docker 내부망에서만 허용하고 Lightsail 호스트에는 게시하지 않습니다.
- Docker API를 TCP 포트로 공개하지 않습니다.
- `self-signed` 모드는 공인 서버 신원을 제공하지 않으며 브라우저 경고와 `sslip.io` 의존이 있습니다.
- `letsencrypt-ip` 모드는 Let’s Encrypt, 공개 인터넷, HTTP-01 도달 가능성과 rate limit에 의존합니다.
- 공인 인증서가 있어도 애플리케이션 보안이나 운영 준비 완료를 의미하지 않습니다.

공인 인증서 모드는 고정된 Certbot 이미지, 현재 static IPv4 SAN, CA chain, 인증서·개인키 일치와 만료 여유를 검사한 뒤에만 적용합니다. 실제 원클릭 경로의 최초 발급과 Nginx 적용은 확인했지만 시간 경과 갱신은 아직 검증하지 않았습니다.

## Docker 호스트 위험

QFieldCloud worker wrapper는 작업마다 임시 QGIS worker를 만들기 위해 호스트 Docker socket을 사용합니다. 작업 스케줄러도 Docker label을 읽습니다. socket의 `:ro` 마운트는 Docker API를 읽기 전용으로 제한하지 않습니다.

worker wrapper나 작업 스케줄러가 침해되면 공격자가 높은 권한의 컨테이너를 만들어 단일 서버 전체를 장악할 수 있습니다. 이를 완화하기 위해 다음을 적용합니다.

- QFieldCloud와 QGIS worker 이미지를 digest로 고정
- Docker API 외부 노출 금지
- 예상하지 않은 컨테이너와 작업 로그 점검
- 중요 운영에서는 앱·worker·DB·객체 저장소 분리 검토

## 데이터 보호 한계

> [!WARNING]
> 이 파일럿에는 애플리케이션 백업, 복원 작업과 자동 snapshot이 없습니다. 인스턴스·디스크·스택 삭제 또는 디스크 손상 시 데이터를 복구할 수 없습니다.

사용자가 별도로 수동 snapshot이나 디스크를 만들 수는 있지만 이 프로젝트가 생성·검증·관리하는 기능이 아닙니다. 수동 snapshot에는 QFieldCloud 데이터와 Secret이 포함될 수 있고 삭제할 때까지 과금될 수 있습니다.

중요 데이터, 법적 보존 의무 또는 복구 목표가 있다면 이 파일럿을 사용하지 말고 DB와 객체 저장소를 분리한 운영 구조를 설계해야 합니다.

## 설치 실패와 삭제

CloudFormation 실패가 항상 모든 자원을 즉시 없애는 것은 아닙니다. 실패 또는 삭제 실패 뒤 다음 항목을 직접 확인합니다.

- CloudFormation 스택과 실패 이벤트
- Lightsail 인스턴스
- static IP와 연결 상태
- 디스크와 사용자가 별도로 만든 snapshot
- 상태 경보
- Billing의 Lightsail 사용량

인스턴스에서 분리된 static IP는 시간당 US$0.005가 과금될 수 있습니다. 템플릿은 전용 IAM 사용자·역할·정책을 만들지 않으므로 정상 삭제 뒤 파일럿 전용 IAM 자원이 남아서는 안 됩니다.

## 위협과 대응

| 위협 | 대응 또는 한계 |
|---|---|
| 변조된 템플릿 실행 | 릴리스별 S3 경로, SHA-256 대조, 변동 참조 금지 |
| AWS 인증정보 노출 | Access Key를 만들거나 URL·문서·로그에 넣지 않음 |
| 루트 계정 탈취 | MFA 필수, 루트 Access Key 금지, 검증된 템플릿만 실행 |
| 관리자 비밀번호 노출 | 서버 내부 생성, Outputs 비노출, 대화형 브라우저 SSH에서만 조회 |
| Docker socket 악용 | 외부 노출 금지, 이미지 digest 고정, 단일 서버 위험 명시 |
| 공개 서비스 공격 | DB·storage 관리 포트 비공개, HTTP/HTTPS만 공개 |
| 서버·디스크 삭제 | 자동 보호 기능 없음; 데이터 영구손실을 설치 전 명시 |
| 설치 실패 뒤 과금 | CloudFormation·Lightsail·Billing에서 잔존 자원 확인 |
| 기존 업무 DB 오작동 | 입력·자격증명·네트워크 경계 완전 분리 |

## 관련 문서

- [파일럿 안내서](lab-lightsail.md)
- [아키텍처](architecture.md)
- [비용](costs.md)
- [삭제 실행서](runbooks/uninstall.md)
