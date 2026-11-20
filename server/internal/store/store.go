package store

import (
	"context"
	"fmt"

	pgxdecimal "github.com/jackc/pgx-shopspring-decimal"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// NewPool membuka pool PostgreSQL. Setiap koneksi mendaftarkan tipe numeric
// <-> decimal.Decimal dan memakai zona waktu sesi UTC (tanggal bisnis dihitung
// dengan outlets.timezone, bukan zona waktu sesi).
func NewPool(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse database url: %w", err)
	}
	cfg.ConnConfig.RuntimeParams["timezone"] = "UTC"
	cfg.AfterConnect = func(_ context.Context, conn *pgx.Conn) error {
		pgxdecimal.Register(conn.TypeMap())
		return nil
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("buka pool: %w", err)
	}
	return pool, nil
}

// WithTx menjalankan fn dalam satu transaksi. Commit bila fn mengembalikan nil,
// rollback bila error atau panic.
func WithTx(ctx context.Context, pool *pgxpool.Pool, fn func(*Queries) error) error {
	err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		return fn(New(tx))
	})
	if err != nil {
		return fmt.Errorf("transaksi: %w", err)
	}
	return nil
}
