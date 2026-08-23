#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet('qfieldcloud-lab-pilot')]
    [string]$StackName = 'qfieldcloud-lab-pilot',

    [ValidateSet('qfieldcloud-lab-pilot')]
    [string]$InstanceName = 'qfieldcloud-lab-pilot',

    [ValidateSet('ap-northeast-2')]
    [string]$Region = 'ap-northeast-2',

    [ValidatePattern('^ap-northeast-2[a-d]$')]
    [string]$AvailabilityZone = 'ap-northeast-2a',

    [ValidateSet('lightsail-connect')]
    [string]$SshAccessMode = 'lightsail-connect',

    [bool]$EnableAutomaticSnapshots = $true,

    [bool]$EnableAlarms = $true,

    [ValidateSet('self-signed', 'letsencrypt-ip')]
    [string]$CertificateMode = 'self-signed',

    [switch]$AcceptLetsEncryptTerms,

    [ValidatePattern('^(?:[01][0-9]|2[0-3]):00$')]
    [string]$AutomaticSnapshotTimeUtc = '18:00',

    [ValidateRange(1, 100)]
    [int]$CpuAlarmThresholdPercent = 80,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Profile,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]{12}$')]
    [string]$ExpectedAccountId,

    [ValidatePattern('^arn:aws:iam::[0-9]{12}:role/qfieldcloud-lab/QFieldCloudLabDeployer$')]
    [string]$ExpectedDeploymentRoleArn,

    [AllowEmptyString()]
    [ValidatePattern('^(?:[0-9a-f]{40})?$')]
    [string]$ApprovedCommitSha = '',

    [AllowEmptyString()]
    [ValidatePattern('^(?:[0-9a-f]{64})?$')]
    [string]$ApprovedPlanSha256 = '',

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Execute -and
    ([string]::IsNullOrWhiteSpace($ApprovedCommitSha) -or
        [string]::IsNullOrWhiteSpace($ApprovedPlanSha256))) {
    throw '실행에는 먼저 검토한 Git commit과 계획 SHA-256이 모두 필요합니다.'
}
if (-not $Execute -and
    (-not [string]::IsNullOrWhiteSpace($ApprovedCommitSha) -or
        -not [string]::IsNullOrWhiteSpace($ApprovedPlanSha256))) {
    throw '승인 식별값은 -Execute 실행에서만 사용할 수 있습니다.'
}
if ($AcceptLetsEncryptTerms -and $CertificateMode -ne 'letsencrypt-ip') {
    throw '-AcceptLetsEncryptTerms는 -CertificateMode letsencrypt-ip와 함께만 사용하세요.'
}
if ($Execute -and $CertificateMode -eq 'letsencrypt-ip' -and -not $AcceptLetsEncryptTerms) {
    throw '공인 IPv4 인증서 발급 전 Lets Encrypt 이용약관 동의가 필요합니다. 검토 후 -AcceptLetsEncryptTerms를 추가하세요.'
}

$repositoryOwner = 'jusubkim94'
$repositoryName = 'qfieldcloud-self-hosting-for-arboreta'
$expectedOrigin = "https://github.com/$repositoryOwner/$repositoryName.git"
$bootstrapPath = 'scripts/lab-lightsail/bootstrap.sh'
$releaseManifestPath = 'config/qfieldcloud-v26.25.env'
$qfieldCloudRawBase = 'https://raw.githubusercontent.com/opengisch/QFieldCloud'
$blueprintId = 'ubuntu_24_04'
$bundleId = 'medium_3_0'
$snapshotStorageUsdPerGbMonth = [decimal]0.05
$allowedDeploymentRoleProfileKeys = @(
    'duration_seconds'
    'region'
    'role_arn'
    'role_session_name'
    'source_profile'
)
$blockedCredentialEnvironmentVariables = @(
    'AWS_ACCESS_KEY_ID'
    'AWS_CONTAINER_AUTHORIZATION_TOKEN'
    'AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE'
    'AWS_CONTAINER_CREDENTIALS_FULL_URI'
    'AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'
    'AWS_ENDPOINT_URL'
    'AWS_ENDPOINT_URL_CLOUDFORMATION'
    'AWS_ENDPOINT_URL_LIGHTSAIL'
    'AWS_ENDPOINT_URL_STS'
    'AWS_ROLE_ARN'
    'AWS_ROLE_SESSION_NAME'
    'AWS_SECRET_ACCESS_KEY'
    'AWS_SECURITY_TOKEN'
    'AWS_SESSION_TOKEN'
    'AWS_WEB_IDENTITY_TOKEN_FILE'
)
$allowedCloudFormationResourceTypes = @(
    'AWS::CloudFormation::WaitCondition'
    'AWS::CloudFormation::WaitConditionHandle'
    'AWS::Lightsail::Alarm'
    'AWS::Lightsail::Instance'
    'AWS::Lightsail::StaticIp'
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
        $perUserPath = Join-Path $localApplicationData 'Programs\Amazon\AWSCLIV2\aws.exe'
        if (-not (Test-Path -LiteralPath $perUserPath -PathType Leaf)) {
            throw 'AWS CLI v2를 찾지 못했습니다.'
        }
        $candidate = $perUserPath
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

    $versionOutput = & $candidate --version 2>&1
    if ($LASTEXITCODE -ne 0 -or ($versionOutput -join ' ') -notmatch '^aws-cli/2\.') {
        throw '이 설치 도구는 공식 AWS CLI v2가 필요합니다.'
    }
    return $candidate
}

function Get-GitExecutable {
    $command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) {
        throw 'Git을 찾지 못했습니다.'
    }
    return $command.Source
}

function Get-AwsBaseArguments {
    param(
        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ProfileName = $Profile
    )

    $arguments = @('--region', $Region, '--no-cli-pager')
    if ($ProfileName) {
        $arguments += @('--profile', $ProfileName)
    }
    return $arguments
}

function Get-AwsProfileSetting {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'duration_seconds', 'login_session', 'region', 'role_arn', 'role_session_name',
            'source_profile', 'sso_account_id', 'sso_role_name', 'sso_session'
        )]
        [string]$Name,

        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ProfileName = $Profile
    )

    $setting = & $script:awsExecutable configure get $Name --profile $ProfileName 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }
    return (($setting -join [Environment]::NewLine).Trim())
}

function Get-AwsResolvedCredentialType {
    param(
        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ProfileName = $Profile
    )

    $configuration = & $script:awsExecutable configure list --profile $ProfileName 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'AWS 프로필의 자격증명 출처를 확인하지 못했습니다.'
    }
    $accessKeyLines = @(
        $configuration | Where-Object {
            $_ -match '^\s*access_key(?:\s*:\s*|\s+)'
        }
    )
    if ($accessKeyLines.Count -ne 1) {
        throw 'AWS 프로필의 자격증명 출처가 하나로 확인되지 않았습니다.'
    }
    $accessKeyLine = [string]$accessKeyLines[0]
    if ($accessKeyLine -match '^\s*access_key\s*:') {
        $typeMatch = [regex]::Match(
            $accessKeyLine,
            '^\s*access_key\s*:\s*\S+\s*:\s*([A-Za-z0-9_-]+)\s*(?::.*)?$'
        )
    }
    else {
        $typeMatch = [regex]::Match(
            $accessKeyLine,
            '^\s*access_key\s+\S+\s+([A-Za-z0-9_-]+)(?:\s+.*)?$'
        )
    }
    if (-not $typeMatch.Success) {
        throw 'AWS 프로필의 자격증명 유형을 안전하게 해석하지 못했습니다.'
    }
    return $typeMatch.Groups[1].Value
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ProfileName = $Profile
    )

    $allArguments = @($Arguments) + (Get-AwsBaseArguments -ProfileName $ProfileName) + @('--output', 'json')
    $rawResult = & $script:awsExecutable @allArguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'AWS 읽기 전용 사전 확인에 실패했습니다. 로그인, 리전, 권한을 확인하세요.'
    }

    $jsonText = ($rawResult -join [Environment]::NewLine)
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return $null
    }
    return ($jsonText | ConvertFrom-Json)
}

function Assert-NoCredentialEnvironmentOverride {
    foreach ($name in $script:blockedCredentialEnvironmentVariables) {
        if (-not [string]::IsNullOrWhiteSpace(
            [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        )) {
            throw 'AWS 임시 프로필과 함께 환경변수 자격증명 또는 endpoint를 사용할 수 없습니다. 해당 환경변수를 제거하세요.'
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

function Get-AwsProfileFileSection {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Config', 'Credentials')]
        [string]$FileKind
    )

    $userProfileDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($userProfileDirectory)) {
        throw 'AWS 프로필 파일의 기본 위치를 확인하지 못했습니다.'
    }

    if ($FileKind -eq 'Config') {
        $overridePath = [Environment]::GetEnvironmentVariable(
            'AWS_CONFIG_FILE',
            [EnvironmentVariableTarget]::Process
        )
        $defaultLeafName = 'config'
        $sectionName = if ($ProfileName -eq 'default') { 'default' } else { "profile $ProfileName" }
    }
    else {
        $overridePath = [Environment]::GetEnvironmentVariable(
            'AWS_SHARED_CREDENTIALS_FILE',
            [EnvironmentVariableTarget]::Process
        )
        $defaultLeafName = 'credentials'
        $sectionName = $ProfileName
    }

    $filePath = if ([string]::IsNullOrWhiteSpace($overridePath)) {
        Join-Path (Join-Path $userProfileDirectory '.aws') $defaultLeafName
    }
    else {
        [System.IO.Path]::GetFullPath($overridePath)
    }
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Values = [ordered]@{}
        }
    }

    $values = [ordered]@{}
    $insideTargetSection = $false
    $matchingSectionCount = 0
    foreach ($line in Get-Content -LiteralPath $filePath) {
        $sectionMatch = [regex]::Match(
            [string]$line,
            '^\s*\[([^\]]+)\]\s*(?:[;#].*)?$'
        )
        if ($sectionMatch.Success) {
            $insideTargetSection = $sectionMatch.Groups[1].Value -ceq $sectionName
            if ($insideTargetSection) {
                $matchingSectionCount++
            }
            continue
        }
        if (-not $insideTargetSection -or
            [string]::IsNullOrWhiteSpace([string]$line) -or
            [string]$line -match '^\s*[;#]') {
            continue
        }

        $settingMatch = [regex]::Match(
            [string]$line,
            '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$'
        )
        if (-not $settingMatch.Success) {
            throw 'AWS 프로필 섹션에 안전하게 해석할 수 없는 설정이 있습니다.'
        }
        $key = $settingMatch.Groups[1].Value.ToLowerInvariant()
        if ($values.Contains($key)) {
            throw 'AWS 프로필 섹션에 중복 설정이 있습니다.'
        }
        $values[$key] = $settingMatch.Groups[2].Value
    }
    if ($matchingSectionCount -gt 1) {
        throw 'AWS 프로필 섹션이 두 번 이상 정의되어 있습니다.'
    }

    return [pscustomobject]@{
        Exists = $matchingSectionCount -eq 1
        Values = $values
    }
}

function Assert-NoStaticCredentialProfile {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ProfileName
    )

    $credentialSection = Get-AwsProfileFileSection `
        -ProfileName $ProfileName `
        -FileKind Credentials
    if ($credentialSection.Exists -and @($credentialSection.Values.Keys).Count -gt 0) {
        throw '역할 체인에 사용하는 프로필에는 shared credentials 파일의 고정 자격증명을 둘 수 없습니다.'
    }
}

function Assert-AllowedProfileKeys {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Values,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedKeys,

        [Parameter(Mandatory = $true)]
        [string[]]$RequiredKeys
    )

    $actualKeys = @($Values.Keys | ForEach-Object { [string]$_ })
    if (@($actualKeys | Where-Object { $_ -notin $AllowedKeys }).Count -gt 0 -or
        @($RequiredKeys | Where-Object { $_ -notin $actualKeys }).Count -gt 0) {
        throw 'AWS 프로필에 허용되지 않은 설정이 있거나 필수 설정이 없습니다.'
    }
}

function Get-TemporaryBrowserSourceProfileContract {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ProfileName
    )

    Assert-NoStaticCredentialProfile -ProfileName $ProfileName
    $section = Get-AwsProfileFileSection -ProfileName $ProfileName -FileKind Config
    if (-not $section.Exists) {
        throw '역할 원본 AWS 프로필 설정을 찾지 못했습니다.'
    }

    $hasLogin = $section.Values.Contains('login_session')
    $hasSso = $section.Values.Contains('sso_session')
    if ($hasLogin -eq $hasSso) {
        throw '역할 원본 프로필에는 aws login 또는 IAM Identity Center 설정 중 정확히 하나가 있어야 합니다.'
    }
    if ($hasLogin) {
        Assert-AllowedProfileKeys `
            -Values $section.Values `
            -AllowedKeys @('login_session', 'output', 'region') `
            -RequiredKeys @('login_session', 'region')
        $loginSession = [string]$section.Values['login_session']
        $loginSessionMatch = [regex]::Match(
            $loginSession,
            '^arn:aws:iam::([0-9]{12}):user/.+$'
        )
        if (-not $loginSessionMatch.Success -or
            $loginSessionMatch.Groups[1].Value -ne $ExpectedAccountId -or
            [string]$section.Values['region'] -cne $Region -or
            (Get-AwsResolvedCredentialType -ProfileName $ProfileName) -ne 'login') {
            throw '역할 원본 aws login 프로필을 지정 계정의 임시 IAM 사용자 세션으로 확인하지 못했습니다.'
        }
        return [pscustomobject]@{
            Kind         = 'login'
            LoginSession = $loginSession
            ProfileName  = $ProfileName
        }
    }

    Assert-AllowedProfileKeys `
        -Values $section.Values `
        -AllowedKeys @('output', 'region', 'sso_account_id', 'sso_role_name', 'sso_session') `
        -RequiredKeys @('region', 'sso_account_id', 'sso_role_name', 'sso_session')
    if ([string]$section.Values['sso_account_id'] -cne $ExpectedAccountId -or
        [string]$section.Values['region'] -cne $Region -or
        [string]::IsNullOrWhiteSpace([string]$section.Values['sso_role_name']) -or
        (Get-AwsResolvedCredentialType -ProfileName $ProfileName) -ne 'sso') {
        throw '역할 원본 IAM Identity Center 프로필을 지정 계정의 임시 SSO 세션으로 확인하지 못했습니다.'
    }
    return [pscustomobject]@{
        Kind         = 'sso'
        LoginSession = ''
        ProfileName  = $ProfileName
    }
}

function Get-DeploymentRoleProfileContract {
    Assert-NoCredentialEnvironmentOverride
    Assert-NoStaticCredentialProfile -ProfileName $Profile

    $expectedRoleMatch = [regex]::Match(
        $ExpectedDeploymentRoleArn,
        '^arn:aws:iam::([0-9]{12}):role/qfieldcloud-lab/QFieldCloudLabDeployer$'
    )
    if (-not $expectedRoleMatch.Success -or
        $expectedRoleMatch.Groups[1].Value -ne $ExpectedAccountId) {
        throw '배포 역할 ARN이 지정 계정의 고정 QFieldCloud 배포 역할과 다릅니다.'
    }

    $section = Get-AwsProfileFileSection -ProfileName $Profile -FileKind Config
    if (-not $section.Exists) {
        throw '배포 역할 AWS 프로필 설정을 찾지 못했습니다.'
    }
    Assert-AllowedProfileKeys `
        -Values $section.Values `
        -AllowedKeys $script:allowedDeploymentRoleProfileKeys `
        -RequiredKeys $script:allowedDeploymentRoleProfileKeys

    $sourceProfile = [string]$section.Values['source_profile']
    $roleSessionName = [string]$section.Values['role_session_name']
    if ([string]$section.Values['role_arn'] -cne $ExpectedDeploymentRoleArn -or
        $sourceProfile -notmatch '^[A-Za-z0-9_-]+$' -or
        $sourceProfile -ceq $Profile -or
        $roleSessionName -notmatch '^[A-Za-z0-9_=,.@-]{2,64}$' -or
        [string]$section.Values['duration_seconds'] -cne '3600' -or
        [string]$section.Values['region'] -cne $Region -or
        (Get-AwsResolvedCredentialType -ProfileName $Profile) -ne 'assume-role') {
        throw '배포 역할 프로필이 고정 역할, 원본, 세션 이름, 1시간 갱신 또는 서울 리전 계약과 다릅니다.'
    }

    $sourceContract = Get-TemporaryBrowserSourceProfileContract -ProfileName $sourceProfile
    return [pscustomobject]@{
        RoleSessionName = $roleSessionName
        Source           = $sourceContract
    }
}

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha256.ComputeHash($Bytes))).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-ApprovalPlanSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Plan,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9]{12}$')]
        [string]$TargetAccountId
    )

    $contract = [ordered]@{
        TargetAccountId = $TargetAccountId
    }
    foreach ($entry in $Plan.GetEnumerator()) {
        $contract[[string]$entry.Key] = $entry.Value
    }
    $json = $contract | ConvertTo-Json -Depth 5 -Compress
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    return Get-Sha256Hex -Bytes $bytes
}

function Get-PinnedHttpsBytes {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^https://[A-Za-z0-9./_-]+$')]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2097152)]
        [int]$MaximumBytes,

        [Parameter(Mandatory = $true)]
        [ValidateSet('bootstrap', 'upstream-dhparams')]
        [string]$Artifact
    )

    $httpClient = [System.Net.Http.HttpClient]::new()
    try {
        $httpClient.Timeout = [TimeSpan]::FromSeconds(60)
        try {
            $bytes = $httpClient.GetByteArrayAsync($Uri).GetAwaiter().GetResult()
        }
        catch {
            throw "고정된 $Artifact 파일을 HTTPS로 내려받지 못했습니다."
        }
        if ($null -eq $bytes -or $bytes.Length -lt 1 -or $bytes.Length -gt $MaximumBytes) {
            throw "고정된 $Artifact 파일 크기가 허용 범위를 벗어났습니다."
        }
        return [byte[]]$bytes
    }
    finally {
        $httpClient.Dispose()
    }
}

function Get-ReleaseManifestValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Lines,

        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'QFIELDCLOUD_COMMIT', 'QFIELDCLOUD_DHPARAM_SHA256',
            'CERTBOT_IMAGE', 'CERTBOT_EXPECTED_VERSION',
            'LETSENCRYPT_ACME_DIRECTORY', 'LETSENCRYPT_CERTIFICATE_PROFILE'
        )]
        [string]$Name
    )

    $matches = @(
        $Lines | Where-Object { $_ -match ('^' + [regex]::Escape($Name) + '=') }
    )
    if ($matches.Count -ne 1) {
        throw "릴리스 manifest의 $Name 값이 정확히 하나가 아닙니다."
    }
    return ([string]$matches[0]).Substring($Name.Length + 1)
}

function Test-StackExists {
    $arguments = @(
        'cloudformation', 'describe-stacks',
        '--stack-name', $StackName
    ) + (Get-AwsBaseArguments) + @('--output', 'json')

    $result = & $script:awsExecutable @arguments 2>&1
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    if (($result -join ' ') -match 'does not exist') {
        return $false
    }
    throw '기존 CloudFormation 스택 확인에 실패했습니다. 권한과 스택 이름을 확인하세요.'
}

$awsExecutable = Get-AwsExecutable
Assert-NoCredentialEnvironmentOverride
$deploymentRoleContract = $null
$loginSession = ''
$ssoSession = ''
if (-not [string]::IsNullOrWhiteSpace($ExpectedDeploymentRoleArn)) {
    $deploymentRoleContract = Get-DeploymentRoleProfileContract
    $resolvedCredentialType = 'assume-role'
}
else {
    $directSourceContract = Get-TemporaryBrowserSourceProfileContract -ProfileName $Profile
    if ($directSourceContract.Kind -eq 'login') {
        $loginSession = $directSourceContract.LoginSession
        $resolvedCredentialType = 'login'
    }
    else {
        $ssoSession = 'configured'
        $resolvedCredentialType = 'sso'
    }
}
$gitExecutable = Get-GitExecutable
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$reportedRepositoryRoot = (& $gitExecutable -C $repositoryRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($reportedRepositoryRoot)) {
    throw '이 배포 파일이 포함된 Git 저장소를 확인하지 못했습니다.'
}
$reportedRepositoryRoot = [System.IO.Path]::GetFullPath($reportedRepositoryRoot.Trim())
$pathComparison = if ($IsWindows) {
    [StringComparison]::OrdinalIgnoreCase
}
else {
    [StringComparison]::Ordinal
}
if (-not $reportedRepositoryRoot.Equals($repositoryRoot, $pathComparison)) {
    throw '배포 파일 위치와 Git 저장소 루트가 다릅니다.'
}

$origin = (& $gitExecutable -C $repositoryRoot remote get-url origin 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -ne $expectedOrigin) {
    throw "origin이 예상 공개 저장소와 다릅니다: $expectedOrigin"
}

$workingTreeState = & $gitExecutable -C $repositoryRoot status --porcelain=v1
if ($LASTEXITCODE -ne 0) {
    throw 'Git 작업 상태를 확인하지 못했습니다.'
}
if ($workingTreeState) {
    throw '배포 전에 변경사항을 커밋하고 Push해야 합니다. 현재 작업 폴더가 깨끗하지 않습니다.'
}

$bootstrapRevision = (& $gitExecutable -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $bootstrapRevision -notmatch '^[0-9a-f]{40}$') {
    throw '현재 Git commit을 40자리 SHA로 확인하지 못했습니다.'
}
if ($Execute -and $bootstrapRevision -cne $ApprovedCommitSha) {
    throw '검토한 Git commit과 현재 commit이 달라 생성하지 않습니다. 새 계획을 다시 검토하세요.'
}

$bootstrapFile = Join-Path $repositoryRoot ($bootstrapPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
$templateFile = Join-Path $repositoryRoot 'infra\lab-lightsail\template.yaml'
$releaseManifestFile = Join-Path $repositoryRoot ($releaseManifestPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $bootstrapFile -PathType Leaf) -or
    -not (Test-Path -LiteralPath $templateFile -PathType Leaf) -or
    -not (Test-Path -LiteralPath $releaseManifestFile -PathType Leaf)) {
    throw '부트스트랩, 릴리스 manifest 또는 CloudFormation 템플릿 파일이 없습니다.'
}

$bootstrapBytes = [System.IO.File]::ReadAllBytes($bootstrapFile)
$templateBytes = [System.IO.File]::ReadAllBytes($templateFile)
$releaseManifestBytes = [System.IO.File]::ReadAllBytes($releaseManifestFile)
$bootstrapSha256 = Get-Sha256Hex -Bytes $bootstrapBytes
$templateSha256 = Get-Sha256Hex -Bytes $templateBytes
$releaseManifestSha256 = Get-Sha256Hex -Bytes $releaseManifestBytes
$rawUrl = "https://raw.githubusercontent.com/$repositoryOwner/$repositoryName/$bootstrapRevision/$bootstrapPath"
$remoteBytes = Get-PinnedHttpsBytes `
    -Uri $rawUrl `
    -MaximumBytes 2097152 `
    -Artifact bootstrap
$remoteSha256 = Get-Sha256Hex -Bytes $remoteBytes
if ($remoteSha256 -ne $bootstrapSha256) {
    throw '공개 GitHub의 부트스트랩과 로컬 commit 파일의 SHA-256이 다릅니다.'
}

$releaseManifestLines = @(Get-Content -LiteralPath $releaseManifestFile)
$qfieldCloudCommit = Get-ReleaseManifestValue `
    -Lines $releaseManifestLines `
    -Name QFIELDCLOUD_COMMIT
$expectedDhparamsSha256 = Get-ReleaseManifestValue `
    -Lines $releaseManifestLines `
    -Name QFIELDCLOUD_DHPARAM_SHA256
$certbotImage = Get-ReleaseManifestValue `
    -Lines $releaseManifestLines `
    -Name CERTBOT_IMAGE
$certbotExpectedVersion = Get-ReleaseManifestValue `
    -Lines $releaseManifestLines `
    -Name CERTBOT_EXPECTED_VERSION
$letsEncryptAcmeDirectory = Get-ReleaseManifestValue `
    -Lines $releaseManifestLines `
    -Name LETSENCRYPT_ACME_DIRECTORY
$letsEncryptCertificateProfile = Get-ReleaseManifestValue `
    -Lines $releaseManifestLines `
    -Name LETSENCRYPT_CERTIFICATE_PROFILE
if ($qfieldCloudCommit -notmatch '^[0-9a-f]{40}$' -or
    $expectedDhparamsSha256 -notmatch '^[0-9a-f]{64}$' -or
    $certbotImage -notmatch '^docker\.io/certbot/certbot@sha256:[0-9a-f]{64}$' -or
    $certbotExpectedVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
    $letsEncryptAcmeDirectory -cne 'https://acme-v02.api.letsencrypt.org/directory' -or
    $letsEncryptCertificateProfile -cne 'shortlived') {
    throw '릴리스 manifest의 QFieldCloud 또는 공인 인증서 고정 정보 형식이 잘못되었습니다.'
}
$dhparamsUrl = "$qfieldCloudRawBase/$qfieldCloudCommit/conf/nginx/dhparams/ssl-dhparams.pem"
$dhparamsBytes = Get-PinnedHttpsBytes `
    -Uri $dhparamsUrl `
    -MaximumBytes 16384 `
    -Artifact upstream-dhparams
$actualDhparamsSha256 = Get-Sha256Hex -Bytes $dhparamsBytes
if ($actualDhparamsSha256 -cne $expectedDhparamsSha256) {
    throw '공식 QFieldCloud commit의 DH parameters 바이트와 릴리스 manifest의 SHA-256이 다릅니다. AWS 자원은 만들지 않습니다.'
}

$identity = Invoke-AwsJson -Arguments @('sts', 'get-caller-identity')
$identityArn = [string]$identity.Arn
$identityAccount = [string]$identity.Account
if ($identityArn -match ':root$') {
    throw 'AWS 루트 사용자로는 자원을 만들지 않습니다. IAM Identity Center 또는 비루트 IAM 콘솔 사용자의 aws login 임시 세션으로 다시 로그인하세요.'
}
if ($identityAccount -ne $ExpectedAccountId) {
    throw '현재 AWS 세션의 계정이 사용자가 지정한 배포 대상 계정과 다릅니다.'
}
$principalType = ''
if ($null -ne $deploymentRoleContract) {
    $sourceIdentity = Invoke-AwsJson `
        -Arguments @('sts', 'get-caller-identity') `
        -ProfileName $deploymentRoleContract.Source.ProfileName
    $sourceIdentityArn = [string]$sourceIdentity.Arn
    $sourceIdentityAccount = [string]$sourceIdentity.Account
    if ($sourceIdentityArn -match ':root$' -or
        $sourceIdentityAccount -ne $ExpectedAccountId) {
        throw '배포 역할 원본 세션이 지정 계정의 비루트 임시 세션이 아닙니다.'
    }
    if ($deploymentRoleContract.Source.Kind -eq 'login') {
        if ($sourceIdentityArn -cne $deploymentRoleContract.Source.LoginSession) {
            throw '배포 역할 원본 aws login 주체가 프로필 설정과 다릅니다.'
        }
    }
    elseif ($sourceIdentityArn -notmatch '^arn:aws:sts::[0-9]{12}:assumed-role/AWSReservedSSO_[A-Za-z0-9+=,.@_-]+_[0-9A-Fa-f]{16}/.+$') {
        throw '배포 역할 원본 IAM Identity Center 주체를 임시 역할 세션으로 확인하지 못했습니다.'
    }

    $expectedCallerArn = "arn:aws:sts::$ExpectedAccountId`:assumed-role/QFieldCloudLabDeployer/$($deploymentRoleContract.RoleSessionName)"
    if ($resolvedCredentialType -ne 'assume-role' -or $identityArn -cne $expectedCallerArn) {
        throw '최종 AWS 주체가 승인된 QFieldCloud 배포 역할 세션과 다릅니다.'
    }
    $principalType = 'temporary-assumed-deployment-role'
}
elseif (-not [string]::IsNullOrWhiteSpace($loginSession)) {
    $loginSessionMatch = [regex]::Match(
        $loginSession,
        '^arn:aws:iam::([0-9]{12}):user/.+$'
    )
    if (-not $loginSessionMatch.Success -or
        $loginSessionMatch.Groups[1].Value -ne $ExpectedAccountId -or
        $identityArn -ne $loginSession -or
        $resolvedCredentialType -ne 'login') {
        throw 'aws login 프로필이 비루트 IAM 콘솔 사용자와 login 자격증명으로 확인되지 않았습니다.'
    }
    $principalType = 'temporary-console-login'
}
else {
    $ssoAccountId = Get-AwsProfileSetting -Name sso_account_id
    if ($resolvedCredentialType -ne 'sso' -or
        $ssoAccountId -ne $ExpectedAccountId -or
        $identityArn -notmatch '^arn:aws:sts::[0-9]{12}:assumed-role/AWSReservedSSO_[A-Za-z0-9+=,.@_-]+_[0-9A-Fa-f]{16}/.+$') {
        throw 'IAM Identity Center 프로필이 지정한 계정의 SSO 임시 역할 세션으로 확인되지 않았습니다.'
    }
    $principalType = 'temporary-identity-center-role'
}

$lightsailRegions = Invoke-AwsJson -Arguments @(
    'lightsail', 'get-regions', '--include-availability-zones'
)
$targetRegion = @($lightsailRegions.regions | Where-Object { $_.name -eq $Region })
if ($targetRegion.Count -ne 1) {
    throw "$Region Lightsail 리전을 확인하지 못했습니다."
}
$targetZone = @(
    $targetRegion[0].availabilityZones |
        Where-Object { $_.zoneName -eq $AvailabilityZone -and $_.state -eq 'available' }
)
if ($targetZone.Count -ne 1) {
    throw "$AvailabilityZone 가용 영역을 available 상태로 확인하지 못했습니다."
}

$blueprints = Invoke-AwsJson -Arguments @('lightsail', 'get-blueprints', '--include-inactive')
$blueprint = @($blueprints.blueprints | Where-Object { $_.blueprintId -eq $blueprintId })
if ($blueprint.Count -ne 1 -or -not [bool]$blueprint[0].isActive) {
    throw "$Region 리전에서 $blueprintId Lightsail blueprint를 활성 상태로 확인하지 못했습니다."
}

$bundles = Invoke-AwsJson -Arguments @('lightsail', 'get-bundles', '--include-inactive')
$bundle = @($bundles.bundles | Where-Object { $_.bundleId -eq $bundleId })
if ($bundle.Count -ne 1 -or -not [bool]$bundle[0].isActive) {
    throw "$Region 리전에서 $bundleId Lightsail bundle을 활성 상태로 확인하지 못했습니다."
}

$bundlePriceUsd = [decimal]$bundle[0].price
$diskSizeGb = [int]$bundle[0].diskSizeInGb
$snapshotEstimateHighUsd = if ($EnableAutomaticSnapshots) {
    [decimal]$diskSizeGb * $snapshotStorageUsdPerGbMonth * 7
}
else {
    [decimal]0
}
$estimatedLowUsd = $bundlePriceUsd
$estimatedHighUsd = $bundlePriceUsd + $snapshotEstimateHighUsd
if ($estimatedHighUsd -gt 100) {
    throw '보수적으로 계산한 기본 월 비용이 100 USD를 넘으므로 배포를 중단했습니다.'
}

$templateFullPath = [System.IO.Path]::GetFullPath($templateFile)
$templateUri = "file://$($templateFullPath.Replace([System.IO.Path]::DirectorySeparatorChar, '/'))"
$null = Invoke-AwsJson -Arguments @(
    'cloudformation', 'validate-template',
    '--template-body', $templateUri
)
$stackExists = Test-StackExists
$staticIpName = "$InstanceName-ip"
$lightsailInstances = Invoke-AwsJson -Arguments @('lightsail', 'get-instances')
$lightsailStaticIps = Invoke-AwsJson -Arguments @('lightsail', 'get-static-ips')
$instanceNameExists = @(
    $lightsailInstances.instances | Where-Object { $_.name -eq $InstanceName }
).Count -gt 0
$staticIpNameExists = @(
    $lightsailStaticIps.staticIps | Where-Object { $_.name -eq $staticIpName }
).Count -gt 0
$alarmNameConflict = $false
$expectedAlarmNames = @()
if ($EnableAlarms) {
    $lightsailAlarms = Invoke-AwsJson -Arguments @('lightsail', 'get-alarms')
    $expectedAlarmNames = @(
        "$StackName-status-check-failed",
        "$StackName-high-cpu"
    )
    $alarmNameConflict = @(
        $lightsailAlarms.alarms | Where-Object { $_.name -in $expectedAlarmNames }
    ).Count -gt 0
}
$physicalNameConflict = $instanceNameExists -or $staticIpNameExists -or $alarmNameConflict
$stackPolicy = '{"Statement":[{"Effect":"Deny","Action":"Update:*","Principal":"*","Resource":"*"}]}'

$approvalPlan = [ordered]@{
    ApprovalSchemaVersion          = 2
    Region                         = $Region
    AvailabilityZone               = $AvailabilityZone
    StackName                       = $StackName
    InstanceName                    = $InstanceName
    StaticIpName                    = $staticIpName
    AlarmNames                      = $expectedAlarmNames -join ','
    ExistingStack                  = $stackExists
    ExistingInstanceName           = $instanceNameExists
    ExistingStaticIpName           = $staticIpNameExists
    ExistingAlarmName              = $alarmNameConflict
    PrincipalType                  = $principalType
    DeploymentRole                 = if ($deploymentRoleContract) {
        'qfieldcloud-lab/QFieldCloudLabDeployer'
    }
    else {
        'legacy-direct-temporary-session'
    }
    AccountBinding                 = 'expected-account-verified'
    Blueprint                      = $blueprintId
    Bundle                         = $bundleId
    BundleMonthlyUsd               = $bundlePriceUsd
    RamGb                          = [decimal]$bundle[0].ramSizeInGb
    CpuCount                       = [int]$bundle[0].cpuCount
    DiskGb                         = $diskSizeGb
    IncludedTransferGb             = [int]$bundle[0].transferPerMonthInGb
    EstimatedMonthlyLowUsd         = $estimatedLowUsd
    EstimatedMonthlyHighUsd        = $estimatedHighUsd
    AutomaticSnapshots             = $EnableAutomaticSnapshots
    AutomaticSnapshotTimeUtc       = $AutomaticSnapshotTimeUtc
    Alarms                          = $EnableAlarms
    CpuAlarmThresholdPercent        = $CpuAlarmThresholdPercent
    SshAccessMode                   = $SshAccessMode
    CertificateMode                = $CertificateMode
    LetsEncryptTermsAccepted       = $AcceptLetsEncryptTerms.IsPresent
    CertificateEndpoint            = if ($CertificateMode -eq 'letsencrypt-ip') { 'static-ipv4' } else { 'ip-sslip-io' }
    CertificateLifetimeHours       = if ($CertificateMode -eq 'letsencrypt-ip') { 160 } else { 'self-signed-365-days' }
    CertificateRenewalCheck        = if ($CertificateMode -eq 'letsencrypt-ip') { 'six-hours-plus-random-delay' } else { 'not-configured' }
    CertificateAuthority           = if ($CertificateMode -eq 'letsencrypt-ip') { 'letsencrypt-external-dependency' } else { 'local-self-signed' }
    CertificateAwsCost             = 'no-additional-aws-resource'
    Http01ChallengePort            = if ($CertificateMode -eq 'letsencrypt-ip') { 80 } else { 'not-used' }
    StaticIpCostWhileAttached      = 'included'
    ManualSnapshotsAndOverage      = 'not-included'
    FailureRollback                = 'disabled-resources-preserved-and-billable'
    TerminationProtection          = 'enabled-at-create'
    StackUpdatePolicy              = 'deny-all-updates'
    CloudFormationResourceTypes    = $allowedCloudFormationResourceTypes -join ','
    BootstrapRevision              = $bootstrapRevision
    BootstrapSha256                = $bootstrapSha256
    TemplateSha256                 = $templateSha256
    ReleaseManifestSha256          = $releaseManifestSha256
    QFieldCloudCommit               = $qfieldCloudCommit
    DhparamsSha256                  = $expectedDhparamsSha256
    CertbotImage                    = $certbotImage
    CertbotVersion                  = $certbotExpectedVersion
    AcmeDirectory                   = $letsEncryptAcmeDirectory
    AcmeCertificateProfile          = $letsEncryptCertificateProfile
    UpstreamDhparams               = 'official-commit-bytes-verified'
    ExistingArboretumDatabaseScope = 'not-accessed'
}
$approvalPlanSha256 = Get-ApprovalPlanSha256 `
    -Plan $approvalPlan `
    -TargetAccountId $ExpectedAccountId
$planValues = [ordered]@{
    Action             = if ($Execute) { 'create-new-stack' } else { 'plan-only' }
    ApprovalPlanSha256 = $approvalPlanSha256
}
foreach ($entry in $approvalPlan.GetEnumerator()) {
    $planValues[$entry.Key] = $entry.Value
}
$plan = [pscustomobject]$planValues

$plan | Format-List
Write-Output "QFC_APPROVAL_RECEIPT_V1=$approvalPlanSha256`:$bootstrapRevision"

if (-not $Execute) {
    Write-Host '사전 확인만 완료했습니다. AWS 자원은 만들거나 변경하지 않았습니다.'
    Write-Host '비용·위험·삭제 방법을 검토하고 승인한 뒤에만 -Execute를 추가하세요.'
    exit 0
}

if ($approvalPlanSha256 -cne $ApprovedPlanSha256) {
    throw '검토한 계획과 현재 계획이 달라 생성하지 않습니다. 새 계획을 다시 검토하세요.'
}

if ($stackExists) {
    throw '같은 이름의 스택이 이미 있습니다. 데이터 인스턴스 교체를 막기 위해 이 설치 도구는 기존 스택을 자동 업데이트하지 않습니다.'
}
if ($physicalNameConflict) {
    throw '기존 Lightsail 인스턴스, 고정 IP 또는 알람 이름이 새 파일럿과 겹칩니다. 기존 자원을 자동 변경하거나 채택하지 않습니다.'
}

$snapshotValue = $EnableAutomaticSnapshots.ToString().ToLowerInvariant()
$alarmsValue = $EnableAlarms.ToString().ToLowerInvariant()
$letsEncryptTermsValue = $AcceptLetsEncryptTerms.IsPresent.ToString().ToLowerInvariant()
$stackParameters = @(
    "ParameterKey=DeploymentRegion,ParameterValue=$Region",
    "ParameterKey=AvailabilityZone,ParameterValue=$AvailabilityZone",
    "ParameterKey=InstanceName,ParameterValue=$InstanceName",
    "ParameterKey=BlueprintId,ParameterValue=$blueprintId",
    "ParameterKey=BundleId,ParameterValue=$bundleId",
    "ParameterKey=CertificateMode,ParameterValue=$CertificateMode",
    "ParameterKey=LetsEncryptTermsAccepted,ParameterValue=$letsEncryptTermsValue",
    "ParameterKey=RepositoryOwner,ParameterValue=$repositoryOwner",
    "ParameterKey=RepositoryName,ParameterValue=$repositoryName",
    "ParameterKey=BootstrapPath,ParameterValue=$bootstrapPath",
    "ParameterKey=BootstrapRevision,ParameterValue=$bootstrapRevision",
    "ParameterKey=BootstrapSha256,ParameterValue=$bootstrapSha256",
    "ParameterKey=EnableAutomaticSnapshots,ParameterValue=$snapshotValue",
    "ParameterKey=AutomaticSnapshotTimeUtc,ParameterValue=$AutomaticSnapshotTimeUtc",
    "ParameterKey=EnableAlarms,ParameterValue=$alarmsValue",
    "ParameterKey=CpuAlarmThresholdPercent,ParameterValue=$CpuAlarmThresholdPercent",
    "ParameterKey=SshAccessMode,ParameterValue=$SshAccessMode"
)
$createArguments = @(
    'cloudformation', 'create-stack',
    '--template-body', $templateUri,
    '--stack-name', $StackName,
    '--resource-types'
) + $allowedCloudFormationResourceTypes + @(
    '--parameters'
) + $stackParameters + @(
    '--tags',
    'Key=Project,Value=qfieldcloud-self-hosting',
    'Key=DeploymentProfile,Value=lab-lightsail',
    '--stack-policy-body', $stackPolicy,
    '--disable-rollback',
    '--enable-termination-protection'
) + (Get-AwsBaseArguments)

$deploymentOutput = & $awsExecutable @createArguments 2>&1
if ($LASTEXITCODE -ne 0) {
    $null = $deploymentOutput
    throw 'CloudFormation 새 스택 생성을 시작하지 못했습니다. 기존 자원과 권한을 확인하세요.'
}
$null = $deploymentOutput

$stack = $null
# The template can wait 150 minutes for certificate-aware bootstrap. Keep the
# local observer alive for about 170 minutes so CloudFormation remains the
# authoritative timeout even when create-request visibility is delayed.
$maxStackPollAttempts = 340
for ($attempt = 1; $attempt -le $maxStackPollAttempts; $attempt++) {
    try {
        $stack = Invoke-AwsJson -Arguments @(
            'cloudformation', 'describe-stacks',
            '--stack-name', $StackName
        )
    }
    catch {
        if ($attempt -le 5) {
            Write-Host 'CloudFormation 생성 요청 반영을 기다리는 중입니다.'
            Start-Sleep -Seconds 5
            continue
        }
        throw
    }
    $currentStatus = [string]$stack.Stacks[0].StackStatus
    if ($currentStatus -eq 'CREATE_COMPLETE') {
        break
    }
    if ($currentStatus -in @(
        'CREATE_FAILED', 'ROLLBACK_IN_PROGRESS', 'ROLLBACK_FAILED', 'ROLLBACK_COMPLETE',
        'DELETE_IN_PROGRESS', 'DELETE_FAILED', 'DELETE_COMPLETE'
    )) {
        throw 'CloudFormation 생성 검증이 실패했습니다. 자동 rollback은 꺼져 있어 부분 자원이 실행·과금 중일 수 있습니다. 콘솔 Events를 확인하고 자동 삭제하지 마세요.'
    }
    if (($attempt % 10) -eq 1) {
        Write-Host "CloudFormation 설치 검증 진행 중: $currentStatus"
    }
    Start-Sleep -Seconds 30
}
if ($null -eq $stack -or [string]$stack.Stacks[0].StackStatus -ne 'CREATE_COMPLETE') {
    throw 'CloudFormation 설치 검증이 제한 시간 안에 끝나지 않았습니다. 자원은 계속 실행·과금 중일 수 있으므로 콘솔에서 확인하세요.'
}
$outputs = @{}
foreach ($output in $stack.Stacks[0].Outputs) {
    $outputs[[string]$output.OutputKey] = [string]$output.OutputValue
}
if ([string]$stack.Stacks[0].StackStatus -ne 'CREATE_COMPLETE') {
    throw 'CloudFormation은 끝났지만 스택 상태가 CREATE_COMPLETE가 아닙니다.'
}
foreach ($requiredOutput in @(
    'InstanceName', 'HttpsUrl', 'AutomaticSnapshots', 'BootstrapRevision',
    'BootstrapSha256', 'BootstrapValidationData', 'CertificateMode'
)) {
    if (-not $outputs.ContainsKey($requiredOutput)) {
        throw "완료된 스택 출력에 $requiredOutput 값이 없습니다."
    }
}
if ([string]$outputs['BootstrapRevision'] -cne $bootstrapRevision -or
    [string]$outputs['BootstrapSha256'] -cne $bootstrapSha256 -or
    [string]$outputs['CertificateMode'] -cne $CertificateMode) {
    throw '완료된 스택의 bootstrap commit 또는 SHA-256이 검토한 로컬 파일과 다릅니다.'
}
try {
    $bootstrapValidation = $outputs['BootstrapValidationData'] | ConvertFrom-Json
    $certificateSha256 = [string]$bootstrapValidation.'qfieldcloud-bootstrap'
}
catch {
    throw '완료된 스택의 인증서 검증 자료를 해석하지 못했습니다.'
}
if ($certificateSha256 -notmatch '^[0-9a-f]{64}$') {
    throw '완료된 스택의 인증서 SHA-256 지문이 올바르지 않습니다.'
}

[pscustomobject]@{
    Deployment          = 'cloudformation-create-complete'
    StackName            = $StackName
    InstanceName         = $outputs['InstanceName']
    PilotUrl             = $outputs['HttpsUrl']
    BootstrapStatus      = 'verified-by-wait-condition'
    BootstrapSource      = 'expected-revision-and-sha256-matched'
    CertificateSha256    = $certificateSha256
    CertificateMode      = $outputs['CertificateMode']
    CertificateRenewal   = if ($CertificateMode -eq 'letsencrypt-ip') { 'scheduled-on-instance' } else { 'not-configured' }
    TerminationProtection = 'enabled'
    AutomaticSnapshot    = $outputs['AutomaticSnapshots']
}

Write-Host 'CloudFormation 생성, QFieldCloud 부트스트랩 및 설치 검증이 모두 통과했습니다.'
Write-Host '이 스크립트는 파일럿을 자동 삭제하지 않습니다.'
