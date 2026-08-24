#!/usr/bin/env bash

set -Eeuo pipefail
set +x
umask 077

mode="renew"
if (($# > 1)); then
  echo "Usage: certificate-renew.sh [--initial]" >&2
  exit 2
fi
if (($# == 1)); then
  if [[ $1 != "--initial" ]]; then
    echo "Usage: certificate-renew.sh [--initial]" >&2
    exit 2
  fi
  mode="initial"
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run this command with sudo on the Lightsail instance." >&2
  exit 1
fi

install_root="${QFC_INSTALL_ROOT:-/opt/qfieldcloud}"
if [[ ! $install_root =~ ^/([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+$ ]] || \
  [[ $install_root == "/" ]] || [[ $install_root == *"//"* ]] || \
  [[ $install_root == *"/./"* ]] || [[ $install_root == */. ]] || \
  [[ $install_root == *"/../"* ]] || [[ $install_root == */.. ]]; then
  echo "The install root must be a safe absolute path other than /." >&2
  exit 1
fi

for required_command in awk chmod cmp curl date docker flock install ln mktemp mv openssl \
  readlink realpath rm sha256sum stat timeout; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required certificate command is unavailable: $required_command" >&2
    exit 1
  fi
done

state_root="$install_root/state"
versions_file="$install_root/versions.env"
runtime_env="$state_root/runtime.env"
compose_file="$install_root/compose.yaml"
public_host_file="$state_root/public-host"
certificate_mode_file="$state_root/certificate-mode"
cert_root="$state_root/certs"
release_root="$cert_root/releases"
current_link="$cert_root/current"
certbot_root="$state_root/certbot"
certbot_work_root="$state_root/certbot-work"
certbot_log_root="$state_root/certbot-log"
certbot_live_root="$certbot_root/live/qfieldcloud-ip"
failure_marker="$state_root/last-certificate-renewal-failure"
command_log="$certbot_log_root/last-command.log"
candidate_dir=""
operation_succeeded="false"

write_state_value() {
  local state_name="$1"
  local state_value="$2"
  local state_tmp=""

  case "$state_name" in
    certificate-sha256 | certificate-not-after | certificate-last-check-at | \
      certificate-last-renewal-at | last-certificate-renewal-failure) ;;
    *) return 1 ;;
  esac
  state_tmp="$(mktemp "$state_root/.$state_name.XXXXXX")"
  if ! printf '%s\n' "$state_value" >"$state_tmp" \
    || ! chmod 0600 "$state_tmp" \
    || ! mv -f -- "$state_tmp" "$state_root/$state_name"; then
    rm -f -- "$state_tmp"
    return 1
  fi
}

on_exit() {
  local exit_code=$?
  trap - EXIT
  set +e
  if [[ -n $candidate_dir && $candidate_dir == "$release_root/.candidate."* ]]; then
    rm -rf -- "$candidate_dir"
  fi
  if [[ $operation_succeeded != "true" ]]; then
    write_state_value last-certificate-renewal-failure \
      "$(date -u +%FT%TZ) certificate-renewal-or-validation-failed" >/dev/null 2>&1 || true
    if [[ $exit_code -eq 0 ]]; then
      exit_code=1
    fi
  fi
  exit "$exit_code"
}
trap on_exit EXIT

skip_locked_operation() {
  local reason="$1"

  # Bootstrap, the worker smoke test, or another certificate check can
  # legitimately hold these locks. Preserve the last verified certificate
  # state and let the next six-hour timer attempt retry. Health still fails if
  # no real certificate check succeeds within its bounded freshness window.
  operation_succeeded="true"
  echo "$reason The current certificate was left unchanged; a later timer run will retry."
  exit 0
}

is_canonical_ipv4() {
  local value="$1"
  local octet=""
  local -a octets=()

  [[ $value =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$value"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    [[ $octet == "0" || $octet != 0* ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

has_root_controlled_ancestors() {
  local current_path="${1%/*}"
  local path_metadata=""

  [[ -n $current_path ]] || current_path="/"
  while :; do
    if [[ ! -d $current_path || -L $current_path ]] || \
      [[ $(realpath -e "$current_path") != "$current_path" ]]; then
      return 1
    fi
    path_metadata="$(stat -c '%u:%g:%a' "$current_path")" || return 1
    [[ $path_metadata =~ ^0:0:[1357][0145][0145]$ ]] || return 1
    [[ $current_path == "/" ]] && return 0
    current_path="${current_path%/*}"
    [[ -n $current_path ]] || current_path="/"
  done
}

for trusted_directory in "$install_root" "$state_root" "$cert_root"; do
  if [[ ! -d $trusted_directory || -L $trusted_directory ]] || \
    [[ $(realpath -e "$trusted_directory") != "$trusted_directory" ]] || \
    [[ $(stat -c '%u:%g:%a' "$trusted_directory") != "0:0:700" ]]; then
    echo "A trusted QFieldCloud certificate directory is unavailable or unsafe." >&2
    exit 1
  fi
done
if ! has_root_controlled_ancestors "$install_root"; then
  echo "The QFieldCloud installation ancestors are not root-controlled." >&2
  exit 1
fi

for required_file in "$versions_file" "$runtime_env" "$compose_file" \
  "$public_host_file" "$certificate_mode_file"; do
  if [[ ! -f $required_file || -L $required_file ]] || \
    [[ $(stat -c '%u:%g:%a' "$required_file") != "0:0:600" ]]; then
    echo "Required certificate state is missing or unsafe: $required_file" >&2
    exit 1
  fi
done

# This file contains only reviewed, non-secret version constants.
# shellcheck disable=SC1090
source "$versions_file"
for version_name in CERTBOT_IMAGE CERTBOT_EXPECTED_VERSION \
  LETSENCRYPT_ACME_DIRECTORY LETSENCRYPT_CERTIFICATE_PROFILE; do
  if [[ -z ${!version_name:-} ]]; then
    echo "The pinned version manifest is missing $version_name." >&2
    exit 1
  fi
done
if [[ ! $CERTBOT_IMAGE =~ ^docker\.io/certbot/certbot@sha256:[0-9a-f]{64}$ ]] || \
  [[ ! $CERTBOT_EXPECTED_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  [[ $LETSENCRYPT_ACME_DIRECTORY != "https://acme-v02.api.letsencrypt.org/directory" ]] || \
  [[ $LETSENCRYPT_CERTIFICATE_PROFILE != "shortlived" ]]; then
  echo "The pinned Certbot or Let’s Encrypt contract is invalid." >&2
  exit 1
fi

certificate_mode="$(<"$certificate_mode_file")"
public_host="$(<"$public_host_file")"
if [[ $certificate_mode != "letsencrypt-ip" ]] || ! is_canonical_ipv4 "$public_host"; then
  echo "Public certificate renewal requires letsencrypt-ip mode and a canonical IPv4 host." >&2
  exit 1
fi

for protected_directory in "$release_root" "$certbot_root" "$certbot_work_root" \
  "$certbot_log_root"; do
  if [[ -e $protected_directory || -L $protected_directory ]]; then
    if [[ ! -d $protected_directory || -L $protected_directory ]] || \
      [[ $(realpath -e "$protected_directory") != "$protected_directory" ]]; then
      echo "A protected certificate state path is unsafe." >&2
      exit 1
    fi
  else
    install -o root -g root -m 0700 -d -- "$protected_directory"
  fi
  chmod 0700 "$protected_directory"
  if [[ $(stat -c '%u:%g:%a' "$protected_directory") != "0:0:700" ]]; then
    echo "A protected certificate state path has unsafe permissions." >&2
    exit 1
  fi
done

compose_command=(
  docker compose
  --env-file "$versions_file"
  --env-file "$runtime_env"
  --file "$compose_file"
)

readonly qfc_lock_parent="/var/lib/qfieldcloud"
readonly qfc_lock_root="$qfc_lock_parent/locks"
prepare_lock_directory() {
  local lock_path=""
  local path_metadata=""
  local trusted_ancestor=""

  for trusted_ancestor in / /var /var/lib; do
    [[ -d $trusted_ancestor && ! -L $trusted_ancestor ]] || return 1
    [[ $(realpath -e "$trusted_ancestor") == "$trusted_ancestor" ]] || return 1
    path_metadata="$(stat -c '%u:%g:%a' "$trusted_ancestor")" || return 1
    [[ $path_metadata =~ ^0:0:[1357][0145][0145]$ ]] || return 1
  done

  for lock_path in "$qfc_lock_parent" "$qfc_lock_root"; do
    if [[ -e $lock_path || -L $lock_path ]]; then
      [[ -d $lock_path && ! -L $lock_path ]] || return 1
    else
      install -o root -g root -m 0700 -d -- "$lock_path" || return 1
    fi
    [[ $(realpath -e "$lock_path") == "$lock_path" ]] || return 1
    [[ $(stat -c '%u:%g:%a' "$lock_path") == "0:0:700" ]] || return 1
  done
}
prepare_lock_file() {
  local lock_file="$1"
  local lock_tmp=""

  [[ $lock_file == "$qfc_lock_root/"* ]] || return 1
  if [[ -e $lock_file || -L $lock_file ]]; then
    [[ -f $lock_file && ! -L $lock_file ]] || return 1
  else
    lock_tmp="$(mktemp "$qfc_lock_root/.lock.XXXXXX")" || return 1
    if ! chmod 0600 "$lock_tmp" \
      || [[ $(stat -c '%u:%g:%a' "$lock_tmp") != "0:0:600" ]]; then
      rm -f -- "$lock_tmp"
      return 1
    fi
    if ! ln -T -- "$lock_tmp" "$lock_file" 2>/dev/null \
      && [[ ! -e $lock_file && ! -L $lock_file ]]; then
      rm -f -- "$lock_tmp"
      return 1
    fi
    rm -f -- "$lock_tmp" || return 1
  fi
  [[ -f $lock_file && ! -L $lock_file ]] || return 1
  [[ $(realpath -e "$lock_file") == "$lock_file" ]] || return 1
  [[ $(stat -c '%u:%g:%a' "$lock_file") == "0:0:600" ]] || return 1
}
lock_fd_matches_file() {
  local lock_fd="$1"
  local lock_file="$2"
  local fd_identity=""
  local file_identity=""

  [[ $lock_fd =~ ^[0-9]+$ && -e /proc/$$/fd/$lock_fd ]] || return 1
  fd_identity="$(stat -Lc '%d:%i' "/proc/$$/fd/$lock_fd")" || return 1
  file_identity="$(stat -c '%d:%i' "$lock_file")" || return 1
  [[ $fd_identity == "$file_identity" ]]
}

prepare_lock_directory || {
  echo "The root-owned QFieldCloud lock directory is missing or unsafe." >&2
  exit 1
}
maintenance_lock_file="$qfc_lock_root/maintenance.lock"
certificate_lock_file="$qfc_lock_root/certificate.lock"
prepare_lock_file "$maintenance_lock_file" || {
  echo "The QFieldCloud maintenance lock file is missing or unsafe." >&2
  exit 1
}
prepare_lock_file "$certificate_lock_file" || {
  echo "The QFieldCloud certificate lock file is missing or unsafe." >&2
  exit 1
}
inherited_lock="false"
if [[ ${QFC_MAINTENANCE_LOCK_FD:-} == "8" ]] && [[ -e /proc/$$/fd/8 ]] && \
  lock_fd_matches_file 8 "$maintenance_lock_file"; then
  inherited_lock="true"
fi
if [[ $inherited_lock != "true" ]]; then
  exec 8>>"$maintenance_lock_file"
  lock_fd_matches_file 8 "$maintenance_lock_file" || {
    echo "The QFieldCloud maintenance lock descriptor changed unexpectedly." >&2
    exit 1
  }
fi
if ! flock -n 8; then
  skip_locked_operation "Another QFieldCloud maintenance operation is already running."
fi
export QFC_MAINTENANCE_LOCK_FD=8

exec 9>>"$certificate_lock_file"
if ! lock_fd_matches_file 9 "$certificate_lock_file"; then
  echo "The QFieldCloud certificate lock descriptor changed unexpectedly." >&2
  exit 1
fi
if ! flock -n 9; then
  skip_locked_operation "Another QFieldCloud certificate operation is already running."
fi

timeout --signal=TERM --kill-after=5s 30s docker info >/dev/null 2>&1 || {
  echo "Docker is not running; the existing certificate was left unchanged." >&2
  exit 1
}
timeout --signal=TERM --kill-after=5s 60s "${compose_command[@]}" config --quiet || {
  echo "The pinned Compose configuration is invalid; the existing certificate was left unchanged." >&2
  exit 1
}
docker image inspect "$CERTBOT_IMAGE" >/dev/null 2>&1 || \
  timeout --signal=TERM --kill-after=15s 600s docker pull "$CERTBOT_IMAGE" >/dev/null
certbot_version_output="$(
  timeout --signal=TERM --kill-after=15s 120s \
    docker run --rm --network none --entrypoint certbot \
      "$CERTBOT_IMAGE" --version 2>&1
)"
if [[ $certbot_version_output != "certbot $CERTBOT_EXPECTED_VERSION" ]]; then
  echo "The pinned Certbot image reported an unexpected version." >&2
  exit 1
fi

command_log_tmp="$(mktemp "$certbot_log_root/.last-command.XXXXXX")"
chmod 0600 "$command_log_tmp"
certbot_exit=0
if [[ $mode == "initial" ]] && \
  { [[ ! -s $certbot_live_root/cert.pem ]] || \
    ! openssl x509 -in "$certbot_live_root/cert.pem" -checkip "$public_host" -noout >/dev/null 2>&1; }; then
  timeout --signal=TERM --kill-after=60s 1200s \
    "${compose_command[@]}" run --rm --no-TTY certbot certonly \
      --non-interactive \
      --agree-tos \
      --register-unsafely-without-email \
      --server "$LETSENCRYPT_ACME_DIRECTORY" \
      --preferred-profile "$LETSENCRYPT_CERTIFICATE_PROFILE" \
      --webroot \
      --webroot-path /var/www/certbot \
      --ip-address "$public_host" \
      --cert-name qfieldcloud-ip \
      >"$command_log_tmp" 2>&1 || certbot_exit=$?
else
  timeout --signal=TERM --kill-after=60s 1200s \
    "${compose_command[@]}" run --rm --no-TTY certbot renew \
      --non-interactive \
      --cert-name qfieldcloud-ip \
      --no-random-sleep-on-renew \
      >"$command_log_tmp" 2>&1 || certbot_exit=$?
fi
mv -f -- "$command_log_tmp" "$command_log"
chmod -R go-rwx "$certbot_root" "$certbot_work_root" "$certbot_log_root"
if [[ $certbot_exit -ne 0 ]]; then
  echo "Certbot did not complete; the existing certificate was left unchanged. Review the root-only Certbot log." >&2
  exit "$certbot_exit"
fi

for source_name in cert.pem chain.pem fullchain.pem privkey.pem; do
  source_path="$certbot_live_root/$source_name"
  source_real="$(realpath -e "$source_path" 2>/dev/null || true)"
  if [[ ! -f $source_path ]] || [[ $source_real != "$certbot_root/archive/qfieldcloud-ip/"* ]]; then
    echo "Certbot did not produce a safe certificate lineage; the existing certificate was left unchanged." >&2
    exit 1
  fi
done
if ! openssl verify \
    -CAfile /etc/ssl/certs/ca-certificates.crt \
    -untrusted "$certbot_live_root/chain.pem" \
    "$certbot_live_root/cert.pem" >/dev/null 2>&1 \
  || ! openssl x509 -in "$certbot_live_root/cert.pem" \
    -checkip "$public_host" -noout >/dev/null 2>&1 \
  || ! openssl x509 -in "$certbot_live_root/cert.pem" \
    -checkend 172800 -noout >/dev/null 2>&1; then
  echo "The renewed certificate failed public trust, IP identity, or 48-hour validity checks." >&2
  exit 1
fi

certificate_public_key_sha256="$(
  openssl x509 -in "$certbot_live_root/cert.pem" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}'
)"
private_public_key_sha256="$(
  openssl pkey -in "$certbot_live_root/privkey.pem" -pubout -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}'
)"
if [[ ! $certificate_public_key_sha256 =~ ^[0-9a-f]{64}$ ]] || \
  [[ $certificate_public_key_sha256 != "$private_public_key_sha256" ]]; then
  echo "The renewed certificate and private key do not match." >&2
  exit 1
fi

candidate_fingerprint="$(
  openssl x509 -in "$certbot_live_root/cert.pem" -outform DER \
    | sha256sum | awk '{print $1}'
)"
if [[ ! $candidate_fingerprint =~ ^[0-9a-f]{64}$ ]]; then
  echo "The renewed certificate fingerprint is invalid." >&2
  exit 1
fi
candidate_not_after_raw="$(openssl x509 -in "$certbot_live_root/cert.pem" -noout -enddate)"
candidate_not_after_raw="${candidate_not_after_raw#notAfter=}"
candidate_not_after="$(date -u --date="$candidate_not_after_raw" +%FT%TZ 2>/dev/null || true)"
if [[ ! $candidate_not_after =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  echo "The renewed certificate expiry could not be normalized." >&2
  exit 1
fi

candidate_dir="$(mktemp -d "$release_root/.candidate.XXXXXX")"
chmod 0700 "$candidate_dir"
install -o root -g root -m 0600 "$certbot_live_root/fullchain.pem" "$candidate_dir/fullchain.pem"
install -o root -g root -m 0600 "$certbot_live_root/privkey.pem" "$candidate_dir/privkey.pem"
final_release="$release_root/$candidate_fingerprint"
if [[ -e $final_release || -L $final_release ]]; then
  if [[ ! -d $final_release || -L $final_release ]] || \
    ! cmp -s -- "$candidate_dir/fullchain.pem" "$final_release/fullchain.pem" || \
    ! cmp -s -- "$candidate_dir/privkey.pem" "$final_release/privkey.pem"; then
    echo "An existing certificate release conflicts with the renewed certificate." >&2
    exit 1
  fi
  rm -rf -- "$candidate_dir"
  candidate_dir=""
else
  mv -- "$candidate_dir" "$final_release"
  candidate_dir=""
fi

previous_target=""
if [[ -L $current_link ]]; then
  previous_target="$(readlink "$current_link")"
  if [[ ! $previous_target =~ ^releases/[A-Za-z0-9._-]+$ ]] || \
    [[ $(realpath -e "$current_link") != "$cert_root/releases/"* ]]; then
    echo "The current certificate selector is unsafe." >&2
    exit 1
  fi
elif [[ -e $current_link ]]; then
  echo "The current certificate selector is not a symbolic link." >&2
  exit 1
else
  echo "No rollback-capable current certificate selector exists." >&2
  exit 1
fi

new_target="releases/$candidate_fingerprint"
current_changed="false"
if [[ $previous_target != "$new_target" ]]; then
  next_link="$cert_root/.current.$$"
  ln -s -- "$new_target" "$next_link"
  mv -Tf -- "$next_link" "$current_link"
  current_changed="true"
fi

rollback_current() {
  local rollback_link="$cert_root/.rollback.$$"
  if [[ -n $previous_target ]]; then
    ln -s -- "$previous_target" "$rollback_link" || return 1
    mv -Tf -- "$rollback_link" "$current_link" || return 1
  else
    rm -f -- "$current_link" || return 1
  fi
  timeout --signal=TERM --kill-after=5s 60s \
    "${compose_command[@]}" exec -T nginx nginx -t >/dev/null 2>&1 || return 1
  timeout --signal=TERM --kill-after=5s 60s \
    "${compose_command[@]}" exec -T nginx nginx -s reload >/dev/null 2>&1 || return 1
}

fail_after_promotion() {
  local reason="$1"

  if [[ $current_changed == "true" ]]; then
    if rollback_current; then
      echo "$reason The previous certificate selector was restored." >&2
    else
      echo "$reason Automatic rollback also failed; inspect the instance before the current certificate expires." >&2
    fi
  else
    echo "$reason" >&2
  fi
  exit 1
}

if ! timeout --signal=TERM --kill-after=5s 60s \
  "${compose_command[@]}" exec -T nginx nginx -t >/dev/null 2>&1; then
  fail_after_promotion "Nginx rejected the renewed certificate."
fi
if [[ $current_changed == "true" ]] && \
  ! timeout --signal=TERM --kill-after=5s 60s \
    "${compose_command[@]}" exec -T nginx nginx -s reload >/dev/null 2>&1; then
  fail_after_promotion "Nginx could not reload the renewed certificate."
fi

live_certificate_output=""
if ! live_certificate_output="$(
  timeout --signal=TERM --kill-after=5s 20s \
    openssl s_client -connect 127.0.0.1:443 -servername "$public_host" </dev/null 2>/dev/null
)"; then
  fail_after_promotion "The live HTTPS certificate could not be retrieved."
fi
live_fingerprint=""
if ! live_fingerprint="$(
    openssl x509 -outform DER 2>/dev/null <<<"$live_certificate_output" \
      | sha256sum | awk '{print $1}'
  )" || [[ ! $live_fingerprint =~ ^[0-9a-f]{64}$ ]]; then
  fail_after_promotion "The live HTTPS certificate fingerprint could not be calculated."
fi
if [[ $live_fingerprint != "$candidate_fingerprint" ]] || \
  ! curl --fail --silent --show-error --connect-timeout 5 --max-time 20 \
    --connect-to "$public_host:443:127.0.0.1:443" \
    "https://$public_host/" >/dev/null 2>&1; then
  fail_after_promotion "The live HTTPS endpoint did not serve the trusted renewed certificate."
fi

now_utc="$(date -u +%FT%TZ)"
write_state_value certificate-sha256 "$candidate_fingerprint"
write_state_value certificate-not-after "$candidate_not_after"
write_state_value certificate-last-check-at "$now_utc"
if [[ $current_changed == "true" || $mode == "initial" ]]; then
  write_state_value certificate-last-renewal-at "$now_utc"
fi
rm -f -- "$failure_marker"
operation_succeeded="true"
echo "The public IPv4 certificate is trusted, current, and served by Nginx."
