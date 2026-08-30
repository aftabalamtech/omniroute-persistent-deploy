FROM diegosouzapw/omniroute:3.8.50

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl jq sqlite3 util-linux zstd \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /app/backup /app/data /app/runtime

COPY backup/ /app/backup/
COPY entrypoint.sh /usr/local/bin/omniroute-persistent-entrypoint

RUN chmod 0755 /app/backup/*.sh /usr/local/bin/omniroute-persistent-entrypoint \
    && chown -R node:node /app/backup /app/data /app/runtime

# Keep the persistent data location explicit and stable for Railway Volume mounts.
# OmniRoute's migration safety guard defaults to 50 pending migrations. This
# deployment can restore older/legacy databases whose migration tracking table
# is absent while their physical schema is already populated. In that recovery
# case the upstream runner must be allowed to reconcile/apply the full pending
# migration set. The migration runner records successful migrations, so after
# the first successful startup subsequent boots normally have few/no pending
# migrations and the bypass is no longer materially exercised.
ENV DATA_DIR=/app/data \
    PORT=20128 \
    HOSTNAME=0.0.0.0 \
    GITHUB_BACKUP_ENABLED=true \
    BACKUP_INTERVAL_MINUTES=10 \
    GITHUB_BACKUP_FILE=latest.db.zst \
    OMNIROUTE_DB_FILENAME=storage.sqlite \
    OMNIROUTE_MAX_PENDING_MIGRATIONS=0

EXPOSE 20128

ENTRYPOINT ["/usr/local/bin/omniroute-persistent-entrypoint"]
CMD ["node", "dev/run-standalone.mjs"]
