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
$bootstrapPath = Join-Path $PSScriptRoot 'bootstrap.sh'
Assert-Contract (
    Test-Path -LiteralPath $bootstrapPath -PathType Leaf
) "Missing script: $bootstrapPath"
$bootstrapText = Get-Content -Raw -LiteralPath $bootstrapPath
$workerSmokeText = Get-Content -Raw -LiteralPath (
    Join-Path $PSScriptRoot 'worker-smoke-test.sh'
)
$backupText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'backup.sh')
$restoreTestText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'restore-test.sh')
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
    $applicationLookups = [regex]::Matches(
        $text,
        'Get-Command (?:aws|git|pwsh) -CommandType Application -ErrorAction SilentlyContinue'
    )
    $singleApplicationLookups = [regex]::Matches(
        $text,
        '(?s)Get-Command (?:aws|git|pwsh) -CommandType Application ' +
            '-ErrorAction SilentlyContinue\s*\|\s*Select-Object -First 1'
    )
    Assert-Contract (
        $applicationLookups.Count -eq $singleApplicationLookups.Count
    ) "$($entry.Key) does not deterministically select one executable when PATH has duplicates."
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
Assert-Contract (
    $bootstrapText.Contains('--entrypoint /usr/bin/python3 ') -and
    $bootstrapText.Contains('The pinned QGIS 3 image could not run its Python 3 verification (exit code $qgis_exit_code).') -and
    $bootstrapText.Contains('exit "$qgis_exit_code"') -and
    $bootstrapText.Contains('[[ $qgis_version != "$QFC_QGIS3_EXPECTED_VERSION"-* ]]') -and
    -not [regex]::IsMatch($bootstrapText, '--entrypoint python\s')
) 'The QGIS image verification must use Python 3, preserve startup failures, and accept the official version suffix.'
Assert-Contract (
    $bootstrapText.Contains('from qfieldcloud.core.models import Person') -and
    $bootstrapText.Contains('Person.objects.create_superuser(') -and
    -not [regex]::IsMatch(
        $bootstrapText,
        '(?s)from django\.contrib\.auth import get_user_model.*?get_user_model\(\)\.objects\.create_superuser\('
    )
) 'The QFieldCloud administrator must be created as a Person so its initial subscription can reference an existing Person row.'
$djangoShellBlocks = [regex]::Matches(
    $bootstrapText,
    "(?ms)app python manage\.py shell -c '\r?\n(?<Script>.*?)\r?\n'"
)
Assert-Contract (
    $djangoShellBlocks.Count -eq 2 -and
    @($djangoShellBlocks | Where-Object { $_.Groups['Script'].Value.Contains("'") }).Count -eq 0
) 'Single-quoted Django shell blocks must not contain apostrophes that terminate the surrounding shell string.'
Assert-Contract (
    $bootstrapText.Contains('curl --fail --silent --show-error --connect-timeout 5 --max-time 20')
) 'The initial HTTPS health gate must bound both connection and total request time.'
$publicIpRetryPattern = '(?m)^[ \t]*if ! candidate="\$\(curl --fail --silent --show-error --max-time 10 https://checkip\.amazonaws\.com \| tr -d ''\[:space:\]''\)"; then\r?\n[ \t]+candidate=""\r?\n[ \t]*fi[ \t]*$'
$nakedPublicIpFetchPattern = '(?m)^[ \t]*candidate="\$\(curl --fail --silent --show-error --max-time 10 https://checkip\.amazonaws\.com \| tr -d ''\[:space:\]''\)"[ \t]*$'
Assert-Contract (
    [regex]::IsMatch($bootstrapText, $publicIpRetryPattern) -and
    -not [regex]::IsMatch($bootstrapText, $nakedPublicIpFetchPattern) -and
    $bootstrapText.Contains('local attempts_remaining=18') -and
    $bootstrapText.Contains('attempts_remaining=$((attempts_remaining - 1))')
) 'Public IPv4 transport failures bypass the bounded retry loop under errexit/pipefail.'
Assert-Contract (
    $bootstrapText.Contains('echo "Installation-gate health-check JSON:"') -and
    $bootstrapText.Contains('if ! "$install_root/bin/health-check.sh" --installation-gate; then') -and
    $bootstrapText.Contains('echo "Final health-check JSON:"') -and
    $bootstrapText.Contains('if ! "$install_root/bin/health-check.sh"; then') -and
    -not $bootstrapText.Contains('--installation-gate >/dev/null')
) 'Bootstrap health failures do not retain their non-secret JSON diagnosis in the root-only log.'
Assert-Contract (
    $bootstrapText.IndexOf('umask 077', [StringComparison]::Ordinal) -ge 0 -and
    $bootstrapText.IndexOf('readonly log_file="/var/log/qfieldcloud/bootstrap.log"', [StringComparison]::Ordinal) -gt
        $bootstrapText.IndexOf('umask 077', [StringComparison]::Ordinal) -and
    $bootstrapText.Contains('touch "$log_file"') -and
    $bootstrapText.Contains('chmod 0600 "$log_file"') -and
    $bootstrapText.Contains('exec > >(tee -a "$log_file") 2>&1')
) 'The inner bootstrap diagnosis log is not pinned to its root-only 0600 contract.'
$lockScriptTexts = [ordered]@{
    Bootstrap   = $bootstrapText
    Backup      = $backupText
    RestoreTest = $restoreTestText
    WorkerSmoke = $workerSmokeText
}
foreach ($lockScript in $lockScriptTexts.GetEnumerator()) {
    Assert-Contract (
        $lockScript.Value.Contains('readonly qfc_lock_parent="/var/lib/qfieldcloud"') -and
        $lockScript.Value.Contains('readonly qfc_lock_root="$qfc_lock_parent/locks"') -and
        $lockScript.Value.Contains('for trusted_ancestor in / /var /var/lib; do') -and
        $lockScript.Value.Contains('install -o root -g root -m 0700 -d -- "$lock_path"') -and
        $lockScript.Value.Contains('[[ $(stat -c ''%u:%g:%a'' "$lock_path") == "0:0:700" ]]') -and
        [regex]::Matches(
            $lockScript.Value,
            '\[\[ -f \$lock_file && ! -L \$lock_file \]\] \|\| return 1'
        ).Count -ge 2 -and
        $lockScript.Value.Contains('lock_tmp="$(mktemp "$qfc_lock_root/.lock.XXXXXX")"') -and
        $lockScript.Value.Contains('ln -T -- "$lock_tmp" "$lock_file"') -and
        $lockScript.Value.Contains('&& [[ ! -e $lock_file && ! -L $lock_file ]]') -and
        -not $lockScript.Value.Contains('install -o root -g root -m 0600 /dev/null "$lock_file"') -and
        $lockScript.Value.Contains('[[ $(stat -c ''%u:%g:%a'' "$lock_file") == "0:0:600" ]]') -and
        $lockScript.Value.Contains('stat -Lc ''%d:%i'' "/proc/$$/fd/$lock_fd"') -and
        $lockScript.Value.Contains('flock -n 8') -and
        $lockScript.Value.Contains('flock -n 9') -and
        -not $lockScript.Value.Contains('/var/lock/qfieldcloud')
    ) "$($lockScript.Key) can follow or replace an attacker-controlled maintenance lock."
}
Assert-Contract (
    -not $bootstrapText.Contains('mkdir -p /var/log/qfieldcloud /var/lib/qfieldcloud') -and
    -not $bootstrapText.Contains('chmod 0700 /var/log/qfieldcloud /var/lib/qfieldcloud')
) 'Bootstrap mutates the persistent lock parent before validating that it is not a symlink.'
$backupMaintenanceMarkerIndex = $backupText.IndexOf(
    'write_recovery_required "backup-maintenance-in-progress"',
    [StringComparison]::Ordinal
)
$backupFirstStopIndex = $backupText.IndexOf(
    'compose stop nginx ofelia',
    [StringComparison]::Ordinal
)
$backupSuccessMarkerRemovalIndex = $backupText.IndexOf(
    'remove_owned_recovery_marker || {',
    $backupMaintenanceMarkerIndex,
    [StringComparison]::Ordinal
)
$backupQuiescedFalseIndex = $backupText.IndexOf(
    'services_quiesced="false"',
    $backupSuccessMarkerRemovalIndex,
    [StringComparison]::Ordinal
)
Assert-Contract (
    $backupMaintenanceMarkerIndex -ge 0 -and
    $backupFirstStopIndex -gt $backupMaintenanceMarkerIndex -and
    $backupText.Contains('The durable recovery-required marker could not be created; no service was stopped.') -and
    $backupSuccessMarkerRemovalIndex -gt $backupFirstStopIndex -and
    $backupQuiescedFalseIndex -gt $backupSuccessMarkerRemovalIndex
) 'Backup can stop services without a durable recovery marker or publish success before removing it.'
$restoreMaintenanceMarkerIndex = $restoreTestText.IndexOf(
    'write_recovery_required "restore-test-maintenance-in-progress"',
    [StringComparison]::Ordinal
)
$restoreFirstStopIndex = $restoreTestText.IndexOf(
    'operational_compose stop nginx ofelia',
    [StringComparison]::Ordinal
)
$restoreCleanupIndex = $restoreTestText.IndexOf('cleanup() {', [StringComparison]::Ordinal)
$restoreRecoveryHealthIndex = $restoreTestText.IndexOf(
    'if [[ $operational_recovered != "true" ]]',
    $restoreCleanupIndex,
    [StringComparison]::Ordinal
)
$restoreMarkerRemovalIndex = $restoreTestText.IndexOf(
    'remove_owned_recovery_marker || cleanup_failed=1',
    $restoreRecoveryHealthIndex,
    [StringComparison]::Ordinal
)
Assert-Contract (
    $restoreMaintenanceMarkerIndex -ge 0 -and
    $restoreFirstStopIndex -gt $restoreMaintenanceMarkerIndex -and
    $restoreTestText.Contains('The durable recovery-required marker could not be created; no operational service was stopped.') -and
    $restoreCleanupIndex -ge 0 -and
    $restoreRecoveryHealthIndex -gt $restoreCleanupIndex -and
    $restoreMarkerRemovalIndex -gt $restoreRecoveryHealthIndex
) 'Restore testing can stop services without a durable marker or clear it before recovery health passes.'
Assert-Contract (
    $workerSmokeText.Contains('readonly job_wait_timeout_seconds=1200') -and
    $workerSmokeText.Contains('readonly job_poll_request_cap_seconds=20') -and
    $workerSmokeText.Contains('--connect-timeout 5') -and
    $workerSmokeText.Contains('IFS='' '' read -r uptime_seconds _ </proc/uptime') -and
    $workerSmokeText.Contains('worker_smoke_deadline=$((worker_smoke_started_monotonic + job_wait_timeout_seconds))') -and
    $workerSmokeText.Contains('local deadline="$3"') -and
    $workerSmokeText.Contains('discovery_remaining=$((worker_smoke_deadline - discovery_now))') -and
    $workerSmokeText.Contains('if ((shared_deadline < deadline)); then') -and
    $workerSmokeText.Contains('deadline=$shared_deadline') -and
    $workerSmokeText.Contains('wait_for_job "$create_job_id" "create-project" "$worker_smoke_deadline"') -and
    $workerSmokeText.Contains('wait_for_job "$process_job_id" "process-projectfile" "$worker_smoke_deadline"') -and
    $workerSmokeText.Contains('wait_for_job "$package_job_id" "package" "$worker_smoke_deadline"') -and
    $workerSmokeText.Contains('request_timeout=$remaining') -and
    $workerSmokeText.Contains('api_get_fresh "$base_url/jobs/$job_id/" "$request_timeout"') -and
    $workerSmokeText.Contains('sleep_seconds=$remaining') -and
    $workerSmokeText.Contains('local timeout_seconds="$1"') -and
    $workerSmokeText.Contains('curl "${curl_common[@]}" --max-time "$timeout_seconds"') -and
    -not $workerSmokeText.Contains('deadline=$((now + job_wait_timeout_seconds))') -and
    -not $workerSmokeText.Contains('seq 1 120')
) 'The three worker jobs do not share one real 20-minute monotonic deadline.'
Assert-Contract (
    $workerSmokeText.Contains('docker container ls --all --no-trunc --quiet --filter "id=$container_id"') -and
    $workerSmokeText.Contains('Docker could not verify temporary QGIS worker container cleanup.') -and
    -not $workerSmokeText.Contains('if docker inspect "$container_id"')
) 'Docker errors can be mistaken for successful temporary worker-container removal.'
Assert-Contract (
    $workerSmokeText.Contains('((.the_qgis_file_name | type) == "string")') -and
    $workerSmokeText.Contains('((.the_qgis_file_name | length) > 0)') -and
    $workerSmokeText.Contains('((.files | type) == "array")') -and
    $workerSmokeText.Contains('((.files | length) > 0)')
) 'The worker smoke test can accept an empty QGIS filename or package.'
$processDiscoveryIndex = $workerSmokeText.IndexOf(
    'if ! process_job_id="$(wait_for_single_project_job_type',
    [StringComparison]::Ordinal
)
$createWaitIndex = $workerSmokeText.IndexOf(
    'wait_for_job "$create_job_id" "create-project"',
    [StringComparison]::Ordinal
)
$createContainerIndex = $workerSmokeText.IndexOf(
    'verify_removed_worker_container "$create_job_id"',
    [StringComparison]::Ordinal
)
$processWaitIndex = $workerSmokeText.IndexOf(
    'wait_for_job "$process_job_id" "process-projectfile"',
    [StringComparison]::Ordinal
)
$processContainerIndex = $workerSmokeText.IndexOf(
    'verify_removed_worker_container "$process_job_id"',
    [StringComparison]::Ordinal
)
$projectReadyIndex = $workerSmokeText.IndexOf(
    'project_json="$(api_get_fresh "$base_url/projects/$project_id/")"',
    [StringComparison]::Ordinal
)
$packagePostIndex = $workerSmokeText.IndexOf(
    'package_job_json="$(api_auth "$default_api_timeout_seconds"',
    [StringComparison]::Ordinal
)
$packageWaitIndex = $workerSmokeText.IndexOf(
    'wait_for_job "$package_job_id" "package"',
    [StringComparison]::Ordinal
)
$packageContainerIndex = $workerSmokeText.IndexOf(
    'verify_removed_worker_container "$package_job_id"',
    [StringComparison]::Ordinal
)
$latestPackageIndex = $workerSmokeText.IndexOf(
    'latest_package="$(api_get_fresh "$base_url/packages/$project_id/latest/")"',
    [StringComparison]::Ordinal
)
Assert-Contract (
    $workerSmokeText.Contains('readonly job_discovery_timeout_seconds=120') -and
    $workerSmokeText.Contains('deadline=$((now + job_discovery_timeout_seconds))') -and
    $workerSmokeText.Contains('.id == $source_job_id and') -and
    $workerSmokeText.Contains('.project_id == $project_id and') -and
    $workerSmokeText.Contains('.type == "create_project" and') -and
    $workerSmokeText.Contains('.created_by == $source_job.created_by and') -and
    $workerSmokeText.Contains('.created_at >= $source_job.created_at') -and
    $workerSmokeText.Contains('if ((matching_count > 1)); then') -and
    $createWaitIndex -ge 0 -and
    $createContainerIndex -gt $createWaitIndex -and
    $processDiscoveryIndex -gt $createContainerIndex -and
    $processWaitIndex -gt $processDiscoveryIndex -and
    $processContainerIndex -gt $processWaitIndex -and
    $projectReadyIndex -gt $processContainerIndex -and
    $packagePostIndex -gt $projectReadyIndex -and
    $packageWaitIndex -gt $packagePostIndex -and
    $packageContainerIndex -gt $packageWaitIndex -and
    $latestPackageIndex -gt $packageContainerIndex
) 'The seed-project smoke test can inspect readiness before its process-projectfile worker finishes.'
Assert-Contract (
    $workerSmokeText.Contains('jq -e --arg package_job_id "$package_job_id"') -and
    $workerSmokeText.Contains('((.package_id | type) == "string")') -and
    $workerSmokeText.Contains('.package_id == $package_job_id')
) 'The worker smoke test can accept a latest package produced by a different job.'
Assert-Contract (
    $backupText.Contains('install -o root -g root -m 0700 -d "$backup_root"') -and
    $backupText.Contains('stat -c ''%u:%g:%a'' "$backup_root"') -and
    $backupText.Contains('has_root_controlled_ancestors "$install_root"') -and
    $backupText.Contains('has_root_controlled_ancestors "$backup_root"') -and
    $backupText.Contains('^0:0:[1357][0145][0145]$') -and
    $backupText.Contains('stat -c ''%u:%g:%a'' "$trusted_directory"') -and
    $backupText.Contains('stat -c ''%u:%g:%a'' "$required_file"') -and
    $backupText.Contains('stat -c ''%u:%g:%a'' "$health_check_file"') -and
    $restoreTestText.Contains('stat -c ''%u:%g:%a'' "$runtime_temp_root"') -and
    $restoreTestText.Contains('stat -c ''%u:%g:%a'' "$backup_file"') -and
    $restoreTestText.Contains('stat -c ''%u:%g:%a'' "$checksums_file"') -and
    $restoreTestText.Contains('has_root_controlled_ancestors "$install_root"') -and
    $restoreTestText.Contains('has_root_controlled_ancestors "$backup_root"') -and
    $restoreTestText.Contains('^0:0:[1357][0145][0145]$') -and
    $restoreTestText.Contains('stat -c ''%u:%g:%a'' "$operational_file"') -and
    $restoreTestText.Contains('stat -c ''%u:%g:%a'' "$operational_health_check_file"')
) 'Backup or isolated-restore paths can bypass their root ownership and mode contract.'
Assert-Contract (
    $restoreTestText.Contains('temporary_database="qfc_restore_test_$(openssl rand -hex 6)"') -and
    $restoreTestText.Contains('^qfc_restore_test_[0-9a-f]{12}$') -and
    $restoreTestText.Contains('createdb --template template0 --username "$operational_db_user"') -and
    $restoreTestText.Contains('dropdb --if-exists --force --username "$operational_db_user"') -and
    $restoreTestText.Contains('A previous restore test left a namespaced temporary database behind; inspect it before retrying.') -and
    $restoreTestText.Contains('SELECT count(*) FROM pg_database WHERE datname = :''restore_database'';') -and
    $restoreTestText.Contains('[[ $database_count == "0" ]]') -and
    $restoreTestText.Contains('docker network connect --alias db "$network_name" "$operational_db_container"') -and
    $restoreTestText.Contains('disconnect_operational_database_network || cleanup_failed=1') -and
    $restoreTestText.Contains('read_env_value "$operational_versions_file" POSTGIS_IMAGE') -and
    $restoreTestText.Contains('[[ $operational_postgis_image == "$postgis_image" ]]') -and
    $restoreTestText.Contains('operational_compose stop rustfs smtp4dev memcached') -and
    -not $restoreTestText.Contains('operational_compose stop db') -and
    -not $restoreTestText.Contains('qfc_restoretest_db_') -and
    -not $restoreTestText.Contains('qfc-restoretest-db-')
) 'The 4 GiB restore test can target an unsafe database name, leak its temporary database, or start a second PostGIS instance.'

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
    'Get-GitExecutable'
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
$resolvedGitExecutable = Get-GitExecutable
Assert-Contract (
    $resolvedGitExecutable -is [string] -and
        -not [string]::IsNullOrWhiteSpace($resolvedGitExecutable) -and
        (Test-Path -LiteralPath $resolvedGitExecutable -PathType Leaf)
) 'The deployer did not reduce duplicate Git PATH matches to one executable path.'
$gitVersionOutput = & $resolvedGitExecutable --version 2>$null
Assert-Contract (
    $LASTEXITCODE -eq 0 -and ($gitVersionOutput -join ' ') -match '^git version '
) 'The executable selected from duplicate Git PATH matches is not runnable Git.'
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
