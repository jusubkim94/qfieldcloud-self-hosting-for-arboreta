# QFieldCloud AWS 원클릭 셀프호스팅

> 이 저장소는 QField 또는 QFieldCloud 공식 프로젝트가 아닌 독립적인 비공식 배포 자동화 프로젝트입니다.

<!-- RELEASE_PUBLISHER: 아래 비활성 이미지를 검증된 quick-create-url.txt의 링크로 감싼 한 줄로만 교체합니다. -->
![Launch QFieldCloud on AWS — S3 게시 전](https://img.shields.io/badge/Launch_QFieldCloud_on_AWS-S3_%EA%B2%8C%EC%8B%9C_%EC%A0%84%20%C2%B7%20%EB%B9%84%ED%99%9C%EC%84%B1-lightgrey?style=for-the-badge)

**현재 버튼은 의도적으로 비활성입니다.** 릴리스별 CloudFormation 템플릿을 공개 S3 객체로 아직 게시하지 않았습니다. 비용이 생기는 AWS 자원이나 외부 S3 게시를 승인 없이 만들지 않는 원칙 때문입니다. [게시 절차](docs/release-publishing.md)를 완료하고 저장소 템플릿과 게시 객체의 SHA-256이 일치한 뒤에만 이 버튼을 활성화해야 합니다.

## 먼저 확인할 비용과 위험

| 항목 | 파일럿 기본값 |
|---|---|
| 예상 월 비용 | 서울 리전 Linux 4GB Lightsail 인스턴스 **월 상한 USD 24**. 시간 단위로 비례 청구되며 중지해도 삭제 전까지 과금됩니다. |
| 생성 자원 | 4GB RAM·2 vCPU·80GB SSD·4TB 전송량 인스턴스 1개, 연결된 고정 IPv4 1개, 상태 경보 1개 |
| 추가 가능 비용 | 세금·환율, 4TB 초과 송신(서울 USD 0.13/GB), 1시간 넘게 분리된 고정 IP(USD 0.005/시간), 사용자가 별도로 만든 자원 |
| 설치 시간 | CloudFormation은 설치 완료 신호를 최대 **150분** 기다립니다. 새 원클릭 경로의 실제 평균 소요시간은 아직 AWS에서 측정하지 않았습니다. |

가격은 2026-08-24에 [AWS Lightsail 공식 가격](https://aws.amazon.com/lightsail/pricing/)과 [공식 상품 표](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-bundles.html)로 다시 확인했습니다. 가격과 상품 제공 여부는 바뀔 수 있으므로 생성 직전에도 확인하세요.

> [!CAUTION]
> 이 구성은 한 서버가 멈추면 전체 서비스가 멈추는 개인용 파일럿입니다. **애플리케이션 백업, 복원 도구, 자동 snapshot이 없습니다. 서버·디스크·스택을 삭제하면 데이터를 복구할 수 없습니다.** 기존 식물이력관리용 PostGIS 데이터베이스에는 연결하거나 변경하지 않습니다.

> [!WARNING]
> AWS 루트 사용자도 기술적으로 차단하지 않지만 권장 경로는 아닙니다. 루트를 사용한다면 반드시 MFA(다중 인증)를 설정하고 루트 Access Key를 만들지 마세요. 이 템플릿은 과금되는 자원을 만듭니다. 릴리스 버전과 S3 `versionId`가 고정된 검증 템플릿만 실행하세요.

## 버튼이 활성화된 뒤 누르는 순서

기본 설치에는 Git, PowerShell, AWS CLI(명령줄 도구), 저장소 복제, 계정 ID·ARN 입력, IAM 사용자·역할 생성, Access Key가 필요 없습니다.

1. MFA가 설정된 계정으로 [AWS 웹 콘솔](https://console.aws.amazon.com/)에 로그인합니다.
2. 이 README 맨 위의 **Launch QFieldCloud on AWS** 버튼을 누릅니다.
3. CloudFormation의 **Quick create stack** 화면에서 오른쪽 위 리전이 **서울 `ap-northeast-2`**인지 확인합니다.
4. 스택 이름 `qfieldcloud-pilot`, 월 USD 24 예상 비용, 생성 자원, 무백업 경고와 검증된 기본 `self-signed` HTTPS 모드를 확인합니다.
5. 템플릿 URL이 릴리스 버전 경로와 S3 `versionId`를 모두 포함하는지 확인한 뒤 **Create stack**을 누릅니다.
6. 상태가 `CREATE_COMPLETE`가 될 때까지 기다립니다. 권한이 부족하면 CloudFormation 이벤트에 거부된 AWS 작업이 표시됩니다.
7. 스택의 **Outputs** 탭에서 `HttpsUrl`을 열어 QFieldCloud에 접속합니다.

`CREATE_COMPLETE`는 데이터베이스 migration, 정적 파일 준비, 서비스 상태 검사와 QGIS 3 worker 최소 기능 시험까지 성공했다는 뜻입니다. 비밀번호는 Outputs, UserData, 로그 또는 GitHub에 표시되지 않습니다.

현재 기본 HTTPS 인증서는 자체서명이라 브라우저가 경고합니다. 관리자 정보 확인 명령이 보여 주는 SHA-256 지문과 브라우저 인증서 세부정보를 비교한 뒤에만 예외를 허용하세요. 공인 `letsencrypt-ip` 모드는 코드에 남아 있지만 새 원클릭 경로에서 아직 종단 간 검증되지 않아 기본값이 아닙니다.

## 관리자 계정 확인

사용자 PC에 프로그램을 설치할 필요가 없습니다.

1. AWS 콘솔에서 **Lightsail → Instances → qfieldcloud-pilot**을 엽니다.
2. **Connect using SSH**를 누릅니다.
3. 브라우저 터미널에 Outputs의 다음 한 줄을 붙여넣습니다.

```bash
sudo /opt/qfieldcloud/bin/show-admin-credentials.sh
```

이 도구는 root 권한의 대화형 터미널에서만 주소·사용자 이름·비밀번호를 보여 줍니다. 출력 내용을 채팅, 파일, 이슈 또는 로그에 붙여넣지 마세요.

## 웹 콘솔에서 완전히 삭제

삭제하면 이 파일럿의 모든 데이터가 영구적으로 사라집니다.

1. AWS 콘솔 오른쪽 위에서 **서울** 리전을 확인합니다.
2. **CloudFormation → Stacks → qfieldcloud-pilot**을 선택합니다.
3. 종료 방지가 켜져 있으면 **Stack actions → Edit termination protection → Deactivate**를 선택합니다.
4. **Delete → Delete stack**을 누르고 `DELETE_COMPLETE`까지 확인합니다.
5. **Lightsail**에서 인스턴스·고정 IP·디스크·사용자가 별도로 만든 수동 snapshot이 남지 않았는지 확인합니다.
6. **Billing and Cost Management**에서 이후 비용이 중단됐는지 다시 확인합니다.

정상 삭제 시 템플릿이 만든 인스턴스, 고정 IP와 경보는 함께 삭제됩니다. `DELETE_FAILED`면 자원이 남아 과금될 수 있으므로 [상세 삭제 안내](docs/runbooks/uninstall.md)를 따르세요.

## 무엇이 자동으로 설치되는가

CloudFormation은 서울 리전의 Ubuntu 24.04 Lightsail 4GB 상품(`medium_3_0`)을 만들고 고정 IP·방화벽을 설정합니다. 서버 안에서는 Docker, digest로 고정된 QFieldCloud `v26.25` 공식 이미지, QFieldCloud 전용 PostgreSQL/PostGIS, 로컬 RustFS 객체 저장소, Nginx·HTTPS, QGIS 3 worker와 앱 cron을 구성합니다.

운영 이미지에는 `latest`, `main`, `master` 같은 변동 참조를 사용하지 않습니다. 공식 QFieldCloud 소스를 포크하거나 수정하지 않습니다. 전체 고정값은 [버전 정책](docs/version-policy.md)에서 확인할 수 있습니다.

## 현재 로그인 주체와 보안 차이

CloudFormation 서비스 역할을 따로 지정하지 않으므로 현재 로그인한 루트 사용자, `AdministratorAccess`가 있는 IAM 사용자, 충분한 권한의 IAM 역할 또는 IAM Identity Center 세션으로 시작할 수 있습니다. 별도 설치자와 1시간 역할 전환이 사라져 훨씬 단순하지만, 기존의 최소 권한 역할 경계도 함께 사라집니다. 로그인 주체가 가진 넓은 권한은 설치 후에도 그대로 유지됩니다.

권한이 부족한 IAM 사용자는 지원할 수 없습니다. 그 경우 AWS가 CloudFormation 이벤트에 필요한 `cloudformation` 또는 `lightsail` 작업의 권한 오류를 표시합니다. 이 저장소는 Access Key, Secret, 비밀번호, 토큰, MFA 코드 또는 개인키를 요청하거나 저장하지 않습니다.

## 아직 검증되지 않은 항목

- 이 변경 후 실제 AWS 스택 생성·삭제는 비용 승인 없이 실행하지 않았습니다.
- `medium_3_0`과 `ap-northeast-2a`의 현재 서울 계정 가용성은 AWS API로 조회하지 않았습니다.
- Let’s Encrypt IP 인증서의 신규 발급·시간 경과 갱신은 새 원클릭 스택에서 종단 간 시험하지 않았습니다.
- 공개 S3 템플릿과 실제 Quick Create 버튼은 아직 게시되지 않았습니다.

정적 검사는 CloudFormation 구조, Quick Create URL 형식, Bash·PowerShell·JSON 문법, 고정 이미지 digest, Secret 패턴, 삭제된 기능의 잔여 호출과 문서 링크를 확인합니다. 정적 검사가 실제 AWS 성공이나 비용을 증명하지는 않습니다.

## 기술 문서

| 문서 | 내용 |
|---|---|
| [lab-lightsail 안내](docs/lab-lightsail.md) | 원클릭 구조, 구성요소, 완료 조건과 한계 |
| [릴리스·S3 게시](docs/release-publishing.md) | artifact, checksum, 버전 고정 URL, 게시 전후 검증 |
| [설치 실행서](docs/runbooks/install.md) | AWS 웹 콘솔 클릭 순서 |
| [상태 확인](docs/runbooks/status.md) | Outputs, 상태 경보, 브라우저 SSH 확인 |
| [삭제 실행서](docs/runbooks/uninstall.md) | 잔존 과금 자원까지 확인하는 삭제 순서 |
| [보안 모델](docs/security-model.md) | 현재 로그인 주체, Secret 처리와 위험 |
| [아키텍처](docs/architecture.md) | `lab-lightsail`과 향후 `standard-aws` 구분 |
| [상표·라이선스](docs/trademarks-and-licenses.md) | 비공식 프로젝트 고지와 외부 구성요소 |

`standard-aws`는 EC2, RDS, S3 등 운영용 분리 구성을 위한 향후 범위이며 이 원클릭 파일럿과 기존 식물이력관리 DB를 섞지 않습니다.
