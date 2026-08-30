#!/usr/bin/env bash
set -Eeuo pipefail

config="${SAS_CONFIG_FILE:-/opt/fmo-data/sas/config.json}"
mkdir -p "$(dirname "$config")"

if [[ ! -f "$config" ]] && {
  [[ -z "${SAS_SERVER_UID:-}" ]] ||
  [[ -z "${SAS_SERVER_CALLSIGN:-}" ]] ||
  [[ -z "${SAS_MQTT_HOST:-}" ]] ||
  [[ -z "${SAS_CERT_FINGERPRINT:-}" ]]
}; then
  echo "first start requires SAS_SERVER_UID, SAS_SERVER_CALLSIGN, SAS_MQTT_HOST and SAS_CERT_FINGERPRINT" >&2
  exit 64
fi

sas_args=(--config "$config")
[[ -n "${SAS_SERVER_UID:-}" ]] && sas_args+=(--server-uid "$SAS_SERVER_UID")
[[ -n "${SAS_SERVER_CALLSIGN:-}" ]] && sas_args+=(--server-callsign "$SAS_SERVER_CALLSIGN")
[[ -n "${SAS_MQTT_HOST:-}" ]] && sas_args+=(--mqtt-host "$SAS_MQTT_HOST")
[[ -n "${SAS_MQTT_PORT:-}" ]] && sas_args+=(--mqtt-port "$SAS_MQTT_PORT")
[[ -n "${SAS_CERT_FINGERPRINT:-}" ]] && sas_args+=(--cert-fingerprint "$SAS_CERT_FINGERPRINT")
sas_args+=(--http-addr "${SAS_HTTP_ADDR:-127.0.0.1}")
sas_args+=(--http-port "${SAS_HTTP_PORT:-8080}")

/opt/fmo-sas/sas "${sas_args[@]}" &
sas_pid=$!

/usr/bin/docker-entrypoint.sh emqx foreground &
emqx_pid=$!

stop_all() {
  kill -TERM "$sas_pid" "$emqx_pid" 2>/dev/null || true
  wait "$sas_pid" 2>/dev/null || true
  wait "$emqx_pid" 2>/dev/null || true
}

trap stop_all TERM INT

set +e
wait -n "$sas_pid" "$emqx_pid"
rc=$?
set -e

stop_all
exit "$rc"
