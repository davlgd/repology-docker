#!/usr/bin/env bash
#
# Download today's Repology dump and load it into the database.
#
# Run by the official postgres entrypoint, once, on first start against an
# empty volume. The server then listens on its unix socket only, so nobody
# can observe a half-restored database.
#
# Environment:
#   REPOLOGY_DUMPS_BASE              dump index root (default: https://dumps.repology.org)
#   REPOLOGY_DUMP_URL                a specific dump, bypassing resolution
#   REPOLOGY_SKIP_DUMP=1             start empty, extensions in place
#   REPOLOGY_IGNORE_VERSION_CHECK=1  bypass the PostgreSQL version check
#
set -euo pipefail

DUMPS_BASE="${REPOLOGY_DUMPS_BASE:-https://dumps.repology.org}"
DUMP_URL="${REPOLOGY_DUMP_URL:-}"

if [ "${REPOLOGY_SKIP_DUMP:-0}" = "1" ]; then
    echo "==> REPOLOGY_SKIP_DUMP=1, skipping the import"
    exit 0
fi

# Not -latest.sql.zst: the dated name carries the PostgreSQL version
# (...pg17.10.sql.zst), which lets us check compatibility before downloading
# 2.3 GiB.
if [ -z "$DUMP_URL" ]; then
    echo "==> Resolving newest dump on ${DUMPS_BASE}/"
    dump_file="$(
        curl -fsSL --retry 5 --retry-delay 5 "${DUMPS_BASE}/" \
            | grep -oE 'href="repology-database-dump-[^"]+\.sql\.zst"' \
            | sed -e 's/^href="//' -e 's/"$//' \
            | grep -v -- '-latest\.' \
            | sort \
            | tail -n 1
    )"
    if [ -z "$dump_file" ]; then
        echo "!! no dump found in the index at ${DUMPS_BASE}/" >&2
        exit 1
    fi
    DUMP_URL="${DUMPS_BASE}/${dump_file}"
fi

echo "==> Dump: ${DUMP_URL}"

# "May be compatible with later versions, definitely not compatible with
#  earlier versions." (dumps.repology.org)
dump_version="$(printf '%s' "${DUMP_URL##*/}" | grep -oE 'pg[0-9]+(\.[0-9]+)?' | head -n1 | cut -c3- || true)"
server_version="$(psql -tAX --username "$POSTGRES_USER" --dbname postgres -c 'SHOW server_version' | awk '{print $1}')"

if [ -n "$dump_version" ]; then
    oldest="$(printf '%s\n%s\n' "$dump_version" "$server_version" | sort -V | head -n1)"
    if [ "$oldest" != "$dump_version" ]; then
        echo "!! Dump made with PostgreSQL ${dump_version}, server runs ${server_version}." >&2
        echo "!! A dump never restores onto an older version." >&2
        echo "!! Raise the image tag (ARG PG_IMAGE in the Dockerfile)," >&2
        echo "!! or force with REPOLOGY_IGNORE_VERSION_CHECK=1." >&2
        [ "${REPOLOGY_IGNORE_VERSION_CHECK:-0}" = "1" ] || exit 1
    fi
    echo "==> Version check passed: dump pg${dump_version} -> server ${server_version}"
fi

echo "==> Importing into ${POSTGRES_DB} (~2.3 GiB to download, ~33 GiB on disk)"

# Database size tracks progress better than downloaded bytes, since most of
# the time goes into rebuilding indexes. curl's own meter would interleave
# unreadably with psql output.
(
    while sleep 120; do
        size="$(psql -tAX --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
                    -c "SELECT pg_size_pretty(pg_database_size('${POSTGRES_DB}'))" 2>/dev/null)" || continue
        echo "    ... importing, database at ${size}"
    done
) &
progress_pid=$!
trap 'kill "$progress_pid" 2>/dev/null || true' EXIT INT TERM

# ON_ERROR_STOP: failing outright beats a half-restored database with missing
# search indexes and broken functions.
curl -fL --no-progress-meter --retry 5 --retry-delay 5 "$DUMP_URL" \
    | zstd -dc \
    | psql -v ON_ERROR_STOP=1 --quiet --output /dev/null \
           --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"

kill "$progress_pid" 2>/dev/null || true
trap - EXIT

# PostgreSQL 17 dumps carry no planner statistics.
echo "==> ANALYZE"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c 'ANALYZE'

projects="$(psql -tAX --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -c 'SELECT count(*) FROM repology.metapackages' 2>/dev/null || echo '?')"
echo "==> Repology mirror ready (${projects} projects)"
