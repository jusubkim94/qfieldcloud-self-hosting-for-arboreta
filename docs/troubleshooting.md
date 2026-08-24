# 문제 해결 안내

## 먼저 지킬 안전 원칙

- 전체 환경변수, 인증 헤더, 비밀번호, 토큰, 개인키 또는 데이터베이스 접속 문자열을 출력하거나 공유하지 않습니다.
- 로그를 공유하기 전에 이메일, 내부 주소와 사용자 데이터를 가립니다.
- 기존 식물이력관리 PostGIS 데이터베이스를 진단이나 대체 저장소로 사용하지 않습니다.
- 실패한 설치를 무작정 반복하지 않습니다. 같은 이름의 자원 충돌과 추가 비용이 생길 수 있습니다.
- 이 파일럿에는 자동 스냅샷과 애플리케이션 백업이 없습니다. 삭제나 교체는 데이터를 영구 손실시킬 수 있습니다.

> 2026-08-24 `v0.1.2` 재시험은 Let’s Encrypt IP 인증서 적용과 갱신 timer 설치까지 성공한 뒤 `create_project`의 `Get Project Seed` 단계에서 실패했습니다. 보존 로그로 worker의 `Host: nginx` 요청이 공식 Nginx 보호 규칙에서 종료된 원인을 확인했으며, 다음 릴리스의 Docker 전용 worker API 경로는 아직 실제 AWS 재시험 전입니다.

## 설치 파일이 내려받아지지 않음

1. README의 초록색 **QFieldCloud 설치 파일 다운로드** 버튼을 다시 누릅니다.
2. GitHub 로그인이나 브라우저 다운로드 차단 알림이 있는지 확인합니다.
3. 계속 실패하면 [`releases/lab-lightsail/v0.1.2/template.yaml`](../releases/lab-lightsail/v0.1.2/template.yaml)을 열고 오른쪽 위 다운로드 버튼을 누릅니다.
4. 파일 이름이 `template.yaml`이고 빈 파일이 아닌지 확인합니다.

`infra/lab-lightsail/template.yaml`은 자리표시자가 있는 원본 틀이므로 업로드하지 않습니다.

## CloudFormation 생성 화면을 사용할 수 없음

1. 현재 로그인한 AWS 계정과 주체를 확인합니다.
2. root 사용자라면 MFA가 켜져 있는지 확인하고 root Access Key는 만들지 않습니다.
3. 현재 주체에 CloudFormation 스택과 템플릿이 정의한 Lightsail 자원을 만들고 조회하고 삭제할 권한이 있는지 AWS 관리자에게 확인합니다.
4. 별도 IAM 사용자나 역할, 로컬 AWS 프로필 또는 Access Key를 새로 만들어 우회하지 않습니다.
5. **Choose an existing template → Upload a template file** 경로를 사용했는지 확인합니다.

권한 오류 해결을 위해 전체 관리자 권한을 임의로 추가하지 않습니다.

## 리전 또는 이름 오류

- AWS 콘솔 오른쪽 위 리전을 **Asia Pacific (Seoul) ap-northeast-2**로 바꿉니다.
- **Stack name**과 **Lightsail instance name**이 모두 `qfieldcloud-pilot`인지 확인합니다.
- 이미 같은 이름의 스택이나 인스턴스가 있으면 새 설치를 시작하지 않습니다.
- 기존 자원이 실패한 설치의 잔존물인지, 다른 사람이 사용하는 자원인지 먼저 확인합니다.

## 스택 생성 실패 또는 오래 멈춤

다음 진단 배포부터는 스택 생성 전 **Configure stack options → Stack failure options → Preserve successfully provisioned resources**를 선택합니다. 이 선택은 YAML에서 자동 설정할 수 없습니다. 실패한 서버와 root 전용 진단 로그가 남는 대신 스택을 삭제할 때까지 비용이 계속 발생합니다.

1. **CloudFormation → Stacks → qfieldcloud-pilot → Events**를 엽니다.
2. 가장 최근 메시지만 보지 말고 처음 실패한 자원을 찾습니다.
3. **Resources** 탭에서 실제로 생성된 자원을 확인합니다.
4. **Lightsail → Instances**, **Networking → Static IPs**, **Alarms**에서도 잔존 자원을 확인합니다.
5. 조사하지 않을 경우 [삭제 실행서](runbooks/uninstall.md)에 따라 제거합니다.

worker 검증이 실패하면 설치기는 시험 프로젝트를 정리하기 전에 `/var/lib/qfieldcloud-bootstrap/diagnostics/worker-smoke-failure.*`에 Job feedback, 최근 Nginx·app·worker wrapper 로그, 확인 가능한 QGIS 작업 컨테이너 상태, OOM 기록과 서버 용량을 자동 저장합니다. 정확한 경로는 `/var/lib/qfieldcloud-bootstrap/bootstrap.log`에도 기록됩니다. 확인 방법과 공유 전 가림 항목은 [로그 실행서](runbooks/logs.md)를 따릅니다.

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

설치기는 공인 인증서를 Nginx에 적용한 뒤 최대 60초 동안 새 인증서 지문과 신뢰된 HTTPS 응답을 다시 확인합니다. 각 시도의 마지막 결과는 root만 읽을 수 있는 `/opt/qfieldcloud/state/certbot-log/last-validation.log`에 저장합니다. `status`, `expected_fingerprint`, `observed_fingerprint`, `openssl_exit`, `curl_exit`을 확인하면 새 인증서 전환 지연과 TLS 신뢰 오류를 구분할 수 있습니다. 이 파일에는 개인키를 기록하지 않지만, 공유하기 전 공개 IP 등 운영 식별정보를 가립니다.

공인 IP 인증서 발급, Nginx 적용과 신뢰된 HTTPS 응답은 실제 AWS에서 확인했습니다. 설치 완료와 시간 경과 자동 갱신까지는 아직 종단 간 검증하지 않았습니다. 정적 검사 성공만으로 검증 완료라고 표현하지 않습니다.

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
