-- =============================================================================
-- Transaksi dari iAbu (schema legacy) -> Glory POS.
-- Dipakai migrate.sql (database kosong) DAN reimport.sql (database yang sudah jalan).
--
-- Selama iAbu masih menjadi sumber transaksi, semua transaksi asal iAbu
-- (legacy_ref IS NOT NULL) dibangun ulang setiap kali file ini jalan. Dengan begitu
-- transaksi baru, transaksi yang diedit, dan transaksi yang dihapus di iAbu
-- semuanya ikut. reimport.sql menolak berjalan bila sudah ada transaksi buatan
-- Glory POS, jadi tidak ada data Glory yang ikut terhapus di sini.
--
-- stock_batches adalah tabel pull (ditarik kasir), jadi tidak dihapus-tulis ulang:
-- di-upsert, dan batch yang hilang dari iAbu di-soft-delete dengan sisa 0.
-- purchases / purchase_lines di-upsert karena dirujuk oleh stock_batches.
-- =============================================================================

-- 0. Hapus transaksi asal iAbu yang dibangun ulang ---------------------------
DELETE FROM debt_payment_allocations WHERE legacy_ref IS NOT NULL;
DELETE FROM debt_payments            WHERE legacy_ref IS NOT NULL;
DELETE FROM stock_movements          WHERE legacy_ref IS NOT NULL;
DELETE FROM stock_opname_lines       WHERE legacy_ref IS NOT NULL;
DELETE FROM stock_opnames            WHERE legacy_ref IS NOT NULL;
DELETE FROM sale_payments            WHERE sale_id IN (SELECT id FROM sales WHERE legacy_ref IS NOT NULL);
DELETE FROM sale_lines               WHERE legacy_ref IS NOT NULL;
DELETE FROM sales                    WHERE legacy_ref IS NOT NULL;

-- 1. Pembelian (BL). Saldo awal (SA) tidak dijadikan pembelian, hanya batch 'opening'.
--    Di iAbu semua pembelian tercatat kredit tanpa pelunasan, jadi status
--    pembayarannya 'legacy' (tidak dianggap hutang terbuka) sampai dikonfirmasi owner.
-- ---------------------------------------------------------------------------
INSERT INTO purchases (id, outlet_id, device_id, type, number, supplier_invoice_no, supplier_id,
                       occurred_at, due_date, subtotal, discount, tax, other_cost, total,
                       paid_amount, payment_status, status, notes, created_by, legacy_ref)
SELECT legacy.lid('purchase', h.notransaksi), legacy.lid('outlet', h.kodekantor),
       CASE WHEN legacy.nz(h.compname) IS NOT NULL THEN legacy.lid('device', h.compname) END,
       'purchase', h.notransaksi, h.notransaksi,
       CASE WHEN legacy.nz(h.kodesupel) IS NOT NULL THEN legacy.lid('partner', h.kodesupel) END,
       legacy.wib(h.tanggal), h.byr_krd_jt::date,
       coalesce(h.subtotal, 0),
       coalesce(nullif(h.potnomfaktur, 0), h.subtotal * coalesce(h.potfaktur, 0) / 100, 0),
       coalesce(h.pajak, 0), coalesce(h.biayalain, 0), coalesce(h.totalakhir, 0),
       coalesce(h.krd_jml_byr, 0) + coalesce(h.jmltunai, 0), 'legacy', 'posted',
       legacy.nz(h.keterangan),
       CASE WHEN legacy.nz(h.user1) IS NOT NULL THEN legacy.lid('user', h.user1) END,
       h.notransaksi
FROM legacy.tbl_imhd h
WHERE h.tipe = 'BL'
ON CONFLICT (id) DO UPDATE SET
  (outlet_id, device_id, number, supplier_invoice_no, supplier_id, occurred_at, due_date, subtotal,
   discount, tax, other_cost, total, paid_amount, notes, created_by)
  = (EXCLUDED.outlet_id, EXCLUDED.device_id, EXCLUDED.number, EXCLUDED.supplier_invoice_no,
     EXCLUDED.supplier_id, EXCLUDED.occurred_at, EXCLUDED.due_date, EXCLUDED.subtotal, EXCLUDED.discount,
     EXCLUDED.tax, EXCLUDED.other_cost, EXCLUDED.total, EXCLUDED.paid_amount, EXCLUDED.notes,
     EXCLUDED.created_by);

CREATE TEMP TABLE src_purchase_lines ON COMMIT DROP AS
SELECT legacy.lid('pline', d.iddetail) AS id, legacy.lid('purchase', d.notransaksi) AS purchase_id,
       d.nobaris AS line_no, legacy.lid('item', d.kodeitem) AS item_id,
       legacy.lid('unit', upper(btrim(d.satuan))) AS unit_id,
       d.jumlah AS qty, CASE WHEN d.jumlah <> 0 THEN q.qty_base / d.jumlah ELSE 1 END AS conversion,
       q.qty_base, d.harga AS price, coalesce(d.potongan, 0) AS discount_pct,
       coalesce(d.pajak, 0) AS tax, d.total,
       legacy.nz(d.kodeprod) AS batch_no, legacy.clean_ed(d.tglexp, h.tanggal, h.tipe) AS expiry_date,
       d.iddetail AS legacy_ref
FROM legacy.tbl_imdt d
JOIN legacy.tbl_imhd h ON h.notransaksi = d.notransaksi
-- tbl_imdt.jmlkonversi selalu NULL di iAbu; qty satuan dasar diambil dari batch-nya
LEFT JOIN legacy.tbl_item_im m ON m.iddetailtrs = d.iddetail
LEFT JOIN item_units iu ON iu.item_id = legacy.lid('item', d.kodeitem)
                       AND iu.unit_id = legacy.lid('unit', upper(btrim(d.satuan)))
                       AND iu.deleted_at IS NULL
CROSS JOIN LATERAL (
  SELECT coalesce(d.jmlkonversi, m.jumlahdasar, d.jumlah * iu.conversion, d.jumlah) AS qty_base
) q
WHERE h.tipe = 'BL';

INSERT INTO purchase_lines (id, purchase_id, line_no, item_id, unit_id, qty, conversion, qty_base,
                            price, discount_pct, tax, total, batch_no, expiry_date, legacy_ref)
SELECT * FROM src_purchase_lines
ON CONFLICT (id) DO UPDATE SET
  (purchase_id, line_no, item_id, unit_id, qty, conversion, qty_base, price, discount_pct, tax, total,
   batch_no, expiry_date)
  = (EXCLUDED.purchase_id, EXCLUDED.line_no, EXCLUDED.item_id, EXCLUDED.unit_id, EXCLUDED.qty,
     EXCLUDED.conversion, EXCLUDED.qty_base, EXCLUDED.price, EXCLUDED.discount_pct, EXCLUDED.tax,
     EXCLUDED.total, EXCLUDED.batch_no, EXCLUDED.expiry_date);

-- baris / faktur pembelian yang dihapus di iAbu
UPDATE stock_batches SET purchase_line_id = NULL
WHERE purchase_line_id IN (SELECT pl.id FROM purchase_lines pl
                           WHERE pl.legacy_ref IS NOT NULL
                             AND pl.id NOT IN (SELECT id FROM src_purchase_lines));
DELETE FROM purchase_lines
WHERE legacy_ref IS NOT NULL AND id NOT IN (SELECT id FROM src_purchase_lines);
DELETE FROM purchases
WHERE legacy_ref IS NOT NULL
  AND id NOT IN (SELECT legacy.lid('purchase', h.notransaksi) FROM legacy.tbl_imhd h WHERE h.tipe = 'BL');

-- 2. Batch stok FIFO (upsert) ---------------------------------------------------
CREATE TEMP TABLE src_batches ON COMMIT DROP AS
SELECT legacy.lid('batch', m.iddetail) AS id, legacy.lid('outlet', m.kodekantor) AS outlet_id,
       legacy.lid('item', m.kodeitem) AS item_id,
       (CASE m.tipe WHEN 'SA' THEN 'opening' WHEN 'OP' THEN 'opname_in' ELSE 'purchase' END)::movement_type AS source,
       CASE WHEN m.tipe = 'BL' THEN legacy.lid('pline', m.iddetailtrs) END AS purchase_line_id,
       legacy.nz(m.kodeprod) AS batch_no, legacy.clean_ed(m.tgl_ed, m.tgl_trs, m.tipe) AS expiry_date,
       legacy.wib(m.tanggal) AS received_at, coalesce(m.hargadasar, 0)::numeric(18,4) AS unit_cost,
       coalesce(m.masuk, 0)::numeric(18,3) AS qty_in, coalesce(m.sisa, 0)::numeric(18,3) AS qty_remaining,
       m.iddetail AS legacy_ref
FROM legacy.tbl_item_im m;

UPDATE stock_batches SET deleted_at = now(), qty_remaining = 0
WHERE legacy_ref IS NOT NULL AND deleted_at IS NULL
  AND id NOT IN (SELECT id FROM src_batches);

INSERT INTO stock_batches (id, outlet_id, item_id, source, purchase_line_id, batch_no, expiry_date,
                           received_at, unit_cost, qty_in, qty_remaining, legacy_ref)
SELECT * FROM src_batches
ON CONFLICT (id) DO UPDATE SET
  (outlet_id, item_id, source, purchase_line_id, batch_no, expiry_date, received_at, unit_cost,
   qty_in, qty_remaining, legacy_ref, deleted_at)
  = (EXCLUDED.outlet_id, EXCLUDED.item_id, EXCLUDED.source, EXCLUDED.purchase_line_id, EXCLUDED.batch_no,
     EXCLUDED.expiry_date, EXCLUDED.received_at, EXCLUDED.unit_cost, EXCLUDED.qty_in,
     EXCLUDED.qty_remaining, EXCLUDED.legacy_ref, NULL)
  WHERE (stock_batches.outlet_id, stock_batches.item_id, stock_batches.source, stock_batches.purchase_line_id,
         stock_batches.batch_no, stock_batches.expiry_date, stock_batches.received_at, stock_batches.unit_cost,
         stock_batches.qty_in, stock_batches.qty_remaining, stock_batches.legacy_ref, stock_batches.deleted_at)
     IS DISTINCT FROM
        (EXCLUDED.outlet_id, EXCLUDED.item_id, EXCLUDED.source, EXCLUDED.purchase_line_id, EXCLUDED.batch_no,
         EXCLUDED.expiry_date, EXCLUDED.received_at, EXCLUDED.unit_cost, EXCLUDED.qty_in,
         EXCLUDED.qty_remaining, EXCLUDED.legacy_ref, NULL::timestamptz);

-- 3. Penjualan (KSR = kasir, JL = faktur jual, RJ = retur jual) ----------------
CREATE TEMP TABLE tmp_sale_cogs ON COMMIT DROP AS
SELECT notransaksi, sum(jumlahdasar * hargadasar) AS cogs
FROM (
  SELECT notransaksi, jumlahdasar, hargadasar FROM legacy.tbl_item_ik WHERE tipe IN ('KSR','JL')
  UNION ALL
  SELECT notransaksi, jumlahdasar, hargadasar FROM legacy.tbl_item_ikret
) x GROUP BY 1;

INSERT INTO sales (id, outlet_id, device_id, type, number, occurred_at, customer_id, ref_sale_id,
                   cashier_id, subtotal, discount, tax, other_cost, rounding, total, cogs_total,
                   cash_tendered, change_amount, credit_amount, credit_paid, due_date,
                   payment_status, status, notes, synced_at, legacy_ref)
SELECT legacy.lid('sale', h.notransaksi), legacy.lid('outlet', h.kodekantor),
       CASE WHEN legacy.nz(h.compname) IS NOT NULL THEN legacy.lid('device', h.compname) END,
       CASE h.tipe WHEN 'JL' THEN 'invoice' WHEN 'RJ' THEN 'return' ELSE 'pos' END::sale_type,
       h.notransaksi, legacy.wib(h.tanggal),
       CASE WHEN legacy.nz(h.kodesupel) IS NOT NULL THEN legacy.lid('partner', h.kodesupel) END,
       -- nota asal retur: dari tbl_rj_piutang (retur faktur kredit), atau dari
       -- baris retur yang menunjuk baris nota asal (retur tunai)
       CASE WHEN h.tipe = 'RJ' THEN coalesce(
         (SELECT legacy.lid('sale', r.notrspot) FROM legacy.tbl_rj_piutang r
          WHERE r.noretur = h.notransaksi LIMIT 1),
         (SELECT legacy.lid('sale', o.notransaksi) FROM legacy.tbl_ikdt rd
          JOIN legacy.tbl_ikdt o ON o.iddetail = rd.idtrsretur
          WHERE rd.notransaksi = h.notransaksi LIMIT 1)) END,
       CASE WHEN legacy.nz(h.user1) IS NOT NULL THEN legacy.lid('user', h.user1) END,
       coalesce(h.subtotal, 0),
       coalesce(nullif(h.potnomfaktur, 0), h.subtotal * coalesce(h.potfaktur, 0) / 100, 0),
       coalesce(h.pajak, 0), coalesce(h.biayalain, 0), coalesce(h.selisihpembulatan, 0),
       coalesce(h.totalakhir, 0), coalesce(c.cogs, 0),
       coalesce(h.jmltunai, 0),
       greatest(coalesce(h.jmltunai, 0) - p.cash_part, 0),
       CASE WHEN h.tipe = 'RJ' THEN 0 ELSE coalesce(h.jmlkredit, 0) END,
       CASE WHEN h.tipe = 'RJ' THEN 0 ELSE coalesce(h.krd_jml_byr, 0) + coalesce(h.krd_jml_pot, 0) END,
       h.byr_krd_jt::date,
       CASE
         WHEN h.tipe = 'RJ' OR coalesce(h.jmlkredit, 0) = 0 THEN 'paid'
         WHEN coalesce(h.krd_jml_byr, 0) + coalesce(h.krd_jml_pot, 0) >= h.jmlkredit THEN 'paid'
         WHEN coalesce(h.krd_jml_byr, 0) + coalesce(h.krd_jml_pot, 0) > 0 THEN 'partial'
         ELSE 'unpaid' END::payment_status,
       'posted', legacy.nz(h.keterangan), legacy.wib(h.dateupd), h.notransaksi
FROM legacy.tbl_ikhd h
LEFT JOIN tmp_sale_cogs c ON c.notransaksi = h.notransaksi
CROSS JOIN LATERAL (
  SELECT greatest(coalesce(h.totalakhir, 0)
                  - coalesce(h.jmlkredit, 0) - coalesce(h.jmldebit, 0) - coalesce(h.jmlkk, 0)
                  - coalesce(h.jmlemoney, 0) - coalesce(h.jmlasuransi, 0), 0) AS cash_part
) p;

CREATE TEMP TABLE tmp_line_cogs ON COMMIT DROP AS
SELECT iddetailtrs, sum(jumlahdasar * hargadasar) AS cogs
FROM (
  SELECT iddetailtrs, jumlahdasar, hargadasar FROM legacy.tbl_item_ik WHERE tipe IN ('KSR','JL')
  UNION ALL
  SELECT iddetailtrs, jumlahdasar, hargadasar FROM legacy.tbl_item_ikret
) x GROUP BY 1;

INSERT INTO sale_lines (id, sale_id, line_no, item_id, unit_id, qty, conversion, qty_base, price,
                        discount_pct, discount_amount, tax, total, cogs, ref_line_id, legacy_ref)
SELECT legacy.lid('sline', d.iddetail), legacy.lid('sale', d.notransaksi), d.nobaris,
       legacy.lid('item', d.kodeitem), legacy.lid('unit', upper(btrim(d.satuan))),
       d.jumlah, CASE WHEN d.jumlah <> 0 THEN q.qty_base / d.jumlah ELSE 1 END,
       q.qty_base, d.harga, coalesce(d.potongan, 0),
       greatest(d.jumlah * d.harga - d.total, 0), coalesce(d.pajak, 0), d.total,
       coalesce(c.cogs, 0),
       CASE WHEN legacy.nz(d.idtrsretur) IS NOT NULL
             AND EXISTS (SELECT 1 FROM legacy.tbl_ikdt o WHERE o.iddetail = d.idtrsretur)
            THEN legacy.lid('sline', d.idtrsretur) END,
       d.iddetail
FROM legacy.tbl_ikdt d
LEFT JOIN tmp_line_cogs c ON c.iddetailtrs = d.iddetail
-- pengaman: jmlkonversi penjualan saat ini selalu terisi, tapi backup lain bisa NULL
LEFT JOIN item_units iu ON iu.item_id = legacy.lid('item', d.kodeitem)
                       AND iu.unit_id = legacy.lid('unit', upper(btrim(d.satuan)))
                       AND iu.deleted_at IS NULL
CROSS JOIN LATERAL (
  SELECT coalesce(d.jmlkonversi, d.jumlah * iu.conversion, d.jumlah) AS qty_base
) q;

-- Pembayaran (1 baris per metode)
INSERT INTO sale_payments (id, sale_id, method, amount)
SELECT legacy.lid('pay-' || m.method, h.notransaksi), legacy.lid('sale', h.notransaksi),
       m.method::payment_method, m.amount
FROM legacy.tbl_ikhd h
CROSS JOIN LATERAL (VALUES
  ('cash', greatest(coalesce(h.totalakhir,0) - coalesce(h.jmlkredit,0) - coalesce(h.jmldebit,0)
                    - coalesce(h.jmlkk,0) - coalesce(h.jmlemoney,0) - coalesce(h.jmlasuransi,0), 0)),
  ('credit',      coalesce(h.jmlkredit, 0)),
  ('debit',       coalesce(h.jmldebit, 0)),
  ('credit_card', coalesce(h.jmlkk, 0)),
  ('emoney',      coalesce(h.jmlemoney, 0)),
  ('insurance',   coalesce(h.jmlasuransi, 0))
) AS m(method, amount)
WHERE m.amount > 0;

-- 4. Stok opname ----------------------------------------------------------------
INSERT INTO stock_opnames (id, outlet_id, number, started_at, finalized_at, status, created_by, legacy_ref)
SELECT legacy.lid('opname', o.kodekantor || '|' || o.periode), legacy.lid('outlet', o.kodekantor),
       o.periode, legacy.wib(min(o.tanggal)), legacy.wib(max(o.dateupd)), 'posted',
       legacy.lid('user', min(o.user1)), o.periode
FROM legacy.tbl_itemopname o
GROUP BY o.kodekantor, o.periode;

INSERT INTO stock_opname_lines (id, opname_id, item_id, counted_at, system_qty, physical_qty,
                                diff_qty, unit_cost, diff_value, expiry_date, counted_by, legacy_ref)
SELECT legacy.lid('opline', o.iddetail),
       legacy.lid('opname', o.kodekantor || '|' || o.periode), legacy.lid('item', o.kodeitem),
       legacy.wib(o.tanggal), o.jmlsebelum, o.jmlfisik, o.jmlselisih, coalesce(o.harga, 0),
       o.jmlselisih * coalesce(o.harga, 0),
       legacy.clean_ed(o.tglexp, o.tanggal, 'OP'),
       CASE WHEN legacy.nz(o.user1) IS NOT NULL THEN legacy.lid('user', o.user1) END,
       o.iddetail
FROM legacy.tbl_itemopname o;

-- 5. Kartu stok ---------------------------------------------------------------
-- Masuk (saldo awal, pembelian, opname plus)
INSERT INTO stock_movements (id, outlet_id, item_id, batch_id, type, qty_base, unit_cost,
                             ref_table, ref_id, ref_line_id, occurred_at, legacy_ref)
SELECT legacy.lid('mv-in', m.iddetail), legacy.lid('outlet', m.kodekantor),
       legacy.lid('item', m.kodeitem), legacy.lid('batch', m.iddetail),
       CASE m.tipe WHEN 'SA' THEN 'opening' WHEN 'OP' THEN 'opname_in' ELSE 'purchase' END::movement_type,
       coalesce(m.masuk, 0), coalesce(m.hargadasar, 0),
       CASE m.tipe WHEN 'BL' THEN 'purchases' WHEN 'OP' THEN 'stock_opnames' END,
       CASE m.tipe WHEN 'BL' THEN legacy.lid('purchase', m.notransaksi)
                   WHEN 'OP' THEN legacy.lid('opname', m.kodekantor || '|' || m.notransaksi) END,
       CASE m.tipe WHEN 'BL' THEN legacy.lid('pline', m.iddetailtrs)
                   WHEN 'OP' THEN legacy.lid('opline', m.iddetailtrs) END,
       legacy.wib(m.tanggal), m.iddetail
FROM legacy.tbl_item_im m;

-- Keluar (penjualan, opname minus)
INSERT INTO stock_movements (id, outlet_id, item_id, batch_id, type, qty_base, unit_cost,
                             ref_table, ref_id, ref_line_id, occurred_at, legacy_ref)
SELECT legacy.lid('mv-out', k.iddetail), legacy.lid('outlet', k.kodekantor),
       legacy.lid('item', k.kodeitem), legacy.lid('batch', k.iddetailim),
       CASE k.tipe WHEN 'OP' THEN 'opname_out' ELSE 'sale' END::movement_type,
       -k.jumlahdasar, k.hargadasar,
       CASE k.tipe WHEN 'OP' THEN 'stock_opnames' ELSE 'sales' END,
       CASE k.tipe WHEN 'OP' THEN legacy.lid('opname', k.kodekantor || '|' || k.notransaksi)
                   ELSE legacy.lid('sale', k.notransaksi) END,
       CASE k.tipe WHEN 'OP' THEN legacy.lid('opline', k.iddetailtrs)
                   ELSE legacy.lid('sline', k.iddetailtrs) END,
       legacy.wib(k.tanggal), k.iddetail
FROM legacy.tbl_item_ik k;

-- Retur penjualan (barang kembali ke batch asalnya)
INSERT INTO stock_movements (id, outlet_id, item_id, batch_id, type, qty_base, unit_cost,
                             ref_table, ref_id, ref_line_id, occurred_at, legacy_ref)
SELECT legacy.lid('mv-ret', r.iddetail), legacy.lid('outlet', h.kodekantor),
       legacy.lid('item', r.kodeitem), legacy.lid('batch', k.iddetailim),
       'sale_return', r.jumlahdasar, r.hargadasar,
       'sales', legacy.lid('sale', r.notransaksi), legacy.lid('sline', r.iddetailtrs),
       legacy.wib(h.tanggal), r.iddetail
FROM legacy.tbl_item_ikret r
JOIN legacy.tbl_item_ik k ON k.iddetail = r.iddetailik
JOIN legacy.tbl_ikhd   h ON h.notransaksi = r.notransaksi;

-- 6. Pembayaran piutang -------------------------------------------------------
INSERT INTO debt_payments (id, outlet_id, kind, number, partner_id, paid_at, method, amount,
                           notes, created_by, legacy_ref)
SELECT legacy.lid('debtpay', h.notransaksi), legacy.lid('outlet', h.kodekantor), 'receivable',
       h.notransaksi, legacy.lid('partner', h.kodesupel), legacy.wib(h.tanggal),
       CASE upper(coalesce(h.carabayar, '')) WHEN 'TRANSFER' THEN 'transfer'
            WHEN 'DEBIT' THEN 'debit' ELSE 'cash' END::payment_method,
       h.totalbayar, legacy.nz(h.keterangan),
       CASE WHEN legacy.nz(h.user1) IS NOT NULL THEN legacy.lid('user', h.user1) END,
       h.notransaksi
FROM legacy.tbl_byrpiutanghd h;

INSERT INTO debt_payment_allocations (id, payment_id, sale_id, amount, discount, legacy_ref)
SELECT legacy.lid('debtalloc', d.iddetail), legacy.lid('debtpay', d.notransaksi),
       legacy.lid('sale', d.notrsmasuk), coalesce(d.krd_jml_byr, 0), coalesce(d.krd_jml_pot, 0),
       d.iddetail
FROM legacy.tbl_byrpiutangdt d;
