#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-RepositoryText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $path = Join-Path $script:repositoryRoot $RelativePath
    Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) "Missing required file: $RelativePath"
    return Get-Content -Raw -LiteralPath $path
}

$script:repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$templateText = Get-RepositoryText 'infra/lab-lightsail/template.yaml'
$bootstrapText = Get-RepositoryText 'scripts/lab-lightsail/bootstrap.sh'
$healthText = Get-RepositoryText 'scripts/lab-lightsail/health-check.sh'
$workerSmokeText = Get-RepositoryText 'scripts/lab-lightsail/worker-smoke-test.sh'
$renewText = Get-RepositoryText 'scripts/lab-lightsail/certificate-renew.sh'
$composeText = Get-RepositoryText 'runtime/lab-lightsail/compose.yaml'
$workerNginxText = Get-RepositoryText 'runtime/lab-lightsail/nginx-worker-api.conf.template'
$versionText = Get-RepositoryText 'config/qfieldcloud-v26.25.env'
$readmeText = Get-RepositoryText 'README.md'
$releaseTemplatePath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.4/template.yaml'
$releaseManifestPath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.4/manifest.json'
$releaseChecksumsPath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.4/SHA256SUMS'
$releaseArchivePath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.4/qfieldcloud-lab-lightsail-v0.1.4.zip'
$previousReleaseTemplatePath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.3/template.yaml'
$previousReleaseArchivePath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.3/qfieldcloud-lab-lightsail-v0.1.3.zip'
$olderReleaseTemplatePath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.2/template.yaml'
$olderReleaseArchivePath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.2/qfieldcloud-lab-lightsail-v0.1.2.zip'
$earlierReleaseTemplatePath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.1/template.yaml'
$earlierReleaseArchivePath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.1/qfieldcloud-lab-lightsail-v0.1.1.zip'
$legacyReleaseTemplatePath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.0/template.yaml'
$legacyReleaseArchivePath = Join-Path $script:repositoryRoot 'releases/lab-lightsail/v0.1.0/qfieldcloud-lab-lightsail-v0.1.0.zip'

$removedPaths = @(
    'infra/lab-lightsail/access-bootstrap.yaml'
    'infra/lab-lightsail/deployer-policy.json'
    'infra/lab-lightsail/cleanup-policy.json'
    'scripts/lab-lightsail/backup.sh'
    'scripts/lab-lightsail/restore-test.sh'
    'scripts/lab-lightsail/Grant-QFieldCloudPilotAccess.ps1'
    'scripts/lab-lightsail/Install-QFieldCloudPilot.ps1'
    'scripts/lab-lightsail/Deploy-QFieldCloudPilot.ps1'
    'scripts/lab-lightsail/Test-QFieldCloudPilot.ps1'
    'docs/access-bootstrap.md'
    'docs/runbooks/backup.md'
    'docs/runbooks/restore-test.md'
)
foreach ($removedPath in $removedPaths) {
    Assert-Contract (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $removedPath))) (
        "Removed IAM/CLI or backup feature remains: $removedPath"
    )
}

Assert-Contract (
    $templateText.Contains('Type: AWS::Lightsail::Instance') -and
    $templateText.Contains('Type: AWS::Lightsail::StaticIp') -and
    $templateText.Contains('Type: AWS::Lightsail::Alarm') -and
    $templateText.Contains('BlueprintId: ubuntu_24_04') -and
    $templateText.Contains('BundleId: medium_3_0') -and
    $templateText.Contains('Default: ap-northeast-2') -and
    $templateText.Contains('Default: ap-northeast-2a') -and
    $templateText.Contains('Default: qfieldcloud-pilot')
) 'The one-click template does not pin the validated Seoul Lightsail defaults.'

$certificateParameterBlock = [regex]::Match(
    $templateText,
    '(?ms)^  CertificateMode:\r?\n(?<Body>.*?)(?=^  LetsEncryptTermsAccepted:)'
)
$termsParameterBlock = [regex]::Match(
    $templateText,
    '(?ms)^  LetsEncryptTermsAccepted:\r?\n(?<Body>.*?)(?=^Rules:)'
)
Assert-Contract (
    $certificateParameterBlock.Success -and
    $certificateParameterBlock.Groups['Body'].Value.Contains('Default: letsencrypt-ip') -and
    $termsParameterBlock.Success -and
    $termsParameterBlock.Groups['Body'].Value.Contains("Default: 'false'") -and
    $termsParameterBlock.Groups['Body'].Value.Contains('https://letsencrypt.org/repository/') -and
    $templateText.Contains('PublicCertificateTermsMustBeAccepted:') -and
    $templateText.Contains("Assert: !Equals [!Ref LetsEncryptTermsAccepted, 'true']")
) "Let’s Encrypt must be the certificate default while agreement remains an explicit user choice."

Assert-Contract (
    -not $templateText.Contains('AWS::IAM::') -and
    -not $templateText.Contains('AddOns:') -and
    -not $templateText.Contains('AutoSnapshot') -and
    -not $templateText.Contains('CPUUtilization') -and
    -not $templateText.Contains('DeletionPolicy: Retain') -and
    -not $templateText.Contains('UpdateReplacePolicy: Retain')
) 'The template still creates IAM, automatic snapshot, CPU alarm, or retained resources.'

$parameterBlock = [regex]::Match($templateText, '(?ms)^Parameters:\r?\n(?<Body>.*?)(?=^Rules:)')
Assert-Contract $parameterBlock.Success 'CloudFormation Parameters block was not found.'
Assert-Contract (
    -not $parameterBlock.Groups['Body'].Value.Contains('BootstrapRevision:') -and
    -not $parameterBlock.Groups['Body'].Value.Contains('BootstrapSha256:') -and
    -not $parameterBlock.Groups['Body'].Value.Contains('BundleId:') -and
    -not $parameterBlock.Groups['Body'].Value.Contains('BlueprintId:')
) 'Release or server product pins remain user-overridable CloudFormation parameters.'

$zeroRevision = '0' * 40
$zeroChecksum = '0' * 64
Assert-Contract (([regex]::Matches($templateText, '(?<!0)0{40}(?!0)')).Count -eq 4) (
    'The release builder contract requires exactly four 40-character revision sentinels.'
)
Assert-Contract (([regex]::Matches($templateText, '(?<!0)0{64}(?!0)')).Count -eq 2) (
    'The release builder contract requires exactly two 64-character checksum sentinels.'
)
Assert-Contract (([regex]::Matches($templateText, '__RELEASE_VERSION__')).Count -eq 1) (
    'The release builder contract requires exactly one release-version sentinel.'
)

foreach ($requiredOutput in @(
    'HttpsUrl:'
    'InstanceName:'
    'InstallationStatus:'
    'AdministratorCredentials:'
    'DeleteInstructions:'
    'DataProtectionWarning:'
)) {
    Assert-Contract $templateText.Contains($requiredOutput) "Missing CloudFormation output: $requiredOutput"
}
Assert-Contract (
    $templateText.Contains('sudo /opt/qfieldcloud/bin/show-admin-credentials.sh') -and
    $templateText.Contains('Type: AWS::CloudFormation::WaitCondition') -and
    $templateText.Contains('Type: AWS::CloudFormation::WaitConditionHandle') -and
    $templateText.Contains("Timeout: '9000'") -and
    $templateText.Contains('set +x') -and
    $templateText.Contains('actual_sha256=') -and
    $templateText.IndexOf('actual_sha256=', [StringComparison]::Ordinal) -lt
        $templateText.IndexOf('install -m 0700 "$download_path" "$bootstrap_file"', [StringComparison]::Ordinal)
) 'UserData checksum, secret-suppression, completion gate, or browser credential contract regressed.'

$outputsBlock = [regex]::Match($templateText, '(?ms)^Outputs:\r?\n(?<Body>.*)$')
Assert-Contract $outputsBlock.Success 'CloudFormation Outputs block was not found.'
Assert-Contract (
    -not [regex]::IsMatch(
        $outputsBlock.Groups['Body'].Value,
        '(?i)(ADMIN_PASSWORD|POSTGRES_PASSWORD|OBJECT_STORAGE_ROOT_PASSWORD|SECRET_KEY|SALT_KEY)'
    )
) 'A secret name appears in CloudFormation Outputs.'

foreach ($serverText in @($bootstrapText, $healthText)) {
    Assert-Contract (
        -not $serverText.Contains('backup.sh') -and
        -not $serverText.Contains('restore-test.sh') -and
        -not $serverText.Contains('last-backup') -and
        -not $serverText.Contains('last-restore-test') -and
        -not $serverText.Contains('restore_test_orphan')
    ) 'Backup or restore remains coupled to bootstrap or health success.'
}
Assert-Contract (
    $bootstrapText.Contains('helper_names=(health-check.sh show-admin-credentials.sh worker-smoke-test.sh certificate-renew.sh)') -and
    $bootstrapText.Contains('"$install_root/bin/worker-smoke-test.sh"') -and
    $bootstrapText.Contains('"$install_root/bin/health-check.sh" --installation-gate') -and
    $bootstrapText.Contains('The complete service and worker validation gate failed.') -and
    $healthText.Contains('[[ $worker_validation == "passed" ]]')
) 'Bootstrap no longer gates completion on service and worker validation.'

$workerCleanupBlock = [regex]::Match(
    $workerSmokeText,
    '(?ms)^cleanup\(\) \{(?<Body>.*?)(?=^\})'
)
Assert-Contract (
    $workerCleanupBlock.Success -and
    $workerSmokeText.Contains('preserve_worker_failure_diagnostics()') -and
    $workerSmokeText.Contains('/var/lib/qfieldcloud-bootstrap') -and
    $workerSmokeText.Contains('compose-app-worker.log') -and
    $workerSmokeText.Contains('qgis-container-state.txt') -and
    $workerSmokeText.Contains('kernel-oom.log') -and
    $workerSmokeText.Contains('Worker failure summary:') -and
    $workerSmokeText.Contains('Redact project names, URLs, addresses, email, and tokens before sharing these files.') -and
    $workerCleanupBlock.Groups['Body'].Value.Contains('preserve_worker_failure_diagnostics') -and
    $workerCleanupBlock.Groups['Body'].Value.Contains('cleanup_owned_smoke_project') -and
    $workerCleanupBlock.Groups['Body'].Value.IndexOf('preserve_worker_failure_diagnostics', [StringComparison]::Ordinal) -lt
        $workerCleanupBlock.Groups['Body'].Value.IndexOf('cleanup_owned_smoke_project', [StringComparison]::Ordinal)
) 'Worker failure diagnostics are not captured root-only before smoke-project cleanup.'

Assert-Contract (
    $templateText.Contains("template cannot set CloudFormation's stack failure behavior") -and
    $readmeText.Contains('Preserve successfully provisioned resources') -and
    $readmeText.Contains('YAML 속성이 아니라 CloudFormation의 스택 생성 실행 옵션') -and
    -not $templateText.Contains('OnFailure:') -and
    -not $templateText.Contains('DisableRollback:')
) 'The template or documentation misrepresents the create-stack failure-preservation option.'

Assert-Contract (
    $renewText.Contains('CERTBOT_EXPECTED_VERSION') -and
    $renewText.Contains('--preferred-profile "$LETSENCRYPT_CERTIFICATE_PROFILE"') -and
    $renewText.Contains('--ip-address "$public_host"') -and
    $renewText.Contains('validation_log="$certbot_log_root/last-validation.log"') -and
    $renewText.Contains('readonly validation_attempt_limit=5') -and
    $renewText.Contains('Nginx did not serve the renewed certificate within 60 seconds.') -and
    $renewText.Contains('Nginx served the renewed certificate, but trusted HTTPS validation failed within 60 seconds.') -and
    $bootstrapText.Contains('systemctl enable --now qfieldcloud-certificate-renew.timer') -and
    $composeText.Contains('image: "${CERTBOT_IMAGE:?required}"')
) 'Pinned HTTPS issuance, renewal, bounded activation retry, or diagnostics are missing.'

Assert-Contract (
    $composeText.Contains('QFIELDCLOUD_WORKER_QFIELDCLOUD_URL: "http://nginx:8080/api/v1/"') -and
    $composeText.Contains('./nginx-worker-api.conf.template:/etc/nginx/templates/qfieldcloud-worker-api.conf.template:ro') -and
    $composeText.Contains("expose:`n      - `"8080`"") -and
    $bootstrapText.Contains('runtime/lab-lightsail/nginx-worker-api.conf.template') -and
    $healthText.Contains('runtime/lab-lightsail/nginx-worker-api.conf.template') -and
    $workerNginxText.Contains('listen 8080;') -and
    $workerNginxText.Contains('allow 172.30.0.0/24;') -and
    $workerNginxText.Contains('deny all;') -and
    $workerNginxText.Contains('proxy_set_header X-Forwarded-Proto https;') -and
    $workerNginxText.Contains('proxy_set_header Host ${QFIELDCLOUD_HOST};') -and
    $workerNginxText.Contains('location /storage-download/')
) 'The Docker-private worker API proxy is missing or no longer preserves secure public request semantics.'

Assert-Contract (
    $renewText.Contains('local validation_attempt_limit_value="$3"') -and
    -not $renewText.Contains('local validation_attempt_limit="$3"')
) 'Certificate validation logging still shadows its readonly retry limit.'

$imageLines = @(
    $versionText -split "`r?`n" |
        Where-Object { $_ -match '^[A-Z0-9_]+_IMAGE=' -and $_ -notmatch '^QFC_QGIS4_IMAGE=' }
)
Assert-Contract ($imageLines.Count -ge 10) 'Expected pinned container image manifest entries were not found.'
foreach ($imageLine in $imageLines) {
    Assert-Contract ($imageLine -match '@sha256:[0-9a-f]{64}$') "Mutable container image reference: $imageLine"
}

$operationalText = @($templateText, $bootstrapText, $composeText, $versionText) -join "`n"
Assert-Contract (
    -not [regex]::IsMatch($operationalText, '(?i)(:latest(?:\s|$)|/refs/heads/(?:main|master)|github\.com/[^\s]+/(?:main|master)/)')
) 'An operational dependency uses latest, main, or master.'

$legacyNames = @(
    'qfc-account-admin'
    'qfc-installer'
    'qfc-lab-role'
    'QFieldCloudLabDeployer'
    'Grant-QFieldCloudPilotAccess.ps1'
    'Install-QFieldCloudPilot.ps1'
)
$safeRepositoryRoot = $repositoryRoot.Replace('\', '/')
$repositoryPaths = @(
    & git -c "safe.directory=$safeRepositoryRoot" -C $repositoryRoot `
        ls-files --cached --others --exclude-standard
)
Assert-Contract ($LASTEXITCODE -eq 0 -and $repositoryPaths.Count -gt 0) (
    'Git could not enumerate the tracked and reviewable untracked repository files.'
)
$scannableFiles = @(
    foreach ($repositoryPath in $repositoryPaths) {
        $fullPath = Join-Path $repositoryRoot $repositoryPath
        if ((Test-Path -LiteralPath $fullPath -PathType Leaf) -and
            $fullPath -ne $PSCommandPath) {
            Get-Item -LiteralPath $fullPath
        }
    }
)
$allRepositoryText = ($scannableFiles | ForEach-Object {
    [System.Text.Encoding]::ASCII.GetString(
        [System.IO.File]::ReadAllBytes($_.FullName)
    )
}) -join "`n"
$removedFeatureTokens = @(
    'backup.sh'
    'restore-test.sh'
    'last-backup-'
    'last-restore-test'
    'com.qfieldcloud.restore-test'
    'EnableAutomaticSnapshots'
    'AutomaticSnapshotTimeUtc'
    'AutoSnapshot'
)
foreach ($removedFeatureToken in $removedFeatureTokens) {
    Assert-Contract (-not $allRepositoryText.Contains($removedFeatureToken)) (
        "Removed backup, restore, or automatic snapshot wiring remains: $removedFeatureToken"
    )
}
foreach ($legacyName in $legacyNames) {
    Assert-Contract (-not $allRepositoryText.Contains($legacyName)) "Legacy IAM/CLI identity remains: $legacyName"
}
Assert-Contract (
    -not [regex]::IsMatch($allRepositoryText, '\b(?:AKIA|ASIA)[A-Z0-9]{16}\b') -and
    -not [regex]::IsMatch($allRepositoryText, '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')
) 'A possible AWS access key ID or private key was found.'

$markdownFiles = @($scannableFiles | Where-Object { $_.Extension -ceq '.md' })
foreach ($markdownFile in $markdownFiles) {
    $markdownText = Get-Content -Raw -LiteralPath $markdownFile.FullName
    $markdownText = [regex]::Replace($markdownText, '(?ms)```.*?```', '')
    foreach ($match in [regex]::Matches($markdownText, '!?(?:\[[^\]]*\])\((?<Target>[^)]+)\)')) {
        $target = $match.Groups['Target'].Value.Trim()
        if ($target.StartsWith('<') -and $target.EndsWith('>')) {
            $target = $target.Substring(1, $target.Length - 2)
        }
        if ($target -match '^(?:https?://|mailto:|#)') {
            continue
        }
        $target = ($target -split '#', 2)[0]
        if ([string]::IsNullOrWhiteSpace($target)) {
            continue
        }
        $resolvedTarget = Join-Path $markdownFile.DirectoryName $target
        Assert-Contract (Test-Path -LiteralPath $resolvedTarget) (
            "Broken relative Markdown link in $($markdownFile.FullName): $target"
        )
    }
}

foreach ($releasePath in @($releaseTemplatePath, $releaseManifestPath, $releaseChecksumsPath, $releaseArchivePath)) {
    Assert-Contract (Test-Path -LiteralPath $releasePath -PathType Leaf) "Missing downloadable release file: $releasePath"
}

$releaseTemplateText = Get-Content -Raw -LiteralPath $releaseTemplatePath
$releaseManifest = Get-Content -Raw -LiteralPath $releaseManifestPath | ConvertFrom-Json
$releaseChecksums = Get-Content -Raw -LiteralPath $releaseChecksumsPath
$releaseTemplateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseTemplatePath).Hash.ToLowerInvariant()
$releaseArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $releaseArchivePath).Hash.ToLowerInvariant()
Add-Type -AssemblyName System.IO.Compression.FileSystem
$releaseArchive = [System.IO.Compression.ZipFile]::OpenRead($releaseArchivePath)
try {
    Assert-Contract (
        $releaseArchive.Entries.Count -eq 1 -and
        $releaseArchive.Entries[0].FullName -eq 'template.yaml' -and
        $releaseArchive.Entries[0].Length -eq (Get-Item -LiteralPath $releaseTemplatePath).Length
    ) 'The downloadable ZIP must contain only the complete template.yaml.'
    $archiveTemplateStream = $releaseArchive.Entries[0].Open()
    try {
        $archiveTemplateHash = [Convert]::ToHexString(
            [System.Security.Cryptography.SHA256]::HashData($archiveTemplateStream)
        ).ToLowerInvariant()
    }
    finally {
        $archiveTemplateStream.Dispose()
    }
    Assert-Contract ($archiveTemplateHash -ceq $releaseTemplateHash) (
        'The template.yaml bytes inside the downloadable ZIP differ from the reviewed release template.'
    )
}
finally {
    $releaseArchive.Dispose()
}
Assert-Contract (
    $releaseManifest.release_version -eq 'v0.1.4' -and
    $releaseManifest.source_revision -eq 'd00c5fa4581188299565938d8324103e740a6d9c' -and
    $releaseManifest.template.sha256 -eq $releaseTemplateHash -and
    $releaseTemplateHash -eq '798f2f5aed1c88e27be81db79a06c7adf61f7e5f9ad8fcd3d7f4a114f8d71ffa' -and
    $releaseChecksums.Contains("$releaseTemplateHash  template.yaml") -and
    $releaseArchiveHash -eq '3b351a133d6336be6c6043b7173e59050de28caab6646316720f084dc68a1ad8' -and
    $releaseChecksums.Contains("$releaseArchiveHash  qfieldcloud-lab-lightsail-v0.1.4.zip")
) 'The committed v0.1.4 release manifest or checksum does not match template.yaml.'
Assert-Contract (
    -not $releaseTemplateText.Contains($zeroRevision) -and
    -not $releaseTemplateText.Contains($zeroChecksum) -and
    -not $releaseTemplateText.Contains('__RELEASE_VERSION__') -and
    $releaseTemplateText.Contains($releaseManifest.source_revision) -and
    $releaseTemplateText.Contains($releaseManifest.bootstrap.sha256)
) 'The downloadable release template still has placeholders or does not match its manifest.'

Assert-Contract (
    (Get-FileHash -Algorithm SHA256 -LiteralPath $previousReleaseTemplatePath).Hash.ToLowerInvariant() -eq
        'c977828bf0828074643fb03fa5c3bba9b99c1313da9c5514333d485b233b7677' -and
    (Get-FileHash -Algorithm SHA256 -LiteralPath $previousReleaseArchivePath).Hash.ToLowerInvariant() -eq
        'cd50246fbcb7cf8445683de9ea0c680e3c6438904d7b3b2f21d7a798e6f74761'
) 'The immutable v0.1.3 release files changed unexpectedly.'
Assert-Contract (
    (Get-FileHash -Algorithm SHA256 -LiteralPath $olderReleaseTemplatePath).Hash.ToLowerInvariant() -eq
        'f3c3391704bf07f7ab6b13d1b16115a105d50e4f07a52b4a5ff337bf2adabff4' -and
    (Get-FileHash -Algorithm SHA256 -LiteralPath $olderReleaseArchivePath).Hash.ToLowerInvariant() -eq
        '8c5200d55d4b3be62fcea84e5fa5492cd1eb59d7db76d42af857f00ae82754b9'
) 'The immutable v0.1.2 release files changed unexpectedly.'
Assert-Contract (
    (Get-FileHash -Algorithm SHA256 -LiteralPath $earlierReleaseTemplatePath).Hash.ToLowerInvariant() -eq
        '33b36470d8a5b31aa4d634d9ecf8ca9804d238b03568feb4ebf11849f91e5b2b' -and
    (Get-FileHash -Algorithm SHA256 -LiteralPath $earlierReleaseArchivePath).Hash.ToLowerInvariant() -eq
        '5620adf6e304172750ab10c7cee8b98b82965f8ea3efa99fb815256b7dad657c'
) 'The immutable v0.1.1 release files changed unexpectedly.'
Assert-Contract (
    (Get-FileHash -Algorithm SHA256 -LiteralPath $legacyReleaseTemplatePath).Hash.ToLowerInvariant() -eq
        '506c2c77bcd0c50907c28777151a7256f5541b45c4d66ec7cee0a5164e4fc539' -and
    (Get-FileHash -Algorithm SHA256 -LiteralPath $legacyReleaseArchivePath).Hash.ToLowerInvariant() -eq
        'b825bcad35871b4ee08321559e567ffa78807d5af2a19d9e3abca4f7a14e5f22'
) 'The immutable v0.1.0 release files changed unexpectedly.'

$downloadUrl = 'https://raw.githubusercontent.com/jusubkim94/qfieldcloud-self-hosting-for-arboreta/ad3db49aa4242225b6b3fcd40b8f74e86579c6dc/releases/lab-lightsail/v0.1.3/qfieldcloud-lab-lightsail-v0.1.3.zip'
Assert-Contract (
    $readmeText.Contains($downloadUrl) -and
    $readmeText.Contains('Upload a template file') -and
    $readmeText.Contains('```mermaid') -and
    $readmeText.Contains('create_project` worker 검증이 실패하여 스택이 롤백되었습니다.') -and
    -not [regex]::IsMatch($readmeText, '(?i)\]\(https://[^)]+cloudformation[^)]+templateURL=')
) 'README must expose the reviewed manual-download artifact and its manual CloudFormation upload flow.'

Write-Output 'Manual-download Lightsail static contract validation passed. AWS and S3 were not called.'
