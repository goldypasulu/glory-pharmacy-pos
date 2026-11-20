#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Menerapkan perubahan skema Glory POS secara berurutan dan mencatatnya di
# tabel schema_migrations.
#
#   00001_baseline   = db/schema.sql (diterapkan bila database masih kosong;
#                      bila tabel Glory POS sudah ada, hanya dicatat)
#   db/migrations/NNNNN_deskripsi.sql (mulai 00002), masing-masing satu transaksi
#
# Pemakaian:
#   DB=glory_pos ./apply-migrations.sh
#   ./apply-migrations.sh glory_pos
#
# File migrasi berisi SQL murni TANPA BEGIN/COMMIT: script ini yang membungkus
# setiap file + pencatatan versinya dalam satu transaksi (psql --single-transaction).
# Aman dijalankan berulang: versi yang sudah tercatat dilewati.
# Koneksi memakai PGHOST / PGPORT / PGUSER / PGPASSWORD.
# -----------------------------------------------------------------------------
set -euo pipefail

DB="${1:-${DB:?Pakai: DB=<database> ./apply-migrations.sh}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")

"${PSQL[@]}" -c "SET client_min_messages = warning; CREATE TABLE IF NOT EXISTS schema_migrations (
  version    text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
)"

applied() {
  [ "$("${PSQL[@]}" -Atc "SELECT 1 FROM schema_migrations WHERE version = '$1'")" = "1" ]
}

BASELINE=00001_baseline
if ! applied "$BASELINE"; then
  if [ "$("${PSQL[@]}" -Atc "SELECT to_regclass('public.items') IS NOT NULL")" = "t" ]; then
    echo "==> $BASELINE: skema sudah ada, hanya dicatat"
    "${PSQL[@]}" -c "INSERT INTO schema_migrations (version) VALUES ('$BASELINE')"
  else
    echo "==> $BASELINE: menerapkan schema.sql"
    "${PSQL[@]}" --single-transaction -f "$HERE/schema.sql" \
      -c "INSERT INTO schema_migrations (version) VALUES ('$BASELINE')"
  fi
fi

shopt -s nullglob
for f in "$HERE"/migrations/*.sql; do
  name="$(basename "$f")"
  if [[ ! "$name" =~ ^[0-9]{5}_[a-z0-9_]+\.sql$ ]]; then
    echo "Nama file migrasi tidak valid: $name (format NNNNN_deskripsi.sql)" >&2
    exit 1
  fi
  version="${name%.sql}"
  applied "$version" && continue
  echo "==> $version"
  "${PSQL[@]}" --single-transaction -f "$f" \
    -c "INSERT INTO schema_migrations (version) VALUES ('$version')"
done
