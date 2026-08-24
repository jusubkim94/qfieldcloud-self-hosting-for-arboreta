#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
$releasePlaceholder = '__RELEASE_VERSION__'
$revisionPlaceholderPattern = '(?<![0-9])0{40}(?![0-9])'
$bootstrapShaPlaceholderPattern = '(?<![0-9])0{64}(?![0-9])'
$requiredArtifactNames = @('manifest.json', 'SHA256SUMS', 'template.yaml')

function Assert-Contract {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    return ([Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($Bytes)
    )).ToLowerInvariant()
}

function Invoke-NativeText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [System.Collections.IDictionary]$EnvironmentOverrides = @{}
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }
    foreach ($name in $EnvironmentOverrides.Keys) {
        $startInfo.Environment[[string]$name] = [string]$EnvironmentOverrides[$name]
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-Contract $process.Start() "Failed to start native process: $FileName"
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $outputTask.GetAwaiter().GetResult()
            Error = $errorTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-NativeBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $output = [System.IO.MemoryStream]::new()
    try {
        Assert-Contract $process.Start() "Failed to start binary process: $FileName"
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($output)
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $null = $copyTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Bytes = $output.ToArray()
            Error = $errorTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $output.Dispose()
        $process.Dispose()
    }
}

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $gitArguments = @(
        '-c', "safe.directory=$Repository",
        '-C', $Repository
    ) + $Arguments
    $result = Invoke-NativeText -FileName $script:gitExecutable -Arguments $gitArguments
    Assert-Contract ($result.ExitCode -eq 0) (
        "Isolated Git fixture command failed: git $($Arguments[0])"
    )
    return $result.Output
}

function Assert-ExactArtifactSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $names = @(
        Get-ChildItem -LiteralPath $Directory -Force |
            ForEach-Object { $_.Name } |
            Sort-Object
    )
    Assert-Contract (($names -join "`n") -ceq ($requiredArtifactNames -join "`n")) (
        'Builder output must contain exactly manifest.json, SHA256SUMS, and template.yaml.'
    )
}

function Get-ArtifactHashes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $hashes = [ordered]@{}
    foreach ($name in $requiredArtifactNames) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Directory $name))
        $hashes[$name] = [pscustomobject]@{
            Length = $bytes.LongLength
            Sha256 = Get-Sha256Hex -Bytes $bytes
        }
    }
    return $hashes
}

function Get-PublisherFunction {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $matches = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $_.Name -ceq $Name })
    Assert-Contract ($matches.Count -eq 1) "Publisher function is missing or duplicated: $Name"
    return $matches[0].Extent.Text
}

function ConvertFrom-QueryString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $result = @{}
    foreach ($pair in ($Query -split '&')) {
        $parts = $pair -split '=', 2
        Assert-Contract ($parts.Count -eq 2) "Malformed URL query pair: $pair"
        $name = [Uri]::UnescapeDataString($parts[0])
        $value = [Uri]::UnescapeDataString($parts[1])
        Assert-Contract (-not $result.ContainsKey($name)) "Duplicate URL query key: $name"
        $result[$name] = $value
    }
    return $result
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$builderSourcePath = Join-Path $repositoryRoot 'scripts/release/New-LabLightsailReleaseArtifacts.ps1'
$publisherSourcePath = Join-Path $repositoryRoot 'scripts/release/Publish-LabLightsailRelease.ps1'
$templateSourcePath = Join-Path $repositoryRoot 'infra/lab-lightsail/template.yaml'
$bootstrapSourcePath = Join-Path $repositoryRoot 'scripts/lab-lightsail/bootstrap.sh'
foreach ($path in @(
    $builderSourcePath,
    $publisherSourcePath,
    $templateSourcePath,
    $bootstrapSourcePath
)) {
    Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) "Missing release fixture source: $path"
}

$builderSourceText = Get-Content -Raw -LiteralPath $builderSourcePath
Assert-Contract (
    $builderSourceText.Contains("Replace('\', '/')", [StringComparison]::Ordinal) -and
    $builderSourceText.Contains('safe.directory=$safeRepositoryRoot', [StringComparison]::Ordinal)
) 'Builder must normalize Windows paths before passing Git safe.directory.'

$templateSourceBytes = [System.IO.File]::ReadAllBytes($templateSourcePath)
$templateSourceText = $utf8NoBom.GetString($templateSourceBytes)
Assert-Contract (
    ([regex]::Matches($templateSourceText, [regex]::Escape($releasePlaceholder))).Count -eq 1
) 'Source template must have exactly one release-version placeholder.'
Assert-Contract (
    ([regex]::Matches($templateSourceText, $revisionPlaceholderPattern)).Count -eq 4
) 'Source template must have exactly four isolated 40-zero revision placeholders.'
Assert-Contract (
    ([regex]::Matches($templateSourceText, $bootstrapShaPlaceholderPattern)).Count -eq 2
) 'Source template must have exactly two isolated 64-zero bootstrap checksum placeholders.'

# A 64-zero checksum sentinel must never be miscounted as a 40-zero revision
# sentinel. The digit boundaries are deliberately stronger than zero-only
# boundaries so longer numeric tokens also fail closed.
$oneChecksumSentinel = '0' * 64
Assert-Contract (
    ([regex]::Matches($oneChecksumSentinel, $revisionPlaceholderPattern)).Count -eq 0
) 'The revision regex counted a 40-zero window inside a 64-zero checksum sentinel.'
Assert-Contract (
    ([regex]::Matches($oneChecksumSentinel, $bootstrapShaPlaceholderPattern)).Count -eq 1
) 'The checksum regex did not recognize one isolated 64-zero sentinel.'
Assert-Contract (
    ([regex]::Matches(('7' + ('0' * 40)), $revisionPlaceholderPattern)).Count -eq 0
) 'The revision regex accepted a 40-zero suffix inside a longer numeric token.'

$gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
Assert-Contract ($null -ne $gitCommand) 'Git is required for the local release artifact contract test.'
$script:gitExecutable = [System.IO.Path]::GetFullPath($gitCommand.Source)

$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$temporaryRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $temporaryBase ("qfc-release-contract-{0}" -f [Guid]::NewGuid().ToString('N')))
)
$temporaryBasePrefix = $temporaryBase.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
$pathComparison = if ($IsWindows) {
    [StringComparison]::OrdinalIgnoreCase
}
else {
    [StringComparison]::Ordinal
}
Assert-Contract $temporaryRoot.StartsWith($temporaryBasePrefix, $pathComparison) (
    'The isolated fixture directory escaped the operating-system temp directory.'
)

try {
    $null = [System.IO.Directory]::CreateDirectory($temporaryRoot)
    $fixtureRepository = Join-Path $temporaryRoot 'repository'
    $null = [System.IO.Directory]::CreateDirectory($fixtureRepository)
    $fixtureGitControls = Join-Path $temporaryRoot 'git-controls'
    $emptyHooksDirectory = Join-Path $fixtureGitControls 'hooks'
    $emptyAttributesFile = Join-Path $fixtureGitControls 'attributes'
    $null = [System.IO.Directory]::CreateDirectory($emptyHooksDirectory)
    [System.IO.File]::WriteAllBytes($emptyAttributesFile, [byte[]]::new(0))
    $fixturePaths = @(
        'scripts/release/New-LabLightsailReleaseArtifacts.ps1'
        'scripts/release/Publish-LabLightsailRelease.ps1'
        'infra/lab-lightsail/template.yaml'
        'scripts/lab-lightsail/bootstrap.sh'
    )
    foreach ($relativePath in $fixturePaths) {
        $sourcePath = Join-Path $repositoryRoot $relativePath
        $destinationPath = Join-Path $fixtureRepository $relativePath
        $null = [System.IO.Directory]::CreateDirectory(
            [System.IO.Path]::GetDirectoryName($destinationPath)
        )
        [System.IO.File]::Copy($sourcePath, $destinationPath, $false)
    }

    $null = Invoke-TestGit -Repository $fixtureRepository -Arguments @('init', '--quiet')
    $null = Invoke-TestGit -Repository $fixtureRepository -Arguments @(
        'config', 'user.name', 'QFieldCloud release contract test'
    )
    $null = Invoke-TestGit -Repository $fixtureRepository -Arguments @(
        'config', 'user.email', 'release-contract@example.invalid'
    )
    $null = Invoke-TestGit -Repository $fixtureRepository -Arguments @(
        'config', 'core.autocrlf', 'false'
    )
    $null = Invoke-TestGit -Repository $fixtureRepository -Arguments @(
        'config', 'core.hooksPath', $emptyHooksDirectory
    )
    $null = Invoke-TestGit -Repository $fixtureRepository -Arguments @(
        'config', 'core.attributesFile', $emptyAttributesFile
    )
    $null = Invoke-TestGit -Repository $fixtureRepository -Arguments @(
        'config', 'commit.gpgsign', 'false'
    )
    $gitAddArguments = @('add', '--') + $fixturePaths
    $null = Invoke-TestGit -Repository $fixtureRepository -Arguments $gitAddArguments
    $null = Invoke-TestGit -Repository $fixtureRepository -Arguments @(
        'commit', '--quiet', '-m', 'release artifact contract fixture'
    )
    $fixtureRevision = (
        Invoke-TestGit -Repository $fixtureRepository -Arguments @('rev-parse', 'HEAD')
    ).Trim()
    Assert-Contract ($fixtureRevision -match '^[0-9a-f]{40}$') (
        'The isolated fixture did not resolve to an exact Git commit.'
    )

    $committedBootstrap = Invoke-NativeBytes -FileName $script:gitExecutable -Arguments @(
        '-c', "safe.directory=$fixtureRepository",
        '-C', $fixtureRepository,
        'show', "${fixtureRevision}:scripts/lab-lightsail/bootstrap.sh"
    )
    Assert-Contract ($committedBootstrap.ExitCode -eq 0) (
        'Could not read exact bootstrap blob bytes from the isolated Git commit.'
    )
    $committedBootstrapBytes = [byte[]]$committedBootstrap.Bytes
    $committedBootstrapSha256 = Get-Sha256Hex -Bytes $committedBootstrapBytes

    # Dirty the fixture working tree after the commit. A correct builder must
    # continue to hash and package the selected commit, never these local bytes.
    $dirtyBootstrapPath = Join-Path $fixtureRepository 'scripts/lab-lightsail/bootstrap.sh'
    $dirtyMarker = $utf8NoBom.GetBytes("`n# uncommitted release-contract marker`n")
    $dirtyBootstrapBytes = [byte[]]::new($committedBootstrapBytes.Length + $dirtyMarker.Length)
    [Buffer]::BlockCopy(
        $committedBootstrapBytes,
        0,
        $dirtyBootstrapBytes,
        0,
        $committedBootstrapBytes.Length
    )
    [Buffer]::BlockCopy(
        $dirtyMarker,
        0,
        $dirtyBootstrapBytes,
        $committedBootstrapBytes.Length,
        $dirtyMarker.Length
    )
    [System.IO.File]::WriteAllBytes($dirtyBootstrapPath, $dirtyBootstrapBytes)
    Assert-Contract (
        (Get-Sha256Hex -Bytes $dirtyBootstrapBytes) -cne $committedBootstrapSha256
    ) 'The dirty bootstrap fixture unexpectedly has the committed blob checksum.'

    $releaseVersion = 'v0.0.0-contract-test'
    $builderPath = Join-Path $fixtureRepository 'scripts/release/New-LabLightsailReleaseArtifacts.ps1'
    $outputRootA = Join-Path $temporaryRoot 'output-a'
    $outputRootB = Join-Path $temporaryRoot 'output-b'
    $buildA = & $builderPath -ReleaseVersion $releaseVersion -Revision HEAD `
        -OutputRoot $outputRootA
    Assert-Contract ($buildA.Result -ceq 'artifacts-created') 'The first local builder run did not create artifacts.'
    Assert-Contract ($buildA.SourceRevision -ceq $fixtureRevision) 'Builder did not resolve the selected Git commit.'
    Assert-Contract ($buildA.BootstrapSha256 -ceq $committedBootstrapSha256) (
        'Builder checksum did not use exact git show bootstrap bytes.'
    )
    $artifactDirectoryA = [string]$buildA.ArtifactDirectory
    Assert-ExactArtifactSet -Directory $artifactDirectoryA

    $buildARepeat = & $builderPath -ReleaseVersion $releaseVersion -Revision HEAD `
        -OutputRoot $outputRootA
    Assert-Contract ($buildARepeat.Result -ceq 'artifacts-already-current') (
        'The repeated builder run was not idempotent.'
    )
    $buildB = & $builderPath -ReleaseVersion $releaseVersion -Revision HEAD `
        -OutputRoot $outputRootB
    Assert-Contract ($buildB.Result -ceq 'artifacts-created') 'The second isolated output was not created.'
    $artifactDirectoryB = [string]$buildB.ArtifactDirectory
    Assert-ExactArtifactSet -Directory $artifactDirectoryB

    $hashesA = Get-ArtifactHashes -Directory $artifactDirectoryA
    $hashesB = Get-ArtifactHashes -Directory $artifactDirectoryB
    foreach ($name in $requiredArtifactNames) {
        Assert-Contract (
            $hashesA[$name].Length -eq $hashesB[$name].Length -and
            $hashesA[$name].Sha256 -ceq $hashesB[$name].Sha256
        ) "Builder output is not deterministic: $name"
    }

    $renderedTemplateBytes = [System.IO.File]::ReadAllBytes(
        (Join-Path $artifactDirectoryA 'template.yaml')
    )
    $renderedTemplateText = $utf8NoBom.GetString($renderedTemplateBytes)
    Assert-Contract (
        -not $renderedTemplateText.Contains($releasePlaceholder, [StringComparison]::Ordinal) -and
        ([regex]::Matches($renderedTemplateText, $revisionPlaceholderPattern)).Count -eq 0 -and
        ([regex]::Matches($renderedTemplateText, $bootstrapShaPlaceholderPattern)).Count -eq 0
    ) 'Rendered template still contains one or more release placeholders.'
    Assert-Contract (
        ([regex]::Matches(
            $renderedTemplateText,
            [regex]::Escape($fixtureRevision)
        )).Count -eq 4
    ) 'Rendered template does not contain exactly four selected revision pins.'
    Assert-Contract (
        ([regex]::Matches(
            $renderedTemplateText,
            [regex]::Escape($committedBootstrapSha256)
        )).Count -eq 2
    ) 'Rendered template does not contain exactly two committed bootstrap checksum pins.'

    $manifestBytes = [System.IO.File]::ReadAllBytes(
        (Join-Path $artifactDirectoryA 'manifest.json')
    )
    $manifest = $utf8NoBom.GetString($manifestBytes) | ConvertFrom-Json -Depth 30
    $renderedTemplateSha256 = Get-Sha256Hex -Bytes $renderedTemplateBytes
    Assert-Contract (
        [int]$manifest.schema_version -eq 1 -and
        [string]$manifest.release_version -ceq $releaseVersion -and
        [string]$manifest.source_revision -ceq $fixtureRevision -and
        [string]$manifest.aws_region -ceq 'ap-northeast-2' -and
        [string]$manifest.quick_create_stack_name -ceq 'qfieldcloud-pilot' -and
        [string]$manifest.template.sha256 -ceq $renderedTemplateSha256 -and
        [long]$manifest.template.size_bytes -eq $renderedTemplateBytes.LongLength -and
        [string]$manifest.bootstrap.sha256 -ceq $committedBootstrapSha256 -and
        [long]$manifest.bootstrap.size_bytes -eq $committedBootstrapBytes.LongLength
    ) 'manifest.json does not match the deterministic release inputs and output.'

    $checksumsText = $utf8NoBom.GetString([System.IO.File]::ReadAllBytes(
        (Join-Path $artifactDirectoryA 'SHA256SUMS')
    ))
    $expectedChecksums = @(
        "$renderedTemplateSha256  template.yaml"
        "$(Get-Sha256Hex -Bytes $manifestBytes)  manifest.json"
        ''
    ) -join "`n"
    Assert-Contract ($checksumsText -ceq $expectedChecksums) (
        'SHA256SUMS does not exactly cover template.yaml and manifest.json.'
    )

    $publisherPath = Join-Path $fixtureRepository 'scripts/release/Publish-LabLightsailRelease.ps1'
    $emptyPath = Join-Path $temporaryRoot 'path-without-aws'
    $null = [System.IO.Directory]::CreateDirectory($emptyPath)
    $powerShellExecutable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    Assert-Contract (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf) (
        'Could not locate the current PowerShell 7 executable.'
    )
    $publisherPlan = Invoke-NativeText -FileName $powerShellExecutable -Arguments @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File', $publisherPath,
        '-ArtifactDirectory', $artifactDirectoryA,
        '-BucketName', 'qfieldcloud-release-contract-example'
    ) -EnvironmentOverrides @{
        PATH = $emptyPath
    }
    Assert-Contract ($publisherPlan.ExitCode -eq 0) (
        'Publisher plan-only mode failed when aws was absent from PATH.'
    )
    # PowerShell's formatting width differs between local consoles and hosted
    # CI. Join only indented continuation lines so long plan values keep the
    # same semantic key/value record before applying the output contract.
    $normalizedPublisherPlanOutput = [regex]::Replace(
        $publisherPlan.Output,
        '\r?\n[ \t]+(?=\S)',
        ''
    )
    Assert-Contract (
        $normalizedPublisherPlanOutput -match '(?m)^Action\s*:\s*plan-only\s*$' -and
        $normalizedPublisherPlanOutput -match '(?m)^AwsWriteRequested\s*:\s*False\s*$' -and
        $normalizedPublisherPlanOutput -match '(?m)^BucketCreation\s*:\s*never\s*$' -and
        $normalizedPublisherPlanOutput -match '(?m)^RequiredBucketVersioning\s*:\s*Enabled\s*$' -and
        $normalizedPublisherPlanOutput -match '(?m)^RequiredTemplateReadAccess\s*:\s*anonymous-s3:GetObjectVersion\s*$' -and
        $normalizedPublisherPlanOutput -match '(?m)^SourceReachabilityCheck\s*:\s*exact-GitHub-raw-bytes-before-any-AWS-write\s*$'
    ) 'Publisher did not report the required no-write, existing-versioned-bucket plan.'

    $publisherTokens = $null
    $publisherParseErrors = $null
    $publisherAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $publisherPath,
        [ref]$publisherTokens,
        [ref]$publisherParseErrors
    )
    Assert-Contract ($publisherParseErrors.Count -eq 0) 'Publisher has PowerShell parse errors.'
    foreach ($functionName in @(
        'ConvertTo-UrlPath',
        'New-S3VersionedHttpsUrl',
        'New-QuickCreateUrl'
    )) {
        . ([scriptblock]::Create(
            (Get-PublisherFunction -Ast $publisherAst -Name $functionName)
        ))
    }

    $BucketName = 'qfieldcloud-release-contract-example'
    $Region = 'ap-northeast-2'
    $testVersionId = '3/L4kqtJlcpXroDTDmJ+rmspXd3dIbrHY+contract=='
    $versionedTemplateUrl = New-S3VersionedHttpsUrl `
        -Key 'qfieldcloud/lab-lightsail/releases/v0.0.0-contract-test/template.yaml' `
        -VersionId $testVersionId
    $templateUri = [Uri]$versionedTemplateUrl
    $templateQuery = ConvertFrom-QueryString -Query $templateUri.Query.TrimStart('?')
    Assert-Contract (
        $templateUri.Scheme -ceq 'https' -and
        $templateUri.Host -ceq "$BucketName.s3.$Region.amazonaws.com" -and
        $templateQuery.ContainsKey('versionId') -and
        [string]$templateQuery.versionId -ceq $testVersionId
    ) 'TemplateURL is not an HTTPS Seoul S3 URL pinned to the exact VersionId.'

    $quickCreateUrl = New-QuickCreateUrl -TemplateUrl $versionedTemplateUrl
    $quickCreateUri = [Uri]$quickCreateUrl
    Assert-Contract (
        $quickCreateUri.Scheme -ceq 'https' -and
        $quickCreateUri.Host -ceq 'ap-northeast-2.console.aws.amazon.com' -and
        $quickCreateUri.AbsolutePath -ceq '/cloudformation/home' -and
        $quickCreateUri.Query -ceq '?region=ap-northeast-2'
    ) 'Quick Create URL is not fixed to the Seoul CloudFormation console.'
    $fragmentParts = $quickCreateUri.Fragment.TrimStart('#') -split '\?', 2
    Assert-Contract (
        $fragmentParts.Count -eq 2 -and
        $fragmentParts[0] -ceq '/stacks/create/review'
    ) 'Quick Create URL does not use the CloudFormation review route.'
    $quickParameters = ConvertFrom-QueryString -Query $fragmentParts[1]
    Assert-Contract (
        [string]$quickParameters.stackName -ceq 'qfieldcloud-pilot' -and
        [string]$quickParameters.templateURL -ceq $versionedTemplateUrl -and
        [string]$quickParameters.param_DeploymentRegion -ceq 'ap-northeast-2' -and
        [string]$quickParameters.param_AvailabilityZone -ceq 'ap-northeast-2a' -and
        [string]$quickParameters.param_InstanceName -ceq 'qfieldcloud-pilot' -and
        [string]$quickParameters.param_CertificateMode -ceq 'self-signed' -and
        [string]$quickParameters.param_LetsEncryptTermsAccepted -ceq 'false'
    ) 'Quick Create URL lost its fixed stack, Seoul, safe certificate, or versioned template contract.'

    $publisherSourceText = Get-Content -Raw -LiteralPath $publisherPath
    Assert-Contract (-not [regex]::IsMatch($publisherSourceText, '(?i)\bcreate-bucket\b')) (
        'Publisher must never create an S3 bucket.'
    )
    $rawVerificationFunction = Get-PublisherFunction -Ast $publisherAst `
        -Name 'Assert-PublishedBootstrapMatches'
    foreach ($requiredToken in @(
        'raw.githubusercontent.com',
        'AllowAutoRedirect = $false',
        'HttpCompletionOption]::ResponseHeadersRead',
        'ContentLength',
        'Get-Sha256Hex -Bytes $downloadedBytes'
    )) {
        Assert-Contract (
            $rawVerificationFunction.Contains($requiredToken, [StringComparison]::Ordinal)
        ) "Publisher raw bootstrap verification is missing: $requiredToken"
    }
    $rawVerificationCallIndex = $publisherSourceText.LastIndexOf(
        'Assert-PublishedBootstrapMatches -SourceRevision',
        [StringComparison]::Ordinal
    )
    $awsExecutableCallIndex = $publisherSourceText.LastIndexOf(
        '$awsExecutable = Get-AwsExecutable',
        [StringComparison]::Ordinal
    )
    Assert-Contract (
        $rawVerificationCallIndex -ge 0 -and
        $awsExecutableCallIndex -gt $rawVerificationCallIndex
    ) 'Publisher must verify public GitHub bootstrap bytes before any AWS operation.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Assert-Contract $temporaryRoot.StartsWith($temporaryBasePrefix, $pathComparison) (
            'Refusing to clean a fixture path outside the operating-system temp directory.'
        )
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Output 'Lab Lightsail release artifact contract validation passed. AWS and S3 were not called.'
