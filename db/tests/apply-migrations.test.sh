#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tes otomatis db/apply-migrations.sh. Dijalankan di container PostgreSQL dev:
#   make test-scripts      (bagian dari make check)
#
# Memakai salinan apply-migrations.sh + schema.sql di folder sementara dengan
# migrasi contoh, terhadap database sekali pakai. db/migrations asli tidak disentuh.
# -----------------------------------------------------------------------------
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
DB="glorypos_scripttest_$$"
DB2="${DB}_lama"

# Folder kerja (beberapa KB) sengaja ditinggal di /tmp container dev yang sekali pakai.
cleanup() {
  dropdb --if-exists "$DB" >/dev/null 2>&1 || true
  dropdb --if-exists "$DB2" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cp "$SRC/apply-migrations.sh" "$SRC/schema.sql" "$WORK/"
mkdir "$WORK/migrations"

PASSED=0
fail() { echo "GAGAL: $*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); echo "ok  $*"; }
q()    { psql -X -q -d "$1" -Atc "$2"; }
versions() { q "$1" "SELECT string_agg(version, ',' ORDER BY version) FROM schema_migrations"; }
run()  { "$WORK/apply-migrations.sh" "$1"; }

# 1. Database kosong: baseline diterapkan.
createdb "$DB"
run "$DB" >/dev/null
[ "$(versions "$DB")" = "00001_baseline" ] || fail "versi setelah baseline: $(versions "$DB")"
[ "$(q "$DB" "SELECT to_regclass('public.items') IS NOT NULL")" = "t" ] || fail "schema.sql tidak diterapkan"
ok "database kosong -> 00001_baseline diterapkan"

# 2. Migrasi sukses lalu migrasi gagal: yang gagal di-rollback penuh dan tidak tercatat.
echo "CREATE TABLE tes_a (x int);" > "$WORK/migrations/00002_tes_a.sql"
printf 'CREATE TABLE tes_b (x int);\nSELECT 1/0;\n' > "$WORK/migrations/00003_tes_b.sql"
if run "$DB" >/dev/null 2>&1; then fail "runner harus gagal saat migrasi error"; fi
[ "$(versions "$DB")" = "00001_baseline,00002_tes_a" ] || fail "versi setelah gagal: $(versions "$DB")"
[ "$(q "$DB" "SELECT to_regclass('tes_a') IS NOT NULL, to_regclass('tes_b') IS NOT NULL")" = "t|f" ] \
  || fail "migrasi gagal meninggalkan sisa"
ok "migrasi gagal -> exit != 0, rollback penuh, versi tidak tercatat"

# 3. Setelah diperbaiki: lanjut dari yang gagal; dijalankan lagi tidak melakukan apa-apa.
echo "CREATE TABLE tes_b (x int);" > "$WORK/migrations/00003_tes_b.sql"
out="$(run "$DB")"
[ "$out" = "==> 00003_tes_b" ] || fail "run perbaikan harus hanya 00003, keluaran: $out"
out="$(run "$DB")"
[ -z "$out" ] || fail "run ulang harus diam, keluaran: $out"
[ "$(versions "$DB")" = "00001_baseline,00002_tes_a,00003_tes_b" ] || fail "versi akhir: $(versions "$DB")"
ok "lanjut dari migrasi yang gagal; run ulang idempoten dan diam"

# 4. Database lama (skema sudah ada, belum punya schema_migrations): baseline hanya dicatat.
createdb "$DB2"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB2" -f "$WORK/schema.sql" >/dev/null
out="$(run "$DB2")"
grep -q "00001_baseline: skema sudah ada, hanya dicatat" <<<"$out" || fail "baseline lama: $out"
[ "$(versions "$DB2")" = "00001_baseline,00002_tes_a,00003_tes_b" ] || fail "versi db lama: $(versions "$DB2")"
ok "database lama -> baseline dicatat tanpa diterapkan ulang"

# 5. Nama file salah ditolak sebelum migrasi mana pun dijalankan (termasuk yang urutannya lebih awal).
echo "CREATE TABLE tes_c (x int);" > "$WORK/migrations/00004_tes_c.sql"
echo "SELECT 1;" > "$WORK/migrations/4_Salah.sql"
if out="$(run "$DB" 2>&1)"; then fail "nama file salah harus ditolak"; fi
grep -q "Nama file migrasi tidak valid: 4_Salah.sql" <<<"$out" || fail "pesan nama salah: $out"
[ "$(q "$DB" "SELECT to_regclass('tes_c') IS NULL")" = "t" ] || fail "00004 sempat dijalankan padahal ada nama salah"
ok "nama file migrasi salah ditolak sebelum migrasi apa pun jalan"

echo "apply-migrations.sh: $PASSED/5 tes lulus"
