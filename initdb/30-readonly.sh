#!/usr/bin/env bash
#
# Same script again, now that the dump has landed.
#
# Default privileges cover object types, never a single table, so the INSERT on
# repology.reports that the "report a problem" form needs can only be granted
# once that table exists. The script is idempotent, hence running it twice
# rather than splitting the logic in two.
#
set -euo pipefail
exec /docker-entrypoint-initdb.d/15-readonly.sh "$@"
