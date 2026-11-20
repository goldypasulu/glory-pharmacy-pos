// Package testdb membuat database PostgreSQL sekali pakai untuk tes integrasi.
//
// Setiap pemanggilan New membuat database baru dari template glorypos_template
// (schema.sql + db/migrations, disiapkan oleh `make test-db`) dan menghapusnya
// saat tes selesai, sehingga tes paralel tidak saling melihat data.
package testdb

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"glorypos/server/internal/store"
)

// Template adalah nama database template yang dibuat `make test-db`.
const Template = "glorypos_template"

// EnvURL menunjuk server PostgreSQL tes (database apa pun selain template).
const EnvURL = "TEST_DATABASE_URL"

const hint = "jalankan `make test-db`, lalu export " + EnvURL +
	"=postgres://postgres:postgres@localhost:55432/postgres?sslmode=disable (Makefile mengisinya otomatis untuk `make test`)"

// DB adalah database tes yang sudah siap pakai.
type DB struct {
	Name string
	URL  string
	Pool *pgxpool.Pool
}

// New membuat database baru dari template dan mendaftarkan penghapusannya di t.Cleanup.
// Tes gagal (bukan skip) bila TEST_DATABASE_URL kosong.
func New(t testing.TB) *DB {
	t.Helper()
	baseURL := os.Getenv(EnvURL)
	if baseURL == "" {
		t.Fatalf("testdb: %s kosong; tes integrasi butuh PostgreSQL nyata: %s", EnvURL, hint)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	name := "glorypos_test_" + randomSuffix(t)
	admin, err := pgx.Connect(ctx, baseURL)
	if err != nil {
		t.Fatalf("testdb: koneksi ke %s gagal: %v; %s", EnvURL, err, hint)
	}
	defer admin.Close(context.Background())

	if err := createFromTemplate(ctx, admin, name); err != nil {
		t.Fatalf("testdb: %v", err)
	}
	t.Cleanup(func() { drop(t, baseURL, name) })

	dbURL, err := withDatabase(baseURL, name)
	if err != nil {
		t.Fatalf("testdb: %v", err)
	}
	pool, err := store.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("testdb: %v", err)
	}
	// Didaftarkan setelah drop agar dijalankan lebih dulu (Cleanup = LIFO).
	t.Cleanup(pool.Close)
	return &DB{Name: name, URL: dbURL, Pool: pool}
}

// createFromTemplate mengulang bila template sedang dipakai sesi lain (55006),
// mis. sesaat setelah `make test-db` atau saat banyak tes membuat database bersamaan.
func createFromTemplate(ctx context.Context, admin *pgx.Conn, name string) error {
	sql := fmt.Sprintf("CREATE DATABASE %s TEMPLATE %s",
		pgx.Identifier{name}.Sanitize(), pgx.Identifier{Template}.Sanitize())
	for attempt := 0; ; attempt++ {
		_, err := admin.Exec(ctx, sql)
		if err == nil {
			return nil
		}
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) {
			switch pgErr.Code {
			case "3D000": // template tidak ada
				return fmt.Errorf("database template %s belum ada: %s", Template, hint)
			case "55006": // template sedang diakses
				if attempt < 50 {
					select {
					case <-time.After(100 * time.Millisecond):
						continue
					case <-ctx.Done():
					}
				}
			}
		}
		return fmt.Errorf("create database %s: %w", name, err)
	}
}

func drop(t testing.TB, baseURL, name string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin, err := pgx.Connect(ctx, baseURL)
	if err != nil {
		t.Errorf("testdb: hapus %s: koneksi gagal: %v", name, err)
		return
	}
	defer admin.Close(context.Background())
	if _, err := admin.Exec(ctx, "DROP DATABASE IF EXISTS "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)"); err != nil {
		t.Errorf("testdb: hapus %s: %v", name, err)
	}
}

// withDatabase mengganti nama database di URL koneksi.
func withDatabase(baseURL, name string) (string, error) {
	u, err := url.Parse(baseURL)
	if err != nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") {
		return "", fmt.Errorf("%s harus berbentuk URL postgres://...: %q", EnvURL, baseURL)
	}
	u.Path = "/" + name
	return u.String(), nil
}

func randomSuffix(t testing.TB) string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		t.Fatalf("testdb: acak nama database: %v", err)
	}
	return hex.EncodeToString(b)
}
