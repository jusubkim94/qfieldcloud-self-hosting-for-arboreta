# 상태확인 실행서

현재 `lab-lightsail`의 정확한 명령과 필드 설명은 [파일럿 안내서](../lab-lightsail.md#6-상태와-관리자-계정-확인)를 따릅니다.

## 검사 계층

1. AWS 자원이 예상 리전에서 실행 중인지 확인
2. 운영체제 디스크·메모리·시간 동기화 확인
3. Docker daemon과 필수 컨테이너 확인
4. HTTPS 인증서의 호스트 이름과 만료 확인
5. QFieldCloud `/api/v1/status/` 확인
6. 응답의 `database`와 `storage`가 정상인지 확인
7. worker wrapper 상태 확인
8. 작은 시험 프로젝트로 임시 QGIS worker 실행 확인
9. 마지막 백업과 마지막 복원시험 시각 확인

## 판정

| 수준 | 의미 |
|---|---|
| 정상 | 설치 tuple, 필수 계층, 7일 이내 worker·최신 로컬 백업·그 백업의 격리 무결성 시험 정상 |
| 부분 장애 | 웹은 열리지만 DB, storage, worker 또는 백업 검사 실패 |
| 장애 | HTTPS 또는 핵심 API 사용 불가 |
| 미검증 | 실제 검사를 실행하지 않음 |

오류 출력에는 Secret 값을 포함하지 않습니다. 서버에서는 `sudo /opt/qfieldcloud/bin/health-check.sh`, 로컬에서는 검토한 commit과 `bootstrap.sh` SHA-256을 함께 지정해 `Test-QFieldCloudPilot.ps1 -StackName qfieldcloud-lab-pilot`을 사용합니다. 서버 상태 도구는 설치 commit의 파일 일치, 고정 이미지 객체, 실제 PROJ-data 격자, 고정 인증서 지문, 남은 복원시험 임시 자원, 모든 장기 실행 컨테이너와 worker·백업·복원시험까지 확인합니다. 외부 상태 주소만 정상인 경우 전체 성공으로 판정하지 않습니다.
