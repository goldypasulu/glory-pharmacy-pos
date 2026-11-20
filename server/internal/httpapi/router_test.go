package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"glorypos/server/internal/testdb"
	"glorypos/shared/api"
)

// newTestServer menjalankan router di server HTTP sungguhan (httptest) agar
// perilaku "server tetap hidup setelah panic" teruji lewat koneksi nyata.
func newTestServer(t *testing.T, db Pinger, logBuf *bytes.Buffer) (*httptest.Server, func(string, http.HandlerFunc)) {
	t.Helper()
	var out io.Writer = io.Discard
	if logBuf != nil {
		out = logBuf
	}
	log := slog.New(slog.NewJSONHandler(out, &slog.HandlerOptions{Level: slog.LevelDebug}))
	r := NewRouter(Deps{Log: log, DB: db})
	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	return srv, func(path string, h http.HandlerFunc) { r.Get(path, h) }
}

func get(t *testing.T, url string) (int, http.Header, []byte) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, resp.Header, body
}

// parseErrorBody memastikan badan respons berformat error kontrak.
func parseErrorBody(t *testing.T, body []byte) api.Error {
	t.Helper()
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatalf("badan bukan JSON: %v: %s", err, body)
	}
	if len(raw) != 1 || raw["error"] == nil {
		t.Fatalf("badan harus tepat {\"error\": {...}}: %s", body)
	}
	var e api.ErrorResponse
	if err := json.Unmarshal(body, &e); err != nil {
		t.Fatal(err)
	}
	if e.Error.Code == "" || e.Error.Message == "" {
		t.Fatalf("code/message kosong: %s", body)
	}
	if _, err := uuid.Parse(e.Error.RequestID); err != nil {
		t.Fatalf("request_id bukan UUID: %q", e.Error.RequestID)
	}
	return e.Error
}

func TestHealthz(t *testing.T) {
	t.Parallel()
	srv, _ := newTestServer(t, nil, nil)
	for _, path := range []string{"/healthz", "/api/v1/healthz"} {
		status, hdr, body := get(t, srv.URL+path)
		if status != http.StatusOK {
			t.Fatalf("%s: status %d: %s", path, status, body)
		}
		if strings.TrimSpace(string(body)) != `{"status":"ok"}` {
			t.Fatalf("%s: badan %s", path, body)
		}
		if _, err := uuid.Parse(hdr.Get(RequestIDHeader)); err != nil {
			t.Fatalf("%s: header %s bukan UUID: %q", path, RequestIDHeader, hdr.Get(RequestIDHeader))
		}
	}
}

func TestReadyz(t *testing.T) {
	t.Parallel()
	db := testdb.New(t)
	srv, _ := newTestServer(t, db.Pool, nil)

	for _, path := range []string{"/readyz", "/api/v1/readyz"} {
		status, _, body := get(t, srv.URL+path)
		if status != http.StatusOK {
			t.Fatalf("%s saat DB hidup: status %d: %s", path, status, body)
		}
	}

	db.Pool.Close()
	for _, path := range []string{"/readyz", "/api/v1/readyz"} {
		status, hdr, body := get(t, srv.URL+path)
		if status != http.StatusServiceUnavailable {
			t.Fatalf("%s saat pool ditutup: status %d: %s", path, status, body)
		}
		e := parseErrorBody(t, body)
		if e.Code != api.CodeUnavailable || !e.Retryable {
			t.Fatalf("%s: harap unavailable + retryable, dapat %+v", path, e)
		}
		if e.RequestID != hdr.Get(RequestIDHeader) {
			t.Fatalf("request_id badan %q != header %q", e.RequestID, hdr.Get(RequestIDHeader))
		}
	}
}

func TestPanicBecomesContractError(t *testing.T) {
	t.Parallel()
	var logs bytes.Buffer
	srv, handle := newTestServer(t, nil, &logs)
	handle("/boom", func(http.ResponseWriter, *http.Request) { panic("sengaja") })

	status, hdr, body := get(t, srv.URL+"/boom")
	if status != http.StatusInternalServerError {
		t.Fatalf("status %d: %s", status, body)
	}
	if ct := hdr.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("Content-Type %q", ct)
	}
	e := parseErrorBody(t, body)
	if e.Code != api.CodeInternal || !e.Retryable {
		t.Fatalf("harap internal + retryable, dapat %+v", e)
	}
	if e.RequestID != hdr.Get(RequestIDHeader) {
		t.Fatalf("request_id badan %q != header %q", e.RequestID, hdr.Get(RequestIDHeader))
	}
	if strings.Contains(string(body), "sengaja") {
		t.Fatalf("isi panic bocor ke klien: %s", body)
	}
	if !strings.Contains(logs.String(), "sengaja") || !strings.Contains(logs.String(), e.RequestID) {
		t.Fatalf("panic tidak dicatat dengan request_id: %s", logs.String())
	}

	// Server tetap hidup dan melayani permintaan berikutnya.
	for range 3 {
		if status, _, body := get(t, srv.URL+"/healthz"); status != http.StatusOK {
			t.Fatalf("setelah panic: status %d: %s", status, body)
		}
	}
}

func TestNotFoundAndMethodNotAllowed(t *testing.T) {
	t.Parallel()
	srv, _ := newTestServer(t, nil, nil)

	for _, path := range []string{"/tidak-ada", "/api/v1/tidak-ada"} {
		status, _, body := get(t, srv.URL+path)
		if status != http.StatusNotFound || parseErrorBody(t, body).Code != api.CodeNotFound {
			t.Fatalf("%s: status %d: %s", path, status, body)
		}
	}

	resp, err := http.Post(srv.URL+"/healthz", "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusMethodNotAllowed || parseErrorBody(t, body).Code != api.CodeBadRequest {
		t.Fatalf("POST /healthz: status %d: %s", resp.StatusCode, body)
	}
}
