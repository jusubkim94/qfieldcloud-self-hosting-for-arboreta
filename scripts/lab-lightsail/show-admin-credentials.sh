#!/usr/bin/env bash

set -Eeuo pipefail
set +x
umask 077

if [[ $EUID -ne 0 ]]; then
  echo "Run this command with sudo inside the Lightsail browser SSH session." >&2
  exit 1
fi

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "Refusing to print administrator credentials to a pipe or redirected file." >&2
  exit 1
fi

install_root="${QFC_INSTALL_ROOT:-/opt/qfieldcloud}"
secrets_file="$install_root/state/secrets.env"
public_host_file="$install_root/state/public-host"
certificate_mode_file="$install_root/state/certificate-mode"
certificate_file="$install_root/state/certs/current/fullchain.pem"
certificate_fingerprint_file="$install_root/state/certificate-sha256"

if [[ ! -f $secrets_file || ! -f $public_host_file || \
  ! -f $certificate_mode_file || ! -f $certificate_file || \
  ! -f $certificate_fingerprint_file ]]; then
  echo "QFieldCloud bootstrap is incomplete." >&2
  exit 1
fi

expected_certificate_sha256="$(<"$certificate_fingerprint_file")"
public_host="$(<"$public_host_file")"
certificate_mode="$(<"$certificate_mode_file")"
actual_certificate_sha256="$(openssl x509 -in "$certificate_file" -outform DER \
  | sha256sum | awk '{print $1}')"
identity_valid="false"
if [[ $certificate_mode == "letsencrypt-ip" ]]; then
  if openssl x509 -in "$certificate_file" -checkip "$public_host" -noout >/dev/null 2>&1 && \
    openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
      -untrusted "$install_root/state/certbot/live/qfieldcloud-ip/chain.pem" \
      "$install_root/state/certbot/live/qfieldcloud-ip/cert.pem" >/dev/null 2>&1; then
    identity_valid="true"
  fi
elif [[ $certificate_mode == "self-signed" ]] && \
  openssl x509 -in "$certificate_file" -checkhost "$public_host" -noout >/dev/null 2>&1; then
  identity_valid="true"
fi
if [[ ! $expected_certificate_sha256 =~ ^[0-9a-f]{64}$ ]] || \
  [[ $actual_certificate_sha256 != "$expected_certificate_sha256" ]] || \
  [[ $identity_valid != "true" ]] || \
  ! openssl x509 -in "$certificate_file" -checkend 0 -noout >/dev/null 2>&1; then
  echo "The stored pilot certificate fingerprint is invalid or stale." >&2
  exit 1
fi
certificate_not_after="$(openssl x509 -in "$certificate_file" -noout -enddate | sed 's/^notAfter=//')"

# This command is deliberately interactive and prints the generated pilot
# administrator credential only to the user's current terminal. Never redirect
# its output to a log, issue, chat, or repository file.
# shellcheck disable=SC1090
source "$secrets_file"

printf 'URL: https://%s/admin/\n' "$public_host"
printf 'Certificate mode: %s\n' "$certificate_mode"
printf 'Certificate SHA-256: %s\n' "$expected_certificate_sha256"
printf 'Certificate expires: %s\n' "$certificate_not_after"
if [[ $certificate_mode == "self-signed" ]]; then
  printf 'Verify this fingerprint in the browser certificate details before entering the password.\n'
else
  printf 'The public CA chain and exact IPv4 identity were verified locally.\n'
fi
printf 'Username: %s\n' "$ADMIN_USERNAME"
printf 'Password: %s\n' "$ADMIN_PASSWORD"
printf '\nDo not paste this output into chat, logs, issues, or GitHub.\n'
