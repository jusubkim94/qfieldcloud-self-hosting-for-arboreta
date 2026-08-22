# 보안 모델

## 보호 대상

사용자 계정, 프로젝트 파일, QFieldCloud 시스템 DB, 암호화 키, DB 비밀번호, 객체 저장소 권한과 작업용 임시 토큰을 보호합니다. 기존 식물이력관리 DB는 이 배포기가 접근하지 않는 별도 보안 경계입니다.

## 확인된 사실

- 공식 worker wrapper는 임시 QGIS worker를 만들기 위해 Docker API를 사용합니다.
- 공식 Compose는 호스트의 Docker socket을 worker wrapper에 마운트합니다.
- 현재 파일럿의 Ofelia 작업 스케줄러도 Docker label을 읽고 `runcrons`를 실행하기 위해 같은 socket을 사용합니다. `:ro` 마운트는 Docker API를 읽기 전용으로 제한하지 않습니다.
- Docker socket 제어는 호스트 파일 마운트와 관리자 수준 컨테이너 생성으로 이어질 수 있어 매우 민감합니다.
- QFieldCloud 상태 endpoint는 DB와 객체 저장소 연결 상태를 확인하지만 전체 보안이나 백업 성공을 증명하지 않습니다.

## 프로젝트 권고

### 인증정보

- GitHub, 템플릿 URL, 예제 파일과 로그에 Secret을 넣지 않습니다.
- `lab-lightsail` worker 시험은 관리자 비밀번호나 일반 로그인 세션을 사용하지 않고, 서버 내부에서 만든 1시간짜리 시험 전용 토큰만 사용한 뒤 그 토큰 하나를 폐기합니다.
- 서버 전원 차단이나 `SIGKILL`로 정리 절차가 실행되지 못하면 root 전용 시험 임시 파일이 남을 수 있습니다. 토큰은 1시간 후 만료되고 다음 시험이 같은 용도의 기존 DB 토큰을 폐기하지만, 남은 파일은 운영자가 점검해야 합니다.
- `standard-aws`는 IAM 역할과 Secrets Manager를 사용합니다.
- Secret 값은 출력하지 않고 존재 여부와 마지막 교체 시각만 진단합니다.
- 노출된 값은 삭제만 하지 않고 즉시 폐기·교체합니다.

### Docker 호스트

- Docker API를 인터넷 TCP 포트로 공개하지 않습니다.
- worker wrapper와 QGIS worker 이미지를 digest로 고정합니다.
- 예상하지 않은 컨테이너 생성과 권한 상승을 로그로 감시합니다.
- 장기적으로 worker 전용 EC2 분리를 검토합니다.

### 네트워크와 HTTPS

- DB와 객체 저장소 관리 포트를 인터넷에 공개하지 않습니다.
- RDS public access를 끄고 보안 그룹을 앱 호스트로 제한합니다.
- S3 public access block과 기본 암호화를 사용합니다.
- 일반 사용자는 공인 인증서가 적용된 HTTPS로만 로그인합니다.
- 자체 서명 인증서는 폐쇄 시험에서 신뢰 CA 배포 절차가 있을 때만 사용합니다.

### 데이터 최소화

원본 드론 정사영상은 기본 저장 대상에서 제외합니다. 로그에는 전체 환경변수, 인증 헤더, 프로젝트 Secret과 DB 접속 문자열을 기록하지 않습니다.

### AWS 배포 권한

- `lab-lightsail`의 자원 생성·태그·방화벽·고정 IP·경보·삭제 권한은 CloudFormation의 전달 요청(`aws:CalledVia`)에서만 허용합니다. 사용자가 Lightsail 쓰기 API를 직접 호출하는 경로로 다른 자원에 파일럿 태그를 붙이거나 삭제할 수 없어야 합니다.
- 직접 운영 권한은 네 개의 파일럿 태그가 이미 있는 인스턴스의 시작·중지·재시작·브라우저 SSH로 제한합니다.
- CloudFormation 스택 삭제와 termination protection(삭제 방지) 해제는 평상시 정책에서 빼고, 승인된 삭제 시간에만 별도 cleanup 정책을 연결합니다.
- IAM은 로컬 `TemplateBody`의 checksum이나 템플릿 안 Lightsail bundle·자원 개수를 검사하지 못합니다. 고정 스택 이름이 아직 없을 때 배포 권한이 탈취되면 다른 템플릿으로 비용 제한을 우회할 잔여 위험이 있으므로, 검토·Push된 commit의 배포 스크립트만 사용하고 이 전용 사용자에 다른 AWS 권한을 추가하지 않습니다.

## 위협과 완화

| 위협 | 완화책 |
|---|---|
| Git에 인증정보 커밋 | Secret 검사, 예제에는 값 대신 설명만 사용 |
| Docker socket 악용 | 전용 호스트, 외부 노출 금지, 고정 이미지, 모니터링 |
| 공급망 변경 | 릴리스·커밋·플랫폼 digest 동시 고정 |
| 삭제 또는 덮어쓰기 | S3 Versioning, DB 백업, 격리 복원시험 |
| 기존 업무 DB 오작동 | 자격증명·네트워크·운영 절차 완전 분리 |
| 과도한 AWS 권한 | 서울·고정 스택·자원 형식·태그·CloudFormation 경유 조건, 삭제 권한 분리, 잔여 TemplateBody 위험 명시 |
