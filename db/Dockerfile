# Citus + PostGIS on PostgreSQL 16, built on the multi-arch postgres image so
# Apple Silicon runs natively (the citusdata/citus image is amd64-only).
# Citus debs come from packagecloud; PostGIS comes from PGDG (already
# configured in the base image). Citus is not preloaded by the stock image —
# docker-compose passes `-c shared_preload_libraries=citus`.
FROM postgres:16-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
 && curl -fsSL https://packagecloud.io/citusdata/community/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/citusdata-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/citusdata-archive-keyring.gpg] https://packagecloud.io/citusdata/community/debian/ bookworm main" \
      > /etc/apt/sources.list.d/citusdata-community.list \
 && apt-get update \
 # Upgrade the pinned server minor too: postgis-3.so is built against the
 # latest PG 16 and fails to load with undefined symbols on an older one.
 && apt-get install -y --no-install-recommends \
      postgresql-16 \
      postgresql-16-citus-13.4 \
      postgresql-16-postgis-3 \
 && rm -rf /var/lib/apt/lists/*
