#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
mkdir -p "$DATA_DIR" /app/runtime

# Railway volumes are commonly mounted root-owned on first attach. Repair only
# the application directory, never the whole container filesystem.
chown -R node:node "$DATA_DIR" 2>/dev/null || true

if [[ "${GITHUB_BACKUP_ENABLED:-true}" == "true" && ! -e "$DATA_DIR/${OMNIROUTE_DB_FILENAME:-storage.sqlite}" ]]; then
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

if [[ "${GITHUB_BACKUP_ENABLED:-true}" == "true" && -n "${GITHUB_BACKUP_REPO:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
  /app/backup/backup.sh &
  backup_pid=$!
  trap 'kill "$backup_pid" 2>/dev/null || true' EXIT INT TERM
fi

# Preserve the official image startup command and permission checks.
exec runuser -u node -- /app/check-permissions.sh "$@"
