# Glory POS - database & migrasi dari iAbu

| File | Isi |
| --- | --- |
| `schema.sql` | Skema PostgreSQL 16: 32 tabel + 8 view laporan, multi-outlet, siap sync offline (watermark xid8) |
| `migrate.sql` | Salin data dari schema `legacy` (backup iAbu) ke skema baru; idempotent (UUID deterministik) |
| `validate.sql` | 23 cek angka legacy vs baru + ringkasan laba, ED, kualitas data |
| `migrate.sh` | Menjalankan semuanya: restore → skema → migrasi → validasi |

## Menjalankan

```bash
# butuh PostgreSQL 15+ (NULLS NOT DISTINCT; diuji di 16), user dengan hak CREATEDB
export PGHOST=localhost PGUSER=postgres PGPASSWORD=...
DB=glory_pos ./migrate.sh /path/GLORY_161126.iAbu
```

Database tujuan **dihapus dan dibuat ulang** setiap kali dijalankan.
Schema `legacy` dibiarkan untuk audit; pakai `KEEP_LEGACY=0` untuk menghapusnya.

Hasil pada backup 16 Nov 2026: 23/23 cek OK, waktu proses ±15 detik.

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
