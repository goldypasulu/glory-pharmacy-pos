package apperr

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"glorypos/shared/api"
)

func TestClassify(t *testing.T) {
	appErr := BusinessRule("sale_already_void", "Nota sudah dibatalkan")
	pg := func(code string) error {
		return fmt.Errorf("posting: %w", &pgconn.PgError{Code: code, Message: "detail internal"})
	}

	tests := []struct {
		name      string
		err       error
		code      string
		retryable bool
	}{
		{"app error langsung", appErr, api.CodeBusinessRule, false},
		{"app error terbungkus", fmt.Errorf("service: %w", appErr), api.CodeBusinessRule, false},
		{"deadline", fmt.Errorf("query: %w", context.DeadlineExceeded), api.CodeUnavailable, true},
		{"canceled", context.Canceled, api.CodeUnavailable, true},
		{"deadlock", pg("40P01"), api.CodeUnavailable, true},
		{"serialization", pg("40001"), api.CodeUnavailable, true},
		{"statement timeout", pg("57014"), api.CodeUnavailable, true},
		{"unique", pg("23505"), api.CodeConflict, false},
		{"check violation = bug", pg("23514"), api.CodeInternal, true},
		{"koneksi gagal", &pgconn.ConnectError{}, api.CodeUnavailable, true},
		{"error biasa", errors.New("nil pointer di service"), api.CodeInternal, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Classify(tt.err)
			if got.Code != tt.code || got.Retryable() != tt.retryable {
				t.Fatalf("Classify = %s retryable=%v, harap %s retryable=%v", got.Code, got.Retryable(), tt.code, tt.retryable)
			}
			if got.Message == "" {
				t.Fatal("pesan kosong")
			}
			// Error asli tetap bisa ditelusuri untuk log.
			if !errors.Is(got, tt.err) && got != appErr {
				t.Fatalf("cause hilang: %v", got)
			}
		})
	}
}

func TestClassifyHidesInternalMessage(t *testing.T) {
	got := Classify(&pgconn.PgError{Code: "23514", Message: `violates check constraint "stock_batches_qty_remaining_check"`})
	if got.Message != "Terjadi kesalahan di server" {
		t.Fatalf("pesan internal bocor ke klien: %q", got.Message)
	}
	if Classify(nil) != nil {
		t.Fatal("Classify(nil) harus nil")
	}
}
