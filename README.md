# Glory POS

Sistem apotek online + offline untuk Apotek Glory Farma (Jember), pengganti program iAbu.

| Folder | Isi | Fase |
| --- | --- | --- |
| `db/` | Skema PostgreSQL, migrasi pertama + impor ulang data iAbu, validasi 23 cek | selesai |
| `shared/` | Kode bersama server dan kasir (kontrak API, uang, FIFO) | 1 |
| `server/` | API Go (chi, pgx, sqlc), CLI, laporan | 1 |
| `cashier/` | Aplikasi kasir Wails + SQLite | 2 |
| `web/` | Dashboard owner Vue 3 | 3 |
| `deploy/` | Docker Compose, Caddy, backup | 1 |
| `docs/` | `API_CONTRACT.md`, `PHASE_1_TASKS.md` | - |

Aturan kerja dan stack ada di `CLAUDE.md`. Mulai dari `docs/PHASE_1_TASKS.md`, Task 1.1.

Monorepo memakai `go.work` (Go 1.24): `shared/`, `server/`, `cashier/` masing-masing punya `go.mod` sendiri.

## Mulai di mesin dev

Butuh Go 1.24+, Docker, dan [sqlc](https://sqlc.dev) (`brew install sqlc`). PostgreSQL lokal tidak diperlukan.

```bash
make test-db     # PostgreSQL 16 di docker (localhost:55432) + database template tes
make check       # gofmt + go vet + sqlc diff + go test (shared, server)
make sqlc        # generate ulang server/internal/store setelah mengubah query atau migrasi

make migrate-legacy LEGACY_DUMP="/path/GLORY 161126.iAbu"   # data iAbu ke DB glory_pos (dev)
make run                                                   # API di :8080 memakai DB glory_pos
curl localhost:8080/api/v1/readyz
```

Tes integrasi memakai `TEST_DATABASE_URL` (diisi otomatis oleh Makefile). Menjalankan `go test` langsung tanpa
variabel itu membuat tes gagal dengan petunjuk, bukan dilewati.
