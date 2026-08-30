#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
DB_PATH="$DATA_DIR/${OMNIROUTE_DB_FILENAME:-storage.sqlite}"
BACKUP_ENABLED="${GITHUB_BACKUP_ENABLED:-true}"

mkdir -p "$DATA_DIR" /app/runtime
# Railway volumes may arrive root-owned on first attach. Repair only the data
# directory; the official application remains under /app.
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
  # Start the scheduler before the application, but keep this shell as PID 1
  # so signals and child lifecycle are supervised rather than orphaned by exec.
  /app/backup/backup.sh &
  backup_pid=$!
  printf '[backup] scheduler process started (interval=%sm)\n' "${BACKUP_INTERVAL_MINUTES:-10}"
else
  printf '[backup] scheduler disabled: credentials or GITHUB_BACKUP_ENABLED are not configured\n'
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

# Preserve the official image entrypoint and command, but run them as the
# upstream non-root node user. The shell remains PID 1 for supervision.
runuser -u node -- /app/check-permissions.sh "$@" &
app_pid=$!
set +e
wait "$app_pid"
status=$?
set -e
shutdown
exit "$status"
