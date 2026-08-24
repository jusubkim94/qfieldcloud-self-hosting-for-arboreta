#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$ReleaseVersion,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$')]
    [string]$Revision = 'HEAD',

    [AllowEmptyString()]
    [string]$OutputRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$templateRepositoryPath = 'infra/lab-lightsail/template.yaml'
$bootstrapRepositoryPath = 'scripts/lab-lightsail/bootstrap.sh'
$releasePlaceholder = '__RELEASE_VERSION__'
$revisionPlaceholderPattern = '(?<![0-9])0{40}(?![0-9])'
$bootstrapShaPlaceholderPattern = '(?<![0-9])0{64}(?![0-9])'
$requiredRevisionPlaceholderCount = 4
$requiredBootstrapShaPlaceholderCount = 2
$requiredReleasePlaceholderCount = 1
$artifactFileNames = @('template.yaml', 'manifest.json', 'SHA256SUMS')
$utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    return ([Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($Bytes)
    )).ToLowerInvariant()
}

function Get-GitExecutable {
    $command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) {
        throw 'Git 실행 파일을 찾지 못했습니다. 이 도구는 배포 사용자가 아니라 릴리스 관리자용입니다.'
    }
    return [System.IO.Path]::GetFullPath($command.Source)
}

function Get-GitBlobBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string]$Commit,

        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'infra/lab-lightsail/template.yaml',
            'scripts/lab-lightsail/bootstrap.sh'
        )]
        [string]$RepositoryPath
    )

    $safeRepositoryRoot = $RepositoryRoot.Replace('\', '/')
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GitExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $null = $startInfo.ArgumentList.Add('-c')
    $null = $startInfo.ArgumentList.Add("safe.directory=$safeRepositoryRoot")
    $null = $startInfo.ArgumentList.Add('-C')
    $null = $startInfo.ArgumentList.Add($RepositoryRoot)
    $null = $startInfo.ArgumentList.Add('show')
    $null = $startInfo.ArgumentList.Add("$Commit`:$RepositoryPath")

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $output = [System.IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) {
            throw "Git blob 읽기를 시작하지 못했습니다: $RepositoryPath"
        }
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($output)
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $null = $copyTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $null = $errorText
            throw "선택한 commit에서 필수 릴리스 파일을 읽지 못했습니다: $RepositoryPath"
        }
        # Prevent PowerShell from enumerating the byte array into individual
        # pipeline objects; callers must receive the exact Git blob bytes.
        return ,$output.ToArray()
    }
    finally {
        $output.Dispose()
        $process.Dispose()
    }
}

function Assert-ExactExistingArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$ExpectedArtifacts
    )

    $directoryItem = Get-Item -LiteralPath $Directory -Force
    if (-not $directoryItem.PSIsContainer -or
        ($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw '기존 artifact 대상은 심볼릭 링크가 아닌 일반 디렉터리여야 합니다.'
    }

    $entries = @(Get-ChildItem -LiteralPath $Directory -Force)
    $actualNames = @($entries | ForEach-Object { $_.Name } | Sort-Object)
    $expectedNames = @($ExpectedArtifacts.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    if (($actualNames -join "`n") -cne ($expectedNames -join "`n")) {
        throw '기존 release artifact 디렉터리가 정확한 세 파일만 포함하지 않습니다. 자동 덮어쓰지 않습니다.'
    }

    foreach ($fileName in $expectedNames) {
        $path = Join-Path $Directory $fileName
        $item = Get-Item -LiteralPath $path -Force
        if (-not $item.PSIsContainer -and
            -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $actualBytes = [System.IO.File]::ReadAllBytes($path)
            $actualSha256 = Get-Sha256Hex -Bytes $actualBytes
            $expectedSha256 = Get-Sha256Hex -Bytes ([byte[]]$ExpectedArtifacts[$fileName])
            if ($actualBytes.LongLength -eq ([byte[]]$ExpectedArtifacts[$fileName]).LongLength -and
                $actualSha256 -ceq $expectedSha256) {
                continue
            }
        }
        throw "기존 release artifact가 결정적 빌드 결과와 다릅니다. 자동 덮어쓰지 않습니다: $fileName"
    }
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$safeRepositoryRoot = $repositoryRoot.Replace('\', '/')
$gitExecutable = Get-GitExecutable
$reportedRepositoryRoot = & $gitExecutable -c "safe.directory=$safeRepositoryRoot" `
    -C $repositoryRoot rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($reportedRepositoryRoot -join ''))) {
    throw '릴리스 스크립트가 포함된 Git 저장소를 확인하지 못했습니다.'
}
$reportedRepositoryRoot = [System.IO.Path]::GetFullPath(($reportedRepositoryRoot -join '').Trim())
$pathComparison = if ($IsWindows) {
    [StringComparison]::OrdinalIgnoreCase
}
else {
    [StringComparison]::Ordinal
}
if (-not $reportedRepositoryRoot.Equals($repositoryRoot, $pathComparison)) {
    throw '릴리스 스크립트 위치와 Git 저장소 루트가 다릅니다.'
}
if ($Revision.Contains('..', [StringComparison]::Ordinal) -or
    $Revision.Contains('//', [StringComparison]::Ordinal)) {
    throw 'Revision에 안전하지 않은 연속 구분자를 사용할 수 없습니다.'
}

$revisionSpec = "$Revision^{commit}"
$resolvedRevision = & $gitExecutable -c "safe.directory=$safeRepositoryRoot" `
    -C $repositoryRoot rev-parse --verify --end-of-options $revisionSpec 2>$null
$resolvedRevision = ($resolvedRevision -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $resolvedRevision -notmatch '^[0-9a-f]{40}$') {
    throw '릴리스 원본 Revision을 정확한 40자리 Git commit으로 확인하지 못했습니다.'
}

# Both source files come from the exact selected commit. In particular, the
# bootstrap checksum is calculated from `git show <revision>:<path>` bytes, not
# from a possibly dirty or line-ending-normalized working-tree file.
$templateSourceBytes = Get-GitBlobBytes -GitExecutable $gitExecutable `
    -RepositoryRoot $repositoryRoot -Commit $resolvedRevision `
    -RepositoryPath $templateRepositoryPath
$bootstrapBytes = Get-GitBlobBytes -GitExecutable $gitExecutable `
    -RepositoryRoot $repositoryRoot -Commit $resolvedRevision `
    -RepositoryPath $bootstrapRepositoryPath
$bootstrapSha256 = Get-Sha256Hex -Bytes $bootstrapBytes

try {
    $templateSourceText = $utf8NoBom.GetString($templateSourceBytes)
}
catch {
    throw 'CloudFormation 원본 템플릿은 BOM 없는 유효한 UTF-8이어야 합니다.'
}

$releasePlaceholderCount = ([regex]::Matches(
    $templateSourceText,
    [regex]::Escape($releasePlaceholder)
)).Count
$revisionPlaceholderCount = ([regex]::Matches(
    $templateSourceText,
    $revisionPlaceholderPattern
)).Count
$bootstrapShaPlaceholderCount = ([regex]::Matches(
    $templateSourceText,
    $bootstrapShaPlaceholderPattern
)).Count
if ($releasePlaceholderCount -ne $requiredReleasePlaceholderCount -or
    $revisionPlaceholderCount -ne $requiredRevisionPlaceholderCount -or
    $bootstrapShaPlaceholderCount -ne $requiredBootstrapShaPlaceholderCount) {
    throw "릴리스 템플릿 placeholder 수가 계약과 다릅니다: release=$releasePlaceholderCount, revision=$revisionPlaceholderCount, bootstrapSha256=$bootstrapShaPlaceholderCount"
}

$renderedTemplate = $templateSourceText.Replace($releasePlaceholder, $ReleaseVersion)
$renderedTemplate = [regex]::Replace(
    $renderedTemplate,
    $bootstrapShaPlaceholderPattern,
    $bootstrapSha256
)
$renderedTemplate = [regex]::Replace(
    $renderedTemplate,
    $revisionPlaceholderPattern,
    $resolvedRevision
)
if ($renderedTemplate.Contains($releasePlaceholder, [StringComparison]::Ordinal) -or
    [regex]::IsMatch($renderedTemplate, $revisionPlaceholderPattern) -or
    [regex]::IsMatch($renderedTemplate, $bootstrapShaPlaceholderPattern)) {
    throw '렌더링된 CloudFormation artifact에 placeholder가 남아 있습니다.'
}
if (-not $renderedTemplate.Contains(
    "https://raw.githubusercontent.com/jusubkim94/qfieldcloud-self-hosting-for-arboreta/$resolvedRevision/$bootstrapRepositoryPath",
    [StringComparison]::Ordinal
)) {
    throw '렌더링된 템플릿의 bootstrap URL이 선택한 commit에 고정되지 않았습니다.'
}

$templateBytes = $utf8NoBom.GetBytes($renderedTemplate)
$templateSha256 = Get-Sha256Hex -Bytes $templateBytes
$manifest = [ordered]@{
    schema_version = 1
    release_version = $ReleaseVersion
    source_repository = 'https://github.com/jusubkim94/qfieldcloud-self-hosting-for-arboreta.git'
    source_revision = $resolvedRevision
    aws_region = 'ap-northeast-2'
    quick_create_stack_name = 'qfieldcloud-pilot'
    template = [ordered]@{
        file = 'template.yaml'
        source_path = $templateRepositoryPath
        sha256 = $templateSha256
        size_bytes = $templateBytes.LongLength
    }
    bootstrap = [ordered]@{
        source_path = $bootstrapRepositoryPath
        sha256 = $bootstrapSha256
        size_bytes = $bootstrapBytes.LongLength
    }
}
$manifestText = (($manifest | ConvertTo-Json -Depth 10) -replace "`r`n", "`n") + "`n"
$manifestBytes = $utf8NoBom.GetBytes($manifestText)
$manifestSha256 = Get-Sha256Hex -Bytes $manifestBytes
$checksumsText = @(
    "$templateSha256  template.yaml"
    "$manifestSha256  manifest.json"
) -join "`n"
$checksumsText += "`n"
$checksumsBytes = $utf8NoBom.GetBytes($checksumsText)

$expectedArtifacts = [ordered]@{
    'template.yaml' = $templateBytes
    'manifest.json' = $manifestBytes
    'SHA256SUMS' = $checksumsBytes
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repositoryRoot 'artifacts\lab-lightsail'
}
$outputRootFullPath = [System.IO.Path]::GetFullPath($OutputRoot)
$artifactDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $outputRootFullPath $ReleaseVersion)
)
$outputRootPrefix = $outputRootFullPath.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
if (-not $artifactDirectory.StartsWith($outputRootPrefix, $pathComparison)) {
    throw 'ReleaseVersion이 artifact 출력 루트 밖의 경로를 가리킵니다.'
}

$result = 'artifacts-created'
if (Test-Path -LiteralPath $artifactDirectory) {
    Assert-ExactExistingArtifacts -Directory $artifactDirectory `
        -ExpectedArtifacts $expectedArtifacts
    $result = 'artifacts-already-current'
}
else {
    $null = [System.IO.Directory]::CreateDirectory($artifactDirectory)
    foreach ($fileName in $artifactFileNames) {
        $filePath = Join-Path $artifactDirectory $fileName
        $stream = [System.IO.File]::Open(
            $filePath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            $bytes = [byte[]]$expectedArtifacts[$fileName]
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
    }
}

[pscustomobject]@{
    Result = $result
    ReleaseVersion = $ReleaseVersion
    SourceRevision = $resolvedRevision
    BootstrapSha256 = $bootstrapSha256
    TemplateSha256 = $templateSha256
    ArtifactDirectory = $artifactDirectory
    Files = $artifactFileNames -join ','
}
