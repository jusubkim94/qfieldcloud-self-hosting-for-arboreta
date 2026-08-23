#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 64)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$SourceProfile,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]{12}$')]
    [string]$ExpectedAccountId,

    [AllowEmptyString()]
    [ValidateLength(0, 64)]
    [ValidatePattern('^(?:[A-Za-z0-9_-]+)?$')]
    [string]$RoleProfile = '',

    [ValidatePattern('^ap-northeast-2[a-d]$')]
    [string]$AvailabilityZone = 'ap-northeast-2a',

    [bool]$EnableAutomaticSnapshots = $true,

    [bool]$EnableAlarms = $true,

    [bool]$Authenticate = $true,

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$region = 'ap-northeast-2'
$deploymentRoleName = 'QFieldCloudLabDeployer'
$deploymentRolePath = '/qfieldcloud-lab/'
$allowedRoleProfileKeys = @(
    'duration_seconds'
    'region'
    'role_arn'
    'role_session_name'
    'source_profile'
)
$blockedEnvironmentVariables = @(
    'AWS_ACCESS_KEY_ID'
    'AWS_CONTAINER_AUTHORIZATION_TOKEN'
    'AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE'
    'AWS_CONTAINER_CREDENTIALS_FULL_URI'
    'AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'
    'AWS_ROLE_ARN'
    'AWS_ROLE_SESSION_NAME'
    'AWS_SECRET_ACCESS_KEY'
    'AWS_SECURITY_TOKEN'
    'AWS_SESSION_TOKEN'
    'AWS_WEB_IDENTITY_TOKEN_FILE'
)

function Get-AwsExecutable {
    $command = Get-Command aws -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        $candidate = $command.Source
    }
    else {
        $localApplicationData = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::LocalApplicationData
        )
        $candidate = Join-Path $localApplicationData 'Programs\Amazon\AWSCLIV2\aws.exe'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw 'AWS CLI v2를 찾지 못했습니다.'
        }
    }

    $candidate = [System.IO.Path]::GetFullPath($candidate)
    if ($IsWindows) {
        if ([System.IO.Path]::GetExtension($candidate) -cne '.exe') {
            throw 'Windows에서는 서명된 AWS CLI 실행 파일만 사용할 수 있습니다.'
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $candidate
        $signerName = if ($signature.SignerCertificate) {
            $signature.SignerCertificate.GetNameInfo(
                [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
                $false
            )
        }
        else {
            ''
        }
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            $signerName -cne 'Amazon Web Services, Inc.') {
            throw 'AWS CLI 실행 파일의 Amazon Web Services 서명을 확인하지 못했습니다.'
        }
    }

    $version = & $candidate --version 2>&1
    if ($LASTEXITCODE -ne 0 -or ($version -join ' ') -notmatch '^aws-cli/2\.') {
        throw '공식 AWS CLI v2가 필요합니다.'
    }
    return $candidate
}

function Assert-NoAwsOverride {
    foreach ($name in $script:blockedEnvironmentVariables) {
        if (-not [string]::IsNullOrWhiteSpace(
            [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        )) {
            throw 'AWS 자격증명 환경변수를 제거한 뒤 다시 실행하세요.'
        }
    }
    foreach ($name in [Environment]::GetEnvironmentVariables().Keys) {
        $environmentName = [string]$name
        if ($environmentName.Equals('AWS_ENDPOINT_URL', [StringComparison]::OrdinalIgnoreCase) -or
            $environmentName.StartsWith('AWS_ENDPOINT_URL_', [StringComparison]::OrdinalIgnoreCase)) {
            throw '사용자 지정 AWS endpoint 환경변수는 허용되지 않습니다.'
        }
    }
}

function ConvertTo-AbsoluteAwsProfileFileOverrides {
    $location = Get-Location
    if ($location.Provider.Name -cne 'FileSystem') {
        throw 'AWS 프로필 경로를 고정하려면 파일 시스템 폴더에서 실행해야 합니다.'
    }
    $basePath = [System.IO.Path]::GetFullPath($location.ProviderPath)
    foreach ($name in @('AWS_CONFIG_FILE', 'AWS_SHARED_CREDENTIALS_FILE')) {
        $value = [Environment]::GetEnvironmentVariable(
            $name,
            [EnvironmentVariableTarget]::Process
        )
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        $absolutePath = if ([System.IO.Path]::IsPathFullyQualified($value)) {
            [System.IO.Path]::GetFullPath($value)
        }
        else {
            [System.IO.Path]::GetFullPath((Join-Path $basePath $value))
        }
        [Environment]::SetEnvironmentVariable(
            $name,
            $absolutePath,
            [EnvironmentVariableTarget]::Process
        )
    }
}

function Get-AwsProfileFileSection {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Config', 'Credentials')]
        [string]$FileKind
    )

    $userDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($userDirectory)) {
        throw 'AWS 프로필 파일 위치를 확인하지 못했습니다.'
    }
    if ($FileKind -eq 'Config') {
        $override = [Environment]::GetEnvironmentVariable('AWS_CONFIG_FILE')
        $leaf = 'config'
        $sectionName = if ($ProfileName -eq 'default') { 'default' } else { "profile $ProfileName" }
    }
    else {
        $override = [Environment]::GetEnvironmentVariable('AWS_SHARED_CREDENTIALS_FILE')
        $leaf = 'credentials'
        $sectionName = $ProfileName
    }
    $path = if ([string]::IsNullOrWhiteSpace($override)) {
        Join-Path (Join-Path $userDirectory '.aws') $leaf
    }
    else {
        [System.IO.Path]::GetFullPath($override)
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Values = [ordered]@{} }
    }

    $inside = $false
    $sectionCount = 0
    $values = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $path) {
        $sectionMatch = [regex]::Match([string]$line, '^\s*\[([^\]]+)\]\s*(?:[;#].*)?$')
        if ($sectionMatch.Success) {
            $inside = $sectionMatch.Groups[1].Value -ceq $sectionName
            if ($inside) { $sectionCount++ }
            continue
        }
        if (-not $inside -or [string]::IsNullOrWhiteSpace([string]$line) -or
            [string]$line -match '^\s*[;#]') {
            continue
        }
        $settingMatch = [regex]::Match([string]$line, '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$')
        if (-not $settingMatch.Success) {
            throw 'AWS 프로필에 안전하게 해석할 수 없는 설정이 있습니다.'
        }
        $key = $settingMatch.Groups[1].Value.ToLowerInvariant()
        if ($values.Contains($key)) {
            throw 'AWS 프로필에 중복 설정이 있습니다.'
        }
        $values[$key] = $settingMatch.Groups[2].Value
    }
    if ($sectionCount -gt 1) {
        throw 'AWS 프로필 섹션이 두 번 이상 정의되어 있습니다.'
    }
    return [pscustomobject]@{ Exists = $sectionCount -eq 1; Values = $values }
}

function Assert-ExactKeys {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Values,

        [Parameter(Mandatory = $true)]
        [string[]]$Allowed,

        [Parameter(Mandatory = $true)]
        [string[]]$Required
    )

    $actual = @($Values.Keys | ForEach-Object { [string]$_ })
    if (@($actual | Where-Object { $_ -notin $Allowed }).Count -gt 0 -or
        @($Required | Where-Object { $_ -notin $actual }).Count -gt 0) {
        throw 'AWS 프로필의 허용 설정 또는 필수 설정 계약이 맞지 않습니다.'
    }
}

function Assert-NoCredentialsSection {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ProfileName
    )

    $section = Get-AwsProfileFileSection -ProfileName $ProfileName -FileKind Credentials
    if ($section.Exists -and @($section.Values.Keys).Count -gt 0) {
        throw '고정 접근키가 있는 shared credentials 프로필은 사용할 수 없습니다.'
    }
}

function Get-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ProfileName
    )

    $raw = & $script:awsExecutable @Arguments `
        --profile $ProfileName --region $script:region --no-cli-pager --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'AWS 임시 세션 확인에 실패했습니다. 로그인 상태와 권한을 확인하세요.'
    }
    return (($raw -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Get-SourceContract {
    Assert-NoCredentialsSection -ProfileName $SourceProfile
    $section = Get-AwsProfileFileSection -ProfileName $SourceProfile -FileKind Config
    if (-not $section.Exists) {
        throw '원본 AWS 프로필을 찾지 못했습니다.'
    }
    $hasLogin = $section.Values.Contains('login_session')
    $hasSso = $section.Values.Contains('sso_session')
    if ($hasLogin -eq $hasSso) {
        throw '원본 프로필에는 aws login 또는 IAM Identity Center 설정 중 하나만 있어야 합니다.'
    }
    if ($hasLogin) {
        Assert-ExactKeys -Values $section.Values `
            -Allowed @('login_session', 'output', 'region') `
            -Required @('login_session', 'region')
        $loginArn = [string]$section.Values['login_session']
        $loginArnMatch = [regex]::Match(
            $loginArn,
            '^arn:aws:iam::([0-9]{12}):user/.+$'
        )
        if (-not $loginArnMatch.Success -or
            $loginArnMatch.Groups[1].Value -cne $ExpectedAccountId -or
            [string]$section.Values['region'] -cne $region) {
            throw 'aws login 원본 프로필이 지정 계정의 서울 리전 IAM 사용자와 다릅니다.'
        }
        return [pscustomobject]@{ Kind = 'login'; LoginArn = $loginArn }
    }

    Assert-ExactKeys -Values $section.Values `
        -Allowed @('output', 'region', 'sso_account_id', 'sso_role_name', 'sso_session') `
        -Required @('region', 'sso_account_id', 'sso_role_name', 'sso_session')
    if ([string]$section.Values['sso_account_id'] -cne $ExpectedAccountId -or
        [string]$section.Values['region'] -cne $region -or
        [string]::IsNullOrWhiteSpace([string]$section.Values['sso_role_name'])) {
        throw 'IAM Identity Center 원본 프로필이 지정 계정의 서울 리전 설정과 다릅니다.'
    }
    return [pscustomobject]@{ Kind = 'sso'; LoginArn = '' }
}

function Set-RoleProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedRoleArn
    )

    Assert-NoCredentialsSection -ProfileName $RoleProfile
    $section = Get-AwsProfileFileSection -ProfileName $RoleProfile -FileKind Config
    $sessionName = if ($section.Exists -and $section.Values.Contains('role_session_name')) {
        [string]$section.Values['role_session_name']
    }
    else {
        $randomBytes = [byte[]]::new(8)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($randomBytes)
        'qfc-lab-' + ([Convert]::ToHexString($randomBytes)).ToLowerInvariant()
    }
    if ($sessionName -notmatch '^qfc-lab-[0-9a-f]{16}$') {
        throw '기존 배포 역할 프로필의 세션 이름이 안전한 고정 형식과 다릅니다.'
    }

    $settings = [ordered]@{
        role_arn          = $ExpectedRoleArn
        source_profile    = $SourceProfile
        role_session_name = $sessionName
        duration_seconds  = '3600'
        region            = $region
    }
    if ($section.Exists) {
        $unexpectedKeys = @(
            $section.Values.Keys | Where-Object { [string]$_ -notin $script:allowedRoleProfileKeys }
        )
        if ($unexpectedKeys.Count -gt 0) {
            throw '기존 배포 역할 프로필에 허용되지 않은 설정이 있습니다.'
        }
        foreach ($key in $section.Values.Keys) {
            if ([string]$section.Values[[string]$key] -cne [string]$settings[[string]$key]) {
                throw '기존 배포 역할 프로필이 고정 역할·원본·1시간 세션·서울 리전 계약과 다릅니다.'
            }
        }
    }

    foreach ($entry in $settings.GetEnumerator()) {
        if (-not $section.Exists -or -not $section.Values.Contains([string]$entry.Key)) {
            $result = & $script:awsExecutable configure set $entry.Key $entry.Value `
                --profile $RoleProfile 2>&1
            if ($LASTEXITCODE -ne 0) {
                $null = $result
                throw '비밀값이 없는 배포 역할 프로필 설정을 저장하지 못했습니다. 다시 실행하면 안전하게 이어서 복구합니다.'
            }
        }
    }
    $section = Get-AwsProfileFileSection -ProfileName $RoleProfile -FileKind Config

    Assert-ExactKeys -Values $section.Values `
        -Allowed $script:allowedRoleProfileKeys `
        -Required $script:allowedRoleProfileKeys
    if ([string]$section.Values['role_arn'] -cne $ExpectedRoleArn -or
        [string]$section.Values['source_profile'] -cne $SourceProfile -or
        [string]$section.Values['role_session_name'] -cne $sessionName -or
        [string]$section.Values['duration_seconds'] -cne '3600' -or
        [string]$section.Values['region'] -cne $region -or
        $sessionName -notmatch '^qfc-lab-[0-9a-f]{16}$') {
        throw '기존 배포 역할 프로필이 고정 역할·원본·1시간 세션·서울 리전 계약과 다릅니다.'
    }
    return $sessionName
}

if ([string]::IsNullOrWhiteSpace($RoleProfile)) {
    if ($SourceProfile.Length -le 55) {
        $RoleProfile = "$SourceProfile-qfc-role"
    }
    else {
        $sourceNameBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($SourceProfile)
        $sourceNameHashBytes = [System.Security.Cryptography.SHA256]::HashData($sourceNameBytes)
        $sourceNameHash = ([Convert]::ToHexString($sourceNameHashBytes)).ToLowerInvariant().Substring(0, 12)
        $RoleProfile = "qfc-$($SourceProfile.Substring(0, 40))-$sourceNameHash"
    }
}
if ($RoleProfile.Length -gt 64 -or $RoleProfile -notmatch '^[A-Za-z0-9_-]+$' -or
    $RoleProfile -ceq $SourceProfile) {
    throw '배포 역할 프로필 이름은 원본과 다른 64자 이하 영숫자·밑줄·하이픈이어야 합니다.'
}

$gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $gitCommand) {
    throw 'Git을 찾지 못했습니다.'
}
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$reportedRepositoryRoot = (& $gitCommand.Source -C $repositoryRoot rev-parse --show-toplevel 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($reportedRepositoryRoot)) {
    throw '이 설치 파일이 포함된 Git 저장소를 확인하지 못했습니다.'
}
$reportedRepositoryRoot = [System.IO.Path]::GetFullPath($reportedRepositoryRoot)
$pathComparison = if ($IsWindows) {
    [StringComparison]::OrdinalIgnoreCase
}
else {
    [StringComparison]::Ordinal
}
if (-not $reportedRepositoryRoot.Equals($repositoryRoot, $pathComparison)) {
    throw '설치 파일 위치와 Git 저장소 루트가 다릅니다.'
}
$deployScript = Join-Path $repositoryRoot 'scripts\lab-lightsail\Deploy-QFieldCloudPilot.ps1'
if (-not (Test-Path -LiteralPath $deployScript -PathType Leaf)) {
    throw '이 저장소의 검증된 배포 스크립트를 찾지 못했습니다.'
}
$pwshCommand = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $pwshCommand) {
    throw 'PowerShell 7 실행 파일을 찾지 못했습니다.'
}
$pwsh = $pwshCommand.Source

Write-Host '로컬 변경 안내: 로그인 캐시가 갱신될 수 있으며, 비밀값이 없는 1시간 배포 역할 프로필을 AWS config에 만들거나 복구합니다.'
Assert-NoAwsOverride
ConvertTo-AbsoluteAwsProfileFileOverrides
$awsExecutable = Get-AwsExecutable
$sourceContract = Get-SourceContract

if ($Authenticate) {
    $loginArguments = if ($sourceContract.Kind -eq 'login') {
        @('login', '--profile', $SourceProfile)
    }
    else {
        @('sso', 'login', '--profile', $SourceProfile)
    }
    $loginResult = & $awsExecutable @loginArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $null = $loginResult
        throw '브라우저 기반 AWS 임시 로그인을 완료하지 못했습니다.'
    }
}

$sourceIdentity = Get-AwsJson -Arguments @('sts', 'get-caller-identity') -ProfileName $SourceProfile
$sourceArn = [string]$sourceIdentity.Arn
if ([string]$sourceIdentity.Account -cne $ExpectedAccountId -or $sourceArn -match ':root$') {
    throw '원본 AWS 세션이 지정 계정의 비루트 임시 세션이 아닙니다.'
}
if ($sourceContract.Kind -eq 'login') {
    if ($sourceArn -cne $sourceContract.LoginArn) {
        throw 'aws login 세션 주체가 원본 프로필과 다릅니다.'
    }
}
elseif ($sourceArn -notmatch '^arn:aws:sts::[0-9]{12}:assumed-role/AWSReservedSSO_[^/]+/.+$') {
    throw 'IAM Identity Center 임시 역할 세션을 확인하지 못했습니다.'
}

$deploymentRoleArn = "arn:aws:iam::$ExpectedAccountId`:role$deploymentRolePath$deploymentRoleName"
$roleSessionName = Set-RoleProfile -ExpectedRoleArn $deploymentRoleArn
$roleIdentity = Get-AwsJson -Arguments @('sts', 'get-caller-identity') -ProfileName $RoleProfile
$expectedCallerArn = "arn:aws:sts::$ExpectedAccountId`:assumed-role/$deploymentRoleName/$roleSessionName"
if ([string]$roleIdentity.Account -cne $ExpectedAccountId -or
    [string]$roleIdentity.Arn -cne $expectedCallerArn) {
    throw '최종 AWS 세션이 고정 QFieldCloud 배포 역할과 다릅니다.'
}

$deployArguments = @(
    '-NoProfile', '-File', $deployScript,
    '-Profile', $RoleProfile,
    '-ExpectedAccountId', $ExpectedAccountId,
    '-ExpectedDeploymentRoleArn', $deploymentRoleArn,
    '-AvailabilityZone', $AvailabilityZone,
    "-EnableAutomaticSnapshots:$($EnableAutomaticSnapshots.ToString().ToLowerInvariant())",
    "-EnableAlarms:$($EnableAlarms.ToString().ToLowerInvariant())"
)

Push-Location -LiteralPath $repositoryRoot
try {
    $planOutput = @(& $pwsh @deployArguments 2>&1)
    $planExitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}
$planOutput | ForEach-Object { Write-Host ([string]$_) }
if ($planExitCode -ne 0) {
    throw '파일럿 배포 계획 검증이 실패했습니다.'
}
$receiptPattern = '(?m)^QFC_APPROVAL_RECEIPT_V1=([0-9a-f]{64}):([0-9a-f]{40})\r?$'
$receiptMatches = [regex]::Matches(($planOutput -join "`n"), $receiptPattern)
if ($receiptMatches.Count -ne 1) {
    throw '검토한 계획의 승인 식별값을 정확히 하나 확인하지 못했습니다.'
}
$approvedPlanSha256 = $receiptMatches[0].Groups[1].Value
$approvedCommitSha = $receiptMatches[0].Groups[2].Value
if (-not $Execute) {
    Write-Host '배포 역할 프로필과 파일럿 계획을 확인했습니다. AWS 자원은 만들지 않았습니다.'
    exit 0
}

$confirmation = 'DEPLOY QFIELDCLOUD LAB PILOT IN SEOUL AFTER REVIEWING COST AND FAILURE RISK'
$typed = Read-Host "계속하려면 정확히 '$confirmation' 를 입력하세요"
if ($typed -cne $confirmation) {
    throw '확인 문구가 달라 AWS 자원을 만들지 않았습니다.'
}

Push-Location -LiteralPath $repositoryRoot
try {
    & $pwsh @deployArguments `
        -ApprovedPlanSha256 $approvedPlanSha256 `
        -ApprovedCommitSha $approvedCommitSha `
        -Execute
    $deploymentExitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($deploymentExitCode -ne 0) {
    throw '파일럿 생성이 완료되지 않았습니다. 부분 자원이 과금될 수 있으며 자동 삭제하지 않습니다.'
}
Write-Host '검증된 배포 역할을 사용한 QFieldCloud 파일럿 생성이 완료되었습니다.'
