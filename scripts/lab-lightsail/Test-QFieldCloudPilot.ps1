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

function Get-AwsExecutable {
    $command = Get-Command aws -ErrorAction SilentlyContinue
    if ($command) {
        $candidate = $command.Source
    }
    else {
        $perUserPath = Join-Path $env:LOCALAPPDATA 'Programs\Amazon\AWSCLIV2\aws.exe'
        if (-not (Test-Path -LiteralPath $perUserPath -PathType Leaf)) {
            throw 'AWS CLI v2를 찾지 못했습니다.'
        }
        $candidate = $perUserPath
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
        [string[]]$Arguments
    )

    $awsExecutable = Get-AwsExecutable
    $allArguments = @($Arguments) + @('--region', $Region, '--output', 'json', '--no-cli-pager')
    if ($Profile) {
        $allArguments += @('--profile', $Profile)
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
        [ValidateSet('login_session', 'sso_session', 'sso_account_id')]
        [string]$Name
    )

    $awsExecutable = Get-AwsExecutable
    $setting = & $awsExecutable configure get $Name --profile $Profile 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }
    return (($setting -join [Environment]::NewLine).Trim())
}

function Get-AwsResolvedCredentialType {
    $awsExecutable = Get-AwsExecutable
    $configuration = & $awsExecutable configure list --profile $Profile 2>$null
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

$instanceState = 'not-queried'
$stackStatus = 'not-queried'
$bootstrapRevision = 'not-queried'
if ($PSCmdlet.ParameterSetName -eq 'Stack') {
    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw '스택 검증에는 명시적인 임시 로그인 프로필이 필요합니다.'
    }
    $loginSession = Get-AwsProfileSetting -Name login_session
    $ssoSession = Get-AwsProfileSetting -Name sso_session
    if ([string]::IsNullOrWhiteSpace($loginSession) -eq [string]::IsNullOrWhiteSpace($ssoSession)) {
        throw '프로필에는 aws login 또는 IAM Identity Center 설정 중 정확히 하나가 있어야 합니다.'
    }
    $resolvedCredentialType = Get-AwsResolvedCredentialType
    $identity = Invoke-AwsJson -Arguments @('sts', 'get-caller-identity')
    $identityArn = [string]$identity.Arn
    $identityAccount = [string]$identity.Account
    if ($identityArn -match ':root$') {
        throw 'AWS 루트 사용자 세션으로는 스택을 검증하지 않습니다.'
    }
    if ($identityAccount -ne $ExpectedAccountId) {
        throw '현재 AWS 세션의 계정이 사용자가 지정한 검증 대상 계정과 다릅니다.'
    }
    if (-not [string]::IsNullOrWhiteSpace($loginSession)) {
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
            $identityArn -notmatch ':assumed-role/') {
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
