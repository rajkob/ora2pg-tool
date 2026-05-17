# syntax=docker/dockerfile:1.6
#
# Ora2Pg in a container.
# Build:   docker build -t ora2pg:local .
# Run:     docker compose run --rm ora2pg -c /work/ora2pg.conf -t SHOW_VERSION
#
# Provide the Oracle Instant Client ZIPs under ./vendor/ before building:
#   vendor/instantclient-basic-linux.x64-*.zip   (required)
#   vendor/instantclient-sdk-linux.x64-*.zip     (required)
#   vendor/instantclient-sqlplus-linux.x64-*.zip (optional)
#
FROM ubuntu:24.04 AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG ORA2PG_VERSION=25.0

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cpanminus \
        curl \
        libaio1t64 \
        libcompress-raw-zlib-perl \
        libdbd-pg-perl \
        libdbi-perl \
        make \
        netcat-openbsd \
        perl \
        perl-modules \
        postgresql-client \
        unzip \
        wget \
    && ln -sf /usr/lib/x86_64-linux-gnu/libaio.so.1t64 \
              /usr/lib/x86_64-linux-gnu/libaio.so.1 \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Oracle Instant Client (from ./vendor/)
# ---------------------------------------------------------------------------
WORKDIR /opt/oracle
COPY vendor/instantclient-*.zip /tmp/ic/

RUN set -eux; \
    cd /tmp/ic; \
    for z in instantclient-basic-linux.x64-*.zip \
             instantclient-sdk-linux.x64-*.zip \
             instantclient-sqlplus-linux.x64-*.zip; do \
        if ls $z >/dev/null 2>&1; then unzip -o $z -d /opt/oracle; fi; \
    done; \
    IC_DIR=$(ls -d /opt/oracle/instantclient_* | head -n1); \
    ln -s "$IC_DIR" /opt/oracle/instantclient; \
    # Create unversioned .so symlinks that the linker needs (e.g. libclntshcore.so) \
    for v in "$IC_DIR"/lib*.so.[0-9]*; do \
        base=$(echo "$v" | sed 's/\.so\.[0-9][0-9.]*$/.so/'); \
        [ "$base" = "$v" ] && continue; \
        [ -e "$base" ] && continue; \
        ln -sf "$v" "$base"; \
    done; \
    echo "/opt/oracle/instantclient" > /etc/ld.so.conf.d/oracle-instantclient.conf; \
    ldconfig; \
    rm -rf /tmp/ic

ENV ORACLE_HOME=/opt/oracle/instantclient \
    LD_LIBRARY_PATH=/opt/oracle/instantclient \
    PATH=/opt/oracle/instantclient:/usr/local/bin:/usr/bin:/bin \
    NLS_LANG=AMERICAN_AMERICA.AL32UTF8

# ---------------------------------------------------------------------------
# Perl modules
# ---------------------------------------------------------------------------
RUN cpanm --notest DBD::Oracle \
    && perl -MDBD::Oracle -e 'print "DBD::Oracle ", $DBD::Oracle::VERSION, " OK\n"' \
    && perl -MDBD::Pg     -e 'print "DBD::Pg ",     $DBD::Pg::VERSION,     " OK\n"'

# ---------------------------------------------------------------------------
# Ora2Pg
# ---------------------------------------------------------------------------
RUN set -eux; \
    cd /tmp; \
    wget -q "https://github.com/darold/ora2pg/archive/refs/tags/v${ORA2PG_VERSION}.tar.gz" \
         -O ora2pg.tar.gz; \
    tar xzf ora2pg.tar.gz; \
    cd ora2pg-${ORA2PG_VERSION}; \
    perl Makefile.PL; \
    make; \
    make install; \
    cd /; \
    rm -rf /tmp/ora2pg*

# ---------------------------------------------------------------------------
# Non-root runtime user
# ---------------------------------------------------------------------------
RUN /usr/sbin/useradd --create-home --shell /bin/bash --uid 1001 ora2pg \
    && mkdir -p /work /work/schema /work/data /work/logs \
    && chown -R ora2pg:ora2pg /work

USER ora2pg
WORKDIR /work

ENTRYPOINT ["ora2pg"]
CMD ["--version"]