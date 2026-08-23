#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Stack', Mandatory = $true)]
    [ValidateSet('qfieldcloud-lab-pilot')]
    [string]$StackName,

    [Parameter(ParameterSetName = 'Host', Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$')]
    [string]$HostName,

    [Parameter(ParameterSetName = 'Host', Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ExpectedCertificateSha256,

    [ValidateSet('ap-northeast-2')]
    [string]$Region = 'ap-northeast-2',

    [Parameter(ParameterSetName = 'Stack', Mandatory = $true)]
    [ValidatePattern('^[0-9]{12}$')]
    [string]$ExpectedAccountId,

    [Parameter(ParameterSetName = 'Stack')]
    [ValidatePattern('^arn:aws:iam::[0-9]{12}:role/qfieldcloud-lab/QFieldCloudLabDeployer$')]
    [string]$ExpectedDeploymentRoleArn,

    [Parameter(ParameterSetName = 'Stack', Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string]$ExpectedBootstrapRevision,

    [Parameter(ParameterSetName = 'Stack', Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ExpectedBootstrapSha256,

    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Profile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        throw '이 검증 도구는 공식 AWS CLI v2가 필요합니다.'
    }
    return $candidate
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ProfileName = $Profile
    )

    $awsExecutable = Get-AwsExecutable
    $allArguments = @($Arguments) + @('--region', $Region, '--output', 'json', '--no-cli-pager')
    if ($ProfileName) {
        $allArguments += @('--profile', $ProfileName)
    }

    $rawResult = & $awsExecutable @allArguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'AWS 읽기 전용 상태 조회에 실패했습니다. 로그인과 리전을 확인하세요.'
    }

    return ($rawResult | ConvertFrom-Json)
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

    $awsExecutable = Get-AwsExecutable
    $setting = & $awsExecutable configure get $Name --profile $ProfileName 2>$null
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

    $awsExecutable = Get-AwsExecutable
    $configuration = & $awsExecutable configure list --profile $ProfileName 2>$null
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

$instanceState = 'not-queried'
$stackStatus = 'not-queried'
$bootstrapRevision = 'not-queried'
if ($PSCmdlet.ParameterSetName -eq 'Stack') {
    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw '스택 검증에는 명시적인 임시 로그인 프로필이 필요합니다.'
    }
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
    $identity = Invoke-AwsJson -Arguments @('sts', 'get-caller-identity')
    $identityArn = [string]$identity.Arn
    $identityAccount = [string]$identity.Account
    if ($identityArn -match ':root$') {
        throw 'AWS 루트 사용자 세션으로는 스택을 검증하지 않습니다.'
    }
    if ($identityAccount -ne $ExpectedAccountId) {
        throw '현재 AWS 세션의 계정이 사용자가 지정한 검증 대상 계정과 다릅니다.'
    }
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
    }
    else {
        $ssoAccountId = Get-AwsProfileSetting -Name sso_account_id
        if ($resolvedCredentialType -ne 'sso' -or
            $ssoAccountId -ne $ExpectedAccountId -or
            $identityArn -notmatch '^arn:aws:sts::[0-9]{12}:assumed-role/AWSReservedSSO_[A-Za-z0-9+=,.@_-]+_[0-9A-Fa-f]{16}/.+$') {
            throw 'IAM Identity Center 프로필이 지정한 계정의 SSO 임시 역할 세션으로 확인되지 않았습니다.'
        }
    }
    $stackResult = Invoke-AwsJson -Arguments @(
        'cloudformation', 'describe-stacks', '--stack-name', $StackName
    )
    if (-not $stackResult.Stacks -or $stackResult.Stacks.Count -ne 1) {
        throw 'CloudFormation 스택을 하나로 확인하지 못했습니다.'
    }

    $stack = $stackResult.Stacks[0]
    $stackStatus = [string]$stack.StackStatus
    if ($stackStatus -ne 'CREATE_COMPLETE') {
        throw '이 파일럿은 CREATE_COMPLETE인 새 스택만 정상 설치로 판정합니다.'
    }
    if (-not [bool]$stack.EnableTerminationProtection) {
        throw '완료된 파일럿 스택의 삭제 방지 기능이 꺼져 있습니다.'
    }
    $stackPolicyResult = Invoke-AwsJson -Arguments @(
        'cloudformation', 'get-stack-policy', '--stack-name', $StackName
    )
    try {
        $stackPolicy = [string]$stackPolicyResult.StackPolicyBody | ConvertFrom-Json
    }
    catch {
        throw '완료된 파일럿 스택의 업데이트 방지 정책을 해석하지 못했습니다.'
    }
    $stackPolicyStatements = @($stackPolicy.Statement)
    if ($stackPolicyStatements.Count -ne 1 -or
        [string]$stackPolicyStatements[0].Effect -ne 'Deny' -or
        [string]$stackPolicyStatements[0].Action -ne 'Update:*' -or
        [string]$stackPolicyStatements[0].Principal -ne '*' -or
        [string]$stackPolicyStatements[0].Resource -ne '*') {
        throw '완료된 파일럿 스택에 전체 업데이트 방지 정책이 적용되어 있지 않습니다.'
    }
    $stackTags = @{}
    foreach ($tag in $stack.Tags) {
        $stackTags[[string]$tag.Key] = [string]$tag.Value
    }
    if ($stackTags['Project'] -ne 'qfieldcloud-self-hosting' -or
        $stackTags['DeploymentProfile'] -ne 'lab-lightsail') {
        throw '선택한 스택이 이 저장소의 lab-lightsail 파일럿 태그와 일치하지 않습니다.'
    }

    $outputs = @{}
    foreach ($output in $stack.Outputs) {
        $outputs[$output.OutputKey] = $output.OutputValue
    }
    foreach ($requiredOutput in @(
        'PilotHostName', 'InstanceName', 'BootstrapRevision', 'BootstrapSha256',
        'BootstrapValidationData'
    )) {
        if (-not $outputs.ContainsKey($requiredOutput)) {
            throw "스택 출력에 $requiredOutput 값이 없습니다."
        }
    }

    $HostName = [string]$outputs['PilotHostName']
    $bootstrapRevision = [string]$outputs['BootstrapRevision']
    if ($bootstrapRevision -notmatch '^[0-9a-f]{40}$') {
        throw '스택의 bootstrap revision이 고정된 전체 Git commit 형식이 아닙니다.'
    }
    $stackBootstrapSha256 = [string]$outputs['BootstrapSha256']
    if ($stackBootstrapSha256 -notmatch '^[0-9a-f]{64}$' -or
        $bootstrapRevision -cne $ExpectedBootstrapRevision.ToLowerInvariant() -or
        $stackBootstrapSha256 -cne $ExpectedBootstrapSha256.ToLowerInvariant()) {
        throw '스택의 bootstrap commit 또는 SHA-256이 사용자가 지정한 검토 파일과 다릅니다.'
    }

    try {
        $validationData = [string]$outputs['BootstrapValidationData'] | ConvertFrom-Json
    }
    catch {
        throw 'CloudFormation bootstrap 검증 자료를 해석하지 못했습니다.'
    }
    $fingerprintProperty = $validationData.PSObject.Properties |
        Where-Object Name -EQ 'qfieldcloud-bootstrap'
    if (-not $fingerprintProperty -or $fingerprintProperty.Count -ne 1) {
        throw 'CloudFormation 검증 자료에 인증서 지문이 하나로 들어 있지 않습니다.'
    }
    $ExpectedCertificateSha256 = [string]$fingerprintProperty[0].Value

    $stateResult = Invoke-AwsJson -Arguments @(
        'lightsail', 'get-instance-state', '--instance-name', [string]$outputs['InstanceName']
    )
    $instanceState = [string]$stateResult.state.name
}

if ($HostName -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$') {
    throw '검증할 호스트 이름 형식이 올바르지 않습니다.'
}
$ExpectedCertificateSha256 = $ExpectedCertificateSha256.ToLowerInvariant()
if ($ExpectedCertificateSha256 -notmatch '^[0-9a-f]{64}$') {
    throw '예상 인증서 SHA-256 지문 형식이 올바르지 않습니다.'
}

$endpointUri = "https://$HostName/api/v1/status/"
$probeNonce = [Guid]::NewGuid().ToString('N')
$probeUri = "$endpointUri`?probe=$probeNonce"
$handler = [System.Net.Http.HttpClientHandler]::new()
$expectedFingerprint = $ExpectedCertificateSha256
$expectedHostName = $HostName
$handler.ServerCertificateCustomValidationCallback = {
    param($requestMessage, $certificate, $chain, $sslPolicyErrors)

    if ($null -eq $certificate) {
        return $false
    }
    $now = [DateTime]::UtcNow
    if ($now -lt $certificate.NotBefore.ToUniversalTime() -or
        $now -ge $certificate.NotAfter.ToUniversalTime()) {
        return $false
    }
    $certificateDnsName = $certificate.GetNameInfo(
        [System.Security.Cryptography.X509Certificates.X509NameType]::DnsName,
        $false
    )
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
        $certificateDnsName,
        $expectedHostName
    )) {
        return $false
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $actualBytes = $sha256.ComputeHash($certificate.GetRawCertData())
        $actualFingerprint = [System.BitConverter]::ToString($actualBytes).Replace('-', '').ToLowerInvariant()
        return [System.StringComparer]::Ordinal.Equals($actualFingerprint, $expectedFingerprint)
    }
    finally {
        $sha256.Dispose()
    }
}.GetNewClosure()

$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(30)
try {
    # QFieldCloud v26.25 caches the status view for 60 seconds. A unique query
    # value makes this validation observe the current DB/storage connections.
    $response = $client.GetAsync($probeUri).GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
        throw '상태 endpoint가 성공 HTTP 응답을 반환하지 않았습니다.'
    }
    $status = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
}
catch {
    throw '고정된 인증서 지문으로 QFieldCloud HTTPS 상태 endpoint를 검증하지 못했습니다.'
}
finally {
    $client.Dispose()
    $handler.Dispose()
}

$databaseState = [string]$status.database
$storageState = [string]$status.storage
$endpointOk = ($databaseState -eq 'ok' -and $storageState -eq 'ok')
$awsStateOk = ($instanceState -eq 'not-queried' -or $instanceState -eq 'running')
$endpointCheck = if ($endpointOk -and $awsStateOk) { 'ok' } else { 'error' }
$validationScope = if ($PSCmdlet.ParameterSetName -eq 'Stack') {
    'cloudformation-create-gate-and-pinned-https-endpoint'
}
else {
    'pinned-https-database-storage-only'
}
$deploymentValidation = if ($PSCmdlet.ParameterSetName -eq 'Stack') {
    'bootstrap-wait-condition-verified'
}
else {
    'partial-worker-not-verified-remotely'
}

[pscustomobject]@{
    EndpointCheck         = $endpointCheck
    ValidationScope       = $validationScope
    DeploymentValidation = $deploymentValidation
    Region                = $Region
    StackStatus           = $stackStatus
    BootstrapRevision     = $bootstrapRevision
    BootstrapSource       = if ($PSCmdlet.ParameterSetName -eq 'Stack') { 'expected-revision-and-sha256-matched' } else { 'not-queried' }
    InstanceState         = $instanceState
    Database              = $databaseState
    Storage               = $storageState
    Endpoint              = $endpointUri
    CertificatePin        = 'matched'
    CertificateValidity   = 'current-hostname-matched'
    TerminationProtection = if ($PSCmdlet.ParameterSetName -eq 'Stack') { 'enabled' } else { 'not-queried' }
    FullHealthCommand     = 'sudo /opt/qfieldcloud/bin/health-check.sh'
    Qgis4Support          = 'disabled-unverified-upstream-image'
}

if ($endpointCheck -ne 'ok') {
    exit 1
}

if ($PSCmdlet.ParameterSetName -eq 'Host') {
    Write-Warning '이 결과는 고정 인증서·외부 HTTPS·데이터베이스·객체 저장소만 확인합니다. 워커와 설치 전체 검증은 서버에서 FullHealthCommand를 실행해야 합니다.'
}
