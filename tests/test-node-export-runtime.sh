#!/bin/sh
# Exercise show_nodes with only SS2022 + Snell enabled and both IP families.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/sb-manager-debian-alpine.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
cat > "$TMP/run.sh" <<'STUBS'
#!/bin/sh
set -eu
APP_DIR=$1
ORIGIN_ADDR=203.0.113.10
ORIGIN_IPV6=2001:db8::10
NODE_LABEL=dual
WS_SERVER=
WS_PATH=
WS_MODE=direct
ARGO_HOST=
ENABLE_ANYTLS=0
ENABLE_WS_TLS=0
ENABLE_VLESS_REALITY=0
ENABLE_NAIVE=0
ENABLE_ANYTLS_REALITY=0
ENABLE_XHTTP=0
ENABLE_SNELL=1
ENABLE_SS2022=1
ANYTLS_PORT=
WS_PORT=
REALITY_PORT=
NAIVE_PORT=
ANYREALITY_PORT=
XHTTP_PORT=
SNELL_PORT=23456
SNELL_VERSION=6
SNELL_PSK=snell-psk
SNELL_USERKEY=snell-user
SNELL_MODE=default
SS2022_PORT=23457
SS2022_METHOD=2022-blake3-aes-256-gcm
SS2022_PASSWORD=abcdefghijklmnopqrstuvwxyz0123456789ABCD
TLS_DOMAIN=
WS_HOST=
WS_UUID=
REALITY_UUID=
REALITY_SNI=
ANYTLS_PASSWORD=
ANYREALITY_PASSWORD=
ANYREALITY_PUBLIC=
ANYREALITY_SID=
NAIVE_USERNAME=
NAIVE_PASSWORD=
XHTTP_UUID=
XHTTP_PATH=
XHTTP_MODE=auto
XRAY_ECH_CONFIG_FILE=
XRAY_CLIENT_CONFIG_FILE=
SNELL_CLIENT_CONFIG_FILE="$APP_DIR/snell-client.json"
msg() { :; }
uri_host() { case "$1" in *:*) printf '[%s]' "$1" ;; *) printf '%s' "$1" ;; esac; }
node_tag() { family_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); address=$2; protocol=$3; tag="$family_lc-$address"; [ -z "$NODE_LABEL" ] || tag="$tag-$NODE_LABEL"; printf '%s-%s' "$tag" "$protocol"; }
write_anyreality_client_json() { return 0; }
write_xhttp_client_json() { return 0; }
write_snell_client_json() { : > "$SNELL_CLIENT_CONFIG_FILE"; }
STUBS
sed -n '/^show_nodes() {/,/^}/p' "$SCRIPT" >> "$TMP/run.sh"
printf '\nshow_nodes\n' >> "$TMP/run.sh"
chmod +x "$TMP/run.sh"
sh "$TMP/run.sh" "$TMP" > "$TMP/output.txt"
NODES="$TMP/nodes.txt"
grep -Fq 'ipv4-203.0.113.10-dual-ss2022' "$NODES"
grep -Fq 'ipv6-2001%3Adb8%3A%3A10-dual-ss2022' "$NODES"
grep -Fq 'ipv4-203.0.113.10-dual-snell' "$NODES"
grep -Fq 'ipv6-2001:db8::10-dual-snell' "$NODES"
if grep -Fq '没有启用任何协议' "$NODES"; then echo 'FAIL: SS2022/Snell-only configuration was marked empty.' >&2; exit 1; fi
echo 'PASS: SS2022-only/Snell-only dual-stack node export prints IPv4 and IPv6 entries.'
