// Package api berisi tipe payload endpoint non-sync (docs/API_CONTRACT.md),
// dipakai bersama server, kasir, dan tes.
package api

// Kode error kontrak (docs/API_CONTRACT.md bagian 3).
const (
	CodeBadRequest       = "bad_request"
	CodeValidationFailed = "validation_failed"
	CodeUnauthenticated  = "unauthenticated"
	CodeTokenExpired     = "token_expired"
	CodeForbidden        = "forbidden"
	CodeOutletForbidden  = "outlet_forbidden"
	CodeDeviceInactive   = "device_inactive"
	CodeNotFound         = "not_found"
	CodeConflict         = "conflict"
	CodeStaleWrite       = "stale_write"
	CodeDuplicateNumber  = "duplicate_number"
	CodePayloadTooLarge  = "payload_too_large"
	CodeBusinessRule     = "business_rule"
	CodeRateLimited      = "rate_limited"
	CodeInternal         = "internal"
	CodeUnavailable      = "unavailable"
)

// ErrorResponse adalah badan JSON setiap respons error: {"error": {...}}.
type ErrorResponse struct {
	Error Error `json:"error"`
}

// Error adalah isi objek "error".
type Error struct {
	Code      string        `json:"code"`
	Message   string        `json:"message"`
	Details   []ErrorDetail `json:"details,omitempty"`
	Retryable bool          `json:"retryable"`
	RequestID string        `json:"request_id"`
}

// ErrorDetail menjelaskan satu masalah per field. Field memakai path gaya
// `lines[0].qty`. Expected/Actual opsional (mis. untuk sum_mismatch).
type ErrorDetail struct {
	Field    string `json:"field,omitempty"`
	Issue    string `json:"issue"`
	Expected string `json:"expected,omitempty"`
	Actual   string `json:"actual,omitempty"`
}
