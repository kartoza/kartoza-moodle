#!/bin/bash
# entrypoint.sh — Moodle container entrypoint
#
# Responsibilities:
#   1. Wait for PostgreSQL to be reachable
#   2. Validate config.php is mounted
#   3. Optionally start cron (when MOODLE_CRON=true)
#   4. Fix moodledata permissions
#   5. Hand off to CMD (apache2-foreground or php for CLI jobs)
#
# Environment variables:
#   DB_HOST            — PostgreSQL host (required)
#   DB_PORT            — PostgreSQL port (default: 5432)
#   DB_NAME            — Database name (required)
#   DB_USER            — Database user (required)
#   MOODLE_DB_PASSWORD — Database password (required)
#   MOODLE_CRON        — Set to "true" to start the cron daemon (default: false)
#   MOODLE_DATAROOT    — Path to moodledata (default: /var/moodledata)
#   SKIP_DB_WAIT       — Set to "true" to skip the DB readiness check

set -euo pipefail

: "${DB_HOST:?DB_HOST is required}"
: "${DB_PORT:=5432}"
: "${DB_NAME:?DB_NAME is required}"
: "${DB_USER:?DB_USER is required}"
: "${MOODLE_DB_PASSWORD:?MOODLE_DB_PASSWORD is required}"
: "${MOODLE_DATAROOT:=/var/moodledata}"
: "${MOODLE_CRON:=false}"
: "${SKIP_DB_WAIT:=false}"

# ── Colours for log output ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[moodle]${NC} $*"; }
warn() { echo -e "${YELLOW}[moodle]${NC} $*"; }
err()  { echo -e "${RED}[moodle]${NC} $*" >&2; }

# ── 1. Wait for PostgreSQL ───────────────────────────────────────────────────
if [[ "${SKIP_DB_WAIT}" != "true" ]]; then
  log "Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}..."
  RETRIES=60
  until PGPASSWORD="${MOODLE_DB_PASSWORD}" pg_isready \
      -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
      -q 2>/dev/null; do
    RETRIES=$((RETRIES - 1))
    if [[ ${RETRIES} -le 0 ]]; then
      err "PostgreSQL not reachable after 5 minutes — aborting."
      exit 1
    fi
    warn "  DB not ready yet (${RETRIES} retries left)..."
    sleep 5
  done
  log "PostgreSQL is ready."
fi

# ── 2. Validate config.php ───────────────────────────────────────────────────
CONFIG_FILE="/var/www/html/config.php"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  err "config.php not found at ${CONFIG_FILE}."
  err "Mount it via a Kubernetes ConfigMap/Secret:"
  err "  volumeMounts:"
  err "    - name: moodle-config"
  err "      mountPath: /var/www/html/config.php"
  err "      subPath: config.php"
  exit 1
fi
log "config.php found."

# ── 3. Ensure moodledata directory exists with correct permissions ───────────
mkdir -p "${MOODLE_DATAROOT}"
chown -R www-data:www-data "${MOODLE_DATAROOT}"
chmod 0777 "${MOODLE_DATAROOT}"
log "moodledata directory ready at ${MOODLE_DATAROOT}."

# ── 4. Start cron daemon (only for the cron sidecar / standalone cron pod) ──
if [[ "${MOODLE_CRON}" == "true" ]]; then
  log "Starting Moodle cron daemon..."
  service cron start
  log "Cron started."
fi

# ── 5. Purge caches on startup (optional — useful after image upgrades) ──────
if [[ "${MOODLE_PURGE_CACHES_ON_START:-false}" == "true" ]]; then
  log "Purging Moodle caches..."
  su -s /bin/bash www-data -c \
    "php /var/www/html/admin/cli/purge_caches.php" || warn "Cache purge failed (may be OK on first boot)."
fi

# ── 6. Hand off to CMD ───────────────────────────────────────────────────────
log "Starting: $*"
exec "$@"
