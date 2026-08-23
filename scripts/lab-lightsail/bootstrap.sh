#!/usr/bin/env bash

set -Eeuo pipefail
set +x
umask 077

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly DEFAULT_INSTALL_ROOT="/opt/qfieldcloud"
readonly DOCKER_REPOSITORY_URL="https://download.docker.com/linux/ubuntu"
readonly DOCKER_APT_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
readonly QFC_DHPARAM_RAW_BASE="https://raw.githubusercontent.com/opengisch/QFieldCloud"

proj_archive_tmp=""
proj_staging_tmp=""
bootstrap_succeeded="false"
bootstrap_state_managed="false"
install_intent_managed="false"

repository_url=""
revision=""
install_root="$DEFAULT_INSTALL_ROOT"
public_host="auto"

usage() {
  cat <<'EOF'
Usage:
  bootstrap.sh --repository-url HTTPS_GIT_URL --revision 40_HEX_COMMIT [options]

Required:
  --repository-url URL   Installer repository HTTPS clone URL ending in .git
  --revision SHA         Exact 40-character installer commit

Options:
  --install-root PATH    Installation directory (default: /opt/qfieldcloud)
  --public-host HOST     Existing DNS name, or "auto" for IP.sslip.io
  --help                 Show this help
EOF
}

while (($# > 0)); do
  case "$1" in
    --repository-url)
      repository_url="${2:-}"
      shift 2
      ;;
    --revision)
      revision="${2:-}"
      shift 2
      ;;
    --install-root)
      install_root="${2:-}"
      shift 2
      ;;
    --public-host)
      public_host="${2:-}"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root." >&2
  exit 1
fi

if [[ ! $repository_url =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]]; then
  echo "--repository-url must be an HTTPS GitHub clone URL ending in .git." >&2
  exit 2
fi

if [[ ! $revision =~ ^[0-9a-f]{40}$ ]]; then
  echo "--revision must be an exact lowercase 40-character Git commit." >&2
  exit 2
fi

if [[ ! $install_root =~ ^/([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+$ ]] || \
  [[ $install_root == *"//"* ]] || [[ $install_root == *"/./"* ]] || \
  [[ $install_root == */. ]] || [[ $install_root == *"/../"* ]] || \
  [[ $install_root == */.. ]]; then
  echo "--install-root must be a safe absolute path other than /." >&2
  exit 2
fi

if [[ $public_host != "auto" ]] && [[ ! $public_host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  echo "--public-host contains unsupported characters." >&2
  exit 2
fi
if ! command -v timeout >/dev/null 2>&1; then
  echo "The required coreutils timeout command is unavailable." >&2
  exit 1
fi

mkdir -p /var/log/qfieldcloud /var/lib/qfieldcloud
chmod 0700 /var/log/qfieldcloud /var/lib/qfieldcloud
readonly log_file="/var/log/qfieldcloud/bootstrap.log"
touch "$log_file"
chmod 0600 "$log_file"
exec > >(tee -a "$log_file") 2>&1

cleanup_proj_temp() {
  if [[ -n $proj_archive_tmp ]] && [[ $proj_archive_tmp == "$install_root/state/proj-data-archive."* ]]; then
    rm -f -- "$proj_archive_tmp"
  fi
  if [[ -n $proj_staging_tmp ]] && [[ $proj_staging_tmp == "$install_root/state/proj-data-staging."* ]] && [[ -d $proj_staging_tmp ]]; then
    rm -rf -- "$proj_staging_tmp"
  fi
  proj_archive_tmp=""
  proj_staging_tmp=""
}

write_root_state_value() {
  local state_name="$1"
  local state_value="$2"
  local bootstrap_state_dir="$install_root/state"
  local state_tmp=""

  case "$state_name" in
    bootstrap-status | installer-revision | installer-manifest-sha256 | \
      bootstrap-completed-at | installed-release | certificate-sha256) ;;
    *) return 1 ;;
  esac

  install -m 0700 -d "$bootstrap_state_dir"
  state_tmp="$(mktemp "$bootstrap_state_dir/.$state_name.XXXXXX")"
  if ! printf '%s\n' "$state_value" >"$state_tmp" \
    || ! chmod 0600 "$state_tmp" \
    || ! mv -f -- "$state_tmp" "$bootstrap_state_dir/$state_name"; then
    rm -f -- "$state_tmp"
    return 1
  fi
}

write_bootstrap_state() {
  local requested_state="$1"

  case "$requested_state" in
    running | services-ready | validating | ready | failed) ;;
    *) return 1 ;;
  esac
  write_root_state_value bootstrap-status "$requested_state"
}

on_exit() {
  local exit_code="$1"

  trap - EXIT
  set +e
  cleanup_proj_temp

  if [[ $bootstrap_state_managed == "true" ]] && \
    [[ $bootstrap_succeeded != "true" ]]; then
    if [[ $install_intent_managed == "true" ]] && \
      declare -F set_install_intent_status >/dev/null 2>&1; then
      set_install_intent_status incomplete failure >/dev/null 2>&1 || true
    fi
    write_bootstrap_state failed >/dev/null 2>&1 || true
    echo "[$(date -u +%FT%TZ)] Bootstrap exited before every validation completed (exit code $exit_code)." >&2
    if [[ $exit_code -eq 0 ]]; then
      exit_code=1
    fi
  fi

  exit "$exit_code"
}
trap 'on_exit $?' EXIT

exec 8>/var/lock/qfieldcloud-maintenance.lock
if ! flock -n 8; then
  echo "Another QFieldCloud maintenance operation is already running." >&2
  exit 1
fi
# Helper scripts called by this bootstrap inherit descriptor 8 and therefore
# share this one exclusive maintenance window without trying to lock it again.
export QFC_MAINTENANCE_LOCK_FD=8
bootstrap_state_managed="true"
write_bootstrap_state running

exec 9>/var/lock/qfieldcloud-bootstrap.lock
if ! flock -n 9; then
  echo "Another QFieldCloud bootstrap process is already running." >&2
  exit 1
fi

echo "[$(date -u +%FT%TZ)] Starting $SCRIPT_NAME for installer commit $revision."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git gnupg jq openssl

if [[ $(dpkg --print-architecture) != "amd64" ]]; then
  echo "The lab pilot supports only linux/amd64." >&2
  exit 1
fi

readonly installer_root="$install_root/installer"
mkdir -p "$install_root" "$installer_root"
chmod 0700 "$install_root"

if [[ ! -d $installer_root/.git ]]; then
  git -C "$installer_root" init --quiet
  git -C "$installer_root" remote add origin "$repository_url"
else
  existing_remote="$(git -C "$installer_root" remote get-url origin)"
  if [[ $existing_remote != "$repository_url" ]]; then
    echo "Existing installer remote does not match the requested repository." >&2
    exit 1
  fi
fi

git -C "$installer_root" fetch --quiet --depth 1 origin "$revision"
fetched_revision="$(git -C "$installer_root" rev-parse FETCH_HEAD)"
if [[ $fetched_revision != "$revision" ]]; then
  echo "Fetched installer commit does not match the requested revision." >&2
  exit 1
fi
git -C "$installer_root" checkout --quiet --detach --force "$revision"

readonly version_source="$installer_root/config/qfieldcloud-v26.25.env"
readonly compose_source="$installer_root/runtime/lab-lightsail/compose.yaml"
helper_names=(health-check.sh show-admin-credentials.sh backup.sh restore-test.sh worker-smoke-test.sh)
for required_file in "$version_source" "$compose_source"; do
  if [[ ! -f $required_file ]]; then
    echo "Required installer file is missing: $required_file" >&2
    exit 1
  fi
done
for helper_name in "${helper_names[@]}"; do
  helper_source="$installer_root/scripts/lab-lightsail/$helper_name"
  if [[ ! -f $helper_source ]]; then
    echo "Required installer helper is missing: $helper_source" >&2
    exit 1
  fi
done

readonly versions_file="$install_root/versions.env"
readonly compose_file="$install_root/compose.yaml"

# The file is from the exact installer commit verified above and contains only
# non-secret version constants.
# shellcheck disable=SC1090
source "$version_source"

required_version_variables=(
  QFIELDCLOUD_RELEASE QFIELDCLOUD_COMMIT QFIELDCLOUD_PLATFORM
  QFIELDCLOUD_DHPARAM_SHA256 QFC_APP_IMAGE QFC_NGINX_IMAGE
  QFC_WORKER_WRAPPER_IMAGE QFC_QGIS3_IMAGE QFC_QGIS3_EXPECTED_VERSION
  QFC_CREATEBUCKETS_IMAGE
  POSTGIS_IMAGE RUSTFS_IMAGE SMTP4DEV_IMAGE OFELIA_IMAGE MEMCACHED_IMAGE
  PROJ_DATA_RELEASE PROJ_DATA_ARCHIVE_URL PROJ_DATA_ARCHIVE_SIZE_BYTES
  PROJ_DATA_ARCHIVE_SHA256
  DOCKER_CE_VERSION DOCKER_CE_CLI_VERSION CONTAINERD_IO_VERSION
  DOCKER_BUILDX_VERSION DOCKER_COMPOSE_VERSION DOCKER_APT_KEY_FINGERPRINT
  DOCKER_APT_KEY_SIZE_BYTES DOCKER_APT_KEY_SHA256
)
for variable_name in "${required_version_variables[@]}"; do
  if [[ -z ${!variable_name:-} ]]; then
    echo "Version manifest is missing $variable_name." >&2
    exit 1
  fi
done

if [[ $QFIELDCLOUD_PLATFORM != "linux/amd64" ]]; then
  echo "Version manifest platform is not linux/amd64." >&2
  exit 1
fi

for image_variable in QFC_APP_IMAGE QFC_NGINX_IMAGE QFC_WORKER_WRAPPER_IMAGE QFC_QGIS3_IMAGE QFC_CREATEBUCKETS_IMAGE POSTGIS_IMAGE RUSTFS_IMAGE SMTP4DEV_IMAGE OFELIA_IMAGE MEMCACHED_IMAGE; do
  if [[ ! ${!image_variable} =~ @sha256:[0-9a-f]{64}$ ]]; then
    echo "$image_variable is not pinned to a sha256 manifest." >&2
    exit 1
  fi
done

if [[ ${QFC_QGIS4_IMAGE:-} != disabled.invalid/* ]]; then
  echo "QGIS 4 must remain fail-closed until an official verified image exists." >&2
  exit 1
fi

if [[ ! $QFC_QGIS3_EXPECTED_VERSION =~ ^3\.[0-9]+\.[0-9]+$ ]]; then
  echo "The expected QGIS 3 version is invalid." >&2
  exit 1
fi
if [[ ! $PROJ_DATA_RELEASE =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  [[ ! $PROJ_DATA_ARCHIVE_URL =~ ^https://github\.com/OSGeo/PROJ-data/releases/download/[0-9]+\.[0-9]+\.[0-9]+/proj-data-[0-9]+\.[0-9]+\.tar\.gz$ ]] || \
  [[ ! $PROJ_DATA_ARCHIVE_SIZE_BYTES =~ ^[0-9]+$ ]] || \
  [[ ! $PROJ_DATA_ARCHIVE_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
  echo "The pinned PROJ-data release metadata is invalid." >&2
  exit 1
fi

source_manifest_listing="$(
  cd "$installer_root"
  sha256sum -- \
    config/qfieldcloud-v26.25.env \
    runtime/lab-lightsail/compose.yaml \
    scripts/lab-lightsail/health-check.sh \
    scripts/lab-lightsail/show-admin-credentials.sh \
    scripts/lab-lightsail/backup.sh \
    scripts/lab-lightsail/restore-test.sh \
    scripts/lab-lightsail/worker-smoke-test.sh
)"
source_manifest_sha256="$(printf '%s\n' "$source_manifest_listing" | sha256sum | awk '{print $1}')"
if [[ ! $source_manifest_sha256 =~ ^[0-9a-f]{64}$ ]]; then
  echo "The installer source manifest checksum could not be calculated." >&2
  exit 1
fi

install -m 0700 -d "$install_root/state"
readonly install_intent_file="$install_root/state/install-intent.json"
set_install_intent_status() {
  local requested_status="$1"
  local transition_reason="$2"
  local transition_at=""
  local install_intent_tmp=""

  case "$requested_status:$transition_reason" in
    incomplete:start | incomplete:failure | complete:success) ;;
    *) return 1 ;;
  esac
  [[ -f $install_intent_file && ! -L $install_intent_file ]] || return 1

  transition_at="$(date -u +%FT%TZ)"
  install_intent_tmp="$(mktemp "$install_root/state/.install-intent.XXXXXX")"
  if ! jq \
    --arg status "$requested_status" \
    --arg reason "$transition_reason" \
    --arg transition_at "$transition_at" \
    '
      .status = $status
      | if $reason == "start" then
          .attempt_started_at_utc = $transition_at
          | del(.completed_at_utc, .failed_at_utc)
        elif $reason == "failure" then
          .failed_at_utc = $transition_at
          | del(.completed_at_utc)
        else
          .completed_at_utc = $transition_at
          | del(.failed_at_utc)
        end
    ' "$install_intent_file" >"$install_intent_tmp" \
    || ! chmod 0600 "$install_intent_tmp" \
    || ! mv -f -- "$install_intent_tmp" "$install_intent_file"; then
    rm -f -- "$install_intent_tmp"
    return 1
  fi
}

if [[ -e $install_intent_file ]]; then
  if [[ ! -f $install_intent_file || -L $install_intent_file ]] || \
    ! jq -e \
      --arg release "$QFIELDCLOUD_RELEASE" \
      --arg revision "$revision" \
      --arg manifest "$source_manifest_sha256" \
      '(.status == "incomplete" or .status == "complete") and
       .release == $release and .installer_revision == $revision and
       .source_manifest_sha256 == $manifest' \
      "$install_intent_file" >/dev/null 2>&1; then
    echo "An incomplete or completed installation is pinned to a different approved tuple." >&2
    echo "No live file was replaced; use a separately reviewed recovery or update procedure." >&2
    exit 1
  fi
else
  install_intent_tmp="$(mktemp "$install_root/state/install-intent.XXXXXX")"
  jq -n \
    --arg release "$QFIELDCLOUD_RELEASE" \
    --arg revision "$revision" \
    --arg manifest "$source_manifest_sha256" \
    --arg created_at "$(date -u +%FT%TZ)" \
    '{
      status: "incomplete",
      release: $release,
      installer_revision: $revision,
      source_manifest_sha256: $manifest,
      created_at_utc: $created_at
    }' >"$install_intent_tmp"
  chmod 0600 "$install_intent_tmp"
  mv -f "$install_intent_tmp" "$install_intent_file"
fi
install_intent_managed="true"
set_install_intent_status incomplete start

readonly installed_release_file="$install_root/state/installed-release"
if [[ -f $installed_release_file ]]; then
  installed_release="$(<"$installed_release_file")"
  if [[ $installed_release != "$QFIELDCLOUD_RELEASE" ]]; then
    echo "An explicit update procedure is required to change QFieldCloud releases." >&2
    exit 1
  fi
  installed_revision_file="$install_root/state/installer-revision"
  installed_manifest_file="$install_root/state/installer-manifest-sha256"
  if [[ ! -f $installed_revision_file ]] || [[ ! -f $installed_manifest_file ]] || \
    [[ $(<"$installed_revision_file") != "$revision" ]] || \
    [[ $(<"$installed_manifest_file") != "$source_manifest_sha256" ]]; then
    echo "An explicit update procedure is required to change the installer revision or manifest." >&2
    exit 1
  fi
  if ! cmp -s -- "$versions_file" "$version_source" || \
    ! cmp -s -- "$compose_file" "$compose_source"; then
    echo "Installed runtime files differ from the approved installer manifest." >&2
    exit 1
  fi
  for helper_name in "${helper_names[@]}"; do
    if ! cmp -s -- "$install_root/bin/$helper_name" \
      "$installer_root/scripts/lab-lightsail/$helper_name"; then
      echo "Installed helper files differ from the approved installer manifest." >&2
      exit 1
    fi
  done
fi

# Do not replace the live manifest, Compose file, or helpers until the pinned
# source manifest has passed every check and the installed release agrees.
install -m 0600 "$version_source" "$versions_file"
install -m 0600 "$compose_source" "$compose_file"
install -m 0700 -d "$install_root/bin"
for helper_name in "${helper_names[@]}"; do
  helper_source="$installer_root/scripts/lab-lightsail/$helper_name"
  install -m 0700 "$helper_source" "$install_root/bin/$helper_name"
done

install -m 0755 -d /etc/apt/keyrings
docker_key_tmp="$(mktemp /etc/apt/keyrings/docker.asc.XXXXXX)"
curl --fail --silent --show-error --location "$DOCKER_APT_KEY_URL" --output "$docker_key_tmp"
docker_key_size="$(stat -c '%s' "$docker_key_tmp")"
docker_key_sha256="$(sha256sum "$docker_key_tmp" | awk '{print $1}')"
if [[ $docker_key_size != "$DOCKER_APT_KEY_SIZE_BYTES" ]] || \
  [[ $docker_key_sha256 != "$DOCKER_APT_KEY_SHA256" ]]; then
  echo "Docker repository signing-key bytes do not match the approved manifest." >&2
  exit 1
fi
docker_key_fingerprint="$(gpg --batch --show-keys --with-colons "$docker_key_tmp" | awk -F: '$1 == "fpr" { print $10; exit }')"
if [[ $docker_key_fingerprint != "$DOCKER_APT_KEY_FINGERPRINT" ]]; then
  echo "Docker APT signing key fingerprint did not match the manifest." >&2
  exit 1
fi
chmod 0644 "$docker_key_tmp"
mv -f "$docker_key_tmp" /etc/apt/keyrings/docker.asc

cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: $DOCKER_REPOSITORY_URL
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
chmod 0644 /etc/apt/sources.list.d/docker.sources

apt-get update
apt-get install -y --no-install-recommends --allow-downgrades \
  "docker-ce=$DOCKER_CE_VERSION" \
  "docker-ce-cli=$DOCKER_CE_CLI_VERSION" \
  "containerd.io=$CONTAINERD_IO_VERSION" \
  "docker-buildx-plugin=$DOCKER_BUILDX_VERSION" \
  "docker-compose-plugin=$DOCKER_COMPOSE_VERSION"
apt-mark hold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
systemctl enable --now docker

install -m 0755 -d /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
  jq '. + {"log-driver":"json-file","log-opts":{"max-size":"100m","max-file":"5"}}' \
    /etc/docker/daemon.json > /etc/docker/daemon.json.qfc.tmp
else
  jq -n '{"log-driver":"json-file","log-opts":{"max-size":"100m","max-file":"5"}}' \
    > /etc/docker/daemon.json.qfc.tmp
fi
install -m 0644 /etc/docker/daemon.json.qfc.tmp /etc/docker/daemon.json
rm -f /etc/docker/daemon.json.qfc.tmp
systemctl restart docker

if ! swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
  if [[ ! -f /swapfile ]]; then
    fallocate -l 4G /swapfile
    chmod 0600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
fi
if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
  printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
fi

discover_public_ipv4() {
  local previous_ip=""
  local stable_count=0
  local candidate=""
  local attempts_remaining=18

  while ((attempts_remaining > 0)); do
    candidate="$(curl --fail --silent --show-error --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
    if [[ $candidate =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      if [[ $candidate == "$previous_ip" ]]; then
        stable_count=$((stable_count + 1))
      else
        previous_ip="$candidate"
        stable_count=1
      fi
      if ((stable_count >= 3)); then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
    attempts_remaining=$((attempts_remaining - 1))
    sleep 10
  done
  return 1
}

auto_public_host="false"
if [[ $public_host == "auto" ]]; then
  auto_public_host="true"
  public_ipv4="$(discover_public_ipv4)"
  public_host="${public_ipv4}.sslip.io"
fi

if [[ ! $public_host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  echo "Resolved public host is invalid." >&2
  exit 1
fi

readonly state_root="$install_root/state"
readonly cert_root="$state_root/certs"
readonly dhparam_root="$state_root/dhparams"
readonly ca_root="$state_root/ca"
readonly nginx_config_root="$state_root/nginx-config"
readonly temp_root="$state_root/tmp"
install -m 0700 -d "$state_root" "$cert_root" "$dhparam_root" "$ca_root" "$nginx_config_root" "$temp_root"

readonly host_state_file="$state_root/public-host"
configure_public_host_files() {
  local previous_host=""

  if [[ -f $host_state_file ]]; then
    previous_host="$(<"$host_state_file")"
  fi
  if [[ $previous_host != "$public_host" ]] || \
    [[ ! -s $cert_root/qfieldcloud.pem ]] || [[ ! -s $cert_root/qfieldcloud-key.pem ]]; then
    openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 365 \
      -keyout "$cert_root/qfieldcloud-key.pem.new" \
      -out "$cert_root/qfieldcloud.pem.new" \
      -subj "/CN=$public_host" \
      -addext "subjectAltName=DNS:$public_host"
    chmod 0600 "$cert_root/qfieldcloud-key.pem.new" "$cert_root/qfieldcloud.pem.new"
    mv -f "$cert_root/qfieldcloud-key.pem.new" "$cert_root/qfieldcloud-key.pem"
    mv -f "$cert_root/qfieldcloud.pem.new" "$cert_root/qfieldcloud.pem"
  fi
  printf '%s\n' "$public_host" >"$host_state_file"
  chmod 0600 "$host_state_file"
}

configure_public_host_files

dhparam_tmp="$(mktemp "$dhparam_root/ssl-dhparams.pem.XXXXXX")"
curl --fail --silent --show-error --location \
  "$QFC_DHPARAM_RAW_BASE/$QFIELDCLOUD_COMMIT/conf/nginx/dhparams/ssl-dhparams.pem" \
  --output "$dhparam_tmp"
actual_dhparam_sha256="$(sha256sum "$dhparam_tmp" | awk '{print $1}')"
if [[ $actual_dhparam_sha256 != "$QFIELDCLOUD_DHPARAM_SHA256" ]]; then
  echo "Official QFieldCloud DH parameters checksum did not match." >&2
  exit 1
fi
install -m 0600 "$dhparam_tmp" "$dhparam_root/ssl-dhparams.pem"
rm -f "$dhparam_tmp"

readonly secrets_file="$state_root/secrets.env"
if [[ ! -f $secrets_file ]]; then
  secrets_tmp="$(mktemp "$state_root/secrets.env.XXXXXX")"
  {
    printf 'SECRET_KEY=%s\n' "$(openssl rand -hex 64)"
    printf 'SALT_KEY=%s\n' "$(openssl rand -hex 32)"
    printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)"
    printf 'OBJECT_STORAGE_ROOT_USER=qfc%s\n' "$(openssl rand -hex 8)"
    printf 'OBJECT_STORAGE_ROOT_PASSWORD=%s\n' "$(openssl rand -hex 32)"
    printf 'ADMIN_USERNAME=qfcadmin\n'
    printf 'ADMIN_EMAIL=admin@localhost.invalid\n'
    printf 'ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 24)"
  } >"$secrets_tmp"
  chmod 0600 "$secrets_tmp"
  mv -f "$secrets_tmp" "$secrets_file"
fi
chmod 0600 "$secrets_file"

# Values are generated on this AWS instance and consist only of fixed strings
# and hexadecimal characters.
# shellcheck disable=SC1090
source "$secrets_file"
for secret_variable in SECRET_KEY SALT_KEY POSTGRES_PASSWORD OBJECT_STORAGE_ROOT_USER OBJECT_STORAGE_ROOT_PASSWORD ADMIN_USERNAME ADMIN_EMAIL ADMIN_PASSWORD; do
  if [[ -z ${!secret_variable:-} ]]; then
    echo "Secret state is incomplete; refusing to replace it automatically." >&2
    exit 1
  fi
done
if [[ ! $SECRET_KEY =~ ^[0-9a-f]{128}$ ]] \
  || [[ ! $SALT_KEY =~ ^[0-9a-f]{64}$ ]] \
  || [[ ! $POSTGRES_PASSWORD =~ ^[0-9a-f]{64}$ ]] \
  || [[ ! $OBJECT_STORAGE_ROOT_USER =~ ^qfc[0-9a-f]{16}$ ]] \
  || [[ ! $OBJECT_STORAGE_ROOT_PASSWORD =~ ^[0-9a-f]{64}$ ]] \
  || [[ $ADMIN_USERNAME != "qfcadmin" ]] \
  || [[ $ADMIN_EMAIL != "admin@localhost.invalid" ]] \
  || [[ ! $ADMIN_PASSWORD =~ ^[0-9a-f]{48}$ ]]; then
  echo "Secret state has an unexpected format; refusing to use or replace it automatically." >&2
  exit 1
fi

readonly runtime_env="$state_root/runtime.env"
write_runtime_env() {
  local runtime_env_tmp=""

  runtime_env_tmp="$(mktemp "$state_root/runtime.env.XXXXXX")"
  cat >"$runtime_env_tmp" <<EOF
DJANGO_ALLOWED_HOSTS=$public_host nginx app
SECRET_KEY=$SECRET_KEY
SALT_KEY=$SALT_KEY
POSTGRES_DB=qfieldcloud_db
POSTGRES_USER=qfieldcloud_db_admin
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
OBJECT_STORAGE_ROOT_USER=$OBJECT_STORAGE_ROOT_USER
OBJECT_STORAGE_ROOT_PASSWORD=$OBJECT_STORAGE_ROOT_PASSWORD
QFIELDCLOUD_HOST=$public_host
STORAGES={"default":{"BACKEND":"qfieldcloud.filestorage.backend.QfcS3Boto3Storage","OPTIONS":{"access_key":"$OBJECT_STORAGE_ROOT_USER","secret_key":"$OBJECT_STORAGE_ROOT_PASSWORD","bucket_name":"qfieldcloud-local","region_name":"","endpoint_url":"http://rustfs:9000"}}}
EOF
  chmod 0600 "$runtime_env_tmp"
  mv -f "$runtime_env_tmp" "$runtime_env"
}

write_runtime_env

compose() {
  docker compose \
    --env-file "$versions_file" \
    --env-file "$runtime_env" \
    --file "$compose_file" \
    "$@"
}

prepare_transformation_grids() {
  local volume_name="qfieldcloud_transformation_grids"
  local inspected_name=""
  local grid_mount=""
  local marker_file=""
  local existing_entry=""
  local available_bytes=""
  local required_free_bytes=""
  local archive_size=""
  local archive_sha256=""
  local archive_listing=""
  local archive_entry=""
  local normalized_entry=""
  local unexpected_entry=""
  local grid_file_count=""
  local expected_grid_file_count=""
  local actual_grid_file_count=""

  docker volume create "$volume_name" >/dev/null
  inspected_name="$(docker volume inspect --format '{{ .Name }}' "$volume_name")"
  grid_mount="$(docker volume inspect --format '{{ .Mountpoint }}' "$volume_name")"
  if [[ $inspected_name != "$volume_name" ]] || [[ $grid_mount != /* ]] || \
    [[ $grid_mount == "/" ]] || [[ ! -d $grid_mount ]]; then
    echo "The transformation grid Docker volume could not be resolved safely." >&2
    exit 1
  fi

  marker_file="$grid_mount/.qfc-proj-data.json"
  if [[ -f $marker_file && ! -L $marker_file ]] && \
    [[ -f $grid_mount/README.DATA && ! -L $grid_mount/README.DATA ]] && \
    [[ -f $grid_mount/copyright_and_licenses.csv && \
       ! -L $grid_mount/copyright_and_licenses.csv ]]; then
    expected_grid_file_count="$(
      jq -er \
      --arg release "$PROJ_DATA_RELEASE" \
      --arg source_url "$PROJ_DATA_ARCHIVE_URL" \
      --arg sha256 "$PROJ_DATA_ARCHIVE_SHA256" \
      --argjson size "$PROJ_DATA_ARCHIVE_SIZE_BYTES" \
        'select(.release == $release and .source_url == $source_url and
                .archive_sha256 == $sha256 and .archive_size_bytes == $size) |
         .grid_file_count | select(type == "number" and . > 0 and floor == .)' \
        "$marker_file" 2>/dev/null || true
    )"
    actual_grid_file_count="$(
      find "$grid_mount" -maxdepth 1 -type f -name '*.tif' -printf '.\n' \
        2>/dev/null | wc -l | tr -d '[:space:]' || true
    )"
    if [[ $expected_grid_file_count =~ ^[0-9]+$ ]] && \
      [[ $actual_grid_file_count == "$expected_grid_file_count" ]]; then
      echo "Pinned PROJ-data $PROJ_DATA_RELEASE transformation grids are already present."
      return 0
    fi
  fi

  existing_entry="$(find "$grid_mount" -mindepth 1 -maxdepth 1 -print -quit)"
  if [[ -n $existing_entry ]]; then
    echo "The transformation grid volume is non-empty but has no valid installer marker." >&2
    echo "It was left unchanged; inspect it before any manual cleanup." >&2
    exit 1
  fi

  available_bytes="$(df --output=avail -B1 "$state_root" | awk 'NR == 2 {print $1}')"
  required_free_bytes=$((PROJ_DATA_ARCHIVE_SIZE_BYTES * 3))
  if [[ ! $available_bytes =~ ^[0-9]+$ ]] || ((available_bytes < required_free_bytes)); then
    echo "At least $required_free_bytes free bytes are required to stage the pinned PROJ-data archive." >&2
    exit 1
  fi

  proj_archive_tmp="$(mktemp "$state_root/proj-data-archive.XXXXXX")"
  proj_staging_tmp="$(mktemp -d "$state_root/proj-data-staging.XXXXXX")"
  timeout --signal=TERM --kill-after=30s 1800s \
    curl --fail --silent --show-error --location \
    --retry 5 --retry-delay 5 --retry-all-errors --retry-max-time 1740 \
    --connect-timeout 15 --max-time 1740 \
    "$PROJ_DATA_ARCHIVE_URL" --output "$proj_archive_tmp"

  archive_size="$(stat -c '%s' "$proj_archive_tmp")"
  archive_sha256="$(sha256sum "$proj_archive_tmp" | awk '{print $1}')"
  if [[ $archive_size != "$PROJ_DATA_ARCHIVE_SIZE_BYTES" ]] || \
    [[ $archive_sha256 != "$PROJ_DATA_ARCHIVE_SHA256" ]]; then
    echo "The PROJ-data archive size or SHA-256 checksum did not match the manifest." >&2
    exit 1
  fi

  archive_listing="$(tar -tzf "$proj_archive_tmp")"
  while IFS= read -r archive_entry; do
    normalized_entry="${archive_entry#./}"
    if [[ -z $normalized_entry ]] || [[ $normalized_entry == /* ]] || \
      [[ $normalized_entry == ".." ]] || [[ $normalized_entry == ../* ]] || \
      [[ $normalized_entry == */../* ]] || [[ $normalized_entry == */.. ]]; then
      echo "The PROJ-data archive contains an unsafe path." >&2
      exit 1
    fi
  done <<<"$archive_listing"
  if ! grep -Eq '(^|/)README\.DATA$' <<<"$archive_listing" || \
    ! grep -Eq '(^|/)copyright_and_licenses\.csv$' <<<"$archive_listing" || \
    ! grep -Eq '\.tif$' <<<"$archive_listing"; then
    echo "The PROJ-data archive does not contain its expected grids and license inventory." >&2
    exit 1
  fi

  tar --no-same-owner --no-same-permissions -xzf "$proj_archive_tmp" -C "$proj_staging_tmp"
  unexpected_entry="$(find "$proj_staging_tmp" -mindepth 1 ! -type f ! -type d -print -quit)"
  if [[ -n $unexpected_entry ]]; then
    echo "The PROJ-data archive contains an unsupported filesystem entry." >&2
    exit 1
  fi
  grid_file_count="$(find "$proj_staging_tmp" -maxdepth 1 -type f -name '*.tif' | wc -l | tr -d '[:space:]')"
  if [[ ! $grid_file_count =~ ^[0-9]+$ ]] || ((grid_file_count == 0)); then
    echo "No transformation grids were found after extracting PROJ-data." >&2
    exit 1
  fi

  cp -a "$proj_staging_tmp/." "$grid_mount/"
  find "$grid_mount" -type d -exec chmod 0755 {} +
  find "$grid_mount" -type f -exec chmod 0644 {} +
  jq -n \
    --arg release "$PROJ_DATA_RELEASE" \
    --arg source_url "$PROJ_DATA_ARCHIVE_URL" \
    --arg sha256 "$PROJ_DATA_ARCHIVE_SHA256" \
    --argjson archive_size_bytes "$PROJ_DATA_ARCHIVE_SIZE_BYTES" \
    --argjson grid_file_count "$grid_file_count" \
    '{
      release: $release,
      source_url: $source_url,
      archive_sha256: $sha256,
      archive_size_bytes: $archive_size_bytes,
      grid_file_count: $grid_file_count
    }' >"$marker_file.new"
  chmod 0644 "$marker_file.new"
  mv -f "$marker_file.new" "$marker_file"
  cleanup_proj_temp
  echo "Installed $grid_file_count pinned PROJ-data transformation grids."
}

verify_qgis3_image() {
  local qgis_exit_code=0
  local qgis_output=""
  local qgis_version=""

  if qgis_output="$(docker run --rm --network none --entrypoint /usr/bin/python3 \
    "$QFC_QGIS3_IMAGE" -c \
    'from qgis.core import Qgis; print("QFC_QGIS_VERSION=" + Qgis.QGIS_VERSION)' 2>&1)"; then
    :
  else
    qgis_exit_code=$?
    echo "The pinned QGIS 3 image could not run its Python 3 verification (exit code $qgis_exit_code)." >&2
    printf '%s\n' "$qgis_output" >&2
    exit "$qgis_exit_code"
  fi
  qgis_version="$(sed -n 's/^QFC_QGIS_VERSION=//p' <<<"$qgis_output" | tail -n 1 | tr -d '\r')"
  if [[ $qgis_version != "$QFC_QGIS3_EXPECTED_VERSION" ]] && \
    [[ $qgis_version != "$QFC_QGIS3_EXPECTED_VERSION"-* ]]; then
    echo "The pinned QGIS 3 image reported an unexpected version." >&2
    exit 1
  fi
  echo "Verified pinned QGIS version $qgis_version."
}

reconcile_auto_public_host() {
  local current_public_ipv4=""
  local current_public_host=""

  if [[ $auto_public_host != "true" ]]; then
    return 0
  fi
  current_public_ipv4="$(discover_public_ipv4)"
  current_public_host="${current_public_ipv4}.sslip.io"
  if [[ $current_public_host != "$public_host" ]]; then
    public_host="$current_public_host"
    configure_public_host_files
    write_runtime_env
    compose config --quiet
    echo "The public address changed while CloudFormation attached the static IP; host and certificate settings were refreshed."
  fi
}

compose config --quiet
compose pull db rustfs createbuckets smtp4dev memcached app nginx worker_wrapper ofelia
docker pull "$QFC_QGIS3_IMAGE"

compose up -d db rustfs smtp4dev memcached
compose run --rm --no-TTY createbuckets
compose run --rm --no-TTY app python manage.py migrate --noinput
compose run --rm --no-TTY app python manage.py migrate --check
compose run --rm --no-TTY app python manage.py collectstatic --noinput
prepare_transformation_grids
verify_qgis3_image
printf '%s\n' "$PROJ_DATA_RELEASE" >"$state_root/proj-data-release"
printf '%s\n' "$QFC_QGIS3_EXPECTED_VERSION" >"$state_root/qgis3-verified-version"
chmod 0600 "$state_root/proj-data-release" "$state_root/qgis3-verified-version"
reconcile_auto_public_host

certificate_sha256="$(openssl x509 -in "$cert_root/qfieldcloud.pem" -outform DER \
  | sha256sum | awk '{print $1}')"
if [[ ! $certificate_sha256 =~ ^[0-9a-f]{64}$ ]]; then
  echo "The pilot certificate SHA-256 fingerprint could not be calculated." >&2
  exit 1
fi
# Backup recovery and every later health gate validate this stored fingerprint
# against the live certificate. Publish it atomically only after the final
# static-IP hostname reconciliation has completed.
write_root_state_value certificate-sha256 "$certificate_sha256"

check_admin_account() {
  compose run --rm --no-TTY \
    -e "QFC_EXPECTED_ADMIN_USERNAME=$ADMIN_USERNAME" \
    -e "QFC_EXPECTED_ADMIN_EMAIL=$ADMIN_EMAIL" \
    app python manage.py shell -c '
import os
from django.contrib.auth import get_user_model

username = os.environ["QFC_EXPECTED_ADMIN_USERNAME"]
email = os.environ["QFC_EXPECTED_ADMIN_EMAIL"]
matches = get_user_model().objects.filter(username=username)
if not matches.exists():
    raise SystemExit(3)
user = matches.get()
raise SystemExit(0 if user.is_staff and user.is_superuser and user.email == email else 4)
'
}

admin_check_exit=0
check_admin_account || admin_check_exit=$?
if [[ $admin_check_exit -eq 3 ]]; then
  printf '%s' "$ADMIN_PASSWORD" | compose run --rm --no-TTY \
    -e "QFC_BOOTSTRAP_ADMIN_USERNAME=$ADMIN_USERNAME" \
    -e "QFC_BOOTSTRAP_ADMIN_EMAIL=$ADMIN_EMAIL" \
    app python manage.py shell -c '
import os
import sys
from django.contrib.auth import get_user_model

password = sys.stdin.read()
if not password:
    raise SystemExit("empty bootstrap password")
get_user_model().objects.create_superuser(
    username=os.environ["QFC_BOOTSTRAP_ADMIN_USERNAME"],
    email=os.environ["QFC_BOOTSTRAP_ADMIN_EMAIL"],
    password=password,
)
'
  admin_check_exit=0
  check_admin_account || admin_check_exit=$?
fi
if [[ $admin_check_exit -eq 4 ]]; then
  echo "The existing administrator does not have the expected email and superuser flags; refusing to modify it automatically." >&2
  exit 1
fi
if [[ $admin_check_exit -ne 0 ]]; then
  echo "Administrator account validation failed with exit code $admin_check_exit." >&2
  exit 1
fi
unset ADMIN_PASSWORD

compose up -d app nginx

health_ok="false"
for _ in $(seq 1 36); do
  # QFieldCloud v26.25 caches this view for 60 seconds. Force each readiness
  # attempt to observe the current database and object-storage connections.
  status_nonce="$(date -u +%s%N)-$$-${RANDOM}"
  status_json="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 20 \
    --cacert "$cert_root/qfieldcloud.pem" \
    --resolve "$public_host:443:127.0.0.1" \
    "https://$public_host/api/v1/status/?bootstrap_nonce=$status_nonce" || true)"
  if jq -e '.database == "ok" and .storage == "ok"' >/dev/null 2>&1 <<<"$status_json"; then
    health_ok="true"
    break
  fi
  sleep 10
done
if [[ $health_ok != "true" ]]; then
  echo "QFieldCloud health endpoint did not report database=ok and storage=ok." >&2
  exit 1
fi

compose up -d worker_wrapper ofelia
sleep 15
for long_running_service in worker_wrapper ofelia; do
  service_container_id="$(compose ps -q "$long_running_service")"
  if [[ -z $service_container_id ]] || \
    [[ $(docker inspect --format '{{ .State.Running }}' "$service_container_id") != "true" ]]; then
    echo "The $long_running_service service is not running." >&2
    exit 1
  fi
done

write_root_state_value installer-revision "$revision"
write_bootstrap_state services-ready
"$install_root/bin/worker-smoke-test.sh"

if [[ $auto_public_host == "true" ]]; then
  final_public_ipv4="$(discover_public_ipv4)"
  if [[ "${final_public_ipv4}.sslip.io" != "$public_host" ]]; then
    echo "The public address changed after services started; rerun the same pinned bootstrap before using the pilot." >&2
    exit 1
  fi
fi

existing_backup_ready="false"
if [[ -f $state_root/last-backup-path && ! -L $state_root/last-backup-path && \
      -f $state_root/last-backup-at && ! -L $state_root/last-backup-at ]]; then
  existing_backup_path="$(<"$state_root/last-backup-path")"
  existing_backup_at="$(<"$state_root/last-backup-at")"
  existing_backup_epoch="$(date --date="$existing_backup_at" +%s 2>/dev/null || true)"
  current_epoch="$(date -u +%s)"
  existing_backup_artifacts_ready="true"
  for backup_artifact in \
    data/database.dump data/object-storage.tar.gz data/media.tar.gz \
    sensitive/secrets.env versions.env compose.yaml public-host manifest.json SHA256SUMS; do
    if [[ ! -s $existing_backup_path/$backup_artifact ]] || \
      [[ -L $existing_backup_path/$backup_artifact ]]; then
      existing_backup_artifacts_ready="false"
      break
    fi
  done
  if [[ $existing_backup_path =~ ^/[A-Za-z0-9._/-]+$ ]] && \
    [[ $existing_backup_path != *"//"* ]] && \
    [[ $existing_backup_path != *"/./"* ]] && \
    [[ $existing_backup_path != *"/../"* ]] && \
    [[ $existing_backup_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && \
    [[ $existing_backup_epoch =~ ^[0-9]+$ ]] && \
    ((current_epoch >= existing_backup_epoch)) && \
    ((current_epoch - existing_backup_epoch <= 604800)) && \
    [[ $existing_backup_artifacts_ready == "true" ]] && \
    [[ -d $existing_backup_path && ! -L $existing_backup_path ]] && \
    [[ -f $existing_backup_path/manifest.json && ! -L $existing_backup_path/manifest.json ]] && \
    jq -e \
      --arg release "$QFIELDCLOUD_RELEASE" \
      --arg commit "$QFIELDCLOUD_COMMIT" \
      '.scope == "qfieldcloud-system-only" and .release == $release and
       .upstream_commit == $commit' \
      "$existing_backup_path/manifest.json" >/dev/null 2>&1; then
    existing_backup_ready="true"
  fi
fi
if [[ $existing_backup_ready != "true" ]]; then
  echo "Creating the initial root-only local pilot backup."
  "$install_root/bin/backup.sh"
else
  echo "Reusing the current release-matched local backup; no duplicate backup was created."
fi

echo "Running an isolated schema and storage integrity restore test."
"$install_root/bin/restore-test.sh"

write_bootstrap_state validating
if ! "$install_root/bin/health-check.sh" --installation-gate >/dev/null; then
  echo "The complete service, worker, backup, and restore validation gate failed." >&2
  exit 1
fi

write_root_state_value installer-revision "$revision"
write_root_state_value installer-manifest-sha256 "$source_manifest_sha256"
write_root_state_value installed-release "$QFIELDCLOUD_RELEASE"
set_install_intent_status complete success
# Publish ready last. If the post-publication assertion below fails, the EXIT
# trap atomically reverts install-intent to incomplete and bootstrap-status to
# failed, so an old success cannot survive a failed retry.
write_bootstrap_state ready

if ! "$install_root/bin/health-check.sh" >/dev/null; then
  echo "The completed installation markers did not pass the final health check." >&2
  exit 1
fi
write_root_state_value bootstrap-completed-at "$(date -u +%FT%TZ)"
bootstrap_succeeded="true"

echo "[$(date -u +%FT%TZ)] QFieldCloud $QFIELDCLOUD_RELEASE bootstrap completed."
echo "Public pilot URL: https://$public_host/"
echo "The certificate is self-signed; review the lab documentation before accepting it."
echo "Administrator credentials remain in a root-only file on the instance and were not printed."
