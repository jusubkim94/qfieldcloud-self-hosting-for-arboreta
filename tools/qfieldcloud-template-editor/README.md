# QFieldCloud Standalone Template Editor

Windows에서 AWS 자격증명이나 개발 도구 없이 `lab-lightsail` CloudFormation YAML을 수정하는 비공식 GUI 도구입니다.

## 기능

- Region, Availability Zone, 인스턴스 이름, Lightsail Bundle, OS Blueprint, HTTPS 인증서 방식, 설치 대기시간과 Alarm 기준 편집
- 모든 YAML 내용을 바꿀 수 있는 고급 원문 편집기
- 필수 CloudFormation 구조, 배포 자리표시자, Secret 패턴과 standalone 단일 node 계약 검사
- QFieldCloud standalone 구조와 전체 설치 과정을 한국어 다이어그램으로 설명
- 내장된 검증 완료 `v0.1.0` 템플릿 복원
- AWS API, Access Key 또는 네트워크 호출 없음

standalone의 서버 node 수는 1로 고정됩니다. 다중 node는 공유 RDS/PostGIS, S3, Load Balancer와 Secret 관리가 필요한 `standard-aws` 별도 아키텍처입니다.

## 로컬 빌드

Windows 10/11에 포함된 .NET Framework C# compiler를 사용하므로 NuGet package나 인터넷 다운로드가 필요하지 않습니다.

```powershell
pwsh -NoProfile -File tools/qfieldcloud-template-editor/Build-QFieldCloudTemplateEditor.ps1
```

결과는 `tools/qfieldcloud-template-editor/output/QFieldCloudTemplateEditor-v0.1.0.exe`에 생성됩니다. 빌드 스크립트는 GUI를 띄우지 않는 `--self-test`도 자동 실행합니다.

## 보안과 한계

- EXE는 코드 서명이 없으므로 Windows SmartScreen 경고가 나타날 수 있습니다.
- 안내형 편집이 아닌 원문 변경은 고정 commit, checksum 또는 firewall 제한을 훼손할 수 있습니다.
- 내장 검사는 AWS 계정별 Lightsail 가용성이나 CloudFormation server-side 검증을 대신하지 않습니다.
- 앱은 AWS 자원을 만들지 않습니다. 수정 YAML을 CloudFormation에서 제출할 때부터 비용이 발생할 수 있습니다.
- 이 파일럿에는 자동 backup, snapshot 또는 복원 기능이 없습니다.
