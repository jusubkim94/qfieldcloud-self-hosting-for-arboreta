#!/usr/bin/env bash
set -Eeuo pipefail

produce_launcher_stream() {
  cat <<'QFC_LAUNCHER_PREFIX'
set -Eeuo pipefail
bash -c 'cat >/dev/null' </dev/null
QFC_LAUNCHER_PREFIX
  # Keep the suffix outside Bash's initial input buffer. Without the
  # /dev/null redirect above, the child consumes this completion statement.
  sleep 0.2
  cat <<'QFC_LAUNCHER_SUFFIX'
printf '%s\n' 'launcher-completion-reached'
QFC_LAUNCHER_SUFFIX
}

result="$(produce_launcher_stream | bash -s)"
if [[ $result != 'launcher-completion-reached' ]]; then
  printf '%s\n' 'Launcher child-process input isolation validation failed.' >&2
  exit 1
fi

printf '%s\n' 'Launcher child-process input isolation validation passed.'
