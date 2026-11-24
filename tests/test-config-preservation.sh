#!/bin/sh
# Regression tests for preserving custom SS2022 and adopting it without loss.
set -eu
command -v jq >/dev/null 2>&1 || { echo 'SKIP: jq not installed'; exit 0; }
new=$(mktemp); old=$(mktemp); out=$(mktemp); filter=$(mktemp)
trap 'rm -f "$new" "$old" "$out" "$filter"' EXIT HUP INT TERM
cat >"$filter" <<'JQ'
.[0] as $new | .[1] as $old |
((["anytls-in","vless-ws-argo-in","vless-ws-tls-in","vless-reality-in","naive-in","anytls-reality-in","snell-in"] + (if $manage_ss2022 or any(($new.inbounds // [])[]; .tag == "ss2022-in") then ["ss2022-in"] else [] end)) as $managed |
 $new + {
  inbounds: (($new.inbounds // []) + [($old.inbounds // [])[] | select(
    ((.tag // "") as $t | ($managed | index($t)) == null) and
    (if any(($new.inbounds // [])[]; .tag == "ss2022-in") then
      ((.type != "shadowsocks") or ((.method // "" | startswith("2022-blake3-") | not)) or (.listen_port != (($new.inbounds // [])[] | select(.tag == "ss2022-in") | .listen_port)))
     else true end)
  )]),
  outbounds: (($new.outbounds // []) + [($old.outbounds // [])[] | select((.tag // "") != "direct")])
 } + (($old | to_entries | map(select(.key as $k | (["log","inbounds","outbounds"] | index($k)) == null and ($new | has($k) | not))) | from_entries))
)
JQ
cat >"$new" <<'JSON'
{"log":{"level":"info"},"inbounds":[{"type":"snell","tag":"snell-in","listen_port":45678}],"outbounds":[{"type":"direct","tag":"direct"}]}
JSON
cat >"$old" <<'JSON'
{"log":{"level":"debug"},"inbounds":[{"type":"shadowsocks","tag":"ss2022-custom","listen_port":12345,"method":"2022-blake3-aes-128-gcm","password":"KEEP-THIS-SECRET"},{"type":"vless","tag":"custom-vless","listen_port":443}],"outbounds":[{"type":"direct","tag":"direct"},{"type":"socks","tag":"user-proxy","server":"127.0.0.1","server_port":1080}],"route":{"final":"user-proxy"},"dns":{"servers":[]}}
JSON
jq -s --argjson manage_ss2022 false -f "$filter" "$new" "$old" >"$out"
jq -e '([.inbounds[]|select(.tag=="ss2022-custom" and .listen_port==12345 and .password=="KEEP-THIS-SECRET")]|length)==1 and ([.inbounds[]|select(.tag=="custom-vless")]|length)==1 and ([.inbounds[]|select(.tag=="snell-in")]|length)==1 and ([.outbounds[]|select(.tag=="user-proxy")]|length)==1 and .route.final=="user-proxy"' "$out" >/dev/null
# When SS2022 is explicitly adopted at the same port, replace the legacy copy once.
cat >"$new" <<'JSON'
{"log":{"level":"info"},"inbounds":[{"type":"shadowsocks","tag":"ss2022-in","listen_port":12345,"method":"2022-blake3-aes-128-gcm","password":"KEEP-THIS-SECRET"}],"outbounds":[{"type":"direct","tag":"direct"}]}
JSON
jq -s --argjson manage_ss2022 true -f "$filter" "$new" "$old" >"$out"
jq -e '([.inbounds[]|select(.type=="shadowsocks" and .listen_port==12345 and .password=="KEEP-THIS-SECRET")]|length)==1' "$out" >/dev/null
# When the manager previously owned ss2022-in, deleting it must remove it.
cat >"$new" <<'JSON'
{"log":{"level":"info"},"inbounds":[{"type":"snell","tag":"snell-in","listen_port":45678}],"outbounds":[{"type":"direct","tag":"direct"}]}
JSON
cat >"$old" <<'JSON'
{"inbounds":[{"type":"shadowsocks","tag":"ss2022-in","listen_port":12345,"method":"2022-blake3-aes-256-gcm","password":"managed-key"}]}
JSON
jq -s --argjson manage_ss2022 true -f "$filter" "$new" "$old" >"$out"
jq -e '([.inbounds[]|select(.tag=="ss2022-in")]|length)==0 and ([.inbounds[]|select(.tag=="snell-in")]|length)==1' "$out" >/dev/null
echo 'PASS: unmanaged SS2022 preserved; existing SS2022 adoption replaces duplicate; managed SS2022 removal works.' 
