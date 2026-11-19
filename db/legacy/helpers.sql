-- Fungsi bantu migrasi iAbu. Dibuat di schema legacy, jadi ikut hilang bila
-- schema legacy dihapus dan dibuat ulang setiap kali migrate.sql / reimport.sql jalan.
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

