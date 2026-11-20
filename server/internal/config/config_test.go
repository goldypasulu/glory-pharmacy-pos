package config

import (
	"log/slog"
	"strings"
	"testing"
)

func envMap(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoadDefaults(t *testing.T) {
	cfg, err := Load(envMap(map[string]string{
		"GLORYPOS_DATABASE_URL": "postgres://x",
		"GLORYPOS_JWT_SECRET":   "rahasia",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.HTTPAddr != ":8080" || cfg.Env != EnvDev || cfg.LogLevel != slog.LevelInfo {
		t.Fatalf("default salah: %+v", cfg)
	}
}

func TestLoadValues(t *testing.T) {
	cfg, err := Load(envMap(map[string]string{
		"GLORYPOS_DATABASE_URL": "postgres://x",
		"GLORYPOS_JWT_SECRET":   "rahasia",
		"GLORYPOS_HTTP_ADDR":    "127.0.0.1:9000",
		"GLORYPOS_ENV":          "PROD",
		"GLORYPOS_LOG_LEVEL":    "debug",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.HTTPAddr != "127.0.0.1:9000" || cfg.Env != EnvProd || cfg.LogLevel != slog.LevelDebug {
		t.Fatalf("nilai salah: %+v", cfg)
	}
}

func TestLoadErrors(t *testing.T) {
	_, err := Load(envMap(map[string]string{
		"GLORYPOS_ENV":       "staging",
		"GLORYPOS_LOG_LEVEL": "verbose",
	}))
	if err == nil {
		t.Fatal("harus gagal")
	}
	for _, want := range []string{"GLORYPOS_DATABASE_URL", "GLORYPOS_JWT_SECRET", "GLORYPOS_ENV", "GLORYPOS_LOG_LEVEL"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error tidak menyebut %s: %v", want, err)
		}
	}
}
