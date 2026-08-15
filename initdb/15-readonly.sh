#!/usr/bin/env bash
#
# Create the read-only role the webapp connects as, and grant it what it needs.
#
# Runs before the dump loads, which is the whole point: ALTER DEFAULT
# PRIVILEGES only covers objects created afterwards, and the restore is what
# creates the schema and its tables.
#
# Also callable on its own, against a database that already holds data or one
# the refresh has just created:
#
#   /docker-entrypoint-initdb.d/15-readonly.sh repology_next
#
# Environment:
#   REPOLOGY_RO_PASSWORD   unset, this does nothing and the mirror behaves as before
#
set -euo pipefail

DB="${1:-${POSTGRES_DB:-repology}}"
OWNER="${POSTGRES_USER:-${PGUSER:-repology}}"

if [ -z "${REPOLOGY_RO_PASSWORD:-}" ]; then
    echo "==> REPOLOGY_RO_PASSWORD unset, skipping the read-only role"
    exit 0
fi

# Roles are cluster-wide, so one may already exist from an earlier database.
if [ "$(psql -tAX -U "$OWNER" -d "$DB" -c "SELECT 1 FROM pg_roles WHERE rolname = 'repology_ro'")" = "1" ]; then
    verb=ALTER
else
    verb=CREATE
fi

# Everything in one heredoc: psql interpolates variables on standard input but
# not in -c, and :'pw' is what keeps quoting the password out of the shell.
psql -v ON_ERROR_STOP=1 -X -q -U "$OWNER" -d "$DB" \
     -v verb="$verb" -v pw="$REPOLOGY_RO_PASSWORD" <<SQL
:verb ROLE repology_ro LOGIN PASSWORD :'pw';

-- The default search_path is "\$user", public: a role named repology_ro would
-- look for a schema of that name and find nothing. The dump puts everything in
-- schema repology and its queries do not qualify it.
ALTER ROLE repology_ro SET search_path = repology, public;

-- For everything the restore is about to create. pg_default_acl is per
-- database and a fresh one inherits nothing, which is why the refresh calls
-- this again on the database it builds.
ALTER DEFAULT PRIVILEGES FOR ROLE $OWNER GRANT USAGE ON SCHEMAS TO repology_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE $OWNER GRANT SELECT ON TABLES TO repology_ro;

-- And for what is already there, when this runs against a loaded database.
DO \$\$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'repology') THEN
        EXECUTE 'GRANT USAGE ON SCHEMA repology TO repology_ro';
        EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA repology TO repology_ro';
    END IF;
    -- The one table the webapp writes to, behind the "report a problem" form.
    -- Its id is an identity column, so no sequence privilege is involved.
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'repology' AND tablename = 'reports') THEN
        EXECUTE 'GRANT INSERT ON repology.reports TO repology_ro';
    END IF;
END
\$\$;
SQL

echo "==> read-only role repology_ro ready on ${DB}"
