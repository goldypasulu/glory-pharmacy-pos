package httpapi

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5/middleware"

	"glorypos/server/internal/apperr"
	"glorypos/shared/api"
)

// HandlerFunc adalah handler yang mengembalikan error. Error apa pun dikirim
// lewat Fail, jadi handler cukup `return err` dan tidak menulis respons error sendiri.
type HandlerFunc func(w http.ResponseWriter, r *http.Request) error

func (h HandlerFunc) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if err := h(w, r); err != nil {
		Fail(w, r, err)
	}
}

// statusByCode memetakan kode kontrak ke status HTTP (docs/API_CONTRACT.md bagian 3).
var statusByCode = map[string]int{
	api.CodeBadRequest:       http.StatusBadRequest,
	api.CodeValidationFailed: http.StatusBadRequest,
	api.CodeUnauthenticated:  http.StatusUnauthorized,
	api.CodeTokenExpired:     http.StatusUnauthorized,
	api.CodeForbidden:        http.StatusForbidden,
	api.CodeOutletForbidden:  http.StatusForbidden,
	api.CodeDeviceInactive:   http.StatusForbidden,
	api.CodeNotFound:         http.StatusNotFound,
	api.CodeConflict:         http.StatusConflict,
	api.CodeStaleWrite:       http.StatusConflict,
	api.CodeDuplicateNumber:  http.StatusConflict,
	api.CodePayloadTooLarge:  http.StatusRequestEntityTooLarge,
	api.CodeBusinessRule:     http.StatusUnprocessableEntity,
	api.CodeRateLimited:      http.StatusTooManyRequests,
	api.CodeInternal:         http.StatusInternalServerError,
	api.CodeUnavailable:      http.StatusServiceUnavailable,
}

// Fail adalah satu-satunya jalan handler mengirim error: mengklasifikasi err
// (apperr.Classify), mencatatnya, lalu menulis respons berformat kontrak.
//
// Log: 500 = Error lengkap dengan penyebab; 503 = Warn; 4xx yang punya penyebab
// (mis. JSON rusak, unique violation) = Info; 4xx biasa cukup di log akses (error_code).
func Fail(w http.ResponseWriter, r *http.Request, err error) {
	e := apperr.Classify(err)
	if e == nil {
		return
	}
	ctx := r.Context()
	log := loggerFrom(ctx)

	status, known := statusByCode[e.Code]
	if !known {
		log.ErrorContext(ctx, "kode error tidak dikenal, dikirim sebagai internal", "code", e.Code, "err", err)
		e = &apperr.Error{Code: api.CodeInternal, Message: "Terjadi kesalahan di server", Cause: err}
		status = http.StatusInternalServerError
	}

	switch {
	case status >= 500 && status != http.StatusServiceUnavailable:
		log.ErrorContext(ctx, "permintaan gagal", "code", e.Code, "err", err)
	case status == http.StatusServiceUnavailable:
		log.WarnContext(ctx, "permintaan gagal sementara", "code", e.Code, "err", err)
	case e.Cause != nil:
		log.InfoContext(ctx, "permintaan ditolak", "code", e.Code, "err", err)
	}

	if headerWritten(w) {
		log.ErrorContext(ctx, "error setelah respons mulai terkirim; respons tidak bisa diganti", "code", e.Code)
		return
	}
	writeError(w, r, status, e)
}

// WriteError menulis error kontrak secara langsung (untuk kasus yang tidak lewat Fail).
func WriteError(w http.ResponseWriter, r *http.Request, status int, code, message string, details ...api.ErrorDetail) {
	writeError(w, r, status, apperr.New(code, message, details...))
}

func writeError(w http.ResponseWriter, r *http.Request, status int, e *apperr.Error) {
	if st := stateFrom(r.Context()); st != nil {
		st.errorCode = e.Code
	}
	WriteJSON(w, r, status, api.ErrorResponse{Error: api.Error{
		Code:      e.Code,
		Message:   e.Message,
		Details:   e.Details,
		Retryable: e.Retryable(),
		RequestID: RequestID(r.Context()),
	}})
}

// headerWritten: status sudah terkirim sehingga respons tidak bisa diganti lagi.
func headerWritten(w http.ResponseWriter) bool {
	ww, ok := w.(middleware.WrapResponseWriter)
	return ok && ww.Status() != 0
}

func loggerFrom(ctx context.Context) *slog.Logger {
	if st := stateFrom(ctx); st != nil && st.log != nil {
		return st.log
	}
	return slog.Default()
}

func notFound(w http.ResponseWriter, r *http.Request) {
	WriteError(w, r, http.StatusNotFound, api.CodeNotFound, "Alamat tidak ditemukan")
}

func methodNotAllowed(w http.ResponseWriter, r *http.Request) {
	WriteError(w, r, http.StatusMethodNotAllowed, api.CodeBadRequest, "Method "+r.Method+" tidak didukung di alamat ini")
}
