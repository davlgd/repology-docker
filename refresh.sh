#!/usr/bin/env bash
#
# Refresh the mirror with no meaningful downtime.
#
# The dump is destructive (pg_dump --clean): replaying it into the live
# database would leave it inconsistent for the whole restore. Instead we load
# into a sibling database, verify it, then swap by rename.
#
# Runs as a client, against any reachable server — a Kubernetes CronJob, a
# cron entry on a workstation, or by hand:
#
#   docker run --rm --network repology-net \
#       -e PGHOST=repology-db -e PGUSER=repology -e PGPASSWORD=… \
#       ghcr.io/davlgd/repology-mirror-db repology-refresh.sh
#
set -euo pipefail

DB="${REPOLOGY_DB:-repology}"
OWNER="${PGUSER:-repology}"
NEXT="${DB}_next"
OLD="${DB}_old"

# A truncated dump or a broken upstream must never replace a healthy database.
MIN_PROJECTS="${MIN_PROJECTS:-1500000}"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }

cleanup_failed() {
    log "failed: dropping $NEXT, the live database was left untouched"
    psql -d postgres -c "DROP DATABASE IF EXISTS $NEXT" >/dev/null 2>&1 || true
}

log "=== Repology mirror refresh ==="
trap cleanup_failed ERR

# Extensions need superuser and live per database: they follow neither the
# dump nor the rename.
psql -d postgres -c "DROP DATABASE IF EXISTS $NEXT" >/dev/null
psql -d postgres -c "CREATE DATABASE $NEXT OWNER $OWNER" >/dev/null
psql -d "$NEXT" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public" >/dev/null
psql -d "$NEXT" -c "CREATE EXTENSION IF NOT EXISTS libversion WITH SCHEMA public" >/dev/null
log "created $NEXT with its extensions"

# The import script is driven entirely by these two variables, so it loads the
# sibling without knowing it is being reused.
POSTGRES_USER="$OWNER" POSTGRES_DB="$NEXT" \
    /docker-entrypoint-initdb.d/20-load-dump.sh

projects="$(psql -tAX -d "$NEXT" -c 'SELECT count(*) FROM repology.metapackages')"
if [ "$projects" -lt "$MIN_PROJECTS" ]; then
    log "aborting: $projects projects, expected at least $MIN_PROJECTS"
    false
fi
exts="$(psql -tAX -d "$NEXT" -c "SELECT count(*) FROM pg_extension WHERE extname IN ('libversion','pg_trgm')")"
if [ "$exts" -ne 2 ]; then
    log "aborting: extensions missing from $NEXT"
    false
fi
log "verified: $projects projects, extensions in place"

trap - ERR

# Renaming requires zero connections to either database. Terminating the
# clients is enough: a pooled reader reconnects by name and lands on the new
# data by itself, which is the whole window of downtime.
psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                     WHERE datname IN ('$DB', '$NEXT') AND pid <> pg_backend_pid()" >/dev/null
psql -d postgres -c "ALTER DATABASE $DB RENAME TO $OLD" >/dev/null
psql -d postgres -c "ALTER DATABASE $NEXT RENAME TO $DB" >/dev/null
log "swap done"

psql -d postgres -c "DROP DATABASE $OLD" >/dev/null
log "old database dropped — finished ($projects projects)"
