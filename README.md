# repology-docker

Container images for a private [Repology](https://repology.org) mirror —
package versions across ~650 distributions — plus the Kubernetes manifests to
run them.

Two images, built from source and published to GitHub Container Registry:

| Image | Contents |
|---|---|
| `ghcr.io/davlgd/repology-mirror-db` | PostgreSQL 17 with `pg_trgm` and `libversion`, loading the daily dump on first start |
| `ghcr.io/davlgd/repology-webapp` | `repology-webapp`, the official Rust frontend |

The dataset is roughly **2.1 million projects**, **33 GiB on disk**, and
**2.3 GiB to download**. A first import takes 20 to 40 minutes.

## Local

```sh
mise run up        # build, start, import (tens of minutes)
mise run logs      # follow the import
mise run verify    # extensions, version_compare2, similarity, row counts
mise run web-up    # build and start the webapp
mise run web-check # confirm it serves real data
```

The webapp then answers on <http://127.0.0.1:8080/> and PostgreSQL on
`127.0.0.1:5432` (`repology` / `repology`). `mise tasks` lists the rest:
`psql`, `top`, `dsn`, `refresh`, `clean`, `shell`.

## Kubernetes

```sh
mise run k8s-up       # namespace, secret, manifests
mise run k8s-status   # pods, import progress, address
```

The database is a `StatefulSet` on a `PersistentVolumeClaim`, the webapp a
`Deployment` behind a `LoadBalancer` service, and a `NetworkPolicy` keeps the
database reachable from the webapp alone. Prerequisites and the reasons behind
each choice: [k8s/README.md](k8s/README.md).

## How the images are rebuilt

`.github/workflows/images.yml` publishes both.

**The webapp** is checked nightly. `repology-rs` publishes no tag or release,
so the workflow compares the current `master` commit against the
`org.opencontainers.image.revision` label on the published image and builds
only when they differ — one registry lookup instead of a 20-minute Rust build.
The commit it built from is recorded on the new image, which is also how you
tell which revision is live:

```sh
docker buildx imagetools inspect ghcr.io/davlgd/repology-webapp:latest \
    --format '{{ index .Image.Config.Labels "org.opencontainers.image.revision" }}'
```

**The database** pins everything it compiles — `libversion` 3.0.4, the
extension 2.0.1, PostgreSQL 17.10 — so it is rebuilt monthly for base image
updates, and on any push touching its sources.

Both are **linux/amd64 only**: `rustc` segfaults under QEMU, and the runners
are amd64 anyway. `workflow_dispatch` triggers either by hand.

## Things worth knowing

These are the traps these images exist to avoid; each cost a debugging session.

**Extensions must exist before the dump.** The dump is made with `pg_dump
--clean --if-exists --no-owner` and its `CREATE EXTENSION` clauses are
commented out: it expects `pg_trgm` and `libversion` to already be installed
by a superuser. They must live in `public`, because the restore runs with an
empty `search_path` and references extension objects as `public.*` — for
instance `public.gin_trgm_ops` in the GIN indexes.

**The webapp does not connect as the owner.** `POSTGRES_USER` creates a
PostgreSQL *superuser*, and handing that to a web frontend would let a
compromise drop the mirror or run commands on the host through `COPY ... FROM
PROGRAM`. Set `REPOLOGY_RO_PASSWORD` and the image also creates `repology_ro`,
which may only `SELECT` — plus `INSERT` into `repology.reports`, the single
table the "report a problem" form writes to. Leave the variable unset and
nothing is created.

Two details make it work. `ALTER ROLE repology_ro SET search_path = repology,
public` is mandatory: the default is `"$user", public`, so a role of that name
would look for a schema of that name and find nothing. And the grants are
applied **twice** — before the dump, where `ALTER DEFAULT PRIVILEGES` covers
everything the restore is about to create, and after it, because default
privileges describe object types and can never name one table.

**`libversion` is packaged almost nowhere.** Repology lists the PostgreSQL
extension as `pgsql:libversion`, present only in openSUSE among the ~650
repositories it tracks — Debian, Ubuntu and Alpine have neither it nor the C
library. Both are therefore built from pinned sources in a builder stage.

**PostgreSQL version, one way only.** A dump restores onto the version it was
made with or a newer one, never an older one. The version is encoded in the
file name (`…pg17.10.sql.zst`), which is why `initdb/20-load-dump.sh` resolves
the *dated* dump rather than `-latest.sql.zst`: it compares against `SHOW
server_version` and fails before downloading 2.3 GiB.

**`ON_ERROR_STOP=1` is not optional.** Without it, a `psql` missing
`libversion` loads the database halfway and yields a silently broken mirror.

**`search_path` carries hidden meaning.** The dump puts everything in schema
`repology` while queries do not qualify it. It works because the default
`search_path` is `"$user", public` and the role is named `repology`. Rename
the role and nothing resolves.

**Name the role in the DSN.** Unlike libpq, `sqlx` does not fall back to the
system user; without a name the webapp tries to authenticate as `anonymous`.

**The webapp cannot use TLS to PostgreSQL.** Its `Cargo.toml` declares `sqlx`
with no TLS feature, so it connects in clear text and dies on `no pg_hba.conf
entry […] no encryption`.

**`fonts-dejavu-core` is required.** The webapp measures SVG badge text at
startup and panics when `DejaVuSans.ttf` is missing.

**An interrupted import leaves a silently incomplete database.** The volume
persists, so on restart the entrypoint finds a valid `PGDATA` and skips the
init scripts — including the import — for good. Check the project count, which
should be around 2.1 million; anything well below means starting over from an
empty volume.
