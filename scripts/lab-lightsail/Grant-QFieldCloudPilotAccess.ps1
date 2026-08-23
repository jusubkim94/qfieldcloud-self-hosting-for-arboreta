#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$AdminProfile,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedAccountId,

    [AllowEmptyString()]
    [string]$TrustedPrincipalArn = '',

    [ValidateSet('qfieldcloud-lab-access')]
    [string]$StackName = 'qfieldcloud-lab-access',

    [ValidateSet('ap-northeast-2')]
    [string]$Region = 'ap-northeast-2',

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryOwner = 'jusubkim94'
$repositoryName = 'qfieldcloud-self-hosting-for-arboreta'
$expectedOrigin = "https://github.com/$repositoryOwner/$repositoryName.git"
$templateRepositoryPath = 'infra/lab-lightsail/access-bootstrap.yaml'
$policyRepositoryPath = 'infra/lab-lightsail/deployer-policy.json'
$deploymentRoleName = 'QFieldCloudLabDeployer'
$deploymentRolePath = '/qfieldcloud-lab/'
$deploymentPolicyName = 'QFieldCloudLabDeployer'
$deploymentPolicyPath = '/qfieldcloud-lab/'
$confirmationText = 'CREATE qfieldcloud-lab-access'

if ($ExpectedAccountId -notmatch '^[0-9]{12}$') {
    throw 'ExpectedAccountId는 12자리 AWS 계정 번호여야 합니다.'
}
if (-not [string]::IsNullOrWhiteSpace($TrustedPrincipalArn) -and
    $TrustedPrincipalArn -match '[*?\s]') {
    throw '신뢰 주체는 wildcard나 공백이 없는 정확한 IAM ARN이어야 합니다.'
}
$trustedPrincipalInputSource = if ([string]::IsNullOrWhiteSpace($TrustedPrincipalArn)) {
    'admin-session-derived'
}
else {
    'explicit'
}

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

    $versionOutput = & $candidate --version 2>&1
    if ($LASTEXITCODE -ne 0 -or ($versionOutput -join ' ') -notmatch '^aws-cli/2\.') {
        throw '이 권한 준비 도구는 공식 AWS CLI v2가 필요합니다.'
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
    return @('--region', $Region, '--profile', $AdminProfile, '--no-cli-pager')
}

function Get-AwsProfileSetting {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $setting = & $script:awsExecutable configure get $Name --profile $AdminProfile 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }
    return (($setting -join [Environment]::NewLine).Trim())
}

function Test-AwsProfileSettingExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    & $script:awsExecutable configure get $Name --profile $AdminProfile *> $null
    return $LASTEXITCODE -eq 0
}

function Get-AwsResolvedCredentialType {
    $configuration = & $script:awsExecutable configure list --profile $AdminProfile 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw '관리자 프로필의 자격증명 출처를 확인하지 못했습니다.'
    }

    $accessKeyLines = @(
        $configuration | Where-Object { $_ -match '^\s*access_key(?:\s*:\s*|\s+)' }
    )
    if ($accessKeyLines.Count -ne 1) {
        throw '관리자 프로필의 자격증명 출처가 하나로 확인되지 않았습니다.'
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
        throw '관리자 프로필의 자격증명 유형을 안전하게 해석하지 못했습니다.'
    }
    return $typeMatch.Groups[1].Value
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [string]$FailureMessage = 'AWS 사전 확인에 실패했습니다. 관리자 로그인과 권한을 확인하세요.'
    )

    $allArguments = @($Arguments) + (Get-AwsBaseArguments) + @('--output', 'json')
    $rawResult = & $script:awsExecutable @allArguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }

    $jsonText = ($rawResult -join [Environment]::NewLine)
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return $null
    }
    return ($jsonText | ConvertFrom-Json -Depth 100)
}

function Invoke-AwsProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$AbsentPattern,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    $allArguments = @($Arguments) + (Get-AwsBaseArguments) + @('--output', 'json')
    $rawResult = & $script:awsExecutable @allArguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        $jsonText = ($rawResult -join [Environment]::NewLine)
        return [pscustomobject]@{
            Exists = $true
            Value  = if ([string]::IsNullOrWhiteSpace($jsonText)) { $null } else { $jsonText | ConvertFrom-Json -Depth 100 }
        }
    }
    if (($rawResult -join ' ') -match $AbsentPattern) {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
    throw $FailureMessage
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

function Write-CanonicalJsonElement {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.Json.JsonElement]$Element,

        [Parameter(Mandatory = $true)]
        [System.Text.Json.Utf8JsonWriter]$Writer
    )

    switch ($Element.ValueKind) {
        'Object' {
            $Writer.WriteStartObject()
            $properties = @($Element.EnumerateObject())
            [Array]::Sort(
                $properties,
                [System.Collections.Generic.Comparer[System.Text.Json.JsonProperty]]::Create(
                    [System.Comparison[System.Text.Json.JsonProperty]]{
                        param($left, $right)
                        return [StringComparer]::Ordinal.Compare($left.Name, $right.Name)
                    }
                )
            )
            foreach ($property in $properties) {
                $Writer.WritePropertyName($property.Name)
                Write-CanonicalJsonElement -Element $property.Value -Writer $Writer
            }
            $Writer.WriteEndObject()
        }
        'Array' {
            $Writer.WriteStartArray()
            foreach ($item in $Element.EnumerateArray()) {
                Write-CanonicalJsonElement -Element $item -Writer $Writer
            }
            $Writer.WriteEndArray()
        }
        'String' { $Writer.WriteStringValue($Element.GetString()) }
        'Number' { $Writer.WriteRawValue($Element.GetRawText(), $true) }
        'True' { $Writer.WriteBooleanValue($true) }
        'False' { $Writer.WriteBooleanValue($false) }
        'Null' { $Writer.WriteNullValue() }
        default { throw 'JSON 정책에 지원하지 않는 값이 있습니다.' }
    }
}

function Get-CanonicalJsonBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
    }
    catch {
        throw '배포 권한 정책 JSON을 해석하지 못했습니다.'
    }

    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.Text.Json.Utf8JsonWriter]::new(
        $stream,
        [System.Text.Json.JsonWriterOptions]@{ Indented = $false }
    )
    try {
        Write-CanonicalJsonElement -Element $document.RootElement -Writer $writer
        $writer.Flush()
        return $stream.ToArray()
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
        $document.Dispose()
    }
}

function Get-CanonicalJsonSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    return Get-Sha256Hex -Bytes (Get-CanonicalJsonBytes -Json $Json)
}

function Get-NormalizedText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-PublicFileText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Revision,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    $uri = "https://raw.githubusercontent.com/$repositoryOwner/$repositoryName/$Revision/$RepositoryPath"
    try {
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing
    }
    catch {
        throw '현재 commit의 필수 파일을 공개 GitHub에서 내려받지 못했습니다. commit이 공개 origin에 Push되어 있는지 확인하세요.'
    }
    if ([int]$response.StatusCode -ne 200) {
        throw '공개 GitHub의 필수 파일 응답이 정상 상태가 아닙니다.'
    }
    if ($response.Content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString([byte[]]$response.Content)
    }
    return [string]$response.Content
}

function Test-ExactStringSet {
    param(
        [AllowEmptyCollection()]
        [string[]]$Actual,

        [AllowEmptyCollection()]
        [string[]]$Expected
    )

    return @(
        Compare-Object -ReferenceObject @($Expected | Sort-Object -Unique) `
            -DifferenceObject @($Actual | Sort-Object -Unique)
    ).Count -eq 0
}

function Get-PolicyDocumentObject {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Document
    )

    if ($Document -is [string]) {
        try {
            return ([System.Net.WebUtility]::UrlDecode([string]$Document) | ConvertFrom-Json -Depth 100)
        }
        catch {
            throw 'AWS의 기본 정책 문서를 해석하지 못했습니다.'
        }
    }
    return $Document
}

function Test-PolicyExcludesCleanupPermissions {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Policy
    )

    $forbiddenActions = @(
        'cloudformation:DeleteStack',
        'cloudformation:UpdateTerminationProtection',
        'iam:CreatePolicyVersion',
        'iam:DeletePolicy',
        'iam:DeleteRole',
        'iam:DetachRolePolicy',
        'iam:PassRole'
    )
    foreach ($statement in @($Policy.Statement)) {
        if ([string]$statement.Effect -cne 'Allow') {
            continue
        }
        if (-not ($statement.PSObject.Properties.Name -contains 'Action') -or
            $statement.PSObject.Properties.Name -contains 'NotAction') {
            return $false
        }
        foreach ($action in @($statement.Action)) {
            $actionText = [string]$action
            if ($actionText -match '[*?]' -or
                $actionText -match '^(?i:iam|organizations|sts):') {
                return $false
            }
            $escaped = [regex]::Escape($actionText).Replace('\*', '.*').Replace('\?', '.')
            foreach ($forbiddenAction in $forbiddenActions) {
                if ($forbiddenAction -match "^$escaped$") {
                    return $false
                }
            }
            if ($actionText -match '^(?i:lightsail):Delete') {
                if ($actionText -notin @('lightsail:DeleteAlarm', 'lightsail:DeleteInstance') -or
                    -not ($statement.PSObject.Properties.Name -contains 'Condition') -or
                    [string]$statement.Condition.'ForAnyValue:StringEquals'.'aws:CalledVia' -cne 'cloudformation.amazonaws.com') {
                    return $false
                }
            }
        }
    }
    return $true
}

function Assert-RoleTrustPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TrustPolicy,

        [Parameter(Mandatory = $true)]
        [ValidateSet('IamUser', 'IdentityCenterPermissionSet')]
        [string]$PrincipalKind,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedPattern
    )

    $statements = @($TrustPolicy.Statement)
    if ($statements.Count -ne 1) {
        throw '생성된 배포 역할의 신뢰 정책 문장 수가 예상과 다릅니다.'
    }
    $statement = $statements[0]
    if ([string]$statement.Effect -cne 'Allow' -or
        -not (Test-ExactStringSet -Actual @($statement.Action) -Expected @('sts:AssumeRole'))) {
        throw '생성된 배포 역할의 신뢰 작업이 예상과 다릅니다.'
    }
    if (-not $statement.Principal -or
        -not (Test-ExactStringSet -Actual @($statement.Principal.PSObject.Properties.Name) -Expected @('AWS'))) {
        throw '생성된 배포 역할의 신뢰 주체 형식이 예상과 다릅니다.'
    }

    if ($PrincipalKind -eq 'IamUser') {
        if ([string]$statement.Principal.AWS -cne $ExpectedPattern) {
            throw '생성된 배포 역할이 검증한 IAM 사용자만 신뢰하지 않습니다.'
        }
        if ($statement.PSObject.Properties.Name -contains 'Condition' -and
            $null -ne $statement.Condition -and
            @($statement.Condition.PSObject.Properties).Count -gt 0) {
            throw 'IAM 사용자 신뢰 정책에 예상하지 않은 조건이 있습니다.'
        }
        return
    }

    $expectedRoot = "arn:aws:iam::$ExpectedAccountId`:root"
    if ([string]$statement.Principal.AWS -cne $expectedRoot) {
        throw 'IAM Identity Center 신뢰 정책의 계정 경계가 예상과 다릅니다.'
    }
    if (-not $statement.Condition -or
        -not (Test-ExactStringSet -Actual @($statement.Condition.PSObject.Properties.Name) -Expected @('ArnLike', 'StringEquals')) -or
        [string]$statement.Condition.ArnLike.'aws:PrincipalArn' -cne $ExpectedPattern -or
        [string]$statement.Condition.StringEquals.'aws:PrincipalAccount' -cne $ExpectedAccountId) {
        throw 'IAM Identity Center 신뢰 정책이 검증한 permission set으로 정확히 제한되지 않았습니다.'
    }
}

$awsExecutable = Get-AwsExecutable
$gitExecutable = Get-GitExecutable
$createStackSkeleton = & $awsExecutable cloudformation create-stack --generate-cli-skeleton input 2>$null
if ($LASTEXITCODE -ne 0) {
    throw '설치된 AWS CLI v2가 안전한 초기 rollback 옵션을 확인하지 못했습니다. AWS CLI v2를 업데이트하세요.'
}
try {
    $createStackSkeletonObject = ($createStackSkeleton -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
}
catch {
    throw '설치된 AWS CLI v2의 CloudFormation 기능을 해석하지 못했습니다. AWS CLI v2를 업데이트하세요.'
}
if (-not ($createStackSkeletonObject.PSObject.Properties.Name -contains 'RetainExceptOnCreate')) {
    throw '설치된 AWS CLI v2가 retain-except-on-create를 지원하지 않습니다. AWS CLI v2를 업데이트하세요.'
}

# 관리자 세션은 aws login 또는 IAM Identity Center에서 발급된 임시 자격증명만 허용한다.
$loginSession = Get-AwsProfileSetting -Name 'login_session'
$ssoSession = Get-AwsProfileSetting -Name 'sso_session'
if ([string]::IsNullOrWhiteSpace($loginSession) -eq [string]::IsNullOrWhiteSpace($ssoSession)) {
    throw '관리자 프로필에는 aws login 또는 IAM Identity Center 설정 중 정확히 하나가 있어야 합니다.'
}

$forbiddenProfileSettings = @(
    'role_arn', 'source_profile', 'credential_source', 'credential_process',
    'web_identity_token_file', 'aws_access_key_id', 'aws_secret_access_key', 'aws_session_token',
    'endpoint_url', 'services'
)
foreach ($settingName in $forbiddenProfileSettings) {
    if (Test-AwsProfileSettingExists -Name $settingName) {
        throw '관리자 프로필에 허용하지 않는 자격증명 체인 또는 사용자 지정 AWS endpoint 설정이 있습니다.'
    }
}
$credentialEnvironmentNames = @(
    'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN',
    'AWS_ROLE_ARN', 'AWS_WEB_IDENTITY_TOKEN_FILE',
    'AWS_CONTAINER_CREDENTIALS_FULL_URI', 'AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'
)
foreach ($environmentName in $credentialEnvironmentNames) {
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($environmentName))) {
        throw '현재 PowerShell에 AWS 자격증명 또는 사용자 지정 endpoint 환경변수가 있습니다. 새 터미널에서 다시 실행하세요.'
    }
}
$customEndpointEnvironmentPresent = @(
    [Environment]::GetEnvironmentVariables().Keys | Where-Object {
        $name = [string]$_
        $name.Equals('AWS_ENDPOINT_URL', [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith('AWS_ENDPOINT_URL_', [StringComparison]::OrdinalIgnoreCase)
    }
).Count -gt 0
if ($customEndpointEnvironmentPresent) {
    throw '현재 PowerShell에 사용자 지정 AWS endpoint 환경변수가 있습니다. 해당 설정을 제거한 새 터미널에서 다시 실행하세요.'
}

$resolvedCredentialType = Get-AwsResolvedCredentialType
if (-not [string]::IsNullOrWhiteSpace($loginSession)) {
    if ($resolvedCredentialType -cne 'login') {
        throw '관리자 aws login 프로필이 login 임시 자격증명으로 확인되지 않았습니다.'
    }
    $adminSessionType = 'temporary-aws-login'
}
else {
    if ($resolvedCredentialType -cne 'sso' -or
        (Get-AwsProfileSetting -Name 'sso_account_id') -cne $ExpectedAccountId) {
        throw '관리자 IAM Identity Center 프로필이 지정한 계정의 SSO 임시 자격증명으로 확인되지 않았습니다.'
    }
    $adminSessionType = 'temporary-identity-center'
}

$identity = Invoke-AwsJson -Arguments @('sts', 'get-caller-identity')
$identityArn = [string]$identity.Arn
if ([string]$identity.Account -cne $ExpectedAccountId -or $identityArn -match ':root$') {
    throw '현재 관리자 세션이 지정한 계정의 비루트 임시 세션이 아닙니다.'
}
if ($adminSessionType -eq 'temporary-aws-login') {
    if ($loginSession -notmatch '^arn:aws:iam::[0-9]{12}:user/[^*?]+$' -or
        $loginSession -cne $identityArn) {
        throw '관리자 aws login 세션이 정확한 비루트 IAM 사용자로 확인되지 않았습니다.'
    }
}
elseif ($identityArn -notmatch "^arn:aws:sts::$ExpectedAccountId`:assumed-role/AWSReservedSSO_[A-Za-z0-9+=,.@_-]+_[0-9A-Fa-f]{16}/[^/]+$") {
    throw '관리자 SSO 세션이 역할 임시 세션으로 확인되지 않았습니다.'
}

# 기본값은 관리자 임시 세션 자체를 신뢰 주체로 사용하여 초보자의 ARN 입력을 줄인다.
# 다른 IAM 사용자 또는 permission set을 신뢰해야 할 때만 정확한 ARN을 명시한다.
if ([string]::IsNullOrWhiteSpace($TrustedPrincipalArn)) {
    if ($adminSessionType -eq 'temporary-aws-login') {
        $TrustedPrincipalArn = $identityArn
    }
    else {
        $ssoCallerMatch = [regex]::Match(
            $identityArn,
            "^arn:aws:sts::$ExpectedAccountId`:assumed-role/(?<RoleName>AWSReservedSSO_[A-Za-z0-9+=,.@_-]+_[0-9A-Fa-f]{16})/[^/]+$"
        )
        if (-not $ssoCallerMatch.Success) {
            throw '관리자 SSO 역할 이름을 안전하게 확인하지 못했습니다.'
        }
        $adminSsoRole = Invoke-AwsJson -Arguments @(
            'iam', 'get-role', '--role-name', $ssoCallerMatch.Groups['RoleName'].Value
        ) -FailureMessage '관리자 IAM Identity Center 역할 ARN을 확인하지 못했습니다.'
        $TrustedPrincipalArn = [string]$adminSsoRole.Role.Arn
    }
}

# 입력한 신뢰 주체는 같은 계정의 실제 IAM 사용자 또는 실제 Identity Center 역할이어야 한다.
$trustedPrincipalKind = ''
$trustedIamUserName = ''
$identityCenterPermissionSetName = ''
$identityCenterRegion = ''
$trustedPrincipalPattern = ''

$iamUserMatch = [regex]::Match(
    $TrustedPrincipalArn,
    '^arn:aws:iam::(?<Account>[0-9]{12}):user/(?<Name>[A-Za-z0-9_+=,.@-]{1,64})$'
)
$identityCenterMatch = [regex]::Match(
    $TrustedPrincipalArn,
    '^arn:aws:iam::(?<Account>[0-9]{12}):role/aws-reserved/sso\.amazonaws\.com/(?:(?<Region>[a-z]{2}(?:-gov)?-[a-z]+-[0-9])/)?AWSReservedSSO_(?<Name>[A-Za-z0-9+=,.@_-]{1,32})_(?<Suffix>[0-9A-Fa-f]{16})$'
)
if ($iamUserMatch.Success) {
    if ($iamUserMatch.Groups['Account'].Value -cne $ExpectedAccountId) {
        throw '신뢰할 IAM 사용자는 배포 대상과 같은 AWS 계정이어야 합니다.'
    }
    $trustedIamUserName = $iamUserMatch.Groups['Name'].Value
    $actualUser = Invoke-AwsJson -Arguments @('iam', 'get-user', '--user-name', $trustedIamUserName) `
        -FailureMessage '신뢰할 IAM 사용자를 AWS에서 정확히 확인하지 못했습니다.'
    if ([string]$actualUser.User.Arn -cne $TrustedPrincipalArn -or
        [string]$actualUser.User.UserName -cne $trustedIamUserName -or
        [string]$actualUser.User.Path -cne '/') {
        throw '입력한 IAM 사용자 ARN이 AWS의 실제 pathless 사용자와 정확히 일치하지 않습니다.'
    }
    $accessKeys = Invoke-AwsJson -Arguments @(
        'iam', 'list-access-keys', '--user-name', $trustedIamUserName
    ) -FailureMessage '신뢰할 IAM 사용자의 장기 접근키 유무를 확인하지 못했습니다.'
    if (@($accessKeys.AccessKeyMetadata).Count -ne 0) {
        throw '신뢰할 IAM 사용자에 장기 Access Key가 있습니다. 모든 키를 폐기한 뒤 임시 브라우저 로그인을 사용하세요.'
    }
    $mfaDevices = Invoke-AwsJson -Arguments @(
        'iam', 'list-mfa-devices', '--user-name', $trustedIamUserName
    ) -FailureMessage '신뢰할 IAM 사용자의 MFA 등록 상태를 확인하지 못했습니다.'
    if (@($mfaDevices.MFADevices).Count -lt 1) {
        throw '신뢰할 IAM 사용자에 MFA가 등록되어 있지 않습니다.'
    }
    $trustedPrincipalKind = 'IamUser'
    $trustedPrincipalPattern = $TrustedPrincipalArn
}
elseif ($identityCenterMatch.Success) {
    if ($identityCenterMatch.Groups['Account'].Value -cne $ExpectedAccountId) {
        throw '신뢰할 IAM Identity Center 역할은 배포 대상과 같은 AWS 계정이어야 합니다.'
    }
    $identityCenterPermissionSetName = $identityCenterMatch.Groups['Name'].Value
    $identityCenterRegion = if ($identityCenterMatch.Groups['Region'].Success) {
        $identityCenterMatch.Groups['Region'].Value
    }
    else {
        'us-east-1'
    }
    $identityCenterRoleName = "AWSReservedSSO_$identityCenterPermissionSetName`_$($identityCenterMatch.Groups['Suffix'].Value)"
    $actualIdentityCenterRole = Invoke-AwsJson -Arguments @('iam', 'get-role', '--role-name', $identityCenterRoleName) `
        -FailureMessage '신뢰할 IAM Identity Center 역할을 AWS에서 정확히 확인하지 못했습니다.'
    if ([string]$actualIdentityCenterRole.Role.Arn -cne $TrustedPrincipalArn -or
        [string]$actualIdentityCenterRole.Role.RoleName -cne $identityCenterRoleName) {
        throw '입력한 IAM Identity Center 역할 ARN이 AWS의 실제 역할과 정확히 일치하지 않습니다.'
    }
    $expectedIdentityCenterPath = if ($identityCenterRegion -eq 'us-east-1') {
        '/aws-reserved/sso.amazonaws.com/'
    }
    else {
        "/aws-reserved/sso.amazonaws.com/$identityCenterRegion/"
    }
    if ([string]$actualIdentityCenterRole.Role.Path -cne $expectedIdentityCenterPath) {
        throw 'IAM Identity Center 역할의 예약 경로가 예상과 다릅니다.'
    }
    $trustedPrincipalKind = 'IdentityCenterPermissionSet'
    $trustedPrincipalPattern = if ($identityCenterRegion -eq 'us-east-1') {
        "arn:aws:iam::$ExpectedAccountId`:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_$identityCenterPermissionSetName`_*"
    }
    else {
        "arn:aws:iam::$ExpectedAccountId`:role/aws-reserved/sso.amazonaws.com/$identityCenterRegion/AWSReservedSSO_$identityCenterPermissionSetName`_*"
    }
}
else {
    throw '신뢰 주체는 pathless IAM 사용자 ARN 또는 정확한 AWSReservedSSO 역할 ARN이어야 합니다.'
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$reportedRepositoryRoot = (& $gitExecutable -C $repositoryRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($reportedRepositoryRoot)) {
    throw '이 권한 준비 파일이 포함된 Git 저장소를 확인하지 못했습니다.'
}
$reportedRepositoryRoot = [System.IO.Path]::GetFullPath($reportedRepositoryRoot.Trim())
$pathComparison = if ($IsWindows) {
    [StringComparison]::OrdinalIgnoreCase
}
else {
    [StringComparison]::Ordinal
}
if (-not $reportedRepositoryRoot.Equals($repositoryRoot, $pathComparison)) {
    throw '권한 준비 파일 위치와 Git 저장소 루트가 다릅니다.'
}
$origin = (& $gitExecutable -C $repositoryRoot remote get-url origin 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -cne $expectedOrigin) {
    throw "origin이 예상 공개 저장소와 다릅니다: $expectedOrigin"
}
$workingTreeState = & $gitExecutable -C $repositoryRoot status --porcelain=v1
if ($LASTEXITCODE -ne 0 -or $workingTreeState) {
    throw '실행 전에 모든 변경사항을 커밋하고 Push하여 작업 폴더를 깨끗하게 만드세요.'
}
$sourceRevision = (& $gitExecutable -C $repositoryRoot rev-parse HEAD 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceRevision -notmatch '^[0-9a-f]{40}$') {
    throw '현재 Git commit을 40자리 SHA로 확인하지 못했습니다.'
}

$templateFile = Join-Path $repositoryRoot ($templateRepositoryPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
$policyFile = Join-Path $repositoryRoot ($policyRepositoryPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $templateFile -PathType Leaf) -or
    -not (Test-Path -LiteralPath $policyFile -PathType Leaf)) {
    throw '권한 준비 템플릿 또는 배포 권한 정책 파일이 없습니다.'
}
$templateText = [System.IO.File]::ReadAllText($templateFile)
$policyText = [System.IO.File]::ReadAllText($policyFile)
try {
    $localPolicy = $policyText | ConvertFrom-Json -Depth 100
}
catch {
    throw '로컬 배포 권한 정책 JSON을 해석하지 못했습니다.'
}
$policySha256 = Get-CanonicalJsonSha256 -Json $policyText
$metadataSection = [regex]::Split($templateText, '(?m)^Parameters:\s*$')[0]
$metadataRevisionMatches = [regex]::Matches(
    $metadataSection,
    "(?m)^\s{4}PolicyRevision:\s*'?(?<Value>[^'\r\n]+)'?\s*$"
)
$metadataShaMatches = [regex]::Matches(
    $metadataSection,
    '(?m)^\s{4}PolicySha256:\s*(?<Value>[0-9a-f]{64})\s*$'
)
if ($metadataRevisionMatches.Count -ne 1 -or $metadataShaMatches.Count -ne 1) {
    throw '권한 준비 템플릿 Metadata의 정책 revision 또는 SHA-256 계약이 정확하지 않습니다.'
}
$policyRevision = $metadataRevisionMatches[0].Groups['Value'].Value.Trim()
$templatePolicySha256 = $metadataShaMatches[0].Groups['Value'].Value
if ([string]::IsNullOrWhiteSpace($policyRevision) -or $templatePolicySha256 -cne $policySha256) {
    throw '권한 준비 템플릿 Metadata와 canonical 배포 정책 SHA-256이 다릅니다.'
}
$publicTemplateText = Get-PublicFileText -Revision $sourceRevision -RepositoryPath $templateRepositoryPath
$publicPolicyText = Get-PublicFileText -Revision $sourceRevision -RepositoryPath $policyRepositoryPath
if ((Get-NormalizedText -Text $publicTemplateText) -cne (Get-NormalizedText -Text $templateText) -or
    (Get-CanonicalJsonSha256 -Json $publicPolicyText) -cne $policySha256) {
    throw '공개 GitHub의 템플릿 또는 정책이 현재 로컬 commit 파일과 다릅니다.'
}
if (-not (Test-PolicyExcludesCleanupPermissions -Policy $localPolicy)) {
    throw '배포 권한 정책에 권한 스택 삭제·변경 또는 IAM 관리 권한이 포함되어 있습니다.'
}
$embeddedPolicyBegin = $templateText.IndexOf('# BEGIN_DEPLOYER_POLICY_JSON', [StringComparison]::Ordinal)
$embeddedPolicyStart = if ($embeddedPolicyBegin -ge 0) {
    $templateText.IndexOf('{', $embeddedPolicyBegin)
}
else {
    -1
}
$embeddedPolicyEnd = if ($embeddedPolicyStart -ge 0) {
    $templateText.IndexOf('# END_DEPLOYER_POLICY_JSON', $embeddedPolicyStart, [StringComparison]::Ordinal)
}
else {
    -1
}
if ($embeddedPolicyBegin -lt 0 -or $embeddedPolicyStart -lt 0 -or $embeddedPolicyEnd -lt 0 -or
    $templateText.IndexOf('# BEGIN_DEPLOYER_POLICY_JSON', $embeddedPolicyBegin + 1, [StringComparison]::Ordinal) -ge 0 -or
    $templateText.IndexOf('# END_DEPLOYER_POLICY_JSON', $embeddedPolicyEnd + 1, [StringComparison]::Ordinal) -ge 0) {
    throw '권한 준비 템플릿의 내장 정책 경계를 정확히 확인하지 못했습니다.'
}
$embeddedPolicyText = $templateText.Substring(
    $embeddedPolicyStart,
    $embeddedPolicyEnd - $embeddedPolicyStart
).Trim()
if ((Get-CanonicalJsonSha256 -Json $embeddedPolicyText) -cne $policySha256) {
    throw '권한 준비 템플릿의 내장 정책이 deployer-policy.json과 다릅니다.'
}

$templateFullPath = [System.IO.Path]::GetFullPath($templateFile)
$templateUri = "file://$($templateFullPath.Replace([System.IO.Path]::DirectorySeparatorChar, '/'))"
$templateValidation = Invoke-AwsJson -Arguments @(
    'cloudformation', 'validate-template', '--template-body', $templateUri
) -FailureMessage 'AWS CloudFormation이 권한 준비 템플릿을 검증하지 못했습니다.'
if (-not (Test-ExactStringSet -Actual @($templateValidation.Capabilities) `
        -Expected @('CAPABILITY_NAMED_IAM'))) {
    throw '권한 준비 템플릿의 CloudFormation capability가 named IAM 하나로 제한되지 않았습니다.'
}
$templateSummary = Invoke-AwsJson -Arguments @(
    'cloudformation', 'get-template-summary', '--template-body', $templateUri
) -FailureMessage 'AWS CloudFormation 템플릿의 자원 범위를 확인하지 못했습니다.'
$declaredTransforms = if ($templateSummary.PSObject.Properties.Name -contains 'DeclaredTransforms') {
    @($templateSummary.DeclaredTransforms)
}
else {
    @()
}
if (-not (Test-ExactStringSet -Actual @($templateSummary.ResourceTypes) `
        -Expected @('AWS::IAM::ManagedPolicy', 'AWS::IAM::Role')) -or
    @($templateSummary.ResourceTypes).Count -ne 2 -or
    $declaredTransforms.Count -ne 0) {
    throw '권한 준비 템플릿은 IAM 역할과 관리형 정책만 만들며 transform을 사용하지 않아야 합니다.'
}

$stackProbe = Invoke-AwsProbe -Arguments @(
    'cloudformation', 'describe-stacks', '--stack-name', $StackName
) -AbsentPattern 'does not exist' -FailureMessage '기존 권한 준비 스택을 확인하지 못했습니다.'
$roleProbe = Invoke-AwsProbe -Arguments @(
    'iam', 'get-role', '--role-name', $deploymentRoleName
) -AbsentPattern '(NoSuchEntity|cannot be found)' -FailureMessage '기존 배포 역할 이름을 확인하지 못했습니다.'
$deploymentRoleArn = "arn:aws:iam::$ExpectedAccountId`:role$deploymentRolePath$deploymentRoleName"
$deploymentPolicyArn = "arn:aws:iam::$ExpectedAccountId`:policy$deploymentPolicyPath$deploymentPolicyName"
$localPolicies = Invoke-AwsJson -Arguments @(
    'iam', 'list-policies', '--scope', 'Local'
) -FailureMessage '기존 고객 관리형 정책 이름을 확인하지 못했습니다.'
$policyNameConflicts = @(
    $localPolicies.Policies | Where-Object { [string]$_.PolicyName -ceq $deploymentPolicyName }
)

$plan = [pscustomobject]@{
    Action                    = if ($Execute) { 'create-access-stack' } else { 'plan-only' }
    Region                    = $Region
    StackName                 = $StackName
    AdminSession              = $adminSessionType
    AccountBinding            = 'same-account-verified'
    TrustedPrincipal          = $trustedPrincipalKind
    TrustedPrincipalInput     = $trustedPrincipalInputSource
    TrustedIamUserAccessKeys  = if ($trustedPrincipalKind -eq 'IamUser') { 'none-verified' } else { 'not-applicable' }
    TrustedIamUserMfa         = if ($trustedPrincipalKind -eq 'IamUser') { 'device-present-verified' } else { 'identity-center-managed' }
    TrustedPrincipalVerified  = $true
    ExistingStack             = [bool]$stackProbe.Exists
    ExistingDeploymentRole    = [bool]$roleProbe.Exists
    ExistingDeploymentPolicy  = $policyNameConflicts.Count -gt 0
    SourceRevision            = $sourceRevision
    CanonicalPolicySha256     = $policySha256
    PublicSourceVerified      = $true
    CreatesUsersOrKeys        = $false
    CloudFormationServiceRole = 'not-used'
    CleanupPermission         = 'not-included'
    TerminationProtection     = 'enabled-at-create'
    StackUpdatePolicy         = 'deny-all-updates'
    FailureRollback           = 'enabled-with-retain-except-on-create'
}
$plan | Format-List

if (-not $Execute) {
    Write-Host '권한 준비 계획만 검증했습니다. AWS 자원은 만들거나 변경하지 않았습니다.'
    Write-Host "검토 후 실행할 때 확인 문구는 다음과 같습니다: $confirmationText"
    exit 0
}
if ($stackProbe.Exists -or $roleProbe.Exists -or $policyNameConflicts.Count -gt 0) {
    throw '기존 권한 스택, 고정 배포 역할 또는 고정 배포 정책이 있습니다. 이 도구는 기존 IAM 자원을 채택하거나 업데이트하지 않습니다.'
}

$typedConfirmation = Read-Host "계속하려면 정확히 '$confirmationText' 를 입력하세요"
if ($typedConfirmation -cne $confirmationText) {
    throw '확인 문구가 정확하지 않아 AWS 변경을 시작하지 않았습니다.'
}

$stackParameters = @(
    [ordered]@{
        ParameterKey   = 'TrustedPrincipalKind'
        ParameterValue = $trustedPrincipalKind
    }
)
if ($trustedPrincipalKind -eq 'IamUser') {
    $stackParameters += [ordered]@{
        ParameterKey   = 'TrustedIamUserName'
        ParameterValue = $trustedIamUserName
    }
}
else {
    $stackParameters += @(
        [ordered]@{
            ParameterKey   = 'IdentityCenterPermissionSetName'
            ParameterValue = $identityCenterPermissionSetName
        },
        [ordered]@{
            ParameterKey   = 'IdentityCenterRegion'
            ParameterValue = $identityCenterRegion
        }
    )
}
$stackParametersJson = ConvertTo-Json -InputObject $stackParameters -Depth 5 -Compress
$stackPolicyJson = '{"Statement":[{"Effect":"Deny","Action":"Update:*","Principal":"*","Resource":"*"}]}'
$temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$parameterDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $temporaryRoot "qfc-access-$([Guid]::NewGuid().ToString('N'))")
)
if (-not $parameterDirectory.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'CloudFormation parameter 임시 경로가 운영체제 임시 폴더 밖으로 확인되었습니다.'
}
$null = New-Item -ItemType Directory -Path $parameterDirectory -ErrorAction Stop
$parameterFile = Join-Path $parameterDirectory 'parameters.json'
$parameterFileUri = "file://$($parameterFile.Replace([System.IO.Path]::DirectorySeparatorChar, '/'))"
$stackPolicyFile = Join-Path $parameterDirectory 'stack-policy.json'
$stackPolicyFileUri = "file://$($stackPolicyFile.Replace([System.IO.Path]::DirectorySeparatorChar, '/'))"
$createArguments = @(
    'cloudformation', 'create-stack',
    '--stack-name', $StackName,
    '--template-body', $templateUri,
    '--parameters', $parameterFileUri,
    '--stack-policy-body', $stackPolicyFileUri,
    '--capabilities', 'CAPABILITY_NAMED_IAM',
    '--enable-termination-protection',
    '--retain-except-on-create',
    '--tags',
    'Key=Project,Value=qfieldcloud-self-hosting',
    'Key=DeploymentProfile,Value=lab-lightsail',
    'Key=Purpose,Value=deployment-access',
    "Key=SourceRevision,Value=$sourceRevision",
    "Key=PolicySha256,Value=$policySha256"
) + (Get-AwsBaseArguments)

$createExitCode = $null
$createResult = $null
try {
    [System.IO.File]::WriteAllText(
        $parameterFile,
        $stackParametersJson,
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
        $stackPolicyFile,
        $stackPolicyJson,
        [System.Text.UTF8Encoding]::new($false)
    )
    $createResult = & $awsExecutable @createArguments 2>$null
    $createExitCode = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stackPolicyFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $parameterDirectory -Force -ErrorAction SilentlyContinue
}
if ($null -eq $createExitCode -or $createExitCode -ne 0) {
    $null = $createResult
    throw '일회성 권한 준비 스택 생성을 시작하지 못했습니다. 관리자 권한과 이름 충돌을 확인하세요.'
}
$null = $createResult

$waitArguments = @(
    'cloudformation', 'wait', 'stack-create-complete', '--stack-name', $StackName
) + (Get-AwsBaseArguments)
& $awsExecutable @waitArguments *> $null
if ($LASTEXITCODE -ne 0) {
    throw '권한 준비 스택 생성이 완료되지 않았습니다. 초기 생성 rollback 결과를 CloudFormation Events에서 확인하세요. 이 도구는 자동 삭제하지 않습니다.'
}

$stackResult = Invoke-AwsJson -Arguments @(
    'cloudformation', 'describe-stacks', '--stack-name', $StackName
) -FailureMessage '생성된 권한 준비 스택을 검증하지 못했습니다.'
$stacks = @($stackResult.Stacks)
if ($stacks.Count -ne 1) {
    throw '생성된 권한 준비 스택 수가 예상과 다릅니다.'
}
$stack = $stacks[0]
$stackRoleArn = if ($stack.PSObject.Properties.Name -contains 'RoleARN') {
    [string]$stack.RoleARN
}
else {
    ''
}
$retainExceptOnCreate = if ($stack.PSObject.Properties.Name -contains 'RetainExceptOnCreate') {
    [bool]$stack.RetainExceptOnCreate
}
else {
    $false
}
if ([string]$stack.StackStatus -cne 'CREATE_COMPLETE' -or
    -not [bool]$stack.EnableTerminationProtection -or
    [bool]$stack.DisableRollback -or
    -not $retainExceptOnCreate -or
    -not [string]::IsNullOrWhiteSpace($stackRoleArn) -or
    -not (Test-ExactStringSet -Actual @($stack.Capabilities) -Expected @('CAPABILITY_NAMED_IAM'))) {
    throw '생성된 권한 준비 스택의 상태, 보호, rollback 또는 service-role 설정이 예상과 다릅니다.'
}
$stackTags = @{}
foreach ($tag in @($stack.Tags)) {
    $stackTags[[string]$tag.Key] = [string]$tag.Value
}
if ($stackTags['Project'] -cne 'qfieldcloud-self-hosting' -or
    $stackTags['DeploymentProfile'] -cne 'lab-lightsail' -or
    $stackTags['Purpose'] -cne 'deployment-access' -or
    $stackTags['SourceRevision'] -cne $sourceRevision -or
    $stackTags['PolicySha256'] -cne $policySha256) {
    throw '생성된 권한 준비 스택의 출처 또는 정책 해시 태그가 예상과 다릅니다.'
}
$outputs = @{}
foreach ($output in @($stack.Outputs)) {
    $outputs[[string]$output.OutputKey] = [string]$output.OutputValue
}
$requiredOutputs = @(
    'DeploymentRoleArn', 'DeploymentPolicyArn', 'TrustedPrincipalKind',
    'TrustedPrincipalPattern', 'PolicyRevision', 'PolicySha256',
    'DeletionPermissionsIncluded'
)
if (-not (Test-ExactStringSet -Actual @($outputs.Keys) -Expected $requiredOutputs) -or
    $outputs['DeploymentRoleArn'] -cne $deploymentRoleArn -or
    $outputs['DeploymentPolicyArn'] -cne $deploymentPolicyArn -or
    $outputs['TrustedPrincipalKind'] -cne $trustedPrincipalKind -or
    $outputs['TrustedPrincipalPattern'] -cne $trustedPrincipalPattern -or
    $outputs['PolicySha256'] -cne $policySha256 -or
    $outputs['PolicyRevision'] -cne $policyRevision -or
    $outputs['DeletionPermissionsIncluded'] -cne 'false') {
    throw '생성된 권한 준비 스택 출력이 검토한 계정·역할·정책·신뢰 범위와 다릅니다.'
}

$resourcesResult = Invoke-AwsJson -Arguments @(
    'cloudformation', 'list-stack-resources', '--stack-name', $StackName
) -FailureMessage '권한 준비 스택의 포함 자원을 검증하지 못했습니다.'
$stackResources = @($resourcesResult.StackResourceSummaries)
if ($stackResources.Count -ne 2 -or
    -not (Test-ExactStringSet -Actual @($stackResources.ResourceType) `
        -Expected @('AWS::IAM::ManagedPolicy', 'AWS::IAM::Role'))) {
    throw '권한 준비 스택에 예상하지 않은 자원 유형이 포함되어 있습니다.'
}

$stackPolicyResult = Invoke-AwsJson -Arguments @(
    'cloudformation', 'get-stack-policy', '--stack-name', $StackName
) -FailureMessage '권한 준비 스택의 업데이트 금지 정책을 검증하지 못했습니다.'
try {
    $actualStackPolicy = [string]$stackPolicyResult.StackPolicyBody | ConvertFrom-Json -Depth 20
    $expectedStackPolicy = $stackPolicyJson | ConvertFrom-Json -Depth 20
}
catch {
    throw '권한 준비 스택의 업데이트 금지 정책을 해석하지 못했습니다.'
}
$actualStackPolicyText = $actualStackPolicy | ConvertTo-Json -Depth 20 -Compress
$expectedStackPolicyText = $expectedStackPolicy | ConvertTo-Json -Depth 20 -Compress
if ((Get-CanonicalJsonSha256 -Json $actualStackPolicyText) -cne
    (Get-CanonicalJsonSha256 -Json $expectedStackPolicyText)) {
    throw '권한 준비 스택의 정책이 모든 CloudFormation 업데이트를 거부하지 않습니다.'
}

$roleResult = Invoke-AwsJson -Arguments @(
    'iam', 'get-role', '--role-name', $deploymentRoleName
) -FailureMessage '생성된 배포 역할을 검증하지 못했습니다.'
$role = $roleResult.Role
if ([string]$role.RoleName -cne $deploymentRoleName -or
    [string]$role.Path -cne $deploymentRolePath -or
    [string]$role.Arn -cne $deploymentRoleArn -or
    [int]$role.MaxSessionDuration -ne 3600 -or
    [string]$role.PermissionsBoundary.PermissionsBoundaryType -cne 'PermissionsBoundaryPolicy' -or
    [string]$role.PermissionsBoundary.PermissionsBoundaryArn -cne $deploymentPolicyArn) {
    throw '생성된 배포 역할의 이름, 경로, 세션 시간 또는 permissions boundary가 예상과 다릅니다.'
}
Assert-RoleTrustPolicy -TrustPolicy $role.AssumeRolePolicyDocument `
    -PrincipalKind $trustedPrincipalKind -ExpectedPattern $trustedPrincipalPattern

$attachedResult = Invoke-AwsJson -Arguments @(
    'iam', 'list-attached-role-policies', '--role-name', $deploymentRoleName
) -FailureMessage '생성된 배포 역할의 연결 정책을 검증하지 못했습니다.'
$attachedPolicies = @($attachedResult.AttachedPolicies)
if ($attachedPolicies.Count -ne 1 -or
    [string]$attachedPolicies[0].PolicyName -cne $deploymentPolicyName -or
    [string]$attachedPolicies[0].PolicyArn -cne $deploymentPolicyArn) {
    throw '생성된 배포 역할에는 검토한 관리형 정책 하나만 연결되어야 합니다.'
}
$inlineResult = Invoke-AwsJson -Arguments @(
    'iam', 'list-role-policies', '--role-name', $deploymentRoleName
) -FailureMessage '생성된 배포 역할의 인라인 정책을 검증하지 못했습니다.'
if (@($inlineResult.PolicyNames).Count -ne 0) {
    throw '생성된 배포 역할에 예상하지 않은 인라인 정책이 있습니다.'
}

$policyResult = Invoke-AwsJson -Arguments @(
    'iam', 'get-policy', '--policy-arn', $deploymentPolicyArn
) -FailureMessage '생성된 배포 관리형 정책을 검증하지 못했습니다.'
$managedPolicy = $policyResult.Policy
if ([string]$managedPolicy.PolicyName -cne $deploymentPolicyName -or
    [string]$managedPolicy.Path -cne $deploymentPolicyPath -or
    [string]$managedPolicy.Arn -cne $deploymentPolicyArn -or
    -not [bool]$managedPolicy.IsAttachable -or
    [int]$managedPolicy.AttachmentCount -ne 1 -or
    [int]$managedPolicy.PermissionsBoundaryUsageCount -ne 1) {
    throw '생성된 배포 관리형 정책의 이름, 경로, 연결 또는 boundary 사용 상태가 예상과 다릅니다.'
}
$versionsResult = Invoke-AwsJson -Arguments @(
    'iam', 'list-policy-versions', '--policy-arn', $deploymentPolicyArn
) -FailureMessage '생성된 배포 정책 버전을 검증하지 못했습니다.'
$policyVersions = @($versionsResult.Versions)
if ($policyVersions.Count -ne 1 -or
    -not [bool]$policyVersions[0].IsDefaultVersion -or
    [string]$policyVersions[0].VersionId -cne [string]$managedPolicy.DefaultVersionId) {
    throw '생성된 배포 정책에는 기본 버전 하나만 있어야 합니다.'
}
$policyVersionResult = Invoke-AwsJson -Arguments @(
    'iam', 'get-policy-version', '--policy-arn', $deploymentPolicyArn,
    '--version-id', [string]$managedPolicy.DefaultVersionId
) -FailureMessage '생성된 배포 정책의 기본 문서를 검증하지 못했습니다.'
$deployedPolicy = Get-PolicyDocumentObject -Document $policyVersionResult.PolicyVersion.Document
$deployedPolicyText = $deployedPolicy | ConvertTo-Json -Depth 100 -Compress
if ((Get-CanonicalJsonSha256 -Json $deployedPolicyText) -cne $policySha256 -or
    -not (Test-PolicyExcludesCleanupPermissions -Policy $deployedPolicy)) {
    throw '생성된 기본 배포 정책이 공개 commit의 검토된 정책 또는 삭제 제외 조건과 다릅니다.'
}

[pscustomobject]@{
    Result                    = 'access-stack-create-complete'
    StackName                 = $StackName
    Region                    = $Region
    DeploymentRole            = 'verified'
    TrustedPrincipal          = $trustedPrincipalKind
    PolicyRevision            = $outputs['PolicyRevision']
    CanonicalPolicySha256     = $policySha256
    SourceRevision            = $sourceRevision
    PermissionsBoundary       = 'same-policy-verified'
    InlinePolicies            = 'none'
    CleanupPermission         = 'not-included'
    TerminationProtection     = 'enabled'
    StackUpdatePolicy         = 'deny-all-updates'
    FailureRollback           = 'enabled'
}

Write-Host '일회성 배포 권한 스택 생성과 최소 권한 검증이 완료되었습니다.'
Write-Host 'IAM 사용자, 그룹, 비밀번호, 접근키 또는 파일럿 애플리케이션은 만들거나 변경하지 않았습니다.'
