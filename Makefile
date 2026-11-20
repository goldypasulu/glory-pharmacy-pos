# Glory POS - perintah pengembangan. Lihat CLAUDE.md bagian "Verifikasi".
SHELL := /bin/bash
.DEFAULT_GOAL := check

COMPOSE_DEV := docker compose -f deploy/docker-compose.dev.yml
# Script db/*.sh dijalankan di dalam container (client PostgreSQL 16 = versi server).
PG_EXEC     := $(COMPOSE_DEV) exec -T -u postgres db
TEMPLATE_DB := glorypos_template

GO_PKGS  := ./shared/... ./server/...
GO_DIRS  := shared server cashier

TEST_DATABASE_URL ?= postgres://postgres:postgres@localhost:55432/postgres?sslmode=disable
export TEST_DATABASE_URL

# Database hasil migrate-legacy / reimport-legacy di PostgreSQL dev, dan target `make run`.
LEGACY_DB ?= glory_pos
GLORYPOS_DATABASE_URL ?= postgres://postgres:postgres@localhost:55432/$(LEGACY_DB)?sslmode=disable
GLORYPOS_JWT_SECRET   ?= dev-only-jangan-dipakai-di-produksi

.PHONY: fmt vet sqlc test test-db test-db-up test-db-down check run migrate-legacy reimport-legacy require-dump

fmt:
	gofmt -w $(GO_DIRS)

vet:
	go vet $(GO_PKGS)

sqlc:
	cd server && sqlc generate

test:
	go test -count=1 $(GO_PKGS)

check:
	@out="$$(gofmt -l $(GO_DIRS))"; if [ -n "$$out" ]; then echo "gofmt belum dijalankan (make fmt):"; echo "$$out"; exit 1; fi
	go vet $(GO_PKGS)
	cd server && sqlc diff
	go test -count=1 $(GO_PKGS)

test-db-up:
	$(COMPOSE_DEV) up -d --wait db

# Membuat ulang database template dari schema.sql + db/migrations.
test-db: test-db-up
	@if [ "$$($(PG_EXEC) psql -X -Atc "SELECT 1 FROM pg_database WHERE datname = '$(TEMPLATE_DB)'")" = "1" ]; then \
	  $(PG_EXEC) psql -X -q -v ON_ERROR_STOP=1 -c "ALTER DATABASE $(TEMPLATE_DB) IS_TEMPLATE false" && \
	  $(PG_EXEC) psql -X -q -v ON_ERROR_STOP=1 -c "DROP DATABASE $(TEMPLATE_DB) WITH (FORCE)"; \
	fi
	$(PG_EXEC) createdb $(TEMPLATE_DB)
	$(PG_EXEC) env DB=$(TEMPLATE_DB) /glorypos/db/apply-migrations.sh
	$(PG_EXEC) psql -X -q -v ON_ERROR_STOP=1 -c "ALTER DATABASE $(TEMPLATE_DB) IS_TEMPLATE true"
	@echo "Template $(TEMPLATE_DB) siap. TEST_DATABASE_URL=$(TEST_DATABASE_URL)"

test-db-down:
	$(COMPOSE_DEV) down

run:
	GLORYPOS_DATABASE_URL='$(GLORYPOS_DATABASE_URL)' GLORYPOS_JWT_SECRET='$(GLORYPOS_JWT_SECRET)' \
	  go run ./server/cmd/glorypos serve

require-dump:
	@if [ -z "$(LEGACY_DUMP)" ]; then echo "Pakai: make $(MAKECMDGOALS) LEGACY_DUMP=/path/backup.iAbu"; exit 2; fi
	@if [ ! -f "$(LEGACY_DUMP)" ]; then echo "File tidak ditemukan: $(LEGACY_DUMP)"; exit 2; fi

# Migrasi pertama iAbu ke database $(LEGACY_DB) di PostgreSQL dev (dihapus dan dibuat ulang).
migrate-legacy: require-dump test-db-up
	$(COMPOSE_DEV) cp "$(LEGACY_DUMP)" db:/tmp/legacy.iAbu
	$(PG_EXEC) env DB=$(LEGACY_DB) /glorypos/db/migrate.sh /tmp/legacy.iAbu; \
	  status=$$?; $(COMPOSE_DEV) exec -T db rm -f /tmp/legacy.iAbu; exit $$status

# Impor ulang backup iAbu ke database $(LEGACY_DB) yang sudah ada (backup DB disimpan di container).
reimport-legacy: require-dump test-db-up
	$(COMPOSE_DEV) cp "$(LEGACY_DUMP)" db:/tmp/legacy.iAbu
	$(PG_EXEC) env DB=$(LEGACY_DB) BACKUP_DIR=/tmp/glorypos-backups /glorypos/db/reimport.sh /tmp/legacy.iAbu; \
	  status=$$?; $(COMPOSE_DEV) exec -T db rm -f /tmp/legacy.iAbu; exit $$status
