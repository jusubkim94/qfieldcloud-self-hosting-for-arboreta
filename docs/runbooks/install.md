# 설치 실행서 설계

## 현재 상태

Phase 1에는 설치 템플릿이나 스크립트가 없습니다. 아래는 향후 자동화가 지켜야 할 순서이며 지금 실행하는 절차가 아닙니다.

## 사전 확인

1. `lab-lightsail` 또는 `standard-aws` 선택
2. 서울 리전과 실제 서비스 가격 확인
3. 도메인과 공인 HTTPS 방식 결정
4. 백업 위치와 보존기간 결정
5. QFieldCloud 검증 릴리스·commit·이미지 digest 확인
6. 기존 식물이력관리 DB 정보가 입력항목에 없는지 확인
7. 생성될 자원, IAM 권한과 삭제 방법 검토

## 제안 흐름

```mermaid
flowchart LR
    A[비용·자원 검토] --> B[사용자 승인]
    B --> C[AWS 안에서 Secret 생성]
    C --> D[고정 이미지 준비]
    D --> E[QFieldCloud 전용 DB migration]
    E --> F[서비스 시작]
    F --> G[상태검사]
    G --> H[작은 프로젝트 worker 시험]
```

Secret은 Quick Create URL, GitHub 또는 문서 예제에 넣지 않습니다. 설치 실패 시 무조건 재실행하기 전에 어느 단계까지 완료됐는지 확인하며, 반복 실행으로 자원이 중복되지 않도록 설계합니다.

## 완료기준

- HTTPS 접속과 `/api/v1/status/`의 DB·storage 정상
- 관리자 생성 과정에서 Secret이 로그에 노출되지 않음
- 작은 시험 프로젝트의 QGIS 작업 완료
- 백업과 삭제 대상이 문서화됨

상태 endpoint만 성공한 경우 설치 전체 성공으로 선언하지 않습니다.
