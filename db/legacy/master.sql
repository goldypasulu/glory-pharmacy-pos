-- =============================================================================
-- Data master dari iAbu (schema legacy) -> Glory POS.
-- Dipakai migrate.sql (database kosong) DAN reimport.sql (database yang sudah jalan).
--
-- Aturan:
-- * Semua id deterministik dari kunci iAbu, jadi upsert berdasarkan id.
-- * Kolom yang bersumber dari iAbu diperbarui. Kolom yang hanya ada / hanya diisi
--   di Glory POS TIDAK ditimpa: items.generic_name, items.drug_class,
--   items.requires_prescription, item_units.barcode (kecuali iAbu punya barcode).
-- * Update hanya bila nilainya berubah (IS DISTINCT FROM), supaya sync_txid tidak
--   naik dan kasir tidak menarik ulang baris yang sama.
-- * Outlet, perangkat, dan user lama hanya ditambahkan bila belum ada; setelah itu
--   dikelola di Glory POS (password, PIN, peran, pengaturan tidak disentuh).
-- =============================================================================

-- 1. Outlet, perangkat, user (insert-only) -------------------------------------
INSERT INTO outlets (id, code, name, address, phone, npwp, receipt_footer)
SELECT legacy.lid('outlet', k.kodekantor), k.kodekantor,
       coalesce(legacy.conf('CMP_NAMA'), k.namakantor),
       coalesce(legacy.nz(k.alamat), legacy.conf('CMP_ALAMAT1')),
       coalesce(legacy.nz(k.notelepon), legacy.conf('CMP_TELP')),
       nullif(legacy.conf('CMP_NPWP'), '-'),
       'Terima kasih, semoga lekas sembuh'
FROM legacy.tbl_kantor k
ON CONFLICT (id) DO NOTHING;

WITH pcs AS (
  SELECT kodekantor, compname FROM legacy.tbl_ikhd
  UNION SELECT kodekantor, compname FROM legacy.tbl_imhd
  UNION SELECT kodekantor, compname FROM legacy.tbl_itemopname
), n AS (
  SELECT p.kodekantor, p.compname,
         (SELECT count(*) FROM devices d WHERE d.outlet_id = legacy.lid('outlet', p.kodekantor)
                                           AND d.id <> legacy.lid('device', p.compname))
         + row_number() OVER (PARTITION BY p.kodekantor ORDER BY p.compname) AS rn
  FROM pcs p
  WHERE legacy.nz(p.compname) IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM devices d WHERE d.id = legacy.lid('device', p.compname))
)
INSERT INTO devices (id, outlet_id, code, name, legacy_ref, is_active)
SELECT legacy.lid('device', compname), legacy.lid('outlet', kodekantor),
       'K' || rn, 'Kasir lama (' || compname || ')', compname, false
FROM n
ON CONFLICT (id) DO NOTHING;

INSERT INTO users (id, username, full_name, role, must_reset_password, legacy_ref)
SELECT legacy.lid('user', userid), lower(userid), coalesce(legacy.nz(nama), userid),
       CASE upper(kelompok)
         WHEN 'ADMINISTRATOR' THEN 'admin'::user_role
         WHEN 'SUPERVISOR'    THEN 'supervisor'::user_role
         ELSE 'cashier'::user_role END,
       true, userid
FROM legacy.tbl_user
ON CONFLICT (id) DO NOTHING;

INSERT INTO user_outlets (user_id, outlet_id)
SELECT legacy.lid('user', u.userid), legacy.lid('outlet', k.kodekantor)
FROM legacy.tbl_user u CROSS JOIN legacy.tbl_kantor k
ON CONFLICT DO NOTHING;

-- 2. Referensi ----------------------------------------------------------------
INSERT INTO units (id, name)
SELECT legacy.lid('unit', s), s FROM (
  SELECT upper(btrim(satuan)) s FROM legacy.tbl_itemsatuan
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_item
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_itemsatuanjml
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_itemhj
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_ikdt
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_imdt
  UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_itemrakitan
) x WHERE legacy.nz(s) IS NOT NULL
ON CONFLICT (id) DO NOTHING;

INSERT INTO item_groups (id, name, description)
SELECT legacy.lid('group', n), n, max(d) FROM (
  SELECT upper(btrim(jenis)) n, legacy.nz(ketjenis) d FROM legacy.tbl_itemjenis
  UNION ALL SELECT upper(btrim(jenis)), NULL FROM legacy.tbl_item
) x WHERE legacy.nz(n) IS NOT NULL GROUP BY n
ON CONFLICT (id) DO UPDATE SET description = EXCLUDED.description
  WHERE item_groups.description IS DISTINCT FROM EXCLUDED.description;

INSERT INTO item_categories (id, name, description)
SELECT legacy.lid('category', n), n, max(d) FROM (
  SELECT upper(btrim(kategori)) n, legacy.nz(ketkategori) d FROM legacy.tbl_itemkategori
  UNION ALL SELECT upper(btrim(kategori)), NULL FROM legacy.tbl_item
) x WHERE legacy.nz(n) IS NOT NULL GROUP BY n
ON CONFLICT (id) DO UPDATE SET description = EXCLUDED.description
  WHERE item_categories.description IS DISTINCT FROM EXCLUDED.description;

INSERT INTO brands (id, name, description)
SELECT legacy.lid('brand', n), n, max(d) FROM (
  SELECT upper(btrim(merek)) n, legacy.nz(ketmerek) d FROM legacy.tbl_itemmerek
  UNION ALL SELECT upper(btrim(merek)), NULL FROM legacy.tbl_item
) x WHERE legacy.nz(n) IS NOT NULL GROUP BY n
ON CONFLICT (id) DO UPDATE SET description = EXCLUDED.description
  WHERE brands.description IS DISTINCT FROM EXCLUDED.description;

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
FROM legacy.tbl_supel s
ON CONFLICT (id) DO UPDATE SET
  (code, type, name, address, city, province, phone, email, contact_person, npwp, bank_name,
   bank_account_name, payment_term_days, credit_limit, notes, is_default_walkin, legacy_ref, deleted_at)
  = (EXCLUDED.code, EXCLUDED.type, EXCLUDED.name, EXCLUDED.address, EXCLUDED.city, EXCLUDED.province,
     EXCLUDED.phone, EXCLUDED.email, EXCLUDED.contact_person, EXCLUDED.npwp, EXCLUDED.bank_name,
     EXCLUDED.bank_account_name, EXCLUDED.payment_term_days, EXCLUDED.credit_limit, EXCLUDED.notes,
     EXCLUDED.is_default_walkin, EXCLUDED.legacy_ref, NULL)
  WHERE (partners.code, partners.type, partners.name, partners.address, partners.city, partners.province,
         partners.phone, partners.email, partners.contact_person, partners.npwp, partners.bank_name,
         partners.bank_account_name, partners.payment_term_days, partners.credit_limit, partners.notes,
         partners.is_default_walkin, partners.legacy_ref, partners.deleted_at)
     IS DISTINCT FROM
        (EXCLUDED.code, EXCLUDED.type, EXCLUDED.name, EXCLUDED.address, EXCLUDED.city, EXCLUDED.province,
         EXCLUDED.phone, EXCLUDED.email, EXCLUDED.contact_person, EXCLUDED.npwp, EXCLUDED.bank_name,
         EXCLUDED.bank_account_name, EXCLUDED.payment_term_days, EXCLUDED.credit_limit, EXCLUDED.notes,
         EXCLUDED.is_default_walkin, EXCLUDED.legacy_ref, NULL::timestamptz);

-- 3. Barang -------------------------------------------------------------------
INSERT INTO items (id, code, name, kind, group_id, category_id, brand_id, base_unit_id,
                   default_supplier_id, min_stock, rack, is_consignment, is_sellable,
                   tax_included, last_cost, notes, is_active, legacy_ref)
SELECT legacy.lid('item', i.kodeitem), i.kodeitem, btrim(i.namaitem),
       CASE WHEN i.tipe = '3' OR EXISTS (SELECT 1 FROM legacy.tbl_itemrakitan r WHERE r.kodeitem = i.kodeitem)
            THEN 'compound' ELSE 'stock' END::item_kind,
       g.id, c.id, b.id, legacy.lid('unit', upper(btrim(i.satuan))),
       p.id, coalesce(i.stokmin, 0), legacy.nz(i.rak),
       coalesce(i.konsinyasi, 'N') = 'Y', coalesce(i.statusjual, 'Y') = 'Y',
       coalesce(i.pajak_include, 1) <> 0 OR legacy.conf('SET_TIPE_PPN') = 'Include',
       coalesce(i.hargapokok, 0), legacy.nz(i.keterangan),
       legacy.nz(i.statushapus) IS NULL, i.kodeitem
FROM legacy.tbl_item i
LEFT JOIN item_groups     g ON g.id = legacy.lid('group', upper(btrim(i.jenis)))
LEFT JOIN item_categories c ON c.id = legacy.lid('category', upper(btrim(i.kategori)))
LEFT JOIN brands          b ON b.id = legacy.lid('brand', upper(btrim(i.merek)))
LEFT JOIN partners        p ON p.id = legacy.lid('partner', legacy.nz(i.supplier1))
ON CONFLICT (id) DO UPDATE SET
  (code, name, kind, group_id, category_id, brand_id, base_unit_id, default_supplier_id, min_stock,
   rack, is_consignment, is_sellable, tax_included, last_cost, notes, is_active, legacy_ref, deleted_at)
  = (EXCLUDED.code, EXCLUDED.name, EXCLUDED.kind, EXCLUDED.group_id, EXCLUDED.category_id, EXCLUDED.brand_id,
     EXCLUDED.base_unit_id, EXCLUDED.default_supplier_id, EXCLUDED.min_stock, EXCLUDED.rack,
     EXCLUDED.is_consignment, EXCLUDED.is_sellable, EXCLUDED.tax_included, EXCLUDED.last_cost,
     EXCLUDED.notes, EXCLUDED.is_active, EXCLUDED.legacy_ref, NULL)
  WHERE (items.code, items.name, items.kind, items.group_id, items.category_id, items.brand_id,
         items.base_unit_id, items.default_supplier_id, items.min_stock, items.rack, items.is_consignment,
         items.is_sellable, items.tax_included, items.last_cost, items.notes, items.is_active,
         items.legacy_ref, items.deleted_at)
     IS DISTINCT FROM
        (EXCLUDED.code, EXCLUDED.name, EXCLUDED.kind, EXCLUDED.group_id, EXCLUDED.category_id,
         EXCLUDED.brand_id, EXCLUDED.base_unit_id, EXCLUDED.default_supplier_id, EXCLUDED.min_stock,
         EXCLUDED.rack, EXCLUDED.is_consignment, EXCLUDED.is_sellable, EXCLUDED.tax_included,
         EXCLUDED.last_cost, EXCLUDED.notes, EXCLUDED.is_active, EXCLUDED.legacy_ref, NULL::timestamptz);

-- Barang yang sudah tidak ada di iAbu: dinonaktifkan, tidak dihapus
UPDATE items SET is_active = false
WHERE legacy_ref IS NOT NULL AND is_active
  AND NOT EXISTS (SELECT 1 FROM legacy.tbl_item i WHERE i.kodeitem = items.legacy_ref);

-- 4. Satuan barang ------------------------------------------------------------
CREATE TEMP TABLE src_item_units ON COMMIT DROP AS
SELECT DISTINCT ON (u.kodeitem, upper(btrim(u.satuan)))
       legacy.lid('item_unit', u.iddetail) AS id, legacy.lid('item', u.kodeitem) AS item_id,
       legacy.lid('unit', upper(btrim(u.satuan))) AS unit_id,
       (CASE WHEN u.tipe = 'D' THEN 1 ELSE u.jumlahkonv END)::numeric(18,3) AS conversion,
       u.tipe = 'D' AS is_base, legacy.nz(u.kodebarcode) AS barcode, u.iddetail AS legacy_ref
FROM legacy.tbl_itemsatuanjml u
JOIN legacy.tbl_item i ON i.kodeitem = u.kodeitem
WHERE u.tipe = 'D' OR u.jumlahkonv > 0
ORDER BY u.kodeitem, upper(btrim(u.satuan)), (u.tipe = 'D') DESC, u.dateupd DESC;

-- satuan legacy yang hilang dari iAbu, dan baris cadangan yang kini punya pasangan legacy
UPDATE item_units SET deleted_at = now()
WHERE deleted_at IS NULL
  AND ((legacy_ref IS NOT NULL AND id NOT IN (SELECT id FROM src_item_units))
       OR (legacy_ref IS NULL AND id = (SELECT legacy.lid('item_unit_base', i.code) FROM items i WHERE i.id = item_units.item_id)
           AND EXISTS (SELECT 1 FROM src_item_units s WHERE s.item_id = item_units.item_id AND s.unit_id = item_units.unit_id)));

INSERT INTO item_units (id, item_id, unit_id, conversion, is_base, barcode, legacy_ref)
SELECT id, item_id, unit_id, conversion, is_base, barcode, legacy_ref FROM src_item_units
ON CONFLICT (id) DO UPDATE SET
  (item_id, unit_id, conversion, is_base, barcode, legacy_ref, deleted_at)
  = (EXCLUDED.item_id, EXCLUDED.unit_id, EXCLUDED.conversion, EXCLUDED.is_base,
     coalesce(EXCLUDED.barcode, item_units.barcode), EXCLUDED.legacy_ref, NULL)
  WHERE (item_units.item_id, item_units.unit_id, item_units.conversion, item_units.is_base,
         item_units.barcode, item_units.legacy_ref, item_units.deleted_at)
     IS DISTINCT FROM
        (EXCLUDED.item_id, EXCLUDED.unit_id, EXCLUDED.conversion, EXCLUDED.is_base,
         coalesce(EXCLUDED.barcode, item_units.barcode), EXCLUDED.legacy_ref, NULL::timestamptz);

-- jaga-jaga: setiap barang wajib punya baris satuan dasar aktif
INSERT INTO item_units (id, item_id, unit_id, conversion, is_base)
SELECT legacy.lid('item_unit_base', i.code), i.id, i.base_unit_id, 1, true
FROM items i
WHERE i.legacy_ref IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM item_units u WHERE u.item_id = i.id AND u.unit_id = i.base_unit_id
                  AND u.deleted_at IS NULL)
ON CONFLICT (id) DO UPDATE SET deleted_at = NULL, conversion = 1, is_base = true;

-- 5. Harga --------------------------------------------------------------------
-- tbl_itemhj (per satuan / bertingkat) diutamakan, lalu harga tunggal tbl_item.hargajual1
CREATE TEMP TABLE src_item_prices ON COMMIT DROP AS
SELECT DISTINCT ON (item_id, unit_id, min_qty) *
FROM (
  SELECT legacy.lid('price', h.iddetail) AS id, legacy.lid('item', h.kodeitem) AS item_id,
         legacy.lid('unit', upper(btrim(h.satuan))) AS unit_id,
         (CASE WHEN h.tipehj = 'J' THEN coalesce(h.jmlsampai, 0) ELSE 0 END)::numeric(18,3) AS min_qty,
         h.hargajual::numeric(18,2) AS price, h.iddetail AS legacy_ref, 1 AS prio
  FROM legacy.tbl_itemhj h
  JOIN legacy.tbl_item i ON i.kodeitem = h.kodeitem
  WHERE h.hargajual > 0
  UNION ALL
  SELECT legacy.lid('price1', i.kodeitem), legacy.lid('item', i.kodeitem),
         legacy.lid('unit', upper(btrim(i.satuan))), 0, i.hargajual1::numeric(18,2),
         'tbl_item.hargajual1:' || i.kodeitem, 2
  FROM legacy.tbl_item i
  WHERE i.hargajual1 > 0
) x
ORDER BY item_id, unit_id, min_qty, prio, legacy_ref;

UPDATE item_prices SET deleted_at = now()
WHERE legacy_ref IS NOT NULL AND deleted_at IS NULL
  AND id NOT IN (SELECT id FROM src_item_prices);

INSERT INTO item_prices (id, item_id, unit_id, price_level, min_qty, price, legacy_ref)
SELECT id, item_id, unit_id, 'retail', min_qty, price, legacy_ref FROM src_item_prices
ON CONFLICT (id) DO UPDATE SET
  (item_id, unit_id, outlet_id, price_level, min_qty, price, legacy_ref, deleted_at)
  = (EXCLUDED.item_id, EXCLUDED.unit_id, NULL, EXCLUDED.price_level, EXCLUDED.min_qty, EXCLUDED.price,
     EXCLUDED.legacy_ref, NULL)
  WHERE (item_prices.item_id, item_prices.unit_id, item_prices.outlet_id, item_prices.price_level,
         item_prices.min_qty, item_prices.price, item_prices.legacy_ref, item_prices.deleted_at)
     IS DISTINCT FROM
        (EXCLUDED.item_id, EXCLUDED.unit_id, NULL::uuid, EXCLUDED.price_level, EXCLUDED.min_qty,
         EXCLUDED.price, EXCLUDED.legacy_ref, NULL::timestamptz);

-- 6. Komposisi racikan --------------------------------------------------------
CREATE TEMP TABLE src_item_components ON COMMIT DROP AS
SELECT legacy.lid('component', r.iddetail) AS id, legacy.lid('item', r.kodeitem) AS item_id,
       legacy.lid('item', r.kodeitemrakitan) AS component_id,
       (r.jumlah * coalesce(iu.conversion, 1))::numeric(18,3) AS qty_base, r.iddetail AS legacy_ref
FROM legacy.tbl_itemrakitan r
LEFT JOIN item_units iu ON iu.item_id = legacy.lid('item', r.kodeitemrakitan)
                       AND iu.unit_id = legacy.lid('unit', upper(btrim(r.satuan)))
                       AND iu.deleted_at IS NULL;

UPDATE item_components SET deleted_at = now()
WHERE legacy_ref IS NOT NULL AND deleted_at IS NULL
  AND id NOT IN (SELECT id FROM src_item_components);

INSERT INTO item_components (id, item_id, component_id, qty_base, legacy_ref)
SELECT id, item_id, component_id, qty_base, legacy_ref FROM src_item_components
ON CONFLICT (id) DO UPDATE SET
  (item_id, component_id, qty_base, legacy_ref, deleted_at)
  = (EXCLUDED.item_id, EXCLUDED.component_id, EXCLUDED.qty_base, EXCLUDED.legacy_ref, NULL)
  WHERE (item_components.item_id, item_components.component_id, item_components.qty_base,
         item_components.legacy_ref, item_components.deleted_at)
     IS DISTINCT FROM
        (EXCLUDED.item_id, EXCLUDED.component_id, EXCLUDED.qty_base, EXCLUDED.legacy_ref, NULL::timestamptz);
