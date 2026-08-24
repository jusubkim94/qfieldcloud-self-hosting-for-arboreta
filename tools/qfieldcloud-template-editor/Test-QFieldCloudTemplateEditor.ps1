#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$releaseExecutablePath = Join-Path $repositoryRoot 'releases/tools/qfieldcloud-template-editor/v0.1.0/QFieldCloudTemplateEditor-v0.1.0.exe'
$releaseChecksumsPath = Join-Path $repositoryRoot 'releases/tools/qfieldcloud-template-editor/v0.1.0/SHA256SUMS'
$expectedReleaseHash = '2163cdbd58ab8cc14e39a263a3b8830c8d975c1a7c4c2b7eada6d8184f59d33f'
foreach ($releasePath in @($releaseExecutablePath, $releaseChecksumsPath)) {
    if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
        throw "Missing editor release file: $releasePath"
    }
}
$releaseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseExecutablePath).Hash.ToLowerInvariant()
$releaseChecksums = Get-Content -Raw -LiteralPath $releaseChecksumsPath
if ($releaseHash -ne $expectedReleaseHash -or
    -not $releaseChecksums.Contains("$releaseHash  QFieldCloudTemplateEditor-v0.1.0.exe")) {
    throw 'The committed editor EXE does not match its reviewed SHA-256.'
}
if ((Get-Item -LiteralPath $releaseExecutablePath).VersionInfo.FileVersion -ne '0.1.0.0') {
    throw 'The committed editor EXE has an unexpected file version.'
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("qfc-template-editor-test-" + [guid]::NewGuid().ToString('N'))
try {
    & (Join-Path $PSScriptRoot 'Build-QFieldCloudTemplateEditor.ps1') -OutputDirectory $temporaryRoot
    $executablePath = Join-Path $temporaryRoot 'QFieldCloudTemplateEditor-v0.1.0.exe'
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        throw 'The editor executable was not created.'
    }
    if ((Get-Item -LiteralPath $executablePath).Length -lt 50000) {
        throw 'The editor executable is unexpectedly small.'
    }

    $sourceText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'QFieldCloudTemplateEditor.cs')
    foreach ($requiredText in @(
        'AWS에 접속하지 않고 CloudFormation YAML만 수정·검증·저장합니다.'
        'standalone 템플릿은 Lightsail 인스턴스가 정확히 1개여야 합니다.'
        'QFieldCloud Standalone Template Editor'
        'DrawArchitecture'
        'DrawInstallation'
        '고급 편집은 모든 내용을 바꿀 수 있지만'
    )) {
        if (-not $sourceText.Contains($requiredText)) {
            throw "Missing editor contract text: $requiredText"
        }
    }
    foreach ($forbiddenText in @(
        'Amazon.Runtime'
        'Amazon.Lightsail'
        'AccessKeyId'
        'SecretAccessKey'
        'WebClient('
        'HttpClient('
    )) {
        if ($sourceText.Contains($forbiddenText)) {
            throw "The offline editor contains a forbidden network or credential dependency: $forbiddenText"
        }
    }

    Write-Output 'QFieldCloud Template Editor build and self-test passed. AWS and the network were not called.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
