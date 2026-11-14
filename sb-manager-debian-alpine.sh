#!/bin/sh
# sing-box multi-protocol manager for Debian + Alpine
# AnyTLS + VLESS/WS/TLS + VLESS/Reality
# Randomized collision-checked ports; Cloudflare DNS-01, HTTP-01, or manual TLS certs
set -eu

APP_DIR=/etc/sing-box
STATE_FILE="$APP_DIR/manager.json"
CONFIG_FILE="$APP_DIR/config.json"
CERT_DIR="$APP_DIR/cert"
CERT_FILE="$CERT_DIR/fullchain.pem"
KEY_FILE="$CERT_DIR/privkey.pem"
CF_TOKEN_FILE="$APP_DIR/cloudflare.token"
CF_ZONE_ID_FILE="$APP_DIR/cloudflare-zone-id"
RELOAD_HOOK=/usr/local/sbin/sing-box-cert-reload
SB_BIN="$(command -v sing-box 2>/dev/null || printf /usr/bin/sing-box)"
OS_FAMILY=""
SERVICE_KIND=""

msg() { printf '\n%s\n' "$*"; }
err() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
warn() { printf '[警告] %s\n' "$*" >&2; }
need_root() { [ "$(id -u)" -eq 0 ] || err '请使用 root 运行。'; }

valid_domain() {
    v=$1
    [ -n "$v" ] || return 1
    [ "${#v}" -le 253 ] || return 1
    case "$v" in *[!A-Za-z0-9.-]*|.*|*..*|*.) return 1 ;; esac
    case "$v" in *-.*|*.-* ) return 1 ;; esac
    printf '%s\n' "$v" | awk -F. 'NF >= 2 { for (i=1;i<=NF;i++) if (length($i)<1 || length($i)>63 || $i ~ /^-/ || $i ~ /-$/) exit 1; exit 0 } { exit 1 }'
}

valid_host() {
    v=$1
    [ -n "$v" ] || return 1
    [ "${#v}" -le 253 ] || return 1
    case "$v" in *[!A-Za-z0-9.:-]*|.*|*..*|*.) return 1 ;; esac
    return 0
}

valid_port() {
    p=$1
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    [ "$p" -ge 10000 ] 2>/dev/null && [ "$p" -le 65535 ] 2>/dev/null
}

valid_ws_port() {
    case "$1" in 2053|2083|2087|2096|8443) return 0 ;; *) return 1 ;; esac
}

port_listening() {
    p=$1
    ss -H -lnt 2>/dev/null | awk -v suffix=":$p" '$4 ~ (suffix "$") {found=1} END {exit !found}'
}

random_between() {
    min=$1
    max=$2
    span=$((max - min + 1))
    random_value=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d '[:space:]')
    case "$random_value" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$((min + (random_value % span)))"
}

port_is_available() {
    candidate=$1
    shift
    for blocked in "$@"; do
        [ -n "$blocked" ] || continue
        [ "$candidate" = "$blocked" ] && return 1
    done
    port_listening "$candidate" && return 1
    return 0
}

pick_random_range_port() {
    min=$1
    max=$2
    shift 2
    tries=0
    while [ "$tries" -lt 1000 ]; do
        candidate=$(random_between "$min" "$max") || return 1
        if port_is_available "$candidate" "$@"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        tries=$((tries + 1))
    done
    return 1
}

pick_random_ws_port() {
    tries=0
    while [ "$tries" -lt 100 ]; do
        index=$(random_between 1 5) || return 1
