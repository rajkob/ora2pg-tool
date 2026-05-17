#!/usr/bin/env bash
# migrate.sh — End-to-end Oracle → PostgreSQL migration via ora2pg in Docker
#
# Usage:
#   ./migrate.sh \
#     --ora-host HOST --ora-service SERVICE \
#     --ora-user USER --ora-pass PASS --ora-schema SCHEMA \
#     --pg-host HOST  --pg-db DB --pg-user USER --pg-pass PASS \
#     [--tables "T1,T2,T3"] [--pg-schema target_schema] \
#     [--preflight-only] [--schema-only] [--data-only]
#
# Flags:
#   --ora-host        Oracle host                          (required)
#   --ora-port        Oracle port                          (default: 1521)
#   --ora-service     Oracle service name                  (required, or use --ora-sid)
#   --ora-sid         Oracle SID                           (alternative to --ora-service)
#   --ora-user        Oracle username                      (required)
#   --ora-pass        Oracle password                      (required)
#   --ora-schema      Oracle schema to migrate             (required)
#   --pg-host         PostgreSQL host                      (required)
#   --pg-port         PostgreSQL port                      (default: 5432)
#   --pg-db           PostgreSQL database name             (required)
#   --pg-user         PostgreSQL username                  (required)
#   --pg-pass         PostgreSQL password                  (required)
#   --tables          Comma/space-separated table names    (default: all)
#   --pg-schema       Target PG schema                     (default: ora-schema lowercased)
#   --pg-version      PG major version fallback             (default: 16, auto-detected from server)
#   --preflight-only  Run connectivity + table checks only
#   --schema-only     Export/import DDL only, skip data
#   --data-only       Export/import data only, skip DDL

set -euo pipefail

CONF="_run.conf"
ENV="_run.env"
IMG="rajkob/ora2pg:25.0"

ORA_HOST=""
ORA_PORT="1521"
ORA_SERVICE=""
ORA_SID=""
ORA_USER=""
ORA_PASS=""
ORA_SCHEMA=""

PG_HOST=""
PG_PORT="5432"
PG_DB=""
PG_USER=""
PG_PASS=""

TABLES=""
PG_SCHEMA=""
PG_VERSION="16"
PREFLIGHT_ONLY=false
SCHEMA_ONLY=false
DATA_ONLY=false

# ── Helpers ────────────────────────────────────────────────────────────────────
step() { printf "\n\033[36m[*] %s\033[0m\n" "$*"; }
ok()   { printf "\033[32m[+] %s\033[0m\n" "$*"; }
info() { printf "    %s\n" "$*"; }
fail() { printf "\n\033[31m[!] %s\033[0m\n" "$*"; exit 1; }

cleanup() { rm -f "$CONF" "$ENV"; }
trap cleanup EXIT

# ── Parse args ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ora-host)      ORA_HOST="$2";    shift 2 ;;
        --ora-port)      ORA_PORT="$2";    shift 2 ;;
        --ora-service)   ORA_SERVICE="$2"; shift 2 ;;
        --ora-sid)       ORA_SID="$2";     shift 2 ;;
        --ora-user)      ORA_USER="$2";    shift 2 ;;
        --ora-pass)      ORA_PASS="$2";    shift 2 ;;
        --ora-schema)    ORA_SCHEMA="$2";  shift 2 ;;
        --pg-host)       PG_HOST="$2";     shift 2 ;;
        --pg-port)       PG_PORT="$2";     shift 2 ;;
        --pg-db)         PG_DB="$2";       shift 2 ;;
        --pg-user)       PG_USER="$2";     shift 2 ;;
        --pg-pass)       PG_PASS="$2";     shift 2 ;;
        --tables)        TABLES="$2";      shift 2 ;;
        --pg-schema)     PG_SCHEMA="$2";   shift 2 ;;
        --pg-version)    PG_VERSION="$2";  shift 2 ;;
        --preflight-only) PREFLIGHT_ONLY=true; shift ;;
        --schema-only)   SCHEMA_ONLY=true; shift ;;
        --data-only)     DATA_ONLY=true;   shift ;;
        *) fail "Unknown option: $1" ;;
    esac
done

# ── Validate required params ───────────────────────────────────────────────────
for var in ORA_HOST ORA_USER ORA_PASS ORA_SCHEMA PG_HOST PG_DB PG_USER PG_PASS; do
    [[ -z "${!var}" ]] && fail "--$(echo "$var" | tr '[:upper:]_' '[:lower:]-') is required"
done
[[ -z "$ORA_SERVICE" && -z "$ORA_SID" ]] && fail "--ora-service (or --ora-sid) is required"

PG_SCHEMA="${PG_SCHEMA:-$(echo "$ORA_SCHEMA" | tr '[:upper:]' '[:lower:]')}"

# ── Build Oracle DSN ───────────────────────────────────────────────────────────
if [[ -n "$ORA_SID" ]]; then
    ORA_DSN="dbi:Oracle:host=${ORA_HOST};port=${ORA_PORT};sid=${ORA_SID}"
else
    ORA_DSN="dbi:Oracle:host=${ORA_HOST};port=${ORA_PORT};service_name=${ORA_SERVICE}"
fi

# ── Build table list and ALLOW regex ──────────────────────────────────────────
TABLE_ARR=()
ALLOW_LINE=""
if [[ -n "$TABLES" ]]; then
    IFS=$',\t ' read -ra RAW <<< "$TABLES"
    for t in "${RAW[@]}"; do
        [[ -n "$t" ]] && TABLE_ARR+=("$t")
    done
    if [[ ${#TABLE_ARR[@]} -gt 0 ]]; then
        ALLOW_PATTERN=$(IFS='|'; echo "${TABLE_ARR[*]}")
        ALLOW_LINE="ALLOW         ^(${ALLOW_PATTERN})$"
    fi
fi

# ── Write temp env file ────────────────────────────────────────────────────────
step "Writing temporary config"

# PGPASSWORD is read by psql inside the container
printf "ORA_PWD=%s\nPG_PWD=%s\nPGPASSWORD=%s\n" \
    "$ORA_PASS" "$PG_PASS" "$PG_PASS" > "$ENV"
chmod 600 "$ENV"

# ── Write temp ora2pg conf ─────────────────────────────────────────────────────
cat > "$CONF" <<EOF
ORACLE_DSN      ${ORA_DSN}
ORACLE_USER     ${ORA_USER}
ORACLE_PWD      ${ORA_PASS}
SCHEMA          ${ORA_SCHEMA}

PG_DSN          dbi:Pg:host=${PG_HOST};port=${PG_PORT};dbname=${PG_DB}
PG_USER         ${PG_USER}
PG_PWD          ${PG_PASS}
PG_SCHEMA       ${PG_SCHEMA}

OUTPUT_DIR      /work/schema
NLS_LANG        AMERICAN_AMERICA.AL32UTF8
DATA_LIMIT      10000
PG_VERSION      ${PG_VERSION}
${ALLOW_LINE}
EOF

mkdir -p schema logs
ok "Config written"

# ── Helper: run ora2pg ─────────────────────────────────────────────────────────
run_ora2pg() {
    docker compose run --rm -T --env-file "$ENV" ora2pg \
        -c "/work/$CONF" "$@"
}

# ── Helper: run psql ───────────────────────────────────────────────────────────
run_psql() {
    docker compose run --rm -T --env-file "$ENV" --entrypoint psql ora2pg \
        -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" "$@"
}

# ── Ensure image exists ────────────────────────────────────────────────────────
if ! docker images -q "$IMG" | grep -q .; then
    step "Image $IMG not found — pulling from Docker Hub"
    docker pull "$IMG"
    ok "Image pulled"
fi

# ── PREFLIGHT: Oracle ──────────────────────────────────────────────────────────
step "Preflight — Oracle ($ORA_USER @ $ORA_HOST:$ORA_PORT)"
if ! ORA_OUT=$(run_ora2pg -t SHOW_VERSION 2>&1); then
    fail "Cannot connect to Oracle.\n${ORA_OUT}"
fi
ok "Oracle reachable — $(echo "$ORA_OUT" | grep -iE 'oracle|version' | head -1)"

# ── PREFLIGHT: PostgreSQL ──────────────────────────────────────────────────────
step "Preflight — PostgreSQL ($PG_USER @ $PG_HOST:$PG_PORT / $PG_DB)"
if ! PG_OUT=$(run_psql -c "SELECT 1" 2>&1); then
    fail "Cannot connect to PostgreSQL.\n${PG_OUT}"
fi
ok "PostgreSQL reachable"

# Auto-detect PostgreSQL major version from the live server (overrides --pg-version fallback)
_pgvernum=$(run_psql -A -t -c "SHOW server_version_num;" 2>/dev/null | tr -d '[:space:]')
if [[ "$_pgvernum" =~ ^[0-9]+$ ]]; then
    PG_VERSION=$(( _pgvernum / 10000 ))
    _tmp=$(mktemp)
    awk -v v="$PG_VERSION" '/^PG_VERSION/{print "PG_VERSION      " v; next} {print}' "$CONF" > "$_tmp" && mv "$_tmp" "$CONF"
    ok "Auto-detected PostgreSQL $PG_VERSION"
fi

# ── PREFLIGHT: Verify tables ───────────────────────────────────────────────────
if [[ ${#TABLE_ARR[@]} -gt 0 ]]; then
    step "Preflight — Verifying tables in schema $ORA_SCHEMA"
    TABLE_LIST=$(run_ora2pg -t SHOW_TABLE 2>&1) || fail "SHOW_TABLE failed.\n${TABLE_LIST}"
    MISSING=()
    for tbl in "${TABLE_ARR[@]}"; do
        echo "$TABLE_LIST" | grep -qi "\b${tbl}\b" || MISSING+=("$tbl")
    done
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        fail "Table(s) not found in ${ORA_SCHEMA}: ${MISSING[*]}"
    fi
    ok "All ${#TABLE_ARR[@]} table(s) verified: ${TABLE_ARR[*]}"
fi

$PREFLIGHT_ONLY && { ok "Preflight passed. Stopping (--preflight-only)."; exit 0; }

# ── SCHEMA: Export + Import ────────────────────────────────────────────────────
if ! $DATA_ONLY; then
    for TYPE in TABLE SEQUENCE INDEX TRIGGER VIEW; do
        step "Exporting $TYPE"
        lower=$(echo "$TYPE" | tr '[:upper:]' '[:lower:]')
        run_ora2pg -t "$TYPE" -o "/work/schema/${lower}.sql"
        ok "$TYPE  →  schema/${lower}.sql"
    done

    step "Importing schema into PostgreSQL ($PG_SCHEMA)"
    for f in table sequence view trigger index; do
        if [[ -f "schema/${f}.sql" ]]; then
            info "schema/${f}.sql"
            run_psql -f "/work/schema/${f}.sql"
        fi
    done
    ok "Schema imported into $PG_DB"
    if [[ -f "schema/table.sql" ]]; then
        _tc=$(grep -ic "^CREATE TABLE" "schema/table.sql" 2>/dev/null || echo 0)
        info "  ${_tc} table(s) queued for data migration"
    fi
fi

# ── DATA: Migrate directly to PostgreSQL via DBI ───────────────────────────────
# When PG_DSN is configured, ora2pg INSERT type writes directly to PostgreSQL
# through its own DBI connection — no intermediate file or psql pipe needed.
if ! $SCHEMA_ONLY; then
    step "Migrating data (direct INSERT to PostgreSQL)"
    run_ora2pg -t INSERT
    ok "Data migrated to $PG_DB"

    step "Row count summary"
    # ANALYZE refreshes pg_class.reltuples (accurate post-bulk-load row estimates)
    run_psql -c "ANALYZE; SELECT c.relname AS table_name, c.reltuples::bigint AS rows FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '${PG_SCHEMA}' AND c.relkind = 'r' ORDER BY c.relname;"
fi

printf "\n"
ok "=== Migration complete ==="
info "Schema artifacts : ./schema/"
info "Logs             : ./logs/"
