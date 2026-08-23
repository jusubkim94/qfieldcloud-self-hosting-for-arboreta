#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

health_mode="normal"
service_only="false"
installation_gate="false"
if (($# > 1)); then
  printf '{"overall":"error","reason":"invalid-arguments"}\n'
  exit 2
fi
if (($# == 1)); then
  case "$1" in
    --service-only)
      health_mode="service-only"
      service_only="true"
      ;;
    --installation-gate)
      health_mode="installation-gate"
      installation_gate="true"
      ;;
    *)
      printf '{"overall":"error","reason":"invalid-arguments"}\n'
      exit 2
      ;;
  esac
fi

if [[ $EUID -ne 0 ]]; then
  printf '{"overall":"error","reason":"root-required"}\n'
  exit 1
fi

install_root="${QFC_INSTALL_ROOT:-/opt/qfieldcloud}"
versions_file="$install_root/versions.env"
runtime_env="$install_root/state/runtime.env"
compose_file="$install_root/compose.yaml"
public_host_file="$install_root/state/public-host"
certificate_mode_file="$install_root/state/certificate-mode"

for required_file in "$versions_file" "$runtime_env" "$compose_file" \
  "$public_host_file" "$certificate_mode_file"; do
  if [[ ! -f $required_file ]]; then
    printf '{"overall":"error","reason":"installation-incomplete"}\n'
    exit 1
  fi
done

# This file contains only non-secret version constants.
# shellcheck disable=SC1090
source "$versions_file"

public_host="$(<"$public_host_file")"
certificate_mode="$(<"$certificate_mode_file")"
if [[ ! $public_host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  printf '{"overall":"error","reason":"invalid-public-host"}\n'
  exit 1
fi
if [[ $certificate_mode != "self-signed" && $certificate_mode != "letsencrypt-ip" ]]; then
  printf '{"overall":"error","reason":"invalid-certificate-mode"}\n'
  exit 1
fi

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
if [[ $certificate_mode == "letsencrypt-ip" ]] && ! is_canonical_ipv4 "$public_host"; then
  printf '{"overall":"error","reason":"public-certificate-host-is-not-ipv4"}\n'
  exit 1
fi

compose() {
  docker compose \
    --env-file "$versions_file" \
    --env-file "$runtime_env" \
    --file "$compose_file" \
    "$@"
}

bootstrap_state="missing"
if [[ -f $install_root/state/bootstrap-status ]]; then
  bootstrap_state="$(<"$install_root/state/bootstrap-status")"
fi

docker_state="stopped"
if systemctl is-active --quiet docker; then
  docker_state="running"
fi

app_state="stopped"
nginx_state="stopped"
worker_state="stopped"
cron_state="stopped"
db_container_state="stopped"
storage_container_state="stopped"
db_container_health="missing"
storage_container_health="missing"
smtp_state="stopped"
cache_state="stopped"
if [[ $docker_state == "running" ]]; then
  running_services="$(compose ps --status running --services 2>/dev/null || true)"
  grep -qx db <<<"$running_services" && db_container_state="running"
  grep -qx rustfs <<<"$running_services" && storage_container_state="running"
  grep -qx smtp4dev <<<"$running_services" && smtp_state="running"
  grep -qx memcached <<<"$running_services" && cache_state="running"
  grep -qx app <<<"$running_services" && app_state="running"
  grep -qx nginx <<<"$running_services" && nginx_state="running"
  grep -qx worker_wrapper <<<"$running_services" && worker_state="running"
  grep -qx ofelia <<<"$running_services" && cron_state="running"

  db_container_id="$(compose ps -q db 2>/dev/null || true)"
  storage_container_id="$(compose ps -q rustfs 2>/dev/null || true)"
  if [[ $db_container_id =~ ^[0-9a-f]{12,64}$ ]]; then
    db_container_health="$(
      docker container inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
        "$db_container_id" 2>/dev/null || true
    )"
  fi
  if [[ $storage_container_id =~ ^[0-9a-f]{12,64}$ ]]; then
    storage_container_health="$(
      docker container inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
        "$storage_container_id" 2>/dev/null || true
    )"
  fi
fi

runtime_provenance_state="unverified"
installer_root="$install_root/installer"
installer_revision_file="$install_root/state/installer-revision"
if [[ -d $installer_root/.git ]] && [[ -f $installer_revision_file ]] && \
  [[ ! -L $installer_revision_file ]]; then
  approved_revision="$(<"$installer_revision_file")"
  approved_paths=(
    config/qfieldcloud-v26.25.env
    runtime/lab-lightsail/compose.yaml
    scripts/lab-lightsail/health-check.sh
    scripts/lab-lightsail/show-admin-credentials.sh
    scripts/lab-lightsail/backup.sh
    scripts/lab-lightsail/restore-test.sh
    scripts/lab-lightsail/worker-smoke-test.sh
    scripts/lab-lightsail/certificate-renew.sh
  )
  live_files_match="true"
  if [[ ! $approved_revision =~ ^[0-9a-f]{40}$ ]] || \
    [[ $(git -C "$installer_root" rev-parse HEAD 2>/dev/null || true) != "$approved_revision" ]] || \
    ! git -C "$installer_root" diff --quiet "$approved_revision" -- "${approved_paths[@]}"; then
    live_files_match="false"
  fi
  if [[ $live_files_match == "true" ]] && \
    ! cmp -s -- "$versions_file" "$installer_root/config/qfieldcloud-v26.25.env"; then
    live_files_match="false"
  fi
  if [[ $live_files_match == "true" ]] && \
    ! cmp -s -- "$compose_file" "$installer_root/runtime/lab-lightsail/compose.yaml"; then
    live_files_match="false"
  fi
  if [[ $live_files_match == "true" ]]; then
    for helper_name in health-check.sh show-admin-credentials.sh backup.sh \
      restore-test.sh worker-smoke-test.sh certificate-renew.sh; do
      if ! cmp -s -- "$install_root/bin/$helper_name" \
        "$installer_root/scripts/lab-lightsail/$helper_name"; then
        live_files_match="false"
        break
      fi
    done
  fi
  if [[ $live_files_match == "true" ]]; then
    runtime_provenance_state="verified-pinned-installer-files"
  fi
fi

runtime_images_state="unverified"
if [[ $docker_state == "running" ]]; then
  runtime_images_state="verified-pinned-image-objects"
  image_services=(db rustfs smtp4dev memcached app nginx worker_wrapper ofelia)
  image_references=(
    "$POSTGIS_IMAGE" "$RUSTFS_IMAGE" "$SMTP4DEV_IMAGE" "$MEMCACHED_IMAGE"
    "$QFC_APP_IMAGE" "$QFC_NGINX_IMAGE" "$QFC_WORKER_WRAPPER_IMAGE" "$OFELIA_IMAGE"
  )
  for image_index in "${!image_services[@]}"; do
    image_service="${image_services[$image_index]}"
    expected_image_reference="${image_references[$image_index]}"
    image_container_id="$(compose ps -q "$image_service" 2>/dev/null || true)"
    expected_image_id="$(
      docker image inspect --format '{{.Id}}' "$expected_image_reference" 2>/dev/null || true
    )"
    running_image_id="$(
      docker container inspect --format '{{.Image}}' "$image_container_id" 2>/dev/null || true
    )"
    if [[ -z $image_container_id ]] || [[ ! $expected_image_id =~ ^sha256:[0-9a-f]{64}$ ]] || \
      [[ $running_image_id != "$expected_image_id" ]]; then
      runtime_images_state="mismatch"
      break
    fi
  done
  if [[ $runtime_images_state == "verified-pinned-image-objects" ]] && \
    { ! docker image inspect "$QFC_CREATEBUCKETS_IMAGE" >/dev/null 2>&1 || \
      ! docker image inspect "$QFC_QGIS3_IMAGE" >/dev/null 2>&1; }; then
    runtime_images_state="mismatch"
  fi
  if [[ $runtime_images_state == "verified-pinned-image-objects" ]] && \
    [[ $certificate_mode == "letsencrypt-ip" ]] && \
    ! docker image inspect "$CERTBOT_IMAGE" >/dev/null 2>&1; then
    runtime_images_state="mismatch"
  fi
fi

protected_state_permissions="invalid"
secrets_file="$install_root/state/secrets.env"
certificate_file="$install_root/state/certs/current/fullchain.pem"
certificate_key_file="$install_root/state/certs/current/privkey.pem"
if [[ $(stat -c '%u:%g:%a' "$install_root" 2>/dev/null || true) == "0:0:700" ]] && \
  [[ $(stat -c '%u:%g:%a' "$install_root/state" 2>/dev/null || true) == "0:0:700" ]] && \
  [[ $(stat -c '%u:%g:%a' "$install_root/state/certs" 2>/dev/null || true) == "0:0:700" ]] && \
  [[ $(stat -c '%u:%g:%a' "$install_root/state/certs/releases" 2>/dev/null || true) == "0:0:700" ]] && \
  [[ $(stat -c '%u:%g:%a' "$public_host_file" 2>/dev/null || true) == "0:0:600" ]] && \
  [[ $(stat -c '%u:%g:%a' "$certificate_mode_file" 2>/dev/null || true) == "0:0:600" ]] && \
  [[ $(stat -c '%u:%g:%a' "$runtime_env" 2>/dev/null || true) == "0:0:600" ]] && \
  [[ $(stat -c '%u:%g:%a' "$secrets_file" 2>/dev/null || true) == "0:0:600" ]] && \
  [[ $(stat -c '%u:%g:%a' "$certificate_file" 2>/dev/null || true) == "0:0:600" ]] && \
  [[ $(stat -c '%u:%g:%a' "$certificate_key_file" 2>/dev/null || true) == "0:0:600" ]]; then
  protected_state_permissions="root-only"
fi
if [[ $protected_state_permissions == "root-only" ]] && \
  [[ $certificate_mode == "letsencrypt-ip" ]]; then
  for certbot_state_dir in "$install_root/state/certbot" \
    "$install_root/state/certbot-work" "$install_root/state/certbot-log"; do
    if [[ ! -d $certbot_state_dir || -L $certbot_state_dir ]] || \
      [[ $(stat -c '%u:%g:%a' "$certbot_state_dir" 2>/dev/null || true) != "0:0:700" ]]; then
      protected_state_permissions="invalid"
      break
    fi
  done
  if [[ $protected_state_permissions == "root-only" ]]; then
    unsafe_certbot_file="$(
      find "$install_root/state/certbot" -type f -perm /077 -print -quit 2>/dev/null || true
    )"
    unsafe_certbot_directory="$(
      find "$install_root/state/certbot" -type d -perm /077 -print -quit 2>/dev/null || true
    )"
    if [[ -n $unsafe_certbot_file || -n $unsafe_certbot_directory ]]; then
      protected_state_permissions="invalid"
    fi
  fi
fi

qgis3_state="missing"
if docker image inspect "$QFC_QGIS3_IMAGE" >/dev/null 2>&1 && \
  [[ -f $install_root/state/qgis3-verified-version ]] && \
  [[ $(<"$install_root/state/qgis3-verified-version") == "$QFC_QGIS3_EXPECTED_VERSION" ]]; then
  qgis3_state="verified"
fi

proj_data_state="missing-or-invalid"
proj_release_file="$install_root/state/proj-data-release"
proj_volume_name="qfieldcloud_transformation_grids"
proj_volume_mount="$(
  docker volume inspect --format '{{ .Mountpoint }}' "$proj_volume_name" 2>/dev/null || true
)"
if [[ -f $proj_release_file && ! -L $proj_release_file ]] && \
  [[ $(<"$proj_release_file") == "$PROJ_DATA_RELEASE" ]] && \
  [[ $proj_volume_mount == /* && $proj_volume_mount != "/" ]] && \
  [[ -d $proj_volume_mount ]] && \
  [[ -f $proj_volume_mount/.qfc-proj-data.json && \
     ! -L $proj_volume_mount/.qfc-proj-data.json ]] && \
  [[ -f $proj_volume_mount/README.DATA && ! -L $proj_volume_mount/README.DATA ]] && \
  [[ -f $proj_volume_mount/copyright_and_licenses.csv && \
     ! -L $proj_volume_mount/copyright_and_licenses.csv ]]; then
  expected_grid_file_count="$(
    jq -er \
      --arg release "$PROJ_DATA_RELEASE" \
      --arg source_url "$PROJ_DATA_ARCHIVE_URL" \
      --arg sha256 "$PROJ_DATA_ARCHIVE_SHA256" \
      --argjson archive_size "$PROJ_DATA_ARCHIVE_SIZE_BYTES" \
      'select(.release == $release and .source_url == $source_url and
              .archive_sha256 == $sha256 and .archive_size_bytes == $archive_size) |
       .grid_file_count | select(type == "number" and . > 0 and floor == .)' \
      "$proj_volume_mount/.qfc-proj-data.json" 2>/dev/null || true
  )"
  actual_grid_file_count="$(
    find "$proj_volume_mount" -maxdepth 1 -type f -name '*.tif' -printf '.\n' \
      2>/dev/null | wc -l | tr -d '[:space:]' || true
  )"
  if [[ $expected_grid_file_count =~ ^[0-9]+$ ]] && \
    [[ $actual_grid_file_count == "$expected_grid_file_count" ]]; then
    proj_data_state="installed-and-verified"
  fi
fi

certificate_state="invalid-or-expired"
certificate_renewal_state="invalid"
certificate_not_after="unknown"
last_certificate_check_at="not-run"
last_certificate_renewal_at="not-run"
certificate_fingerprint_file="$install_root/state/certificate-sha256"
expected_certificate_sha256=""
actual_certificate_sha256=""
current_certificate_target=""
current_certificate_real=""
if [[ -f $certificate_fingerprint_file && ! -L $certificate_fingerprint_file ]]; then
  expected_certificate_sha256="$(<"$certificate_fingerprint_file")"
fi
if [[ -L $install_root/state/certs/current ]]; then
  current_certificate_target="$(readlink "$install_root/state/certs/current")"
  current_certificate_real="$(realpath -e "$install_root/state/certs/current" 2>/dev/null || true)"
fi
if [[ $current_certificate_target =~ ^releases/[A-Za-z0-9._-]+$ ]] && \
  [[ $current_certificate_real == "$install_root/state/certs/releases/"* ]] && \
  [[ -f $certificate_file && ! -L $certificate_file ]] && \
  [[ -f $certificate_key_file && ! -L $certificate_key_file ]]; then
  actual_certificate_sha256="$(
    openssl x509 -in "$certificate_file" -outform DER 2>/dev/null \
      | sha256sum 2>/dev/null || true
  )"
  actual_certificate_sha256="${actual_certificate_sha256%% *}"
fi
if [[ $certificate_mode == "self-signed" ]]; then
  certificate_renewal_state="not-applicable-self-signed"
  if [[ $expected_certificate_sha256 =~ ^[0-9a-f]{64}$ ]] && \
    [[ $actual_certificate_sha256 == "$expected_certificate_sha256" ]] && \
    openssl x509 -in "$certificate_file" -checkend 0 -noout >/dev/null 2>&1 && \
    openssl x509 -in "$certificate_file" -checkhost "$public_host" -noout >/dev/null 2>&1; then
    certificate_state="current-hostname-and-fingerprint-matched"
  fi
else
  certificate_not_after_file="$install_root/state/certificate-not-after"
  certificate_last_check_file="$install_root/state/certificate-last-check-at"
  certificate_last_renewal_file="$install_root/state/certificate-last-renewal-at"
  certificate_failure_file="$install_root/state/last-certificate-renewal-failure"
  certbot_live_root="$install_root/state/certbot/live/qfieldcloud-ip"
  current_public_ipv4=""
  public_ipv4_matches="false"
  certbot_certificate_sha256=""
  live_certificate_sha256=""
  key_matches="false"
  certificate_public_key_sha256="$(
    openssl x509 -in "$certificate_file" -pubkey -noout 2>/dev/null \
      | openssl pkey -pubin -outform DER 2>/dev/null \
      | sha256sum 2>/dev/null || true
  )"
  certificate_public_key_sha256="${certificate_public_key_sha256%% *}"
  private_public_key_sha256="$(
    openssl pkey -in "$certificate_key_file" -pubout -outform DER 2>/dev/null \
      | sha256sum 2>/dev/null || true
  )"
  private_public_key_sha256="${private_public_key_sha256%% *}"
  if [[ $certificate_public_key_sha256 =~ ^[0-9a-f]{64}$ ]] && \
    [[ $certificate_public_key_sha256 == "$private_public_key_sha256" ]]; then
    key_matches="true"
  fi
  if [[ -f $certbot_live_root/cert.pem && -f $certbot_live_root/chain.pem ]]; then
    certbot_certificate_sha256="$(
      openssl x509 -in "$certbot_live_root/cert.pem" -outform DER 2>/dev/null \
        | sha256sum 2>/dev/null || true
    )"
    certbot_certificate_sha256="${certbot_certificate_sha256%% *}"
  fi
  live_certificate_output="$(
    timeout --signal=TERM --kill-after=5s 20s \
      openssl s_client -connect 127.0.0.1:443 -servername "$public_host" </dev/null 2>/dev/null || true
  )"
  live_certificate_sha256="$(
    openssl x509 -outform DER 2>/dev/null <<<"$live_certificate_output" \
      | sha256sum 2>/dev/null || true
  )"
  live_certificate_sha256="${live_certificate_sha256%% *}"
  if [[ -f $certificate_not_after_file && ! -L $certificate_not_after_file ]]; then
    certificate_not_after="$(<"$certificate_not_after_file")"
  fi
  if [[ -f $certificate_last_check_file && ! -L $certificate_last_check_file ]]; then
    last_certificate_check_at="$(<"$certificate_last_check_file")"
  fi
  if [[ -f $certificate_last_renewal_file && ! -L $certificate_last_renewal_file ]]; then
    last_certificate_renewal_at="$(<"$certificate_last_renewal_file")"
  fi
  actual_certificate_not_after_raw="$(openssl x509 -in "$certificate_file" -noout -enddate 2>/dev/null || true)"
  actual_certificate_not_after_raw="${actual_certificate_not_after_raw#notAfter=}"
  actual_certificate_not_after="$(date -u --date="$actual_certificate_not_after_raw" +%FT%TZ 2>/dev/null || true)"
  certificate_check_epoch="$(date --date="$last_certificate_check_at" +%s 2>/dev/null || true)"
  certificate_renewal_epoch="$(date --date="$last_certificate_renewal_at" +%s 2>/dev/null || true)"
  now_epoch="$(date -u +%s)"
  certificate_check_recent="false"
  certificate_renewal_recent="false"
  if [[ $certificate_check_epoch =~ ^[0-9]+$ ]] && \
    ((now_epoch >= certificate_check_epoch)) && \
    ((now_epoch - certificate_check_epoch <= 86400)); then
    certificate_check_recent="true"
  fi
  if [[ $certificate_renewal_epoch =~ ^[0-9]+$ ]] && \
    ((now_epoch >= certificate_renewal_epoch)) && \
    ((now_epoch - certificate_renewal_epoch <= 604800)); then
    certificate_renewal_recent="true"
  fi
  if ! current_public_ipv4="$(
    curl --fail --silent --show-error --max-time 10 https://checkip.amazonaws.com \
      | tr -d '[:space:]'
  )"; then
    current_public_ipv4=""
  fi
  if is_canonical_ipv4 "$current_public_ipv4" && [[ $current_public_ipv4 == "$public_host" ]]; then
    public_ipv4_matches="true"
  fi
  if [[ $expected_certificate_sha256 =~ ^[0-9a-f]{64}$ ]] && \
    [[ $actual_certificate_sha256 == "$expected_certificate_sha256" ]] && \
    [[ $actual_certificate_sha256 == "$certbot_certificate_sha256" ]] && \
    [[ $actual_certificate_sha256 == "$live_certificate_sha256" ]] && \
    [[ $key_matches == "true" ]] && \
    [[ ! -e $certificate_failure_file && ! -L $certificate_failure_file ]] && \
    [[ $certificate_check_recent == "true" ]] && \
    [[ $certificate_renewal_recent == "true" ]] && \
    [[ $public_ipv4_matches == "true" ]] && \
    [[ $certificate_not_after == "$actual_certificate_not_after" ]] && \
    openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
      -untrusted "$certbot_live_root/chain.pem" \
      "$certbot_live_root/cert.pem" >/dev/null 2>&1 && \
    openssl x509 -in "$certificate_file" -checkip "$public_host" -noout >/dev/null 2>&1 && \
    openssl x509 -in "$certificate_file" -checkend 172800 -noout >/dev/null 2>&1; then
    certificate_state="public-ca-ip-san-current"
  fi
  if [[ $certificate_state == "public-ca-ip-san-current" ]] && \
    systemctl is-enabled --quiet qfieldcloud-certificate-renew.timer && \
    systemctl is-active --quiet qfieldcloud-certificate-renew.timer; then
    certificate_renewal_state="scheduled-and-healthy"
  fi
fi

database_state="unreachable"
storage_state="unreachable"
status_nonce="$(date -u +%s%N)-$$-${RANDOM}"
if [[ $certificate_mode == "self-signed" ]]; then
  status_json="$(curl --fail --silent --show-error --cacert "$certificate_file" --max-time 20 \
    --header 'Cache-Control: no-cache' --header 'Pragma: no-cache' \
    --resolve "$public_host:443:127.0.0.1" \
    "https://$public_host/api/v1/status/?health_nonce=$status_nonce" 2>/dev/null || true)"
else
  status_json="$(curl --fail --silent --show-error --max-time 20 \
    --header 'Cache-Control: no-cache' --header 'Pragma: no-cache' \
    --connect-to "$public_host:443:127.0.0.1:443" \
    "https://$public_host/api/v1/status/?health_nonce=$status_nonce" 2>/dev/null || true)"
fi
if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$status_json"; then
  database_state="$(jq -r '.database // "missing"' <<<"$status_json")"
  storage_state="$(jq -r '.storage // "missing"' <<<"$status_json")"
fi

recovery_validation="clear"
recovery_required_file="$install_root/state/recovery-required"
if [[ -e $recovery_required_file || -L $recovery_required_file ]]; then
  if [[ -f $recovery_required_file && ! -L $recovery_required_file ]]; then
    recovery_validation="required"
  else
    recovery_validation="invalid-marker"
  fi
fi

maintenance_failure_state="clear"
for maintenance_failure_file in \
  "$install_root/state/last-backup-failure" \
  "$install_root/state/last-restore-test-failure"; do
  if [[ -e $maintenance_failure_file || -L $maintenance_failure_file ]]; then
    if [[ -f $maintenance_failure_file && ! -L $maintenance_failure_file ]]; then
      maintenance_failure_state="present"
    else
      maintenance_failure_state="invalid-marker"
    fi
    break
  fi
done

restore_test_orphan_state="docker-unavailable"
if [[ $docker_state == "running" ]]; then
  orphan_containers=""
  orphan_volumes=""
  orphan_networks=""
  if ! orphan_containers="$(
    docker container ls --all \
      --filter 'label=com.qfieldcloud.restore-test' \
      --format '{{.Names}}'
  )" \
    || ! orphan_volumes="$(
      docker volume ls \
        --filter 'label=com.qfieldcloud.restore-test' \
        --format '{{.Name}}'
    )" \
    || ! orphan_networks="$(
      docker network ls \
        --filter 'label=com.qfieldcloud.restore-test' \
        --format '{{.Name}}'
    )"; then
    restore_test_orphan_state="enumeration-error"
  elif [[ -n $orphan_containers || -n $orphan_volumes || -n $orphan_networks ]]; then
    restore_test_orphan_state="present"
  else
    restore_test_orphan_state="clear"
  fi
fi

service_health="error"
bootstrap_state_allowed="false"
if [[ $service_only == "true" ]] && \
  [[ $bootstrap_state =~ ^(ready|services-ready|validating)$ ]]; then
  bootstrap_state_allowed="true"
elif [[ $installation_gate == "true" ]] && [[ $bootstrap_state == "validating" ]]; then
  bootstrap_state_allowed="true"
elif [[ $service_only == "false" && $installation_gate == "false" ]] && \
  [[ $bootstrap_state == "ready" ]]; then
  bootstrap_state_allowed="true"
fi
if [[ $bootstrap_state_allowed == "true" && $docker_state == "running" && \
      $db_container_state == "running" && $storage_container_state == "running" && \
      $db_container_health == "healthy" && $storage_container_health == "healthy" && \
      $smtp_state == "running" && $cache_state == "running" && \
      $app_state == "running" && $nginx_state == "running" && \
      $worker_state == "running" && $cron_state == "running" && \
      $runtime_provenance_state == "verified-pinned-installer-files" && \
      $runtime_images_state == "verified-pinned-image-objects" && \
      $protected_state_permissions == "root-only" && \
      $qgis3_state == "verified" && $proj_data_state == "installed-and-verified" && \
      $certificate_state =~ ^(current-hostname-and-fingerprint-matched|public-ca-ip-san-current)$ && \
      $certificate_renewal_state =~ ^(not-applicable-self-signed|scheduled-and-healthy)$ && \
      $database_state == "ok" && $storage_state == "ok" && \
      $restore_test_orphan_state == "clear" ]]; then
  service_health="ok"
fi

last_worker_smoke_at="not-run"
last_backup_at="not-run"
last_restore_test_at="not-run"
latest_backup_name="not-run"
restored_backup_name="not-run"
backup_validation="not-run"
backup_checksum_validation="not-run"
restore_validation="not-run"
restore_matches_latest="false"
restore_checksum_set_validation="not-run"
backup_checksum_set_sha256=""

last_backup_path_file="$install_root/state/last-backup-path"
last_backup_at_file="$install_root/state/last-backup-at"
if [[ -f $last_backup_path_file && ! -L $last_backup_path_file && \
      -f $last_backup_at_file && ! -L $last_backup_at_file ]]; then
  latest_backup_path="$(<"$last_backup_path_file")"
  last_backup_at="$(<"$last_backup_at_file")"
  latest_backup_name="${latest_backup_path##*/}"
  backup_validation="invalid"
  backup_artifacts_valid="true"
  backup_path_valid="false"
  if [[ $latest_backup_path =~ ^/[A-Za-z0-9._/-]+$ ]] && \
    [[ $latest_backup_path != *"//"* ]] && \
    [[ $latest_backup_path != *"/./"* ]] && \
    [[ $latest_backup_path != *"/../"* ]] && \
    [[ -d $latest_backup_path && ! -L $latest_backup_path ]] && \
    [[ -d $latest_backup_path/data && ! -L $latest_backup_path/data ]] && \
    [[ -d $latest_backup_path/sensitive && ! -L $latest_backup_path/sensitive ]]; then
    backup_path_valid="true"
  fi
  for backup_artifact in \
    data/database.dump data/object-storage.tar.gz data/media.tar.gz \
    sensitive/secrets.env versions.env compose.yaml public-host manifest.json SHA256SUMS; do
    if [[ $backup_path_valid != "true" ]] || \
      [[ ! -s $latest_backup_path/$backup_artifact ]] || \
      [[ -L $latest_backup_path/$backup_artifact ]]; then
      backup_artifacts_valid="false"
      break
    fi
  done
  if [[ $backup_path_valid == "true" ]] && \
    [[ $latest_backup_name =~ ^[0-9]{8}T[0-9]{6}Z-v[0-9]+(\.[0-9]+)+$ ]] && \
    [[ $last_backup_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && \
    [[ $backup_artifacts_valid == "true" ]] && \
    [[ -f $latest_backup_path/manifest.json && ! -L $latest_backup_path/manifest.json ]] && \
    jq -e \
      --arg release "$QFIELDCLOUD_RELEASE" \
      --arg commit "$QFIELDCLOUD_COMMIT" \
      '.scope == "qfieldcloud-system-only" and .release == $release and
       .upstream_commit == $commit and .off_instance_copy_created == false' \
      "$latest_backup_path/manifest.json" >/dev/null 2>&1; then
    backup_epoch="$(date --date="$last_backup_at" +%s 2>/dev/null || true)"
    now_epoch="$(date -u +%s)"
    if [[ $backup_epoch =~ ^[0-9]+$ ]] && ((now_epoch >= backup_epoch)) && \
      ((now_epoch - backup_epoch <= 604800)); then
      backup_validation="passed-local-only"
    else
      backup_validation="stale"
    fi
  fi

  if [[ $service_only == "true" ]]; then
    backup_checksum_validation="not-checked-service-only"
  elif [[ $backup_validation == "passed-local-only" ]]; then
    backup_checksum_validation="invalid"
    checksums_file="$latest_backup_path/SHA256SUMS"
    required_checksum_paths=(
      data/database.dump
      data/object-storage.tar.gz
      data/media.tar.gz
      sensitive/secrets.env
      versions.env
      compose.yaml
      public-host
      manifest.json
    )
    checksum_manifest_valid="true"
    checksum_line_count=0
    declare -A checksum_paths_seen=()
    while IFS= read -r checksum_line || [[ -n $checksum_line ]]; do
      ((checksum_line_count += 1))
      if [[ ! $checksum_line =~ ^([0-9a-f]{64})\ \ (.+)$ ]]; then
        checksum_manifest_valid="false"
        continue
      fi
      checksum_relative_path="${BASH_REMATCH[2]}"
      checksum_path_expected="false"
      for required_checksum_path in "${required_checksum_paths[@]}"; do
        if [[ $checksum_relative_path == "$required_checksum_path" ]]; then
          checksum_path_expected="true"
          break
        fi
      done
      if [[ $checksum_path_expected != "true" ]] || \
        [[ -n ${checksum_paths_seen[$checksum_relative_path]+present} ]]; then
        checksum_manifest_valid="false"
        continue
      fi
      checksum_paths_seen["$checksum_relative_path"]="true"
    done <"$checksums_file"

    if ((checksum_line_count != ${#required_checksum_paths[@]})); then
      checksum_manifest_valid="false"
    fi
    for required_checksum_path in "${required_checksum_paths[@]}"; do
      if [[ -z ${checksum_paths_seen[$required_checksum_path]+present} ]]; then
        checksum_manifest_valid="false"
        break
      fi
    done

    checksum_set_before="$(sha256sum -- "$checksums_file" 2>/dev/null || true)"
    checksum_set_before="${checksum_set_before%% *}"
    if [[ $checksum_manifest_valid == "true" ]] && \
      [[ $checksum_set_before =~ ^[0-9a-f]{64}$ ]] && \
      (cd "$latest_backup_path" && \
        sha256sum --check --strict -- SHA256SUMS >/dev/null 2>&1); then
      checksum_set_after="$(sha256sum -- "$checksums_file" 2>/dev/null || true)"
      checksum_set_after="${checksum_set_after%% *}"
      if [[ $checksum_set_after =~ ^[0-9a-f]{64}$ ]] && \
        [[ $checksum_set_after == "$checksum_set_before" ]]; then
        backup_checksum_set_sha256="$checksum_set_after"
        backup_checksum_validation="passed"
      fi
    fi
  fi
fi

last_restore_at_file="$install_root/state/last-restore-test-at"
last_restore_backup_file="$install_root/state/last-restore-test-backup"
last_restore_checksum_file="$install_root/state/last-restore-test-checksum-set-sha256"
if [[ -f $last_restore_at_file && ! -L $last_restore_at_file && \
      -f $last_restore_backup_file && ! -L $last_restore_backup_file && \
      -f $last_restore_checksum_file && ! -L $last_restore_checksum_file ]]; then
  last_restore_test_at="$(<"$last_restore_at_file")"
  restored_backup_name="$(<"$last_restore_backup_file")"
  restored_checksum_set_sha256="$(<"$last_restore_checksum_file")"
  restore_validation="invalid"
  restore_checksum_set_validation="invalid"
  if [[ $backup_checksum_validation == "passed" ]] && \
    [[ $restored_checksum_set_sha256 =~ ^[0-9a-f]{64}$ ]] && \
    [[ $restored_checksum_set_sha256 == "$backup_checksum_set_sha256" ]]; then
    restore_checksum_set_validation="matched"
  fi
  if [[ $last_restore_test_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && \
    [[ $restored_backup_name =~ ^[0-9]{8}T[0-9]{6}Z-v[0-9]+(\.[0-9]+)+$ ]] && \
    [[ $backup_validation == "passed-local-only" ]] && \
    [[ $backup_checksum_validation == "passed" ]] && \
    [[ $restore_checksum_set_validation == "matched" ]] && \
    [[ $restored_backup_name == "$latest_backup_name" ]]; then
    restore_epoch="$(date --date="$last_restore_test_at" +%s 2>/dev/null || true)"
    now_epoch="$(date -u +%s)"
    if [[ $restore_epoch =~ ^[0-9]+$ ]] && ((now_epoch >= restore_epoch)) && \
      ((now_epoch - restore_epoch <= 604800)) && \
      [[ $backup_epoch =~ ^[0-9]+$ ]] && ((restore_epoch >= backup_epoch)); then
      restore_validation="schema-storage-integrity-passed"
      restore_matches_latest="true"
    else
      restore_validation="stale"
    fi
  fi
fi

worker_validation="not-run"
smoke_status_file="$install_root/state/worker-smoke-status.json"
if [[ -f $smoke_status_file ]]; then
  worker_validation="invalid"
  smoke_status="$(jq -r '.status // "invalid"' "$smoke_status_file" 2>/dev/null || true)"
  case "$smoke_status" in
    running | failed)
      worker_validation="$smoke_status"
      ;;
    passed)
      if [[ -f $installer_revision_file ]]; then
        installer_revision="$(<"$installer_revision_file")"
        last_worker_smoke_at="$(jq -r '.completed_at_utc // ""' "$smoke_status_file" 2>/dev/null || true)"
        if jq -e \
          --arg installer_revision "$installer_revision" \
          --arg release "$QFIELDCLOUD_RELEASE" \
          --arg qgis_image "$QFC_QGIS3_IMAGE" \
          --arg qgis_version "$QFC_QGIS3_EXPECTED_VERSION" \
          '.status == "passed" and
           .installer_revision == $installer_revision and
           .release == $release and
           .qgis_image == $qgis_image and
           .qgis_expected_version == $qgis_version and
           (.qgis_reported_version == $qgis_version or
             (.qgis_reported_version | startswith($qgis_version + "-"))) and
           ((.project_id | type) == "string") and
           (.project_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
           ((.package_job_id | type) == "string") and
           (.package_job_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))' \
          "$smoke_status_file" >/dev/null 2>&1 && \
          [[ $last_worker_smoke_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
          smoke_epoch="$(date --date="$last_worker_smoke_at" +%s 2>/dev/null || true)"
          now_epoch="$(date -u +%s)"
          if [[ $smoke_epoch =~ ^[0-9]+$ ]] && ((now_epoch >= smoke_epoch)) && \
            ((now_epoch - smoke_epoch <= 604800)); then
            worker_validation="passed"
          else
            worker_validation="stale"
          fi
        fi
      fi
      ;;
  esac
fi

installation_validation="incomplete"
install_intent_file="$install_root/state/install-intent.json"
installed_release_file="$install_root/state/installed-release"
installed_manifest_file="$install_root/state/installer-manifest-sha256"
if [[ -f $install_intent_file && ! -L $install_intent_file && \
      -f $installed_release_file && ! -L $installed_release_file && \
      -f $installer_revision_file && ! -L $installer_revision_file && \
      -f $installed_manifest_file && ! -L $installed_manifest_file ]] && \
  [[ $(<"$installed_release_file") == "$QFIELDCLOUD_RELEASE" ]] && \
  jq -e \
    --arg release "$QFIELDCLOUD_RELEASE" \
    --arg revision "$(<"$installer_revision_file")" \
    --arg manifest "$(<"$installed_manifest_file")" \
    '.status == "complete" and .release == $release and
     .installer_revision == $revision and .source_manifest_sha256 == $manifest' \
    "$install_intent_file" >/dev/null 2>&1; then
  installation_validation="complete"
fi

overall="error"
if [[ $service_health == "ok" ]] && [[ $service_only == "true" ]]; then
  overall="ok"
elif [[ $service_health == "ok" ]] && \
  [[ $recovery_validation == "clear" ]] && \
  [[ $maintenance_failure_state == "clear" ]] && \
  [[ $worker_validation == "passed" ]] && \
  [[ $backup_validation == "passed-local-only" ]] && \
  [[ $backup_checksum_validation == "passed" ]] && \
  [[ $restore_validation == "schema-storage-integrity-passed" ]] && \
  [[ $restore_matches_latest == "true" ]] && \
  { [[ $installation_gate == "true" ]] || [[ $installation_validation == "complete" ]]; }; then
  overall="ok"
fi

jq -cn \
  --arg overall "$overall" \
  --arg service_health "$service_health" \
  --arg health_mode "$health_mode" \
  --arg installation_validation "$installation_validation" \
  --arg release "$QFIELDCLOUD_RELEASE" \
  --arg platform "$QFIELDCLOUD_PLATFORM" \
  --arg bootstrap "$bootstrap_state" \
  --arg docker "$docker_state" \
  --arg runtime_provenance "$runtime_provenance_state" \
  --arg runtime_images "$runtime_images_state" \
  --arg protected_state_permissions "$protected_state_permissions" \
  --arg db_container "$db_container_state" \
  --arg storage_container "$storage_container_state" \
  --arg db_container_health "$db_container_health" \
  --arg storage_container_health "$storage_container_health" \
  --arg smtp "$smtp_state" \
  --arg cache "$cache_state" \
  --arg app "$app_state" \
  --arg nginx "$nginx_state" \
  --arg worker "$worker_state" \
  --arg cron "$cron_state" \
  --arg qgis3 "$qgis3_state" \
  --arg qgis4 "disabled-unverified-upstream-image" \
  --arg proj_data "$proj_data_state" \
  --arg certificate_mode "$certificate_mode" \
  --arg certificate "$certificate_state" \
  --arg certificate_renewal "$certificate_renewal_state" \
  --arg certificate_not_after "$certificate_not_after" \
  --arg certificate_last_check_at "$last_certificate_check_at" \
  --arg certificate_last_renewal_at "$last_certificate_renewal_at" \
  --arg database "$database_state" \
  --arg storage "$storage_state" \
  --arg recovery_validation "$recovery_validation" \
  --arg maintenance_failures "$maintenance_failure_state" \
  --arg restore_test_orphans "$restore_test_orphan_state" \
  --arg worker_smoke_at "$last_worker_smoke_at" \
  --arg worker_validation "$worker_validation" \
  --arg backup_validation "$backup_validation" \
  --arg backup_checksum_validation "$backup_checksum_validation" \
  --arg latest_backup_name "$latest_backup_name" \
  --arg backup_at "$last_backup_at" \
  --arg restore_validation "$restore_validation" \
  --arg restore_checksum_set_validation "$restore_checksum_set_validation" \
  --arg restored_backup_name "$restored_backup_name" \
  --arg restore_matches_latest "$restore_matches_latest" \
  --arg restore_test_at "$last_restore_test_at" \
  '{
    overall: $overall,
    health_mode: $health_mode,
    service_health: $service_health,
    installation_validation: $installation_validation,
    release: $release,
    platform: $platform,
    bootstrap: $bootstrap,
    docker: $docker,
    runtime_provenance: $runtime_provenance,
    runtime_images: $runtime_images,
    protected_state_permissions: $protected_state_permissions,
    database_container: $db_container,
    database_container_health: $db_container_health,
    object_storage_container: $storage_container,
    object_storage_container_health: $storage_container_health,
    smtp: $smtp,
    cache: $cache,
    app: $app,
    nginx: $nginx,
    worker_wrapper: $worker,
    cron_scheduler: $cron,
    qgis3_image: $qgis3,
    qgis4: $qgis4,
    transformation_grids: $proj_data,
    certificate_mode: $certificate_mode,
    tls_certificate: $certificate,
    certificate_renewal: $certificate_renewal,
    certificate_not_after: $certificate_not_after,
    certificate_last_check_at: $certificate_last_check_at,
    certificate_last_renewal_at: $certificate_last_renewal_at,
    database: $database,
    storage: $storage,
    recovery_validation: $recovery_validation,
    maintenance_failures: $maintenance_failures,
    restore_test_orphans: $restore_test_orphans,
    worker_validation: $worker_validation,
    last_worker_smoke_at: $worker_smoke_at,
    backup_validation: $backup_validation,
    backup_checksum_validation: $backup_checksum_validation,
    latest_backup_name: $latest_backup_name,
    last_backup_at: $backup_at,
    restore_validation: $restore_validation,
    restore_checksum_set_validation: $restore_checksum_set_validation,
    restored_backup_name: $restored_backup_name,
    restore_matches_latest: ($restore_matches_latest == "true"),
    last_restore_test_at: $restore_test_at
  }'

[[ $overall == "ok" ]]
