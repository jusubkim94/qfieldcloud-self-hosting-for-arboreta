# `lab-lightsail` v0.1.4 실제 AWS 검증 기록 — 2026-08-25

## 결론

`v0.1.4` 완성 템플릿의 기본 Let’s Encrypt 공인 IP 인증서 경로가 서울 리전의 새 Lightsail에서 CloudFormation `CREATE_COMPLETE`까지 통과했습니다. 외부에서 인증서 신뢰, IP 주소 일치, QFieldCloud 로그인 이동과 공개 상태 API도 확인했습니다.

이 기록은 실제로 관찰한 결과와 설치 완료 gate(완료 조건)가 보장한 결과를 구분합니다. 운영 준비 완료, 장기 안정성 또는 인증서의 시간 경과 자동 갱신을 보증하지 않습니다.

## 시험 입력

| 항목 | 값 |
|---|---|
| AWS Region / Availability Zone | `ap-northeast-2` / `ap-northeast-2a` |
| 생성 경로 | AWS CloudShell의 `aws cloudformation create-stack` |
| CloudFormation 스택 이름 | `qfc` |
| Lightsail 인스턴스 이름 | `qfieldcloud-pilot` |
| Lightsail bundle / blueprint | `medium_3_0` / `ubuntu_24_04` |
| 인증서 파라미터 | `CertificateMode=letsencrypt-ip`, `LetsEncryptTermsAccepted=true` |
| 실패 처리 실행 옵션 | `--on-failure DO_NOTHING` |
| 시작 | 2026-08-24 23:43:48 KST |
| 완료 | 2026-08-25 00:07:33 KST |
| 걸린 시간 | 23분 45초 |

브라우저의 로컬 파일 선택 자동화 제약 때문에 이번 회차는 CloudShell에서 템플릿을 내려받고 SHA-256을 확인한 뒤 생성했습니다. 문서의 **CloudFormation → Upload a template file** 사용자 화면 흐름은 이번 회차에 다시 시험하지 않았습니다.

## 배포 artifact 고정값

| 항목 | 기대값 | 관찰 결과 |
|---|---|---|
| 릴리스 | `v0.1.4` | Output `ReleaseArtifactVersion` 일치 |
| Template SHA-256 | `798f2f5aed1c88e27be81db79a06c7adf61f7e5f9ad8fcd3d7f4a114f8d71ffa` | CloudShell 다운로드 뒤 일치 |
| 설치 소스 revision | `d00c5fa4581188299565938d8324103e740a6d9c` | Output `BootstrapRevision` 일치 |
| bootstrap SHA-256 | `66fe454dd7b8d85db24b6dc25b30941e4c0a03a735eccb2bf1c2035bf977727c` | Output `BootstrapSha256` 일치 |
| 설치 상태 | `installation-complete` | Output `InstallationStatus` 일치 |

템플릿은 [`releases/lab-lightsail/v0.1.4/template.yaml`](../../releases/lab-lightsail/v0.1.4/template.yaml), 릴리스 메타데이터는 [`manifest.json`](../../releases/lab-lightsail/v0.1.4/manifest.json)에 보존되어 있습니다.

## 외부에서 직접 관찰한 결과

| 검사 | 결과 |
|---|---|
| 고정 IPv4 | `3.39.112.39` |
| 인증서 발급자 | Let’s Encrypt `YE2` |
| Subject Alternative Name | critical IP SAN `3.39.112.39` |
| TLS chain 검증 | OpenSSL verify result `0` |
| 인증서 SHA-256 fingerprint | `807301a01287a3d389b3be3521c0f3d00e3331e3f831ac1a571720554f61ac00` |
| 루트 HTTPS | HTTP `302`, QFieldCloud Sign-In으로 이동 |
| 공개 상태 API | `database=ok`, `storage=ok` |

외부에서 관찰한 인증서 fingerprint는 CloudFormation WaitCondition의 `BootstrapValidationData`에 기록된 값과 일치했습니다.

## 설치 완료 gate가 확인한 결과

[`bootstrap.sh`](../../scripts/lab-lightsail/bootstrap.sh)는 [`worker-smoke-test.sh`](../../scripts/lab-lightsail/worker-smoke-test.sh)와 [`health-check.sh --installation-gate`](../../scripts/lab-lightsail/health-check.sh)가 모두 통과한 뒤에만 CloudFormation 성공 신호를 보냅니다. 이번 스택이 `CREATE_COMPLETE`이고 Outputs가 일치하므로 다음 항목은 **installation-gate 통과 근거**로 확인했습니다.

- QGIS 3 worker smoke test 통과
- `qfieldcloud-certificate-renew.timer`의 enabled·active 상태
- 디스크 인증서, Certbot 인증서와 Nginx 제공 인증서 fingerprint 일치
- 최종 health check 통과

위 네 항목은 이번 회차에 별도 SSH 명령으로 다시 실행해 수집한 독립 관찰값이 아닙니다. CloudFormation 성공 신호 전에 실행되는 고정 소스의 gate가 통과했다는 근거입니다.

## 아직 확인하지 않은 범위

- 시간이 실제로 흐른 뒤 timer가 Let’s Encrypt 인증서를 갱신하는 과정
- `--on-failure DO_NOTHING`을 선택한 실패 배포에서 성공적으로 생성된 자원이 실제로 보존되는 동작: 이번 배포는 실패하지 않았으므로 이 옵션을 경험적으로 시험하지 못했습니다.
- `v0.1.4` 파일을 사용자 PC에 내려받아 브라우저의 **Upload a template file**로 올리는 화면 흐름
- 장기간 부하, 장애 복구, 백업·복원과 운영 규모의 안정성

이 파일럿에는 자동 snapshot, 애플리케이션 백업 또는 복원 기능이 없습니다. 검증 성공은 데이터 복구 가능성을 뜻하지 않습니다.
