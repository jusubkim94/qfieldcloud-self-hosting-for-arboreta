# 문제 해결 안내

## 먼저 지킬 안전 원칙

- 전체 환경변수, 인증 헤더, 비밀번호, 토큰, 개인키 또는 데이터베이스 접속 문자열을 출력하거나 공유하지 않습니다.
- 로그를 공유하기 전에 이메일, 내부 주소와 사용자 데이터를 가립니다.
- 기존 식물이력관리 PostGIS 데이터베이스를 진단이나 대체 저장소로 사용하지 않습니다.
- 실패한 설치를 무작정 반복하지 않습니다. 같은 이름의 자원 충돌과 추가 비용이 생길 수 있습니다.
- 이 파일럿에는 자동 스냅샷과 애플리케이션 백업이 없습니다. 삭제나 교체는 데이터를 영구 손실시킬 수 있습니다.

> 현재 릴리스별 S3 템플릿과 Quick Create URL은 게시되지 않았고, 단순화한 전체 흐름은 실제 AWS에서 아직 검증하지 않았습니다.

## Launch 버튼을 사용할 수 없음

현재는 정상적인 제한입니다. 프로젝트가 다음 조건을 모두 확인하기 전에는 버튼을 활성화하면 안 됩니다.

1. 릴리스별 `template.yaml`, `manifest.json`, `SHA256SUMS` 생성
2. S3 Versioning이 켜진 고정 경로에 게시
3. 게시 객체의 SHA-256, 길이와 `VersionId` 재검증
4. 익명으로 템플릿을 읽을 수 있는지 확인
5. 해당 객체 버전을 가리키는 Quick Create URL 생성

저장소 원본 템플릿을 직접 업로드하거나 임의의 S3 URL을 대신 사용하지 않습니다.

## Quick Create 화면이 열리지 않음

1. 현재 로그인한 AWS 계정과 주체를 확인합니다.
2. root 사용자라면 MFA가 켜져 있는지 확인하고 root Access Key는 만들지 않습니다.
3. 현재 주체에 CloudFormation 스택과 템플릿이 정의한 Lightsail 자원을 만들고 조회하고 삭제할 권한이 있는지 AWS 관리자에게 확인합니다.
4. 별도 IAM 사용자나 역할, 로컬 AWS 프로필 또는 Access Key를 새로 만들어 우회하지 않습니다.
5. 브라우저의 URL이 프로젝트가 공개한 고정 S3 `versionId`를 포함하는지 확인합니다.

권한 오류 해결을 위해 전체 관리자 권한을 임의로 추가하지 않습니다.

## 리전 또는 이름 오류

- AWS 콘솔 오른쪽 위 리전을 **Asia Pacific (Seoul) ap-northeast-2**로 바꿉니다.
- **Stack name**과 **Lightsail instance name**이 모두 `qfieldcloud-pilot`인지 확인합니다.
- 이미 같은 이름의 스택이나 인스턴스가 있으면 새 설치를 시작하지 않습니다.
- 기존 자원이 실패한 설치의 잔존물인지, 다른 사람이 사용하는 자원인지 먼저 확인합니다.

## 스택 생성 실패 또는 오래 멈춤

1. **CloudFormation → Stacks → qfieldcloud-pilot → Events**를 엽니다.
2. 가장 최근 메시지만 보지 말고 처음 실패한 자원을 찾습니다.
3. **Resources** 탭에서 실제로 생성된 자원을 확인합니다.
4. **Lightsail → Instances**, **Networking → Static IPs**, **Alarms**에서도 잔존 자원을 확인합니다.
5. 조사하지 않을 경우 [삭제 실행서](runbooks/uninstall.md)에 따라 제거합니다.

설치기는 완료 신호를 최대 약 150분 기다리도록 설계되어 있습니다. 브라우저를 닫았거나 CloudFormation이 실패했다고 해서 자원이 모두 사라졌다고 가정하지 않습니다. 남은 인스턴스는 월 **US$24**, 분리된 고정 IP는 시간당 **US$0.005** 비용이 발생할 수 있습니다.

## 웹 또는 API가 열리지 않음

먼저 [상태 확인 실행서](runbooks/status.md)의 CloudFormation Outputs를 확인합니다.

1. `HttpsUrl`이 현재 스택의 값인지 확인합니다.
2. **Lightsail → Instances → qfieldcloud-pilot**이 `Running`인지 확인합니다.
3. **Connect using SSH**를 누른 뒤 다음 제한된 상태 명령만 먼저 실행합니다.

```bash
sudo /opt/qfieldcloud/bin/health-check.sh
```

4. `overall`, `tls_certificate`, `database`, `storage`와 `worker_validation`을 확인합니다.
5. 추가 로그가 필요하면 [로그 실행서](runbooks/logs.md)에서 범위가 제한된 로그만 확인합니다.

웹 페이지만 열린 경우에도 데이터베이스, 객체 저장소 또는 worker가 실패할 수 있으므로 전체 성공으로 판정하지 않습니다.

## 인증서 오류

| 증상 | 확인할 내용 | 하지 말아야 할 일 |
|---|---|---|
| 자체 서명 모드의 브라우저 경고 | Outputs의 호스트, 설치 때 기록한 지문, 인증서 만료 | 경고를 무시하고 운영 신뢰로 간주 |
| 공인 인증서 최초 발급 실패 | 약관 동의, 고정 IPv4, TCP 80, CA 응답과 rate limit | 무제한 재시도 |
| 공인 인증서 갱신 실패 | `certificate_renewal`, 마지막 확인 시각, timer 상태 | 유효한 이전 인증서나 실패 표식 삭제 |
| 공인 인증서인데 주소 불일치 | 접속 IP와 인증서 IP SAN, CA chain | 인증서 검증 비활성화 |

공인 인증서 최초 발급과 시간 경과 자동 갱신은 실제 AWS에서 아직 종단 간 검증하지 않았습니다. 정적 검사 성공만으로 검증 완료라고 표현하지 않습니다.

## 데이터베이스, 저장소 또는 worker 오류

| 상태 항목 | 먼저 확인 | 금지 |
|---|---|---|
| `database` 오류 | 이 서버의 QFieldCloud 전용 PostgreSQL/PostGIS 컨테이너와 디스크 여유 | 기존 식물이력관리 DB로 대체 |
| `storage` 오류 | 이 서버의 로컬 S3 호환 저장소와 디스크 여유 | 저장소를 public으로 전환 |
| `worker_validation` 오류 | worker wrapper, 고정 QGIS 3 이미지, 시험 작업 로그와 메모리 | 검증하지 않은 이미지로 변경 |
| 디스크 부족 | 용량 사용처와 최근 오류 | 확인 없이 데이터 파일 삭제 |

파괴적인 조치가 필요하면 대상, 영향과 복구 불가능성을 먼저 설명하고 승인을 받습니다.

## 관리자 정보를 다시 확인해야 함

1. AWS 콘솔에서 **Lightsail → Instances → qfieldcloud-pilot**을 엽니다.
2. **Connect using SSH**를 누릅니다.
3. CloudFormation Output `AdministratorCredentials`에 표시된 다음 명령을 실행합니다.

```bash
sudo /opt/qfieldcloud/bin/show-admin-credentials.sh
```

출력은 해당 브라우저 터미널에서만 확인하고 채팅, 문서, 스크린샷 또는 문제 보고서에 복사하지 않습니다.

## 삭제했는데 비용이 계속 보임

1. **CloudFormation → Stacks**에서 `qfieldcloud-pilot`이 삭제되었는지 확인합니다.
2. **Lightsail → Instances**, **Networking → Static IPs**, **Storage → Disks**, **Snapshots**, **Alarms**를 각각 확인합니다.
3. 특히 인스턴스와 분리된 고정 IP를 확인합니다.
4. **Billing and Cost Management → Bills → Amazon Lightsail**에서 사용량을 확인합니다.

청구 반영에는 시간이 걸릴 수 있습니다. 소유 관계가 불확실한 자원을 비용 때문에 즉시 삭제하지 말고 AWS 관리자에게 확인합니다.

## 데이터 복구가 필요함

이 파일럿에는 자동 복구 지점이 없습니다. 스택, 인스턴스 또는 디스크가 이미 삭제되었다면 이 저장소의 기능으로 QFieldCloud 데이터를 복구할 수 없습니다. 남은 자원이 있다면 추가 삭제나 재설치를 멈추고 그 상태를 보존한 채 전문가의 도움을 요청하세요.
