# 상태 확인 실행서

상태 확인의 기준은 CloudFormation 완료 상태와 템플릿이 제공하는 Outputs입니다. 웹 페이지가 열린다는 사실만으로 전체 설치 성공으로 판정하지 않습니다.

> 완성 템플릿은 다운로드할 수 있지만 이 수동 업로드 상태 확인 흐름은 실제 AWS에서 아직 검증하지 않았습니다.

## 1. CloudFormation에서 확인

1. AWS 웹 콘솔 오른쪽 위에서 **Asia Pacific (Seoul) ap-northeast-2**를 선택합니다.
2. **CloudFormation → Stacks → qfieldcloud-pilot**을 엽니다.
3. **Stack info**에서 상태가 `CREATE_COMPLETE`인지 확인합니다.
4. **Outputs** 탭을 엽니다.

다음 값을 확인합니다.

| Output | 정상 기준 |
|---|---|
| `DeploymentProfile` | `lab-lightsail` |
| `DeployedRegion` | `ap-northeast-2` |
| `InstanceName` | `qfieldcloud-pilot` |
| `InstallationStatus` | `installation-complete` |
| `HttpsUrl` | 파일럿 HTTPS 주소 |
| `CertificateMode` | 설치 때 선택한 인증서 모드 |
| `ReleaseArtifactVersion` | 클릭한 릴리스의 고정 버전 |
| `DataProtectionWarning` | 데이터 보호 기능이 없다는 경고 |

`CREATE_COMPLETE`는 설치기, 데이터베이스 migration, 서비스 상태와 QGIS 3 worker 시험이 완료 신호를 보냈다는 뜻입니다. 다른 상태이면 성공으로 보지 말고 **Events**를 확인합니다.

## 2. 웹 서비스 확인

1. Outputs의 `HttpsUrl`을 새 브라우저 탭에서 엽니다.
2. 설치 때 선택한 인증서 모드와 주소가 일치하는지 확인합니다.
3. `https://호스트/api/v1/status/`를 열어 응답의 `database`와 `storage`가 정상인지 확인합니다.
4. 작은 시험 프로젝트의 동기화와 QGIS 작업이 기대대로 동작하는지 확인합니다.

인증서 경고를 무시하거나 브라우저 검사를 비활성화해 정상으로 처리하지 않습니다.

## 3. 선택적인 서버 상세 확인

서버 내부 상태가 필요할 때만 브라우저 SSH를 사용합니다.

1. AWS 콘솔에서 **Lightsail → Instances → qfieldcloud-pilot**을 엽니다.
2. **Connect using SSH**를 누릅니다.
3. 터미널에서 다음 명령을 실행합니다.

```bash
sudo /opt/qfieldcloud/bin/health-check.sh
```

출력은 JSON입니다. 최소한 다음 항목을 확인합니다.

- `overall`: `ok`
- `runtime_provenance`: `verified-pinned-installer-files`
- `runtime_images`: `verified-pinned-image-objects`
- `worker_validation`: `passed`
- `tls_certificate`와 `certificate_renewal`: 선택한 인증서 모드의 정상값

상태 출력에는 비밀번호나 토큰이 없어야 합니다. 전체 환경변수, Secret 파일, 개인키 또는 데이터베이스 접속 문자열을 출력하거나 공유하지 않습니다.

## 4. 판정

| 판정 | 기준 |
|---|---|
| 정상 | `CREATE_COMPLETE`, Outputs 일치, HTTPS/API 정상, worker 시험 통과 |
| 부분 장애 | 웹은 열리지만 데이터베이스, 저장소, 인증서 또는 worker 검사 실패 |
| 장애 | 스택 생성 실패, HTTPS/API 사용 불가 또는 서버 상세 검사 `overall=error` |
| 미검증 | 실제 검사를 수행하지 않음 |

이 파일럿에는 자동 스냅샷이나 애플리케이션 백업이 없습니다. 상태가 정상이어도 복구 가능한 사본이 있다는 뜻은 아닙니다. 오류는 [문제 해결 안내](../troubleshooting.md)를 따르고, 조사 후 자원을 없앨 때는 [삭제 실행서](uninstall.md)를 따릅니다.
