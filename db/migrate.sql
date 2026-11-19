-- =============================================================================
-- Migrasi PERTAMA data iAbu (schema "legacy") -> skema Glory POS (schema "public").
-- Dijalankan oleh migrate.sh pada database kosong.
--
-- Isinya dipecah ke db/legacy/ agar dipakai bersama dengan reimport.sql:
--   helpers.sql       fungsi bantu (lid, wib, nz, clean_ed, conf)
--   master.sql        outlet, user, referensi, barang, satuan, harga, racikan (upsert)
--   transactions.sql  pembelian, batch, penjualan, opname, kartu stok, piutang
--   seed.sql          pengaturan awal dan kategori biaya (hanya migrasi pertama)
--
-- * Semua UUID diturunkan secara deterministik dari kunci legacy
--   (md5 -> uuid), jadi migrasi bisa diulang dan hasilnya identik.
-- * Timestamp legacy tanpa zona waktu dianggap WIB (Asia/Jakarta).
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;
\ir legacy/helpers.sql
\ir legacy/master.sql
\ir legacy/transactions.sql
\ir legacy/seed.sql
COMMIT;
