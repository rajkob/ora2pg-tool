# ora2pg -- Oracle to PostgreSQL migration tool (Docker)

Runs [Ora2Pg 25.0](https://ora2pg.darold.net/) inside a Docker container so
your machine stays clean -- no Oracle client, no Perl modules, nothing to
install beyond **Docker Desktop**.

Pre-built image on Docker Hub: **[rajkob/ora2pg:25.0](https://hub.docker.com/r/rajkob/ora2pg)**

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **Docker Desktop 4.x** (or Docker Engine 24+) | [Download](https://www.docker.com/products/docker-desktop/) |
| **Docker Compose v2** | Ships with Docker Desktop; verify with: docker compose version |
| Network access to Oracle and PostgreSQL | Can be remote hosts or local |

That is all. No Oracle client, no Perl, no Python, no make.

---

## Quick start -- Windows (PowerShell)

```powershell
# Clone once
git clone https://github.com/rajkob/ora2pg-tool.git
cd ora2pg-tool

# Run a full migration (image downloads automatically on first run ~400 MB)
.\migrate.ps1 `
    -OraHost    prod-oracle.example.com `
    -OraService ORCL `
    -OraUser    scott `
    -OraPass    tiger `
    -OraSchema  SCOTT `
    -PgHost     pg.example.com `
    -PgDb       targetdb `
    -PgUser     postgres `
    -PgPass     secret `
    -Tables     "ORDERS,CUSTOMERS,PRODUCTS"   # omit to migrate all tables
```

Output files land in `.\schema\` and `.\data\` in the current directory.

---

## Quick start -- Linux / macOS (Bash)

```bash
# Clone once
git clone https://github.com/rajkob/ora2pg-tool.git
cd ora2pg-tool
chmod +x migrate.sh

# Run a full migration
./migrate.sh \
    --ora-host    prod-oracle.example.com \
    --ora-service ORCL \
    --ora-user    scott \
    --ora-pass    tiger \
    --ora-schema  SCOTT \
    --pg-host     pg.example.com \
    --pg-db       targetdb \
    --pg-user     postgres \
    --pg-pass     secret \
    --tables      "ORDERS,CUSTOMERS,PRODUCTS"   # omit to migrate all tables
```

---

## migrate.ps1 / migrate.sh -- parameter reference

### Oracle source

| PowerShell | Bash | Default | Description |
|---|---|---|---|
| `-OraHost` | `--ora-host` | **required** | Oracle hostname or IP |
| `-OraPort` | `--ora-port` | `1521` | Oracle listener port |
| `-OraService` | `--ora-service` | **required** * | Oracle service name |
| `-OraSid` | `--ora-sid` | -- | Use SID instead of service name |
| `-OraUser` | `--ora-user` | **required** | Oracle username |
| `-OraPass` | `--ora-pass` | **required** | Oracle password |
| `-OraSchema` | `--ora-schema` | **required** | Oracle schema to migrate |

\* Either `-OraService` or `-OraSid` must be supplied.

### PostgreSQL target

| PowerShell | Bash | Default | Description |
|---|---|---|---|
| `-PgHost` | `--pg-host` | **required** | PostgreSQL hostname or IP |
| `-PgPort` | `--pg-port` | `5432` | PostgreSQL port |
| `-PgDb` | `--pg-db` | **required** | Target database name |
| `-PgUser` | `--pg-user` | **required** | PostgreSQL username |
| `-PgPass` | `--pg-pass` | **required** | PostgreSQL password |
| `-PgSchema` | `--pg-schema` | OraSchema lowercased | Target schema inside the PG database |

### Mode flags

| PowerShell | Bash | Description |
|---|---|---|
| `-Tables "T1,T2"` | `--tables "T1,T2"` | Migrate only these tables (comma or space separated). Omit to migrate all. |
| `-PreflightOnly` | `--preflight-only` | Test connectivity only -- do not migrate anything. |
| `-SchemaOnly` | `--schema-only` | Export and import DDL only, skip data. |
| `-DataOnly` | `--data-only` | Export and import data only, skip DDL. |

---

## What the script does, step by step

1. Writes a temporary `ora2pg.conf` and `.env` (deleted automatically on exit).
2. Pulls `rajkob/ora2pg:25.0` from Docker Hub if not cached locally.
3. **Preflight** -- connects to Oracle (`SHOW_VERSION`) and PostgreSQL (`SELECT 1`).
4. If `-Tables` was given, verifies the tables exist in the Oracle schema.
5. **Schema export** -- runs TABLE, SEQUENCE, INDEX, TRIGGER, VIEW to `schema/*.sql`.
6. **Schema import** -- loads each `schema/*.sql` into PostgreSQL via `psql`.
7. **Data export** -- runs COPY mode to `data/data.sql`.
8. **Data import** -- loads `data/data.sql` into PostgreSQL via `psql`.

Steps 5-6 are skipped with `-DataOnly`; steps 7-8 are skipped with `-SchemaOnly`.

---

## Advanced: manual config file + Makefile

For power users who prefer writing `ora2pg.conf` by hand:

```bash
cp ora2pg.conf.example ora2pg.conf   # edit Oracle/PG connection strings
cp .env.example .env                 # set ORA_PWD and PG_PWD
chmod 600 .env

make help          # list all targets
make check-oracle  # verify Oracle connectivity
make report        # generate logs/assessment.html (migration complexity report)
make schema        # export all DDL into schema/
make data          # export all data into data/
make all           # full pipeline in one shot
```

---

## Repository layout

```
.
+-- migrate.ps1           # Windows end-to-end migration script (primary entry point)
+-- migrate.sh            # Linux/macOS equivalent
+-- docker-compose.yml    # Uses rajkob/ora2pg:25.0 from Docker Hub
+-- Dockerfile            # Used by maintainers to rebuild the image
+-- Makefile              # Power-user wrapper (make help)
+-- ora2pg.conf.example   # Template config for manual runs
+-- .env.example          # Template for ORA_PWD / PG_PWD
+-- .dockerignore
+-- .gitignore
+-- vendor/               # NOT in git -- put Oracle Instant Client ZIPs here
    +-- README.md         # Download instructions
```
