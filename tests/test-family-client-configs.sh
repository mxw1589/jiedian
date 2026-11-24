#!/bin/sh
set -eu
command -v jq >/dev/null 2>&1 || { echo 'SKIP: jq not installed'; exit 0; }
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/sb-manager-debian-alpine.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
cat > "$TMP/run.sh" <<'STUBS'
#!/bin/sh
set -eu
APP_DIR=$1
chown() { :; } # avoid requiring root in the isolated JSON-generation test
ORIGIN_ADDR=203.0.113.10
ORIGIN_IPV6=2001:db8::10
ENABLE_ANYTLS_REALITY=1
ANYREALITY_PORT=4436
ANYREALITY_PASSWORD=anyreality-password
REALITY_SNI=www.bing.com
ANYREALITY_PUBLIC=public-key
ANYREALITY_SID=abcd1234
ENABLE_SNELL=1
SNELL_PORT=4438
SNELL_VERSION=5
SNELL_PSK=snell-psk
SNELL_USERKEY=snell-user
SNELL_OBFS_MODE=http
SNELL_OBFS_HOST=www.bing.com
SNELL_MODE=default
SNELL_CLIENT_CONFIG_FILE="$APP_DIR/snell-client.json"
STUBS
sed -n '/^write_anyreality_client_json_for() {/,/^}/p' "$SCRIPT" >> "$TMP/run.sh"
sed -n '/^write_anyreality_client_json() {/,/^}/p' "$SCRIPT" >> "$TMP/run.sh"
sed -n '/^write_snell_client_json_for() {/,/^}/p' "$SCRIPT" >> "$TMP/run.sh"
sed -n '/^write_snell_client_json() {/,/^}/p' "$SCRIPT" >> "$TMP/run.sh"
cat >> "$TMP/run.sh" <<'RUN'
write_anyreality_client_json
write_snell_client_json
RUN
chmod +x "$TMP/run.sh"
sh "$TMP/run.sh" "$TMP"
for f in anytls-reality-client-ipv4.json snell-client-ipv4.json; do
  [ -s "$TMP/$f" ]
  jq -e '.server == "203.0.113.10"' "$TMP/$f" >/dev/null
done
for f in anytls-reality-client-ipv6.json snell-client-ipv6.json; do
  [ -s "$TMP/$f" ]
  jq -e '.server == "2001:db8::10"' "$TMP/$f" >/dev/null
done
jq -e '.server == "203.0.113.10"' "$TMP/snell-client.json" >/dev/null
[ "$(stat -c '%a' "$TMP/snell-client-ipv4.json" 2>/dev/null || stat -f '%Lp' "$TMP/snell-client-ipv4.json")" = 600 ]
# Re-run as IPv6-only and ensure stale IPv4 files are removed.
cat >> "$TMP/run.sh" <<'RUN6'
ORIGIN_ADDR=
write_anyreality_client_json
write_snell_client_json
RUN6
sh "$TMP/run.sh" "$TMP"
[ ! -e "$TMP/anytls-reality-client-ipv4.json" ]
[ ! -e "$TMP/snell-client-ipv4.json" ]
jq -e '.server == "2001:db8::10"' "$TMP/anytls-reality-client-ipv6.json" >/dev/null
jq -e '.server == "2001:db8::10"' "$TMP/snell-client-ipv6.json" >/dev/null
echo 'PASS: Snell and AnyTLS Reality client JSON files are emitted separately for IPv4 and IPv6.'
