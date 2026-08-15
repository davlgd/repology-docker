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

# Inherited from the database container's own environment, this would make the
# import a no-op and the swap replace live data with an empty database. The
# verification below catches it, but far less legibly than saying so here.
if [ "${REPOLOGY_SKIP_DUMP:-0}" = "1" ]; then
    log "refusing to run with REPOLOGY_SKIP_DUMP=1"
    exit 1
fi

log "=== Repology mirror refresh ==="
trap cleanup_failed ERR

# Extensions need superuser and live per database: they follow neither the
# dump nor the rename.
psql -d postgres -c "DROP DATABASE IF EXISTS $NEXT" >/dev/null
psql -d postgres -c "CREATE DATABASE $NEXT OWNER $OWNER" >/dev/null
psql -d "$NEXT" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public" >/dev/null
psql -d "$NEXT" -c "CREATE EXTENSION IF NOT EXISTS libversion WITH SCHEMA public" >/dev/null
log "created $NEXT with its extensions"

# Default privileges live in the database, so the fresh one inherits none of
# them: without this the webapp loses its access at the swap.
POSTGRES_USER="$OWNER" /docker-entrypoint-initdb.d/15-readonly.sh "$NEXT"

# The import script is driven entirely by these two variables, so it loads the
# sibling without knowing it is being reused.
POSTGRES_USER="$OWNER" POSTGRES_DB="$NEXT" \
    /docker-entrypoint-initdb.d/20-load-dump.sh

# Again, now that the tables exist: default privileges cover object types, so
# the INSERT the report form needs could not be granted before the import.
POSTGRES_USER="$OWNER" /docker-entrypoint-initdb.d/15-readonly.sh "$NEXT"

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

# A database can be perfectly valid and still unusable: the counts above pass
# while the reader has no rights on it, and the site serves errors from a
# mirror that looks healthy. Check as the role that actually serves traffic.
if [ -n "${REPOLOGY_RO_PASSWORD:-}" ]; then
    PGPASSWORD="$REPOLOGY_RO_PASSWORD" psql -tAX -U repology_ro -d "$NEXT" \
        -c 'SELECT count(*) FROM repology.metapackages' >/dev/null
    log "verified: repology_ro can read $NEXT"
fi

log "verified: $projects projects, extensions in place"

trap - ERR

# Renaming requires zero connections to either database. Terminating the
# clients is enough: a pooled reader reconnects by name and lands on the new
# data by itself, which is the whole window of downtime.
#
# client backend only: pg_stat_activity also lists parallel workers, and
# killing one of those is an abnormal exit as far as the postmaster is
# concerned — it restarts the whole cluster into crash recovery.
psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                     WHERE datname IN ('$DB', '$NEXT')
                       AND backend_type = 'client backend'
                       AND pid <> pg_backend_pid()" >/dev/null
psql -d postgres -c "ALTER DATABASE $DB RENAME TO $OLD" >/dev/null
psql -d postgres -c "ALTER DATABASE $NEXT RENAME TO $DB" >/dev/null
log "swap done"

psql -d postgres -c "DROP DATABASE $OLD" >/dev/null
log "old database dropped — finished ($projects projects)"
