#!/usr/bin/env bash
set -Eeuo pipefail

db_path="${1:?database path is required}"
[[ -f "$db_path" ]] || { printf '[db] ERROR: database file is missing\n' >&2; exit 1; }

sqlite3 "$db_path" 'PRAGMA integrity_check;' | grep -qx 'ok' || {
  printf '[db] ERROR: SQLite integrity check failed\n' >&2
  exit 1
}

# These tables are part of OmniRoute v3.8.50's initial schema and are required
# before bootstrap-env credential inspection is safe.
required='provider_connections provider_nodes key_value combos api_keys db_meta usage_history call_logs proxy_logs'
for table in $required; do
  exists="$(sqlite3 "$db_path" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='$table';")"
  [[ "$exists" == '1' ]] || {
    printf '[db] ERROR: required OmniRoute table is missing: %s\n' "$table" >&2
    exit 1
  }
done
printf '[db] OmniRoute schema validation passed\n'
