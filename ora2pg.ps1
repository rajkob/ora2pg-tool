# Usage: .\ora2pg.ps1 <command> [args]
#   .\ora2pg.ps1 build
#   .\ora2pg.ps1 check-oracle
#   .\ora2pg.ps1 report
#   .\ora2pg.ps1 data -Tables "ORDERS CUSTOMERS"

param(
    [Parameter(Position=0)]
    [string]$Command = "help",

    [string]$Tables = "",
    [string]$Ora2pgVersion = "25.0",
    [string]$Conf = "/work/ora2pg.conf"
)

$ErrorActionPreference = "Stop"
$RUN = "docker compose run --rm ora2pg"

switch ($Command) {
    "help" {
        Write-Host "Available commands:"
        Write-Host "  build         Build the Docker image"
        Write-Host "  rebuild       Rebuild from scratch"
        Write-Host "  version       Print ora2pg version"
        Write-Host "  check-oracle  Test Oracle connectivity"
        Write-Host "  show-table    List Oracle tables"
        Write-Host "  report        Generate HTML assessment -> logs/assessment.html"
        Write-Host "  schema        Export all DDL"
        Write-Host "  data          Export all data (use -Tables 'T1 T2' for subset)"
        Write-Host "  shell         Interactive bash shell"
        Write-Host "  clean         Remove the image"
    }
    "build"        { docker compose build --build-arg ORA2PG_VERSION=$Ora2pgVersion }
    "rebuild"      { docker compose build --no-cache --build-arg ORA2PG_VERSION=$Ora2pgVersion }
    "version"      { docker compose run --rm ora2pg --version }
    "check-oracle" { docker compose run --rm ora2pg -c $Conf -t SHOW_VERSION }
    "show-table"   { docker compose run --rm ora2pg -c $Conf -t SHOW_TABLE }
    "report" {
        New-Item -ItemType Directory -Force -Path "logs" | Out-Null
        docker compose run --rm ora2pg -c $Conf -t SHOW_REPORT --estimate_cost --dump_as_html `
            > logs/assessment.html
        Write-Host "Report written to logs/assessment.html"
    }
    "schema" {
        New-Item -ItemType Directory -Force -Path "schema" | Out-Null
        docker compose run --rm ora2pg -c $Conf -t TABLE     -o /work/schema/tables.sql
        docker compose run --rm ora2pg -c $Conf -t VIEW      -o /work/schema/views.sql
        docker compose run --rm ora2pg -c $Conf -t SEQUENCE  -o /work/schema/sequences.sql
        docker compose run --rm ora2pg -c $Conf -t TRIGGER   -o /work/schema/triggers.sql
        docker compose run --rm ora2pg -c $Conf -t FUNCTION  -o /work/schema/functions.sql
        docker compose run --rm ora2pg -c $Conf -t PROCEDURE -o /work/schema/procedures.sql
        docker compose run --rm ora2pg -c $Conf -t GRANT     -o /work/schema/grants.sql
        Write-Host "Schema exported to .\schema\"
    }
    "data" {
        New-Item -ItemType Directory -Force -Path "data" | Out-Null
        if ([string]::IsNullOrWhiteSpace($Tables)) {
            docker compose run --rm ora2pg -c $Conf -t COPY -o /work/data/data.sql
        } else {
            docker compose run --rm ora2pg -c $Conf -t COPY -a "$Tables" -o /work/data/data_subset.sql
        }
        Write-Host "Data exported to .\data\"
    }
    "shell"        { docker compose run --rm --entrypoint bash ora2pg }
    "clean"        { docker image rm ora2pg:local }
    default {
        Write-Host "Unknown command: $Command"
        Write-Host "Run '.\ora2pg.ps1 help' for the list."
        exit 1
    }
}