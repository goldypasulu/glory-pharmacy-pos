// Package httpapi berisi router HTTP, middleware, dan penulis respons sesuai
// docs/API_CONTRACT.md.
package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"glorypos/shared/api"
)

// Pinger memeriksa kesiapan database (*pgxpool.Pool memenuhinya).
type Pinger interface {
	Ping(ctx context.Context) error
}

// Deps adalah dependensi router.
type Deps struct {
	Log            *slog.Logger
	DB             Pinger
	RequestTimeout time.Duration // 0 = 30 detik
}

// NewRouter membangun router chi lengkap dengan middleware standar.
// Endpoint publik /healthz dan /readyz tersedia di root (healthcheck container)
// dan di /api/v1 (kontrak).
func NewRouter(d Deps) *chi.Mux {
	if d.RequestTimeout == 0 {
		d.RequestTimeout = 30 * time.Second
	}
	r := chi.NewRouter()
	r.Use(requestID, requestLogger(d.Log), recoverer(d.Log), timeout(d.RequestTimeout))
	r.NotFound(notFound)
	r.MethodNotAllowed(methodNotAllowed)

	health := func(r chi.Router) {
		r.Get("/healthz", handleHealthz)
		r.Get("/readyz", handleReadyz(d.DB, d.Log))
	}
	health(r)
	r.Route("/api/v1", func(r chi.Router) {
		health(r)
	})
	return r
}

type statusResponse struct {
	Status string `json:"status"`
}

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, http.StatusOK, statusResponse{Status: "ok"})
}

func handleReadyz(db Pinger, log *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if err := db.Ping(ctx); err != nil {
			log.WarnContext(r.Context(), "readyz: database tidak siap", "err", err, "request_id", RequestID(r.Context()))
			WriteError(w, r, http.StatusServiceUnavailable, api.CodeUnavailable, "Database belum siap")
			return
		}
		writeJSON(w, r, http.StatusOK, statusResponse{Status: "ready"})
	}
}
