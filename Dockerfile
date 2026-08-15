# PostgreSQL with pg_trgm and libversion, loading the Repology dump on first
# start. Pinned to the version the dumps are produced with: a dump restores
# onto an equal or newer server, never an older one.
ARG PG_IMAGE=postgres:17.10-bookworm

FROM ${PG_IMAGE} AS builder

ARG LIBVERSION_REF=3.0.4
ARG PG_LIBVERSION_REF=2.0.1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake git pkg-config \
        "postgresql-server-dev-${PG_MAJOR}" \
    && rm -rf /var/lib/apt/lists/*

# Installed twice: into the builder so the extension links against it, and
# into /staging for the runtime image.
RUN git clone --depth 1 --branch "${LIBVERSION_REF}" \
        https://github.com/repology/libversion.git /src/libversion \
    && cmake -S /src/libversion -B /src/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_INSTALL_LIBDIR=lib \
    && cmake --build /src/build -j "$(nproc)" \
    && cmake --install /src/build \
    && DESTDIR=/staging cmake --install /src/build \
    && ldconfig

RUN git clone --depth 1 --branch "${PG_LIBVERSION_REF}" \
        https://github.com/repology/postgresql-libversion.git /src/pg-libversion \
    && make -C /src/pg-libversion -j "$(nproc)" \
    && make -C /src/pg-libversion install DESTDIR=/staging

FROM ${PG_IMAGE}

# curl downloads the dump, zstd decompresses it.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl zstd \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /staging/ /
RUN ldconfig

COPY initdb/ /docker-entrypoint-initdb.d/
