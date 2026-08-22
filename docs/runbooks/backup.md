# 백업 실행서

현재 `lab-lightsail` 명령과 중단 시간·용량·복귀 절차는 [파일럿 안내서](../lab-lightsail.md#7-로컬-백업과-격리-복원시험)를 따릅니다.

## 백업 대상

- QFieldCloud 전용 PostgreSQL/PostGIS DB
- 프로젝트와 첨부파일 객체
- 검증 버전, 비민감 설정과 복구 문서
- 암호화 키와 Secret은 데이터 백업과 분리해 보호

기존 식물이력관리 DB는 이 실행서의 대상이 아닙니다.

## 프로필별 권고

### `lab-lightsail`

현재 스크립트는 일관성을 위해 서비스를 잠시 중단하고 DB·객체·media·분리된 Secret 사본을 같은 서버의 root 전용 로컬 폴더에 저장합니다. 이 사본은 자동으로 암호화하거나 서버 밖으로 복사하지 않으므로 학습용 검증에만 사용합니다. 실제 데이터 전에는 승인된 클라이언트측 암호화, 별도 실패영역 보관과 그 외부 사본 기반 복원시험이 필요합니다. Lightsail snapshot은 보조 수단이며 애플리케이션 수준의 일관된 백업을 대신하지 않습니다.

### `standard-aws`

RDS 자동 백업과 수동 snapshot, S3 Versioning을 사용합니다. 같은 계정의 버전 보존만으로 충분한지는 위험도에 따라 별도 계정 또는 별도 백업 저장소를 검토합니다.

## 성공기준

백업 작업 종료 코드, 파일 크기, checksum, 보관 위치, 생성 시각과 대상 버전을 기록합니다. 백업 파일이 존재하는 것만으로 복구 가능하다고 선언하지 않으며 [복원시험](restore-test.md)을 통과해야 합니다.

실패하면 root 전용 `/opt/qfieldcloud/state/last-backup-failure`의 `artifact_state`와 `artifact_path`를 먼저 확인합니다. 일반 값은 `partial`, `finalized-not-published`, `not-created`이며, `unexpected-`로 시작하면 예상 경로가 일반 폴더가 아니라는 뜻입니다. 스크립트는 실패 산출물을 자동 삭제하지 않으므로 내용을 검토하고 별도 승인을 받기 전에는 해당 경로를 지우지 않습니다.
