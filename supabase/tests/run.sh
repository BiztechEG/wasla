#!/usr/bin/env bash
# Runs the migrations and permission tests on a throwaway local PostgreSQL.
# Usage: supabase/tests/run.sh   (needs PostgreSQL 15+ binaries on PATH or in /usr/lib/postgresql)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
pgbin="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)"
export PATH="${pgbin:+$pgbin:}$PATH"

data="$(mktemp -d)"
port=55432
cleanup() { pg_ctl -D "$data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$data"; }
trap cleanup EXIT

initdb -D "$data" -U postgres --auth=trust >/dev/null
pg_ctl -D "$data" -o "-p $port -k $data -c listen_addresses=''" -w start >/dev/null

psql_run() { psql -h "$data" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }

psql_run -f "$here/auth_stub.sql"
for f in "$root"/supabase/migrations/*.sql; do
  echo "migrating $(basename "$f")"
  psql_run -f "$f"
done
for t in "$here"/*_test.sql; do
  echo "testing $(basename "$t")"
  psql_run -f "$t"
done
