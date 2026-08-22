# 비용 설계

## 금액의 성격

- **확인된 사실:** AWS는 사용한 서비스, 리전, 저장량과 전송량에 따라 과금합니다. 공식 계산은 [AWS Pricing Calculator](https://calculator.aws/)와 각 서비스 가격표를 사용해야 합니다.
- **프로젝트 추론:** 서울 리전에서 QGIS 작업이 가능한 서버와 백업까지 월 1만 원으로 유지하기는 어렵습니다.
- **프로젝트 권고:** Launch Stack 앞에서 추정 월 비용과 비용 중단 방법을 보여주고, 사용자가 AWS 화면에서 직접 승인하게 합니다.

## 초기 비교용 추정

| 프로필 | 월 추정 범위 | 포함 가정 | 별도 증가 요인 |
|---|---:|---|---|
| `lab-lightsail` | 약 3만~5만 원 이상 | 4GB급 단일 서버 | snapshot, 외부 백업, 전송량, 세금 |
| `standard-aws` | 약 10만~25만 원 이상 | EC2, 소형 RDS, S3, 기본 로그 | ALB, NAT, WAF, 백업 보존량, 전송량 |

이는 견적이나 가격 보장이 아닙니다. 환율과 AWS 가격이 바뀌므로 배포 직전 [Lightsail 가격표](https://aws.amazon.com/lightsail/pricing/), [EC2 요금](https://aws.amazon.com/ec2/pricing/), [RDS 요금](https://aws.amazon.com/rds/postgresql/pricing/) 및 [S3 요금](https://aws.amazon.com/s3/pricing/)을 다시 확인합니다.

## 비용을 키우는 선택

- 계속 실행되는 ALB와 NAT Gateway
- RDS 고가용성 및 큰 저장공간
- 오래 보관하는 snapshot과 CloudWatch 로그
- S3 객체 버전 누적
- 인터넷 데이터 전송과 대용량 프로젝트 파일
- 연결되지 않은 고정 IP와 삭제되지 않은 디스크

원본 드론 정사영상은 QFieldCloud 서버에 저장하지 않는 것을 기본 가정으로 하며, 필요한 저해상도 산출물만 별도 검토합니다.

## 비용 알림과 중단

배포 전 AWS Budgets 또는 Billing 알림을 권고하되, 알림은 과금을 자동 차단하지 않는다는 점을 표시합니다. 종료 시 인스턴스만 정지하지 말고 스냅샷, 디스크, RDS, S3, 로드 밸런서, 고정 IP, 로그와 DNS까지 확인합니다. 삭제 순서는 [안전한 삭제](runbooks/uninstall.md)를 따릅니다.
