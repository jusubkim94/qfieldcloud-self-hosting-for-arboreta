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

function ConvertTo-CanonicalJson {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        [string[]]$names = @($Value.PSObject.Properties.Name)
        [Array]::Sort($names, [StringComparer]::Ordinal)
        $members = foreach ($name in $names) {
            $encodedName = ConvertTo-Json -InputObject $name -Compress
            $encodedValue = ConvertTo-CanonicalJson -Value $Value.$name
            '{0}:{1}' -f $encodedName, $encodedValue
        }
        return '{' + ($members -join ',') + '}'
    }

    if ($Value -is [System.Collections.IDictionary]) {
        [string[]]$keys = @($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $members = foreach ($key in $keys) {
            $encodedName = ConvertTo-Json -InputObject $key -Compress
            $encodedValue = ConvertTo-CanonicalJson -Value $Value[$key]
            '{0}:{1}' -f $encodedName, $encodedValue
        }
        return '{' + ($members -join ',') + '}'
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = foreach ($item in $Value) {
            ConvertTo-CanonicalJson -Value $item
        }
        return '[' + ($items -join ',') + ']'
    }

    return ConvertTo-Json -InputObject $Value -Compress
}

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($sha256.ComputeHash($bytes)).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-EmbeddedPolicyJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateText
    )

    $beginMarker = '# BEGIN_DEPLOYER_POLICY_JSON'
    $endMarker = '# END_DEPLOYER_POLICY_JSON'
    $beginIndex = $TemplateText.IndexOf($beginMarker, [StringComparison]::Ordinal)
    Assert-Contract ($beginIndex -ge 0) 'The embedded policy begin marker is missing.'

    $jsonStart = $TemplateText.IndexOf('{', $beginIndex)
    Assert-Contract ($jsonStart -gt $beginIndex) 'The embedded policy JSON opening brace is missing.'

    $endIndex = $TemplateText.IndexOf($endMarker, $jsonStart, [StringComparison]::Ordinal)
    Assert-Contract ($endIndex -gt $jsonStart) 'The embedded policy end marker is missing.'
    Assert-Contract (
        $TemplateText.IndexOf($beginMarker, $beginIndex + $beginMarker.Length, [StringComparison]::Ordinal) -lt 0
    ) 'The template must contain exactly one embedded policy begin marker.'
    Assert-Contract (
        $TemplateText.IndexOf($endMarker, $endIndex + $endMarker.Length, [StringComparison]::Ordinal) -lt 0
    ) 'The template must contain exactly one embedded policy end marker.'

    return $TemplateText.Substring($jsonStart, $endIndex - $jsonStart).Trim()
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$templatePath = Join-Path $repositoryRoot 'infra/lab-lightsail/access-bootstrap.yaml'
$sourcePolicyPath = Join-Path $repositoryRoot 'infra/lab-lightsail/deployer-policy.json'

Assert-Contract (Test-Path -LiteralPath $templatePath -PathType Leaf) 'access-bootstrap.yaml is missing.'
Assert-Contract (Test-Path -LiteralPath $sourcePolicyPath -PathType Leaf) 'deployer-policy.json is missing.'

$templateText = Get-Content -Raw -LiteralPath $templatePath
$sourcePolicy = Get-Content -Raw -LiteralPath $sourcePolicyPath | ConvertFrom-Json -Depth 100
$embeddedPolicyJson = Get-EmbeddedPolicyJson -TemplateText $templateText
$embeddedPolicy = $embeddedPolicyJson | ConvertFrom-Json -Depth 100

$sourceCanonical = ConvertTo-CanonicalJson -Value $sourcePolicy
$embeddedCanonical = ConvertTo-CanonicalJson -Value $embeddedPolicy
Assert-Contract (
    $embeddedCanonical -ceq $sourceCanonical
) 'The embedded IAM policy is not semantically identical to deployer-policy.json.'

$policyHash = Get-Sha256Hex -Text $sourceCanonical
Assert-Contract (
    $policyHash -ceq '22076cfe601c2f192f374a4cc66619fea4e6fbb125f0f7d5169e491f28b5cccb'
) 'The repository deployment policy changed; review it and intentionally revise the bootstrap hash.'
Assert-Contract (
    ([regex]::Matches($templateText, [regex]::Escape($policyHash))).Count -eq 2
) 'The canonical policy hash must appear exactly once in Metadata and once in Outputs.'
Assert-Contract (
    ([regex]::Matches($templateText, [regex]::Escape("'2026-08-23.1'"))).Count -eq 2
) 'The fixed policy revision must appear exactly once in Metadata and once in Outputs.'

$resourcesBlock = [regex]::Match(
    $templateText,
    '(?s)^Resources:\r?\n(?<Body>.*?)^Outputs:',
    [Text.RegularExpressions.RegexOptions]::Multiline
).Groups['Body'].Value
Assert-Contract ($resourcesBlock.Length -gt 0) 'The Resources block could not be inspected.'
$resourceMatches = [regex]::Matches(
    $resourcesBlock,
    '(?m)^  (?<LogicalId>[A-Za-z][A-Za-z0-9]*):\r?\n    Type: (?<Type>[^\r\n]+)$'
)
Assert-Contract ($resourceMatches.Count -eq 2) 'The access template must create exactly two resources.'
$resourceTypes = @($resourceMatches | ForEach-Object { $_.Groups['Type'].Value.Trim() })
Assert-Contract (
    @(Compare-Object `
        -ReferenceObject @('AWS::IAM::ManagedPolicy', 'AWS::IAM::Role') `
        -DifferenceObject @($resourceTypes | Sort-Object)).Count -eq 0
) 'The only resources must be one IAM role and one customer managed policy.'
Assert-Contract (
    @($resourceTypes | Where-Object { $_ -eq 'AWS::IAM::Role' }).Count -eq 1
) 'The template must create exactly one IAM role.'
Assert-Contract (
    @($resourceTypes | Where-Object { $_ -eq 'AWS::IAM::ManagedPolicy' }).Count -eq 1
) 'The template must create exactly one customer managed policy.'

$forbiddenResourceTypes = @(
    'AWS::IAM::AccessKey'
    'AWS::IAM::Group'
    'AWS::IAM::InstanceProfile'
    'AWS::IAM::Policy'
    'AWS::IAM::ServiceLinkedRole'
    'AWS::IAM::User'
)
foreach ($resourceType in $forbiddenResourceTypes) {
    Assert-Contract (
        $templateText -notmatch ('(?m)^\s+Type:\s+' + [regex]::Escape($resourceType) + '\s*$')
    ) "Forbidden IAM resource type found: $resourceType"
}
Assert-Contract ($templateText -notmatch '(?im)^\s*LoginProfile\s*:') 'The template must not create a console password.'
Assert-Contract ($templateText -notmatch '(?im)^\s*(AccessKeyId|SecretAccessKey|Password)\s*:') 'The template must not contain credentials.'

Assert-Contract ($templateText -match '(?m)^    RequiredStackName: qfieldcloud-lab-access$') 'The fixed access stack name is not documented.'
Assert-Contract ($templateText -match '(?m)^    RequiredRegion: ap-northeast-2$') 'The fixed Seoul Region is not documented.'
Assert-Contract ($templateText -match '(?s)SeoulRegionOnly:.*?Ref: AWS::Region.*?- ap-northeast-2') 'The Seoul-only template Rule is missing.'

Assert-Contract ($templateText -match '(?m)^      RoleName: QFieldCloudLabDeployer$') 'The fixed role name is missing.'
Assert-Contract ($templateText -match '(?m)^      ManagedPolicyName: QFieldCloudLabDeployer$') 'The fixed managed-policy name is missing.'
Assert-Contract (
    ([regex]::Matches($templateText, '(?m)^      Path: /qfieldcloud-lab/$')).Count -eq 2
) 'The role and managed policy must both use the fixed /qfieldcloud-lab/ path.'
Assert-Contract ($templateText -match '(?m)^      MaxSessionDuration: 3600$') 'Role sessions must be capped at 3600 seconds.'
Assert-Contract (
    $templateText -match '(?s)ManagedPolicyArns:\s*\r?\n\s+- !Ref LabDeploymentPolicy\s*\r?\n\s+PermissionsBoundary: !Ref LabDeploymentPolicy'
) 'The same managed policy must be attached as both permissions and permissions boundary.'
$expectedRoleTags = [ordered]@{
    Project = 'qfieldcloud-self-hosting'
    DeploymentProfile = 'lab-lightsail'
    ManagedBy = 'CloudFormation'
    CloudFormationStack = 'qfieldcloud-lab-access'
    AccessPurpose = 'pilot-deployment-only'
}
foreach ($tag in $expectedRoleTags.GetEnumerator()) {
    $tagPattern = '(?m)^\s+- Key: {0}\r?\n\s+Value: {1}$' -f `
        [regex]::Escape($tag.Key),
        [regex]::Escape($tag.Value)
    Assert-Contract ($resourcesBlock -match $tagPattern) "Required role tag is missing: $($tag.Key)"
}

Assert-Contract (
    ([regex]::Matches($templateText, '(?m)^    DeletionPolicy: Retain$')).Count -eq 2
) 'Both IAM resources must be retained on stack deletion.'
Assert-Contract (
    ([regex]::Matches($templateText, '(?m)^    UpdateReplacePolicy: Retain$')).Count -eq 2
) 'Both IAM resources must be retained on replacement.'
Assert-Contract ($templateText -match '(?m)^      CreateStackWithTerminationProtection: true$') 'Termination protection must be documented as required.'

$parametersBlock = [regex]::Match($templateText, '(?s)^Parameters:\r?\n(?<Body>.*?)^Rules:', 'Multiline').Groups['Body'].Value
Assert-Contract ($parametersBlock.Length -gt 0) 'The Parameters block could not be inspected.'
Assert-Contract ($parametersBlock -notmatch '(?m)^\s{2}\S*Arn\s*:') 'Caller-supplied ARN parameters are forbidden.'
Assert-Contract (
    ([regex]::Matches($parametersBlock, [regex]::Escape("AllowedPattern: '^$|[A-Za-z0-9+=,.@_-]{1,64}$'"))).Count -eq 1
) 'The IAM user name parameter must exclude paths, ARNs, and wildcard characters.'
Assert-Contract (
    ([regex]::Matches($parametersBlock, [regex]::Escape("AllowedPattern: '^$|[A-Za-z0-9+=,.@_-]{1,32}$'"))).Count -eq 1
) 'The permission-set name parameter must exclude paths, ARNs, and wildcard characters.'
Assert-Contract (
    $parametersBlock -match '(?s)TrustedPrincipalKind:.*?AllowedValues:\s*\r?\n\s+- IamUser\s*\r?\n\s+- IdentityCenterPermissionSet'
) 'Trust kind must allow only exact IAM-user or Identity Center permission-set modes.'
Assert-Contract (
    $templateText -match '(?s)TrustInputsMustMatchSelectedKind:.*?IAM-user mode requires only TrustedIamUserName.*?Identity Center mode requires'
) 'Mode-specific mutually exclusive trust inputs are not enforced by a template Rule.'

$exactUserArn = 'arn:${AWS::Partition}:iam::${AWS::AccountId}:user/${TrustedIamUserName}'
Assert-Contract (
    ([regex]::Matches($templateText, [regex]::Escape($exactUserArn))).Count -eq 2
) 'The exact same-account IAM-user ARN must appear once in trust and once in Outputs.'
Assert-Contract (
    ([regex]::Matches($templateText, [regex]::Escape("AWS: !Sub $exactUserArn"))).Count -eq 1
) 'The IAM-user trust Principal must contain only the exact derived user ARN.'
$sameAccountRoot = 'AWS: !Sub arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
Assert-Contract (
    ([regex]::Matches($templateText, [regex]::Escape($sameAccountRoot))).Count -eq 1
) 'Identity Center trust must use exactly one same-account root Principal.'
Assert-Contract (
    ([regex]::Matches($resourcesBlock, '(?m)^\s+Principal:$')).Count -eq 2
) 'The role trust policy must contain exactly the two conditional Principal definitions.'
Assert-Contract (
    $templateText -notmatch '(?m)^\s*(AWS:\s*)?["'']?\*["'']?\s*$'
) 'Wildcard trust Principals are forbidden.'
Assert-Contract ($templateText -notmatch '(?im)^\s*NotPrincipal\s*:') 'NotPrincipal trust is forbidden.'
Assert-Contract (
    $templateText -match '(?s)Sid: TrustExactSameAccountIdentityCenterPermissionSet.*?ArnLike:\s*\r?\n\s+aws:PrincipalArn: !If.*?StringEquals:\s*\r?\n\s+aws:PrincipalAccount: !Ref AWS::AccountId'
) 'Identity Center trust must bind root delegation to a tight PrincipalArn pattern and the same account.'

$ssoUsEastPattern = 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_${IdentityCenterPermissionSetName}_*'
$ssoRegionalPattern = 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/aws-reserved/sso.amazonaws.com/${IdentityCenterRegion}/AWSReservedSSO_${IdentityCenterPermissionSetName}_*'
Assert-Contract (
    ([regex]::Matches($templateText, [regex]::Escape($ssoUsEastPattern))).Count -eq 2
) 'The exact us-east-1 Identity Center path pattern must appear in trust and Outputs.'
Assert-Contract (
    ([regex]::Matches($templateText, [regex]::Escape($ssoRegionalPattern))).Count -eq 2
) 'The exact regional Identity Center path pattern must appear in trust and Outputs.'
Assert-Contract ($templateText -notmatch 'assumed-role/') 'STS assumed-role session ARNs must never be trusted directly.'

$allowedStatements = @($embeddedPolicy.Statement | Where-Object { $_.Effect -eq 'Allow' })
$allowedActions = @($allowedStatements | ForEach-Object { @($_.Action) })
$forbiddenAllowedActions = @(
    'cloudformation:DeleteStack'
    'cloudformation:UpdateTerminationProtection'
    'iam:PassRole'
)
foreach ($action in $forbiddenAllowedActions) {
    Assert-Contract ($allowedActions -notcontains $action) "Forbidden deployment permission found: $action"
}
Assert-Contract ($templateText -notmatch 'QFieldCloudLabCleanup') 'The cleanup policy must not be included in the access stack.'
Assert-Contract (
    @($allowedActions | Where-Object { $_ -like 'iam:*' }).Count -eq 0
) 'The deployment policy must not grant IAM API access.'
Assert-Contract (
    @($allowedActions | Where-Object { $_ -like 'organizations:*' }).Count -eq 0
) 'The deployment policy must not grant AWS Organizations access.'
Assert-Contract (
    @($allowedActions | Where-Object { $_ -like 'sts:*' }).Count -eq 0
) 'The deployment policy must not grant role chaining or STS API access.'

$allowedDeleteStatements = @(
    $allowedStatements | Where-Object {
        @($_.Action | Where-Object { $_ -match ':Delete' }).Count -gt 0
    }
)
foreach ($statement in $allowedDeleteStatements) {
    $deleteActions = @($statement.Action | Where-Object { $_ -match ':Delete' })
    Assert-Contract (
        @($deleteActions | Where-Object { $_ -notlike 'lightsail:Delete*' }).Count -eq 0
    ) 'Only the source deployer policy''s Lightsail rollback deletes may remain.'
    Assert-Contract (
        $statement.Condition.'ForAnyValue:StringEquals'.'aws:CalledVia' -eq 'cloudformation.amazonaws.com'
    ) 'Every Lightsail rollback delete must be callable only through CloudFormation.'
}
Assert-Contract ($allowedDeleteStatements.Count -gt 0) 'Expected CloudFormation-scoped Lightsail rollback permissions are missing.'

$outputNames = @(
    'DeploymentRoleArn'
    'DeploymentPolicyArn'
    'TrustedPrincipalKind'
    'TrustedPrincipalPattern'
    'PolicyRevision'
    'PolicySha256'
    'DeletionPermissionsIncluded'
)
foreach ($outputName in $outputNames) {
    Assert-Contract (
        $templateText -match ('(?m)^  ' + [regex]::Escape($outputName) + ':$')
    ) "Required output is missing: $outputName"
}
Assert-Contract (
    $templateText -match '(?s)DeletionPermissionsIncluded:.*?Value: ''false'''
) 'The stack must explicitly report that deletion permissions are excluded.'

Write-Host 'Access bootstrap static validation passed.'
Write-Host "Policy revision: 2026-08-23.1"
Write-Host "Canonical policy SHA-256: $policyHash"
