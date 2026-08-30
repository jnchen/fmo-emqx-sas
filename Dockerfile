ARG EMQX_IMAGE=emqx/emqx:5.8.9
ARG SAS_BUILDER_IMAGE=debian:bookworm-slim
ARG SAS_VERSION=v1.0.6
ARG SAS_URL_AMD64=https://github.com/BG5ESN/fmo-server-authrozier-service/releases/download/v1.0.6/linux-x64.tar.gz
ARG SAS_URL_ARM64=https://github.com/BG5ESN/fmo-server-authrozier-service/releases/download/v1.0.6/linux-arm64.tar.gz
ARG SAS_SHA256_AMD64=
ARG SAS_SHA256_ARM64=

FROM --platform=$BUILDPLATFORM ${SAS_BUILDER_IMAGE} AS sas
ARG TARGETARCH
ARG SAS_URL_AMD64
ARG SAS_URL_ARM64
ARG SAS_SHA256_AMD64
ARG SAS_SHA256_ARM64

RUN set -eux; \
    if ! command -v curl >/dev/null || ! command -v tar >/dev/null || ! command -v sha256sum >/dev/null; then \
      apt-get update; \
      apt-get install -y --no-install-recommends ca-certificates curl tar gzip; \
      rm -rf /var/lib/apt/lists/*; \
    fi

RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) SAS_URL="$SAS_URL_AMD64"; SAS_SHA256="$SAS_SHA256_AMD64" ;; \
      arm64) SAS_URL="$SAS_URL_ARM64"; SAS_SHA256="$SAS_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    test -n "$SAS_URL"; \
    curl --fail --location --retry 3 --retry-all-errors "$SAS_URL" -o /tmp/sas.tar.gz; \
    if [ -n "$SAS_SHA256" ]; then \
      echo "${SAS_SHA256#sha256:}  /tmp/sas.tar.gz" | sha256sum -c -; \
    fi; \
    mkdir /out; \
    tar -xzf /tmp/sas.tar.gz -C /out; \
    test -s /out/sas

FROM ${EMQX_IMAGE}

ARG SAS_VERSION
LABEL org.opencontainers.image.title="FMO EMQX + SAS" \
      org.opencontainers.image.source="https://github.com/BG5ESN/fmo-server-authrozier-service" \
      io.fmo.sas.version="${SAS_VERSION}" \
      io.fmo.emqx.version="5.8.9"

USER root

COPY --from=sas /out/ /opt/fmo-sas/
COPY fmo-entrypoint.sh /usr/local/bin/fmo-entrypoint.sh

RUN chmod 0755 /opt/fmo-sas/sas /usr/local/bin/fmo-entrypoint.sh \
    && mkdir -p /opt/fmo-data/sas \
    && chown -R emqx:emqx /opt/fmo-data

ENV SAS_CONFIG_FILE=/opt/fmo-data/sas/config.json \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

USER emqx

EXPOSE 1883 18083
ENTRYPOINT ["/usr/local/bin/fmo-entrypoint.sh"]
