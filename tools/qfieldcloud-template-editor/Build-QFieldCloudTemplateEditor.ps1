#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sourcePath = Join-Path $PSScriptRoot 'QFieldCloudTemplateEditor.cs'
$manifestPath = Join-Path $PSScriptRoot 'app.manifest'
$templatePath = Join-Path $repositoryRoot 'releases/lab-lightsail/v0.1.3/template.yaml'
$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compilerPath = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

if (-not $compilerPath) {
    throw '.NET Framework C# compiler was not found. Windows 10 or Windows 11 with .NET Framework 4.8 is required.'
}
foreach ($requiredPath in @($sourcePath, $manifestPath, $templatePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Missing build input: $requiredPath"
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputPath = Join-Path $OutputDirectory 'QFieldCloudTemplateEditor-v0.1.3.exe'
$arguments = @(
    '/nologo'
    '/target:winexe'
    '/platform:anycpu'
    '/optimize+'
    '/warn:4'
    "/out:$outputPath"
    "/win32manifest:$manifestPath"
    '/reference:System.dll'
    '/reference:System.Core.dll'
    '/reference:System.Drawing.dll'
    '/reference:System.Windows.Forms.dll'
    "/resource:$templatePath,QFieldCloudTemplateEditor.DefaultTemplate.yaml"
    $sourcePath
)

& $compilerPath @arguments
if ($LASTEXITCODE -ne 0) {
    throw "C# compiler failed with exit code $LASTEXITCODE."
}

$selfTest = Start-Process -FilePath $outputPath -ArgumentList '--self-test' -WindowStyle Hidden -Wait -PassThru
if ($selfTest.ExitCode -ne 0) {
    throw "Editor self-test failed with exit code $($selfTest.ExitCode)."
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $outputPath).Hash.ToLowerInvariant()
Write-Output "Built: $outputPath"
Write-Output "SHA256: $hash"
