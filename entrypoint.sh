#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
DB_FILE="${OMNIROUTE_DB_FILENAME:-storage.sqlite}"
DB_PATH="$DATA_DIR/$DB_FILE"
BACKUP_ENABLED="${GITHUB_BACKUP_ENABLED:-true}"
PORT="${PORT:-10000}"
HOSTNAME="0.0.0.0"
READY_TIMEOUT="${APP_READY_TIMEOUT_SECONDS:-300}"
export PORT HOSTNAME OMNIROUTE_PORT="$PORT" DASHBOARD_PORT="$PORT" API_PORT="$PORT" OMNIROUTE_HOSTNAME="$HOSTNAME"
printf '[port] HTTP server target: %s:%s\n' "$HOSTNAME" "$PORT"

mkdir -p "$DATA_DIR" /app/runtime
chown -R node:node "$DATA_DIR" 2>/dev/null || true

# Restore validates both existing and remote databases. Invalid local state is
# retained and quarantined only after a fully validated replacement is ready.
if [[ "$BACKUP_ENABLED" == "true" ]]; then
  if [[ -n "${GITHUB_BACKUP_REPO:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
    restore_backoff="${RESTORE_RETRY_SECONDS:-60}"
    while :; do
      set +e
      /app/backup/restore.sh
      restore_status=$?
      set -e
      if [[ "$restore_status" -eq 0 ]]; then
        break
      elif [[ "$restore_status" -eq 10 && ! -e "$DB_PATH" ]]; then
        break
      fi
      printf '[restore] ERROR: database not safely restorable; retrying in %ss\n' "$restore_backoff" >&2
      sleep "$restore_backoff"
      if (( restore_backoff < 3600 )); then
        restore_backoff=$((restore_backoff * 2))
        (( restore_backoff > 3600 )) && restore_backoff=3600
      fi
    done
  elif [[ -e "$DB_PATH" ]]; then
    printf '[restore] checking existing database\n'
    if ! /app/backup/validate-db.sh "$DB_PATH"; then
      printf '[restore] ERROR: existing database schema is invalid and backup credentials are not configured\n' >&2
      sleep 3600
    fi
  else
    printf '[restore] no backup credentials configured; starting with empty data directory\n'
  fi
else
  printf '[restore] automatic restore disabled\n'
fi

app_pid=''
backup_pid=''
shutdown() {
  trap - TERM INT EXIT
  if [[ -n "$backup_pid" ]] && kill -0 "$backup_pid" 2>/dev/null; then kill -TERM "$backup_pid" 2>/dev/null || true; fi
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then kill -TERM "$app_pid" 2>/dev/null || true; fi
}
trap shutdown TERM INT EXIT

# Start the official application first. The backup scheduler is started only
# after the real health endpoint responds, so it cannot race bootstrap/migrations.
runuser -u node -- env \
  PORT="$PORT" OMNIROUTE_PORT="$PORT" DASHBOARD_PORT="$PORT" API_PORT="$PORT" \
  HOSTNAME="$HOSTNAME" OMNIROUTE_HOSTNAME="$HOSTNAME" \
  /app/check-permissions.sh "$@" &
app_pid=$!
printf '[bootstrap] OmniRoute process started; waiting for application readiness\n'
ready=0
for ((i=0; i<READY_TIMEOUT; i++)); do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    set +e; wait "$app_pid"; status=$?; set -e
    printf '[bootstrap] ERROR: OmniRoute exited before readiness (status %s)\n' "$status" >&2
    exit "$status"
  fi
  if curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:${PORT}/api/monitoring/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if (( ready == 0 )); then
  printf '[bootstrap] ERROR: OmniRoute readiness timeout after %ss\n' "$READY_TIMEOUT" >&2
  shutdown
  exit 1
fi
printf '[bootstrap] OmniRoute ready\n'

if [[ "$BACKUP_ENABLED" == "true" && -n "${GITHUB_BACKUP_REPO:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
  /app/backup/backup.sh &
  backup_pid=$!
  printf '[backup] scheduler started (interval=%sm)\n' "${BACKUP_INTERVAL_MINUTES:-10}"
else
  printf '[backup] scheduler not started: configuration incomplete or disabled\n'
fi

set +e
wait "$app_pid"
status=$?
set -e
shutdown
exit "$status"
