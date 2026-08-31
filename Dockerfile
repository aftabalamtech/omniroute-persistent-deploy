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

# Render web services receive public traffic on the PORT environment variable.
ENV DATA_DIR=/app/data \
    PORT=10000 \
    HOSTNAME=0.0.0.0 \
    GITHUB_BACKUP_ENABLED=true \
    BACKUP_INTERVAL_MINUTES=10 \
    GITHUB_BACKUP_FILE=latest.db.zst \
    OMNIROUTE_DB_FILENAME=storage.sqlite

EXPOSE 10000

ENTRYPOINT ["/usr/local/bin/omniroute-persistent-entrypoint"]
# Render must start the main Next HTTP server directly on the Render-provided PORT.
# The internal WebSocket daemons are optional and must not be the public process.
CMD ["node", "server.js"]
