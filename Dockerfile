ARG EMQX_IMAGE=emqx/emqx:5.8.9
ARG SAS_BUILDER_IMAGE=debian:bookworm-slim

ARG SAS_VERSION=v1.0.6
ARG SAS_URL_AMD64=https://github.com/BG5ESN/fmo-server-authrozier-service/releases/download/v1.0.6/linux-x64.tar.gz
ARG SAS_URL_ARM64=https://github.com/BG5ESN/fmo-server-authrozier-service/releases/download/v1.0.6/linux-arm64.tar.gz
ARG SAS_SHA256_AMD64=
ARG SAS_SHA256_ARM64=

ARG FAS_VERSION=2.0.22
ARG FAS_URL_AMD64=https://bg5esn.com/share/fmo/fas/v2.0.22/fmo-audit-service-linux-x64.tar.gz
ARG FAS_URL_ARM64=https://bg5esn.com/share/fmo/fas/v2.0.22/fmo-audit-service-linux-arm64.tar.gz
ARG FAS_SHA256_AMD64=sha256:9519dc1dfd82e8e774933625c5b979a3af003cc0e59b8555413fd59774edb7ea
ARG FAS_SHA256_ARM64=sha256:6871e31a76fa9a04510e01baff712ce3c6d220efa84dfe783194f60be1ea0da6

ARG JQ_VERSION=1.7.1
ARG JQ_URL_AMD64=https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
ARG JQ_URL_ARM64=https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-arm64
ARG JQ_SHA256_AMD64=sha256:5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5
ARG JQ_SHA256_ARM64=sha256:4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5

FROM --platform=$BUILDPLATFORM ${SAS_BUILDER_IMAGE} AS fetch
ARG TARGETARCH
ARG SAS_URL_AMD64
ARG SAS_URL_ARM64
ARG SAS_SHA256_AMD64
ARG SAS_SHA256_ARM64
ARG FAS_URL_AMD64
ARG FAS_URL_ARM64
ARG FAS_SHA256_AMD64
ARG FAS_SHA256_ARM64
ARG JQ_URL_AMD64
ARG JQ_URL_ARM64
ARG JQ_SHA256_AMD64
ARG JQ_SHA256_ARM64

RUN set -eux; \
    if ! command -v curl >/dev/null || ! command -v tar >/dev/null || ! command -v sha256sum >/dev/null; then \
      apt-get update; \
      apt-get install -y --no-install-recommends ca-certificates curl tar gzip; \
      rm -rf /var/lib/apt/lists/*; \
    fi

RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) \
        SAS_URL="$SAS_URL_AMD64"; SAS_SHA256="$SAS_SHA256_AMD64"; \
        FAS_URL="$FAS_URL_AMD64"; FAS_SHA256="$FAS_SHA256_AMD64"; \
        JQ_URL="$JQ_URL_AMD64"; JQ_SHA256="$JQ_SHA256_AMD64" ;; \
      arm64) \
        SAS_URL="$SAS_URL_ARM64"; SAS_SHA256="$SAS_SHA256_ARM64"; \
        FAS_URL="$FAS_URL_ARM64"; FAS_SHA256="$FAS_SHA256_ARM64"; \
        JQ_URL="$JQ_URL_ARM64"; JQ_SHA256="$JQ_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    test -n "$SAS_URL"; \
    test -n "$FAS_URL"; \
    test -n "$JQ_URL"; \
    mkdir -p /out/sas /out/fas /out/bin; \
    curl --fail --location --retry 3 --retry-all-errors "$SAS_URL" -o /tmp/sas.tar.gz; \
    if [ -n "$SAS_SHA256" ]; then \
      echo "${SAS_SHA256#sha256:}  /tmp/sas.tar.gz" | sha256sum -c -; \
    fi; \
    tar -xzf /tmp/sas.tar.gz -C /out/sas; \
    sas_bin="$(find /out/sas -maxdepth 1 -type f \( -name sas -o -name Sas \) | head -n 1)"; \
    test -n "$sas_bin"; \
    if [ "$sas_bin" != /out/sas/sas ]; then mv "$sas_bin" /out/sas/sas; fi; \
    curl --fail --location --retry 3 --retry-all-errors "$FAS_URL" -o /tmp/fas.tar.gz; \
    if [ -n "$FAS_SHA256" ]; then \
      echo "${FAS_SHA256#sha256:}  /tmp/fas.tar.gz" | sha256sum -c -; \
    fi; \
    tar -xzf /tmp/fas.tar.gz -C /out/fas; \
    fas_bin="$(find /out/fas -maxdepth 2 -type f -name fmo-audit-service | head -n 1)"; \
    test -n "$fas_bin"; \
    if [ "$fas_bin" != /out/fas/fmo-audit-service ]; then mv "$fas_bin" /out/fas/fmo-audit-service; fi; \
    curl --fail --location --retry 3 --retry-all-errors "$JQ_URL" -o /out/bin/jq; \
    if [ -n "$JQ_SHA256" ]; then \
      echo "${JQ_SHA256#sha256:}  /out/bin/jq" | sha256sum -c -; \
    fi; \
    chmod 0755 /out/bin/jq

FROM ${EMQX_IMAGE}

ARG SAS_VERSION
ARG FAS_VERSION
ARG JQ_VERSION
LABEL org.opencontainers.image.title="FMO EMQX + SAS + FAS" \
      org.opencontainers.image.source="https://github.com/BG5ESN/fmo-server-authrozier-service" \
      io.fmo.sas.version="${SAS_VERSION}" \
      io.fmo.fas.version="${FAS_VERSION}" \
      io.fmo.jq.version="${JQ_VERSION}" \
      io.fmo.emqx.version="5.8.9"

USER root

# Install distro packages first so later COPYs of scripts/templates stay cache-friendly.
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends nginx-light; \
    rm -rf /var/lib/apt/lists/*

COPY --from=fetch /out/sas/ /opt/fmo-sas/
COPY --from=fetch /out/fas/fmo-audit-service /opt/fmo-fas/fmo-audit-service
COPY --from=fetch /out/bin/jq /usr/local/bin/jq
COPY fmo-entrypoint.sh /usr/local/bin/fmo-entrypoint.sh
COPY nginx.conf.template /etc/fmo-nginx/nginx.conf.template

RUN set -eux; \
    chmod 0755 /opt/fmo-sas/sas /opt/fmo-fas/fmo-audit-service /usr/local/bin/jq /usr/local/bin/fmo-entrypoint.sh; \
    chmod 0644 /etc/fmo-nginx/nginx.conf.template; \
    mkdir -p /opt/fmo-data/sas/roots /opt/fmo-data/fas; \
    chown -R emqx:emqx /opt/fmo-data

ENV SAS_CONFIG_FILE=/opt/fmo-data/sas/config.json \
    SAS_ROOTS_DIR=/opt/fmo-data/sas/roots \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
    DOTNET_RUNNING_IN_CONTAINER=true \
    FAS_ENABLED=1 \
    EMQX_MONITOR_PORT=9527 \
    EMQX_MONITOR_DB=/opt/fmo-data/fas/fmo-audit-service.db \
    WEB_ENABLED=1 \
    WEB_LISTEN_PORT=8081 \
    WEB_DEFAULT=fas

USER emqx

EXPOSE 1883 18083 9527 8080 8081
ENTRYPOINT ["/usr/local/bin/fmo-entrypoint.sh"]
