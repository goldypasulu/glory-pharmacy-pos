package testdb

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"testing"
)

// dbDir mengembalikan path folder db/ di root repo.
func dbDir(t *testing.T) string {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller gagal")
	}
	return filepath.Join(filepath.Dir(file), "..", "..", "..", "db")
}

var (
	createTableRe = regexp.MustCompile(`(?im)^\s*CREATE TABLE (?:IF NOT EXISTS )?([a-z_][a-z0-9_]*)`)
	createViewRe  = regexp.MustCompile(`(?im)^\s*CREATE (?:OR REPLACE )?VIEW ([a-z_][a-z0-9_]*)`)
)

// expectedRelations membaca nama tabel dan view dari schema.sql + db/migrations.
func expectedRelations(t *testing.T) (tables, views []string, versions []string) {
	dir := dbDir(t)
	files := []string{filepath.Join(dir, "schema.sql")}
	migrations, err := filepath.Glob(filepath.Join(dir, "migrations", "*.sql"))
	if err != nil {
		t.Fatal(err)
	}
	files = append(files, migrations...)
	versions = []string{"00001_baseline"}
	for _, m := range migrations {
		versions = append(versions, strings.TrimSuffix(filepath.Base(m), ".sql"))
	}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range createTableRe.FindAllStringSubmatch(string(b), -1) {
			tables = append(tables, m[1])
		}
		for _, m := range createViewRe.FindAllStringSubmatch(string(b), -1) {
			views = append(views, m[1])
		}
	}
	tables = append(tables, "schema_migrations")
	slices.Sort(tables)
	slices.Sort(views)
	return slices.Compact(tables), slices.Compact(views), versions
}

func queryNames(t *testing.T, db *DB, sql string) []string {
	rows, err := db.Pool.Query(context.Background(), sql)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatal(err)
		}
		names = append(names, n)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return names
}

func TestNewHasFullSchema(t *testing.T) {
	t.Parallel()
	db := New(t)
	wantTables, wantViews, wantVersions := expectedRelations(t)
	if len(wantTables) < 30 {
		t.Fatalf("parser schema.sql hanya menemukan %d tabel", len(wantTables))
	}

	gotTables := queryNames(t, db, `SELECT table_name FROM information_schema.tables
		WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY 1`)
	if !slices.Equal(gotTables, wantTables) {
		t.Errorf("tabel berbeda\n got: %v\nwant: %v", gotTables, wantTables)
	}
	gotViews := queryNames(t, db, `SELECT table_name FROM information_schema.views
		WHERE table_schema = 'public' ORDER BY 1`)
	if !slices.Equal(gotViews, wantViews) {
		t.Errorf("view berbeda\n got: %v\nwant: %v", gotViews, wantViews)
	}
	gotVersions := queryNames(t, db, `SELECT version FROM schema_migrations ORDER BY 1`)
	if !slices.Equal(gotVersions, wantVersions) {
		t.Errorf("schema_migrations berbeda\n got: %v\nwant: %v", gotVersions, wantVersions)
	}

	// Trigger sync ikut tersalin: menulis tabel pull mengisi sync_txid.
	var txid string
	err := db.Pool.QueryRow(context.Background(),
		`INSERT INTO units (name) VALUES ('TES') RETURNING sync_txid::text`).Scan(&txid)
	if err != nil {
		t.Fatalf("insert units: %v", err)
	}
	if txid == "" || txid == "0" {
		t.Errorf("sync_txid tidak diisi trigger: %q", txid)
	}
}

func TestNewIsolatedInParallel(t *testing.T) {
	t.Parallel()
	const n = 6
	names := make(chan string, n)
	t.Run("group", func(t *testing.T) {
		for i := range n {
			t.Run(fmt.Sprint(i), func(t *testing.T) {
				t.Parallel()
				db := New(t)
				ctx := context.Background()
				// Bila database dipakai bersama, CREATE TABLE kedua gagal dan count != 1.
				if _, err := db.Pool.Exec(ctx, `CREATE TABLE isolasi (n int)`); err != nil {
					t.Fatalf("create: %v", err)
				}
				if _, err := db.Pool.Exec(ctx, `INSERT INTO isolasi VALUES ($1)`, i); err != nil {
					t.Fatalf("insert: %v", err)
				}
				var count, got int
				if err := db.Pool.QueryRow(ctx, `SELECT count(*), max(n) FROM isolasi`).Scan(&count, &got); err != nil {
					t.Fatal(err)
				}
				if count != 1 || got != i {
					t.Fatalf("data bocor antar tes: count=%d n=%d (harap 1, %d)", count, got, i)
				}
				var current string
				if err := db.Pool.QueryRow(ctx, `SELECT current_database()`).Scan(&current); err != nil {
					t.Fatal(err)
				}
				if current != db.Name {
					t.Fatalf("current_database %q != %q", current, db.Name)
				}
				names <- db.Name
			})
		}
	})
	close(names)
	seen := map[string]bool{}
	for name := range names {
		if seen[name] {
			t.Fatalf("nama database dobel: %s", name)
		}
		seen[name] = true
	}
	if len(seen) != n {
		t.Fatalf("harap %d database, dapat %d", n, len(seen))
	}
}

func TestDatabaseDroppedAfterCleanup(t *testing.T) {
	t.Parallel()
	var name string
	t.Run("pakai", func(t *testing.T) {
		name = New(t).Name
	})
	// Subtes selesai = Cleanup-nya sudah jalan.
	admin := New(t)
	var exists bool
	err := admin.Pool.QueryRow(context.Background(),
		`SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)`, name).Scan(&exists)
	if err != nil {
		t.Fatal(err)
	}
	if exists {
		t.Fatalf("database %s masih ada setelah cleanup", name)
	}
}
