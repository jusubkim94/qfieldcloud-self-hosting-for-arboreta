#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$releaseExecutablePath = Join-Path $repositoryRoot 'releases/tools/qfieldcloud-template-editor/v0.1.1/QFieldCloudTemplateEditor-v0.1.1.exe'
$releaseChecksumsPath = Join-Path $repositoryRoot 'releases/tools/qfieldcloud-template-editor/v0.1.1/SHA256SUMS'
$expectedReleaseHash = 'd4acbcb0fc5f096652f0795154b55853f8af800c8f690b093b100058121e01a8'
$editorDownloadUrl = 'https://raw.githubusercontent.com/jusubkim94/qfieldcloud-self-hosting-for-arboreta/c7e8b02d26e385d705fd6506c6946f1c58da4bae/releases/tools/qfieldcloud-template-editor/v0.1.1/QFieldCloudTemplateEditor-v0.1.1.exe'
$legacyExecutablePath = Join-Path $repositoryRoot 'releases/tools/qfieldcloud-template-editor/v0.1.0/QFieldCloudTemplateEditor-v0.1.0.exe'
foreach ($releasePath in @($releaseExecutablePath, $releaseChecksumsPath)) {
    if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
        throw "Missing editor release file: $releasePath"
    }
}
$releaseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseExecutablePath).Hash.ToLowerInvariant()
$releaseChecksums = Get-Content -Raw -LiteralPath $releaseChecksumsPath
if ($releaseHash -ne $expectedReleaseHash -or
    -not $releaseChecksums.Contains("$releaseHash  QFieldCloudTemplateEditor-v0.1.1.exe")) {
    throw 'The committed editor EXE does not match its reviewed SHA-256.'
}
if ((Get-Item -LiteralPath $releaseExecutablePath).VersionInfo.FileVersion -ne '0.1.1.0') {
    throw 'The committed editor EXE has an unexpected file version.'
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $legacyExecutablePath).Hash.ToLowerInvariant() -ne
    '2163cdbd58ab8cc14e39a263a3b8830c8d975c1a7c4c2b7eada6d8184f59d33f') {
    throw 'The immutable v0.1.0 editor EXE changed unexpectedly.'
}
$mainReadme = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'README.md')
if (-not $mainReadme.Contains($editorDownloadUrl) -or
    -not $mainReadme.Contains('Standalone 구조') -or
    -not $mainReadme.Contains('전체 설치 과정')) {
    throw 'README does not expose the immutable editor EXE or its Korean diagram guidance.'
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("qfc-template-editor-test-" + [guid]::NewGuid().ToString('N'))
try {
    & (Join-Path $PSScriptRoot 'Build-QFieldCloudTemplateEditor.ps1') -OutputDirectory $temporaryRoot
    $executablePath = Join-Path $temporaryRoot 'QFieldCloudTemplateEditor-v0.1.1.exe'
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
        'Preserve successfully provisioned resources를 직접 선택합니다.'
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
