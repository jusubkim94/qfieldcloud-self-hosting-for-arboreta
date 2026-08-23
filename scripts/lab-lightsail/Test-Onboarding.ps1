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

function Get-CheckedScriptText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Assert-Contract (Test-Path -LiteralPath $Path -PathType Leaf) "Missing script: $Path"
    $text = Get-Content -Raw -LiteralPath $Path
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput(
        $text,
        [ref]$tokens,
        [ref]$errors
    )
    Assert-Contract (@($errors).Count -eq 0) "PowerShell syntax error: $Path"
    return $text
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPaths = [ordered]@{
    Deploy  = Join-Path $PSScriptRoot 'Deploy-QFieldCloudPilot.ps1'
    Verify  = Join-Path $PSScriptRoot 'Test-QFieldCloudPilot.ps1'
    Grant   = Join-Path $PSScriptRoot 'Grant-QFieldCloudPilotAccess.ps1'
    Install = Join-Path $PSScriptRoot 'Install-QFieldCloudPilot.ps1'
}
$scriptTexts = [ordered]@{}
foreach ($entry in $scriptPaths.GetEnumerator()) {
    $scriptTexts[$entry.Key] = Get-CheckedScriptText -Path $entry.Value
}

foreach ($entry in $scriptTexts.GetEnumerator()) {
    $text = [string]$entry.Value
    Assert-Contract (
        $text.Contains('Get-Command aws -CommandType Application')
    ) "$($entry.Key) can resolve a PowerShell function or script instead of the AWS CLI application."
    Assert-Contract (
        $text.Contains('Get-AuthenticodeSignature -LiteralPath $candidate') -and
        $text.Contains("`$signerName -cne 'Amazon Web Services, Inc.'")
    ) "$($entry.Key) does not verify the AWS Windows executable signature."
    Assert-Contract (
        $text.Contains("StartsWith('AWS_ENDPOINT_URL_', [StringComparison]::OrdinalIgnoreCase)")
    ) "$($entry.Key) does not reject every service-specific AWS endpoint override."
}
Assert-Contract (
    [string]$scriptTexts.Deploy -match [regex]::Escape("Join-Path `$PSScriptRoot '..\..'") -and
    [string]$scriptTexts.Deploy -match [regex]::Escape('-C $repositoryRoot rev-parse --show-toplevel') -and
    [string]$scriptTexts.Deploy -match [regex]::Escape('Get-Command git -CommandType Application')
) 'The direct deploy script is not bound to its own verified repository.'

$installText = [string]$scriptTexts.Install
Assert-Contract (
    $installText.Contains("[ValidatePattern('^(?:[A-Za-z0-9_-]+)?`$')]")
) 'The optional role profile name is not fully anchored.'
Assert-Contract (
    $installText.Contains("Join-Path `$PSScriptRoot '..\..'") -and
    $installText.Contains('-C $repositoryRoot rev-parse --show-toplevel')
) 'The installer does not bind execution to its own repository.'
Assert-Contract (
    ([regex]::Matches($installText, 'Push-Location -LiteralPath \$repositoryRoot')).Count -eq 2 -and
    ([regex]::Matches($installText, '(?m)^\s*Pop-Location\s*$')).Count -eq 2
) 'Both child deployment calls must run from the verified repository root.'
Assert-Contract (
    $installText.Contains('$SourceProfile.Length -le 55') -and
    $installText.Contains('$SourceProfile.Substring(0, 40)')
) 'Automatic role profile names are not bounded to 64 characters.'
Assert-Contract (
    $installText.Contains('다시 실행하면 안전하게 이어서 복구합니다.') -and
    $installText.Contains('-not $section.Values.Contains([string]$entry.Key)')
) 'Interrupted local role profile creation is not recoverable by rerunning.'
Assert-Contract (
    $installText.Contains('로컬 변경 안내: 로그인 캐시가 갱신될 수 있으며')
) 'The installer does not disclose its local login-cache and AWS config changes.'
Assert-Contract (
    $installText.Contains("`$confirmation = 'DEPLOY QFIELDCLOUD LAB PILOT IN SEOUL AFTER REVIEWING COST AND FAILURE RISK'") -and
    $installText.Contains('QFC_APPROVAL_RECEIPT_V1=') -and
    $installText.Contains('-ApprovedPlanSha256 $approvedPlanSha256') -and
    $installText.Contains('-ApprovedCommitSha $approvedCommitSha')
) 'The final confirmation is not bound to the reviewed plan and Git commit.'
Assert-Contract (
    $installText -notmatch '(?i)\b(cloudformation|lightsail|iam)\s+(create|delete|update|attach|detach)'
) 'The wrapper must delegate AWS resource mutation to the reviewed scripts.'
Assert-Contract (
    $installText.Contains('function ConvertTo-AbsoluteAwsProfileFileOverrides') -and
    $installText.Contains('[Environment]::SetEnvironmentVariable(') -and
    [regex]::Match(
        $installText,
        '(?m)^\s*ConvertTo-AbsoluteAwsProfileFileOverrides\s*$'
    ).Index -lt [regex]::Match(
        $installText,
        '(?m)^\s*\$awsExecutable\s*=\s*Get-AwsExecutable\s*$'
    ).Index
) 'Relative AWS profile file overrides are not normalized before AWS CLI use.'

$deployText = [string]$scriptTexts.Deploy
Assert-Contract (
    $deployText.Contains("[string]`$ApprovedCommitSha = ''") -and
    $deployText.Contains("[string]`$ApprovedPlanSha256 = ''") -and
    $deployText.Contains('QFC_APPROVAL_RECEIPT_V1=') -and
    $deployText.Contains('$approvalPlanSha256 -cne $ApprovedPlanSha256') -and
    $deployText.Contains('$bootstrapRevision -cne $ApprovedCommitSha')
) 'The deployer does not fail closed when the approved plan or commit changes.'
Assert-Contract (
    $deployText.Contains('ApprovalSchemaVersion') -and
    $deployText.Contains('BundleMonthlyUsd') -and
    $deployText.Contains('TemplateSha256') -and
    $deployText.Contains('ExistingAlarmName') -and
    $deployText.Contains('CloudFormationResourceTypes')
) 'The approval plan hash omits required code, cost, or collision inputs.'
Assert-Contract (
    $deployText.Contains('TargetAccountId = $TargetAccountId') -and
    $deployText.Contains('-TargetAccountId $ExpectedAccountId') -and
    -not $deployText.Contains('TargetAccountId              = $ExpectedAccountId')
) 'The approval hash is not bound to the target account or the account ID is exposed in the displayed plan.'

$deployTokens = $null
$deployErrors = $null
$deployAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $deployText,
    [ref]$deployTokens,
    [ref]$deployErrors
)
foreach ($functionName in @(
    'Get-Sha256Hex'
    'Get-ApprovalPlanSha256'
    'Get-ReleaseManifestValue'
)) {
    $functionNodes = @(
        $deployAst.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq $functionName
            },
            $true
        )
    )
    Assert-Contract ($functionNodes.Count -eq 1) "Deployer function count changed: $functionName"
    . ([scriptblock]::Create($functionNodes[0].Extent.Text))
}
$manifestCommit = 'c32bc110f8291b2a32e318528ee46689771630d6'
$manifestDhparamsSha256 = 'a6e3c01dabf4fe5cb32b20e1f84e55a2aa4309159e102867a1ca8fa7e8acd991'
$manifestLinesWithIntentionalBlanks = @(
    '# Release provenance'
    "QFIELDCLOUD_COMMIT=$manifestCommit"
    ''
    "QFIELDCLOUD_DHPARAM_SHA256=$manifestDhparamsSha256"
    ''
)
Assert-Contract (
    (Get-ReleaseManifestValue `
        -Lines $manifestLinesWithIntentionalBlanks `
        -Name QFIELDCLOUD_COMMIT) -ceq $manifestCommit
) 'The deployer cannot read a release manifest that contains intentional blank lines.'
Assert-Contract (
    (Get-ReleaseManifestValue `
        -Lines $manifestLinesWithIntentionalBlanks `
        -Name QFIELDCLOUD_DHPARAM_SHA256) -ceq $manifestDhparamsSha256
) 'The deployer cannot read the DH parameters pin when the manifest contains blank lines.'
$actualManifestLines = @(
    Get-Content -LiteralPath (Join-Path $repositoryRoot 'config\qfieldcloud-v26.25.env')
)
Assert-Contract (
    (Get-ReleaseManifestValue `
        -Lines $actualManifestLines `
        -Name QFIELDCLOUD_COMMIT) -match '^[0-9a-f]{40}$'
) 'The deployer cannot read the pinned commit from the checked-in release manifest.'
Assert-Contract (
    (Get-ReleaseManifestValue `
        -Lines $actualManifestLines `
        -Name QFIELDCLOUD_DHPARAM_SHA256) -match '^[0-9a-f]{64}$'
) 'The deployer cannot read the DH parameters pin from the checked-in release manifest.'
$sampleApprovalPlan = [ordered]@{
    ApprovalSchemaVersion = 1
    BootstrapRevision     = '0000000000000000000000000000000000000000'
    BundleMonthlyUsd      = [decimal]24
}
$accountAPlanHash = Get-ApprovalPlanSha256 `
    -Plan $sampleApprovalPlan `
    -TargetAccountId '000000000000'
$accountBPlanHash = Get-ApprovalPlanSha256 `
    -Plan $sampleApprovalPlan `
    -TargetAccountId '000000000001'
$accountARepeatHash = Get-ApprovalPlanSha256 `
    -Plan $sampleApprovalPlan `
    -TargetAccountId '000000000000'
Assert-Contract (
    $accountAPlanHash -match '^[0-9a-f]{64}$' -and
    $accountAPlanHash -cne $accountBPlanHash -and
    $accountAPlanHash -ceq $accountARepeatHash
) 'Approval plan hashing is not deterministic and account-bound.'

$grantText = [string]$scriptTexts.Grant
Assert-Contract (
    $grantText.Contains("[string]`$TrustedPrincipalArn = ''") -and
    $grantText.Contains("'admin-session-derived'") -and
    $grantText.Contains("'iam', 'get-role', '--role-name', `$ssoCallerMatch.Groups['RoleName'].Value")
) 'The common access-bootstrap path does not derive the exact principal from the admin temporary session.'
Assert-Contract (
    $grantText.Contains("'iam', 'list-access-keys', '--user-name', `$trustedIamUserName") -and
    $grantText.Contains("'iam', 'list-mfa-devices', '--user-name', `$trustedIamUserName") -and
    $grantText.Contains("TrustedIamUserAccessKeys  = if (`$trustedPrincipalKind -eq 'IamUser') { 'none-verified' }")
) 'The access bootstrap does not reject long-term IAM user keys or missing MFA.'
Assert-Contract (
    $grantText.Contains("Join-Path `$PSScriptRoot '..\..'") -and
    $grantText.Contains('-C $repositoryRoot rev-parse --show-toplevel') -and
    $grantText.Contains('Get-Command git -CommandType Application')
) 'The access bootstrap is not bound to its own verified repository.'
Assert-Contract (
    $grantText -notmatch 'branch --show-current|ls-remote --heads|main 또는 detached HEAD'
) 'The access bootstrap wrongly rejects a clean public main or detached release commit.'
$planGuardIndex = $grantText.IndexOf('if (-not $Execute)', [StringComparison]::Ordinal)
$confirmationIndex = $grantText.IndexOf('$typedConfirmation = Read-Host', [StringComparison]::Ordinal)
$temporaryParameterIndex = $grantText.IndexOf('$parameterDirectory =', [StringComparison]::Ordinal)
Assert-Contract (
    $planGuardIndex -ge 0 -and
    $confirmationIndex -gt $planGuardIndex -and
    $temporaryParameterIndex -gt $confirmationIndex
) 'The access bootstrap plan guard or confirmation order changed.'
Assert-Contract (
    $grantText.Contains("'--retain-except-on-create'") -and
    $grantText.Contains("-cne 'PermissionsBoundaryPolicy'")
) 'The safe initial rollback or permissions-boundary verification is missing.'
Assert-Contract (
    $grantText.Contains("'--parameters', `$parameterFileUri") -and
    $grantText.Contains("'--stack-policy-body', `$stackPolicyFileUri") -and
    $grantText.Contains('[System.Text.UTF8Encoding]::new($false)') -and
    $grantText.Contains('Remove-Item -LiteralPath $stackPolicyFile -Force -ErrorAction SilentlyContinue') -and
    $grantText.Contains('Remove-Item -LiteralPath $parameterDirectory -Force -ErrorAction SilentlyContinue')
) 'CloudFormation parameters are not passed through a cleaned-up UTF-8 file.'
Assert-Contract (
    $grantText.Contains("'cloudformation', 'get-stack-policy', '--stack-name', `$StackName") -and
    $grantText.Contains("StackUpdatePolicy         = 'deny-all-updates'")
) 'The access stack does not set and verify a deny-all update policy.'
Assert-Contract (
    $grantText.Contains("'--capabilities', 'CAPABILITY_NAMED_IAM'") -and
    $grantText.Contains("'--enable-termination-protection'")
) 'The named-IAM acknowledgement or access-stack termination protection is missing.'

Assert-Contract (
    (Test-Path -LiteralPath (Join-Path $repositoryRoot 'infra/lab-lightsail/access-bootstrap.yaml') -PathType Leaf)
) 'The access bootstrap template is missing.'

# Exercise interrupted role-profile creation without invoking AWS or touching the real user profile.
$installTokens = $null
$installErrors = $null
$installAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $installText,
    [ref]$installTokens,
    [ref]$installErrors
)
foreach ($functionName in @(
    'Assert-ExactKeys',
    'Assert-NoCredentialsSection',
    'ConvertTo-AbsoluteAwsProfileFileOverrides',
    'Get-AwsProfileFileSection',
    'Set-RoleProfile'
)) {
    $functionNodes = @(
        $installAst.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq $functionName
            },
            $true
        )
    )
    Assert-Contract ($functionNodes.Count -eq 1) "Installer function count changed: $functionName"
    . ([scriptblock]::Create($functionNodes[0].Extent.Text))
}

$temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $temporaryRoot "qfc-onboarding-test-$([Guid]::NewGuid().ToString('N'))")
)
$temporaryPrefix = $temporaryRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
Assert-Contract (
    $testDirectory.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)
) 'The onboarding test directory escaped the operating-system temporary directory.'

$previousConfigPath = [Environment]::GetEnvironmentVariable(
    'AWS_CONFIG_FILE',
    [EnvironmentVariableTarget]::Process
)
$previousCredentialsPath = [Environment]::GetEnvironmentVariable(
    'AWS_SHARED_CREDENTIALS_FILE',
    [EnvironmentVariableTarget]::Process
)
try {
    $null = New-Item -ItemType Directory -Path $testDirectory -ErrorAction Stop
    $profileDirectory = Join-Path $testDirectory 'profile-files'
    $null = New-Item -ItemType Directory -Path $profileDirectory -ErrorAction Stop
    $testConfigPath = Join-Path $profileDirectory 'config'
    $testCredentialsPath = Join-Path $testDirectory 'credentials'
    Push-Location -LiteralPath $testDirectory
    try {
        [Environment]::SetEnvironmentVariable(
            'AWS_CONFIG_FILE',
            (Join-Path 'profile-files' 'config'),
            [EnvironmentVariableTarget]::Process
        )
        ConvertTo-AbsoluteAwsProfileFileOverrides
    }
    finally {
        Pop-Location
    }
    Assert-Contract (
        [Environment]::GetEnvironmentVariable(
            'AWS_CONFIG_FILE',
            [EnvironmentVariableTarget]::Process
        ) -ceq [System.IO.Path]::GetFullPath($testConfigPath)
    ) 'A relative AWS_CONFIG_FILE was not pinned before the working directory changed.'
    [Environment]::SetEnvironmentVariable(
        'AWS_SHARED_CREDENTIALS_FILE',
        $testCredentialsPath,
        [EnvironmentVariableTarget]::Process
    )

    $script:SourceProfile = 'temporary-source'
    $script:RoleProfile = 'temporary-role'
    $script:region = 'ap-northeast-2'
    $script:allowedRoleProfileKeys = @(
        'duration_seconds', 'region', 'role_arn', 'role_session_name', 'source_profile'
    )
    $script:fakeConfigureCalls = 0
    $script:fakeConfigureFailAt = 3
    $script:awsExecutable = {
        $script:fakeConfigureCalls++
        if ($args.Count -ne 6 -or
            [string]$args[0] -cne 'configure' -or
            [string]$args[1] -cne 'set' -or
            [string]$args[4] -cne '--profile' -or
            [string]$args[5] -cne $script:RoleProfile) {
            $global:LASTEXITCODE = 2
            return
        }
        if ($script:fakeConfigureFailAt -gt 0 -and
            $script:fakeConfigureCalls -eq $script:fakeConfigureFailAt) {
            $global:LASTEXITCODE = 1
            return
        }

        $header = "[profile $($script:RoleProfile)]"
        if (-not (Test-Path -LiteralPath $testConfigPath -PathType Leaf)) {
            [System.IO.File]::WriteAllText(
                $testConfigPath,
                "$header`n",
                [System.Text.UTF8Encoding]::new($false)
            )
        }
        [System.IO.File]::AppendAllText(
            $testConfigPath,
            "$([string]$args[2]) = $([string]$args[3])`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        $global:LASTEXITCODE = 0
    }

    $expectedRoleArn = 'arn:aws:iam::000000000000:role/qfieldcloud-lab/QFieldCloudLabDeployer'
    $interruptionDetected = $false
    try {
        $null = Set-RoleProfile -ExpectedRoleArn $expectedRoleArn
    }
    catch {
        $interruptionDetected = $_.Exception.Message -match '다시 실행하면 안전하게 이어서 복구합니다'
    }
    Assert-Contract $interruptionDetected 'The simulated interrupted profile write did not fail safely.'

    $script:fakeConfigureFailAt = 0
    $sessionName = Set-RoleProfile -ExpectedRoleArn $expectedRoleArn
    Assert-Contract (
        $sessionName -match '^qfc-lab-[0-9a-f]{16}$'
    ) 'Rerunning did not repair the interrupted role profile with a safe session name.'
    $repairedSection = Get-AwsProfileFileSection -ProfileName $script:RoleProfile -FileKind Config
    Assert-Contract (
        $repairedSection.Exists -and
        @($repairedSection.Values.Keys).Count -eq 5 -and
        [string]$repairedSection.Values['role_arn'] -ceq $expectedRoleArn -and
        [string]$repairedSection.Values['source_profile'] -ceq $script:SourceProfile -and
        [string]$repairedSection.Values['role_session_name'] -ceq $sessionName -and
        [string]$repairedSection.Values['duration_seconds'] -ceq '3600' -and
        [string]$repairedSection.Values['region'] -ceq 'ap-northeast-2'
    ) 'The repaired role profile does not have the exact no-secret contract.'
}
finally {
    [Environment]::SetEnvironmentVariable(
        'AWS_CONFIG_FILE',
        $previousConfigPath,
        [EnvironmentVariableTarget]::Process
    )
    [Environment]::SetEnvironmentVariable(
        'AWS_SHARED_CREDENTIALS_FILE',
        $previousCredentialsPath,
        [EnvironmentVariableTarget]::Process
    )
    if (Test-Path -LiteralPath $testDirectory -PathType Container) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}

Write-Host 'Onboarding static validation passed. AWS API was not called.'
