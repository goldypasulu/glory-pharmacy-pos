# Fase 1 - Server inti

Tujuan Fase 1: API Go yang bisa menerima penjualan dari kasir (online/offline), menghitung stok dan HPP FIFO dengan
benar, mengirim data master ke kasir, dan berjalan di VPS. Dashboard (Fase 3) dan aplikasi kasir (Fase 2) belum.

Cara pakai:
- Kerjakan **satu task per sesi**, berurutan. Task boleh dimulai bila task di kolom "Butuh" sudah selesai.
- Setiap task selesai bila **semua kotak kriteria tercentang** dan `make check` hijau, lalu commit
  `task 1.N: <ringkasan>`. Centang kotaknya di file ini dalam commit yang sama.
- Tes untuk logika sensitif ditulis lebih dulu (lihat CLAUDE.md, "Cara kerja").
- Perubahan skema = file baru di `db/migrations/`, bukan edit `db/schema.sql`.

| Task | Judul | Butuh |
| --- | --- | --- |
| 1.1 | Kerangka server, tooling, harness DB tes | - |
| 1.2 | Auth, user, perangkat, CLI | 1.1 |
| 1.3 | API data master | 1.2 |
| 1.4 | Engine FIFO dan defisit (`shared/inventory`) | 1.1 |
| 1.5 | Posting penjualan, retur, void, baca stok | 1.3, 1.4 |
| 1.6 | Pembelian dan pelunasan defisit | 1.5 |
| 1.7 | Sync push | 1.5, 1.6 |
| 1.8 | Sync pull | 1.2 |
| 1.9 | Stok opname | 1.6 |
| 1.10 | Deploy VPS + uji asap dengan data Glory | 1.7, 1.8, 1.9 |

---

## Task 1.1 - Kerangka server, tooling, harness DB tes

**Lingkup**
- `server/cmd/glorypos/main.go`: subperintah dengan paket `flag` standar (tanpa library CLI). Untuk task ini cukup `serve`.
- `server/internal/config`: env `GLORYPOS_DATABASE_URL`, `GLORYPOS_HTTP_ADDR` (default `:8080`),
  `GLORYPOS_JWT_SECRET`, `GLORYPOS_ENV` (`dev`|`prod`), `GLORYPOS_LOG_LEVEL`. Gagal start bila wajib kosong.
- `server/internal/store`: `pgxpool` dengan registrasi `pgx-shopspring-decimal` di `AfterConnect`, helper
  `WithTx(ctx, pool, func(*Queries) error)`.
- `server/sqlc.yaml`: schema `../db/schema.sql` + `../db/migrations`, query `internal/store/queries`, `sql_package: pgx/v5`,
  override `numeric` -> `decimal.Decimal`, `uuid` -> `github.com/google/uuid.UUID`, `timestamptz` -> `time.Time`.
  Kolom `xid8` selalu di-cast `::text` di query.
- **Cek pertama:** jalankan `sqlc generate` terhadap skema. Bila parser sqlc menolak `db/schema.sql` (mis. blok `DO $$`),
  tambahkan target `make sqlc-schema` yang membuat `db/sqlc/schema.sql` lewat `pg_dump --schema-only --no-owner`
  dari database template, arahkan `sqlc.yaml` ke file itu, dan commit hasilnya. Catat keputusan ini di `db/README.md`.
- `server/internal/httpapi`: router chi, middleware request id, recoverer, logger slog, timeout; `GET /healthz`,
  `GET /readyz` (ping DB); penulis error sesuai `docs/API_CONTRACT.md` bagian 3.
- `db/apply-migrations.sh`: membuat `schema_migrations(version text primary key, applied_at timestamptz)`, menerapkan
  `db/migrations/*.sql` yang belum tercatat, berurutan, masing-masing dalam satu transaksi. `db/migrate.sh` memanggilnya
  setelah `schema.sql` dan sebelum `migrate.sql`; `db/reimport.sh` memanggilnya sebelum `reimport.sql` (database lama
  mungkin belum punya migrasi terbaru).
- `deploy/docker-compose.dev.yml`: PostgreSQL 16 untuk tes di port `55432`, data di `tmpfs`, `TZ=Asia/Jakarta`.
- `server/internal/testdb`: `testdb.New(t)` membuat database baru `TEMPLATE glorypos_template` dan menghapusnya saat
  `t.Cleanup`. Bila `TEST_DATABASE_URL` kosong, tes **gagal** dengan pesan jelas (bukan skip).
- `Makefile`: `fmt`, `vet`, `sqlc`, `test`, `test-db` (naikkan compose dev + buat template dari schema.sql + migrations),
  `check` (= gofmt -l kosong + vet + `sqlc diff` + test), `run`, `migrate-legacy LEGACY_DUMP=...`,
  `reimport-legacy LEGACY_DUMP=...`.

**Di luar lingkup:** endpoint bisnis, auth, Dockerfile produksi.

**Kriteria**
- [x] `make test-db && make check` hijau dari repo bersih.
- [x] `sqlc generate` berhasil (langsung atau lewat `make sqlc-schema`), dan `sqlc diff` bersih.
- [x] Tes: `/healthz` 200; `/readyz` 200 saat DB hidup dan 503 `unavailable` saat pool ditutup.
- [x] Tes: handler yang panic menghasilkan 500 berformat error kontrak dengan `request_id`, server tetap hidup.
- [x] Tes: `testdb.New` menghasilkan database berisi semua tabel `schema.sql` + migrations, terisolasi antar tes paralel.
- [x] `make migrate-legacy LEGACY_DUMP=<backup>` tetap lolos 23/23 cek dan mencatat versi di `schema_migrations`.
- [x] `make reimport-legacy LEGACY_DUMP=<backup yang sama>` lolos 23/23 dan ringkasannya menunjukkan selisih 0.

---

## Task 1.2 - Auth, user, perangkat, CLI

**Lingkup**
- Migrasi `00002_auth_refresh_tokens.sql`: `auth_refresh_tokens(id, user_id, token_hash, expires_at, revoked_at,
  replaced_by, created_at, user_agent)`.
- Login bcrypt, access token JWT 15 menit (`sub`, `role`, `outlet_ids`), refresh token acak 32 byte (disimpan SHA-256),
  rotasi tiap refresh, deteksi pemakaian ulang (token lama dipakai lagi -> cabut semua token user itu).
- `must_reset_password = true`: login berhasil tapi token hanya boleh dipakai untuk `/auth/me` dan ganti password sendiri.
- Middleware: `RequireUser`, `RequireRole(...)`, `RequireDevice` (token perangkat 32 byte, disimpan SHA-256 di
  `devices.token_hash`; perangkat nonaktif = 403 `device_inactive`).
- Endpoint bagian Auth, Users, Devices di kontrak.
- CLI: `glorypos user:set-password --username <u>` (baca password dari prompt tanpa echo atau `--password-stdin`,
  set `must_reset_password=false`), `glorypos user:create --username --full-name --role --outlet <code>`,
  `glorypos device:create --outlet <code> --code <K1> --name <...>` (cetak token sekali).
- Audit log: set/reset password, rotasi token perangkat, perubahan peran.

**Kriteria**
- [ ] Tes: login benar, password salah, user tidak ada (pesan dan status sama: 401 `unauthenticated`), user nonaktif 403.
- [ ] Tes: `must_reset_password` membatasi akses sesuai aturan di atas.
- [ ] Tes: refresh berotasi; refresh token lama dipakai ulang mencabut semua sesi user.
- [ ] Tes tabel peran x endpoint (O/A/S/P/C) untuk semua endpoint task ini.
- [ ] Tes: token perangkat valid, salah, dicabut, dan dirotasi.
- [ ] Tes: serialisasi JSON user dan device tidak pernah memuat `password_hash`, `pin_hash`, `token_hash`.
- [ ] Uji manual pada DB hasil `migrate-legacy`: `user:set-password --username admin` lalu login berhasil.

---

## Task 1.3 - API data master

**Lingkup:** endpoint Outlets, Settings, data referensi, Partners, Items (termasuk `units`, `prices`, `components`,
`by-barcode`) sesuai kontrak; pencarian `q` (ILIKE pada `code`, `name`, `generic_name`, dan barcode); paging keyset;
`PUT` mengganti seluruh daftar (baris yang hilang di-soft-delete); `PATCH` wajib `updated_at` (409 `stale_write`);
pelanggaran unique index aktif = 409 `conflict` dengan `details[0].field`. Perubahan harga ditulis ke `audit_logs`.

**Kriteria**
- [ ] Tes CRUD tiap resource termasuk soft delete lalu membuat ulang kode yang sama (harus berhasil).
- [ ] Tes `stale_write` dan `conflict`.
- [ ] Tes `PUT /items/{id}/prices` dengan harga global + override outlet + harga bertingkat (`min_qty`).
- [ ] Tes `PUT /settings/{key}` untuk `outlet_id = null` dua kali menghasilkan satu baris (upsert `NULLS NOT DISTINCT`).
- [ ] Tes `GET /items?q=` menemukan barang dari barcode dan dari zat aktif.
- [ ] Setiap tulis master menaikkan `sync_txid` (dicek lewat query).

---

## Task 1.4 - Engine FIFO dan defisit (`shared/inventory`)

Kode murni tanpa DB. Server (1.5, 1.6, 1.9) dan kasir (Fase 2) memakai paket yang sama.
Juga buat `shared/money` (pembulatan) dan `shared/numbering` (format dan parse nomor nota).

**Fungsi minimal**
- `AllocateOut(batches []Batch, qty decimal.Decimal) (allocs []Allocation, deficit decimal.Decimal, err error)`:
  urut `ReceivedAt`, lalu `ID`; hanya batch `Remaining > 0`.
- `SettleDeficits(incoming Batch, deficits []Deficit) (settled []Settlement, leftover decimal.Decimal)`:
  defisit tertua (`OccurredAt`, lalu `ID`) dilunasi dulu.
- `PlanReturn(lineAllocs []Allocation, lineDeficit decimal.Decimal, qty decimal.Decimal) ReturnPlan`:
  kurangi defisit dulu, sisanya dikembalikan ke batch asal mulai dari alokasi terakhir.
- `ExpandCompound(qtyBase decimal.Decimal, components []Component) []Demand`.
- `LineCOGS(allocs, deficit, provisionalCost) (cogs decimal.Decimal, provisional bool)`.

**Kriteria (tes tabel, ditulis sebelum implementasi)**
- [ ] Penjualan dalam satu batch, lintas tiga batch, tepat menghabiskan batch.
- [ ] Defisit sebagian dan defisit penuh; HPP sementara memakai `provisionalCost`, bukan 0.
- [ ] Urutan stabil bila `ReceivedAt` sama (berdasarkan `ID`).
- [ ] Qty 0 atau negatif = error; batch dengan `Remaining` negatif di input = error.
- [ ] `SettleDeficits` melunasi beberapa defisit dari nota berbeda, berurutan, dengan sisa batch benar.
- [ ] `PlanReturn` untuk baris defisit penuh, campuran, dan tanpa defisit.
- [ ] Racikan dengan dua bahan, salah satunya defisit.
- [ ] Fuzz `FuzzAllocateOut`: jumlah alokasi + defisit = qty, tidak ada batch minus, total HPP = jumlah alokasi x cost.
- [ ] `numbering`: format `UTM-K1-2611-00042`, parse kembali, tolak format salah.

---

## Task 1.5 - Posting penjualan, retur, void, baca stok

**Lingkup**
- Migrasi `00003_doc_sequences.sql`: `doc_sequences(outlet_id, prefix, period, last_value)` untuk nomor dokumen yang
  dibuat server (penjualan web memakai kode perangkat `W`, mis. `UTM-W-2611-00007`).
- Service `sales.Post`: validasi (kontrak bagian 5, aturan disimpan di `shared` agar kasir bisa memakainya), ekspansi
  racikan, kunci batch `FOR UPDATE` urut `item_id`, alokasi dengan `shared/inventory`, tulis `sales`, `sale_lines`,
  `sale_payments`, `stock_movements`, update `stock_batches`, isi `cogs`, `cogs_provisional`, `cogs_total`, `payment_status`.
- Retur (`type = return`) dan `sales.Void` (status `void`, mutasi balik ke batch asal, defisit di-soft-delete, audit log
  berisi alasan dan pelaku).
- Endpoint Sales dan Stock di kontrak.

**Kriteria (tes integrasi PostgreSQL)**
- [ ] HPP nota normal sama dengan hitungan manual dari fixture.
- [ ] 50 kali dua goroutine menjual unit terakhir barang yang sama bersamaan: tidak ada batch minus, tepat satu defisit
      per putaran, tidak ada deadlock.
- [ ] Dua nota berisi barang A,B dan B,A diposting bersamaan berulang kali tanpa deadlock.
- [ ] Void mengembalikan `qty_remaining` persis seperti sebelum penjualan; void kedua = 422 `sale_already_void`.
- [ ] Retur sebagian, retur melebihi sisa (ditolak), retur atas baris defisit (defisit berkurang, tidak ada `sale_return`
      tanpa batch).
- [ ] Racikan memotong stok bahan dan HPP = jumlah HPP bahan.
- [ ] Setelah setiap skenario: `stock_batches.qty_remaining` = jumlah `stock_movements` per batch, dan `v_stock_balance`
      konsisten (query invarian dijadikan helper tes).
- [ ] Validasi: total tidak cocok, pembayaran tidak cocok, resep wajib untuk psikotropika/narkotika/OOT.

---

## Task 1.6 - Pembelian dan pelunasan defisit

**Lingkup:** `purchases.Post`: batch per baris (`batch_no`, `expiry_date` wajib bila setting
`require_expiry_on_purchase`), mutasi `purchase`, `items.last_cost` = harga bersih per satuan dasar, lalu
`SettleDeficits` untuk outlet dan barang itu (update mutasi defisit, `sale_lines.cogs`, `sales.cogs_total`,
`cogs_provisional`). `payment_status` dari `paid_amount`. Void pembelian hanya bila semua batch-nya belum terpakai.
Endpoint Purchases di kontrak.

**Kriteria**
- [ ] Pembelian melunasi defisit dari dua nota berbeda; HPP kedua nota berubah dari biaya sementara ke biaya batch baru
      dan `cogs_provisional` mati.
- [ ] Pembelian yang hanya melunasi sebagian defisit: sisa defisit tetap, flag tetap menyala pada baris yang belum lunas.
- [ ] `last_cost` terhitung benar untuk satuan BOX isi 10 dengan diskon persen.
- [ ] ED kosong ditolak saat setting aktif.
- [ ] Void ditolak bila batch sudah terpakai, berhasil bila belum.
- [ ] Invarian stok tetap benar setelah semua skenario.

---

## Task 1.7 - Sync push

**Lingkup:** `POST /sync/push` sesuai kontrak bagian 5. Entity `sale`, `cash_shift`, `expense`, `purchase`,
`opname_line` memakai service yang sama dengan endpoint web. Satu transaksi per record, pelacakan dependensi dalam batch,
catat `sync_batches`, perbarui `devices.last_seen_at` dan `app_version`. Tipe payload di `shared/syncapi`.

**Kriteria**
- [ ] Batch yang sama dikirim dua kali: hasil kedua semua `duplicate`, stok dan HPP tidak berubah.
- [ ] Id sale sama dengan isi berbeda = `rejected` `conflict`.
- [ ] Shift gagal dibuka -> sale yang memakai shift itu `rejected` `dependency_failed`, `retryable: true`.
- [ ] `outlet_id` berbeda dari outlet perangkat = `outlet_forbidden`; kasir bukan anggota outlet = ditolak.
- [ ] Penjualan saat stok habis tetap `applied` dengan `server.has_deficit: true`.
- [ ] Lebih dari 200 record atau 2 MB = 413.
- [ ] 200 sale dalam satu batch selesai di bawah 5 detik pada mesin dev (catat angkanya).

---

## Task 1.8 - Sync pull

**Lingkup:** `POST /sync/pull` sesuai kontrak bagian 6: `UNION ALL` 15 tabel pull (users lewat `v_sync_users`),
filter outlet perangkat, keyset `(sync_txid, rev)`, batas atas `wm`. Simpan `devices.last_pull_txid` saat `done`.

**Kriteria**
- [ ] Pull pertama (`cursor "0"`) pada DB hasil migrasi legacy mengembalikan jumlah baris per tabel yang sama dengan
      `count(*)` tabel itu (dengan filter outlet).
- [ ] Uji race dua transaksi: T1 menulis lebih dulu tapi commit belakangan, T2 commit duluan; pull di antaranya lalu
      pull berikutnya tidak melewatkan baris T1.
- [ ] Baris diubah di antara halaman 1 dan 2: tidak hilang (muncul di putaran berikutnya), halaman tidak dobel.
- [ ] Baris soft delete terkirim `deleted: true`.
- [ ] Tidak ada `password_hash`, `token_hash`, atau baris `devices` di respons mana pun (cek seluruh JSON).
- [ ] `stock_batches` dan `users` outlet lain tidak ikut.
- [ ] `limit` di luar 1-2000 = 400.

---

## Task 1.9 - Stok opname

**Lingkup:** endpoint Opname di kontrak dan entity push `opname_line`. Saat baris dihitung, simpan `system_qty`
(stok saat `counted_at`). Finalisasi: selisih = `physical_qty - system_qty`; plus -> batch baru `opname_in`
(`unit_cost = last_cost`, `expiry_date` dari baris) lalu `SettleDeficits`; minus -> `AllocateOut` tipe `opname_out`
(kalau baris menyebut `batch_id`, potong batch itu). Opname final tidak bisa diubah. Audit log.

**Kriteria**
- [ ] Opname plus, minus, dan nol; nilai `diff_value` = selisih x biaya.
- [ ] Penjualan terjadi setelah `counted_at` tapi sebelum finalisasi: hasil akhir tetap benar.
- [ ] Opname plus melunasi defisit yang ada.
- [ ] Finalisasi kedua = 422 `opname_already_finalized`; edit baris setelah final ditolak.
- [ ] `v_profit_monthly.stock_adjustment` bulan itu sama dengan total `diff_value`.

---

## Task 1.10 - Deploy VPS + uji asap

**Lingkup**
- `deploy/Dockerfile` multi-stage (`GOWORK=off`, binary statis), `deploy/docker-compose.yml`: `db` (PostgreSQL 16,
  limit 768 MB, `shared_buffers=256MB`, `work_mem=8MB`, `TZ=Asia/Jakarta`, `-c timezone=Asia/Jakarta`), `app`
  (512 MB), `caddy` (128 MB, HTTPS otomatis), service sekali jalan `migrate` (`db/apply-migrations.sh`).
- `deploy/backup.sh`: `pg_dump -Fc` harian, simpan 30 hari, contoh cron. `deploy/README.md`: langkah deploy dari nol,
  update, restore.
- Uji asap di mesin dev dengan compose produksi: migrasi data Glory -> set password admin -> buat perangkat -> pull ->
  push satu penjualan -> cek `v_profit_monthly` dan `v_stock_balance`.

**Kriteria**
- [ ] `docker compose config` valid; ketiga container sehat; `docker stats` menunjukkan limit memori terpasang.
- [ ] Restore dari file backup ke database kosong berhasil dan `validate.sql` tetap 23/23.
- [ ] Seluruh langkah uji asap berhasil dan dicatat di `deploy/README.md`.

---

## Catatan Fase 2 (kasir Wails), dibaca saat mulai Fase 2

- `cashier/go.mod` sudah ada. Jalankan `wails init -n cashier -t vue-ts` di folder sementara, pindahkan isinya ke
  `cashier/` **kecuali** `go.mod`, lalu tambahkan `github.com/wailsapp/wails/v2` dan `modernc.org/sqlite` ke `cashier/go.mod`.
  Pastikan `wails build` dari dalam `cashier/` dan `GOWORK=off go build ./...` sama-sama berhasil.
- SQLite dibuka dengan driver `sqlite` (modernc) dan PRAGMA dari CLAUDE.md; pool tulis `SetMaxOpenConns(1)`.
- Tipe sync dan engine FIFO diambil dari `glorypos/shared`, bukan disalin.
