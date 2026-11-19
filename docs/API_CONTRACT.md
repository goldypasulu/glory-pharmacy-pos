# API Contract - Glory POS v1

Kontrak ini mengikat server (`server/`), aplikasi kasir (`cashier/`), dan dashboard (`web/`).
Tipe Go untuk payload di sini tinggal di `shared/syncapi` (sync) dan `shared/api` (endpoint lain) agar
server dan kasir memakai definisi yang sama. Mengubah kontrak = ubah file ini dulu, baru kode.

## 1. Konvensi

- Base URL: `/api/v1`. JSON UTF-8. Nama field = nama kolom di `db/schema.sql` (snake_case).
- **Tipe nilai**

  | Data | Format JSON | Contoh |
  | --- | --- | --- |
  | id | string UUID (v7 untuk id baru) | `"01936f3a-8c2e-7b41-9a0e-2f1d4c5b6a70"` |
  | uang | string desimal 2 angka | `"12500.00"` |
  | qty, conversion | string desimal 3 angka | `"1.000"` |
  | unit_cost | string desimal 4 angka | `"2828.0000"` |
  | persen diskon | string desimal | `"2.5000"` |
  | timestamp | RFC 3339 dengan offset | `"2026-11-19T14:16:00+07:00"` |
  | tanggal | `YYYY-MM-DD` | `"2027-03-31"` |
  | xid8 (cursor sync) | string desimal | `"5589"` |
  | enum | string sesuai tipe enum di schema | `"pos"`, `"cash"` |
  | null | `null` (bukan string kosong) | |

- **Kolom yang tidak pernah dikirim:** `users.password_hash`, `devices.token_hash`. `users.pin_hash` hanya dikirim
  ke perangkat kasir lewat sync pull.
- **Kolom hitungan server** diabaikan bila dikirim klien: `cogs`, `cogs_total`, `cogs_provisional`, `credit_paid`,
  `payment_status`, `status` (kecuali lewat aksi void), `synced_at`, `sync_txid`, `rev`, `created_at`, `updated_at`.
- **Daftar (list):** `?limit=50&cursor=<opaque>`; respons `{"data": [...], "next_cursor": "..." | null}`.
  Pencarian `?q=`. Baris soft-delete tidak ikut kecuali `?include_deleted=true` (peran admin/owner).
- **Membuat dokumen:** klien mengirim `id` (UUIDv7). POST ulang dengan id dan isi sama = `200` dengan data yang ada;
  id sama tapi isi berbeda = `409 conflict`.
- **Mengubah master:** body PATCH wajib membawa `updated_at` versi yang diedit; bila sudah berubah = `409 stale_write`.

## 2. Autentikasi

| Klien | Header | Sumber token |
| --- | --- | --- |
| Dashboard web | `Authorization: Bearer <access_token>` | `POST /auth/login`, JWT 15 menit, diperbarui lewat `/auth/refresh` |
| Aplikasi kasir | `Authorization: Device <device_token>` | dibuat sekali di `POST /devices`, bisa dicabut (`devices.is_active`) |

Perangkat kasir hanya boleh memanggil `/sync/*`, `/devices/me`, dan `/healthz`. Kasir (orang) login offline
dengan PIN di aplikasi; `cashier_id` dikirim di tiap record push dan divalidasi server (aktif, anggota outlet perangkat).

## 3. Format error

```json
{
  "error": {
    "code": "validation_failed",
    "message": "Total pembayaran tidak sama dengan total nota",
    "details": [{"field": "payments", "issue": "sum_mismatch", "expected": "32000.00", "actual": "30000.00"}],
    "retryable": false,
    "request_id": "01936f3b-0f1a-7c22-8d4e-5a6b7c8d9e0f"
  }
}
```

| HTTP | code | Arti |
| --- | --- | --- |
| 400 | `bad_request`, `validation_failed` | JSON rusak / isi tidak valid (`details` per field, path gaya `lines[0].qty`) |
| 401 | `unauthenticated`, `token_expired` | token tidak ada, salah, atau kedaluwarsa |
| 403 | `forbidden`, `outlet_forbidden`, `device_inactive` | peran atau outlet tidak berhak, perangkat dicabut |
| 404 | `not_found` | |
| 409 | `conflict`, `stale_write`, `duplicate_number` | id/nomor bentrok, versi master usang |
| 413 | `payload_too_large` | push lebih dari 200 record atau 2 MB |
| 422 | `business_rule` | aturan bisnis, mis. `opname_already_finalized`, `sale_already_void` (di `details[0].issue`) |
| 429 | `rate_limited` | |
| 500 | `internal` | `retryable: true` |
| 503 | `unavailable` | maintenance / DB tidak siap, `retryable: true` |

## 4. Daftar endpoint

Peran: O=owner, A=admin, S=supervisor, P=pharmacist, C=cashier, D=perangkat kasir. Kolom Task = task pertama yang wajib
menyediakannya (lihat `docs/PHASE_1_TASKS.md`); task 3.x = Fase 3.

| Method | Path | Peran | Task | Keterangan |
| --- | --- | --- | --- | --- |
| GET | `/healthz`, `/readyz` | publik | 1.1 | hidup / DB siap |
| POST | `/auth/login` | publik | 1.2 | `{username, password}` -> token + user |
| POST | `/auth/refresh` | publik | 1.2 | `{refresh_token}` -> token baru (refresh token dirotasi) |
| POST | `/auth/logout` | semua | 1.2 | cabut refresh token |
| GET | `/auth/me` | semua | 1.2 | user + daftar outlet |
| GET/POST | `/users` | O,A | 1.2 | |
| PATCH | `/users/{id}` | O,A | 1.2 | nama, peran, aktif, outlet |
| PUT | `/users/{id}/password` | O,A (atau diri sendiri) | 1.2 | `{password}`; audit log |
| PUT | `/users/{id}/pin` | O,A,S (atau diri sendiri) | 1.2 | `{pin}` 6 digit |
| GET/POST | `/devices` | O,A | 1.2 | POST `{outlet_id, code, name}` -> `{device, device_token}` (token tampil sekali) |
| PATCH | `/devices/{id}` | O,A | 1.2 | `name`, `is_active` |
| POST | `/devices/{id}/rotate-token` | O,A | 1.2 | token baru, token lama mati |
| GET | `/devices/me` | D | 1.2 | identitas perangkat + outlet + timezone |
| GET/POST/PATCH | `/outlets` | O | 1.3 | |
| GET | `/settings?outlet_id=` | semua | 1.3 | gabungan global + override outlet |
| PUT | `/settings/{key}` | O,A | 1.3 | `{outlet_id \| null, value}` |
| GET/POST/PATCH/DELETE | `/units`, `/item-groups`, `/item-categories`, `/brands`, `/expense-categories` | baca semua; tulis O,A,P | 1.3 | data referensi; DELETE = soft delete |
| GET/POST/PATCH/DELETE | `/partners?type=` | baca semua; tulis O,A,P | 1.3 | supplier, customer, doctor, sales |
| GET | `/items?q=&group_id=&category_id=&is_active=` | semua | 1.3 | `q` cocok ke `code`, `name`, `generic_name`, barcode |
| GET | `/items/{id}` | semua | 1.3 | termasuk `units`, `prices`, `components` |
| GET | `/items/by-barcode/{barcode}` | semua | 1.3 | |
| POST/PATCH/DELETE | `/items`, `/items/{id}` | O,A,P | 1.3 | perubahan harga dicatat di audit log |
| PUT | `/items/{id}/units` | O,A,P | 1.3 | ganti seluruh daftar satuan (yang hilang di-soft-delete) |
| PUT | `/items/{id}/prices` | O,A,P | 1.3 | ganti seluruh daftar harga |
| PUT | `/items/{id}/components` | O,A,P | 1.3 | komposisi racikan |
| POST | `/sync/push` | D | 1.7 | lihat bagian 5 |
| POST | `/sync/pull` | D | 1.8 | lihat bagian 6 |
| GET/POST | `/purchases` | O,A,P | 1.6 | POST = faktur PBF; batch + ED wajib per baris |
| GET | `/purchases/{id}` | O,A,P,S | 1.6 | |
| POST | `/purchases/{id}/void` | O,A | 1.6 | ditolak bila batch-nya sudah terpakai |
| GET | `/sales?outlet_id=&from=&to=&type=&cashier_id=` | O,A,S,P | 1.5 | |
| GET | `/sales/{id}` | O,A,S,P | 1.5 | termasuk `lines`, `payments` |
| POST | `/sales` | O,A,S,P | 1.5 | faktur jual (`invoice`) dan retur (`return`) dari web; bentuk = data record sale di push |
| POST | `/sales/{id}/void` | O,A,S | 1.5 | `{reason}`; audit log |
| GET | `/stock/balances?outlet_id=&q=` | semua | 1.5 | dari `v_stock_balance` |
| GET | `/stock/batches?outlet_id=&item_id=` | semua | 1.5 | |
| GET | `/stock/card?outlet_id=&item_id=&from=&to=` | O,A,S,P | 1.5 | kartu stok dari `stock_movements` |
| GET | `/stock/deficits?outlet_id=` | O,A,S,P | 1.5 | `v_stock_deficits` |
| GET | `/stock/expiry?outlet_id=&status=` | semua | 1.5 | `v_stock_expiry` |
| POST | `/opnames` | O,A,S,P | 1.9 | `{id, outlet_id, number, scope_note}` -> draft |
| GET | `/opnames/{id}` | O,A,S,P | 1.9 | |
| PUT | `/opnames/{id}/lines` | O,A,S,P,C | 1.9 | upsert baris hitung (id baris dari klien) |
| POST | `/opnames/{id}/finalize` | O,A,S | 1.9 | buat mutasi opname, lunasi defisit bila ada; audit log |
| GET/POST/PATCH/DELETE | `/expenses` | O,A | 3.x | biaya operasional |
| POST | `/debt-payments` | O,A | 3.x | `{kind, partner_id, paid_at, method, amount, allocations[]}` |
| GET | `/reports/{name}?outlet_id=&from=&to=&format=json\|pdf\|xlsx` | O,A | 3.x | `sales-daily`, `profit-monthly`, `stock-expiry`, `low-stock`, `stock-card`, `opname`, `receivables` |
| GET | `/exports/{id}` | O,A | 3.x | laporan besar: 202 + polling, lalu tautan unduh |

## 5. `POST /sync/push`

Mengirim antrean outbox kasir. Batas 200 record atau 2 MB per batch.

```json
{
  "batch_id": "01936f40-1111-7aaa-8bbb-000000000001",
  "sent_at": "2026-11-19T14:20:05+07:00",
  "app_version": "1.0.0",
  "pending_outbox": 3,
  "records": [
    {"entity": "cash_shift", "op": "open",   "id": "<uuid>", "data": {"user_id": "<uuid>", "opened_at": "...", "opening_cash": "200000.00"}},
    {"entity": "sale",       "op": "create", "id": "<uuid>", "data": { "...lihat contoh di bawah..." }},
    {"entity": "sale",       "op": "void",   "id": "<uuid>", "data": {"reason": "salah input", "voided_by": "<uuid>", "voided_at": "..."}},
    {"entity": "cash_shift", "op": "close",  "id": "<uuid>", "data": {"closed_at": "...", "counted_cash": "1530000.00", "notes": null}}
  ]
}
```

| entity | op | data |
| --- | --- | --- |
| `sale` | `create` | header `sales` + `lines` + `payments` (contoh di bawah) |
| `sale` | `void` | `reason`, `voided_by`, `voided_at` |
| `cash_shift` | `open`, `close` | kolom `cash_shifts`; server menghitung `expected_cash` dan `difference` saat close |
| `expense` | `create` | kolom `expenses` |
| `purchase` | `create` | header `purchases` + `lines` (kolom `purchase_lines`) |
| `opname_line` | `upsert` | kolom `stock_opname_lines` + `opname_id` (opname harus `draft`) |

`outlet_id` dan `device_id` diambil dari token perangkat; bila dikirim dan berbeda = `rejected / outlet_forbidden`.

**Contoh data `sale.create`**

```json
{
  "number": "UTM-K1-2611-00042",
  "type": "pos",
  "occurred_at": "2026-11-19T14:16:00+07:00",
  "shift_id": "<uuid>",
  "cashier_id": "<uuid>",
  "customer_id": null,
  "doctor_id": null,
  "prescription_no": null,
  "patient_name": null, "patient_address": null, "patient_phone": null,
  "ref_sale_id": null,
  "subtotal": "32000.00", "discount": "0.00", "tax": "0.00", "other_cost": "0.00", "rounding": "0.00",
  "total": "32000.00",
  "cash_tendered": "50000.00", "change_amount": "18000.00",
  "credit_amount": "0.00", "due_date": null,
  "notes": null,
  "lines": [
    {"id": "<uuid>", "line_no": 1, "item_id": "<uuid>", "unit_id": "<uuid>",
     "qty": "2.000", "conversion": "1.000", "qty_base": "2.000",
     "price": "3000.00", "discount_pct": "0.0000", "discount_amount": "0.00", "tax": "0.00",
     "total": "6000.00", "ref_line_id": null}
  ],
  "payments": [
    {"id": "<uuid>", "method": "cash", "amount": "32000.00", "reference": null}
  ]
}
```

**Validasi server (gagal = `rejected`, `validation_failed`)**
- `qty_base = qty x conversion`; `line.total = round2(qty x price - discount_amount + tax)`.
- `subtotal = sum(lines.total)`; `total = subtotal - discount + tax + other_cost + rounding`.
- `sum(payments.amount) = total`; pembayaran `cash` = `cash_tendered - change_amount`; `credit_amount` = jumlah payment `credit`.
- `type = return` wajib `ref_sale_id`, tiap baris wajib `ref_line_id`, qty retur tidak melebihi qty asal dikurangi retur sebelumnya.
- Barang `drug_class` `psikotropika` / `narkotika` / `oot` dengan `requires_prescription` wajib `prescription_no` dan `patient_name`.
- Stok kurang **tidak** membuat record ditolak (menjadi defisit).

**Respons `200`**

```json
{
  "batch_id": "01936f40-1111-7aaa-8bbb-000000000001",
  "status": "partial",
  "server_time": "2026-11-19T14:20:06+07:00",
  "results": [
    {"id": "<uuid>", "entity": "cash_shift", "status": "applied",   "error": null, "server": null},
    {"id": "<uuid>", "entity": "sale",       "status": "applied",   "error": null,
     "server": {"cogs_total": "24826.00", "has_deficit": false}},
    {"id": "<uuid>", "entity": "sale",       "status": "duplicate", "error": null, "server": null},
    {"id": "<uuid>", "entity": "cash_shift", "status": "rejected",
     "error": {"code": "business_rule", "message": "Shift sudah ditutup", "details": [{"issue": "shift_already_closed"}], "retryable": false},
     "server": null}
  ]
}
```

- `status` batch: `applied` (semua applied/duplicate), `partial`, `rejected` (semua ditolak).
- Record diproses berurutan, masing-masing dalam transaksi DB sendiri. Record yang bergantung pada record gagal di batch
  yang sama = `rejected` dengan `dependency_failed`, `retryable: true`.
- Kasir menghapus record dari outbox bila `applied` atau `duplicate`. `rejected` + `retryable: true` dicoba lagi nanti;
  `retryable: false` dipindah ke daftar "perlu ditinjau" di aplikasi kasir.
- Mengirim ulang `batch_id` yang sama aman: record yang sudah tersimpan kembali sebagai `duplicate`.

## 6. `POST /sync/pull`

Menarik perubahan 15 tabel pull untuk outlet perangkat. Lihat komentar `sync_watermark()` di `db/schema.sql`.

**Request**

```json
{"cursor": "5589", "wm": null, "after": null, "limit": 1000}
```

- `cursor`: watermark terakhir yang tersimpan di kasir; `"0"` untuk sync pertama.
- `wm`: `null` di halaman pertama; halaman berikutnya mengirim ulang `wm` dari respons pertama.
- `after`: `null` di halaman pertama; halaman berikutnya = `next.after` dari respons sebelumnya.
- `limit`: 1-2000, default 1000.

**Respons `200`**

```json
{
  "wm": "5601",
  "rows": [
    {"table": "items", "key": {"id": "<uuid>"}, "sync_txid": "5594", "rev": 16324, "deleted": false,
     "data": {"id": "<uuid>", "code": "SARIDON", "name": "SARIDON", "...": "kolom lain items"}},
    {"table": "user_outlets", "key": {"user_id": "<uuid>", "outlet_id": "<uuid>"}, "sync_txid": "5595", "rev": 16330,
     "deleted": true, "data": null}
  ],
  "next": {"after": {"sync_txid": "5595", "rev": 16330}},
  "done": false
}
```

- Server: `wm` dihitung sekali di halaman pertama; setiap halaman `sync_txid >= cursor AND sync_txid < wm AND
  (sync_txid, rev) > after`, urut `(sync_txid, rev)`, gabungan semua tabel pull.
- `deleted: true` bila `deleted_at` terisi; `data` boleh `null`.
- `data` = kolom tabel tanpa kolom rahasia; `users` dari `v_sync_users`; `stock_batches` hanya outlet perangkat;
  `users` dan `user_outlets` hanya anggota outlet perangkat.
- `done: true` = halaman terakhir; `next` = `null`.

**Aturan kasir**
1. Setiap halaman ditulis ke tabel staging lokal dalam transaksi pendek (tidak menahan transaksi penjualan).
2. Setelah `done: true`, staging di-merge ke tabel lokal dan `cursor := wm` disimpan dalam **satu** transaksi SQLite
   (dengan `PRAGMA defer_foreign_keys = ON`), lalu staging dikosongkan.
3. Bila koneksi putus di tengah, staging dibuang dan pull diulang dari `cursor` lama. Baris yang terkirim dua kali
   di-upsert berdasarkan `key`.
4. Stok lokal yang ditampilkan kasir = `stock_batches.qty_remaining` dari server dikurangi penjualan lokal yang belum
   ter-push.

## 7. Objek master di endpoint web

Bentuk objek = kolom tabel di `db/schema.sql` tanpa kolom rahasia, ditambah relasi tertanam:

- `item` = kolom `items` + `units: [item_units]` + `prices: [item_prices]` + `components: [item_components]`
  + `stock: {qty, value}` bila diminta dengan `?include=stock&outlet_id=`.
- `sale` = kolom `sales` + `lines: [sale_lines]` + `payments: [sale_payments]`.
- `purchase` = kolom `purchases` + `lines: [purchase_lines]`.
- `opname` = kolom `stock_opnames` + `lines: [stock_opname_lines]`.
- `user` = kolom `users` tanpa `password_hash` dan `pin_hash` + `outlet_ids: [uuid]`.
- `device` = kolom `devices` tanpa `token_hash`.
