# 버전 고정 정책

## 한눈에 보는 결론

`lab-lightsail` 파일럿의 검증 기준일은 **2026-08-24**입니다. 현재 기준선은 다음과 같습니다.

- QFieldCloud 공식 릴리스 `v26.25`
- 릴리스가 가리키는 전체 commit `c32bc110f8291b2a32e318528ee46689771630d6`
- 실행 플랫폼 `linux/amd64`
- QGIS 3 작업만 지원하며 QGIS 4 작업은 안전하게 실패하도록 차단
- 컨테이너와 PROJ-data는 내용 기반 digest 또는 checksum(다운로드가 바뀌거나 손상되지 않았는지 확인하는 값)으로 고정
- 선택 `letsencrypt-ip` 모드의 Certbot은 `5.7.0`과 `linux/amd64` manifest digest로 고정
- 새 버전은 자동 적용하지 않고 검증 Pull Request(변경 검토 요청)와 사용자 승인을 거쳐 적용

태그는 사람이 읽기 쉬운 이름이고 digest는 실제 내용을 가리키는 고정값입니다. 따라서 문서에는 둘을 함께 기록하되, 배포에는 digest를 사용합니다.

## QFieldCloud 기준선

검토한 공식 자료는 [QFieldCloud `v26.25` 릴리스](https://github.com/opengisch/QFieldCloud/releases/tag/v26.25), [정확한 commit](https://github.com/opengisch/QFieldCloud/commit/c32bc110f8291b2a32e318528ee46689771630d6), [공식 릴리스 이미지 빌드](https://github.com/opengisch/QFieldCloud/actions/runs/32261851081)입니다. GitHub에서 이 릴리스는 draft(초안)나 prerelease(시험 릴리스)로 표시되지 않았습니다. 다만 태그와 commit에는 별도의 암호학적 서명이 없으므로, 공식 저장소·릴리스 이벤트·이미지 provenance(어떤 저장소와 commit에서 만들었는지 보여주는 출처 기록)와 digest를 함께 확인했습니다.

아래 값은 Docker Hub와 GitHub Container Registry에서 동일하게 확인한 `linux/amd64` 이미지 manifest digest, 즉 실제 이미지 내용의 SHA-256 고정값입니다. 다중 플랫폼 태그 전체를 가리키는 index digest가 아니라, 파일럿 서버가 실제로 실행할 플랫폼 manifest를 고정합니다.

| 구성요소 | 참고 태그 | 배포에 사용하는 불변 이미지 참조 |
| --- | --- | --- |
| QFieldCloud app | `26.25` | `docker.io/opengisch/qfieldcloud-app@sha256:b16a02d1a9ab22180335445bd534b7a3b264f4742618b10d1a892f94f7ac88ee` |
| QFieldCloud Nginx | `26.25` | `docker.io/opengisch/qfieldcloud-nginx@sha256:78131eea09a02d8ceaa4387ddf705795ff7bb4793d3e65150a27b7d3844e2bd8` |
| worker wrapper | `26.25` | `docker.io/opengisch/qfieldcloud-worker-wrapper@sha256:7a91e8294e02d908bf8abc0671bfd9af9e3410a99169b95e81a725e81896ec18` |
| QGIS 3 worker | `26.25` | `docker.io/opengisch/qfieldcloud-qgis3@sha256:ef04373b1a4e7e3da52754a8980aab1e96c3ebf37cbc474523bb9aa86b17d363` |
| object-storage bucket 초기화 | `26.25` | `docker.io/opengisch/qfieldcloud-createbuckets@sha256:62a91be5edb90fe7dcc108ded4c5a672863c2c7af1eeb1271f4e982ecf4464fb` |

`latest`, `master`, `main`, 태그 `26.25`만 적은 참조는 배포 입력으로 허용하지 않습니다. 현재 값의 원본 확인에는 예를 들어 [app `26.25` 태그 레코드](https://hub.docker.com/v2/repositories/opengisch/qfieldcloud-app/tags/26.25)를 사용할 수 있지만, 설치 파일에는 위 digest를 기록합니다.

## QGIS 3 전용과 QGIS 4 차단

공식 `v26.25` 소스는 [QGIS 3 `1:3.44.13+40noble`과 QGIS 4 `1:4.2.1+44resolute`](https://github.com/opengisch/QFieldCloud/blob/c32bc110f8291b2a32e318528ee46689771630d6/docker-compose.yml#L151-L177)를 각각 만들도록 정의합니다. 그러나 공식 `qfieldcloud-qgis4:26.25` 이미지는 실제로 QGIS 3 기본값으로 잘못 만들어졌습니다.

[QGIS 4 공식 빌드 로그](https://github.com/opengisch/QFieldCloud/actions/runs/32261851081/job/96096728251)에서 다음을 확인했습니다.

1. Compose 설정 해석이 `QFIELDCLOUD_WORKER_REPLICAS` 누락으로 실패했습니다.
2. 셸 파이프라인이 그 오류를 놓쳐 build arguments가 비었습니다.
3. 빌드는 성공으로 표시됐지만 실제 값은 `noble`, `ubuntu-ltr`, QGIS `1:3.44.13+40noble`이었습니다.

따라서 파일럿은 검증된 QGIS 3 이미지만 사용합니다. QGIS 4 이미지 자리에는 가져올 수 없는 주소를 넣고, QGIS 4 프로젝트가 들어오면 QGIS 3으로 조용히 대신 처리하지 않고 오류로 중단합니다. 이것이 **fail-closed**, 즉 검증되지 않은 경우 안전하게 실패하는 방식입니다.

QGIS 4 지원은 공식 이미지가 실제 QGIS 4 버전을 보고하고, 작은 QGIS 4 프로젝트의 package·sync worker 시험까지 통과한 뒤 별도 Pull Request에서만 활성화합니다.

## 외부 컨테이너

QFieldCloud 이외의 컨테이너도 태그가 아니라 `linux/amd64` manifest digest로 고정합니다. 숫자가 들어간 태그도 나중에 다른 이미지를 가리킬 수 있고, `v3`이나 `1`처럼 범위가 넓은 태그는 특히 변동 가능성이 큽니다.

| 구성요소 | 출처 확인용 태그 | 배포에 사용하는 `linux/amd64` digest |
| --- | --- | --- |
| PostgreSQL/PostGIS | [`postgis/postgis:17-3.5-alpine`](https://hub.docker.com/v2/repositories/postgis/postgis/tags/17-3.5-alpine) | `sha256:966243672c7d98cb996f26854a790b3b76e3cb77455d6eeb19d72ff82d20e7af` |
| RustFS | [`rustfs/rustfs:1.0.0-beta.11`](https://hub.docker.com/v2/repositories/rustfs/rustfs/tags/1.0.0-beta.11) | `sha256:e4151ec4728f4d39a714a2c5f6e1f4bc8e0789fe5af4874b95121bae39c6cd12` |
| smtp4dev | [`rnwood/smtp4dev:v3`](https://hub.docker.com/v2/repositories/rnwood/smtp4dev/tags/v3) | `sha256:a9fc3930b16f26cf8fb3f4e20b2924e96b619c141ed895e02581bcf4f631b8c3` |
| Ofelia | [`mcuadros/ofelia:0.3.18`](https://hub.docker.com/v2/repositories/mcuadros/ofelia/tags/0.3.18) | `sha256:544718912e78a435ec0cd4c732d4f187ee60f0c45bd0d5dee6117c42aa463b62` |
| Memcached | [`memcached:1`](https://hub.docker.com/v2/repositories/library/memcached/tags/1) | `sha256:ccb35654049b320579c935b2b1e9f85ee5a44a39f7610f882f94d7f601a6a50b` |
| Certbot | [`5.7.0` 공식 릴리스](https://github.com/certbot/certbot/releases/tag/v5.7.0) | `sha256:d07bd043d61d6bee1114235ac12c2e9a5c54b6931b3ccf5e1174d6c8c4afaa95` |

digest를 바꾸는 것은 업데이트입니다. 레지스트리에서 새 태그를 발견했다는 이유만으로 실행 중인 서버나 설치 manifest를 자동 변경하지 않습니다. RustFS가 beta이고 smtp4dev가 시험용 메일 도구라는 제품 성격도 버전 검토와 별도로 운영 적합성 검토 대상입니다. Certbot 컨테이너는 `letsencrypt-ip` 모드에서 발급·갱신할 때만 실행하며 설치기는 실제 출력이 정확히 `certbot 5.7.0`인지도 확인합니다.

### Let’s Encrypt IP 인증서 기준선

선택 모드는 production ACME directory `https://acme-v02.api.letsencrypt.org/directory`, certificate profile `shortlived`, HTTP-01 challenge와 고정 IPv4를 사용합니다. [Let’s Encrypt 공식 발표](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability.html)에 따르면 IP 주소 인증서는 short-lived profile이어야 하고 유효기간은 **160시간**입니다. [Certbot 공식 사용 안내](https://letsencrypt.org/2026/03/11/shorter-certs-certbot/)에 따라 IP 주소와 webroot를 지원하는 Certbot을 사용합니다.

이 선택은 인증서 파일을 버전처럼 영구 고정한다는 뜻이 아닙니다. 공인 인증서는 6시간마다, 최대 45분 무작위 지연 뒤 갱신을 확인하며 새 인증서마다 serial과 SHA-256 지문이 바뀔 수 있습니다. 설치된 자동화가 고정하는 것은 Certbot 이미지, ACME endpoint, profile, 안전 검증과 전환 절차입니다. 실제 인증서의 신뢰 여부는 운영체제 CA chain, 현재 IPv4 SAN, 인증서·개인키 일치와 48시간 초과 유효 여유로 다시 판단합니다.

Let’s Encrypt의 CA 운영, 이용약관, 발급 정책, rate limit과 인터넷 가용성은 이 저장소가 digest로 고정하거나 통제할 수 없는 외부 계층입니다. 약관은 [Let’s Encrypt 정책 저장소](https://letsencrypt.org/repository/)에서 설치 직전에 다시 확인해야 합니다. 현재 코드는 정적 계약 검사만 거쳤고 AWS 실제 최초 발급·시간 경과 갱신 종단 간 검증 전이므로, 이 기준선을 검증 완료 인증서 서비스라고 표현하지 않습니다.

## PROJ-data 변환 격자

QGIS worker가 좌표 변환에 사용하는 격자는 [OSGeo PROJ-data `1.24.0` 공식 릴리스](https://github.com/OSGeo/PROJ-data/releases/tag/1.24.0)의 단일 릴리스 자산으로 설치합니다. CDN의 파일을 하나씩 최신 상태로 mirror하지 않습니다.

| 항목 | 고정값 |
| --- | --- |
| 릴리스 태그 | `1.24.0` |
| 태그 commit | [`59fb3aecc47da1d3410f417bf61256a8aa915323`](https://github.com/OSGeo/PROJ-data/commit/59fb3aecc47da1d3410f417bf61256a8aa915323) |
| 공식 archive | [`proj-data-1.24.tar.gz`](https://github.com/OSGeo/PROJ-data/releases/download/1.24.0/proj-data-1.24.tar.gz) |
| 크기 | `792584182` bytes |
| SHA-256 | `eadf412754a2a9a727d79579873fbe7dae802038d4c2a19e452a886d4eddd111` |
| 공식 checksum 파일 | [`proj-data-1.24.tar.gz.sha256sum`](https://github.com/OSGeo/PROJ-data/releases/download/1.24.0/proj-data-1.24.tar.gz.sha256sum) |

설치기는 다운로드 후 크기와 SHA-256이 모두 일치해야만 압축을 풉니다. 또한 안전하지 않은 archive 경로를 거부하고, 격자 파일과 함께 `README.DATA` 및 `copyright_and_licenses.csv`가 있는지 확인합니다. 파일별 라이선스 처리는 [라이선스와 상표 문서](trademarks-and-licenses.md)를 따릅니다.

## 완전히 고정되지 않는 기반 계층

컨테이너와 PROJ-data를 고정해도 Lightsail 가상머신 전체가 byte 단위로 재현되는 것은 아닙니다.

- CloudFormation에는 `BlueprintId=ubuntu_24_04`를 지정합니다. [CloudFormation의 Lightsail Instance 규격](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-lightsail-instance.html)은 blueprint ID를 받지만 이미지 checksum을 받지 않습니다.
- AWS의 [Lightsail blueprint 조회 규격](https://docs.aws.amazon.com/cli/latest/reference/lightsail/get-blueprints.html)은 ID와 별도로 version, version code, 활성 여부를 반환하며 운영체제 업데이트로 오래된 blueprint가 비활성화될 수 있다고 설명합니다. 따라서 같은 ID로 나중에 만든 서버의 기반 이미지가 과거 설치와 완전히 같다고 보증하지 않습니다.
- Docker Engine, CLI, containerd, Buildx와 Compose 패키지는 정확한 버전을 지정하고 설치 후 hold합니다.
- Docker 공식 Ubuntu 서명키도 2026-08-23에 받은 3,817 byte 전체의 SHA-256 `1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570`과 primary fingerprint `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`이 모두 맞아야 사용합니다. 공식 키가 정당하게 교체돼도 자동 수용하지 않고 manifest 검토가 필요합니다.
- 반면 초기 부팅에 필요한 Ubuntu의 `ca-certificates`, `curl`, `git`, `gnupg`, `jq`, `openssl`과 그 의존성은 버전을 지정하지 않습니다. [Ubuntu `apt-get` 설명](https://manpages.ubuntu.com/manpages/noble/man8/apt-get.8.html)은 `update`가 최신 package index를 받고, 버전을 생략한 `install`이 사용 가능한 최신 버전을 선택한다고 설명합니다.

이 선택은 필요한 패키지의 설치 시점 보안 수정본을 받을 수 있게 하지만, 서로 다른 날의 새 설치 결과가 완전히 같지는 않을 수 있다는 뜻입니다. 전체 Ubuntu 보안 업데이트, 재부팅과 사후 worker 검증은 아직 자동화하지 않았으므로 호스트 전체가 최신 보안 상태라고 표현하지 않습니다. 단일 서버 중단을 고려한 patch window와 snapshot·복구 계획을 별도로 승인하기 전에는 공개 운영으로 승격하지 않습니다. 검증 보고서에는 실제 blueprint 정보와 설치된 기반 패키지 버전을 기록하고, 이 계층까지 완전 재현 가능하다고 표현하지 않습니다.

## 명시적인 업데이트 절차

업데이트는 사람이 시작하는 다음 절차로만 진행합니다.

1. 새 공식 릴리스 노트, 알려진 제한과 라이선스 변경을 읽습니다.
2. 릴리스 태그가 가리키는 전체 commit을 확인합니다.
3. 공식 release workflow와 provenance가 그 commit을 사용했는지 확인합니다.
4. 각 이미지의 `linux/amd64` digest와 실제 프로그램 버전을 확인합니다.
5. 외부 이미지, Certbot과 PROJ-data의 digest·checksum·라이선스 목록을 다시 기록합니다.
6. 데이터베이스 migration(구조 변경), 상태 endpoint, QGIS 3 worker 작업, 백업과 격리 복원을 비운영 환경에서 시험합니다. `letsencrypt-ip` 변경이면 staging과 승인된 실제 환경에서 최초 발급·갱신·실패 롤백도 별도로 시험합니다.
7. QGIS 4는 별도의 실제 버전 확인과 worker 시험 없이는 활성화하지 않습니다.
8. 변경값, 비용 영향과 롤백 방법을 Pull Request에 기록합니다.
9. 사용자가 검토하고 명시적으로 승인한 뒤에만 파일럿에 적용합니다.

검증 실패, 이미지 누락, provenance 불일치 또는 예상하지 못한 migration이 있으면 기존 digest를 유지합니다. 되돌릴 때는 이전에 검증한 manifest와 그 버전에 맞는 데이터 백업을 사용합니다.
