#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

if [[ $EUID -ne 0 ]]; then
  echo "Run this command with sudo on the Lightsail instance." >&2
  exit 1
fi

install_root="${QFC_INSTALL_ROOT:-/opt/qfieldcloud}"
backup_root="${QFC_BACKUP_ROOT:-/var/backups/qfieldcloud}"
if [[ ! $install_root =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ $install_root == "/" ]] || \
  [[ $install_root == *"//"* ]] || [[ $install_root == *"/../"* ]] || \
  [[ ! $backup_root =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ $backup_root == "/" ]] || \
  [[ $backup_root == *"//"* ]] || [[ $backup_root == *"/../"* ]]; then
  echo "The install and backup roots must be safe absolute paths other than /." >&2
  exit 1
fi

for required_command in awk chmod date df docker du flock install jq ln mktemp mv \
  readlink realpath rm seq sha256sum sleep stat tar tr; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command is unavailable: $required_command" >&2
    exit 1
  fi
done

state_dir="$install_root/state"
versions_file="$install_root/versions.env"
runtime_env="$state_dir/runtime.env"
compose_file="$install_root/compose.yaml"
secrets_file="$state_dir/secrets.env"
public_host_file="$state_dir/public-host"
health_check_file="$install_root/bin/health-check.sh"

if [[ ! -d $install_root || -L $install_root ]] || \
  [[ $(realpath -e "$install_root") != "$install_root" ]] || \
  [[ ! -d $state_dir || -L $state_dir ]] || \
  [[ $(realpath -e "$state_dir") != "$state_dir" ]]; then
  echo "The trusted QFieldCloud installation directories are unavailable." >&2
  exit 1
fi

for required_file in "$versions_file" "$runtime_env" "$compose_file" \
  "$secrets_file" "$public_host_file" "$health_check_file"; do
  if [[ ! -f $required_file || -L $required_file ]]; then
    echo "Required installation state is missing: $required_file" >&2
    exit 1
  fi
done
if [[ ! -x $health_check_file ]]; then
  echo "The installed health-check helper is not executable." >&2
  exit 1
fi

install -m 0700 -d "$backup_root"
if [[ -L $backup_root ]] || [[ $(realpath -e "$backup_root") != "$backup_root" ]]; then
  echo "The backup root must be a canonical directory, not a symbolic link." >&2
  exit 1
fi

# This file contains only non-secret version constants.
# shellcheck disable=SC1090
source "$versions_file"

compose() {
  docker compose \
    --env-file "$versions_file" \
    --env-file "$runtime_env" \
    --file "$compose_file" \
    "$@"
}

public_host="$(<"$public_host_file")"
if [[ ! $public_host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  echo "The installed public host is invalid." >&2
  exit 1
fi
docker info >/dev/null 2>&1 || {
  echo "Docker is not running." >&2
  exit 1
}
docker compose version >/dev/null 2>&1 || {
  echo "Docker Compose is unavailable." >&2
  exit 1
}
compose config --quiet || {
  echo "The pinned operational Compose configuration is invalid." >&2
  exit 1
}
if ! "$health_check_file" --service-only >/dev/null 2>&1; then
  echo "The operational QFieldCloud services are not healthy; no backup was started." >&2
  exit 1
fi

maintenance_lock_file="/var/lock/qfieldcloud-maintenance.lock"
inherited_lock="false"
if [[ ${QFC_MAINTENANCE_LOCK_FD:-} == "8" ]] && [[ -e /proc/$$/fd/8 ]] && \
  [[ $(readlink -f /proc/$$/fd/8) == "$(readlink -f "$maintenance_lock_file")" ]]; then
  inherited_lock="true"
fi
if [[ $inherited_lock != "true" ]]; then
  exec 8>"$maintenance_lock_file"
  if ! flock -n 8; then
    echo "Another QFieldCloud maintenance operation is already running." >&2
    exit 1
  fi
  export QFC_MAINTENANCE_LOCK_FD=8
fi

exec 9>/var/lock/qfieldcloud-backup.lock
if ! flock -n 9; then
  echo "Another QFieldCloud backup is already running." >&2
  exit 1
fi

recovery_required_file="$install_root/state/recovery-required"
if [[ -e $recovery_required_file || -L $recovery_required_file ]]; then
  echo "An unresolved recovery-required marker already exists; backup is blocked before changing any success marker." >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
created_at_utc="$(date -u +%FT%TZ)"
final_dir="$backup_root/${timestamp}-${QFIELDCLOUD_RELEASE}"
partial_dir="$final_dir.partial"
if [[ -e $final_dir || -e $partial_dir ]]; then
  echo "Backup target already exists; refusing to overwrite it." >&2
  exit 1
fi

services_quiesced="false"
backup_completed="false"
worker_quiesce_blocked="false"
recovery_marker_owned="false"
recovery_marker_identity=""
write_recovery_required() {
  local reason="$1"
  local marker_tmp=""
  local current_identity=""

  if [[ $recovery_marker_owned == "true" ]]; then
    if [[ ! -f $recovery_required_file || -L $recovery_required_file ]]; then
      echo "Refusing to replace a recovery marker not owned by this backup." >&2
      return 1
    fi
    current_identity="$(stat --format '%d:%i' -- "$recovery_required_file")" || return 1
    if [[ $current_identity != "$recovery_marker_identity" ]]; then
      echo "Refusing to replace a recovery marker changed outside this backup." >&2
      return 1
    fi
    return 0
  elif [[ -e $recovery_required_file || -L $recovery_required_file ]]; then
    echo "Refusing to overwrite an existing recovery-required marker." >&2
    return 1
  fi

  marker_tmp="$(mktemp "$install_root/state/.recovery-required.backup.XXXXXX")" \
    || return 1
  if ! {
    printf 'operation=backup\n'
    printf 'detected_at_utc=%s\n' "$(date -u +%FT%TZ)"
    printf 'reason=%s\n' "$reason"
    printf 'manual_command=docker compose --env-file %s --env-file %s --file %s up -d\n' \
      "$versions_file" "$runtime_env" "$compose_file"
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
restart_services() {
  local recovery_ok="false"
  if [[ $services_quiesced == "true" ]]; then
    if compose up -d db rustfs smtp4dev memcached app nginx worker_wrapper ofelia >/dev/null; then
      for _ in $(seq 1 36); do
        if "$install_root/bin/health-check.sh" --service-only >/dev/null 2>&1; then
          recovery_ok="true"
          break
        fi
        sleep 10
      done
    fi
    if [[ $recovery_ok != "true" ]]; then
      write_recovery_required "service-recovery-not-confirmed"
      echo "Backup recovery could not confirm all services. Inspect $install_root/state/recovery-required and restart the pinned Compose stack manually." >&2
      return 1
    fi
    if [[ $worker_quiesce_blocked != "true" ]]; then
      remove_owned_recovery_marker || return 1
    fi
  fi
}
on_exit() {
  local exit_code=$?
  local artifact_path=""
  local artifact_state="not-created"
  local failure_marker_tmp=""
  set +e
  if [[ $exit_code -ne 0 ]] && [[ $backup_completed != "true" ]]; then
    if [[ -d $final_dir && ! -L $final_dir ]]; then
      artifact_state="finalized-not-published"
      artifact_path="$final_dir"
    elif [[ -e $final_dir || -L $final_dir ]]; then
      artifact_state="unexpected-final-path-type"
      artifact_path="$final_dir"
    elif [[ -d $partial_dir && ! -L $partial_dir ]]; then
      artifact_state="partial"
      artifact_path="$partial_dir"
    elif [[ -e $partial_dir || -L $partial_dir ]]; then
      artifact_state="unexpected-partial-path-type"
      artifact_path="$partial_dir"
    fi
    failure_marker_tmp="$(mktemp "$state_dir/.last-backup-failure.XXXXXX")"
    if [[ -n $failure_marker_tmp ]] && {
      printf 'operation=backup\n'
      printf 'failed_at_utc=%s\n' "$(date -u +%FT%TZ)"
      printf 'artifact_state=%s\n' "$artifact_state"
      printf 'artifact_path=%s\n' "$artifact_path"
      printf 'automatic_cleanup=false\n'
      printf 'review_before_manual_removal=true\n'
    } >"$failure_marker_tmp" \
      && chmod 0600 "$failure_marker_tmp" \
      && mv -f -- "$failure_marker_tmp" "$state_dir/last-backup-failure"; then
      failure_marker_tmp=""
    else
      rm -f -- "$failure_marker_tmp"
      echo "The backup failed and its failure marker could not be written safely." >&2
    fi
    case "$artifact_state" in
      partial)
        echo "A partial backup was preserved for diagnosis and was not deleted automatically." >&2
        ;;
      finalized-not-published)
        echo "A finalized backup directory exists, but success markers were not published; inspect it before use." >&2
        ;;
      unexpected-*)
        echo "An unexpected backup artifact path type exists; it was preserved and requires manual inspection." >&2
        ;;
      *)
        echo "The backup failed before any backup artifact directory was created." >&2
        ;;
    esac
  fi
  restart_services || true
  exit "$exit_code"
}
trap on_exit EXIT

rm -f -- "$install_root/state/last-backup-at" "$install_root/state/last-backup-path"

rustfs_mount="$(docker volume inspect --format '{{ .Mountpoint }}' qfieldcloud_rustfs_data)"
media_mount="$(docker volume inspect --format '{{ .Mountpoint }}' qfieldcloud_media)"
if [[ $rustfs_mount != /* ]] || [[ $media_mount != /* ]] || \
  [[ $rustfs_mount == "/" ]] || [[ $media_mount == "/" ]] || \
  [[ ! -d $rustfs_mount ]] || [[ ! -d $media_mount ]]; then
  echo "Expected Docker volume mountpoint is missing or unsafe." >&2
  exit 1
fi

source_database_bytes="$(compose exec -T db \
  psql --username qfieldcloud_db_admin --dbname qfieldcloud_db \
  --tuples-only --no-align --set ON_ERROR_STOP=1 \
  --command "SELECT pg_database_size('qfieldcloud_db');" | tr -d '[:space:]')"
source_object_storage_bytes="$(du --summarize --bytes "$rustfs_mount" | awk '{print $1}')"
source_media_bytes="$(du --summarize --bytes "$media_mount" | awk '{print $1}')"
available_backup_bytes="$(df --output=avail -B1 "$backup_root" | awk 'NR == 2 {print $1}')"
for size_value in "$source_database_bytes" "$source_object_storage_bytes" \
  "$source_media_bytes" "$available_backup_bytes"; do
  if [[ ! $size_value =~ ^[0-9]+$ ]]; then
    echo "Backup size preflight returned an invalid value." >&2
    exit 1
  fi
done
required_backup_bytes=$((
  source_database_bytes + source_object_storage_bytes + source_media_bytes + 1073741824
))
if ((available_backup_bytes < required_backup_bytes)); then
  echo "The backup target does not have enough free space for a conservative local backup." >&2
  echo "No service was stopped and no existing backup was deleted." >&2
  exit 1
fi
install -m 0700 -d "$partial_dir" "$partial_dir/data" "$partial_dir/sensitive"

echo "Stopping public writes and waiting for the single worker before backup."
services_quiesced="true"
compose stop nginx ofelia
compose stop --timeout 900 worker_wrapper
if ! running_worker_children="$(
  docker container ls \
    --filter 'label=app=production_worker' \
    --format '{{.ID}}'
)"; then
  worker_quiesce_blocked="true"
  write_recovery_required "production-worker-enumeration-failed"
  echo "Docker could not prove that every QGIS worker child stopped; backup is blocked." >&2
  exit 1
fi
if [[ -n $running_worker_children ]]; then
  worker_quiesce_blocked="true"
  write_recovery_required "production-worker-still-running-after-wrapper-stop"
  echo "A QGIS worker child is still running after worker_wrapper stopped; backup is blocked." >&2
  echo "No application, database, or storage backup step was started. Inspect the root-only recovery-required marker." >&2
  exit 1
fi
compose stop app

compose exec -T db pg_dump \
  --username qfieldcloud_db_admin \
  --dbname qfieldcloud_db \
  --format custom >"$partial_dir/data/database.dump"
if [[ ! -s $partial_dir/data/database.dump ]] || \
  ! compose exec -T db pg_restore --list <"$partial_dir/data/database.dump" >/dev/null; then
  echo "The streamed PostgreSQL backup is empty or unreadable." >&2
  exit 1
fi
chmod 0600 "$partial_dir/data/database.dump"

compose stop rustfs
source_database_bytes="$(compose exec -T db \
  psql --username qfieldcloud_db_admin --dbname qfieldcloud_db \
  --tuples-only --no-align --set ON_ERROR_STOP=1 \
  --command "SELECT pg_database_size('qfieldcloud_db');" | tr -d '[:space:]')"
source_object_storage_bytes="$(du --summarize --bytes "$rustfs_mount" | awk '{print $1}')"
source_media_bytes="$(du --summarize --bytes "$media_mount" | awk '{print $1}')"
available_backup_bytes="$(df --output=avail -B1 "$backup_root" | awk 'NR == 2 {print $1}')"
for size_value in "$source_database_bytes" "$source_object_storage_bytes" \
  "$source_media_bytes" "$available_backup_bytes"; do
  if [[ ! $size_value =~ ^[0-9]+$ ]]; then
    echo "Quiesced backup size check returned an invalid value; services will be restarted." >&2
    exit 1
  fi
done
required_backup_bytes=$((
  source_database_bytes + source_object_storage_bytes + source_media_bytes + 1073741824
))
if ((available_backup_bytes < required_backup_bytes)); then
  echo "Free space became insufficient after writes were quiesced; services will be restarted." >&2
  exit 1
fi

tar --numeric-owner --xattrs --acls -czf "$partial_dir/data/object-storage.tar.gz" -C "$rustfs_mount" .
tar --numeric-owner --xattrs --acls -czf "$partial_dir/data/media.tar.gz" -C "$media_mount" .
chmod 0600 "$partial_dir/data/object-storage.tar.gz" "$partial_dir/data/media.tar.gz"

install -m 0600 "$secrets_file" "$partial_dir/sensitive/secrets.env"
install -m 0600 "$versions_file" "$partial_dir/versions.env"
install -m 0600 "$compose_file" "$partial_dir/compose.yaml"
printf '%s\n' "$(<"$install_root/state/public-host")" >"$partial_dir/public-host"
chmod 0600 "$partial_dir/public-host"

(
  cd "$partial_dir"
  sha256sum \
    data/database.dump \
    data/object-storage.tar.gz \
    data/media.tar.gz \
    sensitive/secrets.env \
    versions.env \
    compose.yaml \
    public-host >SHA256SUMS
)
chmod 0600 "$partial_dir/SHA256SUMS"

jq -cn \
  --arg created_at "$created_at_utc" \
  --arg release "$QFIELDCLOUD_RELEASE" \
  --arg commit "$QFIELDCLOUD_COMMIT" \
  --arg scope "qfieldcloud-system-only" \
  --argjson database_bytes "$source_database_bytes" \
  --argjson object_storage_bytes "$source_object_storage_bytes" \
  --argjson media_bytes "$source_media_bytes" \
  '{
    created_at_utc: $created_at,
    release: $release,
    upstream_commit: $commit,
    scope: $scope,
    includes: ["database", "object-storage", "media", "separate-root-only-secrets"],
    excludes: ["existing-arboretum-postgis", "docker-images", "logs"],
    source_sizes_bytes: {
      database: $database_bytes,
      object_storage: $object_storage_bytes,
      media: $media_bytes
    },
    retention: "manual-no-automatic-deletion",
    independent_file_encryption: false,
    off_instance_copy_created: false
  }' >"$partial_dir/manifest.json"
chmod 0600 "$partial_dir/manifest.json"
(
  cd "$partial_dir"
  sha256sum manifest.json >>SHA256SUMS
  sha256sum --check SHA256SUMS >/dev/null
)

mv "$partial_dir" "$final_dir"
compose up -d db rustfs smtp4dev memcached app nginx worker_wrapper ofelia >/dev/null
health_ready="false"
for _ in $(seq 1 36); do
  if "$install_root/bin/health-check.sh" --service-only >/dev/null 2>&1; then
    health_ready="true"
    break
  fi
  sleep 10
done
if [[ $health_ready != "true" ]]; then
  echo "Backup completed, but the service did not return to a healthy state." >&2
  exit 1
fi
services_quiesced="false"

backup_path_marker_tmp="$(mktemp "$install_root/state/last-backup-path.XXXXXX")"
backup_at_marker_tmp="$(mktemp "$install_root/state/last-backup-at.XXXXXX")"
printf '%s\n' "$final_dir" >"$backup_path_marker_tmp"
printf '%s\n' "$created_at_utc" >"$backup_at_marker_tmp"
chmod 0600 "$backup_path_marker_tmp" "$backup_at_marker_tmp"
rm -f -- "$install_root/state/last-backup-failure"
mv -f "$backup_path_marker_tmp" "$install_root/state/last-backup-path"
mv -f "$backup_at_marker_tmp" "$install_root/state/last-backup-at"
backup_completed="true"
trap - EXIT

echo "Backup created at $final_dir"
echo "This local backup still depends on the instance disk; create and test an approved off-instance copy before relying on it."
