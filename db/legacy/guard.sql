-- =============================================================================
-- Pengaman impor ulang. Dijalankan reimport.sql SETELAH backup baru menjadi schema
-- legacy dan SEBELUM ada data yang diubah. Satu pelanggaran = RAISE EXCEPTION,
-- seluruh transaksi dibatalkan, database tetap seperti sebelum impor.
-- =============================================================================
DO $$
DECLARE
  n       bigint;
  contoh  text;
  incoming_max timestamptz;
  current_max  timestamptz;
BEGIN
  -- 1. Transaksi buatan Glory POS. Selama impor ulang dipakai, semua transaksi
  --    harus berasal dari iAbu; kalau tidak, stok dan penjualan bisa tercatat dobel.
  SELECT count(*) INTO n FROM (
    SELECT id FROM sales           WHERE legacy_ref IS NULL UNION ALL
    SELECT id FROM purchases       WHERE legacy_ref IS NULL UNION ALL
    SELECT id FROM stock_opnames   WHERE legacy_ref IS NULL UNION ALL
    SELECT id FROM stock_movements WHERE legacy_ref IS NULL UNION ALL
    SELECT id FROM stock_batches   WHERE legacy_ref IS NULL UNION ALL
    SELECT id FROM debt_payments   WHERE legacy_ref IS NULL UNION ALL
    SELECT id FROM stock_transfers
  ) x;
  IF n > 0 THEN
    RAISE EXCEPTION 'Impor ulang dibatalkan: sudah ada % transaksi yang dibuat di Glory POS (penjualan, pembelian, opname, mutasi, atau transfer).', n
      USING HINT = 'Impor ulang hanya untuk masa uji saat iAbu masih menjadi sumber transaksi. Hapus transaksi uji coba atau pakai database terpisah untuk uji transaksi.';
  END IF;

  -- 2. Backup lebih lama dari data yang sudah ada (salah pilih file).
  SELECT max(legacy.wib(tanggal)) INTO incoming_max FROM legacy.tbl_ikhd;
  SELECT max(occurred_at) INTO current_max FROM sales WHERE legacy_ref IS NOT NULL;
  IF current_max IS NOT NULL AND incoming_max < current_max
     AND coalesce(current_setting('glorypos.allow_older', true), '0') <> '1' THEN
    RAISE EXCEPTION 'Impor ulang dibatalkan: transaksi terakhir di backup ini (% WIB) lebih lama dari data yang sudah ada (% WIB).',
      to_char(incoming_max AT TIME ZONE 'Asia/Jakarta', 'DD-MM-YYYY HH24:MI'),
      to_char(current_max  AT TIME ZONE 'Asia/Jakarta', 'DD-MM-YYYY HH24:MI')
      USING HINT = 'Pastikan file .iAbu yang dipilih adalah yang terbaru. Bila memang sengaja mundur, jalankan dengan ALLOW_OLDER=1.';
  END IF;

  -- 3. Barang buatan Glory POS dengan kode yang juga ada di iAbu.
  SELECT count(*), string_agg(code, ', ') INTO n, contoh FROM (
    SELECT i.code FROM items i JOIN legacy.tbl_item l ON l.kodeitem = i.code
    WHERE i.legacy_ref IS NULL AND i.deleted_at IS NULL ORDER BY i.code LIMIT 10) x;
  IF n > 0 THEN
    RAISE EXCEPTION 'Impor ulang dibatalkan: kode barang dibuat di Glory POS dan juga ada di iAbu: %', contoh
      USING HINT = 'Selama masa uji, barang baru dibuat di iAbu. Hapus (soft delete) barang tersebut di Glory POS lalu ulangi.';
  END IF;

  -- 4. Mitra (supplier/pelanggan/dokter/sales) dengan kode bentrok.
  SELECT count(*), string_agg(code, ', ') INTO n, contoh FROM (
    SELECT p.code FROM partners p JOIN legacy.tbl_supel s ON s.kode = p.code
    WHERE p.legacy_ref IS NULL AND p.deleted_at IS NULL ORDER BY p.code LIMIT 10) x;
  IF n > 0 THEN
    RAISE EXCEPTION 'Impor ulang dibatalkan: kode supplier/pelanggan dibuat di Glory POS dan juga ada di iAbu: %', contoh
      USING HINT = 'Selama masa uji, supplier dan pelanggan baru dibuat di iAbu.';
  END IF;

  -- 5. Satuan / jenis / kategori / merek buatan Glory POS dengan nama yang juga dipakai iAbu.
  SELECT count(*), string_agg(nama, ', ') INTO n, contoh FROM (
    SELECT 'satuan ' || u.name AS nama FROM units u
    WHERE u.deleted_at IS NULL AND u.id <> legacy.lid('unit', u.name)
      AND u.name IN (SELECT upper(btrim(satuan)) FROM legacy.tbl_itemsatuanjml
                     UNION SELECT upper(btrim(satuan)) FROM legacy.tbl_item)
    UNION ALL
    SELECT 'jenis ' || g.name FROM item_groups g
    WHERE g.deleted_at IS NULL AND g.id <> legacy.lid('group', g.name)
      AND g.name IN (SELECT upper(btrim(jenis)) FROM legacy.tbl_item UNION SELECT upper(btrim(jenis)) FROM legacy.tbl_itemjenis)
    UNION ALL
    SELECT 'kategori ' || c.name FROM item_categories c
    WHERE c.deleted_at IS NULL AND c.id <> legacy.lid('category', c.name)
      AND c.name IN (SELECT upper(btrim(kategori)) FROM legacy.tbl_item UNION SELECT upper(btrim(kategori)) FROM legacy.tbl_itemkategori)
    UNION ALL
    SELECT 'merek ' || b.name FROM brands b
    WHERE b.deleted_at IS NULL AND b.id <> legacy.lid('brand', b.name)
      AND b.name IN (SELECT upper(btrim(merek)) FROM legacy.tbl_item UNION SELECT upper(btrim(merek)) FROM legacy.tbl_itemmerek)
    LIMIT 10) x;
  IF n > 0 THEN
    RAISE EXCEPTION 'Impor ulang dibatalkan: data referensi dibuat di Glory POS dengan nama yang juga ada di iAbu: %', contoh
      USING HINT = 'Hapus (soft delete) data tersebut di Glory POS lalu ulangi.';
  END IF;

  -- 6. Username buatan Glory POS yang sama dengan user iAbu.
  SELECT count(*), string_agg(username, ', ') INTO n, contoh FROM (
    SELECT u.username FROM users u JOIN legacy.tbl_user l ON lower(l.userid) = lower(u.username)
    WHERE u.deleted_at IS NULL AND u.id <> legacy.lid('user', l.userid) LIMIT 10) x;
  IF n > 0 THEN
    RAISE EXCEPTION 'Impor ulang dibatalkan: username dibuat di Glory POS dan juga ada di iAbu: %', contoh
      USING HINT = 'Ganti username tersebut di Glory POS lalu ulangi.';
  END IF;

  -- 7. Satuan barang atau harga buatan Glory POS pada barang dari iAbu yang bentrok
  --    dengan satuan/harga yang dibawa iAbu (barcode boleh diisi di baris iAbu).
  SELECT count(*), string_agg(code, ', ') INTO n, contoh FROM (
    SELECT i.code FROM item_units u JOIN items i ON i.id = u.item_id
    JOIN legacy.tbl_itemsatuanjml l ON l.kodeitem = i.legacy_ref
     AND legacy.lid('unit', upper(btrim(l.satuan))) = u.unit_id
    WHERE u.legacy_ref IS NULL AND u.deleted_at IS NULL
      AND u.id <> legacy.lid('item_unit_base', i.code)
    UNION
    SELECT i.code FROM item_prices p JOIN items i ON i.id = p.item_id
    WHERE p.legacy_ref IS NULL AND p.deleted_at IS NULL AND p.outlet_id IS NULL
      AND p.price_level = 'retail' AND i.legacy_ref IS NOT NULL
    LIMIT 10) x;
  IF n > 0 THEN
    RAISE EXCEPTION 'Impor ulang dibatalkan: satuan atau harga umum dibuat di Glory POS untuk barang dari iAbu: %', contoh
      USING HINT = 'Selama masa uji, satuan dan harga umum diubah di iAbu. Harga khusus per outlet atau level harga lain boleh dibuat di Glory POS.';
  END IF;
END $$;
