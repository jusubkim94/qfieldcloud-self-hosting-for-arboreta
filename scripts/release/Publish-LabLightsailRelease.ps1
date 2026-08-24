#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(?=.{3,63}$)[a-z0-9][a-z0-9.-]*[a-z0-9]$')]
    [string]$BucketName,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{0,200}$')]
    [string]$KeyPrefix = 'qfieldcloud/lab-lightsail/releases',

    [ValidateSet('ap-northeast-2')]
    [string]$Region = 'ap-northeast-2',

    [AllowEmptyString()]
    [ValidatePattern('^(?:[A-Za-z0-9_-]{1,64})?$')]
    [string]$Profile = '',

    [ValidateSet('object', 'json')]
    [string]$PlanOutputFormat = 'object',

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredFileNames = @('template.yaml', 'manifest.json', 'SHA256SUMS')
$releaseVersionPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
$revisionPlaceholderPattern = '(?<![0-9])0{40}(?![0-9])'
$bootstrapShaPlaceholderPattern = '(?<![0-9])0{64}(?![0-9])'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
$awsExecutable = ''

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    return ([Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($Bytes)
    )).ToLowerInvariant()
}

function Get-Sha256Base64 {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    return [Convert]::ToBase64String(
        [System.Security.Cryptography.SHA256]::HashData($Bytes)
    )
}

function Assert-NoAwsEndpointOverride {
    foreach ($name in [Environment]::GetEnvironmentVariables().Keys) {
        $environmentName = [string]$name
        if ($environmentName.Equals('AWS_ENDPOINT_URL', [StringComparison]::OrdinalIgnoreCase) -or
            $environmentName.StartsWith('AWS_ENDPOINT_URL_', [StringComparison]::OrdinalIgnoreCase)) {
            throw '공식 AWS S3 endpoint를 검증하려면 AWS_ENDPOINT_URL 환경변수를 제거해야 합니다.'
        }
    }
}

function Get-AwsExecutable {
    $command = Get-Command aws -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) {
        throw 'AWS CLI v2를 찾지 못했습니다. 계획 모드에는 필요하지 않지만 -Execute 게시에는 필요합니다.'
    }
    $candidate = [System.IO.Path]::GetFullPath($command.Source)
    $version = & $candidate --version 2>&1
    if ($LASTEXITCODE -ne 0 -or ($version -join ' ') -notmatch '^aws-cli/2\.') {
        throw 'S3 게시에는 공식 AWS CLI v2가 필요합니다.'
    }
    return $candidate
}

function Invoke-AwsRaw {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    if ([string]::IsNullOrWhiteSpace($script:awsExecutable)) {
        throw 'AWS 실행 파일이 준비되지 않았습니다.'
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:awsExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['AWS_PAGER'] = ''
    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }
    $null = $startInfo.ArgumentList.Add('--region')
    $null = $startInfo.ArgumentList.Add($Region)
    # Command-line endpoint selection has higher precedence than shared AWS
    # profile settings. This prevents a profile-level S3 endpoint override from
    # publishing to, or verifying against, a non-AWS service.
    $null = $startInfo.ArgumentList.Add('--endpoint-url')
    $null = $startInfo.ArgumentList.Add("https://s3.$Region.amazonaws.com")
    $null = $startInfo.ArgumentList.Add('--no-cli-pager')
    $null = $startInfo.ArgumentList.Add('--output')
    $null = $startInfo.ArgumentList.Add('json')
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $null = $startInfo.ArgumentList.Add('--profile')
        $null = $startInfo.ArgumentList.Add($Profile)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'AWS CLI 작업을 시작하지 못했습니다.'
        }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $outputText = $outputTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        $result = [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $outputText
            Error = $errorText
        }
        if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
            throw 'AWS S3 작업이 실패했습니다. 권한, 버킷 리전, 버전 관리 및 객체 키 충돌을 확인하세요.'
        }
        return $result
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $result = Invoke-AwsRaw -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return [pscustomobject]@{}
    }
    try {
        return $result.Output | ConvertFrom-Json -Depth 100
    }
    catch {
        throw 'AWS CLI가 해석할 수 없는 JSON을 반환했습니다.'
    }
}

function Get-RemoteHead {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $result = Invoke-AwsRaw -Arguments @(
        's3api', 'head-object',
        '--bucket', $BucketName,
        '--key', $Key,
        '--checksum-mode', 'ENABLED'
    ) -AllowFailure
    if ($result.ExitCode -eq 0) {
        try {
            return $result.Output | ConvertFrom-Json -Depth 30
        }
        catch {
            throw 'S3 객체 메타데이터 JSON을 해석하지 못했습니다.'
        }
    }
    if ($result.Error -match '(?i)(\(404\)|Not Found|NoSuchKey)') {
        return $null
    }
    throw 'S3 객체 존재 여부를 확인하지 못했습니다. 없는 객체와 권한 오류를 구분할 수 없어 게시하지 않습니다.'
}

function Assert-KeyHasNoHistoricalVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $versions = Invoke-AwsJson -Arguments @(
        's3api', 'list-object-versions',
        '--bucket', $BucketName,
        '--prefix', $Key
    )
    $matchingVersions = @()
    if ($versions.PSObject.Properties.Name -contains 'Versions') {
        $matchingVersions += @($versions.Versions | Where-Object { [string]$_.Key -ceq $Key })
    }
    if ($versions.PSObject.Properties.Name -contains 'DeleteMarkers') {
        $matchingVersions += @($versions.DeleteMarkers | Where-Object { [string]$_.Key -ceq $Key })
    }
    if ($matchingVersions.Count -gt 0) {
        throw "현재 보이지 않지만 과거 version 또는 삭제 표식이 있는 release key는 재사용하지 않습니다: $Key"
    }
}

function Assert-RemoteObjectMatches {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Head,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-f]{64}$')]
        [string]$Sha256Hex,

        [Parameter(Mandatory = $true)]
        [string]$Sha256Base64,

        [Parameter(Mandatory = $true)]
        [string]$ReleaseVersion,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$SourceRevision
    )

    $metadata = $Head.Metadata
    $remoteVersionId = [string]$Head.VersionId
    if ([long]$Head.ContentLength -ne $Bytes.LongLength -or
        [string]$Head.ChecksumSHA256 -cne $Sha256Base64 -or
        [string]$metadata.sha256 -cne $Sha256Hex -or
        [string]$metadata.'release-version' -cne $ReleaseVersion -or
        [string]$metadata.'source-revision' -cne $SourceRevision -or
        [string]::IsNullOrWhiteSpace($remoteVersionId) -or
        $remoteVersionId -ceq 'null') {
        throw "게시된 S3 객체의 checksum, 길이, release metadata 또는 VersionId가 다릅니다: $FileName"
    }
    return $remoteVersionId
}

function Publish-OrVerifyObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [string]$ContentType,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
        [string]$ReleaseVersion,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$SourceRevision
    )

    $sha256Hex = Get-Sha256Hex -Bytes $Bytes
    $sha256Base64 = Get-Sha256Base64 -Bytes $Bytes
    $existingHead = Get-RemoteHead -Key $Key
    if ($null -ne $existingHead) {
        return Assert-RemoteObjectMatches -Head $existingHead -FileName $FileName `
            -Bytes $Bytes -Sha256Hex $sha256Hex -Sha256Base64 $sha256Base64 `
            -ReleaseVersion $ReleaseVersion -SourceRevision $SourceRevision
    }

    Assert-KeyHasNoHistoricalVersion -Key $Key
    $metadata = "sha256=$sha256Hex,release-version=$ReleaseVersion,source-revision=$SourceRevision"
    $putResult = Invoke-AwsJson -Arguments @(
        's3api', 'put-object',
        '--bucket', $BucketName,
        '--key', $Key,
        '--body', $FilePath,
        '--content-type', $ContentType,
        '--checksum-algorithm', 'SHA256',
        '--checksum-sha256', $sha256Base64,
        '--metadata', $metadata,
        '--if-none-match', '*'
    )
    $putVersionId = [string]$putResult.VersionId
    if ([string]::IsNullOrWhiteSpace($putVersionId) -or $putVersionId -ceq 'null' -or
        [string]$putResult.ChecksumSHA256 -cne $sha256Base64) {
        throw "S3가 checksum과 VersionId를 포함한 업로드 확인을 반환하지 않았습니다: $FileName"
    }

    $publishedHead = Get-RemoteHead -Key $Key
    $verifiedVersionId = Assert-RemoteObjectMatches -Head $publishedHead `
        -FileName $FileName -Bytes $Bytes -Sha256Hex $sha256Hex `
        -Sha256Base64 $sha256Base64 -ReleaseVersion $ReleaseVersion `
        -SourceRevision $SourceRevision
    if ($verifiedVersionId -cne $putVersionId) {
        throw "업로드 직후 S3 현재 VersionId가 바뀌었습니다. release key를 사용하지 않습니다: $FileName"
    }
    return $verifiedVersionId
}

function ConvertTo-UrlPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return (($Value -split '/') | ForEach-Object {
        [Uri]::EscapeDataString($_)
    }) -join '/'
}

function New-S3VersionedHttpsUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$VersionId
    )

    $encodedKey = ConvertTo-UrlPath -Value $Key
    $encodedVersionId = [Uri]::EscapeDataString($VersionId)
    if ($BucketName.Contains('.', [StringComparison]::Ordinal)) {
        return "https://s3.$Region.amazonaws.com/$BucketName/$encodedKey`?versionId=$encodedVersionId"
    }
    return "https://$BucketName.s3.$Region.amazonaws.com/$encodedKey`?versionId=$encodedVersionId"
}

function New-QuickCreateUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateUrl
    )

    $reviewParameters = [ordered]@{
        stackName = 'qfieldcloud-pilot'
        templateURL = $TemplateUrl
        param_DeploymentRegion = 'ap-northeast-2'
        param_AvailabilityZone = 'ap-northeast-2a'
        param_InstanceName = 'qfieldcloud-pilot'
        param_CertificateMode = 'letsencrypt-ip'
        param_LetsEncryptTermsAccepted = 'false'
    }
    $encodedReviewParameters = @(
        foreach ($entry in $reviewParameters.GetEnumerator()) {
            '{0}={1}' -f (
                [Uri]::EscapeDataString([string]$entry.Key),
                [Uri]::EscapeDataString([string]$entry.Value)
            )
        }
    ) -join '&'
    $quickCreateUrl = "https://$Region.console.aws.amazon.com/cloudformation/home?region=$Region#/stacks/create/review?$encodedReviewParameters"
    if ($quickCreateUrl.Length -gt 1024) {
        throw 'CloudFormation Quick Create URL이 AWS의 1,024자 제한을 넘습니다. 버킷 또는 key prefix를 줄이세요.'
    }
    return $quickCreateUrl
}

function Assert-PublishedBootstrapMatches {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$SourceRevision,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-f]{64}$')]
        [string]$ExpectedSha256,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 1048576)]
        [long]$ExpectedSizeBytes
    )

    # The instance downloads this exact public URL during bootstrap. Prove that
    # the selected commit was pushed and that GitHub serves the same bytes used
    # by the local artifact builder before making any S3 write.
    $bootstrapUrl = [Uri](
        'https://raw.githubusercontent.com/' +
        'jusubkim94/qfieldcloud-self-hosting-for-arboreta/' +
        "$SourceRevision/scripts/lab-lightsail/bootstrap.sh"
    )
    if ($bootstrapUrl.Scheme -cne 'https' -or
        $bootstrapUrl.Host -cne 'raw.githubusercontent.com' -or
        -not [string]::IsNullOrEmpty($bootstrapUrl.Query) -or
        -not [string]::IsNullOrEmpty($bootstrapUrl.Fragment)) {
        throw '고정 bootstrap URL이 허용된 GitHub HTTPS 원본을 가리키지 않습니다.'
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseDefaultCredentials = $false
    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Get,
        $bootstrapUrl
    )
    $null = $request.Headers.UserAgent.TryParseAdd(
        'qfieldcloud-lab-lightsail-release-publisher/1.0'
    )
    $response = $null
    $stream = $null
    $buffered = [System.IO.MemoryStream]::new([int]$ExpectedSizeBytes)
    try {
        $response = $client.Send(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        )
        if ($response.StatusCode -ne [System.Net.HttpStatusCode]::OK) {
            throw "고정 GitHub bootstrap을 읽지 못했습니다(HTTP $([int]$response.StatusCode)). 선택 commit을 공개 원격 저장소에 push했는지 확인하세요."
        }
        if ($null -ne $response.Content.Headers.ContentLength -and
            [long]$response.Content.Headers.ContentLength -ne $ExpectedSizeBytes) {
            throw 'GitHub bootstrap의 Content-Length가 manifest와 다릅니다.'
        }

        $stream = $response.Content.ReadAsStream()
        $buffer = [byte[]]::new(8192)
        while (($readCount = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if (($buffered.Length + $readCount) -gt $ExpectedSizeBytes) {
                throw 'GitHub bootstrap이 manifest에 기록된 크기보다 큽니다.'
            }
            $buffered.Write($buffer, 0, $readCount)
        }
        $downloadedBytes = $buffered.ToArray()
        if ($downloadedBytes.LongLength -ne $ExpectedSizeBytes -or
            (Get-Sha256Hex -Bytes $downloadedBytes) -cne $ExpectedSha256) {
            throw 'GitHub bootstrap의 길이 또는 SHA-256이 commit artifact manifest와 다릅니다.'
        }
    }
    catch [System.Net.Http.HttpRequestException] {
        throw '고정 GitHub bootstrap HTTPS 검증에 실패했습니다. 네트워크와 공개 원격 commit을 확인하세요.'
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
        $buffered.Dispose()
        $request.Dispose()
        $client.Dispose()
    }
}

if ($BucketName.Contains('..', [StringComparison]::Ordinal) -or
    $BucketName.Contains('.-', [StringComparison]::Ordinal) -or
    $BucketName.Contains('-.', [StringComparison]::Ordinal) -or
    $BucketName -match '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$') {
    throw 'BucketName이 유효한 일반 목적 S3 버킷 DNS 이름이 아닙니다.'
}
if ($KeyPrefix.Contains('..', [StringComparison]::Ordinal) -or
    $KeyPrefix.Contains('//', [StringComparison]::Ordinal) -or
    $KeyPrefix.EndsWith('/', [StringComparison]::Ordinal)) {
    throw 'KeyPrefix는 상위 경로, 빈 경로 요소 또는 끝 슬래시를 포함할 수 없습니다.'
}
$artifactDirectoryFullPath = [System.IO.Path]::GetFullPath($ArtifactDirectory)
$artifactDirectoryItem = Get-Item -LiteralPath $artifactDirectoryFullPath -Force
if (-not $artifactDirectoryItem.PSIsContainer -or
    ($artifactDirectoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw 'ArtifactDirectory는 심볼릭 링크가 아닌 일반 디렉터리여야 합니다.'
}
$actualArtifactNames = @(
    Get-ChildItem -LiteralPath $artifactDirectoryFullPath -Force |
        ForEach-Object { $_.Name } |
        Sort-Object
)
$expectedArtifactNames = @($requiredFileNames | Sort-Object)
if (($actualArtifactNames -join "`n") -cne ($expectedArtifactNames -join "`n")) {
    throw 'ArtifactDirectory에는 builder가 만든 template.yaml, manifest.json, SHA256SUMS만 있어야 합니다.'
}

$artifactBytes = [ordered]@{}
foreach ($fileName in $requiredFileNames) {
    $filePath = Join-Path $artifactDirectoryFullPath $fileName
    $fileItem = Get-Item -LiteralPath $filePath -Force
    if ($fileItem.PSIsContainer -or
        ($fileItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Artifact는 심볼릭 링크가 아닌 일반 파일이어야 합니다: $fileName"
    }
    $artifactBytes[$fileName] = [System.IO.File]::ReadAllBytes($filePath)
}

try {
    $checksumsText = $utf8NoBom.GetString([byte[]]$artifactBytes['SHA256SUMS'])
    $manifestText = $utf8NoBom.GetString([byte[]]$artifactBytes['manifest.json'])
    $templateText = $utf8NoBom.GetString([byte[]]$artifactBytes['template.yaml'])
}
catch {
    throw 'Release artifact 텍스트 파일은 BOM 없는 유효한 UTF-8이어야 합니다.'
}
$checksumLines = @($checksumsText -split "`n" | Where-Object { $_ -ne '' })
if ($checksumLines.Count -ne 2) {
    throw 'SHA256SUMS는 template.yaml과 manifest.json 두 항목만 포함해야 합니다.'
}
$declaredChecksums = @{}
foreach ($line in $checksumLines) {
    $match = [regex]::Match($line.TrimEnd("`r"), '^([0-9a-f]{64})  (template\.yaml|manifest\.json)$')
    if (-not $match.Success -or $declaredChecksums.ContainsKey($match.Groups[2].Value)) {
        throw 'SHA256SUMS 형식 또는 항목 중복이 잘못되었습니다.'
    }
    $declaredChecksums[$match.Groups[2].Value] = $match.Groups[1].Value
}
foreach ($fileName in @('template.yaml', 'manifest.json')) {
    $actualSha256 = Get-Sha256Hex -Bytes ([byte[]]$artifactBytes[$fileName])
    if (-not $declaredChecksums.ContainsKey($fileName) -or
        [string]$declaredChecksums[$fileName] -cne $actualSha256) {
        throw "SHA256SUMS와 실제 artifact가 다릅니다: $fileName"
    }
}

try {
    $manifest = $manifestText | ConvertFrom-Json -Depth 30
}
catch {
    throw 'manifest.json을 해석하지 못했습니다.'
}
$releaseVersion = [string]$manifest.release_version
$sourceRevision = [string]$manifest.source_revision
$templateSha256 = Get-Sha256Hex -Bytes ([byte[]]$artifactBytes['template.yaml'])
if ([int]$manifest.schema_version -ne 1 -or
    $releaseVersion -notmatch $releaseVersionPattern -or
    $sourceRevision -notmatch '^[0-9a-f]{40}$' -or
    [string]$manifest.source_repository -cne 'https://github.com/jusubkim94/qfieldcloud-self-hosting-for-arboreta.git' -or
    [string]$manifest.aws_region -cne $Region -or
    [string]$manifest.quick_create_stack_name -cne 'qfieldcloud-pilot' -or
    [string]$manifest.template.file -cne 'template.yaml' -or
    [string]$manifest.template.sha256 -cne $templateSha256 -or
    [long]$manifest.template.size_bytes -ne ([byte[]]$artifactBytes['template.yaml']).LongLength -or
    [string]$manifest.bootstrap.source_path -cne 'scripts/lab-lightsail/bootstrap.sh' -or
    [string]$manifest.bootstrap.sha256 -notmatch '^[0-9a-f]{64}$' -or
    [long]$manifest.bootstrap.size_bytes -lt 1 -or
    [long]$manifest.bootstrap.size_bytes -gt 1048576) {
    throw 'manifest.json의 release, revision, region, stack 또는 checksum 계약이 잘못되었습니다.'
}
if ($templateText.Contains('__RELEASE_VERSION__', [StringComparison]::Ordinal) -or
    [regex]::IsMatch($templateText, $revisionPlaceholderPattern) -or
    [regex]::IsMatch($templateText, $bootstrapShaPlaceholderPattern) -or
    -not $templateText.Contains($sourceRevision, [StringComparison]::Ordinal) -or
    -not $templateText.Contains([string]$manifest.bootstrap.sha256, [StringComparison]::Ordinal)) {
    throw '게시할 template.yaml에 placeholder가 남았거나 manifest pin이 포함되지 않았습니다.'
}

$releaseKeyRoot = "$KeyPrefix/$releaseVersion"
$objectDefinitions = @(
    [pscustomobject]@{
        FileName = 'manifest.json'
        Key = "$releaseKeyRoot/manifest.json"
        ContentType = 'application/json'
    },
    [pscustomobject]@{
        FileName = 'SHA256SUMS'
        Key = "$releaseKeyRoot/SHA256SUMS"
        ContentType = 'text/plain; charset=utf-8'
    },
    [pscustomobject]@{
        FileName = 'template.yaml'
        Key = "$releaseKeyRoot/template.yaml"
        ContentType = 'application/yaml'
    }
)

$plan = [pscustomobject]@{
    Action = if ($Execute) { 'publish-or-verify-existing-release' } else { 'plan-only' }
    AwsWriteRequested = $Execute.IsPresent
    Bucket = $BucketName
    Region = $Region
    ReleaseVersion = $releaseVersion
    ReleaseKeyPrefix = $releaseKeyRoot
    SourceRevision = $sourceRevision
    TemplateSha256 = $templateSha256
    Objects = ($objectDefinitions.Key -join ',')
    BucketCreation = 'never'
    RequiredBucketVersioning = 'Enabled'
    RequiredTemplateReadAccess = 'anonymous-s3:GetObjectVersion'
    SourceReachabilityCheck = 'exact-GitHub-raw-bytes-before-any-AWS-write'
    QuickCreateUrl = if ($Execute) { 'generated-after-version-id-verification' } else { 'available-only-after--Execute' }
}
if ($PlanOutputFormat -ceq 'json') {
    $plan | ConvertTo-Json -Compress
}
else {
    $plan
}

if (-not $Execute) {
    Write-Host '계획만 검증했습니다. AWS API를 호출하거나 S3 객체를 만들지 않았습니다.'
    Write-Host '실제 게시에는 기존 ap-northeast-2 S3 버킷, 활성화된 Versioning, 게시 template version의 익명 읽기 정책, 필요한 최소 권한과 명시적 -Execute가 필요합니다.'
    exit 0
}

Assert-NoAwsEndpointOverride
Assert-PublishedBootstrapMatches -SourceRevision $sourceRevision `
    -ExpectedSha256 ([string]$manifest.bootstrap.sha256) `
    -ExpectedSizeBytes ([long]$manifest.bootstrap.size_bytes)
$awsExecutable = Get-AwsExecutable
$bucketLocation = Invoke-AwsJson -Arguments @(
    's3api', 'get-bucket-location', '--bucket', $BucketName
)
if ([string]$bucketLocation.LocationConstraint -cne $Region) {
    throw '기존 S3 버킷이 ap-northeast-2에 있지 않습니다. 이 도구는 버킷을 만들거나 옮기지 않습니다.'
}
$bucketVersioning = Invoke-AwsJson -Arguments @(
    's3api', 'get-bucket-versioning', '--bucket', $BucketName
)
if ([string]$bucketVersioning.Status -cne 'Enabled') {
    throw '기존 S3 버킷의 Versioning이 Enabled가 아니므로 immutable release URL을 만들 수 없습니다.'
}

$publishedVersions = [ordered]@{}
foreach ($definition in $objectDefinitions) {
    $filePath = Join-Path $artifactDirectoryFullPath $definition.FileName
    $publishedVersions[$definition.FileName] = Publish-OrVerifyObject `
        -Key $definition.Key `
        -FileName $definition.FileName `
        -FilePath $filePath `
        -Bytes ([byte[]]$artifactBytes[$definition.FileName]) `
        -ContentType $definition.ContentType `
        -ReleaseVersion $releaseVersion `
        -SourceRevision $sourceRevision
}

$templateDefinition = @($objectDefinitions | Where-Object { $_.FileName -ceq 'template.yaml' })[0]
$templateVersionId = [string]$publishedVersions['template.yaml']
$templateUrl = New-S3VersionedHttpsUrl -Key $templateDefinition.Key `
    -VersionId $templateVersionId
$anonymousHeadResult = Invoke-AwsRaw -Arguments @(
    's3api', 'head-object',
    '--bucket', $BucketName,
    '--key', $templateDefinition.Key,
    '--version-id', $templateVersionId,
    '--checksum-mode', 'ENABLED',
    '--no-sign-request'
) -AllowFailure
if ($anonymousHeadResult.ExitCode -ne 0) {
    throw '게시된 template version을 자격증명 없이 읽을 수 없습니다. 버킷을 만들거나 정책을 바꾸지 않았으며 Quick Create URL도 발행하지 않습니다.'
}
try {
    $anonymousHead = $anonymousHeadResult.Output | ConvertFrom-Json -Depth 30
}
catch {
    throw '익명 S3 template 검증 응답을 해석하지 못했습니다.'
}
$templateSha256Base64 = Get-Sha256Base64 -Bytes ([byte[]]$artifactBytes['template.yaml'])
if ([string]$anonymousHead.VersionId -cne $templateVersionId -or
    [long]$anonymousHead.ContentLength -ne ([byte[]]$artifactBytes['template.yaml']).LongLength -or
    [string]$anonymousHead.ChecksumSHA256 -cne $templateSha256Base64) {
    throw '익명으로 읽은 template version의 VersionId, 길이 또는 checksum이 로컬 artifact와 다릅니다.'
}
$quickCreateUrl = New-QuickCreateUrl -TemplateUrl $templateUrl

[pscustomobject]@{
    Result = 'release-published-and-verified'
    Bucket = $BucketName
    Region = $Region
    ReleaseVersion = $releaseVersion
    SourceRevision = $sourceRevision
    TemplateSha256 = $templateSha256
    TemplateVersionId = $templateVersionId
    TemplateUrl = $templateUrl
    QuickCreateUrl = $quickCreateUrl
}
Write-Output "QFC_TEMPLATE_URL=$templateUrl"
Write-Output "QFC_QUICK_CREATE_URL=$quickCreateUrl"
