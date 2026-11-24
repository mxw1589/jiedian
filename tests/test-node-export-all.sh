#!/bin/sh
# Exercise every node-export branch, including direct WS, Reality, XHTTP/ECH, SS2022 and Snell.
set -eu
command -v jq >/dev/null 2>&1 || { echo 'SKIP: jq not installed'; exit 0; }
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/sb-manager-debian-alpine.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
cat >"$TMP/run.sh" <<'STUBS'
#!/bin/sh
set -eu
APP_DIR=$1
ORIGIN_ADDR=203.0.113.10
ORIGIN_IPV6=2001:db8::10
PREFERRED_IP=203.0.113.10
NODE_LABEL=dual
WS_SERVER=203.0.113.8
WS_PATH=/ws-test
WS_MODE=direct
ARGO_HOST=argo.example.com
ENABLE_ANYTLS=1
ENABLE_WS_TLS=1
ENABLE_VLESS_REALITY=1
ENABLE_NAIVE=1
ENABLE_ANYTLS_REALITY=1
ENABLE_XHTTP=1
ENABLE_SNELL=1
ENABLE_SS2022=1
ANYTLS_PORT=4433
WS_PORT=24442
REALITY_PORT=4434
NAIVE_PORT=4435
ANYREALITY_PORT=4436
XHTTP_PORT=4437
SNELL_PORT=4438
SS2022_PORT=4439
SNELL_VERSION=5
SNELL_PSK=snell-psk
SNELL_USERKEY=snell-user
SNELL_OBFS_MODE=http
SNELL_OBFS_HOST=www.bing.com
SNELL_MODE=default
SS2022_METHOD=2022-blake3-aes-256-gcm
SS2022_PASSWORD=abcdefghijklmnopqrstuvwxyz0123456789ABCD
TLS_DOMAIN=ws.example.com
WS_HOST=ws.example.com
WS_UUID=550e8400-e29b-41d4-a716-446655440000
REALITY_UUID=550e8400-e29b-41d4-a716-446655440001
REALITY_SNI=www.bing.com
REALITY_PUBLIC=public-reality-key
REALITY_SID=abcd1234
ANYTLS_PASSWORD=anytls-password
ANYREALITY_PASSWORD=anyreality-password
ANYREALITY_PUBLIC=public-anyreality-key
ANYREALITY_SID=efgh5678
NAIVE_USERNAME=naive-user
NAIVE_PASSWORD=naive-password
XHTTP_UUID=550e8400-e29b-41d4-a716-446655440002
XHTTP_PATH=/xhttp/test
XHTTP_MODE=auto
XRAY_ECH_CONFIG_FILE="$APP_DIR/ech.txt"
XRAY_CLIENT_CONFIG_FILE="$APP_DIR/xray-client.json"
SNELL_CLIENT_CONFIG_FILE="$APP_DIR/snell-client.json"
printf 'ech-config-test\n' > "$XRAY_ECH_CONFIG_FILE"
msg() { :; }
uri_host() { case "$1" in *:*) printf '[%s]' "$1" ;; *) printf '%s' "$1" ;; esac; }
write_anyreality_client_json() { printf '{}\n' > "$APP_DIR/anyreality.json"; }
write_xhttp_client_json() { printf '{}\n' > "$XRAY_CLIENT_CONFIG_FILE"; }
write_snell_client_json() { printf '{}\n' > "$SNELL_CLIENT_CONFIG_FILE"; }
STUBS
sed -n '/^node_tag() {/,/^}/p' "$SCRIPT" >> "$TMP/run.sh"
sed -n '/^node_tag_single() {/,/^}/p' "$SCRIPT" >> "$TMP/run.sh"
sed -n '/^show_nodes() {/,/^}/p' "$SCRIPT" >> "$TMP/run.sh"
cat >>"$TMP/run.sh" <<'RUN'
show_nodes
cp "$APP_DIR/nodes-ipv4.txt" "$APP_DIR/test-nodes-ipv4.txt"
cp "$APP_DIR/nodes-ipv6.txt" "$APP_DIR/test-nodes-ipv6.txt"
cp "$APP_DIR/nodes-domain.txt" "$APP_DIR/test-nodes-domain.txt"
# Re-render only WS through an Argo tunnel, using a Cloudflare edge IP as the client address.
ENABLE_ANYTLS=0; ENABLE_WS_TLS=1; ENABLE_VLESS_REALITY=0; ENABLE_NAIVE=0
ENABLE_ANYTLS_REALITY=0; ENABLE_XHTTP=0; ENABLE_SNELL=0; ENABLE_SS2022=0
WS_MODE=argo; ARGO_HOST=argo.example.com; WS_SERVER=198.51.100.9
WS_HOST=argo.example.com; TLS_DOMAIN=
show_nodes
RUN
chmod +x "$TMP/run.sh"
sh "$TMP/run.sh" "$TMP" > "$TMP/output.txt"
APP_DIR="$TMP"
# First render: all protocols, IPv4 and IPv6 formatting, URI schemes, and ECH hint.
cp "$TMP/output.txt" "$TMP/all-output.txt"
grep -Fq 'anytls://anytls-password@203.0.113.10:4433/' "$TMP/all-output.txt"
grep -Fq 'anytls://anytls-password@[2001:db8::10]:4433/' "$TMP/all-output.txt"
grep -Fq 'vless://550e8400-e29b-41d4-a716-446655440000@203.0.113.8:24442' "$TMP/all-output.txt"
grep -Fq 'vless://550e8400-e29b-41d4-a716-446655440001@[2001:db8::10]:4434' "$TMP/all-output.txt"
grep -Fq 'naive+https://naive-user:naive-password@203.0.113.10:4435/' "$TMP/all-output.txt"
grep -Fq 'anytls://anyreality-password@[2001:db8::10]:4436?security=reality' "$TMP/all-output.txt"
grep -Fq 'vless://550e8400-e29b-41d4-a716-446655440002@ws.example.com:4437?encryption=none&security=tls' "$TMP/all-output.txt"
grep -Fq 'ECH Config' "$TMP/all-output.txt"
grep -Fq 'ss://' "$TMP/all-output.txt"
grep -Fq 'Snell v5' "$TMP/all-output.txt"
grep -Fq 'ipv6-2001:db8::10-dual-snell' "$TMP/all-output.txt"
# Family-specific files must be compact, correctly grouped and copy-ready.
IPV4="$APP_DIR/test-nodes-ipv4.txt"; IPV6="$APP_DIR/test-nodes-ipv6.txt"; DOMAIN="$APP_DIR/test-nodes-domain.txt"
grep -Fq 'anytls://anytls-password@203.0.113.10:4433/' "$IPV4"
grep -Fq 'vless://550e8400-e29b-41d4-a716-446655440000@203.0.113.8:24442' "$IPV4"
grep -Fq 'ipv4-203.0.113.10-dual-ss2022' "$IPV4"
! grep -Fq '2001:db8::10' "$IPV4"
grep -Fq 'anytls://anytls-password@[2001:db8::10]:4433/' "$IPV6"
grep -Fq 'vless://550e8400-e29b-41d4-a716-446655440001@[2001:db8::10]:4434' "$IPV6"
grep -Fq 'ipv6-2001%3Adb8%3A%3A10-dual-ss2022' "$IPV6"
! grep -Fq '@203.0.113.10:' "$IPV6"
grep -Fq 'vless://550e8400-e29b-41d4-a716-446655440002@ws.example.com:4437' "$DOMAIN"
# Every exported node is one physical line (compact list, not prose blocks).
[ "$(wc -l < "$IPV4")" -ge 6 ]
[ "$(wc -l < "$IPV6")" -ge 5 ]
! grep -Fq '地址：' "$APP_DIR/test-nodes-ipv4.txt"
! grep -Fq '地址：' "$APP_DIR/test-nodes-ipv6.txt"
! grep -vE '^(anytls|vless|naive\+https|ss)://' "$IPV4"
! grep -vE '^(anytls|vless|naive\+https|ss)://' "$IPV6"
grep -Fq 'Snell v5 [2001:db8::10]:4438' "$TMP/all-output.txt"
grep -Fq 'Snell v5 203.0.113.10:4438' "$TMP/all-output.txt"
# Second render: Argo client-side port, SNI and Host must use the fixed tunnel hostname.
NODES="$TMP/nodes.txt"
grep -Fq 'vless://550e8400-e29b-41d4-a716-446655440000@198.51.100.9:443?encryption=none&security=tls&sni=argo.example.com&type=ws&host=argo.example.com' "$NODES"
[ ! -s "$APP_DIR/nodes-ipv6.txt" ]
[ ! -s "$APP_DIR/nodes-domain.txt" ]
[ "$(wc -l < "$APP_DIR/nodes-ipv4.txt")" -eq 1 ]
echo 'PASS: all legacy manager node exporters render direct/Argo WS, Reality, AnyTLS, Naive, XHTTP/ECH, SS2022 and Snell correctly.'
