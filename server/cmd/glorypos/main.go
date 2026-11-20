// Command glorypos adalah server Glory POS: API HTTP dan perintah admin.
//
//	glorypos serve      menjalankan API HTTP
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"glorypos/server/internal/config"
	"glorypos/server/internal/httpapi"
	"glorypos/server/internal/store"
)

const usage = `Pemakaian: glorypos <perintah> [opsi]

Perintah:
  serve    menjalankan API HTTP

Konfigurasi lewat environment:
  GLORYPOS_DATABASE_URL  (wajib) mis. postgres://user:pass@host:5432/glory_pos
  GLORYPOS_JWT_SECRET    (wajib)
  GLORYPOS_HTTP_ADDR     default :8080
  GLORYPOS_ENV           dev | prod (default dev; prod = log JSON)
  GLORYPOS_LOG_LEVEL     debug | info | warn | error (default info)
`

func main() {
	os.Exit(run(os.Args[1:], os.Stderr))
}

func run(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	switch args[0] {
	case "serve":
		return serve(args[1:], stderr)
	case "help", "-h", "-help", "--help":
		fmt.Fprint(stderr, usage)
		return 0
	default:
		fmt.Fprintf(stderr, "perintah tidak dikenal: %q\n\n%s", args[0], usage)
		return 2
	}
}

func serve(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() { fmt.Fprint(stderr, "Pemakaian: glorypos serve\n\n"+usage) }
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}

	cfg, err := config.Load(os.Getenv)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	log := newLogger(cfg, stderr)
	slog.SetDefault(log)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := runServer(ctx, cfg, log); err != nil {
		log.Error("server berhenti dengan error", "err", err)
		return 1
	}
	return 0
}

func newLogger(cfg config.Config, w io.Writer) *slog.Logger {
	opts := &slog.HandlerOptions{Level: cfg.LogLevel}
	if cfg.Env == config.EnvProd {
		return slog.New(slog.NewJSONHandler(w, opts))
	}
	return slog.New(slog.NewTextHandler(w, opts))
}

func runServer(ctx context.Context, cfg config.Config, log *slog.Logger) error {
	pool, err := store.NewPool(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()
	// Database yang belum hidup tidak menggagalkan start: /readyz melaporkan 503
	// sampai database siap (container DB bisa menyala belakangan).
	if err := pool.Ping(ctx); err != nil {
		log.Warn("database belum bisa dihubungi", "err", err)
	}

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           httpapi.NewRouter(httpapi.Deps{Log: log, DB: pool}),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("server mendengarkan", "addr", cfg.HTTPAddr, "env", string(cfg.Env))
		errCh <- srv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		return fmt.Errorf("listen %s: %w", cfg.HTTPAddr, err)
	case <-ctx.Done():
	}

	log.Info("menghentikan server")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutdown: %w", err)
	}
	return nil
}
