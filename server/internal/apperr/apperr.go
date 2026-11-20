// Package apperr adalah error aplikasi berkode kontrak (docs/API_CONTRACT.md bagian 3).
//
// Service mengembalikan *Error untuk kegagalan yang memang untuk klien (validasi,
// aturan bisnis, tidak ditemukan, ...). Error lain (bug, database) dibiarkan apa
// adanya; Classify mengubahnya menjadi kode kontrak. Paket ini tidak tahu HTTP,
// sehingga sync push (per record) memakai kode yang sama dengan endpoint web.
package apperr

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5/pgconn"

	"glorypos/shared/api"
)

// Error adalah error yang aman ditampilkan ke klien. Cause hanya untuk log.
type Error struct {
	Code    string
	Message string
	Details []api.ErrorDetail
	Cause   error
}

func (e *Error) Error() string {
	if e.Cause != nil {
		return fmt.Sprintf("%s: %s: %v", e.Code, e.Message, e.Cause)
	}
	return e.Code + ": " + e.Message
}

func (e *Error) Unwrap() error { return e.Cause }

// Retryable: klien boleh mengirim ulang permintaan yang sama apa adanya.
func (e *Error) Retryable() bool {
	switch e.Code {
	case api.CodeInternal, api.CodeUnavailable, api.CodeRateLimited:
		return true
	}
	return false
}

// New membuat error berkode kontrak.
func New(code, message string, details ...api.ErrorDetail) *Error {
	return &Error{Code: code, Message: message, Details: details}
}

// Validation: 400 validation_failed dengan detail per field (path gaya `lines[0].qty`).
func Validation(message string, details ...api.ErrorDetail) *Error {
	return New(api.CodeValidationFailed, message, details...)
}

// BusinessRule: 422 business_rule; issue (mis. "sale_already_void") ada di details[0].issue.
func BusinessRule(issue, message string) *Error {
	return New(api.CodeBusinessRule, message, api.ErrorDetail{Issue: issue})
}

// Kode SQLSTATE PostgreSQL yang dipetakan.
const (
	pgUniqueViolation      = "23505"
	pgSerializationFailure = "40001"
	pgDeadlockDetected     = "40P01"
	pgQueryCanceled        = "57014"
	pgAdminShutdown        = "57P01"
	pgCannotConnectNow     = "57P03"
)

// Classify mengubah error apa pun menjadi *Error berkode kontrak.
//   - *Error di rantai error: dipakai apa adanya.
//   - batas waktu / konflik konkurensi / database tidak tersedia: unavailable (retryable).
//   - unique violation yang tidak ditangani service: conflict.
//   - selain itu: internal. Pesan aslinya tidak pernah dikirim ke klien (ada di Cause untuk log).
func Classify(err error) *Error {
	if err == nil {
		return nil
	}
	var appErr *Error
	if errors.As(err, &appErr) {
		return appErr
	}
	unavailable := func(msg string) *Error { return &Error{Code: api.CodeUnavailable, Message: msg, Cause: err} }

	if errors.Is(err, context.DeadlineExceeded) {
		return unavailable("Permintaan melebihi batas waktu, coba lagi")
	}
	if errors.Is(err, context.Canceled) {
		return unavailable("Permintaan dibatalkan")
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		switch pgErr.Code {
		case pgSerializationFailure, pgDeadlockDetected:
			return unavailable("Data sedang diubah bersamaan, coba lagi")
		case pgQueryCanceled, pgAdminShutdown, pgCannotConnectNow:
			return unavailable("Database sedang tidak tersedia, coba lagi")
		case pgUniqueViolation:
			return &Error{Code: api.CodeConflict, Message: "Data bentrok dengan data yang sudah ada",
				Details: []api.ErrorDetail{{Issue: "already_exists"}}, Cause: err}
		}
	}
	var connErr *pgconn.ConnectError
	if errors.As(err, &connErr) {
		return unavailable("Database sedang tidak tersedia, coba lagi")
	}
	return &Error{Code: api.CodeInternal, Message: "Terjadi kesalahan di server", Cause: err}
}
