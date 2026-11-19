-- Data awal yang hanya dibuat SEKALI saat migrasi pertama (migrate.sql).
-- reimport.sql tidak memanggil file ini: pengaturan dan kategori biaya
-- sesudah go-live dikelola di Glory POS.
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
