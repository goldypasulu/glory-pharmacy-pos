#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Migrasi backup iAbu (.iAbu = pg_dump custom format, PostgreSQL 8.4)
# ke database Glory POS.
#
# Pemakaian:
#   ./migrate.sh /path/GLORY_161126.iAbu            # DB tujuan default: glory_pos
#   DB=glory_pos_test ./migrate.sh backup.iAbu
#   KEEP_LEGACY=0 ./migrate.sh backup.iAbu          # hapus schema legacy setelah selesai
#
# Butuh: PostgreSQL 15+ (client + server; skema memakai NULLS NOT DISTINCT),
# user dengan hak CREATEDB.
# Koneksi memakai variabel standar PGHOST / PGPORT / PGUSER / PGPASSWORD.
# Script ini MENGHAPUS dan membuat ulang database tujuan.
# -----------------------------------------------------------------------------
set -euo pipefail

DUMP="${1:?Pakai: ./migrate.sh <file.iAbu>}"
DB="${DB:-glory_pos}"
KEEP_LEGACY="${KEEP_LEGACY:-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -f "$DUMP" ] || { echo "File tidak ditemukan: $DUMP" >&2; exit 1; }
PGVER=$(psql -d postgres -Atc "SHOW server_version_num")
[ "$PGVER" -ge 150000 ] || { echo "Butuh PostgreSQL 15+, server: $PGVER" >&2; exit 1; }

echo "==> Membuat ulang database $DB"
dropdb --if-exists "$DB"
createdb "$DB"

echo "==> Restore backup iAbu ke schema sementara"
# Dump PG 8.4 memakai WITH OIDS; pg_restore modern mengabaikannya (hanya warning).
# Exit code pg_restore diabaikan karena dump lama memicu error minor yang tidak
# fatal; keberhasilan restore diperiksa langsung dari tabel inti di bawah.
pg_restore --no-owner --no-privileges -d "$DB" "$DUMP" 2>&1 | grep -v "WITH OIDS" || true

for t in tbl_item tbl_ikhd tbl_ikdt tbl_imhd tbl_imdt tbl_item_im tbl_item_ik tbl_supel; do
  if [ "$(psql -d "$DB" -Atc "SELECT to_regclass('public.$t') IS NOT NULL")" != "t" ]; then
    echo "Restore gagal: tabel $t tidak ada. Periksa apakah file benar backup iAbu." >&2
    exit 1
  fi
done

psql -v ON_ERROR_STOP=1 -q -d "$DB" <<'SQL'
ALTER SCHEMA public RENAME TO legacy;
CREATE SCHEMA public;
SQL

echo "==> Membuat skema Glory POS"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$HERE/schema.sql"

echo "==> Migrasi data"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$HERE/migrate.sql"

echo "==> Validasi"
psql -v ON_ERROR_STOP=1 -d "$DB" -f "$HERE/validate.sql"

if [ "$KEEP_LEGACY" = "0" ]; then
  echo "==> Menghapus schema legacy"
  psql -q -d "$DB" -c "DROP SCHEMA legacy CASCADE;"
fi

echo "==> Selesai. Database: $DB"
