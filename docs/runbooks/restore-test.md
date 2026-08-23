# 복원시험 실행서

현재 `lab-lightsail` 구현의 범위와 명령은 [파일럿 안내서](../lab-lightsail.md#최신-백업-격리-복원시험)를 따릅니다. 구현된 시험은 최신 로컬 백업의 **schema·storage 무결성 시험**이며 별도 호스트의 앱·worker 종단 간 재해 복구 연습은 아닙니다.

## 절대 원칙

운영 QFieldCloud DB나 기존 식물이력관리 DB 위에 복원시험을 수행하지 않습니다. 4GB 실험 서버에서는 QFieldCloud 전용 PostgreSQL 컨테이너 안에 이름이 `qfc_restore_test_`로 제한된 별도 임시 DB를 만들고, 시험이 끝나면 그 DB만 삭제합니다. 객체 저장소와 media는 별도 임시 Docker 볼륨을 사용합니다. 비용이 생기는 자원은 사전 설명과 승인 후에만 만듭니다.

## 순서

1. 복원할 백업, 시각과 QFieldCloud 버전 선택
2. checksum과 암호화 키 접근 가능 여부 확인
3. 격리된 시험 대상과 삭제 계획 검토
4. DB 복원 후 schema와 migration 상태 확인
5. 객체 복원 후 누락·크기 검사
6. 고정된 앱 이미지로 migration 호환성 확인
7. RustFS bucket·version과 media archive 읽기 확인
8. 이름이 제한된 시험 DB와 이 시험이 만든 label의 임시 자원만 정리
9. 운영 서비스 자동 복귀와 상태 확인
10. 별도 승인을 받은 외부 호스트 재해 복구 시험에서는 앱 endpoint·프로젝트·worker도 추가 검증

## 완료기준

현재 로컬 무결성 시험은 checksum, DB/PostGIS, migration, RustFS versioned storage, media 비교, 임시 시험 DB·label 기반 임시 자원 삭제 재확인과 운영 서비스 복귀가 모두 정상이어야 합니다. 프로젝트 조회와 worker까지 포함한 완전 복구 판정은 별도 호스트 시험을 추가로 통과해야 합니다. 실패한 시험은 성공 표식을 무효화하고 root 전용 `/opt/qfieldcloud/state/last-restore-test-failure`에 실패 단계·제한된 원인·정리 결과·다음 조치를 기록합니다.
