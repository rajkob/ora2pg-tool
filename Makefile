# ---------------------------------------------------------------------------
# Ora2Pg Docker wrapper
# ---------------------------------------------------------------------------
# Usage:  make <target>
# Help:   make help   (or just `make`)
#
# Every target ultimately invokes `docker compose run --rm ora2pg ...`
# with the local ./ora2pg.conf mounted at /work/ora2pg.conf inside the
# container. Output files land in ./schema, ./data, ./logs on the host.
# ---------------------------------------------------------------------------

# ----- Configurable variables (override on the CLI, e.g. `make data TABLES='T1 T2'`)
ORA2PG_VERSION ?= 25.0
CONF           ?= /work/ora2pg.conf
TABLES         ?=
SCHEMA_DIR     ?= schema
DATA_DIR       ?= data
LOG_DIR        ?= logs

# Compose command (works for both `docker compose` and legacy `docker-compose`)
COMPOSE        ?= docker compose
RUN            := $(COMPOSE) run --rm ora2pg
RUN_SH         := $(COMPOSE) run --rm --entrypoint bash ora2pg
RUN_PSQL       := $(COMPOSE) run --rm --entrypoint psql ora2pg
RUN_SQLPLUS    := $(COMPOSE) run --rm --entrypoint sqlplus ora2pg

# Default goal
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Meta
# ---------------------------------------------------------------------------

.PHONY: help
help: ## Show this help
	@echo "Ora2Pg Docker wrapper — available targets:"
	@echo
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Common overrides:"
	@echo "  make data TABLES='ORDERS CUSTOMERS'"
	@echo "  make build ORA2PG_VERSION=25.1"

.PHONY: dirs
dirs: ## Create output directories on the host
	@mkdir -p $(SCHEMA_DIR) $(DATA_DIR) $(LOG_DIR)

# ---------------------------------------------------------------------------
# Image lifecycle
# ---------------------------------------------------------------------------

.PHONY: build
build: ## Build the Docker image (use ORA2PG_VERSION=x.y to pin)
	$(COMPOSE) build --build-arg ORA2PG_VERSION=$(ORA2PG_VERSION)

.PHONY: rebuild
rebuild: ## Rebuild the image from scratch (no cache)
	$(COMPOSE) build --no-cache --build-arg ORA2PG_VERSION=$(ORA2PG_VERSION)

.PHONY: clean
clean: ## Remove the built image
	-docker image rm ora2pg:local

.PHONY: clean-output
clean-output: ## Delete schema/, data/, logs/ contents (NOT configs)
	rm -rf $(SCHEMA_DIR)/* $(DATA_DIR)/* $(LOG_DIR)/*

# ---------------------------------------------------------------------------
# Smoke tests / connectivity
# ---------------------------------------------------------------------------

.PHONY: version
version: ## Print ora2pg version from inside the container
	$(RUN) --version

.PHONY: check-oracle
check-oracle: ## Quick `SHOW_VERSION` against Oracle using the config
	$(RUN) -c $(CONF) -t SHOW_VERSION

.PHONY: check-pg
check-pg: ## Print PostgreSQL server version (set PGURL, e.g. PGURL='host=... dbname=... user=...')
	@test -n "$(PGURL)" || (echo "Set PGURL, e.g. make check-pg PGURL='host=h dbname=d user=u'" && exit 1)
	$(RUN_PSQL) "$(PGURL)" -c "SELECT version();"

# ---------------------------------------------------------------------------
# Inventory / assessment
# ---------------------------------------------------------------------------

.PHONY: show-schema
show-schema: ## List Oracle schemas visible to the configured user
	$(RUN) -c $(CONF) -t SHOW_SCHEMA

.PHONY: show-table
show-table: ## List tables in the configured schema
	$(RUN) -c $(CONF) -t SHOW_TABLE

.PHONY: show-column
show-column: ## List columns per table
	$(RUN) -c $(CONF) -t SHOW_COLUMN

.PHONY: report
report: dirs ## Full HTML migration assessment -> logs/assessment.html
	$(RUN) -c $(CONF) -t SHOW_REPORT --estimate_cost --dump_as_html \
	    > $(LOG_DIR)/assessment.html
	@echo "Report written to $(LOG_DIR)/assessment.html"

# ---------------------------------------------------------------------------
# Schema export
# ---------------------------------------------------------------------------

.PHONY: schema
schema: dirs ## Export ALL schema artefacts (tables, views, seqs, triggers, fns, procs, grants)
	$(RUN) -c $(CONF) -t TABLE     -o /work/$(SCHEMA_DIR)/tables.sql
	$(RUN) -c $(CONF) -t VIEW      -o /work/$(SCHEMA_DIR)/views.sql
	$(RUN) -c $(CONF) -t SEQUENCE  -o /work/$(SCHEMA_DIR)/sequences.sql
	$(RUN) -c $(CONF) -t TRIGGER   -o /work/$(SCHEMA_DIR)/triggers.sql
	$(RUN) -c $(CONF) -t FUNCTION  -o /work/$(SCHEMA_DIR)/functions.sql
	$(RUN) -c $(CONF) -t PROCEDURE -o /work/$(SCHEMA_DIR)/procedures.sql
	$(RUN) -c $(CONF) -t GRANT     -o /work/$(SCHEMA_DIR)/grants.sql
	@echo "Schema exported to ./$(SCHEMA_DIR)/"

.PHONY: schema-tables
schema-tables: dirs ## Export only table DDL
	$(RUN) -c $(CONF) -t TABLE -o /work/$(SCHEMA_DIR)/tables.sql

# ---------------------------------------------------------------------------
# Data export
# ---------------------------------------------------------------------------

.PHONY: data
data: dirs ## Export data using fast COPY format (override TABLES='T1 T2' for a subset)
ifeq ($(strip $(TABLES)),)
	$(RUN) -c $(CONF) -t COPY -o /work/$(DATA_DIR)/data.sql
else
	$(RUN) -c $(CONF) -t COPY -a '$(TABLES)' -o /work/$(DATA_DIR)/data_subset.sql
endif
	@echo "Data exported to ./$(DATA_DIR)/"

.PHONY: data-inserts
data-inserts: dirs ## Export data as portable INSERT statements (slower, more portable)
	$(RUN) -c $(CONF) -t INSERT -o /work/$(DATA_DIR)/data_inserts.sql

# ---------------------------------------------------------------------------
# PL/SQL → PL/pgSQL conversion test
# ---------------------------------------------------------------------------

.PHONY: test
test: ## Run ora2pg TEST (PL/SQL conversion accuracy check)
	$(RUN) -c $(CONF) -t TEST

# ---------------------------------------------------------------------------
# Convenience shells
# ---------------------------------------------------------------------------

.PHONY: shell
shell: ## Interactive bash shell inside the container
	$(RUN_SH)

.PHONY: sqlplus
sqlplus: ## SQL*Plus shell (pass CONN='user/pass@//host:1521/SVC')
	@test -n "$(CONN)" || (echo "Set CONN, e.g. make sqlplus CONN='u/p@//host:1521/SVC'" && exit 1)
	$(RUN_SQLPLUS) '$(CONN)'

.PHONY: psql
psql: ## psql shell (pass PGURL='host=... dbname=... user=...')
	@test -n "$(PGURL)" || (echo "Set PGURL, e.g. make psql PGURL='host=h dbname=d user=u'" && exit 1)
	$(RUN_PSQL) "$(PGURL)"

# ---------------------------------------------------------------------------
# End-to-end pipelines
# ---------------------------------------------------------------------------

.PHONY: all
all: build check-oracle report schema data ## Full pipeline: build → connect → report → schema → data
	@echo "✅ Full migration export complete."