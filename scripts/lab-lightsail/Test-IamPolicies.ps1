#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Contract {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-AllowStatementsForAction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Policy,

        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    return @(
        $Policy.Statement | Where-Object {
            $_.Effect -eq 'Allow' -and @($_.Action) -contains $Action
        }
    )
}

function Get-StatementsBySid {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Policy,

        [Parameter(Mandatory = $true)]
        [string]$Sid
    )

    return @(
        $Policy.Statement | Where-Object {
            $_.PSObject.Properties.Name -contains 'Sid' -and $_.Sid -eq $Sid
        }
    )
}

function Test-ExactSet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Actual,

        [Parameter(Mandatory = $true)]
        [string[]]$Expected
    )

    $difference = Compare-Object `
        -ReferenceObject @($Expected | Sort-Object -Unique) `
        -DifferenceObject @($Actual | Sort-Object -Unique)
    return @($difference).Count -eq 0
}

function Test-PilotResourceTags {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Statement
    )

    $equals = $Statement.Condition.StringEquals
    return (
        $equals.'aws:RequestedRegion' -eq 'ap-northeast-2' -and
        $equals.'aws:ResourceTag/Project' -eq 'qfieldcloud-self-hosting' -and
        $equals.'aws:ResourceTag/DeploymentProfile' -eq 'lab-lightsail' -and
        $equals.'aws:ResourceTag/ManagedBy' -eq 'CloudFormation' -and
        $equals.'aws:ResourceTag/CloudFormationStack' -eq 'qfieldcloud-lab-pilot'
    )
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$deployerPath = Join-Path $repositoryRoot 'infra/lab-lightsail/deployer-policy.json'
$cleanupPath = Join-Path $repositoryRoot 'infra/lab-lightsail/cleanup-policy.json'
$templatePath = Join-Path $repositoryRoot 'infra/lab-lightsail/template.yaml'
$deployScriptPath = Join-Path $PSScriptRoot 'Deploy-QFieldCloudPilot.ps1'
$testScriptPath = Join-Path $PSScriptRoot 'Test-QFieldCloudPilot.ps1'

$deployerText = Get-Content -Raw -LiteralPath $deployerPath
$deployer = $deployerText | ConvertFrom-Json -Depth 100
$cleanup = Get-Content -Raw -LiteralPath $cleanupPath | ConvertFrom-Json -Depth 100

$allowedResourceTypes = @(
    'AWS::CloudFormation::WaitCondition'
    'AWS::CloudFormation::WaitConditionHandle'
    'AWS::Lightsail::Alarm'
    'AWS::Lightsail::Instance'
    'AWS::Lightsail::StaticIp'
)
$cloudFormationOnlyLightsailActions = @(
    'lightsail:AllocateStaticIp'
    'lightsail:AttachStaticIp'
    'lightsail:CreateInstances'
    'lightsail:DeleteAlarm'
    'lightsail:DeleteInstance'
    'lightsail:DetachStaticIp'
    'lightsail:DisableAddOn'
    'lightsail:EnableAddOn'
    'lightsail:PutAlarm'
    'lightsail:PutInstancePublicPorts'
    'lightsail:ReleaseStaticIp'
    'lightsail:TagResource'
)
$expectedCloudFormationAllowActions = @(
    'cloudformation:CreateStack'
    'cloudformation:DescribeStackEvents'
    'cloudformation:DescribeStackResources'
    'cloudformation:DescribeStacks'
    'cloudformation:GetStackPolicy'
    'cloudformation:GetTemplate'
    'cloudformation:ListStackResources'
    'cloudformation:ListStacks'
    'cloudformation:ValidateTemplate'
)
$expectedLightsailAllowActions = @(
    $cloudFormationOnlyLightsailActions
    'lightsail:GetAlarms'
    'lightsail:GetBlueprints'
    'lightsail:GetBundles'
    'lightsail:GetDisks'
    'lightsail:GetDistributions'
    'lightsail:GetInstance'
    'lightsail:GetInstanceAccessDetails'
    'lightsail:GetInstances'
    'lightsail:GetInstanceSnapshots'
    'lightsail:GetInstanceState'
    'lightsail:GetKeyPairs'
    'lightsail:GetLoadBalancers'
    'lightsail:GetRegions'
    'lightsail:GetStaticIp'
    'lightsail:GetStaticIps'
    'lightsail:RebootInstance'
    'lightsail:StartInstance'
    'lightsail:StopInstance'
)

$allAllowActions = @(
    $deployer.Statement |
        Where-Object { $_.Effect -eq 'Allow' } |
        ForEach-Object { @($_.Action) }
)
$cloudFormationAllowActions = @($allAllowActions | Where-Object { $_ -like 'cloudformation:*' })
$lightsailAllowActions = @($allAllowActions | Where-Object { $_ -like 'lightsail:*' })
Assert-Contract (Test-ExactSet -Actual $cloudFormationAllowActions -Expected $expectedCloudFormationAllowActions) '배포 정책에 예상 밖 CloudFormation Allow가 있거나 필수 Allow가 없습니다.'
Assert-Contract (Test-ExactSet -Actual $lightsailAllowActions -Expected $expectedLightsailAllowActions) '배포 정책에 예상 밖 Lightsail Allow가 있거나 필수 Allow가 없습니다.'
Assert-Contract (([regex]::Replace($deployerText, '\s+', '')).Length -le 6144) '배포 정책이 IAM 고객 관리형 정책의 6,144자 제한을 초과합니다.'
Assert-Contract (([regex]::Replace($deployerText, '\s+', '')).Length -le 6000) '배포 정책이 향후 안전한 수정을 위한 144자 여유를 남기지 않습니다.'

$cloudFormationRegionDeny = @(Get-StatementsBySid -Policy $deployer -Sid 'DenyCfnGeo')
Assert-Contract ($cloudFormationRegionDeny.Count -eq 1) '서울 밖 CloudFormation Deny가 정확히 하나여야 합니다.'
Assert-Contract ($cloudFormationRegionDeny[0].Action -eq 'cloudformation:*') '서울 밖 CloudFormation Deny 작업이 다릅니다.'
Assert-Contract ($cloudFormationRegionDeny[0].Resource -eq '*') '서울 밖 CloudFormation Deny 범위가 다릅니다.'
Assert-Contract ($cloudFormationRegionDeny[0].Condition.StringNotEquals.'aws:RequestedRegion' -eq 'ap-northeast-2') 'CloudFormation 허용 리전은 서울뿐이어야 합니다.'

$lightsailRegionDeny = @(Get-StatementsBySid -Policy $deployer -Sid 'DenyLsGeo')
Assert-Contract ($lightsailRegionDeny.Count -eq 1) '승인 리전 밖 Lightsail Deny가 정확히 하나여야 합니다.'
Assert-Contract ($lightsailRegionDeny[0].Action -eq 'lightsail:*') '승인 리전 밖 Lightsail Deny 작업이 다릅니다.'
Assert-Contract ($lightsailRegionDeny[0].Resource -eq '*') '승인 리전 밖 Lightsail Deny 범위가 다릅니다.'
Assert-Contract (Test-ExactSet -Actual @($lightsailRegionDeny[0].Condition.StringNotEquals.'aws:RequestedRegion') -Expected @('ap-northeast-2', 'us-east-1')) 'Lightsail 허용 리전 목록이 다릅니다.'

$seoulReadActions = @(
    'lightsail:GetAlarms'
    'lightsail:GetBlueprints'
    'lightsail:GetBundles'
    'lightsail:GetDisks'
    'lightsail:GetInstance'
    'lightsail:GetInstances'
    'lightsail:GetInstanceSnapshots'
    'lightsail:GetInstanceState'
    'lightsail:GetKeyPairs'
    'lightsail:GetLoadBalancers'
    'lightsail:GetRegions'
    'lightsail:GetStaticIp'
    'lightsail:GetStaticIps'
)
$seoulReadStatement = @(Get-StatementsBySid -Policy $deployer -Sid 'ReadLsSeoul')
Assert-Contract ($seoulReadStatement.Count -eq 1) '서울 Lightsail 조회 statement가 정확히 하나여야 합니다.'
Assert-Contract (Test-ExactSet -Actual @($seoulReadStatement[0].Action) -Expected $seoulReadActions) '서울 Lightsail 조회 작업 목록이 다릅니다.'
Assert-Contract ($seoulReadStatement[0].Resource -eq '*') '서울 Lightsail 목록 조회는 AWS가 요구하는 별표 범위여야 합니다.'
Assert-Contract ($seoulReadStatement[0].Condition.StringEquals.'aws:RequestedRegion' -eq 'ap-northeast-2') '서울 Lightsail 조회 리전이 다릅니다.'

$distributionReadStatement = @(Get-StatementsBySid -Policy $deployer -Sid 'ReadLsCdn')
Assert-Contract ($distributionReadStatement.Count -eq 1) '버지니아 CDN 조회 statement가 정확히 하나여야 합니다.'
Assert-Contract ($distributionReadStatement[0].Action -eq 'lightsail:GetDistributions') '버지니아에서는 CDN 목록 조회만 허용해야 합니다.'
Assert-Contract ($distributionReadStatement[0].Resource -eq '*') 'CDN 목록 조회는 AWS가 요구하는 별표 범위여야 합니다.'
Assert-Contract ($distributionReadStatement[0].Condition.StringEquals.'aws:RequestedRegion' -eq 'us-east-1') 'CDN 목록 조회 리전은 버지니아 북부여야 합니다.'

foreach ($action in $cloudFormationOnlyLightsailActions) {
    $statements = @(Get-AllowStatementsForAction -Policy $deployer -Action $action)
    Assert-Contract ($statements.Count -gt 0) "필수 CloudFormation 작업 권한이 없습니다: $action"
    foreach ($statement in $statements) {
        $calledVia = $statement.Condition.'ForAnyValue:StringEquals'.'aws:CalledVia'
        Assert-Contract ($calledVia -eq 'cloudformation.amazonaws.com') "직접 Lightsail 쓰기가 열려 있습니다: $action"
        Assert-Contract (-not ($statement.Condition.PSObject.Properties.Name -contains 'StringEqualsIfExists')) "CalledVia에 IfExists를 사용할 수 없습니다: $action"
    }
}

$createInstances = @(Get-AllowStatementsForAction -Policy $deployer -Action 'lightsail:CreateInstances')
Assert-Contract ($createInstances.Count -eq 1) 'CreateInstances Allow는 정확히 하나여야 합니다.'
$createTags = $createInstances[0].Condition.StringEquals
Assert-Contract ($createTags.'aws:RequestTag/Project' -eq 'qfieldcloud-self-hosting') 'CreateInstances Project 태그가 다릅니다.'
Assert-Contract ($createTags.'aws:RequestTag/DeploymentProfile' -eq 'lab-lightsail') 'CreateInstances DeploymentProfile 태그가 다릅니다.'
Assert-Contract ($createTags.'aws:RequestTag/ManagedBy' -eq 'CloudFormation') 'CreateInstances ManagedBy 태그가 다릅니다.'
Assert-Contract ($createTags.'aws:RequestTag/CloudFormationStack' -eq 'qfieldcloud-lab-pilot') 'CreateInstances CloudFormationStack 태그가 다릅니다.'

$managedInstanceStatement = @(Get-StatementsBySid -Policy $deployer -Sid 'ManageVm')
Assert-Contract ($managedInstanceStatement.Count -eq 1) 'CloudFormation 인스턴스 관리 statement가 정확히 하나여야 합니다.'
Assert-Contract (Test-ExactSet -Actual @($managedInstanceStatement[0].Action) -Expected @('lightsail:DeleteInstance', 'lightsail:PutInstancePublicPorts')) 'CloudFormation 인스턴스 관리 작업 목록이 다릅니다.'
Assert-Contract (Test-PilotResourceTags -Statement $managedInstanceStatement[0]) 'CloudFormation 인스턴스 관리 태그 조건이 다릅니다.'

$attachStatements = @(Get-AllowStatementsForAction -Policy $deployer -Action 'lightsail:AttachStaticIp')
Assert-Contract ($attachStatements.Count -eq 2) 'AttachStaticIp는 Instance와 StaticIp용 두 statement로 분리해야 합니다.'
$attachInstanceStatement = @($attachStatements | Where-Object { $_.Resource -eq 'arn:aws:lightsail:ap-northeast-2:*:Instance/*' })
$attachStaticIpStatement = @($attachStatements | Where-Object { $_.Resource -eq 'arn:aws:lightsail:ap-northeast-2:*:StaticIp/*' })
Assert-Contract ($attachInstanceStatement.Count -eq 1) 'AttachStaticIp의 Instance 권한이 정확히 하나여야 합니다.'
Assert-Contract ($attachStaticIpStatement.Count -eq 1) 'AttachStaticIp의 StaticIp 권한이 정확히 하나여야 합니다.'
Assert-Contract (Test-PilotResourceTags -Statement $attachInstanceStatement[0]) 'AttachStaticIp의 대상 Instance 태그 조건이 다릅니다.'

$directActions = @(
    'lightsail:GetInstanceAccessDetails'
    'lightsail:RebootInstance'
    'lightsail:StartInstance'
    'lightsail:StopInstance'
)
$directStatement = @(Get-StatementsBySid -Policy $deployer -Sid 'OperateVm')
Assert-Contract ($directStatement.Count -eq 1) '직접 운영 권한 statement가 정확히 하나여야 합니다.'
Assert-Contract (Test-ExactSet -Actual @($directStatement[0].Action) -Expected $directActions) '직접 운영 권한은 SSH·시작·중지·재시작만 허용해야 합니다.'
Assert-Contract (Test-PilotResourceTags -Statement $directStatement[0]) '직접 운영 권한의 파일럿 태그 조건이 다릅니다.'

$createStack = @(Get-AllowStatementsForAction -Policy $deployer -Action 'cloudformation:CreateStack')
Assert-Contract ($createStack.Count -eq 1) 'CreateStack 허용은 정확히 하나여야 합니다.'
Assert-Contract ($createStack[0].Resource -eq 'arn:aws:cloudformation:ap-northeast-2:*:stack/qfieldcloud-lab-pilot/*') 'CloudFormation 스택 ARN이 고정되지 않았습니다.'
Assert-Contract ($createStack[0].Condition.StringEquals.'aws:RequestedRegion' -eq 'ap-northeast-2') 'CreateStack 리전이 서울로 고정되지 않았습니다.'
Assert-Contract ($createStack[0].Condition.StringEquals.'aws:RequestTag/Project' -eq 'qfieldcloud-self-hosting') 'CreateStack Project 태그가 다릅니다.'
Assert-Contract ($createStack[0].Condition.StringEquals.'aws:RequestTag/DeploymentProfile' -eq 'lab-lightsail') 'CreateStack DeploymentProfile 태그가 다릅니다.'
Assert-Contract ($createStack[0].Condition.Null.'cloudformation:ResourceTypes' -eq 'false') 'CreateStack에서 resource-types 생략을 막아야 합니다.'
Assert-Contract (Test-ExactSet -Actual @($createStack[0].Condition.'ForAllValues:StringEquals'.'cloudformation:ResourceTypes') -Expected $allowedResourceTypes) '정책의 CloudFormation 자원 형식 목록이 다릅니다.'

foreach ($action in 'cloudformation:DeleteStack', 'cloudformation:UpdateTerminationProtection') {
    $deleteStatements = @(Get-AllowStatementsForAction -Policy $deployer -Action $action)
    Assert-Contract ($deleteStatements.Count -eq 0) "평상시 배포 정책에 삭제 권한이 있습니다: $action"
}

$cleanupAllows = @($cleanup.Statement | Where-Object { $_.Effect -eq 'Allow' })
Assert-Contract ($cleanupAllows.Count -eq 1) 'cleanup 정책의 Allow는 정확히 하나여야 합니다.'
Assert-Contract (Test-ExactSet -Actual @($cleanupAllows[0].Action) -Expected @('cloudformation:DeleteStack', 'cloudformation:UpdateTerminationProtection')) 'cleanup 정책에는 두 삭제 준비 작업만 있어야 합니다.'
Assert-Contract ($cleanupAllows[0].Resource -eq 'arn:aws:cloudformation:ap-northeast-2:*:stack/qfieldcloud-lab-pilot/*') 'cleanup 정책의 대상 스택이 고정되지 않았습니다.'
Assert-Contract ($cleanupAllows[0].Condition.StringEquals.'aws:RequestedRegion' -eq 'ap-northeast-2') 'cleanup 정책 리전이 서울로 고정되지 않았습니다.'

$templateText = Get-Content -Raw -LiteralPath $templatePath
$templateResourceTypes = @(
    [regex]::Matches($templateText, '(?m)^    Type: (AWS::[A-Za-z0-9:]+)\s*$') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
)
Assert-Contract (Test-ExactSet -Actual $templateResourceTypes -Expected $allowedResourceTypes) '템플릿 자원 형식과 정책 allowlist가 다릅니다.'

$userDataMatch = [regex]::Match(
    $templateText,
    '(?ms)^      UserData: !Sub \|\r?\n(?<Body>.*?)(?=^  StaticIp:\s*$)'
)
Assert-Contract $userDataMatch.Success 'Lightsail UserData 블록을 찾지 못했습니다.'
$userDataLines = @(
    $userDataMatch.Groups['Body'].Value.TrimEnd("`r", "`n") -split '\r?\n' |
        ForEach-Object {
            if ($_ -eq '') {
                return ''
            }
            Assert-Contract ($_.StartsWith('        ')) 'Lightsail UserData 들여쓰기가 일관되지 않습니다.'
            return $_.Substring(8)
        }
)
Assert-Contract ($userDataLines.Count -gt 3) 'Lightsail UserData 본문이 비어 있습니다.'
Assert-Contract ($userDataLines[0] -ceq '#!/bin/sh') 'Lightsail UserData의 이식 가능한 외부 셸 선언이 없습니다.'
$userDataCommands = @(
    $userDataLines | Where-Object { $_ -ne '' -and -not $_.StartsWith('#') }
)
Assert-Contract ($userDataCommands[0] -ceq 'umask 077') 'Lightsail 외부 셸이 파일 권한 기본값을 먼저 제한하지 않습니다.'
Assert-Contract ($userDataCommands[1] -ceq "PATH='/usr/sbin:/usr/bin:/sbin:/bin'") 'Lightsail 외부 셸의 명령 검색 경로가 고정되지 않았습니다.'
Assert-Contract ($userDataCommands[2] -ceq 'export PATH') 'Lightsail 외부 셸의 고정 명령 검색 경로를 Bash에 전달하지 않습니다.'
Assert-Contract ($userDataCommands[3] -ceq "exec /usr/bin/env bash -s -- <<'QFC_LIGHTSAIL_BASH_V1'") 'Lightsail 래퍼가 Bash로 명시적으로 전환하지 않습니다.'
$bashHandoffLine = [array]::IndexOf($userDataLines, "exec /usr/bin/env bash -s -- <<'QFC_LIGHTSAIL_BASH_V1'")
Assert-Contract ($bashHandoffLine -ge 0) 'Lightsail Bash 전환 위치를 찾지 못했습니다.'
Assert-Contract ($userDataLines[$bashHandoffLine + 1] -ceq '#!/usr/bin/env bash') '전달되는 Bash 본문에 실행기 정보가 없습니다.'
Assert-Contract ($userDataLines[$bashHandoffLine + 2] -ceq 'set -Eeuo pipefail') 'Bash 안전 옵션이 명시적 Bash 전환 바로 뒤에 있지 않습니다.'
Assert-Contract ($userDataLines[-2] -ceq 'QFC_LIGHTSAIL_BASH_V1') 'Lightsail Bash heredoc 종료 표식이 UserData 끝에 없습니다.'
Assert-Contract ($userDataLines[-1] -ceq 'exit 127') 'Lightsail Bash 실행 실패를 성공으로 오인할 수 있습니다.'
Assert-Contract ((@($userDataLines | Where-Object { $_ -eq 'QFC_LIGHTSAIL_BASH_V1' })).Count -eq 1) 'Lightsail Bash heredoc 종료 표식은 정확히 하나여야 합니다.'
Assert-Contract (([regex]::Matches($userDataMatch.Groups['Body'].Value, 'QFC_LIGHTSAIL_BASH_V1')).Count -eq 2) 'Lightsail Bash heredoc 이름은 시작과 종료에만 있어야 합니다.'
Assert-Contract (([regex]::Matches($userDataMatch.Groups['Body'].Value, 'QFC_WAIT_HANDLE_V1')).Count -eq 2) 'WaitHandle heredoc 이름은 시작과 종료에만 있어야 합니다.'
$waitHandleReadLine = [array]::IndexOf($userDataLines, "IFS= read -r wait_handle <<'QFC_WAIT_HANDLE_V1'")
Assert-Contract ($waitHandleReadLine -gt 0) 'WaitHandle을 읽는 quoted heredoc 블록을 찾지 못했습니다.'
Assert-Contract ($userDataLines[$waitHandleReadLine + 1] -ceq '${BootstrapWaitHandle}') 'WaitHandle 치환값이 quoted heredoc의 단독 데이터 줄에 있지 않습니다.'
Assert-Contract ($userDataLines[$waitHandleReadLine + 2] -ceq 'QFC_WAIT_HANDLE_V1') 'WaitHandle quoted heredoc 종료 표식 위치가 다릅니다.'
Assert-Contract ($userDataLines[$waitHandleReadLine + 3] -ceq 'readonly wait_handle') '읽은 WaitHandle 변수를 즉시 읽기 전용으로 만들지 않습니다.'
Assert-Contract (([regex]::Matches($userDataMatch.Groups['Body'].Value, '\$\{BootstrapWaitHandle\}')).Count -eq 1) 'WaitHandle 치환값은 보호된 데이터 줄에 정확히 한 번만 있어야 합니다.'
$disableTraceLine = [array]::IndexOf($userDataLines, 'set +x')
Assert-Contract ($disableTraceLine -ge 0 -and $disableTraceLine -lt $waitHandleReadLine) 'WaitHandle을 읽기 전에 Bash 실행 추적을 명시적으로 꺼야 합니다.'
Assert-Contract (-not (@($userDataLines[0..$waitHandleReadLine] | Where-Object { $_ -ceq 'set -x' }))) 'WaitHandle을 읽기 전에 Bash 실행 추적을 다시 켜면 안 됩니다.'
$onExitStart = [array]::IndexOf($userDataLines, 'on_exit() {')
$onExitEnd = if ($onExitStart -ge 0) {
    [array]::IndexOf($userDataLines, '}', $onExitStart)
}
else {
    -1
}
Assert-Contract ($onExitStart -ge 0 -and $onExitEnd -gt $onExitStart) 'Lightsail 실패 trap 함수를 찾지 못했습니다.'
$onExitLines = @($userDataLines[$onExitStart..$onExitEnd])
Assert-Contract ($onExitLines[1] -ceq '  rc=$?') 'Lightsail 실패 trap이 원래 종료코드를 먼저 보존하지 않습니다.'
Assert-Contract ($onExitLines[2] -ceq '  trap - EXIT') 'Lightsail 실패 trap의 재귀 실행을 막지 않습니다.'
Assert-Contract ($onExitLines[3] -ceq '  set +e') 'Lightsail 실패 정리 작업이 원래 종료코드를 가릴 수 있습니다.'
Assert-Contract ($onExitLines -contains '       [ ! -L "$state_dir" ] &&') 'Lightsail 실패 상태 디렉터리의 symlink 쓰기를 거부하지 않습니다.'
Assert-Contract ($onExitLines[-2] -ceq '  exit "$rc"') 'Lightsail 실패 trap이 원래 종료코드로 끝나지 않습니다.'
$expectedUserDataSubstitutions = @(
    'BootstrapPath'
    'BootstrapRevision'
    'BootstrapSha256'
    'BootstrapWaitHandle'
    'RepositoryName'
    'RepositoryOwner'
)
$actualUserDataSubstitutions = @(
    [regex]::Matches($userDataMatch.Groups['Body'].Value, '\$\{(?<Name>[^}]+)\}') |
        ForEach-Object { $_.Groups['Name'].Value } |
        Sort-Object -Unique
)
Assert-Contract (Test-ExactSet -Actual $actualUserDataSubstitutions -Expected $expectedUserDataSubstitutions) 'Lightsail UserData의 CloudFormation 치환 변수 allowlist가 다릅니다.'

$deployScriptText = Get-Content -Raw -LiteralPath $deployScriptPath
$testScriptText = Get-Content -Raw -LiteralPath $testScriptPath
$deployResourceTypesMatch = [regex]::Match(
    $deployScriptText,
    '(?s)\$allowedCloudFormationResourceTypes\s*=\s*@\((?<Body>.*?)\)'
)
Assert-Contract $deployResourceTypesMatch.Success '배포 스크립트의 CloudFormation 자원 형식 배열을 찾지 못했습니다.'
$deployResourceTypes = @(
    [regex]::Matches($deployResourceTypesMatch.Groups['Body'].Value, "'(AWS::[A-Za-z0-9:]+)'") |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
)
Assert-Contract (Test-ExactSet -Actual $deployResourceTypes -Expected $allowedResourceTypes) '배포 스크립트와 정책의 CloudFormation 자원 형식 목록이 다릅니다.'
Assert-Contract ($deployScriptText -match "(?s)\[ValidateSet\('qfieldcloud-lab-pilot'\)\]\s*\[string\]\`$StackName") '배포 스크립트의 StackName이 고정되지 않았습니다.'
Assert-Contract ($deployScriptText -match "(?s)\[ValidateSet\('qfieldcloud-lab-pilot'\)\]\s*\[string\]\`$InstanceName") '배포 스크립트의 InstanceName이 고정되지 않았습니다.'
Assert-Contract ($testScriptText -match "(?s)\[ValidateSet\('qfieldcloud-lab-pilot'\)\]\s*\[string\]\`$StackName") '검증 스크립트의 StackName이 고정되지 않았습니다.'
Assert-Contract ($deployScriptText.Contains("`$releaseManifestPath = 'config/qfieldcloud-v26.25.env'")) '배포 전 릴리스 manifest 경로가 고정되지 않았습니다.'
Assert-Contract ($deployScriptText.Contains("`$qfieldCloudRawBase = 'https://raw.githubusercontent.com/opengisch/QFieldCloud'")) '공식 QFieldCloud raw source가 고정되지 않았습니다.'
Assert-Contract ($deployScriptText.Contains('function Get-PinnedHttpsBytes')) '배포 스크립트가 원격 파일의 원본 바이트를 읽지 않습니다.'
Assert-Contract ($deployScriptText.Contains('-Name QFIELDCLOUD_DHPARAM_SHA256')) '배포 스크립트가 DH parameters 고정값을 읽지 않습니다.'
Assert-Contract ($deployScriptText.Contains("-Artifact upstream-dhparams")) '배포 스크립트가 공식 DH parameters를 배포 전에 확인하지 않습니다.'
Assert-Contract ($deployScriptText.Contains("UpstreamDhparams               = 'official-commit-bytes-verified'")) '배포 계획에 공식 DH parameters 검증 결과가 없습니다.'

Write-Host 'IAM 정책 정적 계약을 확인했습니다. AWS API는 호출하지 않았습니다.'
