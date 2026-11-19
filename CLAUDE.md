# CLAUDE.md - Glory POS

Sistem apotek online + offline untuk Apotek Glory Farma (Jember), pengganti program iAbu.
Server pusat (Go + PostgreSQL) + dashboard owner (Vue) + aplikasi kasir desktop (Wails + SQLite)
yang tetap bisa berjualan saat internet putus lalu sync otomatis. Siap multi-cabang.

Baca file ini sebelum menulis kode. Detail lain ada di file berikut; buka hanya bila task membutuhkannya:
- `db/schema.sql` - skema baseline (sumber kebenaran tabel, kolom, view). Jangan menebak nama kolom.
- `db/README.md` - pemetaan tabel iAbu -> Glory POS dan aturan migrasi.
- `docs/API_CONTRACT.md` - endpoint dan bentuk JSON. Semua nama field mengikuti file ini.
- `docs/PHASE_1_TASKS.md` - daftar task + kriteria selesai.

## Struktur repo (monorepo, go.work)

```
go.work            use ./shared ./server ./cashier
db/                schema.sql (baseline), migrate.sh (migrasi pertama), reimport.sh (impor ulang iAbu masa uji),
                   legacy/*.sql (logika migrasi bersama), validate.sql, migrations/ (perubahan skema berikutnya)
shared/            module glorypos/shared  - kode tanpa I/O: tipe kontrak API, uang/qty, engine FIFO, format nomor nota
server/            module glorypos/server  - API chi + pgx + sqlc, CLI, laporan PDF/XLSX, menyajikan web/dist
cashier/           module glorypos/cashier - Wails v2 + SQLite (Fase 2)
web/               Vue 3 + Vite + Tailwind, dashboard owner (Fase 3)
deploy/            Dockerfile, docker-compose.yml, Caddyfile
docs/              kontrak API, checklist task
```

- `shared` tidak boleh mengimpor `server` atau `cashier`, dan tidak boleh menyentuh database, HTTP, atau file.
- `server` dan `cashier` punya `replace glorypos/shared => ../shared` agar build tetap jalan dengan `GOWORK=off`
  (Dockerfile, Wails CLI). Jangan hapus baris replace itu.
- `go:embed` tidak bisa membaca di luar folder modul. Build dashboard menyalin `web/dist` ke
  `server/internal/webui/dist` lewat Makefile sebelum `go build`.
- Nama modul `glorypos/...` sengaja tanpa domain. Bila repo dipublikasi, ganti serentak di go.mod, go.work, dan import.

## Stack yang dikunci

Jangan menambah atau mengganti dependensi di luar daftar ini tanpa bertanya dulu.

| Kebutuhan | Pilihan |
| --- | --- |
| Go | 1.24 (`go` directive di semua go.mod) |
| Router | `github.com/go-chi/chi/v5` (+ `chi/middleware`) |
| PostgreSQL | 16 di produksi; minimal 15 (skema memakai `NULLS NOT DISTINCT`) |
| Driver + pool | `github.com/jackc/pgx/v5`, `pgxpool` |
| Query | `sqlc` (engine postgresql, `sql_package: pgx/v5`), query di `server/internal/store/queries/*.sql` |
| Desimal | `github.com/shopspring/decimal` + `github.com/jackc/pgx-shopspring-decimal` (override sqlc `numeric`) |
| UUID | `github.com/google/uuid`, selalu `uuid.NewV7()` untuk id baru |
| Password/PIN | `golang.org/x/crypto/bcrypt` (cost 12) |
| Token | `github.com/golang-jwt/jwt/v5` (access token); refresh token = string acak, disimpan sebagai hash |
| Log | `log/slog` (JSON di produksi) |
| Excel / PDF | `github.com/xuri/excelize/v2` (pakai `StreamWriter` untuk laporan besar), `github.com/johnfercher/maroto/v2` |
| Migrasi skema | file SQL berurutan di `db/migrations/` + runner psql di `deploy/` (tanpa tool tambahan) |
| Kasir | Wails v2, SQLite `modernc.org/sqlite` (tanpa CGO) |
| Web | Vue 3 + Vite + TypeScript + Tailwind |

## Aturan data (wajib)

1. **Uang dan qty tidak pernah `float64`.** Pakai `decimal.Decimal` di Go, `numeric` di DB, dan string di JSON
   (`"12500.00"`, `"1.000"`). Uang dibulatkan 2 desimal half-up per baris; `unit_cost` 4 desimal; qty 3 desimal.
2. **Waktu:** DB `timestamptz`, Go `time.Time` dalam UTC, JSON RFC 3339 dengan offset. "Tanggal bisnis"
   (hari ini, bulan laporan, YYMM nomor nota) dihitung dengan `outlets.timezone`, bukan zona waktu server.
3. **ID** dibuat oleh pembuat data (kasir atau server) dengan UUIDv7. Server tidak mengganti id dari kasir.
4. **Kuantitas stok selalu satuan dasar** (`qty_base`). Baris transaksi menyimpan `qty`, `unit_id`,
   `conversion`, dan `qty_base = qty * conversion`.
5. **Soft delete** (`deleted_at`) hanya untuk data master. Transaksi yang sudah diposting tidak diedit dan tidak
   dihapus: koreksi lewat void (status `void` + mutasi balik + `audit_logs`) atau dokumen retur.
6. **Nomor nota** `{OUTLET}-{DEVICE}-{YYMM}-{urut 5 digit}`, mis. `UTM-K1-2611-00042`; urutan per perangkat per
   bulan, dibuat di perangkat. Nomor tidak pernah dipakai ulang (unique penuh, termasuk dokumen void).
7. **Skema:** `db/schema.sql` adalah baseline dan tidak diedit lagi. Perubahan skema = file baru
   `db/migrations/NNNNN_deskripsi.sql` (mulai 00002), SQL murni, satu transaksi. `sqlc.yaml` membaca
   baseline + folder migrations. Jangan menyentuh `db/migrate.sql`, `db/reimport.sql`, atau `db/legacy/*.sql`
   kecuali task-nya tentang migrasi iAbu. Migrasi skema yang mengubah tabel yang diisi `db/legacy/*.sql`
   (mis. kolom NOT NULL baru) wajib ikut menyesuaikan file itu, lalu `make migrate-legacy` dan
   `make reimport-legacy` keduanya tetap lolos 23/23 cek.
8. **Data apotek tidak masuk repo.** Jangan commit file `.iAbu`, hasil `pg_dump`, atau CSV data nyata.
   Tes memakai fixture sintetis.

## Aturan stok dan HPP (wajib)

- **FIFO** per `(outlet_id, item_id)`, urut `received_at`, lalu `id`. HPP baris jual = jumlah `qty x unit_cost`
  dari batch yang terambil. Jangan ganti ke FEFO tanpa keputusan owner.
- **Engine FIFO** murni ada di `shared/inventory`; server membungkusnya dengan transaksi DB.
- **Penguncian:** saat posting, kunci batch dengan `SELECT ... FOR UPDATE` dan selalu urutkan berdasarkan
  `item_id` sebelum mengunci, agar dua nota dengan banyak barang tidak deadlock.
- **Batch tidak pernah minus** (`CHECK qty_remaining >= 0`). Qty yang tidak tertutup batch = **defisit**: mutasi keluar
  dengan `batch_id NULL`, `unit_cost = items.last_cost` (bukan 0), dan `sale_lines.cogs_provisional = true`.
  Penjualan offline tidak pernah ditolak karena stok kurang.
- **Pelunasan defisit:** saat batch baru masuk (pembelian, opname plus, transfer masuk), alokasikan defisit tertua
  dulu ke batch itu. Isi `batch_id`, perbarui `unit_cost`, `sale_lines.cogs`, `sales.cogs_total`, dan matikan
  `cogs_provisional` bila barisnya sudah tertutup penuh.
- **Retur atas baris yang masih defisit:** kurangi `qty_base` mutasi defisitnya (soft delete bila nol). Jangan membuat
  `sale_return` tanpa batch karena tidak terbaca `v_stock_balance`.
- **Racikan** (`items.kind = 'compound'`): tidak punya batch; FIFO dijalankan pada tiap `item_components.component_id`
  sebanyak `qty_base x komposisi`, HPP baris = jumlah HPP bahan.
- `stock_batches.qty_remaining` hanya diubah oleh engine stok, dan selalu sama dengan jumlah mutasinya.

## Aturan sync (wajib)

- **Pull** hanya untuk 15 tabel di blok `pull_tables` pada `db/schema.sql`. `devices` tidak ikut pull.
- **Cursor pull = watermark `xid8`**, bukan `max(rev)`. Halaman pertama mengambil `wm := sync_watermark()` dan
  mengirimnya ke klien; setiap halaman memakai `sync_txid >= cursor AND sync_txid < wm` dengan keyset
  `(sync_txid, rev)`; setelah halaman terakhir cursor klien = `wm`. Di SQL, `xid8` selalu di-cast ke `text`; di JSON
  berupa string desimal (bisa melebihi 2^53).
- `users` ditarik lewat `v_sync_users`. `password_hash` dan `devices.token_hash` tidak pernah keluar dari server.
- `stock_batches` dan `users` ditarik hanya untuk outlet perangkat (filter `outlet_id` / `user_outlets`).
- **Push idempotent:** `sync_batches.id` (batch) dan id record. Batch yang sama dikirim ulang = respons yang sama;
  record yang sudah ada = `duplicate`, bukan error.

## Keamanan dan peran

Peran: `owner`, `admin`, `supervisor`, `pharmacist`, `cashier`. Cek peran di middleware, cek outlet di service.
Password lama iAbu tidak dimigrasi; login pertama memakai `glorypos user:set-password --username <u>`.
Aksi sensitif (void, ubah harga, finalisasi opname, reset password) wajib menulis `audit_logs`.

## Cara kerja

- **Satu sesi = satu task** dari `docs/PHASE_1_TASKS.md`. Baca task itu, kerjakan hanya lingkupnya, centang kriterianya.
- **Logika sensitif ditulis tes dulu** (FIFO, defisit, retur, racikan, watermark, idempotensi), baru implementasinya.
- Tes integrasi memakai PostgreSQL nyata (`TEST_DATABASE_URL`, disiapkan `make test-db`); tiap tes membuat database
  dari template berisi `schema.sql` + migrations. Jangan mock database untuk logika stok atau sync.
- Error dibungkus `fmt.Errorf("...: %w", err)`; handler tidak boleh panic; respons error mengikuti `docs/API_CONTRACT.md`.
- Komentar kode dan pesan commit boleh bahasa Indonesia. Pesan commit: `task 1.3: engine FIFO dan defisit`.

## Verifikasi (tersedia setelah Task 1.1)

Jangan anggap task selesai sebelum semua perintah yang relevan lulus tanpa error:

```bash
make check        # = gofmt -l (harus kosong) + go vet + sqlc diff + go test -count=1 untuk shared dan server
make test-db      # menyalakan PostgreSQL tes di docker (port 55432) dan menyiapkan database template
make migrate-legacy LEGACY_DUMP=/path/backup.iAbu   # opsional: migrasi iAbu pertama + validasi 23 cek
make reimport-legacy LEGACY_DUMP=/path/backup.iAbu  # opsional: impor ulang ke DB yang sudah ada + validasi
cd cashier && wails build -platform windows/amd64    # mulai Fase 2
cd web && npm ci && npm run build                    # mulai Fase 3
```

Bila sebuah perintah gagal karena hal di luar task (mis. tool belum terpasang), laporkan, jangan diakali.
