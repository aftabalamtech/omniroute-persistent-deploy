#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
DB_PATH="$DATA_DIR/${OMNIROUTE_DB_FILENAME:-storage.sqlite}"
BACKUP_ENABLED="${GITHUB_BACKUP_ENABLED:-true}"
RUNTIME_DIR="${RUNTIME_DIR:-/app/runtime}"
BASE_SCHEMA="/app/backup/001_initial_schema.sql"

mkdir -p "$DATA_DIR" "$RUNTIME_DIR"
chown -R node:node "$DATA_DIR" 2>/dev/null || true

# Only a missing/corrupt SQLite file requires remote restore. A structurally
# valid legacy database is preserved and migrated forward instead of being
# replaced merely because it predates provider_connections.
database_needs_restore() {
  [[ -f "$DB_PATH" ]] || return 0
  if ! sqlite3 "$DB_PATH" 'PRAGMA quick_check;' 2>/dev/null | grep -qx 'ok'; then
    printf '[restore] existing SQLite database failed integrity check; recovery required\n' >&2
    return 0
  fi
  return 1
}

restore_needed=0
if [[ -f "$DB_PATH" ]]; then
  if database_needs_restore; then
    restore_needed=1
  else
    printf '[restore] existing SQLite database validated; preserving it for migration\n'
  fi
else
  printf '[restore] empty data directory detected\n'
  restore_needed=1
fi

if (( restore_needed )); then
  if [[ "$BACKUP_ENABLED" == "true" && -n "${GITHUB_BACKUP_REPO:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
    restore_attempt=0
    restore_backoff="${RESTORE_RETRY_SECONDS:-60}"
    while :; do
      set +e
      RESTORE_ALLOW_INVALID_LOCAL=true /app/backup/restore.sh
      restore_status=$?
      set -e
      if [[ "$restore_status" -eq 0 || "$restore_status" -eq 10 ]]; then
        break
      fi
      restore_attempt=$((restore_attempt + 1))
      printf '[restore] ERROR: validated backup unavailable; retry %s in %ss\n' "$restore_attempt" "$restore_backoff" >&2
      sleep "$restore_backoff"
      if (( restore_backoff < 3600 )); then
        restore_backoff=$((restore_backoff * 2))
        (( restore_backoff > 3600 )) && restore_backoff=3600
      fi
    done
  else
    printf '[restore] ERROR: database recovery is required but GitHub backup credentials are not configured\n' >&2
    exit 1
  fi
fi

# bootstrap-env.mjs runs before OmniRoute's migration runner and directly
# queries provider_connections. Therefore the official v3.8.51 base schema must
# exist before the Node process starts. CREATE IF NOT EXISTS preserves all data.
if [[ ! -f "$BASE_SCHEMA" ]]; then
  printf '[bootstrap] ERROR: missing official base schema: %s\n' "$BASE_SCHEMA" >&2
  exit 1
fi
printf '[bootstrap] ensuring OmniRoute v3.8.51 base schema\n'
runuser -u node -- sqlite3 "$DB_PATH" < "$BASE_SCHEMA"

if ! sqlite3 "$DB_PATH" 'PRAGMA integrity_check;' 2>/dev/null | grep -qx 'ok'; then
  printf '[bootstrap] ERROR: SQLite integrity check failed after base schema preparation\n' >&2
  exit 1
fi
if ! sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='provider_connections' LIMIT 1;" 2>/dev/null | grep -qx '1'; then
  printf '[bootstrap] ERROR: provider_connections is still missing after base schema preparation\n' >&2
  exit 1
fi
printf '[bootstrap] base schema ready; OmniRoute migrations can continue\n'

app_pid=''
shutdown() {
  trap - TERM INT EXIT
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill -TERM "$app_pid" 2>/dev/null || true
  fi
  if [[ -n "${backup_pid:-}" ]] && kill -0 "$backup_pid" 2>/dev/null; then
    kill -TERM "$backup_pid" 2>/dev/null || true
  fi
}
trap shutdown TERM INT EXIT

# Start OmniRoute first. The backup scheduler must not race database migrations,
# bootstrap-env, or credential initialization.
runuser -u node -- /app/check-permissions.sh "$@" &
app_pid=$!

# Wait for the application to become HTTP-ready before starting the scheduler.
health_url="http://127.0.0.1:${PORT:-20128}/api/monitoring/health"
ready_timeout="${APP_READY_TIMEOUT_SECONDS:-180}"
ready=0
for ((i=0; i<ready_timeout; i++)); do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    set +e
    wait "$app_pid"
    status=$?
    set -e
    exit "$status"
  fi
  if curl -fsS --max-time 2 "$health_url" >/dev/null 2>&1; then
    ready=1
    printf '[startup] OmniRoute HTTP readiness confirmed\n'
    break
  fi
  sleep 1
done

if (( ! ready )); then
  printf '[startup] ERROR: OmniRoute did not become HTTP-ready within %ss\n' "$ready_timeout" >&2
  exit 1
fi

backup_pid=''
if [[ "$BACKUP_ENABLED" == "true" && -n "${GITHUB_BACKUP_REPO:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
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

set +e
wait "$app_pid"
status=$?
set -e
shutdown
exit "$status"
