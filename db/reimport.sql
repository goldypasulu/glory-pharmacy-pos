-- =============================================================================
-- IMPOR ULANG backup iAbu terbaru ke database Glory POS yang SUDAH berjalan.
-- Dijalankan oleh reimport.sh, yang lebih dulu memuat backup baru ke schema
-- legacy_incoming. Seluruh proses satu transaksi: gagal di mana pun = tidak ada
-- yang berubah.
--
-- Yang diperbarui dari iAbu : data master (kolom asal iAbu), transaksi, stok/batch, piutang.
-- Yang tidak disentuh       : password/PIN/peran user, perangkat kasir, pengaturan,
--                             outlet, biaya operasional, barcode, golongan obat,
--                             zat aktif, flag resep, harga khusus outlet.
-- Pengaman (legacy/guard.sql): menolak bila sudah ada transaksi buatan Glory POS,
-- backup lebih lama dari data yang ada, atau kode/nama yang bentrok.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

SELECT set_config('glorypos.allow_older', :'allow_older', true);

-- backup baru menggantikan schema legacy
DROP SCHEMA IF EXISTS legacy CASCADE;
ALTER SCHEMA legacy_incoming RENAME TO legacy;

\ir legacy/helpers.sql
\ir legacy/guard.sql

CREATE TEMP TABLE reimport_before ON COMMIT DROP AS
SELECT 'Barang' AS data, (SELECT count(*) FROM items WHERE legacy_ref IS NOT NULL) AS sebelum
UNION ALL SELECT 'Supplier/pelanggan', (SELECT count(*) FROM partners WHERE legacy_ref IS NOT NULL)
UNION ALL SELECT 'Nota penjualan',     (SELECT count(*) FROM sales)
UNION ALL SELECT 'Faktur pembelian',   (SELECT count(*) FROM purchases)
UNION ALL SELECT 'Batch stok aktif',   (SELECT count(*) FROM stock_batches WHERE deleted_at IS NULL)
UNION ALL SELECT 'Sesi stok opname',   (SELECT count(*) FROM stock_opnames)
UNION ALL SELECT 'Pembayaran piutang', (SELECT count(*) FROM debt_payments);

\ir legacy/master.sql
\ir legacy/transactions.sql

\echo
\echo '=== RINGKASAN IMPOR ULANG ==='
WITH after AS (
  SELECT 'Barang' AS data, (SELECT count(*) FROM items WHERE legacy_ref IS NOT NULL) AS sesudah
  UNION ALL SELECT 'Supplier/pelanggan', (SELECT count(*) FROM partners WHERE legacy_ref IS NOT NULL)
  UNION ALL SELECT 'Nota penjualan',     (SELECT count(*) FROM sales)
  UNION ALL SELECT 'Faktur pembelian',   (SELECT count(*) FROM purchases)
  UNION ALL SELECT 'Batch stok aktif',   (SELECT count(*) FROM stock_batches WHERE deleted_at IS NULL)
  UNION ALL SELECT 'Sesi stok opname',   (SELECT count(*) FROM stock_opnames)
  UNION ALL SELECT 'Pembayaran piutang', (SELECT count(*) FROM debt_payments)
)
SELECT b.data, b.sebelum, a.sesudah, a.sesudah - b.sebelum AS selisih
FROM reimport_before b JOIN after a USING (data);

\echo
\echo '=== BARIS YANG BERUBAH DAN AKAN DITARIK KASIR ==='
SELECT t AS tabel, n AS baris_berubah FROM (
  SELECT 'items' t, count(*) n FROM items WHERE sync_txid = pg_current_xact_id() UNION ALL
  SELECT 'item_units', count(*) FROM item_units WHERE sync_txid = pg_current_xact_id() UNION ALL
  SELECT 'item_prices', count(*) FROM item_prices WHERE sync_txid = pg_current_xact_id() UNION ALL
  SELECT 'item_components', count(*) FROM item_components WHERE sync_txid = pg_current_xact_id() UNION ALL
  SELECT 'partners', count(*) FROM partners WHERE sync_txid = pg_current_xact_id() UNION ALL
  SELECT 'users (baru)', count(*) FROM users WHERE sync_txid = pg_current_xact_id() UNION ALL
  SELECT 'stock_batches', count(*) FROM stock_batches WHERE sync_txid = pg_current_xact_id()
) x;

INSERT INTO audit_logs (action, entity, after)
SELECT 'legacy_reimport', 'database', jsonb_build_object(
  'transaksi_terakhir_backup', (SELECT max(legacy.wib(tanggal)) FROM legacy.tbl_ikhd),
  'nota_penjualan',            (SELECT count(*) FROM sales),
  'faktur_pembelian',          (SELECT count(*) FROM purchases));

COMMIT;
