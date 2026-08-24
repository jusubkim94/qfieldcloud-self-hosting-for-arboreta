# QFieldCloud Standalone Template Editor v0.1.0

`QFieldCloudTemplateEditor-v0.1.0.exe`는 `lab-lightsail` 배포 YAML을 로컬에서 수정·검증·저장하는 Windows GUI 앱입니다.

- 지원 OS: Windows 10/11과 .NET Framework 4.8
- 설치: 필요 없음
- AWS·네트워크 호출: 없음
- AWS Access Key: 입력하거나 저장하지 않음
- 코드 서명: 없음. Windows SmartScreen 경고가 나타날 수 있음
- EXE SHA-256: `2163cdbd58ab8cc14e39a263a3b8830c8d975c1a7c4c2b7eada6d8184f59d33f`

앱에서 새 YAML을 저장한 뒤 사용자가 AWS CloudFormation에 직접 업로드합니다. 앱을 실행하는 것만으로 AWS 비용은 발생하지 않습니다.

standalone의 서버 node 수는 1로 고정됩니다. 다중 node는 공유 RDS/PostGIS, S3와 Load Balancer가 필요한 별도 `standard-aws` 아키텍처입니다.
