-- =============================================================================
-- Glory POS - skema database server (PostgreSQL 16)
-- Apotek Glory Farma, Jember
--
-- Prinsip:
--   * Multi-outlet sejak awal: semua data operasional punya outlet_id.
--   * Offline-first: primary key UUID dibuat di perangkat kasir (UUIDv7),
--     sehingga transaksi offline tidak pernah bentrok saat sync.
--   * Tabel yang DITARIK kasir (master + batch stok) punya kolom sync:
--     sync_txid (xid8 transaksi penulis), rev (urutan dalam transaksi),
--     deleted_at (soft delete agar penghapusan ikut tersinkron).
--     Tabel transaksi hanya DIDORONG kasir, jadi tanpa kolom/indeks sync.
--   * Cursor pull = watermark xid8 (lihat sync_watermark()), BUKAN max(rev):
--     nilai sequence dibagikan sebelum commit, sehingga max(rev) bisa
--     melompati baris milik transaksi yang commit belakangan.
--   * Stok = jumlah mutasi per batch (FIFO). stock_batches.qty_remaining adalah
--     cache yang selalu bisa dihitung ulang dari stock_movements.
--   * Kuantitas di level stok selalu dalam SATUAN DASAR barang.
--   * legacy_ref menyimpan kunci asli dari database iAbu untuk audit migrasi.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- Sync infrastructure
-- -----------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS sync_rev_seq;

-- Tabel pull: catat transaksi penulis (xid8) + urutan, untuk sync kasir.
CREATE OR REPLACE FUNCTION touch_sync_columns() RETURNS trigger AS $$
BEGIN
  NEW.sync_txid := pg_current_xact_id();
  NEW.rev       := nextval('sync_rev_seq');
  IF TG_OP = 'UPDATE' THEN
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Tabel transaksi: cukup updated_at.
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Watermark pull. Semua transaksi dengan xid < nilai ini sudah selesai,
-- jadi baris yang belum pernah dilihat kasir pasti punya sync_txid >= nilai ini.
-- Endpoint /sync/pull, dipaginasi lintas request HTTP:
--   1. halaman pertama: wm := sync_watermark(), dikirim ke kasir sebagai batas atas
--      tetap untuk seluruh putaran ini
--   2. tiap halaman:  WHERE sync_txid >= $cursor AND sync_txid < $wm
--                       AND (sync_txid, rev) > ($last_txid, $last_rev)   -- keyset
--                     ORDER BY sync_txid, rev LIMIT n
--      Semua transaksi < wm sudah final, jadi isi jendela ini stabil antar request.
--      Baris yang diubah di tengah putaran pindah ke sync_txid >= wm dan
--      terambil di putaran berikutnya.
--   3. setelah halaman terakhir: cursor kasir := wm
-- Baris boleh terkirim ulang; kasir meng-upsert berdasarkan id (idempotent).
-- Pull tabel users WAJIB lewat v_sync_users (tanpa password_hash).
CREATE OR REPLACE FUNCTION sync_watermark() RETURNS xid8
  LANGUAGE sql STABLE AS $$ SELECT pg_snapshot_xmin(pg_current_snapshot()) $$;

-- -----------------------------------------------------------------------------
-- Enum types
-- -----------------------------------------------------------------------------
CREATE TYPE user_role        AS ENUM ('owner','admin','supervisor','pharmacist','cashier');
CREATE TYPE partner_type     AS ENUM ('supplier','customer','doctor','sales');
CREATE TYPE item_kind        AS ENUM ('stock','compound','service','non_stock');
CREATE TYPE drug_class       AS ENUM ('bebas','bebas_terbatas','keras','narkotika','psikotropika',
                                      'prekursor','oot','obat_tradisional','alkes','kosmetik','umum');
CREATE TYPE sale_type        AS ENUM ('pos','invoice','return');
CREATE TYPE purchase_type    AS ENUM ('purchase','return');
CREATE TYPE doc_status       AS ENUM ('draft','posted','void');
CREATE TYPE payment_method   AS ENUM ('cash','debit','credit_card','qris','emoney','transfer',
                                      'credit','insurance');
CREATE TYPE payment_status   AS ENUM ('unpaid','partial','paid','legacy');
CREATE TYPE movement_type    AS ENUM ('opening','purchase','purchase_return','sale','sale_return',
                                      'opname_in','opname_out','adjust_in','adjust_out',
                                      'transfer_in','transfer_out','expired_writeoff');
CREATE TYPE debt_kind        AS ENUM ('receivable','payable');

-- -----------------------------------------------------------------------------
-- Organisasi, perangkat, pengguna
-- -----------------------------------------------------------------------------
CREATE TABLE outlets (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code          varchar(20)  NOT NULL,                 -- mis. UTM, CB2
  name          varchar(150) NOT NULL,
  address       text,
  phone         varchar(50),
  npwp          varchar(50),
  sia_number    varchar(100),                          -- nomor Surat Izin Apotek
  apoteker_name varchar(150),
  sipa_number   varchar(100),                          -- SIPA apoteker penanggung jawab
  receipt_footer text,
  timezone      varchar(40) NOT NULL DEFAULT 'Asia/Jakarta', -- WIB/WITA/WIT per cabang
  is_active     boolean NOT NULL DEFAULT true,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);

-- Bukan tabel pull: kolom telemetri (last_seen_at, last_pull_txid) diperbarui
-- tiap sync, dan token_hash tidak boleh sampai ke kasir lain. Kasir menerima
-- identitas dirinya sendiri saat registrasi/login perangkat.
CREATE TABLE devices (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id      uuid NOT NULL REFERENCES outlets(id),
  code           varchar(20) NOT NULL,                 -- dipakai di nomor transaksi, mis. K1
  name           varchar(150) NOT NULL,
  token_hash     text,                                 -- hash token perangkat untuk API sync
  last_pull_txid xid8 NOT NULL DEFAULT '0'::xid8,      -- telemetri: watermark pull terakhir
  last_seen_at   timestamptz,
  app_version    varchar(30),
  is_active      boolean NOT NULL DEFAULT true,
  legacy_ref     text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz
);

CREATE TABLE users (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username          varchar(50)  NOT NULL,
  full_name         varchar(150) NOT NULL,
  password_hash     text,                              -- bcrypt/argon2; NULL = wajib set password
  pin_hash          text,                              -- PIN cepat untuk login kasir offline
  role              user_role NOT NULL,
  must_reset_password boolean NOT NULL DEFAULT true,
  is_active         boolean NOT NULL DEFAULT true,
  legacy_ref        text,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz
);

CREATE TABLE user_outlets (
  user_id    uuid NOT NULL REFERENCES users(id),
  outlet_id  uuid NOT NULL REFERENCES outlets(id),
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  PRIMARY KEY (user_id, outlet_id)
);

CREATE TABLE settings (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id  uuid REFERENCES outlets(id),              -- NULL = berlaku global
  key        varchar(100) NOT NULL,
  value      jsonb NOT NULL,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);
-- NULLS NOT DISTINCT (PG15+): outlet_id NULL dianggap satu nilai, sehingga
-- upsert bisa memakai ON CONFLICT (outlet_id, key) WHERE deleted_at IS NULL.
CREATE UNIQUE INDEX settings_scope_key ON settings (outlet_id, key) NULLS NOT DISTINCT WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- Master barang (global untuk semua outlet; harga bisa di-override per outlet)
-- -----------------------------------------------------------------------------
CREATE TABLE item_groups (                            -- legacy: tbl_itemjenis (TABLET, SYRUP, HV ...)
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar(100) NOT NULL,
  description text,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);

CREATE TABLE item_categories (                        -- legacy: tbl_itemkategori
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar(100) NOT NULL,
  description text,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);

CREATE TABLE brands (                                 -- legacy: tbl_itemmerek
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar(100) NOT NULL,
  description text,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);

CREATE TABLE units (                                  -- PCS, STRIP, BOX, BTL ...
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar(50) NOT NULL,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);

CREATE TABLE partners (                               -- legacy: tbl_supel
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code          varchar(50) NOT NULL,
  type          partner_type NOT NULL,
  name          varchar(200) NOT NULL,
  address       text,
  city          varchar(100),
  province      varchar(100),
  phone         varchar(50),
  email         varchar(150),
  contact_person varchar(150),
  npwp          varchar(50),
  bank_name     varchar(100),
  bank_account_name varchar(150),
  payment_term_days integer NOT NULL DEFAULT 0,
  credit_limit  numeric(18,2) NOT NULL DEFAULT 0,
  notes         text,
  is_default_walkin boolean NOT NULL DEFAULT false,  -- pelanggan UMUM
  is_active     boolean NOT NULL DEFAULT true,
  legacy_ref    text,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
CREATE INDEX partners_type_name ON partners (type, name);

CREATE TABLE items (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code             varchar(100) NOT NULL,              -- legacy kodeitem dipertahankan
  name             text NOT NULL,
  generic_name     text,                               -- zat aktif, untuk pencarian & substitusi
  kind             item_kind NOT NULL DEFAULT 'stock',
  drug_class       drug_class,                         -- golongan obat (baru, isi bertahap)
  requires_prescription boolean NOT NULL DEFAULT false,
  group_id         uuid REFERENCES item_groups(id),
  category_id      uuid REFERENCES item_categories(id),
  brand_id         uuid REFERENCES brands(id),
  base_unit_id     uuid NOT NULL REFERENCES units(id),
  default_supplier_id uuid REFERENCES partners(id),
  min_stock        numeric(18,3) NOT NULL DEFAULT 0,   -- dalam satuan dasar
  rack             varchar(100),
  is_consignment   boolean NOT NULL DEFAULT false,
  is_sellable      boolean NOT NULL DEFAULT true,
  tax_included     boolean NOT NULL DEFAULT true,      -- legacy SET_TIPE_PPN = Include
  last_cost        numeric(18,4) NOT NULL DEFAULT 0,   -- harga pokok terakhir per satuan dasar
  notes            text,
  is_active        boolean NOT NULL DEFAULT true,
  legacy_ref       text,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
CREATE INDEX items_name_trgm_fallback ON items (lower(name));

CREATE TABLE item_units (                             -- legacy: tbl_itemsatuanjml
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id       uuid NOT NULL REFERENCES items(id),
  unit_id       uuid NOT NULL REFERENCES units(id),
  conversion    numeric(18,3) NOT NULL CHECK (conversion > 0),  -- isi dalam satuan dasar
  is_base       boolean NOT NULL DEFAULT false,
  barcode       varchar(100),
  legacy_ref    text,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
CREATE UNIQUE INDEX item_units_barcode ON item_units (barcode) WHERE barcode IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE item_prices (                            -- legacy: tbl_item.hargajual1 + tbl_itemhj
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id       uuid NOT NULL REFERENCES items(id),
  unit_id       uuid NOT NULL REFERENCES units(id),
  outlet_id     uuid REFERENCES outlets(id),          -- NULL = harga umum semua outlet
  price_level   varchar(30) NOT NULL DEFAULT 'retail', -- retail, resep, grosir, member ...
  min_qty       numeric(18,3) NOT NULL DEFAULT 0,     -- harga bertingkat berdasarkan qty
  price         numeric(18,2) NOT NULL,
  legacy_ref    text,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
CREATE UNIQUE INDEX item_prices_key ON item_prices
  (item_id, unit_id, outlet_id, price_level, min_qty) NULLS NOT DISTINCT
  WHERE deleted_at IS NULL;

CREATE TABLE item_components (                        -- racikan / paket (legacy: tbl_itemrakitan)
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id       uuid NOT NULL REFERENCES items(id),   -- barang racikan
  component_id  uuid NOT NULL REFERENCES items(id),   -- bahan
  qty_base      numeric(18,3) NOT NULL,
  legacy_ref    text,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);

-- -----------------------------------------------------------------------------
-- Pembelian
-- -----------------------------------------------------------------------------
CREATE TABLE purchases (                              -- legacy: tbl_imhd (BL)
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id       uuid NOT NULL REFERENCES outlets(id),
  device_id       uuid REFERENCES devices(id),
  type            purchase_type NOT NULL DEFAULT 'purchase',
  number          varchar(60) NOT NULL,                -- nomor internal
  supplier_invoice_no varchar(100),                    -- nomor faktur dari PBF
  supplier_id     uuid REFERENCES partners(id),
  ref_purchase_id uuid REFERENCES purchases(id),       -- untuk retur pembelian
  occurred_at     timestamptz NOT NULL,
  due_date        date,
  subtotal        numeric(18,2) NOT NULL DEFAULT 0,
  discount        numeric(18,2) NOT NULL DEFAULT 0,
  tax             numeric(18,2) NOT NULL DEFAULT 0,
  other_cost      numeric(18,2) NOT NULL DEFAULT 0,
  total           numeric(18,2) NOT NULL DEFAULT 0,
  paid_amount     numeric(18,2) NOT NULL DEFAULT 0,
  payment_status  payment_status NOT NULL DEFAULT 'unpaid',
  status          doc_status NOT NULL DEFAULT 'posted',
  notes           text,
  created_by      uuid REFERENCES users(id),
  legacy_ref      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz,
  UNIQUE (outlet_id, number)
);
CREATE INDEX purchases_outlet_date ON purchases (outlet_id, occurred_at);
CREATE INDEX purchases_supplier ON purchases (supplier_id, payment_status);

CREATE TABLE purchase_lines (                         -- legacy: tbl_imdt
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_id   uuid NOT NULL REFERENCES purchases(id),
  line_no       integer NOT NULL,
  item_id       uuid NOT NULL REFERENCES items(id),
  unit_id       uuid NOT NULL REFERENCES units(id),
  qty           numeric(18,3) NOT NULL,
  conversion    numeric(18,3) NOT NULL DEFAULT 1,
  qty_base      numeric(18,3) NOT NULL,
  price         numeric(18,4) NOT NULL,              -- per unit_id
  discount_pct  numeric(9,4)  NOT NULL DEFAULT 0,
  tax           numeric(18,2) NOT NULL DEFAULT 0,
  total         numeric(18,2) NOT NULL,
  batch_no      varchar(100),
  expiry_date   date,                                -- WAJIB diisi di aplikasi baru
  legacy_ref    text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
CREATE INDEX purchase_lines_purchase ON purchase_lines (purchase_id);

-- -----------------------------------------------------------------------------
-- Penjualan
-- -----------------------------------------------------------------------------
CREATE TABLE sales (                                  -- legacy: tbl_ikhd (KSR, JL, RJ)
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id       uuid NOT NULL REFERENCES outlets(id),
  device_id       uuid REFERENCES devices(id),
  shift_id        uuid,                                -- FK ke cash_shifts (ditambah di bawah)
  type            sale_type NOT NULL DEFAULT 'pos',
  number          varchar(60) NOT NULL,                -- {OUTLET}-{DEVICE}-{YYMM}-{seq}
  occurred_at     timestamptz NOT NULL,
  customer_id     uuid REFERENCES partners(id),
  doctor_id       uuid REFERENCES partners(id),
  prescription_no varchar(100),
  patient_name    varchar(150),                        -- wajib untuk resep psikotropika/narkotika/OOT
  patient_address text,
  patient_phone   varchar(50),
  ref_sale_id     uuid REFERENCES sales(id),           -- untuk retur penjualan
  cashier_id      uuid REFERENCES users(id),
  subtotal        numeric(18,2) NOT NULL DEFAULT 0,
  discount        numeric(18,2) NOT NULL DEFAULT 0,
  tax             numeric(18,2) NOT NULL DEFAULT 0,
  other_cost      numeric(18,2) NOT NULL DEFAULT 0,
  rounding        numeric(18,2) NOT NULL DEFAULT 0,
  total           numeric(18,2) NOT NULL DEFAULT 0,
  cogs_total      numeric(18,2) NOT NULL DEFAULT 0,    -- HPP FIFO, dihitung server saat posting
  cash_tendered   numeric(18,2) NOT NULL DEFAULT 0,
  change_amount   numeric(18,2) NOT NULL DEFAULT 0,
  credit_amount   numeric(18,2) NOT NULL DEFAULT 0,    -- bagian piutang
  credit_paid     numeric(18,2) NOT NULL DEFAULT 0,
  due_date        date,
  payment_status  payment_status NOT NULL DEFAULT 'paid',
  status          doc_status NOT NULL DEFAULT 'posted',
  notes           text,
  synced_at       timestamptz,                         -- kapan diterima server
  legacy_ref      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz,
  UNIQUE (outlet_id, number)
);
CREATE INDEX sales_outlet_date ON sales (outlet_id, occurred_at);
CREATE INDEX sales_customer ON sales (customer_id) WHERE credit_amount > 0;

CREATE TABLE sale_lines (                             -- legacy: tbl_ikdt
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id       uuid NOT NULL REFERENCES sales(id),
  line_no       integer NOT NULL,
  item_id       uuid NOT NULL REFERENCES items(id),
  unit_id       uuid NOT NULL REFERENCES units(id),
  qty           numeric(18,3) NOT NULL,
  conversion    numeric(18,3) NOT NULL DEFAULT 1,
  qty_base      numeric(18,3) NOT NULL,
  price         numeric(18,2) NOT NULL,
  discount_pct  numeric(9,4)  NOT NULL DEFAULT 0,
  discount_amount numeric(18,2) NOT NULL DEFAULT 0,
  tax           numeric(18,2) NOT NULL DEFAULT 0,
  total         numeric(18,2) NOT NULL,
  cogs          numeric(18,2) NOT NULL DEFAULT 0,    -- HPP baris ini (FIFO)
  cogs_provisional boolean NOT NULL DEFAULT false,   -- true = sebagian qty belum dapat batch (stok minus)
  ref_line_id   uuid REFERENCES sale_lines(id),      -- baris asal saat retur
  legacy_ref    text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
CREATE INDEX sale_lines_sale ON sale_lines (sale_id);
CREATE INDEX sale_lines_item ON sale_lines (item_id);

CREATE TABLE sale_payments (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id    uuid NOT NULL REFERENCES sales(id),
  method     payment_method NOT NULL,
  amount     numeric(18,2) NOT NULL,
  reference  varchar(150),                            -- no. kartu/approval/QRIS
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
CREATE INDEX sale_payments_sale ON sale_payments (sale_id);

-- -----------------------------------------------------------------------------
-- Stok: batch FIFO + mutasi
-- -----------------------------------------------------------------------------
CREATE TABLE stock_batches (                          -- legacy: tbl_item_im
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id      uuid NOT NULL REFERENCES outlets(id),
  item_id        uuid NOT NULL REFERENCES items(id),
  source         movement_type NOT NULL,              -- opening/purchase/opname_in/transfer_in/...
  purchase_line_id uuid REFERENCES purchase_lines(id),
  batch_no       varchar(100),
  expiry_date    date,                                -- NULL = tidak diketahui
  received_at    timestamptz NOT NULL,
  unit_cost      numeric(18,4) NOT NULL,              -- per satuan dasar
  qty_in         numeric(18,3) NOT NULL,
  qty_remaining  numeric(18,3) NOT NULL CHECK (qty_remaining >= 0), -- cache; = sum(stock_movements.qty_base)
  legacy_ref     text,
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
CREATE INDEX stock_batches_fifo   ON stock_batches (outlet_id, item_id, received_at) WHERE qty_remaining > 0;
CREATE INDEX stock_batches_expiry ON stock_batches (outlet_id, expiry_date) WHERE qty_remaining > 0;

CREATE TABLE stock_movements (                        -- kartu stok; legacy: item_im + item_ik + item_ikret
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id      uuid NOT NULL REFERENCES outlets(id),
  item_id        uuid NOT NULL REFERENCES items(id),
  -- batch_id NULL pada mutasi keluar = DEFISIT: barang terjual saat stok sistem
  -- habis (mis. dua kasir offline menjual unit terakhir). Batch tidak pernah minus.
  -- unit_cost defisit sementara = items.last_cost (bukan 0) agar laba tidak
  -- terdistorsi; saat batch baru masuk, server mengalokasikan defisit FIFO ke
  -- batch itu, mengisi batch_id, memperbarui unit_cost, sale_lines.cogs dan
  -- sales.cogs_total, lalu mematikan cogs_provisional.
  -- Retur atas baris jual yang masih defisit tidak membuat baris sale_return
  -- tanpa batch (tidak terbaca v_stock_balance): server mengurangi qty_base
  -- mutasi defisit tersebut, atau soft delete bila terkompensasi penuh.
  batch_id       uuid REFERENCES stock_batches(id),
  type           movement_type NOT NULL,
  qty_base       numeric(18,3) NOT NULL,              -- + masuk, - keluar
  unit_cost      numeric(18,4) NOT NULL DEFAULT 0,
  ref_table      varchar(40),                         -- sales / purchases / stock_opnames / stock_transfers
  ref_id         uuid,
  ref_line_id    uuid,
  occurred_at    timestamptz NOT NULL,
  device_id      uuid REFERENCES devices(id),
  created_by     uuid REFERENCES users(id),
  legacy_ref     text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
CREATE INDEX stock_movements_card  ON stock_movements (outlet_id, item_id, occurred_at);
CREATE INDEX stock_movements_batch ON stock_movements (batch_id);
CREATE INDEX stock_movements_ref   ON stock_movements (ref_table, ref_id);
CREATE INDEX stock_movements_deficit ON stock_movements (outlet_id, item_id, occurred_at)
  WHERE batch_id IS NULL AND deleted_at IS NULL;

CREATE TABLE stock_opnames (                          -- legacy: tbl_itemopname (per periode)
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id    uuid NOT NULL REFERENCES outlets(id),
  number       varchar(60) NOT NULL,
  started_at   timestamptz NOT NULL,
  finalized_at timestamptz,
  status       doc_status NOT NULL DEFAULT 'draft',
  scope_note   text,                                 -- mis. "Rak A", "Semua sirup"
  created_by   uuid REFERENCES users(id),
  legacy_ref   text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz,
  UNIQUE (outlet_id, number)
);

CREATE TABLE stock_opname_lines (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  opname_id     uuid NOT NULL REFERENCES stock_opnames(id),
  item_id       uuid NOT NULL REFERENCES items(id),
  batch_id      uuid REFERENCES stock_batches(id),
  counted_at    timestamptz NOT NULL,
  system_qty    numeric(18,3) NOT NULL,
  physical_qty  numeric(18,3) NOT NULL,
  diff_qty      numeric(18,3) NOT NULL,
  unit_cost     numeric(18,4) NOT NULL DEFAULT 0,
  diff_value    numeric(18,2) NOT NULL DEFAULT 0,
  expiry_date   date,
  counted_by    uuid REFERENCES users(id),
  notes         text,
  legacy_ref    text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
CREATE INDEX stock_opname_lines_opname ON stock_opname_lines (opname_id);

CREATE TABLE stock_transfers (                        -- mutasi antar cabang (baru)
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  number          varchar(60) NOT NULL UNIQUE,
  from_outlet_id  uuid NOT NULL REFERENCES outlets(id),
  to_outlet_id    uuid NOT NULL REFERENCES outlets(id),
  sent_at         timestamptz,
  received_at     timestamptz,
  status          varchar(20) NOT NULL DEFAULT 'draft', -- draft, sent, received, void
  notes           text,
  created_by      uuid REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz,
  CHECK (from_outlet_id <> to_outlet_id)
);

CREATE TABLE stock_transfer_lines (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id  uuid NOT NULL REFERENCES stock_transfers(id),
  item_id      uuid NOT NULL REFERENCES items(id),
  qty_base     numeric(18,3) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);

-- -----------------------------------------------------------------------------
-- Hutang / piutang, biaya, shift kasir
-- -----------------------------------------------------------------------------
CREATE TABLE debt_payments (                          -- legacy: tbl_byrpiutanghd / tbl_byrhutanghd
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id   uuid NOT NULL REFERENCES outlets(id),
  kind        debt_kind NOT NULL,
  number      varchar(60) NOT NULL,
  partner_id  uuid NOT NULL REFERENCES partners(id),
  paid_at     timestamptz NOT NULL,
  method      payment_method NOT NULL DEFAULT 'cash',
  amount      numeric(18,2) NOT NULL,
  notes       text,
  created_by  uuid REFERENCES users(id),
  legacy_ref  text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz,
  UNIQUE (outlet_id, kind, number)
);

CREATE TABLE debt_payment_allocations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id   uuid NOT NULL REFERENCES debt_payments(id),
  sale_id      uuid REFERENCES sales(id),
  purchase_id  uuid REFERENCES purchases(id),
  amount       numeric(18,2) NOT NULL,
  discount     numeric(18,2) NOT NULL DEFAULT 0,
  legacy_ref   text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz,
  CHECK ((sale_id IS NULL) <> (purchase_id IS NULL))
);

CREATE TABLE expense_categories (
  id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar(100) NOT NULL,                         -- Gaji, Listrik, Sewa, Internet, Lain-lain
  sync_txid xid8, rev bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);

CREATE TABLE expenses (                               -- baru: dasar laba bersih
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id    uuid NOT NULL REFERENCES outlets(id),
  category_id  uuid NOT NULL REFERENCES expense_categories(id),
  occurred_at  timestamptz NOT NULL,
  amount       numeric(18,2) NOT NULL CHECK (amount > 0),
  method       payment_method NOT NULL DEFAULT 'cash',
  shift_id     uuid,
  description  text,
  attachment_url text,
  created_by   uuid REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
CREATE INDEX expenses_outlet_date ON expenses (outlet_id, occurred_at);

CREATE TABLE cash_shifts (                            -- buka/tutup kasir (baru)
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outlet_id       uuid NOT NULL REFERENCES outlets(id),
  device_id       uuid NOT NULL REFERENCES devices(id),
  user_id         uuid NOT NULL REFERENCES users(id),
  opened_at       timestamptz NOT NULL,
  closed_at       timestamptz,
  opening_cash    numeric(18,2) NOT NULL DEFAULT 0,
  expected_cash   numeric(18,2),
  counted_cash    numeric(18,2),
  difference      numeric(18,2),
  notes           text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz
);
ALTER TABLE sales    ADD CONSTRAINT sales_shift_fk    FOREIGN KEY (shift_id) REFERENCES cash_shifts(id);
ALTER TABLE expenses ADD CONSTRAINT expenses_shift_fk FOREIGN KEY (shift_id) REFERENCES cash_shifts(id);

-- -----------------------------------------------------------------------------
-- Audit & sync log
-- -----------------------------------------------------------------------------
CREATE TABLE audit_logs (
  id          bigserial PRIMARY KEY,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  user_id     uuid REFERENCES users(id),
  device_id   uuid REFERENCES devices(id),
  outlet_id   uuid REFERENCES outlets(id),
  action      varchar(50) NOT NULL,                   -- void_sale, price_change, opname_finalize ...
  entity      varchar(50) NOT NULL,
  entity_id   uuid,
  before      jsonb,
  after       jsonb
);
CREATE INDEX audit_logs_entity ON audit_logs (entity, entity_id);

CREATE TABLE sync_batches (                           -- setiap push dari kasir (idempotensi)
  id           uuid PRIMARY KEY,                      -- dibuat perangkat; push ulang = no-op
  device_id    uuid NOT NULL REFERENCES devices(id),
  received_at  timestamptz NOT NULL DEFAULT now(),
  record_count integer NOT NULL,
  status       varchar(20) NOT NULL,                  -- applied, partial, rejected
  error        text
);

-- -----------------------------------------------------------------------------
-- Trigger & indeks
--   * tabel PULL (ditarik kasir): sync_txid + rev, indeks (sync_txid, rev)
--   * tabel lain: updated_at saja (tanpa beban indeks sync)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  t text;
  pull_tables text[] := ARRAY['outlets','users','user_outlets','settings',
    'item_groups','item_categories','brands','units','partners','items','item_units',
    'item_prices','item_components','expense_categories','stock_batches'];
BEGIN
  FOREACH t IN ARRAY pull_tables LOOP
    EXECUTE format('CREATE TRIGGER trg_%1$s_sync BEFORE INSERT OR UPDATE ON %1$I
                    FOR EACH ROW EXECUTE FUNCTION touch_sync_columns()', t);
    EXECUTE format('CREATE INDEX %1$s_sync ON %1$I (sync_txid, rev)', t);
  END LOOP;
  FOR t IN SELECT c.table_name FROM information_schema.columns c
           WHERE c.table_schema = 'public' AND c.column_name = 'updated_at'
             AND c.table_name <> ALL (pull_tables)
             AND c.table_name IN (SELECT table_name FROM information_schema.tables
                                  WHERE table_schema = 'public' AND table_type = 'BASE TABLE')
  LOOP
    EXECUTE format('CREATE TRIGGER trg_%1$s_upd BEFORE UPDATE ON %1$I
                    FOR EACH ROW EXECUTE FUNCTION touch_updated_at()', t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Unik hanya untuk baris aktif, agar kode/nama yang di-soft-delete bisa dipakai lagi.
-- (Nomor dokumen transaksi tetap unik penuh: nomor nota tidak boleh dipakai ulang.)
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX outlets_code_active         ON outlets (code)               WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX devices_code_active         ON devices (outlet_id, code)    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX users_username_active       ON users (lower(username))      WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX item_groups_name_active     ON item_groups (name)           WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX item_categories_name_active ON item_categories (name)       WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX brands_name_active          ON brands (name)                WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX units_name_active           ON units (name)                 WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX partners_code_active        ON partners (code)              WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX items_code_active           ON items (code)                 WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX item_units_active           ON item_units (item_id, unit_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX expense_categories_active   ON expense_categories (name)    WHERE deleted_at IS NULL;

-- Indeks foreign key yang dipakai laporan
CREATE INDEX stock_opname_lines_item ON stock_opname_lines (item_id);
-- pull stok per cabang tidak memindai perubahan batch cabang lain
CREATE INDEX stock_batches_outlet_sync ON stock_batches (outlet_id, sync_txid, rev);
CREATE INDEX stock_batches_pline     ON stock_batches (purchase_line_id) WHERE purchase_line_id IS NOT NULL;
CREATE INDEX purchase_lines_item     ON purchase_lines (item_id);
CREATE INDEX debt_payments_partner   ON debt_payments (partner_id, paid_at);
CREATE INDEX debt_alloc_sale         ON debt_payment_allocations (sale_id)     WHERE sale_id IS NOT NULL;
CREATE INDEX debt_alloc_purchase     ON debt_payment_allocations (purchase_id) WHERE purchase_id IS NOT NULL;
CREATE INDEX sales_ref_sale          ON sales (ref_sale_id) WHERE ref_sale_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- View laporan
-- -----------------------------------------------------------------------------
-- Zona waktu: setiap view memakai outlets.timezone, bukan zona waktu server,
-- jadi "hari ini" dan tanggal laporan benar untuk WIB/WITA/WIT dan tidak
-- bergeser bila container PostgreSQL berjalan dalam UTC.

-- Stok per outlet per barang (satuan dasar) = sisa batch + defisit yang belum teralokasi
CREATE VIEW v_stock_balance AS
SELECT outlet_id, item_id, sum(qty) AS qty, sum(value) AS value
FROM (
  SELECT b.outlet_id, b.item_id, b.qty_remaining AS qty, b.qty_remaining * b.unit_cost AS value
  FROM stock_batches b WHERE b.deleted_at IS NULL
  UNION ALL
  SELECT m.outlet_id, m.item_id, m.qty_base, m.qty_base * m.unit_cost
  FROM stock_movements m WHERE m.batch_id IS NULL AND m.qty_base < 0 AND m.deleted_at IS NULL
) x
GROUP BY outlet_id, item_id;

-- Penjualan yang sempat membuat stok minus dan menunggu batch baru
CREATE VIEW v_stock_deficits AS
SELECT m.outlet_id, m.item_id, i.code, i.name, m.occurred_at, -m.qty_base AS qty,
       m.unit_cost AS provisional_cost, m.ref_id AS sale_id, m.ref_line_id AS sale_line_id
FROM stock_movements m
JOIN items i ON i.id = m.item_id
WHERE m.batch_id IS NULL AND m.qty_base < 0 AND m.deleted_at IS NULL;

-- Penjualan harian (retur mengurangi), tanggal menurut zona waktu outlet
CREATE VIEW v_sales_daily AS
SELECT s.outlet_id,
       (s.occurred_at AT TIME ZONE o.timezone)::date AS day,
       count(*) FILTER (WHERE s.type <> 'return')         AS trx_count,
       sum(CASE WHEN s.type = 'return' THEN -s.total      ELSE s.total END)      AS revenue,
       sum(CASE WHEN s.type = 'return' THEN -s.cogs_total ELSE s.cogs_total END) AS cogs,
       sum(CASE WHEN s.type = 'return' THEN -(s.total - s.cogs_total)
                ELSE s.total - s.cogs_total END)                                 AS gross_profit
FROM sales s
JOIN outlets o ON o.id = s.outlet_id
WHERE s.status = 'posted' AND s.deleted_at IS NULL
GROUP BY 1, 2;

-- Laba rugi bulanan: omzet - HPP - selisih opname - biaya operasional
CREATE VIEW v_profit_monthly AS
WITH s AS (
  SELECT outlet_id, date_trunc('month', day)::date AS month,
         sum(revenue) revenue, sum(cogs) cogs, sum(gross_profit) gross_profit
  FROM v_sales_daily GROUP BY 1, 2
), o AS (
  SELECT m.outlet_id, date_trunc('month', m.occurred_at AT TIME ZONE ot.timezone)::date AS month,
         sum(m.qty_base * m.unit_cost) AS opname_adjustment
  FROM stock_movements m
  JOIN outlets ot ON ot.id = m.outlet_id
  WHERE m.type IN ('opname_in','opname_out','adjust_in','adjust_out','expired_writeoff')
    AND m.deleted_at IS NULL
  GROUP BY 1, 2
), e AS (
  SELECT x.outlet_id, date_trunc('month', x.occurred_at AT TIME ZONE ot.timezone)::date AS month,
         sum(x.amount) AS expenses
  FROM expenses x JOIN outlets ot ON ot.id = x.outlet_id
  WHERE x.deleted_at IS NULL GROUP BY 1, 2
)
SELECT coalesce(s.outlet_id, o.outlet_id, e.outlet_id) AS outlet_id,
       coalesce(s.month, o.month, e.month)             AS month,
       coalesce(s.revenue, 0)            AS revenue,
       coalesce(s.cogs, 0)               AS cogs,
       coalesce(s.gross_profit, 0)       AS gross_profit,
       coalesce(o.opname_adjustment, 0)  AS stock_adjustment,
       coalesce(e.expenses, 0)           AS expenses,
       coalesce(s.gross_profit, 0) + coalesce(o.opname_adjustment, 0) - coalesce(e.expenses, 0) AS net_profit
FROM s
FULL JOIN o ON o.outlet_id = s.outlet_id AND o.month = s.month
FULL JOIN e ON e.outlet_id = coalesce(s.outlet_id, o.outlet_id) AND e.month = coalesce(s.month, o.month);

-- Stok expired dan mendekati expired, "hari ini" menurut zona waktu outlet
CREATE VIEW v_stock_expiry AS
SELECT b.outlet_id, b.item_id, i.code, i.name, b.batch_no, b.expiry_date,
       b.qty_remaining, b.unit_cost, b.qty_remaining * b.unit_cost AS value,
       CASE
         WHEN b.expiry_date IS NULL               THEN 'unknown'
         WHEN b.expiry_date <  t.today            THEN 'expired'
         WHEN b.expiry_date <  t.today + 30       THEN 'lt_1_month'
         WHEN b.expiry_date <  t.today + 90       THEN 'lt_3_months'
         WHEN b.expiry_date <  t.today + 180      THEN 'lt_6_months'
         ELSE 'ok'
       END AS expiry_status
FROM stock_batches b
JOIN items i   ON i.id = b.item_id
JOIN outlets o ON o.id = b.outlet_id
CROSS JOIN LATERAL (SELECT (now() AT TIME ZONE o.timezone)::date AS today) t
WHERE b.qty_remaining > 0 AND b.deleted_at IS NULL;

-- Kolom users yang boleh sampai ke SQLite kasir (password_hash tidak pernah ikut)
CREATE VIEW v_sync_users AS
SELECT id, username, full_name, pin_hash, role, is_active,
       sync_txid, rev, created_at, updated_at, deleted_at
FROM users;

-- Barang di bawah stok minimum
CREATE VIEW v_low_stock AS
SELECT o.id AS outlet_id, i.id AS item_id, i.code, i.name, i.min_stock,
       coalesce(sb.qty, 0) AS qty
FROM items i
CROSS JOIN outlets o
LEFT JOIN v_stock_balance sb ON sb.item_id = i.id AND sb.outlet_id = o.id
WHERE i.is_active AND i.deleted_at IS NULL AND i.kind = 'stock' AND i.min_stock > 0
  AND o.is_active AND o.deleted_at IS NULL
  AND coalesce(sb.qty, 0) <= i.min_stock;

-- Piutang & hutang terbuka
CREATE VIEW v_open_receivables AS
SELECT s.outlet_id, s.id AS sale_id, s.number, s.occurred_at, s.due_date, s.customer_id,
       s.credit_amount, s.credit_paid, s.credit_amount - s.credit_paid AS outstanding
FROM sales s
WHERE s.credit_amount > s.credit_paid AND s.status = 'posted' AND s.type <> 'return'
  AND s.deleted_at IS NULL;

CREATE VIEW v_open_payables AS
SELECT p.outlet_id, p.id AS purchase_id, p.number, p.supplier_invoice_no, p.occurred_at,
       p.due_date, p.supplier_id, p.total, p.paid_amount, p.total - p.paid_amount AS outstanding
FROM purchases p
WHERE p.payment_status IN ('unpaid','partial') AND p.status = 'posted' AND p.deleted_at IS NULL;
