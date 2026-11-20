package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"

	"glorypos/server/internal/apperr"
	"glorypos/shared/api"
)

// DefaultBodyLimit adalah batas badan permintaan biasa. Sync push memakai
// DecodeJSONLimit dengan batas kontrak (2 MB).
const DefaultBodyLimit = 1 << 20

// WriteJSON menulis v sebagai JSON. Kegagalan encode hanya dicatat karena
// header sudah terkirim.
func WriteJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		loggerFrom(r.Context()).ErrorContext(r.Context(), "tulis respons JSON gagal", "err", err)
	}
}

// DecodeJSON membaca badan JSON ke dst dengan batas DefaultBodyLimit.
func DecodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	return DecodeJSONLimit(w, r, dst, DefaultBodyLimit)
}

// DecodeJSONLimit membaca tepat satu nilai JSON ke dst. Error yang dikembalikan
// sudah berkode kontrak (bad_request, validation_failed, payload_too_large),
// handler cukup mengembalikannya.
//
// Field yang tidak dikenal diabaikan, bukan ditolak: kontrak mewajibkan server
// mengabaikan kolom hitungan server (cogs, rev, ...) yang ikut dikirim klien.
func DecodeJSONLimit(w http.ResponseWriter, r *http.Request, dst any, limit int64) error {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, limit))
	if err := dec.Decode(dst); err != nil {
		return decodeError(err, limit)
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err != nil {
			return decodeError(err, limit)
		}
		return apperr.New(api.CodeBadRequest, "Badan permintaan berisi lebih dari satu nilai JSON")
	}
	return nil
}

func decodeError(err error, limit int64) error {
	var (
		syntaxErr *json.SyntaxError
		typeErr   *json.UnmarshalTypeError
		sizeErr   *http.MaxBytesError
	)
	switch {
	case errors.Is(err, io.EOF):
		return apperr.New(api.CodeBadRequest, "Badan permintaan kosong")
	case errors.As(err, &sizeErr):
		return apperr.New(api.CodePayloadTooLarge, fmt.Sprintf("Badan permintaan melebihi %d byte", limit))
	case errors.As(err, &syntaxErr):
		e := apperr.New(api.CodeBadRequest, fmt.Sprintf("JSON tidak valid di posisi %d", syntaxErr.Offset))
		e.Cause = err
		return e
	case errors.Is(err, io.ErrUnexpectedEOF):
		e := apperr.New(api.CodeBadRequest, "JSON terpotong")
		e.Cause = err
		return e
	case errors.As(err, &typeErr):
		field := typeErr.Field
		if field == "" {
			field = "(root)"
		}
		e := apperr.Validation("Tipe nilai tidak sesuai", api.ErrorDetail{Field: field, Issue: "invalid_type"})
		e.Cause = err
		return e
	default:
		// mis. decimal atau UUID yang formatnya salah (error dari UnmarshalJSON tipe itu).
		e := apperr.Validation("Isi JSON tidak valid", api.ErrorDetail{Issue: "invalid_value"})
		e.Cause = err
		return e
	}
}
