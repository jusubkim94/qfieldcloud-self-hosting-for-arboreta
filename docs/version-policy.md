# 버전 고정 정책

## 목적

`lab-lightsail`은 사용자가 버튼을 누른 시점마다 다른 코드가 설치되는 일을 막아야 합니다. CloudFormation 템플릿, 설치 파일, 컨테이너 이미지와 큰 다운로드 파일을 검토한 값으로 고정합니다.

> 현재 `v0.1.2` 완성 artifact가 저장소에 포함되어 있습니다. 원본 템플릿에는 릴리스 생성 과정에서 바꿀 표식이 있으므로 직접 배포할 수 없습니다. `v0.1.0`은 `create_project` worker 검증에 실패했고, `v0.1.1`은 공인 IP 인증서 발급 후 Nginx 적용 검증에 실패했습니다. 적용 재시도와 진단을 추가한 `v0.1.2`는 아직 실제 AWS 재시험 전입니다.

## 원클릭 릴리스 단위

게시 가능한 릴리스는 다음 세 파일을 한 묶음으로 가져야 합니다.

| 파일 | 역할 |
|---|---|
| `template.yaml` | 고정 릴리스 값이 삽입된 CloudFormation 템플릿 |
| `manifest.json` | 릴리스 버전, commit, 파일 크기와 SHA-256 기록 |
| `SHA256SUMS` | 세 파일의 내용 checksum |

각 묶음은 저장소의 `releases/lab-lightsail/<고정 버전>/...`에 새 파일로 커밋합니다. 이미 공개한 같은 버전 파일을 다른 내용으로 덮어쓰지 않고 새 버전을 만듭니다.

선택 기능인 Quick Create 링크를 따로 게시할 때는 다음 값을 고정해야 합니다.

- 리전: `ap-northeast-2`
- 스택 이름: `qfieldcloud-pilot`
- 인스턴스 이름: `qfieldcloud-pilot`
- 버전별 S3 HTTPS URL과 `versionId`

`main`, `master`, `latest`, 움직이는 컨테이너 태그와 만료되는 서명 URL은 배포 입력으로 허용하지 않습니다.

## QFieldCloud 기준선

검증 기준일은 **2026-08-24**이며 현재 기준선은 다음과 같습니다.

- 공식 릴리스: [QFieldCloud `v26.25`](https://github.com/opengisch/QFieldCloud/releases/tag/v26.25)
- 전체 commit: [`c32bc110f8291b2a32e318528ee46689771630d6`](https://github.com/opengisch/QFieldCloud/commit/c32bc110f8291b2a32e318528ee46689771630d6)
- 실행 플랫폼: `linux/amd64`
- 지원 worker: QGIS 3
- QGIS 4: 검증된 공식 이미지와 실제 worker 시험이 마련될 때까지 안전하게 차단

QFieldCloud app, Nginx, worker wrapper, QGIS 3 worker와 bucket 초기화 이미지는 [`config/qfieldcloud-v26.25.env`](../config/qfieldcloud-v26.25.env)의 전체 `@sha256:...` 참조를 사용합니다. 사람이 읽기 쉬운 `26.25` 태그만 배포 입력으로 사용하지 않습니다.

## 외부 구성요소 기준선

외부 컨테이너도 `linux/amd64` manifest digest로 고정합니다. 현재 핵심 값은 다음과 같습니다.

| 구성요소 | 기준 | SHA-256 manifest digest |
|---|---|---|
| PostgreSQL/PostGIS | `17-3.5-alpine` | `966243672c7d98cb996f26854a790b3b76e3cb77455d6eeb19d72ff82d20e7af` |
| RustFS | `1.0.0-beta.11` | `e4151ec4728f4d39a714a2c5f6e1f4bc8e0789fe5af4874b95121bae39c6cd12` |
| Certbot | `5.7.0` | `d07bd043d61d6bee1114235ac12c2e9a5c54b6931b3ccf5e1174d6c8c4afaa95` |

나머지 smtp4dev, Ofelia와 Memcached를 포함한 전체 실행값도 [`config/qfieldcloud-v26.25.env`](../config/qfieldcloud-v26.25.env)를 단일 기준으로 사용합니다. digest를 바꾸는 행위는 업데이트이며 자동 적용하지 않습니다.

## PROJ-data 기준선

QGIS 좌표 변환 격자는 [OSGeo PROJ-data `1.24.0`](https://github.com/OSGeo/PROJ-data/releases/tag/1.24.0)의 단일 공식 archive를 사용합니다.

| 항목 | 값 |
|---|---|
| 파일 | `proj-data-1.24.tar.gz` |
| 크기 | `792584182` bytes |
| SHA-256 | `eadf412754a2a9a727d79579873fbe7dae802038d4c2a19e452a886d4eddd111` |

설치기는 크기와 SHA-256이 모두 맞아야 압축을 풀고, 안전하지 않은 archive 경로는 거부합니다.

## 완전히 고정되지 않는 계층

Lightsail `ubuntu_24_04` blueprint는 AWS가 제공하는 이미지 ID이며 가상머신 전체의 byte checksum을 지정할 수 없습니다. 초기 부팅 때 설치되는 일부 Ubuntu 패키지도 그 시점의 저장소 상태에 따라 달라질 수 있습니다.

따라서 컨테이너와 다운로드 파일의 checksum이 고정되어도 서로 다른 날의 서버가 byte 단위로 완전히 같다고 보증하지 않습니다. 실제 blueprint 정보와 설치된 기반 패키지 버전은 검증 기록에 남겨야 합니다.

## 새 버전 승인 기준

1. 공식 릴리스 노트, 라이선스와 알려진 제한을 검토합니다.
2. 릴리스 태그, 전체 commit과 이미지 provenance를 확인합니다.
3. 모든 `linux/amd64` 이미지 digest, 파일 크기와 checksum을 기록합니다.
4. 정적 검사와 비운영 설치에서 데이터베이스 migration, HTTPS, API와 QGIS 3 worker를 확인합니다.
5. 비용 영향, 데이터 손실 위험과 실패 뒤 삭제 방법을 Pull Request에 기록합니다.
6. 새 완성 artifact와 SHA-256을 커밋하고 README 다운로드 주소를 새 버전으로 갱신합니다. 선택적인 S3 게시에는 별도 사용자 승인이 필요합니다.

이 파일럿에는 자동 스냅샷, 애플리케이션 백업 또는 데이터 보존 업데이트가 없습니다. 새 버전 적용은 데이터가 없는 스택을 삭제하고 다시 만드는 범위만 문서화되어 있으며, 실제 AWS 교체 설치는 아직 검증하지 않았습니다. 자세한 사용자 절차는 [업데이트 실행서](runbooks/update.md)와 [롤백 실행서](runbooks/rollback.md)를 따릅니다.
