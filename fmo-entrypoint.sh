#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[fmo] %s\n' "$*"; }
die() { printf '[fmo] ERROR: %s\n' "$*" >&2; exit 64; }
need() { [[ -n "${!1:-}" ]] || die "$1 is required"; }

# Data dirs must be writable by the container user (emqx, uid 1000).
# Named volumes inherit ownership from the image automatically; bind mounts
# keep host ownership, so Linux hosts need `chown -R 1000:1000 <host-dir>`.
ensure_dir_writable() {
  local d="$1"
  mkdir -p "$d" 2>/dev/null || true
  if ! touch "$d/.fmo-writable" 2>/dev/null; then
    die "data directory not writable: $d (uid $(id -u) $(id -un))
  You probably bind-mounted it from a host dir owned by another user.
  Fix on the host, then recreate the container:
      chown -R 1000:1000 <host-dir>
  Or switch to named volumes (required on Windows/macOS Docker Desktop)."
  fi
  rm -f "$d/.fmo-writable"
}

# Random alphanumeric string. head finishes by byte count (no SIGPIPE),
# so this is safe under `set -o pipefail` unlike `tr ... | head`.
rand_alnum() {
  local s
  s="$(head -c 256 /dev/urandom | tr -dc 'a-zA-Z0-9')"
  printf '%s' "${s:0:$1}"
}

json_array_or_empty() {
  local name="$1" value="${2:-}"
  [[ -z "$value" ]] && return 0
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$value" \
    || die "$name must be a JSON array"
}

json_array_or_empty SAS_CLUSTERS_JSON "${SAS_CLUSTERS_JSON:-}"
json_array_or_empty SAS_ADMINS_JSON "${SAS_ADMINS_JSON:-}"

config="${SAS_CONFIG_FILE:-/opt/fmo-data/sas/config.json}"
config_dir="$(dirname "$config")"
roots_dir="${SAS_ROOTS_DIR:-/opt/fmo-data/sas/roots}"
ensure_dir_writable "$config_dir"
ensure_dir_writable "$roots_dir"

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

# FAS autoconfig part 1: prepare the API key BEFORE EMQX starts, so EMQX
# picks it up via api_key.bootstrap_file at boot. (FAS_AUTOCONFIG=1 only.)
fas_pid=""
fas_api_key=""
fas_api_secret=""
if [[ "${FAS_ENABLED:-1}" == "1" && "${FAS_AUTOCONFIG:-1}" == "1" ]]; then
  # Keep the key inside the FAS data dir so all persistent state lives
  # under the three mountable volumes (emqx data / sas / fas).
  keyfile="${EMQX_MONITOR_DB:-/opt/fmo-data/fas/fmo-audit-service.db}"
  keyfile="$(dirname "$keyfile")/emqx-api-key"
  if [[ -n "${FAS_EMQX_API_KEY:-}" || -n "${FAS_EMQX_API_SECRET:-}" ]]; then
    [[ -n "${FAS_EMQX_API_KEY:-}" && -n "${FAS_EMQX_API_SECRET:-}" ]] \
      || die "FAS_EMQX_API_KEY and FAS_EMQX_API_SECRET must be set together"
    if ! [[ -s "$keyfile" && "$(cat "$keyfile")" == "${FAS_EMQX_API_KEY}:${FAS_EMQX_API_SECRET}" ]]; then
      umask 077
      printf '%s:%s\n' "$FAS_EMQX_API_KEY" "$FAS_EMQX_API_SECRET" > "$keyfile"
      umask 022
    fi
  elif [[ ! -s "$keyfile" ]]; then
    fas_api_key="fmofas$(rand_alnum 16)"
    fas_api_secret="$(rand_alnum 32)"
    umask 077
    printf '%s:%s\n' "$fas_api_key" "$fas_api_secret" > "$keyfile"
    umask 022
    log "generated EMQX API key for FAS: $fas_api_key (stored in $keyfile)"
  fi
  fas_api_key="$(cut -d: -f1 "$keyfile")"
  fas_api_secret="$(cut -d: -f2 "$keyfile")"
  export EMQX_API_KEY__BOOTSTRAP_FILE="$keyfile"
fi

# Compose-friendly dashboard credential names for plain `docker run`:
# .env/compose use EMQX_DASHBOARD_PASSWORD / _USERNAME, while EMQX itself
# only reads EMQX_DASHBOARD__DEFAULT_PASSWORD / _USERNAME (effective at the
# FIRST initialization of the EMQX data dir only).
if [[ -z "${EMQX_DASHBOARD__DEFAULT_PASSWORD:-}" && -n "${EMQX_DASHBOARD_PASSWORD:-}" ]]; then
  export EMQX_DASHBOARD__DEFAULT_PASSWORD="$EMQX_DASHBOARD_PASSWORD"
fi
if [[ -z "${EMQX_DASHBOARD__DEFAULT_USERNAME:-}" && -n "${EMQX_DASHBOARD_USERNAME:-}" ]]; then
  export EMQX_DASHBOARD__DEFAULT_USERNAME="$EMQX_DASHBOARD_USERNAME"
fi

log "starting EMQX"
/usr/bin/docker-entrypoint.sh emqx foreground &
emqx_pid=$!

# ---------------------------------------------------------------------------
# FAS autoconfiguration.
# The released FAS binary ignores EMQX_MONITOR_WEBHOOK_URL in --configure and
# always auto-detects the container IP, so the EMQX-side webhook/rule must be
# refreshed after every boot. Flow:
#   * fresh DB  : run --configure BEFORE starting FAS (service then starts
#                 fully configured); the bridge verification at that moment
#                 reports "disconnected" because FAS is not listening yet -
#                 expected, it connects once FAS starts.
#   * every boot: after FAS is listening, re-run --configure once to refresh
#                 the webhook to the current container IP (self-healing) and
#                 to verify the bridge, plus initialize the admin account.
# ---------------------------------------------------------------------------
fas_run_configure() {
  EMQX_URL="http://127.0.0.1:${EMQX_DASHBOARD_PORT:-18083}" \
  EMQX_API_KEY="$fas_api_key" \
  EMQX_API_SECRET="$fas_api_secret" \
  EMQX_MONITOR_DB="$EMQX_MONITOR_DB" \
  /opt/fmo-fas/fmo-audit-service --configure 2>&1
}

fas_wait_emqx() {
  local emqx_mgmt="http://127.0.0.1:${EMQX_DASHBOARD_PORT:-18083}/api/v5/clients?limit=1"
  for _ in $(seq 1 120); do
    if curl -sf --max-time 2 -u "$fas_api_key:$fas_api_secret" -o /dev/null "$emqx_mgmt"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

fas_wait_service() {
  for _ in $(seq 1 90); do
    if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:${EMQX_MONITOR_PORT:-9527}/api/status"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

fas_admin_setup() {
  # Initialize the admin account once (idempotent - skipped when the
  # FAS database already has an admin).
  local user="${FAS_ADMIN_USERNAME:-admin}"
  local pass="${FAS_ADMIN_PASSWORD:-}"
  local generated=0
  if [[ -z "$pass" ]]; then
    pass="$(rand_alnum 16)"
    generated=1
  fi
  local body=/tmp/fmo-fas-status.json
  local need_setup=false
  rm -f "$body"
  if curl -s --max-time 5 -o "$body" "http://127.0.0.1:${EMQX_MONITOR_PORT:-9527}/api/status" \
     && [[ -s "$body" ]] && grep -q '系统未初始化' "$body"; then
    need_setup=true
  fi
  [[ "$need_setup" == "true" ]] || return 0
  local resp
  resp="$(curl -s --max-time 5 -X POST "http://127.0.0.1:${EMQX_MONITOR_PORT:-9527}/api/setup" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$user\",\"password\":\"$pass\"}" || true)"
  if printf '%s' "$resp" | grep -q '"ok":true'; then
    if [[ "$generated" == "1" ]]; then
      local pwfile
      pwfile="$(dirname "${EMQX_MONITOR_DB:-/opt/fmo-data/fas/fmo-audit-service.db}")/admin-password.txt"
      umask 077
      printf '%s\n' "$pass" > "$pwfile"
      umask 022
      log "FAS admin created: username=$user password=$pass (also saved to $pwfile)"
    else
      log "FAS admin created: username=$user (password from FAS_ADMIN_PASSWORD)"
    fi
  else
    log "FAS admin setup skipped: $resp"
  fi
}

fas_post_start() {
  # Background job after FAS starts: admin setup + webhook refresh/verify.
  if ! fas_wait_service; then
    log "WARNING: FAS not listening within 90s, autoconfig skipped"
    return 0
  fi
  fas_admin_setup
  if [[ "${FAS_AUTOCONFIG:-1}" == "1" && -n "$fas_api_key" ]]; then
    if ! fas_wait_emqx; then
      log "WARNING: EMQX API not ready in 120s, webhook refresh skipped"
      return 0
    fi
    local out
    if out="$(fas_run_configure)"; then
      log "FAS bridge ready (webhook refreshed to current container IP)"
    else
      log "WARNING: FAS bridge verification failed:"
      printf '%s\n' "$out" | sed 's/^/[fmo]   /'
    fi
  fi
}

if [[ "${FAS_ENABLED:-1}" == "1" ]]; then
  [[ -x /opt/fmo-fas/fmo-audit-service ]] || die "FAS binary not found at /opt/fmo-fas/fmo-audit-service"
  export EMQX_MONITOR_PORT="${EMQX_MONITOR_PORT:-9527}"
  export EMQX_MONITOR_DB="${EMQX_MONITOR_DB:-/opt/fmo-data/fas/fmo-audit-service.db}"
  # Honored by newer FAS builds in --configure (stable loopback address).
  # The currently released 2.0.22 binary ignores it and auto-detects the
  # container IP instead; fas_post_start refreshes that every boot.
  export EMQX_MONITOR_WEBHOOK_URL="${EMQX_MONITOR_WEBHOOK_URL:-http://127.0.0.1:${EMQX_MONITOR_PORT}/api/ingest}"
  export DOTNET_RUNNING_IN_CONTAINER="${DOTNET_RUNNING_IN_CONTAINER:-true}"
  # FAS is behind our nginx when WEB_ENABLED=1: trust X-Forwarded-For so the
  # login lockout sees real client IPs. nginx overwrites that header with
  # $remote_addr, so it cannot be spoofed. With WEB_ENABLED=0 (direct access)
  # keep FAS's secure default (TCP peer IP, ignore the header).
  if [[ "${WEB_ENABLED:-1}" == "1" ]]; then
    export EMQX_MONITOR_TRUST_PROXY="${EMQX_MONITOR_TRUST_PROXY:-1}"
  fi
  ensure_dir_writable "$(dirname "$EMQX_MONITOR_DB")"

  if [[ "${FAS_AUTOCONFIG:-1}" == "1" && -n "$fas_api_key" && ! -f "$EMQX_MONITOR_DB" ]]; then
    # First boot: save connection config before the service starts. The
    # bridge check will report disconnected (FAS not up yet) - the post-start
    # job reconnects/verifies it a few seconds later.
    log "first boot: waiting for EMQX API (up to 120s)"
    if fas_wait_emqx; then
      out="$(fas_run_configure)" || true
      if printf '%s' "$out" | grep -q '已保存连接配置'; then
        log "FAS connection config saved (bridge connects once FAS is up)"
      else
        log "WARNING: FAS autoconfigure failed, FAS starts unconfigured:"
        printf '%s\n' "$out" | sed 's/^/[fmo]   /'
      fi
    else
      log "WARNING: EMQX API not ready in 120s, skipping first-boot FAS autoconfigure"
    fi
  fi

  log "starting FAS on :${EMQX_MONITOR_PORT} (db=$EMQX_MONITOR_DB)"
  /opt/fmo-fas/fmo-audit-service &
  fas_pid=$!
  if [[ "${FAS_AUTOCONFIG:-1}" == "1" ]]; then
    fas_post_start &
  fi
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
