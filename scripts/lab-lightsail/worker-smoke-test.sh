#!/usr/bin/env bash

set -Eeuo pipefail
set +x
umask 077

if [[ $EUID -ne 0 ]]; then
  echo "Run this command with sudo on the Lightsail instance." >&2
  exit 1
fi

install_root="${QFC_INSTALL_ROOT:-/opt/qfieldcloud}"
versions_file="$install_root/versions.env"
runtime_env="$install_root/state/runtime.env"
compose_file="$install_root/compose.yaml"
secrets_file="$install_root/state/secrets.env"
public_host_file="$install_root/state/public-host"
certificate_mode_file="$install_root/state/certificate-mode"
certificate_file="$install_root/state/certs/current/fullchain.pem"
installer_revision_file="$install_root/state/installer-revision"
smoke_status_file="$install_root/state/worker-smoke-status.json"
smoke_owner_file="$install_root/state/worker-smoke-owned-project.json"
smoke_project_name="installer-worker-smoke"
smoke_description_prefix="qfc-installer-worker-smoke"
readonly default_api_timeout_seconds=60
readonly job_poll_request_cap_seconds=20
readonly job_poll_seconds=10
readonly job_wait_timeout_seconds=1200
readonly job_discovery_timeout_seconds=120

for required_file in "$versions_file" "$runtime_env" "$compose_file" "$secrets_file" \
  "$public_host_file" "$certificate_mode_file" "$certificate_file" \
  "$installer_revision_file"; do
  if [[ ! -f $required_file || -L $required_file ]]; then
    echo "Required installation state is missing: $required_file" >&2
    exit 1
  fi
done

# The version file is approved public configuration. Secret values are never
# printed, exported, or evaluated as shell code by this script.
# shellcheck disable=SC1090
source "$versions_file"

ADMIN_USERNAME=""
admin_username_count=0
while IFS= read -r secret_line || [[ -n $secret_line ]]; do
  secret_line="${secret_line%$'\r'}"
  if [[ $secret_line == ADMIN_USERNAME=* ]]; then
    admin_username_count=$((admin_username_count + 1))
    ADMIN_USERNAME="${secret_line#*=}"
  fi
done <"$secrets_file"

if [[ $admin_username_count -ne 1 ]] || [[ ! $ADMIN_USERNAME =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "The generated administrator username format is unexpected." >&2
  exit 1
fi
public_host="$(<"$public_host_file")"
certificate_mode="$(<"$certificate_mode_file")"
if [[ ! $public_host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  echo "The public host state is invalid." >&2
  exit 1
fi
if [[ $certificate_mode != "self-signed" && $certificate_mode != "letsencrypt-ip" ]]; then
  echo "The certificate mode state is invalid." >&2
  exit 1
fi
installer_revision="$(<"$installer_revision_file")"
if [[ ! $installer_revision =~ ^[0-9a-f]{40}$ ]]; then
  echo "The installer revision state is invalid." >&2
  exit 1
fi

compose() {
  docker compose \
    --env-file "$versions_file" \
    --env-file "$runtime_env" \
    --file "$compose_file" \
    "$@"
}

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

for required_lock_command in chmod flock install ln mktemp realpath rm stat; do
  command -v "$required_lock_command" >/dev/null 2>&1 || {
    echo "Required lock command is unavailable: $required_lock_command" >&2
    exit 1
  }
done
prepare_lock_directory || {
  echo "The root-owned QFieldCloud lock directory is missing or unsafe." >&2
  exit 1
}
maintenance_lock_file="$qfc_lock_root/maintenance.lock"
worker_smoke_lock_file="$qfc_lock_root/worker-smoke.lock"
prepare_lock_file "$maintenance_lock_file" || {
  echo "The QFieldCloud maintenance lock file is missing or unsafe." >&2
  exit 1
}
prepare_lock_file "$worker_smoke_lock_file" || {
  echo "The QFieldCloud worker-smoke lock file is missing or unsafe." >&2
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
  echo "Another QFieldCloud maintenance operation is already running." >&2
  exit 1
fi
export QFC_MAINTENANCE_LOCK_FD=8

exec 9>>"$worker_smoke_lock_file"
if ! lock_fd_matches_file 9 "$worker_smoke_lock_file"; then
  echo "The QFieldCloud worker-smoke lock descriptor changed unexpectedly." >&2
  exit 1
fi
if ! flock -n 9; then
  echo "Another worker smoke test is already running." >&2
  exit 1
fi

# Invalidate every prior success before any allocation for this attempt. If a
# later setup step fails, health-check cannot reuse the old passed result.
rm -f -- "$smoke_status_file" \
  "$install_root/state/last-worker-smoke-at" \
  "$install_root/state/last-worker-smoke-project-id"

test_root="$(mktemp -d "$install_root/state/worker-smoke.XXXXXX")"
auth_config="$test_root/curl-auth.conf"
auth_ready="false"
auth_token=""
base_url="https://$public_host/api/v1"
smoke_completed="false"
smoke_started_at="$(date -u +%FT%TZ)"
project_id=""
create_job_id=""
process_job_id=""
package_job_id=""
verified_qgis_version=""
attempt_nonce=""
ownership_description=""
ownership_ready="false"
worker_smoke_deadline=0

write_smoke_status() {
  local status="$1"
  local completed_at="$2"
  local status_tmp=""

  status_tmp="$(mktemp "$install_root/state/worker-smoke-status.XXXXXX")"
  jq -n \
    --arg status "$status" \
    --arg started_at "$smoke_started_at" \
    --arg completed_at "$completed_at" \
    --arg installer_revision "$installer_revision" \
    --arg release "$QFIELDCLOUD_RELEASE" \
    --arg qgis_image "$QFC_QGIS3_IMAGE" \
    --arg qgis_expected_version "$QFC_QGIS3_EXPECTED_VERSION" \
    --arg qgis_reported_version "$verified_qgis_version" \
    --arg project_id "$project_id" \
    --arg job_id "$package_job_id" \
    '{
      status: $status,
      started_at_utc: $started_at,
      completed_at_utc: $completed_at,
      installer_revision: $installer_revision,
      release: $release,
      qgis_image: $qgis_image,
      qgis_expected_version: $qgis_expected_version,
      qgis_reported_version: $qgis_reported_version,
      project_id: $project_id,
      package_job_id: $job_id
    }' >"$status_tmp"
  chmod 0600 "$status_tmp"
  mv -f "$status_tmp" "$smoke_status_file"
}

write_smoke_status running ""

curl_common=(
  --silent
  --show-error
  --fail
  --connect-timeout 5
)
if [[ $certificate_mode == "letsencrypt-ip" ]]; then
  curl_common+=(--connect-to "$public_host:443:127.0.0.1:443")
else
  curl_common+=(--cacert "$certificate_file" --resolve "$public_host:443:127.0.0.1")
fi

api_auth() {
  local timeout_seconds="$1"
  shift

  if [[ ! $timeout_seconds =~ ^[1-9][0-9]*$ ]]; then
    echo "The worker-smoke API timeout is invalid." >&2
    return 2
  fi
  curl "${curl_common[@]}" --max-time "$timeout_seconds" --config "$auth_config" "$@"
}

api_nonce_counter=0
api_get_fresh() {
  local request_url="$1"
  local timeout_seconds="${2:-$default_api_timeout_seconds}"
  local separator="?"
  local request_nonce=""

  api_nonce_counter=$((api_nonce_counter + 1))
  if [[ $request_url == *\?* ]]; then
    separator="&"
  fi
  request_nonce="${attempt_nonce}-${api_nonce_counter}-$(date +%s%N)"
  api_auth "$timeout_seconds" \
    --header 'Cache-Control: no-cache' \
    --header 'Pragma: no-cache' \
    "${request_url}${separator}qfc_smoke_nonce=${request_nonce}"
}

monotonic_seconds() {
  local uptime_seconds=""

  if [[ ! -r /proc/uptime ]]; then
    return 1
  fi
  IFS=' ' read -r uptime_seconds _ </proc/uptime || return 1
  uptime_seconds="${uptime_seconds%%.*}"
  [[ $uptime_seconds =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$uptime_seconds"
}

is_uuid() {
  [[ $1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

write_smoke_owner_marker() {
  local marker_tmp=""

  if [[ -e $smoke_owner_file ]] && \
    { [[ ! -f $smoke_owner_file ]] || [[ -L $smoke_owner_file ]]; }; then
    echo "The worker-smoke ownership marker path is unsafe." >&2
    return 1
  fi
  marker_tmp="$(mktemp "$install_root/state/worker-smoke-owned-project.XXXXXX")" \
    || return 1
  if ! jq -n \
    --arg installer_revision "$installer_revision" \
    --arg release "$QFIELDCLOUD_RELEASE" \
    --arg owner "$ADMIN_USERNAME" \
    --arg name "$smoke_project_name" \
    --arg description "$ownership_description" \
    --arg attempt_nonce "$attempt_nonce" \
    --arg project_id "$project_id" \
    '{
      schema: 1,
      installer_revision: $installer_revision,
      release: $release,
      owner: $owner,
      name: $name,
      description: $description,
      attempt_nonce: $attempt_nonce,
      project_id: $project_id
    }' >"$marker_tmp" \
    || ! chmod 0600 "$marker_tmp" \
    || ! mv -f -- "$marker_tmp" "$smoke_owner_file"; then
    rm -f -- "$marker_tmp"
    return 1
  fi
}

load_smoke_owner_marker() {
  local marker_revision=""
  local marker_release=""
  local marker_owner=""
  local marker_name=""
  local marker_description=""
  local marker_project_id=""

  [[ -f $smoke_owner_file && ! -L $smoke_owner_file ]] || return 1
  marker_revision="$(jq -er '.installer_revision | select(type == "string")' "$smoke_owner_file")" \
    || return 1
  marker_release="$(jq -er '.release | select(type == "string")' "$smoke_owner_file")" \
    || return 1
  marker_owner="$(jq -er '.owner | select(type == "string")' "$smoke_owner_file")" \
    || return 1
  marker_name="$(jq -er '.name | select(type == "string")' "$smoke_owner_file")" \
    || return 1
  marker_description="$(jq -er '.description | select(type == "string")' "$smoke_owner_file")" \
    || return 1
  attempt_nonce="$(jq -er '.attempt_nonce | select(type == "string")' "$smoke_owner_file")" \
    || return 1
  marker_project_id="$(jq -er '.project_id | select(type == "string")' "$smoke_owner_file")" \
    || return 1
  if ! jq -e '.schema == 1' "$smoke_owner_file" >/dev/null 2>&1 \
    || [[ ! $marker_revision =~ ^[0-9a-f]{40}$ ]] \
    || [[ ! $marker_release =~ ^v[0-9]+(\.[0-9]+)+$ ]] \
    || [[ $marker_owner != "$ADMIN_USERNAME" ]] \
    || [[ $marker_name != "$smoke_project_name" ]] \
    || [[ ! $attempt_nonce =~ ^[0-9a-f]{32}$ ]] \
    || [[ $marker_description != "$smoke_description_prefix:$marker_revision:$attempt_nonce" ]] \
    || { [[ -n $marker_project_id ]] && ! is_uuid "$marker_project_id"; }; then
    return 1
  fi
  ownership_description="$marker_description"
  project_id="$marker_project_id"
  ownership_ready="true"
}

create_smoke_owner_marker() {
  attempt_nonce="$(openssl rand -hex 16)" || return 1
  [[ $attempt_nonce =~ ^[0-9a-f]{32}$ ]] || return 1
  ownership_description="$smoke_description_prefix:$installer_revision:$attempt_nonce"
  project_id=""
  ownership_ready="true"
  write_smoke_owner_marker
}

revoke_smoke_token() {
  [[ -n $auth_token ]] || return 0
  printf '%s' "$auth_token" | compose exec -T app python manage.py shell -c '
import sys

from qfieldcloud.authentication.models import AuthToken

token_key = sys.stdin.read()
deleted, _ = AuthToken.objects.filter(
    key=token_key,
    client_type=AuthToken.ClientType.CLI,
    user_agent="qfc-installer-worker-smoke",
).delete()
raise SystemExit(0 if deleted == 1 else 3)
'
}

cleanup_owned_worker_children() {
  local target_project_id="$1"
  local wait_for_late_child="$2"
  local required_empty_checks=2
  local empty_checks=0
  local container_ids=""
  local inspect_output=""
  local inspected_id=""
  local inspected_app=""
  local inspected_job_id=""
  local inspected_project_id=""
  local inspected_running=""

  [[ -n $target_project_id ]] || return 0
  is_uuid "$target_project_id" || return 1
  if [[ $wait_for_late_child == "true" ]]; then
    required_empty_checks=10
  fi

  for _ in $(seq 1 60); do
    if ! container_ids="$(
      docker container ls --all \
        --filter 'label=app=production_worker' \
        --filter "label=project_id=$target_project_id" \
        --format '{{.ID}}'
    )"; then
      echo "Docker could not enumerate worker-smoke child containers." >&2
      return 1
    fi

    if [[ -z $container_ids ]]; then
      empty_checks=$((empty_checks + 1))
      if ((empty_checks >= required_empty_checks)); then
        return 0
      fi
      sleep 1
      continue
    fi
    empty_checks=0

    while IFS= read -r container_id; do
      [[ -n $container_id ]] || continue
      if ! inspect_output="$(
        docker container inspect \
          --format '{{.Id}}|{{index .Config.Labels "app"}}|{{index .Config.Labels "job_id"}}|{{index .Config.Labels "project_id"}}|{{.State.Running}}' \
          "$container_id" 2>/dev/null
      )"; then
        if docker container inspect "$container_id" >/dev/null 2>&1; then
          echo "A worker-smoke child container could not be inspected safely." >&2
          return 1
        fi
        continue
      fi
      IFS='|' read -r inspected_id inspected_app inspected_job_id \
        inspected_project_id inspected_running <<<"$inspect_output"
      if [[ ! $inspected_id =~ ^[0-9a-f]{64}$ ]] \
        || [[ $inspected_app != "production_worker" ]] \
        || ! is_uuid "$inspected_job_id" \
        || [[ $inspected_project_id != "$target_project_id" ]] \
        || [[ $inspected_running != "true" && $inspected_running != "false" ]]; then
        echo "Refusing to remove a container without the exact worker-smoke ownership labels." >&2
        return 1
      fi
      if [[ $inspected_running == "true" ]]; then
        if ! docker container stop --time 30 "$inspected_id" >/dev/null 2>&1 \
          && docker container inspect "$inspected_id" >/dev/null 2>&1; then
          echo "The exact worker-smoke QGIS child could not be stopped." >&2
          return 1
        fi
      fi
      if docker container inspect "$inspected_id" >/dev/null 2>&1 \
        && ! docker container rm --force "$inspected_id" >/dev/null 2>&1; then
        echo "The exact worker-smoke QGIS child could not be removed." >&2
        return 1
      fi
    done <<<"$container_ids"
    sleep 1
  done

  echo "Worker-smoke cleanup could not prove that every exact QGIS child was removed." >&2
  return 1
}

inspect_owned_smoke_project() {
  compose exec -T \
    -e "QFC_SMOKE_ADMIN_USERNAME=$ADMIN_USERNAME" \
    -e "QFC_SMOKE_PROJECT_NAME=$smoke_project_name" \
    -e "QFC_SMOKE_PROJECT_DESCRIPTION=$ownership_description" \
    -e "QFC_SMOKE_PROJECT_ID=$project_id" \
    app python manage.py shell -c '
import json
import os

from django.contrib.auth import get_user_model
from qfieldcloud.project.models import Project

user = get_user_model().objects.get(
    username=os.environ["QFC_SMOKE_ADMIN_USERNAME"],
    is_staff=True,
    is_superuser=True,
)
projects = Project.objects.filter(
    name=os.environ["QFC_SMOKE_PROJECT_NAME"],
    description=os.environ["QFC_SMOKE_PROJECT_DESCRIPTION"],
    owner=user,
    created_by=user,
)
requested_id = os.environ.get("QFC_SMOKE_PROJECT_ID", "")
if requested_id:
    projects = projects.filter(id=requested_id)
count = projects.count()
if count > 1:
    raise SystemExit(40)
if count == 0:
    result = {"state": "absent", "project_id": requested_id, "jobs": []}
else:
    project = projects.get()
    jobs = project.jobs.order_by("created_at")
    if jobs.exclude(created_by=user).exists():
        raise SystemExit(41)
    result = {
        "state": "present",
        "project_id": str(project.id),
        "jobs": [
            {"id": str(job.id), "status": job.status}
            for job in jobs
        ],
    }
print("QFC_SMOKE_INSPECT=" + json.dumps(result, separators=(",", ":")))
'
}

delete_owned_smoke_project() {
  compose exec -T \
    -e "QFC_SMOKE_ADMIN_USERNAME=$ADMIN_USERNAME" \
    -e "QFC_SMOKE_PROJECT_NAME=$smoke_project_name" \
    -e "QFC_SMOKE_PROJECT_DESCRIPTION=$ownership_description" \
    -e "QFC_SMOKE_PROJECT_ID=$project_id" \
    app python manage.py shell -c '
import json
import os

from django.contrib.auth import get_user_model
from django.db import transaction
from qfieldcloud.project.models import Project

user = get_user_model().objects.get(
    username=os.environ["QFC_SMOKE_ADMIN_USERNAME"],
    is_staff=True,
    is_superuser=True,
)
with transaction.atomic():
    projects = Project.objects.select_for_update().filter(
        id=os.environ["QFC_SMOKE_PROJECT_ID"],
        name=os.environ["QFC_SMOKE_PROJECT_NAME"],
        description=os.environ["QFC_SMOKE_PROJECT_DESCRIPTION"],
        owner=user,
        created_by=user,
    )
    count = projects.count()
    if count > 1:
        raise SystemExit(42)
    if count == 0:
        result = {"state": "absent"}
    else:
        project = projects.get()
        if project.jobs.exclude(created_by=user).exists():
            raise SystemExit(43)
        project.delete()
        result = {"state": "deleted"}
print("QFC_SMOKE_DELETE=" + json.dumps(result, separators=(",", ":")))
'
}

cleanup_owned_smoke_project() {
  local inspect_output=""
  local inspect_json=""
  local inspect_state=""
  local inspected_project_id=""
  local had_active_job="false"
  local delete_output=""
  local delete_json=""

  [[ $ownership_ready == "true" ]] || return 0
  if ! inspect_output="$(inspect_owned_smoke_project)"; then
    echo "The installer-owned smoke project could not be identified safely; it was preserved." >&2
    return 1
  fi
  inspect_json="$(sed -n 's/^QFC_SMOKE_INSPECT=//p' <<<"$inspect_output" | tail -n 1)"
  if ! jq -e '
    (.state == "present" or .state == "absent")
    and (.project_id | type == "string")
    and (.jobs | type == "array")
    and all(.jobs[]; (.id | type == "string") and (.status | type == "string"))
  ' >/dev/null 2>&1 <<<"$inspect_json"; then
    echo "The smoke-project ownership inspection returned invalid metadata." >&2
    return 1
  fi
  inspect_state="$(jq -r '.state' <<<"$inspect_json")"
  inspected_project_id="$(jq -r '.project_id' <<<"$inspect_json")"
  if [[ -n $inspected_project_id ]]; then
    is_uuid "$inspected_project_id" || return 1
    if [[ -n $project_id && $project_id != "$inspected_project_id" ]]; then
      echo "The smoke-project identifier changed; refusing cleanup." >&2
      return 1
    fi
    project_id="$inspected_project_id"
    write_smoke_owner_marker || return 1
  fi
  if jq -e 'any(.jobs[]; .status == "pending" or .status == "queued" or .status == "started")' \
    >/dev/null 2>&1 <<<"$inspect_json"; then
    had_active_job="true"
  fi

  if [[ $inspect_state == "present" ]]; then
    if ! delete_output="$(delete_owned_smoke_project)"; then
      echo "The exact installer-owned smoke project could not be canceled and deleted." >&2
      return 1
    fi
    delete_json="$(sed -n 's/^QFC_SMOKE_DELETE=//p' <<<"$delete_output" | tail -n 1)"
    if ! jq -e '.state == "deleted" or .state == "absent"' \
      >/dev/null 2>&1 <<<"$delete_json"; then
      echo "The smoke-project deletion returned invalid metadata." >&2
      return 1
    fi
  elif [[ -n $project_id ]]; then
    # A prior process may have exited after deleting the database rows but
    # before a just-dequeued wrapper created its child. Keep watching the exact
    # project label long enough to catch and remove that late child.
    had_active_job="true"
  fi

  cleanup_owned_worker_children "$project_id" "$had_active_job" || return 1
  rm -f -- "$smoke_owner_file" || return 1
  ownership_ready="false"
}

cleanup() {
  local exit_code=$?
  local ownership_cleanup_failed="false"
  set +e
  if [[ $ownership_ready == "true" ]]; then
    cleanup_owned_smoke_project || ownership_cleanup_failed="true"
  fi
  if [[ $auth_ready == "true" ]]; then
    revoke_smoke_token >/dev/null 2>&1 || true
  fi
  if [[ $test_root == "$install_root/state/worker-smoke."* ]] && [[ -d $test_root ]]; then
    rm -rf -- "$test_root"
  fi
  if [[ $exit_code -ne 0 ]] && [[ $smoke_completed != "true" ]]; then
    write_smoke_status failed "$(date -u +%FT%TZ)" >/dev/null 2>&1 || true
  fi
  if [[ $ownership_cleanup_failed == "true" ]]; then
    exit_code=1
  fi
  exit "$exit_code"
}
trap cleanup EXIT

if ! "$install_root/bin/health-check.sh" --service-only >/dev/null; then
  echo "The service health check must pass before starting a worker smoke test." >&2
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "OpenSSL is required to create a unique worker-smoke ownership nonce." >&2
  exit 1
fi

if [[ -e $smoke_owner_file ]]; then
  if ! load_smoke_owner_marker; then
    echo "A worker-smoke ownership marker is invalid; no project or job was changed." >&2
    exit 1
  fi
  echo "Recovering the exact installer-owned project from an interrupted worker smoke test."
  if ! cleanup_owned_smoke_project; then
    echo "Interrupted worker-smoke cleanup is incomplete; refusing to create another project." >&2
    exit 1
  fi
fi
if ! create_smoke_owner_marker; then
  echo "A root-only worker-smoke ownership marker could not be created." >&2
  exit 1
fi

token_output="$(compose exec -T \
  -e "QFC_SMOKE_ADMIN_USERNAME=$ADMIN_USERNAME" \
  app python manage.py shell -c '
import os
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.utils import timezone
from qfieldcloud.authentication.models import AuthToken

user = get_user_model().objects.get(
    username=os.environ["QFC_SMOKE_ADMIN_USERNAME"],
    is_staff=True,
    is_superuser=True,
)
AuthToken.objects.filter(
    user=user,
    client_type=AuthToken.ClientType.CLI,
    user_agent="qfc-installer-worker-smoke",
).delete()
token = AuthToken.objects.create(
    user=user,
    client_type=AuthToken.ClientType.CLI,
    user_agent="qfc-installer-worker-smoke",
    expires_at=timezone.now() + timedelta(hours=1),
)
print("QFC_SMOKE_TOKEN=" + token.key)
')"
auth_token="$(sed -n 's/^QFC_SMOKE_TOKEN=//p' <<<"$token_output" | tail -n 1)"
unset token_output
if [[ -n $auth_token ]]; then
  auth_ready="true"
fi
if [[ ! $auth_token =~ ^[A-Za-z0-9]+$ ]]; then
  echo "The API returned an invalid temporary authentication token." >&2
  exit 1
fi
printf 'header = "Authorization: Token %s"\n' "$auth_token" >"$auth_config"
chmod 0600 "$auth_config"

if ! worker_smoke_started_monotonic="$(monotonic_seconds)"; then
  echo "A monotonic clock is unavailable for the shared worker-smoke deadline." >&2
  exit 1
fi
worker_smoke_deadline=$((worker_smoke_started_monotonic + job_wait_timeout_seconds))

projects_json="$(api_get_fresh "$base_url/projects/?search=$smoke_project_name&limit=100")"
matching_projects="$(jq -c \
  --arg name "$smoke_project_name" \
  --arg owner "$ADMIN_USERNAME" \
  --arg description "$ownership_description" \
  '[.[] | select(.name == $name and .owner == $owner and .description == $description)]' \
  <<<"$projects_json")"
colliding_project_count="$(jq -r \
  --arg name "$smoke_project_name" \
  --arg owner "$ADMIN_USERNAME" \
  '[.[] | select(.name == $name and .owner == $owner)] | length' \
  <<<"$projects_json")"
project_count="$(jq -r 'length' <<<"$matching_projects")"
if [[ $project_count == "0" ]]; then
  if [[ $colliding_project_count != "0" ]]; then
    echo "A same-name project without this attempt's ownership nonce already exists; it was not changed." >&2
    exit 1
  fi
  project_request="$test_root/project.json"
  jq -n \
    --arg name "$smoke_project_name" \
    --arg owner "$ADMIN_USERNAME" \
    --arg description "$ownership_description" \
    '{
      name: $name,
      owner: $owner,
      description: $description,
      is_public: false,
      seed: {
        basemap_provider: "none",
        extent: "126.90,37.40,127.10,37.60"
      }
    }' >"$project_request"
  project_json="$(api_auth "$default_api_timeout_seconds" \
    --request POST \
    --header 'Content-Type: application/json' \
    --data-binary "@$project_request" \
    "$base_url/projects/")"
  created_project_id="$(jq -er '.id | select(type == "string")' <<<"$project_json")"
  if ! is_uuid "$created_project_id" \
    || ! jq -e \
      --arg id "$created_project_id" \
      --arg name "$smoke_project_name" \
      --arg owner "$ADMIN_USERNAME" \
      --arg description "$ownership_description" \
      '.id == $id and .name == $name and .owner == $owner and .description == $description' \
      >/dev/null 2>&1 <<<"$project_json"; then
    echo "The created worker-smoke project did not return the exact ownership metadata." >&2
    exit 1
  fi
  project_id="$created_project_id"
  write_smoke_owner_marker || {
    echo "The worker-smoke project identifier could not be saved safely." >&2
    exit 1
  }

else
  if [[ $project_count != "1" ]]; then
    echo "More than one exact worker smoke project was returned; refusing to guess." >&2
    exit 1
  fi
  recovered_project_id="$(jq -er '.[0].id | select(type == "string")' <<<"$matching_projects")"
  if ! is_uuid "$recovered_project_id"; then
    echo "The recovered worker-smoke project identifier is invalid." >&2
    exit 1
  fi
  project_id="$recovered_project_id"
  write_smoke_owner_marker || {
    echo "The recovered worker-smoke project identifier could not be saved safely." >&2
    exit 1
  }
fi
if ! is_uuid "$project_id"; then
  echo "The worker smoke project identifier is invalid." >&2
  exit 1
fi

while :; do
  if ! discovery_now="$(monotonic_seconds)"; then
    echo "The monotonic clock failed during create-project job discovery." >&2
    exit 1
  fi
  discovery_remaining=$((worker_smoke_deadline - discovery_now))
  ((discovery_remaining > 0)) || break
  discovery_request_timeout=$job_poll_request_cap_seconds
  if ((discovery_remaining < discovery_request_timeout)); then
    discovery_request_timeout=$discovery_remaining
  fi
  jobs_json="$(api_get_fresh \
    "$base_url/jobs/?project_id=$project_id" "$discovery_request_timeout")"
  matching_create_jobs="$(jq -c --arg project_id "$project_id" '
    [.[] | select(.project_id == $project_id and .type == "create_project")]
  ' <<<"$jobs_json")"
  create_job_count="$(jq -r 'length' <<<"$matching_create_jobs")"
  if [[ ! $create_job_count =~ ^[0-9]+$ ]] || ((create_job_count > 1)); then
    echo "The seed project did not return exactly one create-project worker job." >&2
    exit 1
  fi
  if ((create_job_count == 1)); then
    create_job_id="$(jq -er '.[0].id | select(type == "string")' \
      <<<"$matching_create_jobs")"
    break
  fi
  if ! discovery_now="$(monotonic_seconds)"; then
    echo "The monotonic clock failed during create-project job discovery." >&2
    exit 1
  fi
  discovery_remaining=$((worker_smoke_deadline - discovery_now))
  ((discovery_remaining > 0)) || break
  discovery_sleep_seconds=$job_poll_seconds
  if ((discovery_remaining < discovery_sleep_seconds)); then
    discovery_sleep_seconds=$discovery_remaining
  fi
  sleep "$discovery_sleep_seconds"
done
if ! is_uuid "$create_job_id"; then
  echo "The seed project did not create one valid worker job before the shared deadline." >&2
  exit 1
fi

wait_for_job() {
  local job_id="$1"
  local job_label="$2"
  local deadline="$3"
  local job_json=""
  local job_status=""
  local now=0
  local remaining=0
  local request_timeout=0
  local sleep_seconds=0

  if [[ ! $deadline =~ ^[0-9]+$ ]] || ! is_uuid "$job_id"; then
    echo "The $job_label worker deadline input is invalid." >&2
    return 1
  fi
  if ! now="$(monotonic_seconds)"; then
    echo "A monotonic clock is unavailable for the $job_label worker deadline." >&2
    return 1
  fi
  while :; do
    if ! now="$(monotonic_seconds)"; then
      echo "The monotonic clock failed during the $job_label worker wait." >&2
      return 1
    fi
    remaining=$((deadline - now))
    ((remaining > 0)) || break
    request_timeout=$job_poll_request_cap_seconds
    if ((remaining < request_timeout)); then
      request_timeout=$remaining
    fi
    job_json="$(api_get_fresh "$base_url/jobs/$job_id/" "$request_timeout")"
    job_status="$(jq -er '.status | select(type == "string")' <<<"$job_json")"
    case "$job_status" in
      finished)
        return 0
        ;;
      failed | stopped)
        echo "$job_label worker job ended with status $job_status." >&2
        return 1
        ;;
      pending | queued | started)
        if ! now="$(monotonic_seconds)"; then
          echo "The monotonic clock failed during the $job_label worker wait." >&2
          return 1
        fi
        remaining=$((deadline - now))
        ((remaining > 0)) || break
        sleep_seconds=$job_poll_seconds
        if ((remaining < sleep_seconds)); then
          sleep_seconds=$remaining
        fi
        sleep "$sleep_seconds"
        ;;
      *)
        echo "$job_label worker job returned an unexpected status." >&2
        return 1
        ;;
    esac
  done
  echo "$job_label worker job did not finish before the shared 20-minute worker-smoke deadline." >&2
  return 1
}

wait_for_single_project_job_type() {
  local target_project_id="$1"
  local source_job_id="$2"
  local job_type="$3"
  local job_label="$4"
  local shared_deadline="$5"
  local deadline=0
  local jobs_json=""
  local matching_jobs=""
  local matching_count=0
  local matching_job_id=""
  local now=0
  local remaining=0
  local request_timeout=0
  local sleep_seconds=0

  if ! is_uuid "$target_project_id" || ! is_uuid "$source_job_id" \
    || [[ ! $job_type =~ ^[a-z_]+$ ]] \
    || [[ ! $shared_deadline =~ ^[0-9]+$ ]]; then
    echo "The $job_label worker discovery input is invalid." >&2
    return 1
  fi
  if ! now="$(monotonic_seconds)"; then
    echo "A monotonic clock is unavailable for the $job_label discovery deadline." >&2
    return 1
  fi
  deadline=$((now + job_discovery_timeout_seconds))
  if ((shared_deadline < deadline)); then
    deadline=$shared_deadline
  fi
  while :; do
    if ! now="$(monotonic_seconds)"; then
      echo "The monotonic clock failed during $job_label discovery." >&2
      return 1
    fi
    remaining=$((deadline - now))
    ((remaining > 0)) || break
    request_timeout=$job_poll_request_cap_seconds
    if ((remaining < request_timeout)); then
      request_timeout=$remaining
    fi
    if ! jobs_json="$(api_get_fresh \
      "$base_url/jobs/?project_id=$target_project_id" "$request_timeout")"; then
      echo "The jobs API failed during $job_label discovery." >&2
      return 1
    fi
    if ! matching_jobs="$(jq -c \
      --arg project_id "$target_project_id" \
      --arg source_job_id "$source_job_id" \
      --arg type "$job_type" '
        [.[] | select(
          .id == $source_job_id and
          .project_id == $project_id and
          .type == "create_project" and
          ((.created_at | type) == "string")
        )] as $source_jobs |
        if ($source_jobs | length) != 1 then
          error("source worker job metadata is not unique")
        else
          $source_jobs[0] as $source_job |
          [.[] | select(
            .project_id == $project_id and
            .type == $type and
            .created_by == $source_job.created_by and
            ((.created_at | type) == "string") and
            .created_at >= $source_job.created_at
          )]
        end
      ' <<<"$jobs_json")"; then
      echo "The jobs API returned invalid JSON during $job_label discovery." >&2
      return 1
    fi
    matching_count="$(jq -r 'length' <<<"$matching_jobs")"
    if [[ ! $matching_count =~ ^[0-9]+$ ]]; then
      echo "The jobs API returned an invalid $job_label count." >&2
      return 1
    fi
    if ((matching_count > 1)); then
      echo "More than one $job_label worker job exists for the exact smoke project." >&2
      return 1
    fi
    if ((matching_count == 1)); then
      matching_job_id="$(jq -er '.[0].id | select(type == "string")' <<<"$matching_jobs")"
      if ! is_uuid "$matching_job_id"; then
        echo "The discovered $job_label worker job identifier is invalid." >&2
        return 1
      fi
      printf '%s\n' "$matching_job_id"
      return 0
    fi
    if ! now="$(monotonic_seconds)"; then
      echo "The monotonic clock failed during $job_label discovery." >&2
      return 1
    fi
    remaining=$((deadline - now))
    ((remaining > 0)) || break
    sleep_seconds=$job_poll_seconds
    if ((remaining < sleep_seconds)); then
      sleep_seconds=$remaining
    fi
    sleep "$sleep_seconds"
  done
  echo "The $job_label worker job was not discovered before its bounded discovery deadline." >&2
  return 1
}

verify_removed_worker_container() {
  local job_id="$1"
  local metadata_output=""
  local metadata_json=""
  local container_id=""
  local matching_ids=""
  local qgis_version=""

  metadata_output="$(compose exec -T \
    -e "QFC_SMOKE_JOB_ID=$job_id" \
    app python manage.py shell -c '
import json
import os
from qfieldcloud.core.models import Job

job = Job.objects.get(id=os.environ["QFC_SMOKE_JOB_ID"])
print("QFC_SMOKE_METADATA=" + json.dumps({
    "container_id": job.container_id,
    "qgis_version": job.qgis_version,
    "status": job.status,
}))
')"
  metadata_json="$(sed -n 's/^QFC_SMOKE_METADATA=//p' <<<"$metadata_output" | tail -n 1)"
  if ! jq -e '.status == "finished"' >/dev/null 2>&1 <<<"$metadata_json"; then
    echo "The finished worker job metadata could not be verified." >&2
    return 1
  fi
  container_id="$(jq -r '.container_id // ""' <<<"$metadata_json")"
  qgis_version="$(jq -r '.qgis_version // ""' <<<"$metadata_json")"
  if [[ ! $container_id =~ ^[0-9a-f]{64}$ ]]; then
    echo "The worker job has no valid temporary container record." >&2
    return 1
  fi
  if [[ $qgis_version != "$QFC_QGIS3_EXPECTED_VERSION" ]] && \
    [[ $qgis_version != "$QFC_QGIS3_EXPECTED_VERSION"-* ]]; then
    echo "The worker job did not report the pinned QGIS 3 version." >&2
    return 1
  fi
  if ! matching_ids="$(
    docker container ls --all --no-trunc --quiet --filter "id=$container_id"
  )"; then
    echo "Docker could not verify temporary QGIS worker container cleanup." >&2
    return 1
  fi
  if [[ -n $matching_ids ]]; then
    echo "The temporary QGIS worker container still exists or Docker returned unexpected metadata." >&2
    return 1
  fi
  verified_qgis_version="$qgis_version"
}

if [[ -n $create_job_id ]]; then
  wait_for_job "$create_job_id" "create-project" "$worker_smoke_deadline"
  verify_removed_worker_container "$create_job_id"
fi

if ! process_job_id="$(wait_for_single_project_job_type \
  "$project_id" "$create_job_id" "process_projectfile" "process-projectfile" \
  "$worker_smoke_deadline")"; then
  echo "The seed project did not produce one process-projectfile worker job." >&2
  exit 1
fi
wait_for_job "$process_job_id" "process-projectfile" "$worker_smoke_deadline"
verify_removed_worker_container "$process_job_id"

project_json="$(api_get_fresh "$base_url/projects/$project_id/")"
if ! jq -e '
  type == "object" and
  .status == "ok" and
  ((.the_qgis_file_name | type) == "string") and
  ((.the_qgis_file_name | length) > 0)
' >/dev/null <<<"$project_json"; then
  echo "The worker smoke project is not ready for packaging." >&2
  exit 1
fi

package_request="$test_root/package.json"
jq -n --arg project_id "$project_id" \
  '{project_id: $project_id, type: "package"}' >"$package_request"
package_job_json="$(api_auth "$default_api_timeout_seconds" \
  --request POST \
  --header 'Content-Type: application/json' \
  --data-binary "@$package_request" \
  "$base_url/jobs/")"
package_job_id="$(jq -er '.id | select(type == "string")' <<<"$package_job_json")"
if ! is_uuid "$package_job_id"; then
  echo "The package worker job identifier is invalid." >&2
  exit 1
fi

wait_for_job "$package_job_id" "package" "$worker_smoke_deadline"
verify_removed_worker_container "$package_job_id"

latest_package="$(api_get_fresh "$base_url/packages/$project_id/latest/")"
if ! jq -e --arg package_job_id "$package_job_id" '
  type == "object" and
  .status == "finished" and
  ((.package_id | type) == "string") and
  .package_id == $package_job_id and
  ((.files | type) == "array") and
  ((.files | length) > 0)
' >/dev/null <<<"$latest_package"; then
  echo "The finished worker job did not produce a readable project package." >&2
  exit 1
fi

timestamp="$(date -u +%FT%TZ)"
if ! cleanup_owned_smoke_project; then
  echo "The worker work passed, but its exact installer-owned project or child cleanup did not." >&2
  exit 1
fi
if ! revoke_smoke_token >/dev/null; then
  echo "The exact temporary worker-smoke token could not be revoked." >&2
  exit 1
fi
auth_ready="false"
unset auth_token
write_smoke_status passed "$timestamp"
smoke_completed="true"
echo "Worker smoke test passed: seed project creation, QGIS 3 processing, packaging, and temporary-container cleanup were verified."
