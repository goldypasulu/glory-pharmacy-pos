-- =============================================================================
-- Migrasi data iAbu (schema "legacy") -> skema Glory POS (schema "public")
--
-- * Dijalankan oleh migrate.sh setelah dump di-restore ke schema legacy.
-- * Semua UUID diturunkan secara deterministik dari kunci legacy
--   (md5 -> uuid), jadi migrasi bisa diulang dan hasilnya identik.
-- * Timestamp legacy tanpa zona waktu dianggap WIB (Asia/Jakarta).
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION legacy.lid(ns text, k text) RETURNS uuid
  LANGUAGE sql IMMUTABLE AS $$ SELECT md5(ns || '|' || coalesce(k, ''))::uuid $$;

CREATE OR REPLACE FUNCTION legacy.wib(ts timestamp) RETURNS timestamptz
  LANGUAGE sql IMMUTABLE AS $$ SELECT ts AT TIME ZONE 'Asia/Jakarta' $$;

CREATE OR REPLACE FUNCTION legacy.nz(t text) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$ SELECT nullif(btrim(t), '') $$;

-- Tanggal ED legacy dianggap TIDAK DIKETAHUI bila:
--   kosong, sama dengan tanggal transaksi (field dilewati kasir),
--   default saldo awal 2024-01-14, atau tidak masuk akal (< 2000).
CREATE OR REPLACE FUNCTION legacy.clean_ed(ed timestamp, trs timestamp, tipe text) RETURNS date
  LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN ed IS NULL                                   THEN NULL
    WHEN ed::date = trs::date                         THEN NULL
    WHEN tipe = 'SA' AND ed::date = DATE '2024-01-14' THEN NULL
    WHEN ed::date < DATE '2000-01-01'                 THEN NULL
    ELSE ed::date END $$;

CREATE OR REPLACE FUNCTION legacy.conf(k text) RETURNS text
  LANGUAGE sql STABLE AS $$ SELECT legacy.nz(confvalue) FROM legacy.tbl_conf WHERE confname = k $$;

-- ---------------------------------------------------------------------------
-- 1. Outlet, perangkat, pengguna
-- ---------------------------------------------------------------------------
INSERT INTO outlets (id, code, name, address, phone, npwp, receipt_footer)
SELECT legacy.lid('outlet', k.kodekantor), k.kodekantor,
       coalesce(legacy.conf('CMP_NAMA'), k.namakantor),
       coalesce(legacy.nz(k.alamat), legacy.conf('CMP_ALAMAT1')),
       coalesce(legacy.nz(k.notelepon), legacy.conf('CMP_TELP')),
       nullif(legacy.conf('CMP_NPWP'), '-'),
       'Terima kasih, semoga lekas sembuh'
FROM legacy.tbl_kantor k;

WITH pcs AS (
  SELECT kodekantor, compname FROM legacy.tbl_ikhd
  UNION SELECT kodekantor, compname FROM legacy.tbl_imhd
  UNION SELECT kodekantor, compname FROM legacy.tbl_itemopname
), n AS (
  SELECT kodekantor, compname,
         row_number() OVER (PARTITION BY kodekantor ORDER BY compname) AS rn
  FROM pcs WHERE legacy.nz(compname) IS NOT NULL
)
INSERT INTO devices (id, outlet_id, code, name, legacy_ref, is_active)
SELECT legacy.lid('device', compname), legacy.lid('outlet', kodekantor),
       'K' || rn, 'Kasir lama (' || compname || ')', compname, false
FROM n;

INSERT INTO users (id, username, full_name, role, must_reset_password, legacy_ref)
SELECT legacy.lid('user', userid), lower(userid), coalesce(legacy.nz(nama), userid),
       CASE upper(kelompok)
         WHEN 'ADMINISTRATOR' THEN 'admin'::user_role
         WHEN 'SUPERVISOR'    THEN 'supervisor'::user_role
         ELSE 'cashier'::user_role END,
       true, userid
FROM legacy.tbl_user;

INSERT INTO user_outlets (user_id, outlet_id)
SELECT u.id, o.id FROM users u CROSS JOIN outlets o;

-- ---------------------------------------------------------------------------
-- 2. Master referensi
-- ---------------------------------------------------------------------------
INSERT INTO units (id, name)
SELECT legacy.lid('unit', s), s FROM (
  SELECT upper(btrim(satuan)) s FROM legacy.tbl_itemsatuan
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_item
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_itemsatuanjml
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_itemhj
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_ikdt
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_imdt
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_itemrakitan
) x WHERE legacy.nz(s) IS NOT NULL;

INSERT INTO item_groups (id, name, description)
SELECT legacy.lid('group', n), n, max(d) FROM (
  SELECT upper(btrim(jenis)) n, legacy.nz(ketjenis) d FROM legacy.tbl_itemjenis
  UNION ALL SELECT upper(btrim(jenis)), NULL FROM legacy.tbl_item
) x WHERE legacy.nz(n) IS NOT NULL GROUP BY n;

INSERT INTO item_categories (id, name, description)
SELECT legacy.lid('category', n), n, max(d) FROM (
  SELECT upper(btrim(kategori)) n, legacy.nz(ketkategori) d FROM legacy.tbl_itemkategori
  UNION ALL SELECT upper(btrim(kategori)), NULL FROM legacy.tbl_item
) x WHERE legacy.nz(n) IS NOT NULL GROUP BY n;

INSERT INTO brands (id, name, description)
SELECT legacy.lid('brand', n), n, max(d) FROM (
  SELECT upper(btrim(merek)) n, legacy.nz(ketmerek) d FROM legacy.tbl_itemmerek
  UNION ALL SELECT upper(btrim(merek)), NULL FROM legacy.tbl_item
) x WHERE legacy.nz(n) IS NOT NULL GROUP BY n;

INSERT INTO partners (id, code, type, name, address, city, province, phone, email,
                      contact_person, npwp, bank_name, bank_account_name,
                      payment_term_days, credit_limit, notes, is_default_walkin, legacy_ref)
SELECT legacy.lid('partner', s.kode), s.kode,
       CASE s.tipe WHEN 'SU' THEN 'supplier' WHEN 'DO' THEN 'doctor'
                   WHEN 'SE' THEN 'sales' ELSE 'customer' END::partner_type,
       coalesce(legacy.nz(s.nama), s.kode),
       legacy.nz(s.alamat), legacy.nz(s.kota), legacy.nz(s.provinsi), legacy.nz(s.telepon),
       legacy.nz(s.email), legacy.nz(s.kontak), legacy.nz(s.npwp), legacy.nz(s.bank),
       legacy.nz(s.atasnama), coalesce(s.harijt, 0), coalesce(s.limitjmlhupi, 0),
       legacy.nz(s.keterangan), s.kode = coalesce(legacy.conf('DEF_PEL_UMUM'), 'UMUM'), s.kode
FROM legacy.tbl_supel s;

-- ---------------------------------------------------------------------------
-- 3. Barang, satuan, harga, racikan
-- ---------------------------------------------------------------------------
INSERT INTO items (id, code, name, kind, group_id, category_id, brand_id, base_unit_id,
                   default_supplier_id, min_stock, rack, is_consignment, is_sellable,
                   tax_included, last_cost, notes, is_active, legacy_ref)
SELECT legacy.lid('item', i.kodeitem), i.kodeitem, btrim(i.namaitem),
       CASE i.tipe WHEN '3' THEN 'compound' ELSE 'stock' END::item_kind,
       g.id, c.id, b.id, legacy.lid('unit', upper(btrim(i.satuan))),
       p.id, coalesce(i.stokmin, 0), legacy.nz(i.rak),
       coalesce(i.konsinyasi, 'N') = 'Y', coalesce(i.statusjual, 'Y') = 'Y',
       coalesce(i.pajak_include, 1) <> 0 OR legacy.conf('SET_TIPE_PPN') = 'Include',
       coalesce(i.hargapokok, 0), legacy.nz(i.keterangan),
       legacy.nz(i.statushapus) IS NULL, i.kodeitem
FROM legacy.tbl_item i
LEFT JOIN item_groups     g ON g.name = upper(btrim(i.jenis))
LEFT JOIN item_categories c ON c.name = upper(btrim(i.kategori))
LEFT JOIN brands          b ON b.name = upper(btrim(i.merek))
LEFT JOIN partners        p ON p.code = legacy.nz(i.supplier1);

INSERT INTO item_units (id, item_id, unit_id, conversion, is_base, barcode, legacy_ref)
SELECT DISTINCT ON (u.kodeitem, upper(btrim(u.satuan)))
       legacy.lid('item_unit', u.iddetail), legacy.lid('item', u.kodeitem),
       legacy.lid('unit', upper(btrim(u.satuan))),
       CASE WHEN u.tipe = 'D' THEN 1 ELSE u.jumlahkonv END,
       u.tipe = 'D', legacy.nz(u.kodebarcode), u.iddetail
FROM legacy.tbl_itemsatuanjml u
JOIN legacy.tbl_item i ON i.kodeitem = u.kodeitem
WHERE u.tipe = 'D' OR u.jumlahkonv > 0
ORDER BY u.kodeitem, upper(btrim(u.satuan)), (u.tipe = 'D') DESC, u.dateupd DESC;

-- jaga-jaga: setiap barang wajib punya baris satuan dasar
INSERT INTO item_units (id, item_id, unit_id, conversion, is_base)
SELECT legacy.lid('item_unit_base', i.code), i.id, i.base_unit_id, 1, true
FROM items i
WHERE NOT EXISTS (SELECT 1 FROM item_units u WHERE u.item_id = i.id AND u.unit_id = i.base_unit_id);

-- Harga: dari tbl_itemhj (per satuan / bertingkat) lalu harga tunggal tbl_item.hargajual1
INSERT INTO item_prices (id, item_id, unit_id, price_level, min_qty, price, legacy_ref)
SELECT legacy.lid('price', h.iddetail), legacy.lid('item', h.kodeitem),
       legacy.lid('unit', upper(btrim(h.satuan))), 'retail',
       CASE WHEN h.tipehj = 'J' THEN coalesce(h.jmlsampai, 0) ELSE 0 END,
       h.hargajual, h.iddetail
FROM legacy.tbl_itemhj h
JOIN legacy.tbl_item i ON i.kodeitem = h.kodeitem
WHERE h.hargajual > 0
ON CONFLICT DO NOTHING;

INSERT INTO item_prices (id, item_id, unit_id, price_level, min_qty, price, legacy_ref)
SELECT legacy.lid('price1', i.kodeitem), legacy.lid('item', i.kodeitem),
       legacy.lid('unit', upper(btrim(i.satuan))), 'retail', 0, i.hargajual1,
       'tbl_item.hargajual1'
FROM legacy.tbl_item i
WHERE i.hargajual1 > 0
ON CONFLICT DO NOTHING;

INSERT INTO item_components (id, item_id, component_id, qty_base, legacy_ref)
SELECT legacy.lid('component', r.iddetail), legacy.lid('item', r.kodeitem),
       legacy.lid('item', r.kodeitemrakitan),
       r.jumlah * coalesce(iu.conversion, 1), r.iddetail
FROM legacy.tbl_itemrakitan r
LEFT JOIN item_units iu ON iu.item_id = legacy.lid('item', r.kodeitemrakitan)
                       AND iu.unit_id = legacy.lid('unit', upper(btrim(r.satuan)));

-- ---------------------------------------------------------------------------
-- 4. Pembelian (BL). Saldo awal (SA) tidak dijadikan pembelian, hanya batch 'opening'.
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
WHERE h.tipe = 'BL';

INSERT INTO purchase_lines (id, purchase_id, line_no, item_id, unit_id, qty, conversion, qty_base,
                            price, discount_pct, tax, total, batch_no, expiry_date, legacy_ref)
SELECT legacy.lid('pline', d.iddetail), legacy.lid('purchase', d.notransaksi), d.nobaris,
       legacy.lid('item', d.kodeitem), legacy.lid('unit', upper(btrim(d.satuan))),
       d.jumlah, CASE WHEN d.jumlah <> 0 THEN q.qty_base / d.jumlah ELSE 1 END,
       q.qty_base, d.harga, coalesce(d.potongan, 0), coalesce(d.pajak, 0), d.total,
       legacy.nz(d.kodeprod), legacy.clean_ed(d.tglexp, h.tanggal, h.tipe), d.iddetail
FROM legacy.tbl_imdt d
JOIN legacy.tbl_imhd h ON h.notransaksi = d.notransaksi
-- tbl_imdt.jmlkonversi selalu NULL di iAbu; qty satuan dasar diambil dari batch-nya
LEFT JOIN legacy.tbl_item_im m ON m.iddetailtrs = d.iddetail
LEFT JOIN item_units iu ON iu.item_id = legacy.lid('item', d.kodeitem)
                       AND iu.unit_id = legacy.lid('unit', upper(btrim(d.satuan)))
CROSS JOIN LATERAL (
  SELECT coalesce(d.jmlkonversi, m.jumlahdasar, d.jumlah * iu.conversion, d.jumlah) AS qty_base
) q
WHERE h.tipe = 'BL';

-- ---------------------------------------------------------------------------
-- 5. Penjualan (KSR = kasir, JL = faktur jual, RJ = retur jual)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE tmp_sale_cogs AS
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

CREATE TEMP TABLE tmp_line_cogs AS
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

-- ---------------------------------------------------------------------------
-- 6. Stok opname (dibuat sebelum mutasi agar mutasi bisa merujuk dokumennya)
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 7. Batch stok FIFO + kartu stok
-- ---------------------------------------------------------------------------
INSERT INTO stock_batches (id, outlet_id, item_id, source, purchase_line_id, batch_no, expiry_date,
                           received_at, unit_cost, qty_in, qty_remaining, legacy_ref)
SELECT legacy.lid('batch', m.iddetail), legacy.lid('outlet', m.kodekantor),
       legacy.lid('item', m.kodeitem),
       CASE m.tipe WHEN 'SA' THEN 'opening' WHEN 'OP' THEN 'opname_in' ELSE 'purchase' END::movement_type,
       CASE WHEN m.tipe = 'BL' THEN legacy.lid('pline', m.iddetailtrs) END,
       legacy.nz(m.kodeprod), legacy.clean_ed(m.tgl_ed, m.tgl_trs, m.tipe),
       legacy.wib(m.tanggal), coalesce(m.hargadasar, 0), coalesce(m.masuk, 0), coalesce(m.sisa, 0), m.iddetail
FROM legacy.tbl_item_im m;

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

-- ---------------------------------------------------------------------------
-- 8. Pembayaran piutang
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 9. Pengaturan & data awal baru
-- ---------------------------------------------------------------------------
INSERT INTO settings (key, value) VALUES
  ('company', jsonb_build_object(
      'name',    legacy.conf('CMP_NAMA'),
      'address', legacy.conf('CMP_ALAMAT1'),
      'phone',   legacy.conf('CMP_TELP'))),
  ('cogs_method',          to_jsonb('FIFO'::text)),
  ('tax_mode',             to_jsonb(coalesce(legacy.conf('SET_TIPE_PPN'), 'Include'))),
  ('default_due_days',     to_jsonb(coalesce(legacy.conf('DEF_JATUH_TEMPO'), '30')::int)),
  ('rounding',             jsonb_build_object('enabled', legacy.conf('CFG_AKTIF_PEMBULATAN') = '1',
                                              'step', coalesce(legacy.conf('CFG_ITEM_PEMBULATAN'), '500')::int)),
  ('require_expiry_on_purchase', 'true'::jsonb),
  ('expiry_alert_days',    '[30, 90, 180]'::jsonb);

INSERT INTO expense_categories (name) VALUES
  ('Gaji Karyawan'), ('Listrik & Air'), ('Sewa Tempat'), ('Internet & Telepon'),
  ('Perlengkapan & ATK'), ('Transportasi & Ongkir'), ('Pajak & Retribusi'),
  ('Perawatan & Perbaikan'), ('Lain-lain');

-- Barang tipe racikan tidak punya batch stok sendiri
UPDATE items SET kind = 'compound' WHERE id IN (SELECT DISTINCT item_id FROM item_components);

COMMIT;
