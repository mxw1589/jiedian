#!/bin/sh
# Regression test for config merge: custom SS2022 inbound and its credentials
# must survive managed protocol rebuilds; managed entries must not duplicate.
set -eu
command -v jq >/dev/null 2>&1 || { echo 'SKIP: jq not installed'; exit 0; }
new=$(mktemp); old=$(mktemp); out=$(mktemp)
trap 'rm -f "$new" "$old" "$out"' EXIT HUP INT TERM
cat >"$new" <<'JSON'
{"log":{"level":"info"},"inbounds":[{"type":"snell","tag":"snell-in","listen_port":45678}],"outbounds":[{"type":"direct","tag":"direct"}]}
JSON
cat >"$old" <<'JSON'
{"log":{"level":"debug"},"inbounds":[{"type":"shadowsocks","tag":"ss2022-custom","listen_port":12345,"method":"2022-blake3-aes-128-gcm","password":"KEEP-THIS-SECRET"},{"type":"vless","tag":"vless-reality-in","listen_port":443}],"outbounds":[{"type":"direct","tag":"direct"},{"type":"socks","tag":"user-proxy","server":"127.0.0.1","server_port":1080}],"route":{"final":"user-proxy"},"dns":{"servers":[]}}
JSON
jq -s '
  .[0] as $new | .[1] as $old |
  (["anytls-in","vless-ws-argo-in","vless-ws-tls-in","vless-reality-in","naive-in","anytls-reality-in","snell-in"] as $managed |
   $new + {
     inbounds: (($new.inbounds // []) + [($old.inbounds // [])[] | select((.tag // "") as $t | ($managed | index($t)) == null)]),
     outbounds: (($new.outbounds // []) + [($old.outbounds // [])[] | select((.tag // "") != "direct")])
   } + (($old | to_entries | map(select(.key as $k | (["log","inbounds","outbounds"] | index($k)) == null and ($new | has($k) | not))) | from_entries))
  )' "$new" "$old" > "$out"
jq -e '
  ([.inbounds[] | select(.tag=="ss2022-custom" and .listen_port==12345 and .password=="KEEP-THIS-SECRET")] | length)==1 and
  ([.inbounds[] | select(.tag=="snell-in")] | length)==1 and
  ([.inbounds[] | select(.tag=="vless-reality-in")] | length)==0 and
  ([.outbounds[] | select(.tag=="user-proxy")] | length)==1 and
  .route.final=="user-proxy" and (.dns.servers|length)==0
' "$out" >/dev/null
echo 'PASS: SS2022 inbound credentials, custom outbound, route and DNS preserved; managed stale inbound replaced.'
