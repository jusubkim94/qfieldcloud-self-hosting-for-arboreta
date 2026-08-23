# 상태확인 실행서

현재 `lab-lightsail`의 정확한 명령과 필드 설명은 [파일럿 안내서](../lab-lightsail.md#6-상태와-관리자-계정-확인)를 따릅니다.

2026-08-23 실제 AWS 검증 이력은 기본 `self-signed` 모드입니다. 선택 `letsencrypt-ip`은 현재 AWS 스택에 적용하지 않았고 실제 최초 발급·자동 갱신 종단 간 검증 전입니다.

## 검사 계층

1. AWS 자원이 예상 리전에서 실행 중인지 확인
2. 운영체제 디스크·메모리·시간 동기화 확인
3. Docker daemon과 필수 컨테이너 확인
4. `certificate_mode` 확인. `self-signed`는 호스트 이름·지문·만료, `letsencrypt-ip`은 공인 CA chain·고정 IPv4 SAN·48시간 초과 여유 확인
5. QFieldCloud `/api/v1/status/` 확인
6. 응답의 `database`와 `storage`가 정상인지 확인
7. worker wrapper 상태 확인
8. 작은 시험 프로젝트로 임시 QGIS worker 실행 확인
9. `letsencrypt-ip`이면 갱신 timer 활성화, 마지막 확인·갱신 시각과 실패 표식 확인
10. 마지막 백업과 마지막 복원시험 시각 확인

## 판정

| 수준 | 의미 |
|---|---|
| 정상 | 설치 tuple, 필수 계층, 7일 이내 worker·최신 로컬 백업·그 백업의 격리 무결성 시험 정상 |
| 부분 장애 | 웹은 열리지만 DB, storage, worker 또는 백업 검사 실패 |
| 장애 | HTTPS 또는 핵심 API 사용 불가 |
| 미검증 | 실제 검사를 실행하지 않음 |

인증서 모드별 정상값은 다음과 같습니다.

| 모드 | `tls_certificate` | `certificate_renewal` |
|---|---|---|
| `self-signed` | `current-hostname-and-fingerprint-matched` | `not-applicable-self-signed` |
| `letsencrypt-ip` | `public-ca-ip-san-current` | `scheduled-and-healthy` |

공인 모드에서는 `certificate_not_after`, `certificate_last_check_at`, `certificate_last_renewal_at`도 확인합니다. 상태 도구는 현재 디스크 인증서, Certbot lineage와 Nginx가 실제 제공하는 인증서가 같고, 개인키가 일치하며 systemd timer가 enabled·active인지 검사합니다. root 전용 `last-certificate-renewal-failure`가 있거나 만료 여유가 48시간 이하이면 정상으로 판정하지 않습니다.

오류 출력에는 Secret 값을 포함하지 않습니다. 서버에서는 `sudo /opt/qfieldcloud/bin/health-check.sh`, 로컬에서는 검토한 commit과 `bootstrap.sh` SHA-256을 함께 지정해 `Test-QFieldCloudPilot.ps1 -StackName qfieldcloud-lab-pilot`을 사용합니다. 서버 상태 도구는 설치 commit의 파일 일치, 고정 이미지 객체, 실제 PROJ-data 격자, 모드별 인증서 신뢰와 갱신 상태, 남은 복원시험 임시 자원, 모든 장기 실행 컨테이너와 worker·백업·복원시험까지 확인합니다. 외부 상태 주소만 정상인 경우 전체 성공으로 판정하지 않습니다.
