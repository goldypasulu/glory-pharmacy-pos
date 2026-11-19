-- =============================================================================
-- Validasi hasil migrasi: setiap angka dibandingkan langsung dengan data legacy.
-- Kolom status: OK / BEDA. Bagian INFO hanya ringkasan untuk owner.
-- =============================================================================
\pset footer off
\echo
\echo '=== CEK KELENGKAPAN & KECOCOKAN ANGKA ==='
WITH checks(no, cek, legacy_value, new_value) AS (
  VALUES
  (1,  'Jumlah barang',
       (SELECT count(*) FROM legacy.tbl_item)::numeric,          (SELECT count(*) FROM items)::numeric),
  (2,  'Jumlah supplier/pelanggan/dokter/sales',
       (SELECT count(*) FROM legacy.tbl_supel),                  (SELECT count(*) FROM partners)),
  (3,  'Satuan barang (unik per barang+satuan)',
       (SELECT count(DISTINCT (kodeitem, upper(btrim(satuan)))) FROM legacy.tbl_itemsatuanjml),          (SELECT count(*) FROM item_units WHERE legacy_ref IS NOT NULL)),
  (4,  'Jumlah transaksi penjualan (KSR+JL+RJ)',
       (SELECT count(*) FROM legacy.tbl_ikhd),                   (SELECT count(*) FROM sales)),
  (5,  'Jumlah baris penjualan',
       (SELECT count(*) FROM legacy.tbl_ikdt),                   (SELECT count(*) FROM sale_lines)),
  (6,  'Total nilai penjualan kasir (KSR)',
       (SELECT sum(totalakhir) FROM legacy.tbl_ikhd WHERE tipe='KSR'), (SELECT sum(total) FROM sales WHERE type='pos')),
  (7,  'Total nilai faktur jual (JL)',
       (SELECT sum(totalakhir) FROM legacy.tbl_ikhd WHERE tipe='JL'),  (SELECT sum(total) FROM sales WHERE type='invoice')),
  (8,  'Total nilai retur jual (RJ)',
       (SELECT sum(totalakhir) FROM legacy.tbl_ikhd WHERE tipe='RJ'),  (SELECT sum(total) FROM sales WHERE type='return')),
  (9,  'Total HPP penjualan (FIFO, bersih retur)',
       (SELECT sum(jumlahdasar*hargadasar) FROM legacy.tbl_item_ik WHERE tipe IN ('KSR','JL'))
         - (SELECT sum(jumlahdasar*hargadasar) FROM legacy.tbl_item_ikret),
       (SELECT sum(CASE WHEN type='return' THEN -cogs_total ELSE cogs_total END) FROM sales)),
  (10, 'HPP header = jumlah HPP baris',
       (SELECT sum(cogs_total) FROM sales),                      (SELECT sum(cogs) FROM sale_lines)),
  (11, 'Transaksi dgn total pembayaran <> total nota',
       0,                                                        (SELECT count(*) FROM sales s
                                                                  WHERE abs(s.total - coalesce((SELECT sum(amount) FROM sale_payments p WHERE p.sale_id=s.id),0)) > 1)),
  (12, 'Jumlah pembelian (BL)',
       (SELECT count(*) FROM legacy.tbl_imhd WHERE tipe='BL'),   (SELECT count(*) FROM purchases)),
  (13, 'Jumlah baris pembelian',
       (SELECT count(*) FROM legacy.tbl_imdt d JOIN legacy.tbl_imhd h USING (notransaksi) WHERE h.tipe='BL'),
       (SELECT count(*) FROM purchase_lines)),
  (14, 'Total nilai pembelian',
       (SELECT sum(totalakhir) FROM legacy.tbl_imhd WHERE tipe='BL'), (SELECT sum(total) FROM purchases)),
  (15, 'Jumlah batch stok',
       (SELECT count(*) FROM legacy.tbl_item_im),                (SELECT count(*) FROM stock_batches)),
  (16, 'Jumlah mutasi stok (masuk+keluar+retur)',
       (SELECT count(*) FROM legacy.tbl_item_im) + (SELECT count(*) FROM legacy.tbl_item_ik)
         + (SELECT count(*) FROM legacy.tbl_item_ikret),         (SELECT count(*) FROM stock_movements)),
  (17, 'Total sisa stok (satuan dasar)',
       (SELECT sum(sisa) FROM legacy.tbl_item_im),               (SELECT sum(qty_remaining) FROM stock_batches)),
  (18, 'Nilai persediaan (Rp)',
       (SELECT sum(sisa*hargadasar) FROM legacy.tbl_item_im),    (SELECT sum(value) FROM v_stock_balance)),
  (19, 'Batch yg sisa <> jumlah mutasinya',
       0,                                                        (SELECT count(*) FROM stock_batches b
                                                                  WHERE b.qty_remaining <> coalesce((SELECT sum(m.qty_base) FROM stock_movements m WHERE m.batch_id=b.id), 0))),
  (20, 'Baris stok opname',
       (SELECT count(*) FROM legacy.tbl_itemopname),             (SELECT count(*) FROM stock_opname_lines)),
  (21, 'Periode stok opname',
       (SELECT count(DISTINCT (kodekantor, periode)) FROM legacy.tbl_itemopname), (SELECT count(*) FROM stock_opnames)),
  (22, 'Total pembayaran piutang',
       (SELECT sum(totalbayar) FROM legacy.tbl_byrpiutanghd),    (SELECT sum(amount) FROM debt_payments WHERE kind='receivable')),
  (23, 'Sisa piutang pelanggan',
       (SELECT sum(jmlkredit - krd_jml_byr - krd_jml_pot) FROM legacy.tbl_ikhd WHERE tipe='JL'),
       (SELECT sum(outstanding) FROM v_open_receivables))
)
SELECT no, cek,
       to_char(legacy_value, 'FM999G999G999G990D00') AS legacy,
       to_char(new_value,    'FM999G999G999G990D00') AS baru,
       -- toleransi < Rp 1 untuk pembulatan HPP per baris ke 2 desimal
       CASE WHEN abs(coalesce(legacy_value,0) - coalesce(new_value,0)) < 1 THEN 'OK' ELSE 'BEDA' END AS status
FROM checks ORDER BY no;

\echo
\echo '=== INFO: selisih stok cache iAbu (tbl_itemstok) vs batch FIFO ==='
SELECT s.kodeitem, s.stok AS itemstok_iabu, coalesce(b.qty, 0) AS batch_fifo,
       s.stok - coalesce(b.qty, 0) AS selisih
FROM legacy.tbl_itemstok s
LEFT JOIN (SELECT kodeitem, sum(sisa) qty FROM legacy.tbl_item_im GROUP BY 1) b USING (kodeitem)
WHERE s.stok <> coalesce(b.qty, 0)
ORDER BY abs(s.stok - coalesce(b.qty, 0)) DESC;

\echo
\echo '=== INFO: laba rugi bulanan (12 bulan terakhir) ==='
SELECT to_char(month, 'YYYY-MM') AS bulan,
       to_char(revenue,          'FM999G999G990') AS omzet,
       to_char(cogs,             'FM999G999G990') AS hpp,
       to_char(gross_profit,     'FM999G999G990') AS laba_kotor,
       to_char(stock_adjustment, 'FM999G999G990') AS selisih_opname,
       to_char(expenses,         'FM999G999G990') AS biaya,
       to_char(net_profit,       'FM999G999G990') AS laba_bersih
FROM v_profit_monthly
WHERE month >= date_trunc('month', now()) - interval '11 months'
ORDER BY month;

\echo
\echo '=== INFO: status kedaluwarsa stok ==='
SELECT expiry_status, count(DISTINCT item_id) AS jml_barang,
       sum(qty_remaining) AS qty, to_char(sum(value), 'FM999G999G990') AS nilai_rp
FROM v_stock_expiry GROUP BY 1 ORDER BY 1;

\echo
\echo '=== INFO: kualitas data yang perlu dibenahi ==='
SELECT 'Baris pembelian tanpa ED valid' AS hal,
       count(*) FILTER (WHERE expiry_date IS NULL)::text || ' dari ' || count(*) AS nilai
FROM purchase_lines
UNION ALL
SELECT 'Satuan barang yang punya barcode',
       count(*) FILTER (WHERE barcode IS NOT NULL)::text || ' dari ' || count(*) FROM item_units
UNION ALL
SELECT 'Barang tanpa golongan obat (perlu diisi)',
       count(*) FILTER (WHERE drug_class IS NULL)::text || ' dari ' || count(*) FROM items
UNION ALL
SELECT 'Pembelian berstatus legacy (hutang belum dikonfirmasi)',
       count(*)::text || ' faktur, Rp ' || to_char(sum(total), 'FM999G999G990')
FROM purchases WHERE payment_status = 'legacy';
