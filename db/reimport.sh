#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Impor ulang backup iAbu TERBARU ke database Glory POS yang sudah berjalan,
# tanpa menghapus database. Password, PIN, perangkat kasir, pengaturan, barcode,
# golongan obat, zat aktif, dan biaya operasional tetap utuh.
#
# Pakai selama masa uji, saat iAbu masih dipakai berjualan dan Glory POS
# dipakai untuk memantau / mencoba. Setelah iAbu dimatikan, script ini tidak
# dipakai lagi (dan akan menolak jalan begitu ada transaksi buatan Glory POS).
#
# Pemakaian:
#   ./reimport.sh /path/GLORY_terbaru.iAbu                 # DB default: glory_pos
#   DB=glory_pos BACKUP_DIR=/srv/backups ./reimport.sh backup.iAbu
#   ALLOW_OLDER=1 ./reimport.sh backup-lama.iAbu          # sengaja mundur ke backup lebih lama
#
# Sebelum mengubah apa pun, database disalin ke $BACKUP_DIR (pg_dump -Fc).
# Pulihkan dengan: pg_restore --clean --if-exists -d <DB> <file.dump>
#
# Butuh: PostgreSQL 15+ client + server, user dengan hak CREATEDB.
# Koneksi memakai PGHOST / PGPORT / PGUSER / PGPASSWORD.
# -----------------------------------------------------------------------------
set -euo pipefail

DUMP="${1:?Pakai: ./reimport.sh <file.iAbu>}"
DB="${DB:-glory_pos}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/glorypos-backups}"
ALLOW_OLDER="${ALLOW_OLDER:-0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP_DB="${DB}_reimport_tmp"

[ -f "$DUMP" ] || { echo "File tidak ditemukan: $DUMP" >&2; exit 1; }
PGVER=$(psql -d postgres -Atc "SHOW server_version_num")
[ "$PGVER" -ge 150000 ] || { echo "Butuh PostgreSQL 15+, server: $PGVER" >&2; exit 1; }

if [ "$(psql -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$DB'")" != "1" ]; then
  echo "Database $DB belum ada. Untuk migrasi pertama pakai ./migrate.sh" >&2; exit 1
fi
if [ "$(psql -d "$DB" -Atc "SELECT to_regclass('public.items') IS NOT NULL AND to_regclass('public.stock_batches') IS NOT NULL")" != "t" ]; then
  echo "Database $DB bukan database Glory POS (tabel items/stock_batches tidak ada)." >&2; exit 1
fi

cleanup() {
  dropdb --if-exists "$TMP_DB" >/dev/null 2>&1 || true
  psql -q -d "$DB" -c "DROP SCHEMA IF EXISTS legacy_incoming CASCADE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ "${SKIP_BACKUP:-0}" != "1" ]; then
  mkdir -p "$BACKUP_DIR"
  BACKUP_FILE="$BACKUP_DIR/${DB}-sebelum-reimport-$(date +%Y%m%d-%H%M%S).dump"
  echo "==> Backup database $DB ke $BACKUP_FILE"
  pg_dump -Fc -d "$DB" -f "$BACKUP_FILE"
fi

echo "==> Membaca backup iAbu ke database sementara"
dropdb --if-exists "$TMP_DB"
createdb "$TMP_DB"
# Exit code pg_restore diabaikan karena dump lama memicu error minor yang tidak fatal;
# keberhasilan restore diperiksa langsung dari tabel inti di bawah.
pg_restore --no-owner --no-privileges -d "$TMP_DB" "$DUMP" 2>&1 | grep -v "WITH OIDS" || true
for t in tbl_item tbl_ikhd tbl_ikdt tbl_imhd tbl_imdt tbl_item_im tbl_item_ik tbl_supel; do
  if [ "$(psql -d "$TMP_DB" -Atc "SELECT to_regclass('public.$t') IS NOT NULL")" != "t" ]; then
    echo "Restore gagal: tabel $t tidak ada. Periksa apakah file benar backup iAbu." >&2
    exit 1
  fi
done
psql -q -v ON_ERROR_STOP=1 -d "$TMP_DB" -c "ALTER SCHEMA public RENAME TO legacy_incoming"

echo "==> Menyalin backup ke schema legacy_incoming di $DB"
psql -q -d "$DB" -c "DROP SCHEMA IF EXISTS legacy_incoming CASCADE"
pg_dump --no-owner --no-privileges -n legacy_incoming -d "$TMP_DB" | psql -q -v ON_ERROR_STOP=1 -d "$DB" >/dev/null

echo "==> Impor ulang (satu transaksi; gagal = tidak ada yang berubah)"
psql -v ON_ERROR_STOP=1 -v allow_older="$ALLOW_OLDER" -d "$DB" -f "$HERE/reimport.sql"

echo "==> Validasi"
psql -v ON_ERROR_STOP=1 -d "$DB" -f "$HERE/validate.sql"

echo "==> Selesai. Database: $DB"
