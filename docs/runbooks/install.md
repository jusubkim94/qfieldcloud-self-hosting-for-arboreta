# lab-lightsail 설치 실행서

기본 설치 방법은 GitHub에 보관된 완성 템플릿을 PC로 내려받아 AWS CloudFormation에 직접 업로드하는 방식입니다. 공개 S3 버킷, Git, PowerShell, AWS CLI와 Access Key는 필요하지 않습니다.

> 2026-08-24 `v0.1.2` 시험은 공인 인증서 적용 뒤 `create_project` worker 내부 API 단계에서 실패했습니다. 수정 경로의 생성부터 `CREATE_COMPLETE`와 삭제까지 이어지는 성공 종단 간 시험은 아직 완료하지 못했습니다. 아래 작업은 월 최대 US$24인 Lightsail 서버를 만들 수 있습니다.

## 시작 전 확인

- AWS 콘솔 오른쪽 위 리전: **서울 `ap-northeast-2`**
- 로그인 계정: MFA(다중 인증)가 설정된 관리자 계정 권장
- 루트 Access Key: 만들지 않음
- 데이터: 자동 백업과 복원 기능이 없으며 삭제 시 복구 불가
- 권한: CloudFormation 스택과 Lightsail 자원을 생성, 조회, 삭제할 수 있어야 함

기존 식물이력관리 PostgreSQL/PostGIS에는 연결하거나 변경하지 않습니다.

## 설치

1. README의 **QFieldCloud 설치 파일 다운로드** 버튼으로 `template.yaml`을 받습니다.
2. AWS 콘솔에서 **CloudFormation → Stacks → Create stack → With new resources (standard)**를 누릅니다.
3. **Choose an existing template → Upload a template file → Choose file**을 선택하고 받은 파일을 올립니다.
4. **Next**를 누르고 스택 이름에 `qfieldcloud-pilot`을 입력합니다.
5. 기본값을 유지하고 **Next**를 눌러 **Configure stack options** 화면으로 이동합니다.
6. **Stack failure options → Preserve successfully provisioned resources**를 선택합니다.
7. 마지막 화면에서 **Submit**을 누릅니다.
8. 최대 150분 동안 기다립니다. `CREATE_COMPLETE`가 되면 **Outputs → HttpsUrl**을 엽니다.

`Preserve successfully provisioned resources`는 업로드한 YAML의 속성이 아니라 CloudFormation이 스택을 생성할 때 받는 실행 옵션입니다. 따라서 YAML이나 GUI 편집기가 이 선택을 자동으로 켤 수 없습니다. AWS CLI를 사용하는 별도 자동화에서는 `create-stack --on-failure DO_NOTHING`으로 같은 동작을 요청할 수 있지만, 이 설치 실행서는 Access Key가 필요 없는 웹 콘솔 방식을 유지합니다. 자세한 규격은 [AWS CloudFormation의 실패 리소스 보존 안내](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/stack-failure-options.html)를 참고합니다.

이 옵션으로 실패한 스택을 보존하면 Lightsail과 Static IP가 자동 삭제되지 않습니다. 진단을 마친 즉시 [삭제 실행서](uninstall.md)에 따라 스택을 삭제하고 Lightsail 잔존 자원을 확인해야 비용이 멈춥니다.

AWS 화면 문구는 콘솔 언어와 개편 시점에 따라 조금 다를 수 있습니다. 예상하지 못한 IAM(권한 관리) 자원 생성 승인란이 나타나면 제출하지 말고 파일이 README의 배포 파일인지 다시 확인합니다.

## 성공 확인

CloudFormation의 **Outputs**에서 `HttpsUrl`, `InstallationStatus`, `AdministratorCredentials`, `DeleteInstructions`를 확인합니다. 자체서명 HTTPS 인증서가 기본값이므로 첫 접속 때 브라우저 경고가 나타납니다.

관리자 계정은 **Lightsail → Instances → qfieldcloud-pilot → Connect using SSH**에서 다음 명령으로 확인합니다.

```bash
sudo /opt/qfieldcloud/bin/show-admin-credentials.sh
```

비밀번호를 파일, 채팅, GitHub 이슈나 로그에 저장하지 않습니다.

## 어떤 파일을 올려야 하나요?

사용할 파일은 [`releases/lab-lightsail/v0.1.3/template.yaml`](../../releases/lab-lightsail/v0.1.3/template.yaml)입니다. [`infra/lab-lightsail/template.yaml`](../../infra/lab-lightsail/template.yaml)은 릴리스 제작용 원본 틀이므로 직접 올리지 않습니다.

CloudFormation은 업로드한 템플릿을 사용자 계정의 내부 S3 업로드 공간에 보관할 수 있습니다. 이는 AWS 콘솔의 정상 동작이며 사용자가 공개 버킷이나 공개 정책을 만들 필요는 없습니다.

문제가 생기면 [문제 해결](../troubleshooting.md)을 확인합니다. 비용을 멈추려면 [삭제 실행서](uninstall.md)를 따릅니다.
