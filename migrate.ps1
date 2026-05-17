<#
.SYNOPSIS
    End-to-end Oracle to PostgreSQL migration via ora2pg in Docker.

.DESCRIPTION
    1. Runs preflight connectivity checks (Oracle + PostgreSQL).
    2. Optionally verifies that specified tables exist in the Oracle schema.
    3. Exports schema (DDL) and/or data from Oracle.
    4. Imports them into PostgreSQL.

    No .env or ora2pg.conf is needed beforehand — both are generated from
    the parameters you pass and are deleted automatically when the script exits.

.EXAMPLE
    .\migrate.ps1 `
        -OraHost db-oracle.example.com -OraService ORCL `
        -OraUser scott -OraPass tiger -OraSchema SCOTT `
        -PgHost  pg.example.com -PgDb targetdb `
        -PgUser  postgres -PgPass secret `
        -Tables  "ORDERS,CUSTOMERS,PRODUCTS"

.EXAMPLE
    # Preflight checks only — no migration
    .\migrate.ps1 -OraHost ... -OraService ... -OraUser ... -OraPass ... `
        -OraSchema ... -PgHost ... -PgDb ... -PgUser ... -PgPass ... `
        -PreflightOnly

.EXAMPLE
    # Export and import DDL only (skip data)
    .\migrate.ps1 ... -SchemaOnly

.EXAMPLE
    # Export and import data only (assume schema already exists)
    .\migrate.ps1 ... -DataOnly
#>
[CmdletBinding()]
param(
    # ── Oracle source ──────────────────────────────────────────────────────────
    [Parameter(Mandatory)][string] $OraHost,
    [int]                          $OraPort    = 1521,
    [Parameter(Mandatory)][string] $OraService,          # service name (use -OraSid for SID)
    [string]                       $OraSid     = "",      # alternative to OraService
    [Parameter(Mandatory)][string] $OraUser,
    [Parameter(Mandatory)][string] $OraPass,
    [Parameter(Mandatory)][string] $OraSchema,

    # ── PostgreSQL target ──────────────────────────────────────────────────────
    [Parameter(Mandatory)][string] $PgHost,
    [int]                          $PgPort     = 5432,
    [Parameter(Mandatory)][string] $PgDb,
    [Parameter(Mandatory)][string] $PgUser,
    [Parameter(Mandatory)][string] $PgPass,

    # ── Scope ──────────────────────────────────────────────────────────────────
    [string] $Tables   = "",  # Comma- or space-separated table names; "" = all tables
    [string] $PgSchema = "",  # Target PG schema; defaults to OraSchema lowercased

    # ── Mode ───────────────────────────────────────────────────────────────────
    [switch] $PreflightOnly,  # Run checks only, do not migrate
    [switch] $SchemaOnly,     # Export + import DDL only, skip data
    [switch] $DataOnly        # Skip DDL, export + import data only
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$CONF = "_run.conf"
$ENV  = "_run.env"

# ── Helpers ────────────────────────────────────────────────────────────────────
function Step($m) { Write-Host "`n[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m"   -ForegroundColor Green }
function Info($m) { Write-Host "    $m" }
function Fail($m) { Write-Host "`n[!] $m" -ForegroundColor Red; throw $m }

function Cleanup {
    Remove-Item -Force -ErrorAction SilentlyContinue $CONF, $ENV
}

try {
    # ── Resolve table list and ALLOW regex ─────────────────────────────────────
    $tableArr  = @()
    $allowLine = ""
    if ($Tables -ne "") {
        $tableArr  = ($Tables -split '[,\s]+') | Where-Object { $_ -ne "" }
        $allowLine = "ALLOW         ^($($tableArr -join '|'))$"
    }

    $pgTarget = if ($PgSchema -ne "") { $PgSchema } else { $OraSchema.ToLower() }

    # ── Build Oracle DSN ───────────────────────────────────────────────────────
    $oraDsn = if ($OraSid -ne "") {
        "dbi:Oracle:host=${OraHost};port=${OraPort};sid=${OraSid}"
    } else {
        "dbi:Oracle:host=${OraHost};port=${OraPort};service_name=${OraService}"
    }

    # ── Write temp env file ────────────────────────────────────────────────────
    Step "Writing temporary config"

    # PGPASSWORD is read by the psql client inside the container
    "ORA_PWD=${OraPass}`nPG_PWD=${PgPass}`nPGPASSWORD=${PgPass}" |
        Set-Content $ENV -Encoding ascii

    # ── Write temp ora2pg conf ─────────────────────────────────────────────────
    @"
ORACLE_DSN      ${oraDsn}
ORACLE_USER     ${OraUser}
ORACLE_PWD      ENV{ORA_PWD}
SCHEMA          ${OraSchema}

PG_DSN          dbi:Pg:host=${PgHost};port=${PgPort};dbname=${PgDb}
PG_USER         ${PgUser}
PG_PWD          ENV{PG_PWD}
PG_SCHEMA       ${pgTarget}

OUTPUT_DIR      /work/schema
NLS_LANG        AMERICAN_AMERICA.AL32UTF8
DATA_LIMIT      10000
${allowLine}
"@ | Set-Content $CONF -Encoding ascii

    New-Item -ItemType Directory -Force -Path schema, data, logs | Out-Null
    Ok "Config written"

    # ── Ensure Docker image exists ─────────────────────────────────────────────
    $imgId = (& docker images -q "rajkob/ora2pg:25.0" 2>$null)
    if (-not $imgId) {
        Step "Image rajkob/ora2pg:25.0 not found — pulling from Docker Hub"
        & docker pull rajkob/ora2pg:25.0
        if ($LASTEXITCODE -ne 0) { Fail "docker pull failed — check your internet connection" }
        Ok "Image pulled"
    }

    # ── Shortcut: docker compose run with our env file ─────────────────────────
    function Invoke-Ora2pg([string[]] $ExtraArgs) {
        & docker compose run --rm -T --env-file $ENV ora2pg `
            -c "/work/$CONF" @ExtraArgs
        if ($LASTEXITCODE -ne 0) { Fail "ora2pg exited with code $LASTEXITCODE" }
    }

    function Invoke-Psql([string[]] $ExtraArgs) {
        & docker compose run --rm -T --env-file $ENV --entrypoint psql ora2pg `
            -h $PgHost -p $PgPort -U $PgUser -d $PgDb @ExtraArgs
        if ($LASTEXITCODE -ne 0) { Fail "psql exited with code $LASTEXITCODE" }
    }

    # ── PREFLIGHT: Oracle ──────────────────────────────────────────────────────
    Step "Preflight — Oracle ($OraUser @ $($OraHost):$($OraPort))"
    $oraOut = & docker compose run --rm -T --env-file $ENV ora2pg `
        -c "/work/$CONF" -t SHOW_VERSION 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "Cannot connect to Oracle.`n$($oraOut -join "`n")"
    }
    Ok "Oracle reachable — $($oraOut | Select-String 'Oracle|version' | Select-Object -First 1)"

    # ── PREFLIGHT: PostgreSQL ──────────────────────────────────────────────────
    Step "Preflight — PostgreSQL ($PgUser @ $($PgHost):$($PgPort) / $PgDb)"
    $pgOut = & docker compose run --rm -T --env-file $ENV --entrypoint psql ora2pg `
        -h $PgHost -p $PgPort -U $PgUser -d $PgDb -c "SELECT 1" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "Cannot connect to PostgreSQL.`n$($pgOut -join "`n")"
    }
    Ok "PostgreSQL reachable"

    # ── PREFLIGHT: Verify tables exist ─────────────────────────────────────────
    if ($tableArr.Count -gt 0) {
        Step "Preflight — Verifying tables in schema $OraSchema"
        $showOut = & docker compose run --rm -T --env-file $ENV ora2pg `
            -c "/work/$CONF" -t SHOW_TABLE 2>&1
        if ($LASTEXITCODE -ne 0) { Fail "SHOW_TABLE failed.`n$($showOut -join "`n")" }

        $outUpper = ($showOut -join "`n").ToUpper()
        $missing  = $tableArr | Where-Object { $outUpper -notmatch "\b$($_.ToUpper())\b" }
        if ($missing) {
            Fail "Table(s) not found in ${OraSchema}: $($missing -join ', ')"
        }
        Ok "All $($tableArr.Count) table(s) verified: $($tableArr -join ', ')"
    }

    if ($PreflightOnly) {
        Ok "Preflight passed. Stopping (-PreflightOnly)."
        Cleanup; exit 0
    }

    # ── SCHEMA: Export ─────────────────────────────────────────────────────────
    if (-not $DataOnly) {
        foreach ($type in @("TABLE","SEQUENCE","INDEX","TRIGGER","VIEW")) {
            Step "Exporting $type"
            $lower = $type.ToLower()
            Invoke-Ora2pg "-t", $type, "-o", "/work/schema/${lower}.sql"
            Ok "$type  →  schema\${lower}.sql"
        }

        # ── SCHEMA: Import ─────────────────────────────────────────────────────
        Step "Importing schema into PostgreSQL ($pgTarget)"
        foreach ($f in @("table","sequence","view","trigger","index")) {
            if (Test-Path "schema\${f}.sql") {
                Info "schema\${f}.sql"
                Invoke-Psql "-f", "/work/schema/${f}.sql"
            }
        }
        Ok "Schema imported into $PgDb"
    }

    # ── DATA: Export ───────────────────────────────────────────────────────────
    if (-not $SchemaOnly) {
        Step "Exporting data (COPY)"
        Invoke-Ora2pg "-t", "COPY", "-o", "/work/data/data.sql"
        Ok "Data  →  data\data.sql"

        # ── DATA: Import ───────────────────────────────────────────────────────
        Step "Importing data into PostgreSQL"
        Invoke-Psql "-f", "/work/data/data.sql"
        Ok "Data imported into $PgDb"
    }

    Write-Host ""
    Ok "=== Migration complete ==="
    Info "Schema artifacts : .\schema\"
    Info "Data artifacts   : .\data\"
    Info "Logs             : .\logs\"

} finally {
    Cleanup
}
