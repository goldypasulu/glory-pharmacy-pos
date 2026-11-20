package store_test

import (
	"context"
	"errors"
	"testing"

	"github.com/shopspring/decimal"

	"glorypos/server/internal/store"
	"glorypos/server/internal/testdb"
)

func TestNumericDecodesToDecimal(t *testing.T) {
	t.Parallel()
	db := testdb.New(t)
	var d decimal.Decimal
	// Nilai yang tidak bisa diwakili float64 secara tepat harus utuh.
	err := db.Pool.QueryRow(context.Background(), `SELECT '12345678901234.0001'::numeric(18,4)`).Scan(&d)
	if err != nil {
		t.Fatalf("scan numeric -> decimal: %v", err)
	}
	if d.String() != "12345678901234.0001" {
		t.Fatalf("decimal salah: %s", d)
	}
}

func TestWithTx(t *testing.T) {
	t.Parallel()
	db := testdb.New(t)
	ctx := context.Background()
	count := func() int {
		var n int
		if err := db.Pool.QueryRow(ctx, `SELECT count(*) FROM units WHERE name LIKE 'TX-%'`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	// Commit: watermark bisa dibaca lewat Queries di dalam transaksi.
	err := store.WithTx(ctx, db.Pool, func(q *store.Queries) error {
		if _, err := q.SyncWatermark(ctx); err != nil {
			return err
		}
		_, err := db.Pool.Exec(ctx, `SELECT 1`) // pool tetap bisa dipakai di luar tx
		return err
	})
	if err != nil {
		t.Fatalf("WithTx: %v", err)
	}

	// Rollback saat fn mengembalikan error; error asli tetap bisa dikenali.
	sentinel := errors.New("batal")
	err = store.WithTx(ctx, db.Pool, func(q *store.Queries) error {
		if _, err := db.Pool.Exec(ctx, `SELECT 1`); err != nil {
			return err
		}
		return insertUnit(ctx, q, "TX-ROLLBACK", sentinel)
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("harap error sentinel, dapat %v", err)
	}
	if n := count(); n != 0 {
		t.Fatalf("rollback gagal: %d baris tersisa", n)
	}

	// Rollback saat panic, lalu panic diteruskan.
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("panic harus diteruskan")
			}
		}()
		_ = store.WithTx(ctx, db.Pool, func(q *store.Queries) error {
			_ = insertUnit(ctx, q, "TX-PANIC", nil)
			panic("sengaja")
		})
	}()
	if n := count(); n != 0 {
		t.Fatalf("rollback saat panic gagal: %d baris tersisa", n)
	}

	// Commit sungguhan.
	if err := store.WithTx(ctx, db.Pool, func(q *store.Queries) error {
		return insertUnit(ctx, q, "TX-COMMIT", nil)
	}); err != nil {
		t.Fatal(err)
	}
	if n := count(); n != 1 {
		t.Fatalf("commit: harap 1 baris, dapat %d", n)
	}
}

// insertUnit menulis lewat koneksi transaksi milik Queries (belum ada query
// sqlc untuk units di Task 1.1), lalu mengembalikan ret.
func insertUnit(ctx context.Context, q *store.Queries, name string, ret error) error {
	if _, err := store.QueriesDB(q).Exec(ctx, `INSERT INTO units (name) VALUES ($1)`, name); err != nil {
		return err
	}
	return ret
}
