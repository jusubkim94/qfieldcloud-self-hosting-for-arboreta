# 로그 실행서

## 우선순위

1. Nginx: HTTPS와 요청 전달 오류
2. app: 인증, API, DB 및 storage 오류
3. worker wrapper: 작업 선택과 임시 컨테이너 관리 오류
4. 임시 QGIS worker: 프로젝트 처리 오류
5. DB와 객체 저장소: 해당 서비스 장애가 의심될 때만

## 안전한 수집

- 조사 시간 범위와 영향을 받은 작업 ID만 선택합니다.
- 전체 환경변수와 전체 컨테이너 상세정보를 수집하지 않습니다.
- 인증 헤더, 토큰, 이메일, 내부 호스트, DB 접속 문자열과 프로젝트 Secret을 가립니다.
- 가린 진단본을 만들고 원본 운영 로그를 공개 Issue에 첨부하지 않습니다.
- 로그 회전과 최대 크기를 설정해 디스크 고갈을 막습니다.

## 기록할 정보

버전 매니페스트, 발생 시각과 시간대, 영향 범위, 마지막 정상 시각, 재현 단계와 가려진 오류 종류를 기록합니다.

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

DB나 객체 저장소 장애가 의심될 때만 같은 `docker compose ... logs` 명령의 마지막 서비스 이름을 `db rustfs`로 바꿉니다. `docker inspect`, `env`, `printenv`, `set`, `sudo cat /opt/qfieldcloud/state/secrets.env`는 사용하지 않습니다.

공유하기 전 로컬 화면에서 인증 헤더, 토큰, 이메일, 프로젝트 이름, 내부 주소와 DB 접속 문자열을 가립니다. 원본 파일을 GitHub Issue나 채팅에 올리지 않습니다. 진단이 끝난 뒤 파일 삭제가 필요하면 정확한 경로와 보존 필요성을 확인하고 별도 승인 후 처리합니다.
