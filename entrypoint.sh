#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/app/app/data}"
DB_PATH="$DATA_DIR/${OMNIROUTE_DB_FILENAME:-storage.sqlite}"
BACKUP_ENABLED="${GITHUB_BACKUP_ENABLED:-true}"

mkdir -p "$DATA_DIR" /app/runtime
# The Railway Volume must be mounted at the actual OmniRoute persistent path.
# Repair only the data directory; never change ownership of the application tree.
chown -R node:node "$DATA_DIR" 2>/dev/null || true

if [[ "$BACKUP_ENABLED" == "true" && ! -e "$DB_PATH" ]]; then
  if [[ -n "${GITHUB_BACKUP_REPO:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
    set +e
    /app/backup/restore.sh
    restore_status=$?
    set -e
    if [[ "$restore_status" -eq 10 ]]; then
      :
    elif [[ "$restore_status" -ne 0 ]]; then
      exit "$restore_status"
    fi
  else
    printf '[restore] no backup credentials configured; starting with empty data directory\n'
  fi
else
  printf '[restore] existing data detected; skipping restore\n'
fi

backup_pid=''
if [[ "$BACKUP_ENABLED" == "true" && -n "${GITHUB_BACKUP_REPO:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
  # Keep this shell as PID 1 so the backup scheduler and official application
  # have predictable lifecycles and both receive termination signals.
  /app/backup/backup.sh &
  backup_pid=$!
  printf '[backup] scheduler process started (interval=%sm)\n' "${BACKUP_INTERVAL_MINUTES:-10}"
else
  if [[ "$BACKUP_ENABLED" != "true" ]]; then
    printf '[backup] scheduler disabled: GITHUB_BACKUP_ENABLED is not true\n'
  else
    [[ -n "${GITHUB_BACKUP_REPO:-}" ]] || printf '[backup] ERROR: GITHUB_BACKUP_REPO is not configured\n'
    [[ -n "${GITHUB_TOKEN:-}" ]] || printf '[backup] ERROR: GITHUB_TOKEN is not configured\n'
    printf '[backup] scheduler disabled until backup configuration is complete\n'
  fi
fi

app_pid=''
shutdown() {
  trap - TERM INT EXIT
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill -TERM "$app_pid" 2>/dev/null || true
  fi
  if [[ -n "$backup_pid" ]] && kill -0 "$backup_pid" 2>/dev/null; then
    kill -TERM "$backup_pid" 2>/dev/null || true
  fi
}
trap shutdown TERM INT EXIT

# Preserve the official image startup command while running it as the upstream
# non-root node user. The wrapper remains PID 1 for process supervision.
runuser -u node -- /app/check-permissions.sh "$@" &
app_pid=$!
set +e
wait "$app_pid"
status=$?
set -e
shutdown
exit "$status"
