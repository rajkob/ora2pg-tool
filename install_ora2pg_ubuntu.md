# Installing Ora2Pg on Ubuntu 24.04

Ora2Pg is a Perl-based tool for migrating Oracle databases to PostgreSQL.
This guide covers installation (steps 1–4) plus practical usage, tuning, and
troubleshooting. Configuration files are already present in this directory,
so editing `/etc/ora2pg/ora2pg.conf` is **not** required — use `-c ./ora2pg.conf`.

> 💡 **When NOT to use ora2pg.** If your source is already PostgreSQL (e.g.
> copying tables from PG prod to PG test), skip this guide entirely and use
> `pg_dump | psql` or `pg_dump -Fc` + `pg_restore`. Ora2Pg is only the right
> tool when the source is **Oracle**.

---

## 0. Pre-flight Checklist

Run these before installing anything:

```bash
# Confirm OS
lsb_release -a

# Confirm you can reach Oracle and PostgreSQL
nc -zv ORACLE_HOST 1521
nc -zv PG_HOST     5432

# Estimate free disk space (data dumps can be large)
df -h /var /tmp /opt
```

Also confirm:

| Item | Notes |
|---|---|
| **Oracle source version** | Instant Client major version must be **≥** source DB version. |
| **Target PostgreSQL version** | 13+ recommended; some Ora2Pg features assume 12+. |
| **Credentials** | A read-only Oracle user with `SELECT ANY DICTIONARY` is enough for most exports. |
| **Charset** | Find Oracle's `NLS_CHARACTERSET` (`SELECT * FROM nls_database_parameters`); usually `AL32UTF8`. |

---

## 1. Install Prerequisites

```bash
sudo apt update
sudo apt install -y \
    build-essential \
    perl \
    perl-modules \
    make \
    cpanminus \
    libdbi-perl \
    libdbd-pg-perl \
    libcompress-raw-zlib-perl \
    unzip \
    wget \
    netcat-openbsd \
    postgresql-client
```

> Ubuntu 24.04 replaced `libcompress-zlib-perl` with `libcompress-raw-zlib-perl`.
> `postgresql-client` provides `psql` for validation later.

---

## 2. Install Oracle Instant Client

Ora2Pg needs **Basic** + **SDK**. SQL*Plus is optional but extremely helpful
for verifying connectivity before running ora2pg.

### 2a. Download

Get the latest Linux x86_64 ZIPs from Oracle:
https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html

- `instantclient-basic-linux.x64-<version>.zip`   (required)
- `instantclient-sdk-linux.x64-<version>.zip`     (required for DBD::Oracle)
- `instantclient-sqlplus-linux.x64-<version>.zip` (optional, recommended)

> Oracle's "Basic" and "SDK" ZIPs are direct-download (no SSO). The full
> installer RPMs require an Oracle account — avoid them on Ubuntu.

### 2b. Install

```bash
sudo apt install -y libaio1t64
# Compatibility symlink — DBD::Oracle still looks for the old libaio.so.1
sudo ln -sf /usr/lib/x86_64-linux-gnu/libaio.so.1t64 \
            /usr/lib/x86_64-linux-gnu/libaio.so.1

sudo mkdir -p /opt/oracle
cd /opt/oracle
sudo unzip -o ~/Downloads/instantclient-basic-linux.x64-*.zip
sudo unzip -o ~/Downloads/instantclient-sdk-linux.x64-*.zip
sudo unzip -o ~/Downloads/instantclient-sqlplus-linux.x64-*.zip   # optional
```

This creates something like `/opt/oracle/instantclient_23_5/`.

### 2c. Register the library path

```bash
echo "/opt/oracle/instantclient_23_5" \
  | sudo tee /etc/ld.so.conf.d/oracle-instantclient.conf
sudo ldconfig
```

### 2d. Set environment variables

Append to `~/.bashrc` (adjust the version directory):

```bash
export ORACLE_HOME=/opt/oracle/instantclient_23_5
export LD_LIBRARY_PATH=$ORACLE_HOME:$LD_LIBRARY_PATH
export PATH=$ORACLE_HOME:$PATH
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
```

Reload and verify:

```bash
source ~/.bashrc
sqlplus -V        # if installed
```

---

## 3. Install Required Perl Modules

```bash
sudo -E cpanm DBD::Oracle
```

> The `-E` flag preserves `ORACLE_HOME` / `LD_LIBRARY_PATH` for the root build
> process. Without it, the build fails with "Oracle library not found".

`DBD::Pg` was already installed in step 1. Sanity-check both:

```bash
perl -MDBD::Oracle -e 'print "DBD::Oracle OK\n"'
perl -MDBD::Pg     -e 'print "DBD::Pg OK\n"'
```

---

## 4. Download and Install Ora2Pg

Pin or fetch latest dynamically:

```bash
cd /tmp
LATEST=$(curl -s https://api.github.com/repos/darold/ora2pg/releases/latest \
         | grep tag_name | cut -d'"' -f4)
wget "https://github.com/darold/ora2pg/archive/refs/tags/${LATEST}.tar.gz" \
     -O ora2pg.tar.gz
tar xzf ora2pg.tar.gz
cd ora2pg-*/
perl Makefile.PL
make
sudo make install
```

Installed locations:
- Executable: `/usr/local/bin/ora2pg`
- Default config template: `/etc/ora2pg/ora2pg.conf.dist`

Verify:

```bash
ora2pg --version
```

---

## 5. Verify Connectivity Before Running Ora2Pg

Catch 80% of issues here:

```bash
# Oracle side (using sqlplus from the Instant Client)
sqlplus 'USER/PASS@//ORACLE_HOST:1521/SERVICE_NAME' <<< "SELECT 1 FROM dual;"

# PostgreSQL side
psql "host=PG_HOST port=5432 dbname=DB user=USER" -c "SELECT version();"
```

If either fails, fix that **before** invoking ora2pg.

---

## 6. Recommended Project Layout

Keep migrations reproducible:

```
ora2pg-migration/
├── ora2pg.conf            # main / default config
├── ora2pg_schema.conf     # schema-only run
├── ora2pg_data.conf       # data-only run
├── .env                   # ORA_PWD / PG_PWD (chmod 600)
├── logs/
├── schema/                # SCHEMA_DIR / OUTPUT_DIR target
└── data/
```

---

## 7. Common Ora2Pg Commands

Run all of these with the local config (`-c ./ora2pg.conf`):

```bash
# Smoke test — talks to Oracle and prints its banner
ora2pg -c ./ora2pg.conf -t SHOW_VERSION

# Inventory
ora2pg -c ./ora2pg.conf -t SHOW_SCHEMA
ora2pg -c ./ora2pg.conf -t SHOW_TABLE
ora2pg -c ./ora2pg.conf -t SHOW_COLUMN

# Full migration assessment report (great first artefact for stakeholders)
ora2pg -c ./ora2pg.conf -t SHOW_REPORT --estimate_cost --dump_as_html \
       > logs/assessment.html

# Schema export
ora2pg -c ./ora2pg.conf -t TABLE     -o schema/tables.sql
ora2pg -c ./ora2pg.conf -t VIEW      -o schema/views.sql
ora2pg -c ./ora2pg.conf -t SEQUENCE  -o schema/sequences.sql
ora2pg -c ./ora2pg.conf -t TRIGGER   -o schema/triggers.sql
ora2pg -c ./ora2pg.conf -t FUNCTION  -o schema/functions.sql
ora2pg -c ./ora2pg.conf -t PROCEDURE -o schema/procedures.sql
ora2pg -c ./ora2pg.conf -t GRANT     -o schema/grants.sql

# Data export
ora2pg -c ./ora2pg.conf -t COPY   -o data/data.sql              # COPY format (fast)
ora2pg -c ./ora2pg.conf -t INSERT -o data/data_inserts.sql      # portable fallback

# Subset: only specific tables (overrides ALLOW in the conf)
ora2pg -c ./ora2pg.conf -t COPY -a 'TABLE_A TABLE_B' -o data/subset.sql

# PL/SQL → PL/pgSQL conversion accuracy test
ora2pg -c ./ora2pg.conf -t TEST
```

Useful flags:

| Flag | Purpose |
|---|---|
| `--debug` | Verbose progress output |
| `--estimate_cost` | Add complexity scoring to reports |
| `--dump_as_html` / `--dump_as_csv` | Report format |
| `-J N` | Override `JOBS` from CLI |
| `-L N` | Override `DATA_LIMIT` from CLI |
| `-a 'T1 T2'` | Allow only listed tables |
| `-e 'T1 T2'` | Exclude listed tables |

> Bonus: `ora2pg_scanner` (ships with the package) auto-discovers all schemas
> on an Oracle instance and produces one report per schema. Great for
> first-time audits of unfamiliar databases.

---

## 8. Performance Tuning Cheat-Sheet

Edit these in `ora2pg.conf`:

| Setting | Purpose | Reasonable starting value |
|---|---|---|
| `JOBS` | Parallel PG COPY workers | # of PG cores |
| `ORACLE_COPIES` | Parallel Oracle readers | 4–8 |
| `PARALLEL_TABLES` | Tables exported in parallel | 2–4 |
| `DATA_LIMIT` | Rows per fetch batch | 10000–50000 |
| `BLOB_LIMIT` | Rows per batch when table has LOBs | 500–1000 |
| `LONGREADLEN` | Max LOB size (bytes) | 1048576+ (only as needed) |
| `NLS_LANG` | Charset handling | `AMERICAN_AMERICA.AL32UTF8` |
| `FILE_PER_TABLE` | One output file per table | 1 for large migrations |
| `TRUNCATE_TABLE` | Truncate before load | 1 for re-runnable loads |
| `DROP_INDEXES` | Drop indexes before COPY | 1 for big data loads |
| `DEFER_FKEY` | Defer FKs during load | 1 |

Rule of thumb: raise `DATA_LIMIT` until memory hurts, raise `JOBS` until PG
CPU is the bottleneck.

---

## 9. Credentials: Don't Hard-Code Them

In `ora2pg.conf`, reference environment variables instead of plaintext:

```
ORACLE_PWD ENV{ORA_PWD}
PG_PWD     ENV{PG_PWD}
```

Store secrets in a local `.env` file (and `chmod 600 .env`):

```bash
export ORA_PWD='oracle_password_here'
export PG_PWD='pg_password_here'
```

Then:

```bash
set -a; source .env; set +a
ora2pg -c ./ora2pg.conf -t SHOW_VERSION
```

---

## 10. Post-Migration Validation

Don't trust a green exit code — verify:

```bash
# Row-count comparison (run per table, compare manually or via script)
sqlplus -S 'USER/PASS@//ORACLE_HOST:1521/SVC' <<< \
  "SELECT COUNT(*) FROM SCHEMA.TABLE_A;"

psql "host=PG_HOST dbname=DB user=USER" -c \
  "SELECT COUNT(*) FROM schema.table_a;"
```

Then on the PostgreSQL side:

```sql
-- Refresh planner stats
ANALYZE;

-- Resync sequences to MAX(id)+1 (a commonly forgotten step)
SELECT setval(
  pg_get_serial_sequence('schema.table_a', 'id'),
  (SELECT COALESCE(MAX(id), 1) FROM schema.table_a)
);

-- Validate FKs / constraints actually fire
SET CONSTRAINTS ALL IMMEDIATE;
```

---

## 11. Troubleshooting

| Symptom | Fix |
|---|---|
| `libclntsh.so: cannot open shared object file` | Re-run `sudo ldconfig`; confirm `/etc/ld.so.conf.d/oracle-instantclient.conf` exists. |
| `libaio.so.1: cannot open shared object file` | Create the symlink shown in step 2b. |
| `DBD::Oracle` build fails | `env \| grep ORACLE` to confirm vars; use `sudo -E cpanm DBD::Oracle`. |
| `ORA-12154: TNS:could not resolve...` | Prefer `service_name=` over SID in `ORACLE_DSN`. |
| `ORA-01017: invalid username/password` | Quote `ORACLE_PWD` if it contains special chars. |
| `ORA-28759: failure to open file` | Oracle wallet / SSL path is wrong. |
| `Wide character in print` (Perl) | Set `NLS_LANG=AMERICAN_AMERICA.AL32UTF8` and `BINMODE utf8` in conf. |
| `Out of memory` during COPY | Lower `DATA_LIMIT`; raise `LONGREADLEN` only when needed. |
| `ora2pg: command not found` | `/usr/local/bin` not on PATH — `hash -r` or restart shell. |
| Slow exports | Increase `JOBS`, `ORACLE_COPIES`, `DATA_LIMIT`; enable `FILE_PER_TABLE`. |
| Truncated CLOB/BLOB | Raise `LONGREADLEN`; lower `BLOB_LIMIT`. |

---

## 12. Uninstall / Cleanup

```bash
# Ora2Pg
sudo rm -f /usr/local/bin/ora2pg
sudo rm -rf /etc/ora2pg
sudo rm -rf /usr/local/share/perl/*/Ora2Pg*

# Oracle Instant Client
sudo rm -rf /opt/oracle
sudo rm -f /etc/ld.so.conf.d/oracle-instantclient.conf
sudo ldconfig
```

Then remove the `ORACLE_HOME` / `LD_LIBRARY_PATH` / `NLS_LANG` lines from
`~/.bashrc`.

---

## Next Step: Dockerized Version

A containerized setup (coming next) avoids touching the host entirely:
- No Instant Client install on your machine
- No CPAN modules in system Perl
- Reproducible across dev / CI / prod
- Easy version pinning

See `Dockerfile` and `README-docker.md` (next deliverable).