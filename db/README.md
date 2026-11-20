# Glory POS - database & migrasi dari iAbu

| File | Isi |
| --- | --- |
| `schema.sql` | Skema PostgreSQL 16: 32 tabel + 8 view laporan, multi-outlet, siap sync offline (watermark xid8) |
| `migrate.sh` + `migrate.sql` | **Migrasi pertama** ke database kosong: restore -> skema -> data -> validasi |
| `reimport.sh` + `reimport.sql` | **Impor ulang** backup iAbu terbaru ke database Glory POS yang sudah jalan (masa uji) |
| `validate.sql` | 23 cek angka legacy vs baru + ringkasan laba, ED, kualitas data |
| `legacy/helpers.sql` | Fungsi bantu (id deterministik, WIB, pembersihan ED) |
| `legacy/master.sql` | Outlet, user, referensi, barang, satuan, harga, racikan (upsert) |
| `legacy/transactions.sql` | Pembelian, batch, penjualan, opname, kartu stok, piutang (dibangun ulang) |
| `legacy/seed.sql` | Pengaturan awal dan kategori biaya (hanya migrasi pertama) |
| `legacy/guard.sql` | Pengaman impor ulang |
| `apply-migrations.sh` | Runner perubahan skema: `00001_baseline` (= `schema.sql`) + `migrations/*.sql`, dicatat di `schema_migrations` |
| `migrations/` | Perubahan skema setelah baseline, mulai `00002_...sql` (aturan di `migrations/README.md`) |

`migrate.sql` dan `reimport.sql` memakai file `legacy/*.sql` yang sama, jadi hasil migrasi pertama dan
impor ulang tidak pernah berbeda logika.

## Versi skema (`schema_migrations`)

`apply-migrations.sh` membuat tabel `schema_migrations(version, applied_at)` lalu:

- `00001_baseline`: bila database kosong, menerapkan `schema.sql`; bila tabel Glory POS sudah ada (database dibuat
  sebelum runner ini ada, atau oleh `migrate.sh`), hanya mencatat versinya.
- `migrations/NNNNN_*.sql` yang belum tercatat, berurutan, masing-masing satu transaksi bersama pencatatan versinya.

Dipanggil oleh `migrate.sh` (setelah `schema.sql`, sebelum `migrate.sql`), `reimport.sh` (sebelum `reimport.sql`),
dan `make test-db` (database template tes). Aman dijalankan berulang.

**sqlc** membaca `schema.sql` + `migrations/` secara langsung (diuji dengan sqlc v1.31: blok `DO $$` pembuat trigger
diabaikan parser tanpa error), jadi target `make sqlc-schema` / `db/sqlc/schema.sql` tidak diperlukan. Bila suatu
migrasi kelak ditolak parser sqlc, baru tambahkan target itu (lihat Task 1.1).

## Migrasi pertama

```bash
# butuh PostgreSQL 15+ (NULLS NOT DISTINCT; diuji di 16), user dengan hak CREATEDB
export PGHOST=localhost PGUSER=postgres PGPASSWORD=...
DB=glory_pos ./migrate.sh /path/GLORY_161126.iAbu

# atau di mesin dev, lewat PostgreSQL 16 di docker (client = versi server, tanpa PostgreSQL lokal):
make migrate-legacy LEGACY_DUMP="/path/GLORY 161126.iAbu"     # DB glory_pos di localhost:55432
```

Client `pg_dump` harus versi >= server; `reimport.sh` memakai `pg_dump`. Karena itu target `make` menjalankan
script di dalam container `postgres:16`.

Database tujuan **dihapus dan dibuat ulang**. Pakai hanya untuk database baru.
Schema `legacy` dibiarkan untuk audit; pakai `KEEP_LEGACY=0` untuk menghapusnya.
Hasil pada backup 16 Nov 2026: 23/23 cek OK, waktu proses ±15 detik.

## Impor ulang selama masa uji

Selama iAbu masih dipakai berjualan dan Glory POS dipakai memantau / mencoba, masukkan backup iAbu terbaru
tanpa menghapus database:

```bash
DB=glory_pos BACKUP_DIR=/srv/glorypos-backups ./reimport.sh /path/GLORY_terbaru.iAbu
make reimport-legacy LEGACY_DUMP=/path/GLORY_terbaru.iAbu     # mesin dev (backup DB disimpan di container)
```

| Diperbarui dari iAbu | Tidak disentuh (milik Glory POS) |
| --- | --- |
| Barang, satuan, harga umum, racikan, supplier/pelanggan (kolom asal iAbu) | Password, PIN, peran user; perangkat kasir; outlet dan pengaturan |
| Barang/user/satuan baru dari iAbu | Barcode, golongan obat, zat aktif, flag resep |
| Semua penjualan, retur, pembelian, opname, pembayaran piutang | Harga khusus per outlet / level harga lain |
| Stok, batch, ED, HPP | Biaya operasional, data referensi buatan Glory |

- Sebelum mengubah apa pun, database disalin ke `BACKUP_DIR` (`pg_dump -Fc`). Pulihkan dengan
  `pg_restore --clean --if-exists -d glory_pos <file.dump>`. `SKIP_BACKUP=1` untuk melewatinya.
- Satu transaksi: gagal di tengah = tidak ada yang berubah.
- Baris yang nilainya sama tidak disentuh, jadi kasir hanya menarik yang benar-benar berubah.
- **Ditolak** (dengan pesan dan saran) bila:
  - sudah ada transaksi yang dibuat di Glory POS (penjualan, pembelian, opname, mutasi, transfer);
  - backup lebih lama dari data yang sudah ada (`ALLOW_OLDER=1` bila memang sengaja);
  - kode barang, kode supplier/pelanggan, username, atau nama satuan/jenis/kategori/merek dibuat di
    Glory POS dan juga ada di iAbu;
  - satuan atau harga umum dibuat di Glory POS untuk barang asal iAbu.
- Aturan masa uji: **data master baru dan transaksi dibuat di iAbu**. Di Glory POS boleh mengisi
  barcode, golongan obat, zat aktif, flag resep, harga khusus outlet, user, perangkat, pengaturan, biaya.
  Uji coba transaksi Glory POS dilakukan di database terpisah.
- Saat go-live: impor ulang terakhir dari backup iAbu terakhir, iAbu dimatikan, lalu Glory POS dipakai sendiri.
  Setelah ada transaksi Glory POS, `reimport.sh` otomatis menolak berjalan.

Diuji pada data asli (backup dipotong per 31 Okt lalu diimpor ulang dengan backup 16 Nov): +455 nota,
+41 faktur, +1 barang, +262 batch; 16 tabel data iAbu identik dengan migrasi segar dari backup 16 Nov;
9 jenis isian Glory POS utuh; impor ulang backup yang sama tidak mengubah satu baris pun.

## Aturan migrasi penting

- Timestamp iAbu dianggap WIB (Asia/Jakarta).
- ED = NULL (tidak diketahui) bila kosong, sama dengan tanggal transaksi,
  default saldo awal 2024-01-14, atau < tahun 2000.
- `tbl_imdt.jmlkonversi` selalu NULL di iAbu; qty satuan dasar pembelian diambil dari batch (`tbl_item_im.jumlahdasar`).
- Pembayaran tunai = total nota − metode lain; `jmltunai` disimpan sebagai uang diterima, selisihnya kembalian.
- Pembelian lama → `payment_status = 'legacy'` (tidak dianggap hutang terbuka) sampai dikonfirmasi owner.
- Jurnal akuntansi iAbu (`tbl_accjurnal`) tidak dimigrasi; semua laporan dihitung dari transaksi.

## Pemetaan tabel

| iAbu | Glory POS |
| --- | --- |
| tbl_kantor, tbl_conf | outlets, settings |
| tbl_user | users (password tidak dimigrasi, wajib set ulang) |
| tbl_supel (SU/PL/SE/DO) | partners (supplier/customer/sales/doctor) |
| tbl_item, tbl_itemjenis, tbl_itemkategori, tbl_itemmerek | items, item_groups, item_categories, brands |
| tbl_itemsatuanjml | item_units |
| tbl_item.hargajual1, tbl_itemhj | item_prices |
| tbl_itemrakitan | item_components |
| tbl_imhd/imdt (BL) | purchases, purchase_lines |
| tbl_ikhd/ikdt (KSR/JL/RJ) | sales, sale_lines, sale_payments |
| tbl_item_im | stock_batches + stock_movements (masuk) |
| tbl_item_ik | stock_movements (keluar) + sale_lines.cogs |
| tbl_item_ikret | stock_movements (retur jual) |
| tbl_itemopname | stock_opnames, stock_opname_lines |
| tbl_byrpiutanghd/dt | debt_payments, debt_payment_allocations |

## Catatan untuk backend (Fase 1)

- **Pull sync**: cursor kasir = `sync_watermark()` (xid8), bukan `max(rev)`. Halaman pertama mengambil
  `wm := sync_watermark()` dan mengirimnya ke kasir sebagai batas atas tetap; tiap halaman memakai
  `WHERE sync_txid >= $cursor AND sync_txid < $wm AND (sync_txid, rev) > ($last_txid, $last_rev)
  ORDER BY sync_txid, rev`. Setelah halaman terakhir, cursor kasir := `wm`.
- **Tabel pull** (15): outlets, users (lewat `v_sync_users`, tanpa `password_hash`), user_outlets, settings,
  item_groups, item_categories, brands, units, partners, items, item_units, item_prices, item_components,
  expense_categories, stock_batches (filter `outlet_id`). `devices` bukan tabel pull.
- **Retur atas penjualan defisit**: kurangi `qty_base` mutasi defisitnya (soft delete bila lunas),
  jangan menambah `sale_return` tanpa batch.
- **Stok minus**: batch tidak boleh minus (`CHECK qty_remaining >= 0`). Kekurangan dicatat sebagai
  `stock_movements` keluar dengan `batch_id NULL` (HPP sementara = `items.last_cost`,
  `sale_lines.cogs_provisional = true`), lalu dialokasikan ke batch baru saat pembelian masuk.
- **Racikan** (`items.kind = 'compound'`): FIFO dijalankan pada tiap `item_components.component_id`.
- **Upsert**: `ON CONFLICT (outlet_id, key) WHERE deleted_at IS NULL` untuk `settings`;
  `(item_id, unit_id, outlet_id, price_level, min_qty) WHERE deleted_at IS NULL` untuk `item_prices`.
- **Login pertama**: password lama tidak dimigrasi; sediakan CLI `glorypos user:set-password`.
