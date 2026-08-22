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

$deployer = Get-Content -Raw -LiteralPath $deployerPath | ConvertFrom-Json -Depth 100
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
    'lightsail:GetInstance'
    'lightsail:GetInstanceAccessDetails'
    'lightsail:GetInstances'
    'lightsail:GetInstanceState'
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

$managedInstanceStatement = @($deployer.Statement | Where-Object { $_.Sid -eq 'ManageTaggedPilotInstancesOnlyViaCloudFormation' })
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
$directStatement = @($deployer.Statement | Where-Object { $_.Sid -eq 'OperateOnlyTaggedQFieldCloudLabInstances' })
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

Write-Host 'IAM 정책 정적 계약을 확인했습니다. AWS API는 호출하지 않았습니다.'
