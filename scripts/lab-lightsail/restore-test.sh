#!/usr/bin/env bash

set -Eeuo pipefail
set +x
umask 077

failure_marker_ready="false"
failure_stage="preflight"
failure_reason="unexpected-error"
cleanup_status="not-run"
write_restore_failure_marker() {
  local marker_path="${state_dir:-}/last-restore-test-failure"
  local marker_tmp=""
  local safe_reason="${failure_reason//$'\r'/ }"
  local selected_backup="${latest_backup_name:-not-selected}"

  safe_reason="${safe_reason//$'\n'/ }"
  [[ $failure_marker_ready == "true" ]] || return 0
  [[ -d ${state_dir:-} && ! -L ${state_dir:-} ]] || return 1
  if [[ -e $marker_path || -L $marker_path ]] && \
    [[ ! -f $marker_path || -L $marker_path ]]; then
    return 1
  fi
  marker_tmp="$(mktemp "$state_dir/.last-restore-test-failure.XXXXXX")" \
    || return 1
  if ! {
    printf 'operation=restore-test\n'
    printf 'failed_at_utc=%s\n' "$(date -u +%FT%TZ)"
    printf 'stage=%s\n' "$failure_stage"
    printf 'reason=%s\n' "$safe_reason"
    printf 'selected_backup=%s\n' "$selected_backup"
    printf 'cleanup_status=%s\n' "$cleanup_status"
    printf 'next_action=inspect-root-only-state-and-redacted-service-logs-before-retry\n'
  } >"$marker_tmp" \
    || ! chmod 0600 "$marker_tmp" \
    || ! mv -f -- "$marker_tmp" "$marker_path"; then
    rm -f -- "$marker_tmp"
    return 1
  fi
}

preflight_on_exit() {
  local exit_code=$?

  trap - EXIT
  if [[ $exit_code -ne 0 ]]; then
    cleanup_status="not-started"
    if ! write_restore_failure_marker; then
      echo "The root-only restore-test preflight failure marker could not be written safely." >&2
    fi
  fi
  exit "$exit_code"
}

die() {
  failure_reason="$1"
  echo "$failure_reason" >&2
  if ! write_restore_failure_marker; then
    echo "The root-only restore-test failure marker could not be written safely." >&2
  fi
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  die "Run this command with sudo on the Lightsail instance."
fi

for required_command in awk cat chmod date df docker find flock gzip install jq ln mktemp \
  mv openssl readlink realpath rm seq sha256sum sleep sort stat tar tr; do
  command -v "$required_command" >/dev/null 2>&1 \
    || die "Required command is unavailable: $required_command"
done

has_root_controlled_ancestors() {
  local current_path="${1%/*}"
  local path_metadata=""

  [[ -n $current_path ]] || current_path="/"
  while :; do
    if [[ ! -d $current_path || -L $current_path ]] \
      || [[ $(realpath -e "$current_path") != "$current_path" ]]; then
      return 1
    fi
    path_metadata="$(stat -c '%u:%g:%a' "$current_path")" || return 1
    [[ $path_metadata =~ ^0:0:[1357][0145][0145]$ ]] || return 1
    [[ $current_path == "/" ]] && return 0
    current_path="${current_path%/*}"
    [[ -n $current_path ]] || current_path="/"
  done
}

install_root="${QFC_INSTALL_ROOT:-/opt/qfieldcloud}"
backup_root="${QFC_BACKUP_ROOT:-/var/backups/qfieldcloud}"
state_dir="$install_root/state"
bin_dir="$install_root/bin"
operational_versions_file="$install_root/versions.env"
operational_runtime_env="$state_dir/runtime.env"
operational_compose_file="$install_root/compose.yaml"
operational_health_check_file="$bin_dir/health-check.sh"

if [[ ! $install_root =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ $install_root == "/" ]] || \
  [[ $install_root == *"//"* ]] || [[ $install_root == *"/../"* ]] || \
  [[ ! $backup_root =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ $backup_root == "/" ]] || \
  [[ $backup_root == *"//"* ]] || [[ $backup_root == *"/../"* ]]; then
  die "The install and backup roots must be safe absolute paths other than /."
fi

for trusted_directory in "$install_root" "$state_dir" "$bin_dir"; do
  if [[ ! -d $trusted_directory || -L $trusted_directory ]] \
    || [[ $(realpath -e "$trusted_directory") != "$trusted_directory" ]] \
    || [[ $(stat -c '%u:%g:%a' "$trusted_directory") != "0:0:700" ]]; then
    die "A trusted QFieldCloud installation directory is unavailable or unsafe."
  fi
done
has_root_controlled_ancestors "$install_root" \
  || die "The QFieldCloud installation ancestors are not root-controlled."
for operational_file in "$operational_versions_file" "$operational_runtime_env" \
  "$operational_compose_file"; do
  if [[ ! -f $operational_file || -L $operational_file ]] \
    || [[ $(stat -c '%u:%g:%a' "$operational_file") != "0:0:600" ]]; then
    die "The operational Compose state is missing or unsafe."
  fi
done
if [[ ! -f $operational_health_check_file || -L $operational_health_check_file \
      || ! -x $operational_health_check_file ]] \
  || [[ $(stat -c '%u:%g:%a' "$operational_health_check_file") != "0:0:700" ]]; then
  die "The operational health-check helper is missing or unsafe."
fi

if [[ ! -d $backup_root || -L $backup_root ]] \
  || [[ $(realpath -e "$backup_root") != "$backup_root" ]] \
  || [[ $(stat -c '%u:%g:%a' "$backup_root") != "0:0:700" ]]; then
  die "No canonical root-owned QFieldCloud backup directory with mode 0700 is available."
fi
has_root_controlled_ancestors "$backup_root" \
  || die "The backup ancestors are not root-controlled."
docker info >/dev/null 2>&1 || die "Docker is not running."

docker_architecture="$(docker info --format '{{.Architecture}}')"
if [[ $docker_architecture != "x86_64" && $docker_architecture != "amd64" ]]; then
  die "The restore test supports only linux/amd64."
fi

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

prepare_lock_directory || die "The root-owned QFieldCloud lock directory is missing or unsafe."
maintenance_lock_file="$qfc_lock_root/maintenance.lock"
restore_test_lock_file="$qfc_lock_root/restore-test.lock"
prepare_lock_file "$maintenance_lock_file" \
  || die "The QFieldCloud maintenance lock file is missing or unsafe."
prepare_lock_file "$restore_test_lock_file" \
  || die "The QFieldCloud restore-test lock file is missing or unsafe."
inherited_lock="false"
if [[ ${QFC_MAINTENANCE_LOCK_FD:-} == "8" ]] && [[ -e /proc/$$/fd/8 ]] && \
  lock_fd_matches_file 8 "$maintenance_lock_file"; then
  inherited_lock="true"
fi
if [[ $inherited_lock != "true" ]]; then
  exec 8>>"$maintenance_lock_file"
  lock_fd_matches_file 8 "$maintenance_lock_file" \
    || die "The QFieldCloud maintenance lock descriptor changed unexpectedly."
fi
if ! flock -n 8; then
  die "Another QFieldCloud maintenance operation is already running."
fi
export QFC_MAINTENANCE_LOCK_FD=8

exec 9>>"$restore_test_lock_file"
lock_fd_matches_file 9 "$restore_test_lock_file" \
  || die "The QFieldCloud restore-test lock descriptor changed unexpectedly."
if ! flock -n 9; then
  die "Another QFieldCloud restore test is already running."
fi

runtime_temp_root="/run/qfieldcloud"
has_root_controlled_ancestors "$runtime_temp_root" \
  || die "The restore-test runtime ancestors are not root-controlled."
if [[ -e $runtime_temp_root || -L $runtime_temp_root ]]; then
  if [[ ! -d $runtime_temp_root || -L $runtime_temp_root ]] \
    || [[ $(realpath -e "$runtime_temp_root") != "$runtime_temp_root" ]] \
    || [[ $(stat -c '%u:%g:%a' "$runtime_temp_root") != "0:0:700" ]]; then
    die "The existing restore-test runtime directory is unsafe."
  fi
else
  install -o root -g root -m 0700 -d "$runtime_temp_root"
fi
[[ $(stat -c '%u:%g:%a' "$runtime_temp_root") == "0:0:700" ]] \
  || die "The restore-test runtime directory ownership or permissions are unsafe."
stale_runtime_env_files="$(
  find "$runtime_temp_root" -mindepth 1 -maxdepth 1 -type f \
    -name 'restore-test-*.env.*' -printf '%f\n' | LC_ALL=C sort
)"
if [[ -n $stale_runtime_env_files ]]; then
  printf 'Root-only restore-test credential files from an interrupted run require manual inspection:\n%s\n' \
    "$stale_runtime_env_files" >&2
  die "No stale credential file was removed automatically."
fi

failure_marker_ready="true"
trap preflight_on_exit EXIT

operational_compose() {
  docker compose \
    --env-file "$operational_versions_file" \
    --env-file "$operational_runtime_env" \
    --file "$operational_compose_file" \
    "$@"
}
recovery_required_file="$state_dir/recovery-required"
if [[ -e $recovery_required_file || -L $recovery_required_file ]]; then
  die "An unresolved recovery-required marker already exists; restore testing is blocked before changing any success marker."
fi
for previous_marker in "$state_dir/last-restore-test-at" \
  "$state_dir/last-restore-test-backup" \
  "$state_dir/last-restore-test-checksum-set-sha256" \
  "$state_dir/last-restore-test-failure"; do
  if [[ -d $previous_marker && ! -L $previous_marker ]]; then
    die "A restore-test marker path is an unexpected directory."
  fi
done
# These markers describe the current recovery-readiness test, not historical
# success. Invalidate them before any preflight so a failed retry cannot reuse a
# stale success marker. They are recreated only after validation and cleanup.
rm -f -- \
  "$state_dir/last-restore-test-at" \
  "$state_dir/last-restore-test-backup" \
  "$state_dir/last-restore-test-checksum-set-sha256"

resource_label_key="com.qfieldcloud.restore-test"
orphan_containers="$(
  docker container ls --all \
    --filter "label=$resource_label_key" \
    --format '{{.Names}}'
)"
orphan_volumes="$(
  docker volume ls \
    --filter "label=$resource_label_key" \
    --format '{{.Name}}'
)"
orphan_networks="$(
  docker network ls \
    --filter "label=$resource_label_key" \
    --format '{{.Name}}'
)"
if [[ -n $orphan_containers || -n $orphan_volumes || -n $orphan_networks ]]; then
  echo "A previous restore test left labeled Docker resources behind." >&2
  if [[ -n $orphan_containers ]]; then
    printf 'Containers to inspect manually:\n%s\n' "$orphan_containers" >&2
  fi
  if [[ -n $orphan_volumes ]]; then
    printf 'Volumes to inspect manually:\n%s\n' "$orphan_volumes" >&2
  fi
  if [[ -n $orphan_networks ]]; then
    printf 'Networks to inspect manually:\n%s\n' "$orphan_networks" >&2
  fi
  die "No resource was removed. Confirm that no test is active, inspect the listed resources, and remove them manually before retrying."
fi

failure_stage="backup-selection-and-integrity"
latest_backup_name=""
while IFS= read -r candidate_name; do
  if [[ $candidate_name =~ ^[0-9]{8}T[0-9]{6}Z-v[0-9]+(\.[0-9]+)+$ ]]; then
    latest_backup_name="$candidate_name"
    break
  fi
done < <(
  find "$backup_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | LC_ALL=C sort --reverse
)

[[ -n $latest_backup_name ]] || die "No completed QFieldCloud backup was found."

backup_root_real="$(realpath -e "$backup_root")"
backup_dir="$(realpath -e "$backup_root/$latest_backup_name")"
if [[ $backup_dir != "$backup_root_real/"* ]] \
  || [[ -L $backup_root/$latest_backup_name ]] \
  || [[ $(stat -c '%u:%g:%a' "$backup_dir") != "0:0:700" ]]; then
  die "The selected backup path is unsafe."
fi

for backup_subdirectory in "$backup_dir/data" "$backup_dir/sensitive"; do
  if [[ ! -d $backup_subdirectory || -L $backup_subdirectory ]] \
    || [[ $(realpath -e "$backup_subdirectory") != "$backup_subdirectory" ]] \
    || [[ $(stat -c '%u:%g:%a' "$backup_subdirectory") != "0:0:700" ]]; then
    die "The latest backup contains an unsafe directory."
  fi
done

required_backup_files=(
  data/database.dump
  data/object-storage.tar.gz
  data/media.tar.gz
  sensitive/secrets.env
  versions.env
  compose.yaml
  public-host
  manifest.json
)

for relative_path in "${required_backup_files[@]}"; do
  backup_file="$backup_dir/$relative_path"
  if [[ ! -f $backup_file ]] || [[ -L $backup_file ]]; then
    die "The latest backup is incomplete."
  fi
  backup_file_real="$(realpath -e "$backup_file")"
  if [[ $backup_file_real != "$backup_dir/"* ]] \
    || [[ $(stat -c '%u:%g:%a' "$backup_file") != "0:0:600" ]]; then
    die "The latest backup contains an unsafe file path."
  fi
done

checksums_file="$backup_dir/SHA256SUMS"
if [[ ! -f $checksums_file ]] || [[ -L $checksums_file ]] \
  || [[ $(realpath -e "$checksums_file") != "$checksums_file" ]] \
  || [[ $(stat -c '%u:%g:%a' "$checksums_file") != "0:0:600" ]]; then
  die "The latest backup has no safe checksum manifest."
fi

nonempty_checksum_lines="$(awk 'NF { count += 1 } END { print count + 0 }' "$checksums_file")"
if [[ $nonempty_checksum_lines -ne ${#required_backup_files[@]} ]]; then
  die "The checksum manifest has an unexpected number of entries."
fi

verify_checksum() {
  local relative_path="$1"
  local expected_hash=""
  local match_count="0"
  local actual_hash=""

  match_count="$(
    awk -v target="$relative_path" '$2 == target { count += 1 } END { print count + 0 }' \
      "$checksums_file"
  )"
  [[ $match_count -eq 1 ]] || return 1

  expected_hash="$(
    awk -v target="$relative_path" '$2 == target { print $1 }' "$checksums_file"
  )"
  [[ $expected_hash =~ ^[0-9a-f]{64}$ ]] || return 1

  actual_hash="$(sha256sum -- "$backup_dir/$relative_path")"
  actual_hash="${actual_hash%% *}"
  [[ $actual_hash == "$expected_hash" ]]
}

for relative_path in "${required_backup_files[@]}"; do
  verify_checksum "$relative_path" || die "Backup checksum validation failed."
done
checksums_file_sha256="$(sha256sum -- "$checksums_file")"
checksums_file_sha256="${checksums_file_sha256%% *}"
[[ $checksums_file_sha256 =~ ^[0-9a-f]{64}$ ]] \
  || die "The checksum-set digest could not be determined safely."

read_env_value() {
  local file_path="$1"
  local requested_key="$2"
  local line=""
  local value=""
  local found_count=0

  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%$'\r'}"
    if [[ $line == "$requested_key="* ]]; then
      found_count=$((found_count + 1))
      value="${line#*=}"
    fi
  done <"$file_path"

  [[ $found_count -eq 1 ]] || return 1
  [[ -n $value ]] || return 1
  printf '%s' "$value"
}

backup_versions_file="$backup_dir/versions.env"
if ! backup_release="$(read_env_value "$backup_versions_file" QFIELDCLOUD_RELEASE)" \
  || ! backup_commit="$(read_env_value "$backup_versions_file" QFIELDCLOUD_COMMIT)" \
  || ! backup_platform="$(read_env_value "$backup_versions_file" QFIELDCLOUD_PLATFORM)" \
  || ! postgis_image="$(read_env_value "$backup_versions_file" POSTGIS_IMAGE)" \
  || ! rustfs_image="$(read_env_value "$backup_versions_file" RUSTFS_IMAGE)" \
  || ! app_image="$(read_env_value "$backup_versions_file" QFC_APP_IMAGE)"; then
  die "The backup version manifest is incomplete."
fi

[[ $backup_release =~ ^v[0-9]+(\.[0-9]+)+$ ]] \
  || die "The backup release identifier is invalid."
[[ $backup_commit =~ ^[0-9a-f]{40}$ ]] \
  || die "The backup commit identifier is invalid."
[[ $backup_platform == "linux/amd64" ]] \
  || die "The backup platform is not linux/amd64."

for pinned_image in "$postgis_image" "$rustfs_image" "$app_image"; do
  if [[ ! $pinned_image =~ ^docker\.io/[-a-z0-9._/]+@sha256:[0-9a-f]{64}$ ]]; then
    die "A restore-test image is not pinned to an allowed Docker manifest digest."
  fi
done

if ! jq -e \
  --arg release "$backup_release" \
  --arg commit "$backup_commit" \
  '
    type == "object"
    and .scope == "qfieldcloud-system-only"
    and .release == $release
    and .upstream_commit == $commit
    and (.includes | type == "array")
    and (.includes | index("database")) != null
    and (.includes | index("object-storage")) != null
    and (.includes | index("media")) != null
    and (.excludes | type == "array")
    and (.excludes | index("existing-arboretum-postgis")) != null
    and (.source_sizes_bytes | type == "object")
    and ((.source_sizes_bytes.database | type) == "number")
    and (.source_sizes_bytes.database >= 0)
    and (.source_sizes_bytes.database == (.source_sizes_bytes.database | floor))
    and (.source_sizes_bytes.database <= 9007199254740991)
    and ((.source_sizes_bytes.object_storage | type) == "number")
    and (.source_sizes_bytes.object_storage >= 0)
    and (.source_sizes_bytes.object_storage == (.source_sizes_bytes.object_storage | floor))
    and (.source_sizes_bytes.object_storage <= 9007199254740991)
    and ((.source_sizes_bytes.media | type) == "number")
    and (.source_sizes_bytes.media >= 0)
    and (.source_sizes_bytes.media == (.source_sizes_bytes.media | floor))
    and (.source_sizes_bytes.media <= 9007199254740991)
  ' "$backup_dir/manifest.json" >/dev/null; then
  die "The backup manifest does not describe an isolated QFieldCloud backup."
fi

database_source_bytes="$(
  jq --raw-output '.source_sizes_bytes.database' "$backup_dir/manifest.json"
)"
object_storage_source_bytes="$(
  jq --raw-output '.source_sizes_bytes.object_storage' "$backup_dir/manifest.json"
)"
media_source_bytes="$(
  jq --raw-output '.source_sizes_bytes.media' "$backup_dir/manifest.json"
)"
for source_size in "$database_source_bytes" "$object_storage_source_bytes" \
  "$media_source_bytes"; do
  [[ $source_size =~ ^[0-9]+$ ]] \
    || die "The backup manifest contains an unusable source size."
done

database_dump_bytes="$(stat -c '%s' "$backup_dir/data/database.dump")"
if [[ ! $database_dump_bytes =~ ^[0-9]+$ ]] || ((database_dump_bytes == 0)); then
  die "The database dump size could not be determined."
fi
restore_working_bytes=$((
  database_source_bytes * 2
  + object_storage_source_bytes
  + media_source_bytes
))
restore_headroom_bytes=$((restore_working_bytes / 4))
if ((restore_headroom_bytes < 2147483648)); then
  restore_headroom_bytes=2147483648
fi
required_restore_bytes=$((restore_working_bytes + restore_headroom_bytes))
backup_secrets_file="$backup_dir/sensitive/secrets.env"
if ! rustfs_access_key="$(
  read_env_value "$backup_secrets_file" OBJECT_STORAGE_ROOT_USER
)" || ! rustfs_secret_key="$(
  read_env_value "$backup_secrets_file" OBJECT_STORAGE_ROOT_PASSWORD
)"; then
  die "The protected backup credentials are incomplete."
fi

if ! operational_db_user="$(
  read_env_value "$operational_runtime_env" POSTGRES_USER
)" || ! operational_db_password="$(
  read_env_value "$operational_runtime_env" POSTGRES_PASSWORD
)" || ! operational_postgis_image="$(
  read_env_value "$operational_versions_file" POSTGIS_IMAGE
)"; then
  die "The protected operational database settings are incomplete."
fi

if [[ ! $rustfs_access_key =~ ^[A-Za-z0-9_-]{8,128}$ ]] \
  || [[ ! $rustfs_secret_key =~ ^[A-Za-z0-9_-]{16,256}$ ]] \
  || [[ ! $operational_db_user =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] \
  || [[ ! $operational_db_password =~ ^[0-9a-f]{64}$ ]]; then
  die "The protected backup credentials have an unsafe format."
fi
[[ $operational_postgis_image == "$postgis_image" ]] \
  || die "The running PostGIS image does not match the selected backup."

if ! stale_restore_database_count="$(
  operational_compose exec --no-TTY db \
    psql --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 \
      --username "$operational_db_user" --dbname postgres \
      --command "SELECT count(*) FROM pg_database WHERE datname ~ '^qfc_restore_test_[0-9a-f]{12}$';" \
    2>/dev/null | tr -d '\r'
)"; then
  die "The operational QFieldCloud database service could not be inspected safely."
fi
[[ $stale_restore_database_count == "0" ]] \
  || die "A previous restore test left a namespaced temporary database behind; inspect it before retrying."

for pinned_image in "$postgis_image" "$rustfs_image" "$app_image"; do
  if ! docker image inspect "$pinned_image" >/dev/null 2>&1; then
    docker pull "$pinned_image" >/dev/null
  fi
  docker image inspect "$pinned_image" >/dev/null 2>&1 \
    || die "A pinned restore-test image is unavailable."
done

docker_root_dir="$(docker info --format '{{.DockerRootDir}}')"
if [[ $docker_root_dir != /* ]] || [[ ! -d $docker_root_dir ]]; then
  die "Docker reported an unsafe data-root path."
fi
docker_available_bytes="$(
  df --block-size=1 --output=avail "$docker_root_dir" \
    | awk 'NR > 1 { available = $1 } END { print available }'
)"
if [[ ! $docker_available_bytes =~ ^[0-9]+$ ]]; then
  die "Docker data-root free space could not be determined."
fi
if ((docker_available_bytes < required_restore_bytes)); then
  die "Insufficient Docker data-root space. Required: $required_restore_bytes bytes; available: $docker_available_bytes bytes."
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(openssl rand -hex 4)"
network_name="qfc-restoretest-$run_id"
rustfs_volume="qfc_restoretest_rustfs_$run_id"
media_volume="qfc_restoretest_media_$run_id"
rustfs_container="qfc-restoretest-rustfs-$run_id"
app_check_container="qfc-restoretest-app-check-$run_id"
storage_check_container="qfc-restoretest-storage-check-$run_id"
temporary_database="qfc_restore_test_$(openssl rand -hex 6)"

network_created="false"
rustfs_volume_created="false"
media_volume_created="false"
temporary_env_file=""
operational_services_quiesced="false"
operational_db_container=""
operational_db_network_attached="false"
temporary_database_created="false"
worker_quiesce_blocked="false"
recovery_marker_owned="false"
recovery_marker_identity=""

write_recovery_required() {
  local reason="$1"
  local marker_tmp=""
  local current_identity=""

  if [[ $recovery_marker_owned == "true" ]]; then
    if [[ ! -f $recovery_required_file || -L $recovery_required_file ]]; then
      echo "Refusing to replace a recovery marker not owned by this restore test." >&2
      return 1
    fi
    current_identity="$(stat --format '%d:%i' -- "$recovery_required_file")" || return 1
    if [[ $current_identity != "$recovery_marker_identity" ]]; then
      echo "Refusing to replace a recovery marker changed outside this restore test." >&2
      return 1
    fi
    return 0
  elif [[ -e $recovery_required_file || -L $recovery_required_file ]]; then
    echo "Refusing to overwrite an existing recovery-required marker." >&2
    return 1
  fi

  marker_tmp="$(mktemp "$state_dir/.recovery-required.restore-test.XXXXXX")" \
    || return 1
  if ! {
    printf 'operation=restore-test\n'
    printf 'detected_at_utc=%s\n' "$(date -u +%FT%TZ)"
    printf 'reason=%s\n' "$reason"
    printf 'manual_command=docker compose --env-file %s --env-file %s --file %s up -d\n' \
      "$operational_versions_file" "$operational_runtime_env" "$operational_compose_file"
  } >"$marker_tmp" \
    || ! chmod 0600 "$marker_tmp" \
    || ! ln -- "$marker_tmp" "$recovery_required_file"; then
    rm -f -- "$marker_tmp"
    return 1
  fi
  rm -f -- "$marker_tmp" || return 1
  recovery_marker_identity="$(stat --format '%d:%i' -- "$recovery_required_file")" \
    || return 1
  recovery_marker_owned="true"
}

remove_owned_recovery_marker() {
  local current_identity=""

  [[ $recovery_marker_owned == "true" ]] || return 0
  [[ -f $recovery_required_file && ! -L $recovery_required_file ]] || return 1
  current_identity="$(stat --format '%d:%i' -- "$recovery_required_file")" || return 1
  [[ $current_identity == "$recovery_marker_identity" ]] || return 1
  rm -f -- "$recovery_required_file" || return 1
  recovery_marker_owned="false"
  recovery_marker_identity=""
}

remove_owned_container() {
  local container_name="$1"
  local owner_label=""

  if ! docker container inspect "$container_name" >/dev/null 2>&1; then
    return 0
  fi
  owner_label="$(
    docker container inspect \
      --format '{{ index .Config.Labels "com.qfieldcloud.restore-test" }}' \
      "$container_name" 2>/dev/null
  )"
  if [[ $owner_label != "$run_id" ]]; then
    echo "Refusing to remove a container not owned by this restore test: $container_name" >&2
    return 1
  fi
  docker container rm --force "$container_name" >/dev/null 2>&1
}

remove_owned_volume() {
  local volume_name="$1"
  local owner_label=""

  if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
    return 0
  fi
  owner_label="$(
    docker volume inspect \
      --format '{{ index .Labels "com.qfieldcloud.restore-test" }}' \
      "$volume_name" 2>/dev/null
  )"
  if [[ $owner_label != "$run_id" ]]; then
    echo "Refusing to remove a volume not owned by this restore test: $volume_name" >&2
    return 1
  fi
  docker volume rm "$volume_name" >/dev/null 2>&1
}

remove_owned_network() {
  local target_network="$1"
  local owner_label=""

  if ! docker network inspect "$target_network" >/dev/null 2>&1; then
    return 0
  fi
  owner_label="$(
    docker network inspect \
      --format '{{ index .Labels "com.qfieldcloud.restore-test" }}' \
      "$target_network" 2>/dev/null
  )"
  if [[ $owner_label != "$run_id" ]]; then
    echo "Refusing to remove a network not owned by this restore test: $target_network" >&2
    return 1
  fi
  docker network rm "$target_network" >/dev/null 2>&1
}

drop_owned_temporary_database() {
  local database_count=""

  [[ $temporary_database_created == "true" ]] || return 0
  [[ $temporary_database =~ ^qfc_restore_test_[0-9a-f]{12}$ ]] || {
    echo "Refusing to drop a database outside the restore-test namespace." >&2
    return 1
  }
  [[ $operational_db_user =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || return 1

  operational_compose exec --no-TTY db \
    dropdb --if-exists --force --username "$operational_db_user" \
    "$temporary_database" >/dev/null 2>&1 || return 1
  database_count="$(
    operational_compose exec --no-TTY db \
      psql --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 \
        --username "$operational_db_user" --dbname postgres \
        --set "restore_database=$temporary_database" \
        --command "SELECT count(*) FROM pg_database WHERE datname = :'restore_database';" \
      2>/dev/null | tr -d '\r'
  )" || return 1
  [[ $database_count == "0" ]] || return 1
  temporary_database_created="false"
}

disconnect_operational_database_network() {
  [[ $operational_db_network_attached == "true" ]] || return 0
  [[ $operational_db_container =~ ^[0-9a-f]{64}$ ]] || return 1
  docker network disconnect "$network_name" "$operational_db_container" \
    >/dev/null 2>&1 || return 1
  operational_db_network_attached="false"
}

verify_no_owned_restore_resources() {
  local remaining_containers=""
  local remaining_volumes=""
  local remaining_networks=""
  local enumeration_failed=0

  if ! remaining_containers="$(
    docker container ls --all \
      --filter "label=$resource_label_key=$run_id" \
      --format '{{.Names}}'
  )"; then
    echo "Docker could not enumerate restore-test containers after cleanup." >&2
    enumeration_failed=1
  fi
  if ! remaining_volumes="$(
    docker volume ls \
      --filter "label=$resource_label_key=$run_id" \
      --format '{{.Name}}'
  )"; then
    echo "Docker could not enumerate restore-test volumes after cleanup." >&2
    enumeration_failed=1
  fi
  if ! remaining_networks="$(
    docker network ls \
      --filter "label=$resource_label_key=$run_id" \
      --format '{{.Name}}'
  )"; then
    echo "Docker could not enumerate restore-test networks after cleanup." >&2
    enumeration_failed=1
  fi

  if [[ -n $remaining_containers ]]; then
    printf 'Restore-test containers still present after cleanup:\n%s\n' \
      "$remaining_containers" >&2
  fi
  if [[ -n $remaining_volumes ]]; then
    printf 'Restore-test volumes still present after cleanup:\n%s\n' \
      "$remaining_volumes" >&2
  fi
  if [[ -n $remaining_networks ]]; then
    printf 'Restore-test networks still present after cleanup:\n%s\n' \
      "$remaining_networks" >&2
  fi

  [[ $enumeration_failed -eq 0 ]] \
    && [[ -z $remaining_containers ]] \
    && [[ -z $remaining_volumes ]] \
    && [[ -z $remaining_networks ]]
}

cleanup() {
  local cleanup_failed=0
  local operational_recovered="false"

  remove_owned_container "$storage_check_container" || cleanup_failed=1
  remove_owned_container "$app_check_container" || cleanup_failed=1
  remove_owned_container "$rustfs_container" || cleanup_failed=1
  drop_owned_temporary_database || cleanup_failed=1
  disconnect_operational_database_network || cleanup_failed=1

  if [[ $media_volume_created == "true" ]]; then
    remove_owned_volume "$media_volume" || cleanup_failed=1
  fi
  if [[ $rustfs_volume_created == "true" ]]; then
    remove_owned_volume "$rustfs_volume" || cleanup_failed=1
  fi
  if [[ $network_created == "true" ]]; then
    remove_owned_network "$network_name" || cleanup_failed=1
  fi

  if [[ -n $temporary_env_file ]]; then
    if [[ $temporary_env_file == "$runtime_temp_root/restore-test-"*.env.* ]]; then
      rm -f -- "$temporary_env_file" || cleanup_failed=1
    else
      echo "Refusing to remove an unexpected temporary file path." >&2
      cleanup_failed=1
    fi
  fi

  if [[ $operational_services_quiesced == "true" ]]; then
    if operational_compose up -d \
      db rustfs smtp4dev memcached app nginx worker_wrapper ofelia >/dev/null; then
      for _ in $(seq 1 36); do
        if "$operational_health_check_file" --service-only >/dev/null 2>&1; then
          operational_recovered="true"
          break
        fi
        sleep 10
      done
    fi
    if [[ $operational_recovered != "true" ]]; then
      write_recovery_required "service-recovery-not-confirmed"
      echo "Restore-test recovery could not confirm all operational services; inspect the root-only recovery-required marker." >&2
      cleanup_failed=1
    else
      if [[ $worker_quiesce_blocked != "true" ]]; then
        remove_owned_recovery_marker || cleanup_failed=1
      fi
      operational_services_quiesced="false"
    fi
  fi

  # A transient inspect failure must never be mistaken for successful removal.
  # Re-enumerate every resource bearing this run's label and fail closed when
  # Docker cannot prove that all of them are gone.
  verify_no_owned_restore_resources || cleanup_failed=1

  return "$cleanup_failed"
}

on_exit() {
  local original_exit_code="$1"
  local cleanup_exit_code=0

  trap - EXIT
  set +e
  cleanup
  cleanup_exit_code=$?
  if [[ $cleanup_exit_code -eq 0 ]]; then
    cleanup_status="passed"
  else
    cleanup_status="failed"
  fi
  if [[ $cleanup_exit_code -ne 0 && $original_exit_code -eq 0 ]]; then
    original_exit_code=1
    failure_stage="cleanup"
    failure_reason="Temporary resource cleanup or operational service recovery was not confirmed."
  fi
  if [[ $original_exit_code -ne 0 ]] && ! write_restore_failure_marker; then
    echo "The root-only restore-test failure marker could not be updated after cleanup." >&2
  fi
  exit "$original_exit_code"
}
trap 'on_exit $?' EXIT

write_state_marker() {
  local marker_name="$1"
  local marker_value="$2"
  local marker_path=""
  local marker_temp=""

  case "$marker_name" in
    last-restore-test-at | last-restore-test-backup | last-restore-test-checksum-set-sha256) ;;
    *) return 1 ;;
  esac
  marker_path="$state_dir/$marker_name"
  if [[ -e $marker_path && ! -f $marker_path && ! -L $marker_path ]]; then
    return 1
  fi
  marker_temp="$(mktemp "$state_dir/.$marker_name.XXXXXX")" || return 1
  if ! printf '%s\n' "$marker_value" >"$marker_temp" \
    || ! chmod 0600 "$marker_temp" \
    || ! mv --force -- "$marker_temp" "$marker_path"; then
    rm -f -- "$marker_temp"
    return 1
  fi
}

failure_stage="temporary-resource-preflight"
for resource_name in "$network_name" "$rustfs_volume" \
  "$media_volume" "$rustfs_container" "$app_check_container" \
  "$storage_check_container"; do
  if docker network inspect "$resource_name" >/dev/null 2>&1 \
    || docker volume inspect "$resource_name" >/dev/null 2>&1 \
    || docker container inspect "$resource_name" >/dev/null 2>&1; then
    die "A generated restore-test resource name is already in use."
  fi
done

failure_stage="operational-service-quiesce"
echo "Quiescing the operational pilot during the isolated integrity test."
write_recovery_required "restore-test-maintenance-in-progress" \
  || die "The durable recovery-required marker could not be created; no operational service was stopped."
operational_services_quiesced="true"
operational_compose stop nginx ofelia
operational_compose stop --timeout 900 worker_wrapper
if ! running_worker_children="$(
  docker container ls \
    --filter 'label=app=production_worker' \
    --format '{{.ID}}'
)"; then
  worker_quiesce_blocked="true"
  write_recovery_required "production-worker-enumeration-failed"
  die "Docker could not prove that every QGIS worker child stopped; restore testing is blocked."
fi
if [[ -n $running_worker_children ]]; then
  worker_quiesce_blocked="true"
  write_recovery_required "production-worker-still-running-after-wrapper-stop"
  echo "No application, database, storage, or temporary restore resource was stopped or created after this check." >&2
  die "A QGIS worker child is still running after worker_wrapper stopped; restore testing is blocked."
fi
operational_compose stop app
operational_compose stop rustfs smtp4dev memcached
operational_db_container="$(operational_compose ps --quiet db | tr -d '\r')"
if [[ ! $operational_db_container =~ ^[0-9a-f]{64}$ ]] \
  || [[ $(docker container inspect --format '{{.State.Running}}' "$operational_db_container") != "true" ]]; then
  die "The operational QFieldCloud database container is not running safely."
fi

mem_available_kib="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
if [[ ! $mem_available_kib =~ ^[0-9]+$ ]]; then
  die "Available memory could not be determined safely."
fi
available_memory_bytes=$((mem_available_kib * 1024))
if ((available_memory_bytes < 2684354560)); then
  die "At least 2.5 GiB of available RAM is required after quiescing the pilot; swap is not counted."
fi

docker network create \
  --internal \
  --label "$resource_label_key=$run_id" \
  "$network_name" >/dev/null
network_created="true"

docker network connect --alias db "$network_name" "$operational_db_container"
operational_db_network_attached="true"
docker volume create --label "$resource_label_key=$run_id" "$rustfs_volume" >/dev/null
rustfs_volume_created="true"
docker volume create --label "$resource_label_key=$run_id" "$media_volume" >/dev/null
media_volume_created="true"

get_owned_volume_mountpoint() {
  local volume_name="$1"
  local owner_label=""
  local mountpoint=""

  owner_label="$(
    docker volume inspect \
      --format '{{ index .Labels "com.qfieldcloud.restore-test" }}' \
      "$volume_name"
  )"
  [[ $owner_label == "$run_id" ]] || return 1
  mountpoint="$(docker volume inspect --format '{{ .Mountpoint }}' "$volume_name")"
  [[ $mountpoint == /* ]] || return 1
  [[ $mountpoint != "/" ]] || return 1
  [[ -d $mountpoint ]] || return 1
  printf '%s' "$mountpoint"
}

restore_and_compare_archive() {
  local archive_path="$1"
  local target_volume="$2"
  local target_mountpoint=""

  gzip --test "$archive_path" >/dev/null 2>&1 || return 1
  tar --list --gzip --file="$archive_path" >/dev/null 2>&1 || return 1
  target_mountpoint="$(get_owned_volume_mountpoint "$target_volume")" || return 1
  if [[ -n $(find "$target_mountpoint" -mindepth 1 -print -quit) ]]; then
    return 1
  fi
  tar \
    --extract \
    --gzip \
    --file="$archive_path" \
    --directory="$target_mountpoint" \
    --numeric-owner \
    --same-owner \
    --xattrs \
    --acls >/dev/null 2>&1 || return 1
  tar \
    --compare \
    --gzip \
    --file="$archive_path" \
    --directory="$target_mountpoint" \
    --numeric-owner \
    --xattrs \
    --acls >/dev/null 2>&1
}

restore_and_compare_archive \
  "$backup_dir/data/object-storage.tar.gz" \
  "$rustfs_volume" \
  || die "The object-storage archive could not be restored and compared safely."
restore_and_compare_archive \
  "$backup_dir/data/media.tar.gz" \
  "$media_volume" \
  || die "The media archive could not be restored and compared safely."

docker_available_after_archives="$(
  df --block-size=1 --output=avail "$docker_root_dir" \
    | awk 'NR > 1 { available = $1 } END { print available }'
)"
database_restore_requirement=$((database_source_bytes * 2 + restore_headroom_bytes))
if [[ ! $docker_available_after_archives =~ ^[0-9]+$ ]] || \
  ((docker_available_after_archives < database_restore_requirement)); then
  die "Docker data-root space became insufficient after restoring storage archives."
fi

temporary_env_file="$(mktemp "$runtime_temp_root/restore-test-$run_id.env.XXXXXX")"
chmod 0600 "$temporary_env_file"
temporary_secret_key="$(openssl rand -hex 64)"
temporary_salt_key="$(openssl rand -hex 32)"
cat >"$temporary_env_file" <<EOF
POSTGRES_DB=$temporary_database
POSTGRES_DB_TEST=test_$temporary_database
POSTGRES_USER=$operational_db_user
POSTGRES_PASSWORD=$operational_db_password
POSTGRES_HOST=db
POSTGRES_PORT=5432
POSTGRES_SSLMODE=disable
RUSTFS_ACCESS_KEY=$rustfs_access_key
RUSTFS_SECRET_KEY=$rustfs_secret_key
RUSTFS_CONSOLE_ENABLE=false
RUSTFS_ADDRESS=0.0.0.0:9000
RUSTFS_EXTERNAL_ADDRESS=:9000
AWS_EC2_METADATA_DISABLED=true
DJANGO_ALLOWED_HOSTS=restore-test.invalid
DJANGO_USE_X_FORWARDED_HOST=1
DJANGO_SETTINGS_MODULE=qfieldcloud.settings
SECRET_KEY=$temporary_secret_key
SALT_KEY=$temporary_salt_key
DEBUG=0
ENVIRONMENT=production
SENTRY_DSN=
SENTRY_RELEASE=$backup_release
SENTRY_ENVIRONMENT=restore-test
SENTRY_SAMPLE_RATE=0
LOGGER_SOURCE=app
STORAGES={"default":{"BACKEND":"qfieldcloud.filestorage.backend.QfcS3Boto3Storage","OPTIONS":{"access_key":"$rustfs_access_key","secret_key":"$rustfs_secret_key","bucket_name":"qfieldcloud-local","region_name":"","endpoint_url":"http://rustfs:9000"}}}
STORAGES_PROJECT_DEFAULT_STORAGE=
STORAGES_PROJECT_DEFAULT_ATTACHMENTS_STORAGE=
STORAGE_PROJECT_DEFAULT_ATTACHMENTS_VERSIONED=1
COMPOSE_PROJECT_NAME=qfc-restore-test
QFIELDCLOUD_DEFAULT_NETWORK=$network_name
QFIELDCLOUD_PASSWORD_LOGIN_IS_ENABLED=1
ACCOUNT_EMAIL_VERIFICATION=optional
SOCIALACCOUNT_PROVIDERS={}
EMAIL_HOST=smtp.invalid
EMAIL_USE_TLS=False
EMAIL_USE_SSL=False
EMAIL_PORT=25
EMAIL_HOST_USER=
EMAIL_HOST_PASSWORD=
DEFAULT_FROM_EMAIL=restore-test@localhost.invalid
CORS_ALLOWED_ORIGINS=https://restore-test.invalid
CORS_ALLOW_CREDENTIALS=1
QFIELDCLOUD_HOST=restore-test.invalid
QFIELDCLOUD_ADMIN_URI=admin/
QFIELDCLOUD_WORKER_QFIELDCLOUD_URL=http://restore-test.invalid/api/v1/
QFIELDCLOUD_SUBSCRIPTION_MODEL=subscription.Subscription
QFIELDCLOUD_ACCOUNT_ADAPTER=qfieldcloud.core.adapters.AccountAdapterSignUpClosed
QFIELDCLOUD_AUTH_TOKEN_EXPIRATION_HOURS=1
QFIELDCLOUD_USE_I18N=1
QFIELDCLOUD_DEFAULT_LANGUAGE=en
QFIELDCLOUD_DEFAULT_TIME_ZONE=UTC
QFIELDCLOUD_WORKER_TIMEOUT_S=600
QFIELDCLOUD_QGIS3_IMAGE_NAME=disabled.invalid/qfieldcloud-qgis3:restore-test
QFIELDCLOUD_QGIS4_IMAGE_NAME=disabled.invalid/qfieldcloud-qgis4:restore-test
QFIELDCLOUD_TRANSFORMATION_GRIDS_VOLUME_NAME=qfc-restore-test-unused
EOF

# The pinned QFieldCloud PostGIS container stays running to avoid starting a
# second PostgreSQL process on the 4 GiB lab host. The dump is restored only
# into a generated database whose name is restricted to the restore-test
# namespace. The operational QFieldCloud database and any arboretum PostGIS are
# never selected as a restore target.
failure_stage="isolated-database-restore"
if ! operational_compose exec --no-TTY db \
  pg_restore --list <"$backup_dir/data/database.dump" >/dev/null 2>&1; then
  die "The database dump catalog could not be read in the pinned PostGIS container."
fi
if ! operational_compose exec --no-TTY db \
  createdb --template template0 --username "$operational_db_user" \
    "$temporary_database" >/dev/null 2>&1; then
  die "The generated restore-test database could not be created."
fi
temporary_database_created="true"

if ! operational_compose exec --no-TTY db \
  pg_restore \
    --exit-on-error \
    --single-transaction \
    --no-owner \
    --no-privileges \
    --username "$operational_db_user" \
    --dbname "$temporary_database" \
    <"$backup_dir/data/database.dump" >/dev/null 2>&1; then
  die "The PostgreSQL dump failed its isolated restore validation."
fi

postgis_count="$(
  operational_compose exec --no-TTY db \
    psql --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 \
      --username "$operational_db_user" --dbname "$temporary_database" \
      --command "SELECT count(*) FROM pg_extension WHERE extname = 'postgis';" \
    2>/dev/null | tr -d '\r'
)"
[[ $postgis_count == "1" ]] \
  || die "The restored database does not contain exactly one PostGIS extension."

migration_count="$(
  operational_compose exec --no-TTY db \
    psql --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 \
      --username "$operational_db_user" --dbname "$temporary_database" \
      --command "SELECT count(*) FROM public.django_migrations;" \
    2>/dev/null | tr -d '\r'
)"
[[ $migration_count =~ ^[0-9]+$ ]] && ((migration_count > 0)) \
  || die "The restored database has no Django migration history."

qfieldcloud_table_count="$(
  operational_compose exec --no-TTY db \
    psql --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 \
      --username "$operational_db_user" --dbname "$temporary_database" \
      --command "SELECT count(*) FROM pg_class WHERE oid IN (to_regclass('public.django_migrations'), to_regclass('public.core_user'));" \
    2>/dev/null | tr -d '\r'
)"
[[ $qfieldcloud_table_count == "2" ]] \
  || die "The restored database is missing required QFieldCloud tables."

operational_compose exec --no-TTY db \
  psql --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 \
    --username "$operational_db_user" --dbname "$temporary_database" \
    --command "SELECT postgis_full_version();" >/dev/null 2>&1 \
  || die "The restored PostGIS extension did not pass its version query."

failure_stage="isolated-object-storage-restore"
docker run --detach \
  --memory 384m \
  --memory-swap 384m \
  --name "$rustfs_container" \
  --label "$resource_label_key=$run_id" \
  --network "$network_name" \
  --network-alias rustfs \
  --env-file "$temporary_env_file" \
  --mount "type=volume,source=$rustfs_volume,target=/data" \
  "$rustfs_image" >/dev/null

rustfs_ready="false"
for _ in $(seq 1 90); do
  if docker exec "$rustfs_container" \
    curl --fail --silent --show-error http://localhost:9000/health \
    >/dev/null 2>&1; then
    rustfs_ready="true"
    break
  fi
  sleep 2
done
[[ $rustfs_ready == "true" ]] || die "The temporary RustFS did not become ready."

failure_stage="application-migration-validation"
if ! docker run --rm \
  --memory 512m \
  --memory-swap 512m \
  --name "$app_check_container" \
  --label "$resource_label_key=$run_id" \
  --network "$network_name" \
  --env-file "$temporary_env_file" \
  --entrypoint python \
  "$app_image" \
  manage.py migrate --check >/dev/null 2>&1; then
  die "The restored database is not at the migration level expected by its pinned QFieldCloud app image."
fi

failure_stage="object-storage-api-validation"
if ! docker run --rm \
  --memory 512m \
  --memory-swap 512m \
  --name "$storage_check_container" \
  --label "$resource_label_key=$run_id" \
  --network "$network_name" \
  --env-file "$temporary_env_file" \
  --entrypoint python \
  "$app_image" \
  -c '
import os

import boto3
from botocore.config import Config

bucket_name = "qfieldcloud-local"
client = boto3.client(
    "s3",
    endpoint_url="http://rustfs:9000",
    aws_access_key_id=os.environ["RUSTFS_ACCESS_KEY"],
    aws_secret_access_key=os.environ["RUSTFS_SECRET_KEY"],
    region_name="us-east-1",
    config=Config(
        signature_version="s3v4",
        connect_timeout=5,
        read_timeout=30,
        retries={"max_attempts": 3, "mode": "standard"},
        s3={"addressing_style": "path"},
    ),
)

client.head_bucket(Bucket=bucket_name)
if client.get_bucket_versioning(Bucket=bucket_name).get("Status") != "Enabled":
    raise SystemExit("bucket versioning is not enabled")

for _page in client.get_paginator("list_objects_v2").paginate(Bucket=bucket_name):
    pass

sample = None
for page in client.get_paginator("list_object_versions").paginate(Bucket=bucket_name):
    if sample is None and page.get("Versions"):
        version = page["Versions"][0]
        sample = (version["Key"], version["VersionId"], version["Size"])

if sample is not None:
    key, version_id, size = sample
    request = {"Bucket": bucket_name, "Key": key, "VersionId": version_id}
    if size > 0:
        request["Range"] = "bytes=0-0"
    response = client.get_object(**request)
    body = response["Body"]
    body.read(1)
    body.close()
' >/dev/null 2>&1; then
  die "The restored RustFS bucket failed its isolated API validation."
fi

failure_stage="cleanup"
if ! cleanup; then
  die "Validation passed, but one or more temporary Docker resources could not be removed. No success marker was written."
fi
cleanup_status="passed"
trap - EXIT

failure_stage="success-marker-write"
restore_test_completed_at="$(date -u +%FT%TZ)"
rm -f -- "$state_dir/last-restore-test-failure" \
  || die "Restore validation passed, but the previous failure marker could not be cleared."
write_state_marker last-restore-test-checksum-set-sha256 "$checksums_file_sha256" \
  || die "Temporary resources were removed, but the checksum-set success marker could not be written."
write_state_marker last-restore-test-backup "$latest_backup_name" \
  || die "Temporary resources were removed, but the backup-name success marker could not be written."
write_state_marker last-restore-test-at "$restore_test_completed_at" \
  || die "Temporary resources were removed, but the timestamp success marker could not be written."

echo "Schema and storage integrity restore test passed for backup: $backup_dir"
echo "Checksums, PostgreSQL/PostGIS, RustFS versioned storage, and the media archive were validated."
echo "Only labeled temporary Docker resources were used and removed; operational volumes were not attached."
echo "This is not a separate-host application or worker disaster-recovery rehearsal."
