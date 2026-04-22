#!/usr/bin/env bash
# MariaDB migration runner.
#
# Applies every *.sql and *.sh file in scripts/migrations/mariadb/ in
# lexicographic order, skipping files whose version is already recorded
# in the schema_migrations table. version = filename without extension.
#
# SQL migrations are piped into the `mariadb` client inside the
# Bitnami MariaDB pod via `kubectl exec -i` — no host-side mariadb/mysql
# client required. SH migrations run locally with MARIADB_* env vars
# exported; they may use the in-pod client the same way or any other
# path to the database.
#
# Fail-stop: a failing migration aborts the runner and is not recorded.
# See ADR-0004 (migration runner) and ADR-0005 (coexistence with
# seaql_migrations).
#
# Usage (typically invoked from init.sh, can be run directly):
#   ./scripts/run-migrations-mariadb.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="$SCRIPT_DIR/migrations/mariadb"

# ── MariaDB location (pod) and credentials ───────────────────────────────
export MARIADB_NAMESPACE="${MARIADB_NAMESPACE:-insight}"
export MARIADB_POD="${MARIADB_POD:-insight-mariadb-0}"
export MARIADB_CONTAINER="${MARIADB_CONTAINER:-mariadb}"
export MARIADB_USER="${MARIADB_USER:-insight}"
export MARIADB_PASSWORD="${MARIADB_PASSWORD:-insight-pass}"
export MARIADB_DB="${MARIADB_DB:-analytics}"
# Kept for SH-migration convenience (and for downstream seed scripts that
# still connect host-side via port-forward + pymysql).
export MARIADB_HOST="${MARIADB_HOST:-localhost}"
export MARIADB_PORT="${MARIADB_PORT:-3306}"
export MARIADB_URL="mysql://${MARIADB_USER}:${MARIADB_PASSWORD}@${MARIADB_HOST}:${MARIADB_PORT}/${MARIADB_DB}"

echo "=== MariaDB migrations (pod: $MARIADB_NAMESPACE/$MARIADB_POD) ==="

# Execute a SQL statement inside the MariaDB pod.
# Reads SQL from stdin, writes results to stdout, errors to stderr.
mariadb_exec() {
  kubectl -n "$MARIADB_NAMESPACE" exec -i "$MARIADB_POD" \
    -c "$MARIADB_CONTAINER" -- \
    mariadb -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -D "$MARIADB_DB" \
    --batch --skip-column-names "$@"
}

# ── Bootstrap schema_migrations ──────────────────────────────────────────
mariadb_exec <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     VARCHAR(255) NOT NULL PRIMARY KEY,
    applied_at  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL

# ── Load applied versions ────────────────────────────────────────────────
APPLIED_FILE="$(mktemp)"
trap 'rm -f "$APPLIED_FILE"' EXIT
mariadb_exec -e "SELECT version FROM schema_migrations" > "$APPLIED_FILE"

is_applied() {
  local version="$1"
  grep -Fx -- "$version" "$APPLIED_FILE" >/dev/null 2>&1
}

record_applied() {
  local version="$1"
  mariadb_exec -e "INSERT INTO schema_migrations (version) VALUES ('$version')"
}

# ── Enumerate pending migrations ─────────────────────────────────────────
if [ ! -d "$MIGRATIONS_DIR" ]; then
  echo "  No migrations directory ($MIGRATIONS_DIR) — nothing to do."
  exit 0
fi

shopt -s nullglob
migrations=("$MIGRATIONS_DIR"/*.sql "$MIGRATIONS_DIR"/*.sh)
shopt -u nullglob

if [ ${#migrations[@]} -eq 0 ]; then
  echo "  No migration files in $MIGRATIONS_DIR"
  exit 0
fi

IFS=$'\n' sorted_migrations=($(printf '%s\n' "${migrations[@]}" | sort))
unset IFS

applied_count=0
skipped_count=0

for file in "${sorted_migrations[@]}"; do
  name="$(basename "$file")"
  version="${name%.*}"   # filename without extension
  ext="${name##*.}"

  if is_applied "$version"; then
    echo "  skip    $name"
    skipped_count=$((skipped_count + 1))
    continue
  fi

  echo "  apply   $name"
  case "$ext" in
    sql)
      mariadb_exec < "$file"
      ;;
    sh)
      bash "$file"
      ;;
    *)
      echo "ERROR: unknown migration extension: $name" >&2
      exit 1
      ;;
  esac
  record_applied "$version"
  applied_count=$((applied_count + 1))
done

echo "=== Migrations done: applied=$applied_count, skipped=$skipped_count ==="
