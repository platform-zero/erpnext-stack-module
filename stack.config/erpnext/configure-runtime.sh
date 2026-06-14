#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[erpnext-configurator] %s\n' "$*" >&2
}

BENCH_DIR="/home/frappe/frappe-bench"
SITE_NAME="${ERPNEXT_SITE_NAME:-erpnext.${DOMAIN}}"
DB_HOST="${DB_HOST:-mariadb}"
DB_PORT="${DB_PORT:-3306}"
REDIS_CACHE="${REDIS_CACHE:?missing REDIS_CACHE}"
REDIS_QUEUE="${REDIS_QUEUE:?missing REDIS_QUEUE}"
SOCKETIO_PORT="${SOCKETIO_PORT:-9000}"
HOST_URL="${ERPNEXT_HOST_URL:-https://${SITE_NAME}}"

cd "$BENCH_DIR"

log "writing bench app inventory"
ls -1 apps > sites/apps.txt

log "configuring database and redis endpoints"
bench set-config -g db_host "$DB_HOST"
bench set-config -gp db_port "$DB_PORT"
bench set-config -g redis_cache "redis://$REDIS_CACHE"
bench set-config -g redis_queue "redis://$REDIS_QUEUE"
bench set-config -g redis_socketio "redis://$REDIS_QUEUE"
bench set-config -gp socketio_port "$SOCKETIO_PORT"
bench set-config -g chromium_path /usr/bin/chromium-headless-shell
bench set-config -g host_name "$HOST_URL"

log "runtime bench configuration is ready"
