package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"runtime/debug"
	"time"

	"github.com/go-chi/chi/v5/middleware"
	"github.com/google/uuid"

	"glorypos/shared/api"
)

type ctxKey int

const requestIDKey ctxKey = iota

// RequestIDHeader dikirim di setiap respons agar keluhan pengguna bisa dicocokkan dengan log.
const RequestIDHeader = "X-Request-Id"

// RequestID mengembalikan id permintaan dari konteks, atau "" bila tidak ada.
func RequestID(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey).(string)
	return id
}

// requestID memberi setiap permintaan UUIDv7 baru. Header dari klien tidak
// dipercaya agar id di log selalu unik dan berformat sama.
func requestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := uuid.Must(uuid.NewV7()).String()
		w.Header().Set(RequestIDHeader, id)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), requestIDKey, id)))
	})
}

// quietPaths dicatat di level debug karena dipanggil terus oleh healthcheck.
var quietPaths = map[string]bool{
	"/healthz": true, "/readyz": true,
	"/api/v1/healthz": true, "/api/v1/readyz": true,
}

// requestLogger mencatat satu baris slog per permintaan setelah selesai.
func requestLogger(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
			next.ServeHTTP(ww, r)

			status := ww.Status()
			if status == 0 {
				status = http.StatusOK
			}
			level := slog.LevelInfo
			switch {
			case status >= 500:
				level = slog.LevelError
			case quietPaths[r.URL.Path]:
				level = slog.LevelDebug
			}
			log.LogAttrs(r.Context(), level, "http",
				slog.String("method", r.Method),
				slog.String("path", r.URL.Path),
				slog.Int("status", status),
				slog.Int("bytes", ww.BytesWritten()),
				slog.Duration("duration", time.Since(start)),
				slog.String("request_id", RequestID(r.Context())),
			)
		})
	}
}

// recoverer mengubah panic di handler menjadi 500 `internal` berformat kontrak
// sehingga server tetap hidup. http.ErrAbortHandler diteruskan (koneksi sengaja diputus).
func recoverer(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				rec := recover()
				if rec == nil {
					return
				}
				if rec == http.ErrAbortHandler {
					panic(rec)
				}
				log.ErrorContext(r.Context(), "panic di handler",
					"panic", rec,
					"stack", string(debug.Stack()),
					"method", r.Method,
					"path", r.URL.Path,
					"request_id", RequestID(r.Context()),
				)
				// Bila header sudah terkirim, respons tidak bisa diganti lagi.
				if ww, ok := w.(middleware.WrapResponseWriter); ok && ww.Status() != 0 {
					return
				}
				WriteError(w, r, http.StatusInternalServerError, api.CodeInternal, "Terjadi kesalahan di server")
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// timeout membatasi umur konteks permintaan. Query DB dan pekerjaan lain yang
// menghormati konteks akan berhenti saat batas tercapai.
func timeout(d time.Duration) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ctx, cancel := context.WithTimeout(r.Context(), d)
			defer cancel()
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}
