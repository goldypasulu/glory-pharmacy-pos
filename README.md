# Glory POS

Sistem apotek online + offline untuk Apotek Glory Farma (Jember), pengganti program iAbu.

| Folder | Isi | Fase |
| --- | --- | --- |
| `db/` | Skema PostgreSQL, migrasi data iAbu, validasi 23 cek | selesai |
| `shared/` | Kode bersama server dan kasir (kontrak API, uang, FIFO) | 1 |
| `server/` | API Go (chi, pgx, sqlc), CLI, laporan | 1 |
| `cashier/` | Aplikasi kasir Wails + SQLite | 2 |
| `web/` | Dashboard owner Vue 3 | 3 |
| `deploy/` | Docker Compose, Caddy, backup | 1 |
| `docs/` | `API_CONTRACT.md`, `PHASE_1_TASKS.md` | - |

Aturan kerja dan stack ada di `CLAUDE.md`. Mulai dari `docs/PHASE_1_TASKS.md`, Task 1.1.

Monorepo memakai `go.work` (Go 1.24): `shared/`, `server/`, `cashier/` masing-masing punya `go.mod` sendiri.

```bash
go work sync
go test ./shared/... ./server/... ./cashier/...
```
