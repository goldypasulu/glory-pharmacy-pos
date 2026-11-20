package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRunExitCodes(t *testing.T) {
	t.Setenv("GLORYPOS_DATABASE_URL", "")
	t.Setenv("GLORYPOS_JWT_SECRET", "")

	tests := []struct {
		name string
		args []string
		code int
		want string
	}{
		{"tanpa perintah", nil, 2, "Pemakaian: glorypos"},
		{"perintah tidak dikenal", []string{"hapus-semua"}, 2, `perintah tidak dikenal: "hapus-semua"`},
		{"help", []string{"help"}, 0, "Pemakaian: glorypos"},
		{"serve -h", []string{"serve", "-h"}, 0, "Pemakaian: glorypos serve"},
		{"serve flag asing", []string{"serve", "--port=1"}, 2, "flag provided but not defined"},
		{"serve tanpa env wajib", []string{"serve"}, 1, "GLORYPOS_DATABASE_URL wajib diisi"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var stderr bytes.Buffer
			if got := run(tt.args, &stderr); got != tt.code {
				t.Fatalf("exit %d, harap %d; stderr:\n%s", got, tt.code, stderr.String())
			}
			if !strings.Contains(stderr.String(), tt.want) {
				t.Fatalf("stderr tidak memuat %q:\n%s", tt.want, stderr.String())
			}
		})
	}
}
