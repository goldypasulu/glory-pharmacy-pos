package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"glorypos/server/internal/apperr"
	"glorypos/shared/api"
)

// logRecords mengurai log JSON per baris.
func logRecords(t *testing.T, buf *bytes.Buffer) []map[string]any {
	t.Helper()
	var recs []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if line == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("log bukan JSON: %v: %s", err, line)
		}
		recs = append(recs, m)
	}
	return recs
}

func findLog(t *testing.T, buf *bytes.Buffer, msg string) map[string]any {
	t.Helper()
	for _, r := range logRecords(t, buf) {
		if r["msg"] == msg {
			return r
		}
	}
	t.Fatalf("log %q tidak ada:\n%s", msg, buf.String())
	return nil
}

// serveOnce memasang h di /x lalu memanggilnya sekali.
func serveOnce(t *testing.T, deps Deps, h http.Handler) (status int, hdr http.Header, body []byte, logs *bytes.Buffer) {
	t.Helper()
	logs = &bytes.Buffer{}
	if deps.Log == nil {
		deps.Log = slog.New(slog.NewJSONHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	}
	r := NewRouter(deps)
	r.Method(http.MethodGet, "/x", h)
	srv := httptest.NewServer(r)
	defer srv.Close()
	status, hdr, body = get(t, srv.URL+"/x")
	return status, hdr, body, logs
}

func TestFailInternalLogsCauseButHidesIt(t *testing.T) {
	t.Parallel()
	status, hdr, body, logs := serveOnce(t, Deps{}, HandlerFunc(func(http.ResponseWriter, *http.Request) error {
		return fmt.Errorf("query items: %w", errors.New("rahasia-internal"))
	}))
	if status != http.StatusInternalServerError {
		t.Fatalf("status %d", status)
	}
	e := parseErrorBody(t, body)
	if e.Code != api.CodeInternal || !e.Retryable || strings.Contains(string(body), "rahasia") {
		t.Fatalf("respons salah atau membocorkan penyebab: %s", body)
	}
	rec := findLog(t, logs, "permintaan gagal")
	if rec["level"] != "ERROR" || !strings.Contains(fmt.Sprint(rec["err"]), "rahasia-internal") {
		t.Fatalf("log tidak memuat penyebab: %v", rec)
	}
	if rec["request_id"] != hdr.Get(RequestIDHeader) {
		t.Fatalf("log tanpa request_id yang benar: %v", rec)
	}
	access := findLog(t, logs, "http")
	if access["error_code"] != api.CodeInternal || access["request_id"] != hdr.Get(RequestIDHeader) {
		t.Fatalf("log akses kurang lengkap: %v", access)
	}
}

func TestFailAppError(t *testing.T) {
	t.Parallel()
	status, _, body, logs := serveOnce(t, Deps{}, HandlerFunc(func(http.ResponseWriter, *http.Request) error {
		return fmt.Errorf("void: %w", apperr.BusinessRule("sale_already_void", "Nota sudah dibatalkan"))
	}))
	if status != http.StatusUnprocessableEntity {
		t.Fatalf("status %d: %s", status, body)
	}
	e := parseErrorBody(t, body)
	if e.Code != api.CodeBusinessRule || e.Retryable || len(e.Details) != 1 || e.Details[0].Issue != "sale_already_void" {
		t.Fatalf("badan salah: %s", body)
	}
	access := findLog(t, logs, "http")
	if access["level"] != "WARN" || access["error_code"] != api.CodeBusinessRule {
		t.Fatalf("log akses 4xx: %v", access)
	}
}

func TestTimeoutBecomes503(t *testing.T) {
	t.Parallel()
	status, _, body, logs := serveOnce(t, Deps{RequestTimeout: 30 * time.Millisecond},
		HandlerFunc(func(_ http.ResponseWriter, r *http.Request) error {
			<-r.Context().Done() // seperti query DB yang menghormati konteks
			return fmt.Errorf("query: %w", r.Context().Err())
		}))
	if status != http.StatusServiceUnavailable {
		t.Fatalf("status %d: %s", status, body)
	}
	if e := parseErrorBody(t, body); e.Code != api.CodeUnavailable || !e.Retryable {
		t.Fatalf("badan salah: %s", body)
	}
	if rec := findLog(t, logs, "permintaan gagal sementara"); rec["level"] != "WARN" {
		t.Fatalf("level log: %v", rec)
	}
}

func TestErrorAfterResponseStarted(t *testing.T) {
	t.Parallel()
	status, _, body, logs := serveOnce(t, Deps{}, HandlerFunc(func(w http.ResponseWriter, r *http.Request) error {
		WriteJSON(w, r, http.StatusOK, statusResponse{Status: "ok"})
		return errors.New("gagal setelah menulis")
	}))
	if status != http.StatusOK || strings.Contains(string(body), "error") {
		t.Fatalf("respons yang sudah terkirim berubah: %d %s", status, body)
	}
	findLog(t, logs, "error setelah respons mulai terkirim; respons tidak bisa diganti")
}

func TestServiceLogsCarryRequestID(t *testing.T) {
	t.Parallel()
	var logs bytes.Buffer
	// Seperti main: logger yang sama dipakai router dan service.
	log := slog.New(NewLogHandler(slog.NewJSONHandler(&logs, nil)))
	_, hdr, _, _ := serveOnce(t, Deps{Log: log}, HandlerFunc(func(w http.ResponseWriter, r *http.Request) error {
		log.With("modul", "sales").InfoContext(r.Context(), "dari service")
		WriteJSON(w, r, http.StatusOK, statusResponse{Status: "ok"})
		return nil
	}))
	rec := findLog(t, &logs, "dari service")
	if rec["request_id"] != hdr.Get(RequestIDHeader) || rec["modul"] != "sales" {
		t.Fatalf("log service tanpa request_id: %v", rec)
	}
	if strings.Count(logs.String(), `"request_id"`) != 2 { // log service + log akses, tanpa duplikat
		t.Fatalf("request_id dobel atau hilang:\n%s", logs.String())
	}
}

func TestDecodeJSON(t *testing.T) {
	t.Parallel()
	type payload struct {
		ID    uuid.UUID       `json:"id"`
		Total decimal.Decimal `json:"total"`
		Qty   int             `json:"qty"`
	}
	tests := []struct {
		name  string
		body  string
		limit int64
		code  string // "" = sukses
		field string
	}{
		{name: "valid", body: `{"id":"01936f3a-8c2e-7b41-9a0e-2f1d4c5b6a70","total":"12500.00","qty":2}`},
		{name: "field asing diabaikan", body: `{"total":"1.00","cogs":"999.00"}`},
		{name: "kosong", body: ``, code: api.CodeBadRequest},
		{name: "rusak", body: `{"total":`, code: api.CodeBadRequest},
		{name: "sintaks", body: `{"total" "1"}`, code: api.CodeBadRequest},
		{name: "dua nilai", body: `{} {}`, code: api.CodeBadRequest},
		{name: "tipe salah", body: `{"qty":"dua"}`, code: api.CodeValidationFailed, field: "qty"},
		{name: "desimal salah", body: `{"total":"dua ribu"}`, code: api.CodeValidationFailed},
		{name: "uuid salah", body: `{"id":"bukan-uuid"}`, code: api.CodeValidationFailed},
		{name: "terlalu besar", body: `{"total":"` + strings.Repeat("9", 100) + `"}`, limit: 32, code: api.CodePayloadTooLarge},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			limit := tt.limit
			if limit == 0 {
				limit = DefaultBodyLimit
			}
			req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(tt.body))
			var p payload
			err := DecodeJSONLimit(httptest.NewRecorder(), req, &p, limit)
			if tt.code == "" {
				if err != nil {
					t.Fatalf("harap sukses: %v", err)
				}
				return
			}
			var e *apperr.Error
			if !errors.As(err, &e) || e.Code != tt.code {
				t.Fatalf("harap %s, dapat %v", tt.code, err)
			}
			if tt.field != "" && (len(e.Details) == 0 || e.Details[0].Field != tt.field) {
				t.Fatalf("field harap %q: %+v", tt.field, e.Details)
			}
		})
	}
}

func TestEveryContractCodeHasStatus(t *testing.T) {
	codes := []string{
		api.CodeBadRequest, api.CodeValidationFailed, api.CodeUnauthenticated, api.CodeTokenExpired,
		api.CodeForbidden, api.CodeOutletForbidden, api.CodeDeviceInactive, api.CodeNotFound,
		api.CodeConflict, api.CodeStaleWrite, api.CodeDuplicateNumber, api.CodePayloadTooLarge,
		api.CodeBusinessRule, api.CodeRateLimited, api.CodeInternal, api.CodeUnavailable,
	}
	for _, c := range codes {
		if statusByCode[c] == 0 {
			t.Errorf("kode %s belum punya status HTTP", c)
		}
	}
	if len(statusByCode) != len(codes) {
		t.Errorf("statusByCode punya %d kode, daftar tes %d", len(statusByCode), len(codes))
	}
}

func TestUnknownCodeBecomesInternal(t *testing.T) {
	t.Parallel()
	status, _, body, logs := serveOnce(t, Deps{}, HandlerFunc(func(http.ResponseWriter, *http.Request) error {
		return apperr.New("kode_ngarang", "x")
	}))
	if status != http.StatusInternalServerError || parseErrorBody(t, body).Code != api.CodeInternal {
		t.Fatalf("status %d: %s", status, body)
	}
	findLog(t, logs, "kode error tidak dikenal, dikirim sebagai internal")
}
