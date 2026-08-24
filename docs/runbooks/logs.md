# 로그 실행서

2026-08-24 실제 AWS `v0.1.2` 시험에서 공인 IP 인증서 발급·Nginx 적용·신뢰된 HTTPS 확인과 자동 갱신 timer 설치까지 성공했고, `v0.1.3` 자체서명 시험과 2026-08-25 `v0.1.4` 기본 공인 인증서 시험은 전체 설치 완료까지 통과했습니다. `v0.1.4` 설치 완료 gate는 timer의 enabled·active 상태를 확인했지만 시간 경과 후의 실제 인증서 자동 갱신은 아직 검증하지 않았습니다. [검증 기록](../verification/lab-lightsail-v0.1.4-2026-08-25.md)과 함께 아래 절차를 사용합니다.

## 우선순위

1. Nginx: HTTPS와 요청 전달 오류
2. `letsencrypt-ip`일 때 인증서 갱신 timer·service와 root 전용 Certbot 로그
3. app: 인증, API, DB 및 storage 오류
4. worker wrapper: 작업 선택과 임시 컨테이너 관리 오류
5. 임시 QGIS worker: 프로젝트 처리 오류
6. DB와 객체 저장소: 해당 서비스 장애가 의심될 때만

## 안전한 수집

- 조사 시간 범위와 영향을 받은 작업 ID만 선택합니다.
- 전체 환경변수와 전체 컨테이너 상세정보를 수집하지 않습니다.
- 인증 헤더, 토큰, 이메일, 내부 호스트, DB 접속 문자열과 프로젝트 Secret을 가립니다.
- 가린 진단본을 만들고 원본 운영 로그를 공개 Issue에 첨부하지 않습니다.
- 로그 회전과 최대 크기를 설정해 디스크 고갈을 막습니다.

## 기록할 정보

버전 매니페스트, 인증서 모드, 발생 시각과 시간대, 영향 범위, 마지막 정상 시각, 재현 단계와 가려진 오류 종류를 기록합니다. 공인 모드에서는 인증서 만료 시각, 마지막 갱신 확인·성공 시각과 timer 활성 여부만 기록하고 ACME 계정 내용이나 개인키는 기록하지 않습니다.

## 서버에서 제한된 범위만 수집

먼저 전체 환경변수나 컨테이너 상세정보를 출력하지 않는 상태 확인을 실행합니다.

```bash
sudo /opt/qfieldcloud/bin/health-check.sh
```

최근 30분, 서비스별 마지막 200줄만 root 전용 파일에 모읍니다. 이 명령은 컨테이너 환경변수를 출력하지 않지만 애플리케이션 로그에 이메일·프로젝트 이름·요청 경로가 있을 수 있습니다.

```bash
sudo install -m 0700 -d /var/tmp/qfc-diagnostics
sudo bash -c 'umask 077; docker compose --env-file /opt/qfieldcloud/versions.env --env-file /opt/qfieldcloud/state/runtime.env --file /opt/qfieldcloud/compose.yaml logs --no-color --timestamps --since 30m --tail 200 nginx app worker_wrapper > /var/tmp/qfc-diagnostics/compose-last-30m.log'
sudo less /var/tmp/qfc-diagnostics/compose-last-30m.log
```

CloudFormation 설치 자체가 실패했다면 다음 root 전용 로그의 마지막 200줄만 먼저 봅니다.

```bash
sudo tail -n 200 /var/lib/qfieldcloud-bootstrap/bootstrap.log
```

worker smoke test가 실패하면 시험 프로젝트를 삭제하기 전에 다음 root 전용 자료를 자동 보존합니다.

- `summary.txt`: 시각, 릴리스, 작업 종류와 ID
- `job.json`: 제한된 Job output·feedback과 오류 분류
- `compose-app-worker.log`: 최근 30분의 Nginx·app·worker wrapper 마지막 400줄
- `qgis-container-state.txt`, `qgis-container.log`: 정확히 일치하는 임시 QGIS 컨테이너가 아직 남아 있을 때만 생성
- `host-capacity.txt`, `kernel-oom.log`: 메모리·디스크 상태와 OOM 강제 종료 흔적

bootstrap 로그의 `Worker failure diagnostics saved in root-only directory:` 다음 경로를 확인합니다. 경로를 찾지 못하면 최신 항목 이름을 다음 파일에서 확인합니다.

```bash
sudo cat /var/lib/qfieldcloud-bootstrap/diagnostics/latest-worker-smoke-failure
```

표시된 이름이 정확히 `worker-smoke-failure.`로 시작하는지 확인한 뒤 해당 디렉터리의 `summary.txt`와 `job.json`부터 봅니다. 이 자동 보존은 서버 디스크 안에만 존재하므로 CloudFormation 실패 옵션에서 리소스 보존을 선택하지 않아 Lightsail이 롤백되면 로그도 함께 사라집니다.

`letsencrypt-ip`의 최초 발급 또는 자동 갱신이 실패했다면 전체 ACME 상태를 복사하지 말고 다음 제한된 정보부터 봅니다.

```bash
sudo systemctl status qfieldcloud-certificate-renew.timer --no-pager --lines=30
sudo systemctl status qfieldcloud-certificate-renew.service --no-pager --lines=30
sudo journalctl -u qfieldcloud-certificate-renew.service --since '24 hours ago' -n 200 --no-pager
sudo tail -n 200 /opt/qfieldcloud/state/certbot-log/last-command.log
sudo tail -n 50 /opt/qfieldcloud/state/certbot-log/last-validation.log
```

`last-validation.log`는 최대 60초의 Nginx 적용 재시도 중 마지막 시도만 원자적으로 보존합니다. `expected_fingerprint`와 `observed_fingerprint`가 다르면 Nginx 인증서 전환 실패이고, 두 값이 같은데 `curl_exit`이 `0`이 아니면 TLS 신뢰 또는 HTTPS 응답 실패입니다.

`/opt/qfieldcloud/state/certbot`, `certbot-work`, `certbot-log`, `certs`는 ACME 계정·개인키·발급 이력이 있을 수 있는 root 전용 경로입니다. 디렉터리를 통째로 archive하거나 채팅·GitHub에 올리지 않습니다. `last-certificate-renewal-failure`는 상태 도구로 존재 여부를 먼저 확인하고, 원본 로그를 공유해야 한다면 CA order URL, 공개 IP, 이메일, 토큰처럼 운영 식별에 도움이 되는 값도 가립니다.

DB나 객체 저장소 장애가 의심될 때만 같은 `docker compose ... logs` 명령의 마지막 서비스 이름을 `db rustfs`로 바꿉니다. `docker inspect`, `env`, `printenv`, `set`, `sudo cat /opt/qfieldcloud/state/secrets.env`는 사용하지 않습니다.

공유하기 전 로컬 화면에서 인증 헤더, 토큰, 이메일, 프로젝트 이름, 공개·내부 주소, ACME order URL과 DB 접속 문자열을 가립니다. 원본 파일을 GitHub Issue나 채팅에 올리지 않습니다. 진단이 끝난 뒤 파일 삭제가 필요하면 정확한 경로와 보존 필요성을 확인하고 별도 승인 후 처리합니다. 갱신 실패를 숨기려고 표식이나 기존 인증서를 먼저 지우지 마세요.
