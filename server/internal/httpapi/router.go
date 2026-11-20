// Package httpapi berisi router HTTP, middleware, dan penulis respons sesuai
// docs/API_CONTRACT.md.
package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"glorypos/server/internal/apperr"
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
	// Pastikan setiap log berkonteks permintaan membawa request_id.
	d.Log = slog.New(NewLogHandler(d.Log.Handler()))
	r := chi.NewRouter()
	r.Use(requestID, requestLogger(d.Log), recoverer(d.Log), timeout(d.RequestTimeout))
	r.NotFound(notFound)
	r.MethodNotAllowed(methodNotAllowed)

	health := func(r chi.Router) {
		r.Get("/healthz", handleHealthz)
		r.Method(http.MethodGet, "/readyz", handleReadyz(d.DB))
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
	WriteJSON(w, r, http.StatusOK, statusResponse{Status: "ok"})
}

func handleReadyz(db Pinger) HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) error {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if err := db.Ping(ctx); err != nil {
			// Selalu unavailable (bukan internal) apa pun penyebabnya; Fail mencatatnya di level Warn.
			return &apperr.Error{Code: api.CodeUnavailable, Message: "Database belum siap", Cause: err}
		}
		WriteJSON(w, r, http.StatusOK, statusResponse{Status: "ready"})
		return nil
	}
}
