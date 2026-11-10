#!/usr/bin/env bash
set -Eeuo pipefail

config="${SAS_CONFIG_FILE:-/opt/fmo-data/sas/config.json}"
config_dir="$(dirname "$config")"
roots_dir="${SAS_ROOTS_DIR:-/opt/fmo-data/sas/roots}"
mkdir -p "$config_dir" "$roots_dir"

log() { printf '[fmo] %s\n' "$*"; }
die() { printf '[fmo] ERROR: %s\n' "$*" >&2; exit 64; }
need() { [[ -n "${!1:-}" ]] || die "$1 is required"; }

json_array_or_empty() {
  local name="$1" value="${2:-}"
  [[ -z "$value" ]] && return 0
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$value" \
    || die "$name must be a JSON array"
}

json_array_or_empty SAS_CLUSTERS_JSON "${SAS_CLUSTERS_JSON:-}"
json_array_or_empty SAS_ADMINS_JSON "${SAS_ADMINS_JSON:-}"

has_init_env=false
for v in SAS_SERVER_UID SAS_SERVER_CALLSIGN SAS_MQTT_HOST SAS_CERT_FINGERPRINT; do
  if [[ -n "${!v:-}" ]]; then has_init_env=true; fi
done

if [[ ! -f "$config" && "$has_init_env" != true ]]; then
  die "first start requires SAS_SERVER_UID, SAS_SERVER_CALLSIGN, SAS_MQTT_HOST and SAS_CERT_FINGERPRINT"
fi

if [[ "$has_init_env" == true ]]; then
  for v in SAS_SERVER_UID SAS_SERVER_CALLSIGN SAS_MQTT_HOST SAS_CERT_FINGERPRINT; do
    need "$v"
  done
fi

# Create the first config ourselves when cluster/admin overrides are requested,
# so the running SAS process never needs a restart just to pick them up.
generate_config() {
  [[ "$SAS_SERVER_UID" =~ ^[0-9]+$ ]] || die "SAS_SERVER_UID must be an integer"
  local port="${SAS_MQTT_PORT:-1883}"
  [[ "$port" =~ ^[0-9]+$ ]] || die "SAS_MQTT_PORT must be an integer"

  local tmp
  tmp="$(mktemp "${config_dir}/.config.XXXXXX")"
  jq -n \
    --argjson uid "$SAS_SERVER_UID" \
    --arg callsign "$SAS_SERVER_CALLSIGN" \
    --arg host "$SAS_MQTT_HOST" \
    --argjson port "$port" \
    --arg certFingerprint "$SAS_CERT_FINGERPRINT" \
    --argjson clusters "${SAS_CLUSTERS_JSON:-[]}" \
    --argjson admins "${SAS_ADMINS_JSON:-[]}" '
      {
        Server: {
          Uid: $uid,
          Callsign: $callsign,
          CertFingerprint: $certFingerprint,
          Admins: $admins
        },
        Mqtt: {
          Host: $host,
          Port: $port,
          Clusters: $clusters
        },
        Trust: {},
        Crl: {},
        Log: {},
        Http: {},
        Update: {}
      }
    ' > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$config"
  log "generated $config"
}

# SAS writes PascalCase keys, while older/hand-written configs may use lowercase.
# Normalize both forms so the env overrides work either way.
merge_json_overrides() {
  local clusters="${SAS_CLUSTERS_JSON:-null}"
  local admins="${SAS_ADMINS_JSON:-null}"
  local tmp
  tmp="$(mktemp "${config_dir}/.config.XXXXXX")"
  jq --argjson clusters "$clusters" --argjson admins "$admins" '
    def mqtt_obj:
      if has("Mqtt") then .Mqtt
      elif has("mqtt") then .mqtt
      else {} end;
    def server_obj:
      if has("Server") then .Server
      elif has("server") then .server
      else {} end;
    def normalize_mqtt:
      . as $m
      | ($m + {
          Host: ($m.Host // $m.host // ""),
          Port: ($m.Port // $m.port // 1883),
          Clusters: ($m.Clusters // $m.clusters // [])
        })
      | del(.host, .port, .clusters);
    def normalize_server:
      . as $s
      | ($s + {
          Uid: ($s.Uid // $s.uid // 0),
          Callsign: ($s.Callsign // $s.callsign // ""),
          CertFingerprint: ($s.CertFingerprint // $s.certFingerprint // ""),
          Admins: ($s.Admins // $s.admins // [])
        })
      | del(.uid, .callsign, .certFingerprint, .admins);
    (if $clusters != null then
       .Mqtt = ((mqtt_obj | normalize_mqtt) + {Clusters: $clusters})
       | del(.mqtt)
     else . end)
    | (if $admins != null then
         .Server = ((server_obj | normalize_server) + {Admins: $admins})
         | del(.server)
       else . end)
  ' "$config" > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$config"
  log "applied JSON overrides to $config"
}

if [[ ! -f "$config" ]]; then
  if [[ -n "${SAS_CLUSTERS_JSON:-}" || -n "${SAS_ADMINS_JSON:-}" ]]; then
    generate_config
  fi
elif [[ -n "${SAS_CLUSTERS_JSON:-}" || -n "${SAS_ADMINS_JSON:-}" ]]; then
  merge_json_overrides
fi

sas_args=(--config "$config")
if [[ -n "${SAS_SERVER_UID:-}" ]]; then sas_args+=(--server-uid "$SAS_SERVER_UID"); fi
if [[ -n "${SAS_SERVER_CALLSIGN:-}" ]]; then sas_args+=(--server-callsign "$SAS_SERVER_CALLSIGN"); fi
if [[ -n "${SAS_MQTT_HOST:-}" ]]; then sas_args+=(--mqtt-host "$SAS_MQTT_HOST"); fi
if [[ -n "${SAS_MQTT_PORT:-}" ]]; then sas_args+=(--mqtt-port "$SAS_MQTT_PORT"); fi
if [[ -n "${SAS_CERT_FINGERPRINT:-}" ]]; then sas_args+=(--cert-fingerprint "$SAS_CERT_FINGERPRINT"); fi
sas_args+=(--http-addr "${SAS_HTTP_ADDR:-127.0.0.1}")
sas_args+=(--http-port "${SAS_HTTP_PORT:-8080}")
if [[ -n "${SAS_HTTP_TTL:-}" ]]; then sas_args+=(--http-ttl "$SAS_HTTP_TTL"); fi
if [[ -n "${SAS_CRL_REFRESH:-}" ]]; then sas_args+=(--crl-refresh "$SAS_CRL_REFRESH"); fi
if [[ -n "${SAS_ALLOW_ISSUER_SN:-}" ]]; then sas_args+=(--allow-issuer-sn "$SAS_ALLOW_ISSUER_SN"); fi
if [[ -n "${SAS_ISSUER_SN:-}" ]]; then sas_args+=(--issuer-sn "$SAS_ISSUER_SN"); fi
if [[ -n "${SAS_LOG_LEVEL:-}" ]]; then sas_args+=(--log-level "$SAS_LOG_LEVEL"); fi
sas_args+=(--roots-dir "$roots_dir")

log "starting SAS (config=$config)"
DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 /opt/fmo-sas/sas "${sas_args[@]}" &
sas_pid=$!

# EMQX 5.x wants array elements via EMQX_AUTHENTICATION__1. Keep a baked default
# so a plain `docker run` works without an extra compose/environment entry.
if [[ -z "${EMQX_AUTHENTICATION__1:-}" && -z "${EMQX_AUTHENTICATION:-}" ]]; then
  sas_http_port="${SAS_HTTP_PORT:-8080}"
  EMQX_AUTHENTICATION__1="$(printf '{mechanism = password_based, backend = http, method = post, url = "http://127.0.0.1:%s/auth", headers = {"Content-Type" = "application/json"}, body = {username = "${username}", password = "${password}"}}' "$sas_http_port")"
  export EMQX_AUTHENTICATION__1
fi

log "starting EMQX"
/usr/bin/docker-entrypoint.sh emqx foreground &
emqx_pid=$!

fas_pid=""
if [[ "${FAS_ENABLED:-1}" == "1" ]]; then
  [[ -x /opt/fmo-fas/fmo-audit-service ]] || die "FAS binary not found at /opt/fmo-fas/fmo-audit-service"
  export EMQX_MONITOR_PORT="${EMQX_MONITOR_PORT:-9527}"
  export EMQX_MONITOR_DB="${EMQX_MONITOR_DB:-/opt/fmo-data/fas/fmo-audit-service.db}"
  export EMQX_MONITOR_WEBHOOK_URL="${EMQX_MONITOR_WEBHOOK_URL:-http://127.0.0.1:${EMQX_MONITOR_PORT}/api/ingest}"
  export DOTNET_RUNNING_IN_CONTAINER="${DOTNET_RUNNING_IN_CONTAINER:-true}"
  mkdir -p "$(dirname "$EMQX_MONITOR_DB")"
  log "starting FAS on :${EMQX_MONITOR_PORT} (db=$EMQX_MONITOR_DB)"
  /opt/fmo-fas/fmo-audit-service &
  fas_pid=$!
else
  log "FAS disabled (FAS_ENABLED=$FAS_ENABLED)"
fi

nginx_pid=""
if [[ "${WEB_ENABLED:-1}" == "1" ]]; then
  web_port="${WEB_LISTEN_PORT:-8081}"
  [[ "$web_port" =~ ^[0-9]+$ ]] || die "WEB_LISTEN_PORT must be an integer"

  fas_backend="127.0.0.1:9527"
  emqx_backend="127.0.0.1:18083"
  case "${WEB_DEFAULT:-fas}" in
    fas)  default_backend="$fas_backend" ;;
    emqx) default_backend="$emqx_backend" ;;
    *) die "WEB_DEFAULT must be 'fas' or 'emqx'" ;;
  esac

  switcher_html='<!doctype html><meta charset="utf-8"><title>FMO Web</title><h1>FMO Web</h1><p>Choose an app. The choice is stored in the fmoapp cookie.</p><ul><li><a href="/__fmo/fas">FAS audit service</a></li><li><a href="/__fmo/emqx">EMQX Dashboard</a></li></ul>'

  mkdir -p /tmp/fmo-nginx/body /tmp/fmo-nginx/proxy /tmp/fmo-nginx/fastcgi \
           /tmp/fmo-nginx/uwsgi /tmp/fmo-nginx/scgi
  sed -e "s|__WEB_PORT__|$web_port|g" \
      -e "s|__DEFAULT_BACKEND__|$default_backend|g" \
      -e "s|__FAS_BACKEND__|$fas_backend|g" \
      -e "s|__EMQX_BACKEND__|$emqx_backend|g" \
      -e "s|__SWITCHER_HTML__|$switcher_html|g" \
      /etc/fmo-nginx/nginx.conf.template > /tmp/fmo-nginx/nginx.conf

  /usr/sbin/nginx -t -c /tmp/fmo-nginx/nginx.conf
  log "starting nginx on :${web_port} (default=${WEB_DEFAULT:-fas}, switch at /__fmo)"
  /usr/sbin/nginx -c /tmp/fmo-nginx/nginx.conf -g 'daemon off;' &
  nginx_pid=$!
else
  log "nginx disabled (WEB_ENABLED=$WEB_ENABLED)"
fi

pids=("$sas_pid" "$emqx_pid")
if [[ -n "$fas_pid" ]]; then pids+=("$fas_pid"); fi
if [[ -n "$nginx_pid" ]]; then pids+=("$nginx_pid"); fi

stop_all() {
  trap - TERM INT
  kill -TERM "${pids[@]}" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    local alive=0
    for p in "${pids[@]}"; do
      if kill -0 "$p" 2>/dev/null; then alive=1; fi
    done
    if [[ "$alive" -eq 0 ]]; then break; fi
    sleep 1
  done
  for p in "${pids[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
  wait "${pids[@]}" 2>/dev/null || true
}

trap stop_all TERM INT

set +e
wait -n "${pids[@]}"
rc=$?
set -e

log "a service exited (rc=$rc); stopping container"
stop_all
exit "$rc"
