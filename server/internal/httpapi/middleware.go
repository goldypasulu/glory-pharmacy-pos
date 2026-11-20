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

const (
	requestIDKey ctxKey = iota
	stateKey
)

// RequestIDHeader dikirim di setiap respons agar keluhan pengguna bisa dicocokkan dengan log.
const RequestIDHeader = "X-Request-Id"

// RequestID mengembalikan id permintaan dari konteks, atau "" bila tidak ada.
func RequestID(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey).(string)
	return id
}

// requestState dibagi middleware dan penulis respons selama satu permintaan.
type requestState struct {
	log       *slog.Logger
	errorCode string // kode error kontrak yang dikirim, untuk log akses
}

func stateFrom(ctx context.Context) *requestState {
	st, _ := ctx.Value(stateKey).(*requestState)
	return st
}

// NewLogHandler membungkus h agar setiap log yang memakai konteks permintaan
// (log.InfoContext(ctx, ...)) otomatis membawa request_id. Dipasang sekali di main;
// service tidak perlu menambah request_id sendiri.
func NewLogHandler(h slog.Handler) slog.Handler {
	if _, ok := h.(logHandler); ok {
		return h
	}
	return logHandler{h}
}

type logHandler struct{ slog.Handler }

func (h logHandler) Handle(ctx context.Context, rec slog.Record) error {
	if id := RequestID(ctx); id != "" {
		rec.AddAttrs(slog.String("request_id", id))
	}
	return h.Handler.Handle(ctx, rec)
}

func (h logHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return logHandler{h.Handler.WithAttrs(attrs)}
}

func (h logHandler) WithGroup(name string) slog.Handler {
	return logHandler{h.Handler.WithGroup(name)}
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
// Query string, header, dan badan sengaja tidak dicatat (password, token).
func requestLogger(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			st := &requestState{log: log}
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
			r = r.WithContext(context.WithValue(r.Context(), stateKey, st))
			next.ServeHTTP(ww, r)

			status := ww.Status()
			if status == 0 {
				status = http.StatusOK
			}
			level := slog.LevelInfo
			switch {
			case status >= 500:
				level = slog.LevelError
			case status >= 400:
				level = slog.LevelWarn
			case quietPaths[r.URL.Path]:
				level = slog.LevelDebug
			}
			attrs := []slog.Attr{
				slog.String("method", r.Method),
				slog.String("path", r.URL.Path),
				slog.Int("status", status),
				slog.Int("bytes", ww.BytesWritten()),
				slog.Duration("duration", time.Since(start)),
			}
			if st.errorCode != "" {
				attrs = append(attrs, slog.String("error_code", st.errorCode))
			}
			log.LogAttrs(r.Context(), level, "http", attrs...)
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
				)
				if headerWritten(w) {
					return
				}
				WriteError(w, r, http.StatusInternalServerError, api.CodeInternal, "Terjadi kesalahan di server")
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// timeout membatasi umur konteks permintaan. Query DB dan pekerjaan lain yang
// menghormati konteks akan berhenti saat batas tercapai (Fail mengirim 503).
func timeout(d time.Duration) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ctx, cancel := context.WithTimeout(r.Context(), d)
			defer cancel()
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}
