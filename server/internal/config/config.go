// Package config membaca konfigurasi server dari environment.
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"strings"
)

// Env adalah mode jalan server.
type Env string

const (
	EnvDev  Env = "dev"
	EnvProd Env = "prod"
)

// Config adalah konfigurasi server hasil Load.
type Config struct {
	DatabaseURL string     // GLORYPOS_DATABASE_URL (wajib)
	HTTPAddr    string     // GLORYPOS_HTTP_ADDR, default ":8080"
	JWTSecret   string     // GLORYPOS_JWT_SECRET (wajib)
	Env         Env        // GLORYPOS_ENV: dev | prod, default dev
	LogLevel    slog.Level // GLORYPOS_LOG_LEVEL: debug | info | warn | error, default info
}

// Load membaca konfigurasi lewat getenv (os.Getenv di produksi, map di tes).
// Semua masalah dikumpulkan jadi satu error agar operator langsung melihat semuanya.
func Load(getenv func(string) string) (Config, error) {
	get := func(k string) string { return strings.TrimSpace(getenv(k)) }

	cfg := Config{
		DatabaseURL: get("GLORYPOS_DATABASE_URL"),
		HTTPAddr:    get("GLORYPOS_HTTP_ADDR"),
		JWTSecret:   get("GLORYPOS_JWT_SECRET"),
		Env:         Env(strings.ToLower(get("GLORYPOS_ENV"))),
	}
	if cfg.HTTPAddr == "" {
		cfg.HTTPAddr = ":8080"
	}
	if cfg.Env == "" {
		cfg.Env = EnvDev
	}

	var errs []error
	if cfg.DatabaseURL == "" {
		errs = append(errs, errors.New("GLORYPOS_DATABASE_URL wajib diisi"))
	}
	if cfg.JWTSecret == "" {
		errs = append(errs, errors.New("GLORYPOS_JWT_SECRET wajib diisi"))
	}
	if cfg.Env != EnvDev && cfg.Env != EnvProd {
		errs = append(errs, fmt.Errorf("GLORYPOS_ENV harus dev atau prod, bukan %q", cfg.Env))
	}

	level := strings.ToLower(get("GLORYPOS_LOG_LEVEL"))
	if level == "" {
		level = "info"
	}
	if err := cfg.LogLevel.UnmarshalText([]byte(level)); err != nil {
		errs = append(errs, fmt.Errorf("GLORYPOS_LOG_LEVEL tidak dikenal %q (debug|info|warn|error)", level))
	}

	if err := errors.Join(errs...); err != nil {
		return Config{}, fmt.Errorf("konfigurasi: %w", err)
	}
	return cfg, nil
}
