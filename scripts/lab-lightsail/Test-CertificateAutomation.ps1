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

function Get-Text {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Assert-Contract (Test-Path -LiteralPath $Path -PathType Leaf) "Missing file: $Path"
    return Get-Content -Raw -LiteralPath $Path
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$manifestText = Get-Text (Join-Path $repositoryRoot 'config/qfieldcloud-v26.25.env')
$composeText = Get-Text (Join-Path $repositoryRoot 'runtime/lab-lightsail/compose.yaml')
$templateText = Get-Text (Join-Path $repositoryRoot 'infra/lab-lightsail/template.yaml')
$bootstrapText = Get-Text (Join-Path $PSScriptRoot 'bootstrap.sh')
$renewText = Get-Text (Join-Path $PSScriptRoot 'certificate-renew.sh')
$healthText = Get-Text (Join-Path $PSScriptRoot 'health-check.sh')
$workerSmokeText = Get-Text (Join-Path $PSScriptRoot 'worker-smoke-test.sh')
$deployText = Get-Text (Join-Path $PSScriptRoot 'Deploy-QFieldCloudPilot.ps1')
$installText = Get-Text (Join-Path $PSScriptRoot 'Install-QFieldCloudPilot.ps1')
$verifyText = Get-Text (Join-Path $PSScriptRoot 'Test-QFieldCloudPilot.ps1')

Assert-Contract (
    $manifestText.Contains('CERTBOT_IMAGE=docker.io/certbot/certbot@sha256:d07bd043d61d6bee1114235ac12c2e9a5c54b6931b3ccf5e1174d6c8c4afaa95') -and
    $manifestText.Contains('CERTBOT_EXPECTED_VERSION=5.7.0') -and
    $manifestText.Contains('LETSENCRYPT_ACME_DIRECTORY=https://acme-v02.api.letsencrypt.org/directory') -and
    $manifestText.Contains('LETSENCRYPT_CERTIFICATE_PROFILE=shortlived') -and
    -not $manifestText.Contains('CERTBOT_IMAGE=certbot/certbot:latest')
) 'Certbot, the production ACME directory, and the short-lived profile are not immutably pinned.'

$certbotService = [regex]::Match(
    $composeText,
    '(?ms)^  certbot:\r?\n(?<Body>.*?)(?=^  [a-zA-Z0-9_]+:|^networks:)'
)
Assert-Contract $certbotService.Success 'The maintenance-only Certbot Compose service is missing.'
Assert-Contract (
    $certbotService.Groups['Body'].Value.Contains('image: "${CERTBOT_IMAGE:?required}"') -and
    $certbotService.Groups['Body'].Value.Contains('./state/certbot:/etc/letsencrypt') -and
    $certbotService.Groups['Body'].Value.Contains('certbot_www:/var/www/certbot') -and
    -not $certbotService.Groups['Body'].Value.Contains('/var/run/docker.sock') -and
    -not [regex]::IsMatch($certbotService.Groups['Body'].Value, '(?m)^\s+ports:')
) 'The Certbot service is not isolated from public ports and the Docker socket.'
Assert-Contract (
    $composeText.Contains('QFIELDCLOUD_WORKER_QFIELDCLOUD_URL: "http://nginx/api/v1/"') -and
    $composeText.Contains('certbot_www:/var/www/certbot:ro') -and
    $composeText.Contains('QFIELDCLOUD_TLS_CERT: /etc/nginx/certs/current/fullchain.pem') -and
    $composeText.Contains('QFIELDCLOUD_TLS_KEY: /etc/nginx/certs/current/privkey.pem')
) 'Raw public IPv4 mode is not separated from Docker-internal routing or the atomic certificate selector.'

Assert-Contract (
    $bootstrapText.Contains('--certificate-mode)') -and
    $bootstrapText.Contains('$certificate_mode != "letsencrypt-ip"') -and
    $bootstrapText.Contains('public_host="$public_ipv4"') -and
    $bootstrapText.Contains('-addext "subjectAltName=$san_kind:$public_host"') -and
    $bootstrapText.Contains('"$install_root/bin/certificate-renew.sh" --initial') -and
    $bootstrapText.Contains('The public IPv4 certificate was not issued and validated; bootstrap will not report success.') -and
    $bootstrapText.Contains('OnCalendar=*-*-* 00,06,12,18:00:00') -and
    $bootstrapText.Contains('RandomizedDelaySec=45m') -and
    $bootstrapText.Contains('Persistent=true')
) 'Bootstrap does not fail closed around direct-IP issuance and the six-hour renewal timer.'
$nginxStartIndex = $bootstrapText.IndexOf('compose up -d app nginx', [StringComparison]::Ordinal)
$initialIssuanceIndex = $bootstrapText.IndexOf('"$install_root/bin/certificate-renew.sh" --initial', [StringComparison]::Ordinal)
$fingerprintPublishIndex = $bootstrapText.IndexOf('write_root_state_value certificate-sha256 "$certificate_sha256"', [StringComparison]::Ordinal)
Assert-Contract (
    $nginxStartIndex -ge 0 -and
    $initialIssuanceIndex -gt $nginxStartIndex -and
    $fingerprintPublishIndex -gt $initialIssuanceIndex
) 'HTTP-01 is attempted before Nginx is ready or the initial evidence is published before public issuance succeeds.'

Assert-Contract (
    $templateText.Contains('CertificateMode:') -and
    $templateText.Contains('LetsEncryptTermsAccepted:') -and
    $templateText.Contains('PublicCertificateTermsMustBeAccepted:') -and
    $templateText.Contains('RuleCondition: !Equals [!Ref CertificateMode, letsencrypt-ip]') -and
    $templateText.Contains("--certificate-mode '`${CertificateMode}'") -and
    $templateText.Contains('PublicCertificateEnabled: !Equals [!Ref CertificateMode, letsencrypt-ip]') -and
    $templateText.Contains("- 'https://`${IpAddress}/'")
) 'CloudFormation does not bind terms acceptance, bootstrap mode, and the raw-IPv4 output together.'

foreach ($scriptContract in @(
    [pscustomobject]@{ Name = 'Deploy'; Text = $deployText },
    [pscustomobject]@{ Name = 'Install'; Text = $installText }
)) {
    Assert-Contract (
        $scriptContract.Text.Contains("[ValidateSet('self-signed', 'letsencrypt-ip')]") -and
        $scriptContract.Text.Contains('[switch]$AcceptLetsEncryptTerms') -and
        $scriptContract.Text.Contains("`$Execute -and `$CertificateMode -eq 'letsencrypt-ip' -and -not `$AcceptLetsEncryptTerms")
    ) "$($scriptContract.Name) does not require explicit terms acceptance for an executing public-certificate plan."
}
Assert-Contract (
    $deployText.Contains('ApprovalSchemaVersion          = 2') -and
    $deployText.Contains('CertificateLifetimeHours') -and
    $deployText.Contains('CertificateRenewalCheck') -and
    $deployText.Contains('CertbotImage') -and
    $deployText.Contains('AcmeCertificateProfile') -and
    $deployText.Contains('ParameterKey=LetsEncryptTermsAccepted')
) 'The approval hash omits public certificate lifetime, dependency, pin, or terms inputs.'
Assert-Contract (
    $templateText.Contains("readonly bootstrap_timeout_seconds='6000'") -and
    $templateText.Contains("Timeout: '9000'") -and
    $deployText.Contains('$maxStackPollAttempts = 340')
) 'Certificate-aware bootstrap and its local stack observer do not have consistent bounded timeouts.'

Assert-Contract (
    $renewText.Contains('set -Eeuo pipefail') -and
    $renewText.Contains('set +x') -and
    $renewText.Contains('umask 077') -and
    $renewText.Contains('readonly qfc_lock_root="$qfc_lock_parent/locks"') -and
    $renewText.Contains('flock -n 8') -and
    $renewText.Contains('flock -n 9') -and
    $renewText.Contains('skip_locked_operation') -and
    $renewText.Contains('operation_succeeded="true"') -and
    $renewText.Contains('docker run --rm --network none --entrypoint certbot') -and
    $renewText.Contains('certbot_version_output != "certbot $CERTBOT_EXPECTED_VERSION"') -and
    $renewText.Contains('timeout --signal=TERM --kill-after=60s 1200s') -and
    $renewText.Contains('"${compose_command[@]}" run --rm --no-TTY certbot') -and
    -not [regex]::IsMatch($renewText, '(?s)timeout .*?\r?\n\s+compose run') -and
    -not $renewText.Contains('--force-renewal')
) 'Renewal is not bounded, mutually exclusive, quiet, or safe from production force-renew loops.'
Assert-Contract (
    $renewText.Contains('--preferred-profile "$LETSENCRYPT_CERTIFICATE_PROFILE"') -and
    $renewText.Contains('--webroot-path /var/www/certbot') -and
    $renewText.Contains('--ip-address "$public_host"') -and
    $renewText.Contains('--no-random-sleep-on-renew') -and
    $renewText.Contains('openssl verify') -and
    $renewText.Contains('-checkip "$public_host"') -and
    $renewText.Contains('-checkend 172800') -and
    $renewText.Contains('certificate_public_key_sha256') -and
    $renewText.Contains('private_public_key_sha256')
) 'The candidate certificate is not checked for CA trust, exact IP SAN, 48-hour safety, and key matching.'
Assert-Contract (
    $bootstrapText.Contains('bootstrap_https_route=(--connect-to "$public_host:443:127.0.0.1:443")') -and
    $renewText.Contains('--connect-to "$public_host:443:127.0.0.1:443"') -and
    $healthText.Contains('--connect-to "$public_host:443:127.0.0.1:443"') -and
    $workerSmokeText.Contains('certificate_mode == "letsencrypt-ip"') -and
    $workerSmokeText.Contains('--connect-to "$public_host:443:127.0.0.1:443"')
) 'Raw IPv4 local TLS checks can accidentally hairpin through the public address instead of testing local Nginx.'
$candidateValidationIndex = $renewText.IndexOf('if ! openssl verify', [StringComparison]::Ordinal)
$releaseMoveIndex = $renewText.IndexOf('mv -- "$candidate_dir" "$final_release"', [StringComparison]::Ordinal)
$selectorMoveIndex = $renewText.IndexOf('mv -Tf -- "$next_link" "$current_link"', [StringComparison]::Ordinal)
$nginxTestIndex = $renewText.IndexOf('exec -T nginx nginx -t', [StringComparison]::Ordinal)
$nginxReloadIndex = $renewText.IndexOf('exec -T nginx nginx -s reload', [StringComparison]::Ordinal)
$liveVerifyIndex = $renewText.IndexOf('live_fingerprint=', [StringComparison]::Ordinal)
$statePublishIndex = $renewText.LastIndexOf('write_state_value certificate-sha256', [StringComparison]::Ordinal)
Assert-Contract (
    $candidateValidationIndex -ge 0 -and
    $releaseMoveIndex -gt $candidateValidationIndex -and
    $selectorMoveIndex -gt $releaseMoveIndex -and
    $nginxTestIndex -gt $selectorMoveIndex -and
    $nginxReloadIndex -gt $nginxTestIndex -and
    $liveVerifyIndex -gt $nginxReloadIndex -and
    $statePublishIndex -gt $liveVerifyIndex -and
    $renewText.Contains('if ! live_fingerprint="$(') -and
    $renewText.Contains('fail_after_promotion "The live HTTPS certificate fingerprint could not be calculated."') -and
    $renewText.Contains('rollback_current')
) 'Certificate promotion is not validate-first, pair-atomic, reload-checked, live-checked, and rollback-capable.'
Assert-Contract (
    $renewText.Contains('install -o root -g root -m 0600') -and
    $renewText.Contains('chmod -R go-rwx "$certbot_root"') -and
    $renewText.Contains('last-certificate-renewal-failure') -and
    $renewText.Contains('certificate-last-check-at') -and
    $renewText.Contains('certificate-last-renewal-at') -and
    $renewText.Contains('rm -f -- "$failure_marker"')
) 'Root-only ACME state and success/failure markers are incomplete.'

Assert-Contract (
    $healthText.Contains('certificate_mode == "letsencrypt-ip"') -and
    $healthText.Contains('public-ca-ip-san-current') -and
    $healthText.Contains('scheduled-and-healthy') -and
    $healthText.Contains('systemctl is-enabled --quiet qfieldcloud-certificate-renew.timer') -and
    $healthText.Contains('systemctl is-active --quiet qfieldcloud-certificate-renew.timer') -and
    $healthText.Contains('-checkend 172800') -and
    $healthText.Contains('last-certificate-renewal-failure') -and
    $healthText.Contains('live_certificate_sha256') -and
    $healthText.Contains('https://checkip.amazonaws.com') -and
    $healthText.Contains('public_ipv4_matches')
) 'Health status does not fail on public trust, IP identity, live mismatch, expiry margin, timer, or unresolved renewal failure.'
$publicVerifierBranch = [regex]::Match(
    $verifyText,
    '(?s)if \(\$CertificateMode -eq ''letsencrypt-ip''\) \{(?<Body>.*?)\}\s*else \{'
)
Assert-Contract (
    $verifyText.Contains('[QfcCertificateValidator]::CreatePublicIp($HostName)') -and
    $verifyText.Contains('errors != SslPolicyErrors.None') -and
    $verifyText.Contains('public-ca-chain-valid') -and
    $verifyText.Contains('public-ip-san-matched') -and
    $publicVerifierBranch.Success -and
    -not $publicVerifierBranch.Groups['Body'].Value.Contains('CreatePinned')
) 'The external verifier can still accept a rotating public certificate by initial fingerprint alone.'

Write-Output 'Certificate automation static validation passed. AWS and the production ACME API were not called.'
