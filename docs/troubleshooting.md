# 문제 해결 안내

## 안전 원칙

문제를 해결하려고 전체 환경변수, 인증 헤더, DB 접속 문자열 또는 Secret 파일을 출력하지 않습니다. 로그를 공유하기 전 이메일, 내부 주소, 토큰과 사용자 데이터를 가립니다. 기존 식물이력관리 DB에 진단 목적으로 접속하지 않습니다.

## 진단 순서

현재 실제 AWS 검증 이력은 기본 `self-signed` 모드입니다. `letsencrypt-ip`은 현재 AWS 스택에 적용하지 않았고 최초 발급·자동 갱신 종단 간 검증 전이므로, 정적 검사 성공만 보고 CA 문제를 배포 완료로 단정하지 않습니다.

1. AWS 콘솔에서 예상한 리전과 자원 이름 확인
2. 인스턴스 실행 상태와 디스크 여유 확인
3. Docker daemon과 필수 컨테이너 상태 확인
4. Nginx와 app 로그에서 시간대와 오류 종류 확인
5. `certificate_mode` 확인. `self-signed`이면 호스트 이름·지문, `letsencrypt-ip`이면 고정 IP SAN·공인 CA chain·만료와 timer 확인
6. `letsencrypt-ip`이면 HTTP 80의 ACME challenge 도달 가능성, CA·인터넷 오류와 rate limit 종류 확인
7. `/api/v1/status/`의 `database`와 `storage` 상태 확인
8. worker wrapper 대기 상태 확인
9. 작은 시험 프로젝트의 작업 결과와 가려진 로그 확인
10. 최근 변경 버전과 마지막 정상 시점 기록

공식 README는 상태 endpoint로 `https://호스트/api/v1/status/`를 안내합니다. 이 응답이 정상이어도 메일, worker 작업과 복원 가능성은 별도 검사해야 합니다.

## 흔한 증상

| 증상 | 우선 확인 | 하지 말아야 할 일 |
|---|---|---|
| 웹 접속 실패 | DNS, 인증서, Nginx, 보안 그룹 | 임의로 모든 포트를 공개 |
| 공인 인증서 최초 발급 실패 | 선택 모드·약관 동의, 고정 IPv4, HTTP-01의 TCP 80, CA 응답·rate limit | 자체서명 인증서로 바꿔 성공 처리하거나 무제한 재시도 |
| 공인 인증서 갱신 실패 | timer·service, 마지막 확인·갱신 시각, 48시간 여유, root 전용 실패 표식 | 유효한 이전 인증서·실패 표식을 먼저 삭제 |
| 공인 인증서인데 브라우저 경고 | 접속한 IP와 IP SAN, CA chain, 현재 Nginx live 인증서 | 인증서 오류 무시 또는 신뢰 검사 비활성화 |
| 갱신 뒤 HTTPS 실패 | `current` link, Nginx 설정·reload, 이전 release 롤백 결과 | 개인키를 채팅에 붙이거나 임의 인증서 덮어쓰기 |
| DB 상태 실패 | QFieldCloud 전용 DB 상태와 허용 규칙 | 기존 식물이력 DB로 대체 |
| storage 실패 | 전용 버킷·로컬 저장소 상태와 권한 | 버킷을 public으로 전환 |
| worker 작업 실패 | wrapper와 임시 QGIS worker 로그, 메모리 | 무검증 이미지로 변경 |
| 디스크 부족 | 로그·임시 파일·백업 사용량 | 확인 없이 데이터 삭제 |

파괴적인 조치가 필요하면 먼저 대상, 영향, 백업 상태와 복구 가능성을 설명하고 승인을 받습니다.

## 공인 IPv4 인증서의 안전한 첫 확인

다음 명령은 Secret 값을 출력하지 않는 전체 상태와 systemd 상태부터 확인합니다.

```bash
sudo /opt/qfieldcloud/bin/health-check.sh
sudo systemctl status qfieldcloud-certificate-renew.timer --no-pager --lines=30
sudo systemctl status qfieldcloud-certificate-renew.service --no-pager --lines=30
```

정상이라면 `tls_certificate=public-ca-ip-san-current`, `certificate_renewal=scheduled-and-healthy`이고 만료까지 48시간보다 많이 남아야 합니다. 후보 인증서가 검증되기 전에는 `certs/current`를 바꾸지 않으며, Nginx 검사·reload·실제 HTTPS 확인이 실패하면 이전 release로 되돌리는 것이 설계된 동작입니다.

CA 장애, 인터넷 단절 또는 rate limit이면 아직 유효한 이전 인증서를 그대로 둔 채 원인을 기록합니다. 반복 수동 실행은 rate limit을 악화시킬 수 있으므로 [로그 실행서](runbooks/logs.md)의 제한된 로그만 확인하고, CA의 응답·남은 만료 시간·다음 timer 실행 시각을 검토합니다. `last-certificate-renewal-failure`를 지우거나 자체서명으로 교체해 상태를 정상처럼 만들지 않습니다.
