# db/migrations

Perubahan skema setelah baseline `db/schema.sql` (yang tidak diedit lagi).

- Nama file: `NNNNN_deskripsi.sql`, mulai `00002`, huruf kecil/angka/garis bawah. Contoh: `00002_auth_refresh_tokens.sql`.
- Isi: SQL murni **tanpa** `BEGIN`/`COMMIT`. `db/apply-migrations.sh` menjalankan setiap file beserta pencatatan
  versinya di `schema_migrations` dalam satu transaksi; gagal = tidak ada yang berubah, dan versi tidak tercatat.
- File yang sudah di-commit tidak diubah lagi; koreksi = file migrasi baru.
- Tidak boleh memakai perintah yang tidak bisa jalan di dalam transaksi (mis. `CREATE INDEX CONCURRENTLY`).
- `server/sqlc.yaml` membaca folder ini setelah `schema.sql`; jalankan `make sqlc` setelah menambah migrasi,
  lalu `make test-db` agar template tes ikut diperbarui.
