package httpapi

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"glorypos/shared/api"
)

// retryableCodes: klien boleh mengulang permintaan yang sama apa adanya.
var retryableCodes = map[string]bool{
	api.CodeInternal:    true,
	api.CodeUnavailable: true,
	api.CodeRateLimited: true,
}

// WriteError menulis respons error berformat kontrak (docs/API_CONTRACT.md bagian 3)
// lengkap dengan request_id dari konteks permintaan.
func WriteError(w http.ResponseWriter, r *http.Request, status int, code, message string, details ...api.ErrorDetail) {
	writeJSON(w, r, status, api.ErrorResponse{Error: api.Error{
		Code:      code,
		Message:   message,
		Details:   details,
		Retryable: retryableCodes[code],
		RequestID: RequestID(r.Context()),
	}})
}

// writeJSON menulis v sebagai JSON. Kegagalan encode hanya dicatat karena
// header sudah terkirim.
func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.ErrorContext(r.Context(), "tulis respons JSON gagal", "err", err, "request_id", RequestID(r.Context()))
	}
}

func notFound(w http.ResponseWriter, r *http.Request) {
	WriteError(w, r, http.StatusNotFound, api.CodeNotFound, "Alamat tidak ditemukan")
}

func methodNotAllowed(w http.ResponseWriter, r *http.Request) {
	WriteError(w, r, http.StatusMethodNotAllowed, api.CodeBadRequest, "Method "+r.Method+" tidak didukung di alamat ini")
}
