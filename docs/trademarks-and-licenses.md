# 라이선스와 상표

## 이 프로젝트의 위치

이 저장소는 QFieldCloud와 함께 사용할 수 있는 **독립적인 비공식 설치 도구**입니다. OPENGIS.ch, QField 또는 QFieldCloud 공식 프로젝트가 제작·승인·보증하거나 지원하는 제품이 아닙니다.

MIT와 같은 오픈소스 라이선스는 소프트웨어를 사용할 권리를 설명하지만, 이름과 로고를 공식 제품처럼 사용할 권리까지 자동으로 주지는 않습니다. 따라서 QFieldCloud라는 이름은 호환 대상을 설명하는 데 필요한 범위로만 사용하고 공식 로고는 이 프로젝트의 로고로 사용하지 않습니다.

## 현재 배포 인벤토리

아래 표는 `lab-lightsail` 기준선에서 반드시 추적할 항목입니다. 정확한 이미지 digest는 [버전 고정 정책](version-policy.md)에 기록합니다. digest 고정은 동일한 이미지 내용을 받게 할 뿐이며, 그 안의 모든 소프트웨어가 하나의 라이선스를 가진다는 뜻은 아닙니다.

| 구성요소 | 고정한 버전 | 공식 라이선스·출처 근거 | 이 프로젝트의 처리 |
| --- | --- | --- | --- |
| QFieldCloud app, Nginx, worker wrapper, bucket 초기화 코드 | `v26.25`, commit `c32bc110f8291b2a32e318528ee46689771630d6` | [해당 commit의 MIT License](https://github.com/opengisch/QFieldCloud/blob/c32bc110f8291b2a32e318528ee46689771630d6/LICENSE) | QFieldCloud 소스 또는 상당 부분을 재배포할 때 저작권과 MIT 고지를 유지합니다. 이미지 안의 기반 OS와 Python 패키지는 각자의 고지도 별도로 확인합니다. |
| QGIS 3 worker | QFieldCloud `v26.25` 이미지, QGIS `3.44.13` | [QGIS `final-3_44_13`의 COPYING](https://github.com/qgis/QGIS/blob/final-3_44_13/COPYING), [QFieldCloud MIT License](https://github.com/opengisch/QFieldCloud/blob/c32bc110f8291b2a32e318528ee46689771630d6/LICENSE) | QFieldCloud worker 코드와 QGIS 및 OS 패키지를 하나의 라이선스로 뭉뚱그리지 않습니다. 이미지를 별도 배포하거나 수정하면 각 구성요소의 소스 제공·고지 의무를 다시 검토합니다. |
| PROJ-data 변환 격자 | `1.24.0`, archive SHA-256 `eadf412754a2a9a727d79579873fbe7dae802038d4c2a19e452a886d4eddd111` | [공식 릴리스](https://github.com/OSGeo/PROJ-data/releases/tag/1.24.0), [`README.DATA`](https://github.com/OSGeo/PROJ-data/blob/1.24.0/README.DATA), [`copyright_and_licenses.csv`](https://github.com/OSGeo/PROJ-data/blob/1.24.0/copyright_and_licenses.csv) | 단일 라이선스로 표시하지 않습니다. archive에 포함된 파일별 저작권·라이선스 목록을 격자와 함께 보존합니다. |
| PostgreSQL/PostGIS 이미지 | `postgis/postgis:17-3.5-alpine`의 고정 digest | [공식 docker-postgis 저장소](https://github.com/postgis/docker-postgis) | 이미지 제작 저장소, PostgreSQL, PostGIS, Alpine과 포함 패키지의 고지를 각각 확인합니다. |
| RustFS 이미지 | `rustfs/rustfs:1.0.0-beta.11`의 고정 digest | [공식 RustFS 저장소](https://github.com/rustfs/rustfs) | beta 구성요소임을 표시하고, 재배포 전 해당 릴리스와 포함 의존성의 고지를 확인합니다. |
| smtp4dev 이미지 | `rnwood/smtp4dev:v3`의 고정 digest | [공식 smtp4dev 저장소](https://github.com/rnwood/smtp4dev) | 파일럿용 메일 시험 구성임을 표시하며 이미지와 포함 런타임의 고지를 확인합니다. |
| Ofelia 이미지 | `mcuadros/ofelia:0.3.18`의 고정 digest | [공식 Ofelia 저장소](https://github.com/mcuadros/ofelia) | 예약 작업 실행기와 기반 이미지의 라이선스 고지를 확인합니다. |
| Memcached 이미지 | `memcached:1`의 고정 digest | [공식 Memcached 저장소](https://github.com/memcached/memcached) | Memcached와 공식 컨테이너 기반 계층의 고지를 확인합니다. |

## PROJ-data 라이선스 목록

PROJ-data는 좌표 변환용 여러 기관의 격자를 모은 데이터 묶음입니다. [공식 `README.DATA`](https://github.com/OSGeo/PROJ-data/blob/1.24.0/README.DATA)는 격자들이 허용적 라이선스로 공개된다고 설명하지만, 모든 파일이 같은 라이선스인 것은 아닙니다. Public domain, X/MIT, BSD, CC0, CC-BY, CC-BY-SA 등 조건이 파일마다 다를 수 있습니다.

파일별 기준은 [`copyright_and_licenses.csv`](https://github.com/OSGeo/PROJ-data/blob/1.24.0/copyright_and_licenses.csv)의 `filename`, `copyright`, `license`, `version_added`, `version_removed` 열입니다. 특히 CC-BY 계열은 저작자 표시 조건을, CC-BY-SA 계열은 추가 조건을 확인해야 합니다.

현재 설치기는 공식 `proj-data-1.24.tar.gz`의 크기와 SHA-256을 확인한 뒤 다음을 모두 만족해야 설치합니다.

1. 하나 이상의 `.tif` 격자 파일이 있습니다.
2. `README.DATA`가 있습니다.
3. `copyright_and_licenses.csv`가 있습니다.
4. 이 두 안내 파일을 격자와 같은 Docker volume(컨테이너 밖에 유지되는 저장 공간)에 복사합니다.

격자를 다른 archive, 컨테이너 이미지, 백업 배포물 또는 mirror에 넣어 전달할 때도 해당 파일과 필요한 저작자 표시를 함께 보존합니다. checksum은 무결성을 증명하지만 라이선스 준수를 대신하지 않습니다.

## 공개와 재배포 전 확인

- 저장소와 README 상단에 독립적인 비공식 프로젝트임을 한국어와 영어로 표시합니다.
- QFieldCloud 소스 고지와 PROJ-data 파일별 고지를 제거하지 않습니다.
- 컨테이너 digest, 사람이 읽는 버전, 공식 출처와 확인 날짜를 함께 기록합니다.
- 컨테이너를 우리 registry로 복제하거나 수정 이미지를 공개하기 전에 이미지 안의 OS·언어 패키지까지 포함한 라이선스 목록과 소스 제공 의무를 다시 확인합니다.
- 공식 로고, 화면 자산 또는 홍보 문구를 추가하려면 별도의 사용 허가나 최신 공식 지침이 있는지 먼저 확인합니다.
- 라이선스 또는 상표 조건이 불명확하면 공개 범위를 넓히지 않고 권리자나 법률 전문가에게 확인합니다.

## 불확실성

검토 시점에 모든 사용 상황을 포괄하는 QField/QFieldCloud 세부 상표 정책을 확정하지 못했습니다. 따라서 이름 사용은 호환 대상 설명에 필요한 범위로 제한합니다. 이 문서는 기술적인 준수 기록이며 법률 자문이 아닙니다.
