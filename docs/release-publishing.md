# 선택 기능: Quick Create용 S3 게시

이 문서는 **릴리스 관리자용 선택적 고급 절차**입니다. 일반 사용자는 README에서 완성 `template.yaml`을 내려받아 CloudFormation에 직접 업로드하므로 S3가 필요하지 않습니다. 여러 사용자에게 Quick Create 한 번 클릭 링크를 제공하려는 관리자만 이 절차를 사용합니다.

현재 공개 S3 URL은 없지만 README의 수동 다운로드 버튼은 사용할 수 있습니다. 이 절차에서 `-Execute`를 사용하면 외부 S3 상태와 소액의 저장·요청 비용이 생길 수 있으므로 대상 버킷, 공개 범위와 삭제 방법을 검토하고 명시적 승인을 받은 뒤에만 실행합니다.

## 왜 릴리스별 S3 객체가 필요한가

AWS CloudFormation Quick Create는 `templateURL`에 S3 객체 URL을 요구합니다. GitHub의 `main`, `latest` 또는 일반 웹 URL을 고정 템플릿처럼 사용할 수 없습니다.

이 저장소는 다음 세 겹으로 변경을 막습니다.

1. 릴리스별 경로: `qfieldcloud/lab-lightsail/releases/<릴리스>/template.yaml`
2. 템플릿 안의 40자리 Git commit과 `bootstrap.sh` SHA-256 고정
3. README URL의 S3 `versionId` 고정

Quick Create 화면의 파라미터는 사용자가 바꿀 수 있으므로 QFieldCloud 릴리스와 bootstrap 출처를 파라미터로 노출하지 않습니다. 릴리스 builder가 저장소 템플릿의 명시적 placeholder를 고정값으로 교체합니다.

## 생성되는 로컬 artifact

검토와 정적 검사가 끝난 **커밋된 기능 브랜치**에서 40자리 commit을 확인합니다. 작업 트리의 미커밋 파일은 artifact에 포함되지 않습니다.

```powershell
pwsh -NoProfile -File .\scripts\release\New-LabLightsailReleaseArtifacts.ps1 `
  -ReleaseVersion v0.1.0 `
  -Revision 0123456789abcdef0123456789abcdef01234567
```

기본 출력 위치는 `artifacts/lab-lightsail/v0.1.0/`이며 `.gitignore`에 포함됩니다.

| 파일 | 의미 |
|---|---|
| `template.yaml` | commit·bootstrap checksum·릴리스 버전이 삽입된 실제 배포 템플릿 |
| `manifest.json` | 원본 commit, 파일 크기, template과 bootstrap SHA-256 |
| `SHA256SUMS` | template과 manifest의 재계산용 checksum |

builder는 다음 조건이 하나라도 다르면 중단합니다.

- 원본 템플릿의 placeholder 개수가 예상과 다름
- 선택한 commit에 템플릿이나 bootstrap이 없음
- 렌더링 뒤 placeholder가 남음
- bootstrap URL이 정확한 commit을 가리키지 않음
- 같은 릴리스 디렉터리에 다른 내용 또는 추가 파일이 있음

같은 입력으로 다시 실행하면 세 파일의 byte와 SHA-256이 같아야 합니다.

## S3 게시 전 준비와 비용

게시 스크립트는 버킷을 만들거나 Versioning(객체 버전 관리), Block Public Access 또는 bucket policy를 변경하지 않습니다. 다음 조건을 갖춘 **기존 전용 버킷**이 필요합니다.

- 리전: `ap-northeast-2`
- Versioning: `Enabled`
- 게시자에게 해당 릴리스 prefix의 조회·신규 객체 업로드·버전 조회 권한
- 공개 사용자에게 게시된 CloudFormation 템플릿 version의 익명 `s3:GetObjectVersion` 읽기 허용
- 릴리스 key 덮어쓰기 금지

공개 템플릿에는 비밀번호나 AWS 자격증명이 없지만, 공개 버킷 범위를 잘못 설정하면 다른 객체까지 노출할 수 있습니다. 기존 업무 버킷을 함께 쓰지 말고 전용 버킷과 릴리스 prefix로 범위를 좁히세요. S3 저장·요청 비용과 유지 책임이 생깁니다.

버킷 생성, Versioning 변경 또는 공개 정책 적용이 필요하면 먼저 다음을 사용자에게 설명하고 승인을 받습니다.

- 정확한 AWS 계정·리전·버킷 이름
- 공개되는 객체 prefix
- 월 예상 저장·요청 비용
- Block Public Access 변경 영향
- README 버튼 비활성화, public read 제거와 객체 version 삭제 순서

## 계획 모드

다음 명령은 artifact만 검사합니다. AWS CLI를 찾거나 AWS API를 호출하지 않고 S3도 변경하지 않습니다.

```powershell
pwsh -NoProfile -File .\scripts\release\Publish-LabLightsailRelease.ps1 `
  -ArtifactDirectory .\artifacts\lab-lightsail\v0.1.0 `
  -BucketName example-dedicated-release-bucket
```

출력에서 다음을 확인합니다.

- `Action = plan-only`
- `AwsWriteRequested = false`
- 서울 리전과 정확한 릴리스 key
- `BucketCreation = never`
- Versioning과 익명 template 읽기 요구사항
- 실제 게시 전에 고정 GitHub commit의 bootstrap 원본을 다시 확인한다는 안내

## 승인 후 실제 게시

다음 명령은 외부 상태를 변경합니다. 승인 전에 실행하지 않습니다.

```powershell
pwsh -NoProfile -File .\scripts\release\Publish-LabLightsailRelease.ps1 `
  -ArtifactDirectory .\artifacts\lab-lightsail\v0.1.0 `
  -BucketName example-dedicated-release-bucket `
  -Region ap-northeast-2 `
  -Execute
```

먼저 선택한 commit을 공개 GitHub 원격 저장소에 push해야 합니다. 게시 도구는 `-Execute`를 받으면 S3를 쓰기 전에 고정 `raw.githubusercontent.com` URL을 HTTPS로 내려받고, 길이와 SHA-256이 `manifest.json`과 정확히 같은지 확인합니다. commit이 아직 push되지 않아 404가 나오거나 byte가 다르면 게시를 중단합니다.

그 다음 게시 도구는 버킷 리전과 Versioning을 확인하고, 기존 key나 과거 삭제 표식이 있으면 새 릴리스 이름을 요구합니다. 신규 객체를 조건부 업로드한 뒤 다음을 다시 확인합니다.

- 로컬 SHA-256과 S3 `ChecksumSHA256`
- 크기, 릴리스·원본 commit metadata
- 반환된 S3 `VersionId`
- 정확한 template version의 익명 읽기 가능 여부

`versionId`가 들어간 S3 객체를 읽을 때 필요한 작업은 `s3:GetObjectVersion`입니다. 현재 객체 URL도 별도로 공개하려는 경우에만 `s3:GetObject`를 추가하고, 어느 경우든 정책의 `Resource`는 릴리스 template prefix로 제한합니다. 권한 의미는 [Amazon S3 GetObject API 문서](https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html)에서 확인할 수 있습니다.

검증이 모두 통과한 경우에만 다음 두 값을 출력합니다.

```text
QFC_TEMPLATE_URL=https://.../template.yaml?versionId=...
QFC_QUICK_CREATE_URL=https://ap-northeast-2.console.aws.amazon.com/cloudformation/...
```

Quick Create URL은 서울 리전, 스택·인스턴스 이름 `qfieldcloud-pilot`, 검증된 `ap-northeast-2a`, 4GB 상품과 자체서명 HTTPS 기본값을 사용합니다. AWS 공식 형식은 [CloudFormation Quick Create 링크](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cfn-console-create-stacks-quick-create-links.html)에서 확인할 수 있습니다.

## README 버튼 활성화

1. 새 브라우저의 로그아웃 상태에서도 `QFC_TEMPLATE_URL`을 읽을 수 있는지 확인합니다.
2. URL에 릴리스 경로와 `versionId`가 모두 있는지 확인합니다.
3. 내려받은 template의 SHA-256을 `manifest.json`과 다시 비교합니다.
4. `QFC_QUICK_CREATE_URL`을 열어 리전, 스택 이름, 파라미터와 경고를 검토하되 **실제 Create stack은 비용 승인 없이는 누르지 않습니다.**
5. README의 `RELEASE_PUBLISHER` 주석 바로 아래 비활성 이미지 한 줄만 다음 형태의 링크로 교체합니다.

```markdown
[![Launch QFieldCloud on AWS](https://img.shields.io/badge/Launch_QFieldCloud_on_AWS-orange?style=for-the-badge)](검증된_QFC_QUICK_CREATE_URL)
```

검증 결과에는 릴리스 버전, source commit, template SHA-256, S3 VersionId와 확인 시각을 기록합니다. 실제 AWS 스택을 만들지 않았다면 게시 성공과 설치 성공을 구분해서 적습니다.

## 게시 중단과 제거

문제가 발견되면 가장 먼저 README 버튼을 다시 비활성화합니다. 그 다음 전용 S3 버킷의 해당 template version에 대한 익명 읽기를 제거하면 신규 Quick Create가 중단됩니다.

S3 객체 version 삭제는 복구가 어려운 파괴 작업이며 기존 URL도 깨뜨립니다. 정확한 버킷·key·VersionId, 영향과 복구 가능성을 설명하고 별도 승인을 받은 뒤 AWS 콘솔에서 삭제합니다. 게시 도구는 버킷, 정책 또는 객체를 자동 삭제하지 않습니다.

이미 정상 설치가 끝난 Lightsail 서버는 bootstrap 시점 이후 게시 S3 template을 실행 의존성으로 사용하지 않습니다. 다만 스택 이력 검토와 재현을 위해 사용한 template version과 manifest를 보존하는 편이 좋습니다.
