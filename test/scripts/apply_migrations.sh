#!/usr/bin/env bash
# Applies the test harness setup, then the OpenPlay migrations, to the local
# openplay_test database. Migrations 001-003 are substituted with the
# PostGIS-free local variants in test/sql/*.local.sql (see those files and
# the final report for why); every migration from 004 onward is the real,
# unmodified file from supabase/migrations/.
set -euo pipefail

export PGPASSWORD=postgres
PGBIN="/c/Program Files/PostgreSQL/17/bin"
PSQL="$PGBIN/psql.exe"
# Portable: resolve repo root relative to this script's own location instead
# of a hardcoded drive letter (this harness has been run from both H:\ and
# E:\ mounts of the same repo across sessions).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PGPORT_TEST=5433

run() {
  echo "=== $1 ==="
  "$PSQL" -p "$PGPORT_TEST" -U postgres -h localhost -d openplay_test -v ON_ERROR_STOP=1 -f "$1"
}

"$PSQL" -p "$PGPORT_TEST" -U postgres -h localhost -d postgres -c "DROP DATABASE IF EXISTS openplay_test;"
"$PSQL" -p "$PGPORT_TEST" -U postgres -h localhost -d postgres -c "CREATE DATABASE openplay_test;"

run "$ROOT/test/sql/000_test_harness_setup.sql"
run "$ROOT/test/sql/001_extensions_and_enums.local.sql"
run "$ROOT/test/sql/002_tables.local.sql"
run "$ROOT/test/sql/003_indexes.local.sql"

for f in "$ROOT"/supabase/migrations/20260910000*.sql; do
  base=$(basename "$f")
  num="${base:8:6}"
  if [[ "$num" == "000001" || "$num" == "000002" || "$num" == "000003" ]]; then
    continue # PostGIS-free local variants applied above instead
  fi
  if [[ "$num" == "000024" ]]; then
    continue # pg_cron is not installed in this local Postgres 17 build -- live-project-only (see the final report)
  fi
  run "$f"
done

echo "=== DONE ==="
