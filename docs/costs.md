# `lab-lightsail` 비용

이 문서는 브라우저 원클릭 파일럿의 기본 AWS 비용과 비용을 멈추는 방법을 설명합니다. 금액은 견적이나 가격 보장이 아니며 실제 배포 직전에 [AWS Lightsail 공식 가격표](https://aws.amazon.com/lightsail/pricing/)를 다시 확인해야 합니다.

## 기본 월 비용

확인 기준일은 **2026-08-24**입니다.

| 항목 | 포함 내용 | 공식 USD 가격 |
|---|---|---:|
| Lightsail Linux 4GB 상품 | 4GB RAM, 2 vCPU, 80GB SSD, 월 4TB 전송량 | **US$24/월** |
| 인스턴스에 연결된 static IP | `qfieldcloud-pilot` 인스턴스에 연결 | 추가 요금 없음 |
| 인스턴스에서 분리된 static IP | 연결 없이 계정에 남아 있음 | **US$0.005/시간** |
| 자동 snapshot | 이 파일럿은 생성하지 않음 | US$0 |
| 애플리케이션 백업 자원 | 이 파일럿은 생성하지 않음 | US$0 |

기본 예상은 **월 US$24**입니다. 세금, 환율, 포함량을 넘는 데이터 전송과 사용자가 따로 만든 자원은 포함하지 않습니다.

## 비용에 포함되지 않는 항목

- 포함량을 넘는 인터넷 데이터 전송
- 사용자가 콘솔에서 별도로 만든 디스크나 수동 snapshot
- 다른 리전에 복사한 자원
- 이 파일럿과 무관한 기존 AWS 자원
- 세금과 환전 비용
- 아직 게시하지 않은 릴리스 artifact용 S3 버킷·객체

S3 artifact는 현재 게시되지 않았고 관련 AWS 자원도 이 작업에서 만들지 않았습니다. 향후 실제 게시 전에 버킷, 리전, 공개 범위, 예상 비용과 삭제 방법을 별도로 설명하고 승인받아야 합니다.

## 비용이 시작되는 시점

CloudFormation Quick Create에서 **Create stack**을 누르면 과금 자원이 생성될 수 있습니다. 설치가 `CREATE_COMPLETE`에 도달하지 못해도 인스턴스나 static IP가 남으면 비용이 계속될 수 있습니다.

현재 Quick Create 링크는 S3 미게시 상태라 활성화되지 않았으며, 단순화한 경로의 실제 AWS 비용 발생 시험도 수행하지 않았습니다.

## 비용을 멈추는 방법

인스턴스를 정지하거나 브라우저 창을 닫는 것만으로 월 상품 비용이 끝난다고 생각하면 안 됩니다.

1. AWS 콘솔의 리전을 **Asia Pacific (Seoul) / `ap-northeast-2`**로 선택합니다.
2. **CloudFormation → Stacks → `qfieldcloud-pilot`**을 엽니다.
3. 필요한 경우 termination protection(삭제 방지)을 해제합니다.
4. **Delete stack**을 누르고 `DELETE_COMPLETE`를 확인합니다.
5. **Lightsail → Instances**에서 `qfieldcloud-pilot`이 사라졌는지 확인합니다.
6. **Lightsail → Networking**에서 분리된 static IP가 없는지 확인합니다.
7. **Storage/Disks**, **Snapshots**와 경보 목록에 사용자가 별도로 만든 잔존 자원이 없는지 확인합니다.
8. **Billing and Cost Management → Bills/Cost Explorer**에서 Lightsail 사용량을 확인합니다.

static IP가 분리된 채 남으면 시간당 US$0.005가 과금될 수 있으므로 스택 삭제 뒤에도 반드시 Networking 화면을 확인합니다. 청구 화면 반영에는 시간이 걸릴 수 있습니다.

자세한 클릭 순서는 [삭제 실행서](runbooks/uninstall.md)를 따릅니다.

## 데이터와 비용의 관계

이 파일럿에는 백업·복원·자동 snapshot이 없습니다. 비용을 줄이기 위해 스택을 삭제하면 서버 데이터도 영구적으로 사라집니다. 비용 중단과 데이터 보존을 동시에 보장하는 기능은 제공하지 않습니다.

중요 데이터가 있다면 스택을 만들기 전에 이 파일럿이 적합한지 다시 판단해야 합니다.
