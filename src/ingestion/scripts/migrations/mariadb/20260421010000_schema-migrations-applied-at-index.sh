#!/usr/bin/env bash
# Migration: add an index on schema_migrations(applied_at).
#
# Purpose:
#   Speed up "latest applied migration" queries — `SELECT MAX(applied_at)`
#   or `ORDER BY applied_at DESC LIMIT 1` — used by operators when
#   debugging apply order.
#
# This is also the first SH-style migration in the project. It doubles
# as a smoke test for the runner's `.sh` execution branch: the runner
# exports MARIADB_* env vars, invokes `bash file`, and records the
# version in `schema_migrations` on exit 0.
set -euo pipefail

kubectl -n "${MARIADB_NAMESPACE:?}" exec -i "${MARIADB_POD:?}" \
  -c "${MARIADB_CONTAINER:?}" -- \
  mariadb -u "${MARIADB_USER:?}" -p"${MARIADB_PASSWORD:?}" -D "${MARIADB_DB:?}" \
  --batch <<'SQL'
CREATE INDEX IF NOT EXISTS idx_schema_migrations_applied_at
    ON schema_migrations (applied_at);
SQL
