#!/bin/sh
# sing-box multi-protocol manager for Debian + Alpine
# AnyTLS + VLESS/WS/TLS + VLESS/Reality
# Random high-port allocation with occupied-port detection and retry
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

# 检查 TCP 监听端口。ss 的本地地址可能是 IPv4、IPv6 或通配地址。
port_listening() {
    p=$1
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null | awk -v p="$p" '{a=$4; sub(/^.*:/,"",a); if (a==p) found=1} END {exit !found}'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk -v p="$p" '{a=$4; sub(/^.*:/,"",a); if (a==p) found=1} END {exit !found}'
    else
        # 安装流程会安装 iproute2；没有 ss/netstat 时采取保守策略。
        return 1
    fi
}

port_in_list() {
    needle=" $1 "
    haystack=" ${2-} "
    case "$haystack" in *"$needle"*) return 0 ;; *) return 1 ;; esac
}

random_u32() {
    n=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
    case "$n" in ''|*[!0-9]*) n=$(date +%s) ;; esac
    printf '%s\n' "$n"
}

candidate_port_free() {
    p=$1
    if port_in_list "$p" "${EXCLUDE_PORTS-} ${USED_PORTS-}"; then return 1; fi
    if port_listening "$p"; then return 1; fi
    return 0
}

pick_random_port_range() {
    low=$1
    high=$2
    span=$((high - low + 1))
    tries=0
    while [ "$tries" -lt 1200 ]; do
        n=$(random_u32)
        candidate=$((low + n % span))
        if candidate_port_free "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        tries=$((tries + 1))
    done
    return 1
}

pick_random_ws_port() {
    # Cloudflare 默认代理的 HTTPS 端口；均高于 1024。
    available=""
    for p in 2053 2083 2087 2096 8443; do
        if candidate_port_free "$p"; then available="$available $p"; fi
    done
    set -- $available
    count=$#
    [ "$count" -gt 0 ] || return 1
    n=$(random_u32)
    wanted=$((n % count + 1))
    i=1
    for p do
        if [ "$i" -eq "$wanted" ]; then
            printf '%s\n' "$p"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

choose_random_ports() {
    EXCLUDE_PORTS="${PREVIOUS_PORTS-}"
    USED_PORTS=""
    ANYTLS_PORT=$(pick_random_port_range 10000 65535) || err '没有找到可用的 AnyTLS 高位 TCP 端口。'
    USED_PORTS="$USED_PORTS $ANYTLS_PORT"
    WS_PORT=$(pick_random_ws_port) || err 'Cloudflare 支持的 HTTPS 高位端口均不可用，无法分配 WS TLS 端口。'
    USED_PORTS="$USED_PORTS $WS_PORT"
    REALITY_PORT=$(pick_random_port_range 10000 65535) || err '没有找到可用的 Reality 高位 TCP 端口。'
    USED_PORTS="$USED_PORTS $REALITY_PORT"
    [ "$ANYTLS_PORT" != "$WS_PORT" ] && [ "$ANYTLS_PORT" != "$REALITY_PORT" ] && [ "$WS_PORT" != "$REALITY_PORT" ] || err '随机端口发生重复，请重试。'
    msg "随机端口分配完成：AnyTLS=$ANYTLS_PORT / WS-TLS=$WS_PORT / Reality=$REALITY_PORT"
}

uri_host() {
    case "$1" in *:*) printf '[%s]' "$1" ;; *) printf '%s' "$1" ;; esac
}

ask_value() {
    prompt=$1
    default=${2-}
    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$prompt" "$default"
    else
        printf '%s: ' "$prompt"
    fi
    IFS= read -r REPLY || REPLY=""
    if [ -z "$REPLY" ]; then REPLY=$default; fi
}

install_dependencies_and_core() {
    if [ -f /etc/alpine-release ]; then
        OS_FAMILY=alpine
        msg '检测到 Alpine Linux，安装 sing-box 和依赖……'
        apk update
        apk add --no-cache ca-certificates curl jq openssl iproute2 tar gzip
        if ! apk add --no-cache sing-box; then
            warn '当前 Alpine 仓库没有 sing-box 包，尝试安装官方 Linux 发布版。'
            tag=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
            ver=${tag#v}
            case "$(uname -m)" in
                x86_64) rel_arch=amd64 ;;
                aarch64) rel_arch=arm64 ;;
                armv7l|armv7) rel_arch=armv7 ;;
                *) err "暂不支持此 Alpine CPU 架构：$(uname -m)" ;;
            esac
            archive="sing-box-${ver}-linux-${rel_arch}.tar.gz"
            curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/${tag}/${archive}" -o "/tmp/${archive}"
            mkdir -p /tmp/sing-box-unpack
            tar -xzf "/tmp/${archive}" -C /tmp/sing-box-unpack
            install -m 0755 "/tmp/sing-box-unpack/sing-box-${ver}-linux-${rel_arch}/sing-box" /usr/local/bin/sing-box
            rm -rf "/tmp/${archive}" /tmp/sing-box-unpack
        fi
        update-ca-certificates 2>/dev/null || true
    elif [ -f /etc/debian_version ]; then
        OS_FAMILY=debian
        msg '检测到 Debian，安装 sing-box 官方仓库和依赖……'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq openssl iproute2 gpg
        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
        chmod a+r /etc/apt/keyrings/sagernet.asc
        cat > /etc/apt/sources.list.d/sagernet.sources <<'APT_EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
APT_EOF
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y sing-box
    else
        err '仅支持 Debian 和 Alpine Linux。'
    fi
    command -v sing-box >/dev/null 2>&1 || err 'sing-box 安装失败。请确认系统仓库可用。'
    SB_BIN="$(command -v sing-box)"
    "$SB_BIN" version | head -n 1 || true
}

ensure_service_account() {
    if ! grep -q '^sing-box:' /etc/group 2>/dev/null; then
        if [ "$OS_FAMILY" = alpine ]; then addgroup -S sing-box; else addgroup --system sing-box; fi
    fi
    if ! grep -q '^sing-box:' /etc/passwd 2>/dev/null; then
        if [ "$OS_FAMILY" = alpine ]; then
            adduser -S -D -H -s /sbin/nologin -G sing-box sing-box
        else
            useradd --system --no-create-home --shell /usr/sbin/nologin --gid sing-box sing-box
        fi
    fi
    install -d -o root -g sing-box -m 0750 "$APP_DIR" "$CERT_DIR"
}

create_service() {
    if [ "$OS_FAMILY" = debian ] && command -v systemctl >/dev/null 2>&1; then
        SERVICE_KIND=systemd
        cat > /etc/systemd/system/sing-box.service <<EOF_SERVICE
[Unit]
Description=sing-box proxy service
Wants=network-online.target
After=network-online.target

[Service]
User=sing-box
Group=sing-box
Type=simple
ExecStart=$SB_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null
    elif command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        SERVICE_KIND=openrc
        cat > /etc/init.d/sing-box <<EOF_SERVICE
#!/sbin/openrc-run
description="sing-box proxy service"
command="$SB_BIN"
command_args="run -c $CONFIG_FILE"
command_user="sing-box:sing-box"
command_background="yes"
pidfile="/run/sing-box.pid"

depend() {
    need net
    after firewall
}
EOF_SERVICE
        chmod 0755 /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1 || true
    else
        err '未检测到可用的 systemd 或 OpenRC 服务管理器。'
    fi
}

service_restart() {
    if [ "$SERVICE_KIND" = systemd ]; then
        systemctl restart sing-box || return 1
        systemctl is-active --quiet sing-box
    elif [ "$SERVICE_KIND" = openrc ]; then
        rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1 || return 1
        sleep 1
        rc-service sing-box status >/dev/null 2>&1
    else
        err '服务管理器尚未初始化。'
    fi
}

service_status() {
    if [ "$SERVICE_KIND" = systemd ]; then
        systemctl --no-pager --full status sing-box || true
    elif [ "$SERVICE_KIND" = openrc ]; then
        rc-service sing-box status || true
    fi
}

setup_reload_hook() {
    cat > "$RELOAD_HOOK" <<'EOF_HOOK'
#!/bin/sh
set -eu
[ -f /etc/sing-box/config.json ] || exit 0
chown root:sing-box /etc/sing-box/cert /etc/sing-box/cert/privkey.pem /etc/sing-box/cert/fullchain.pem 2>/dev/null || true
chmod 750 /etc/sing-box/cert 2>/dev/null || true
chmod 640 /etc/sing-box/cert/privkey.pem 2>/dev/null || true
chmod 644 /etc/sing-box/cert/fullchain.pem 2>/dev/null || true
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl restart sing-box
elif command -v rc-service >/dev/null 2>&1; then
  rc-service sing-box restart
fi
EOF_HOOK
    chmod 0750 "$RELOAD_HOOK"
}

start_cron() {
    if [ "$OS_FAMILY" = alpine ]; then
        apk add --no-cache cronie
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y cron
        systemctl enable --now cron >/dev/null 2>&1 || true
    fi
    if command -v crontab >/dev/null 2>&1; then
        current_cron=$(crontab -l 2>/dev/null || true)
        printf '%s\n' "$current_cron" | grep -q '/root/.acme.sh/acme.sh --cron' || {
            { printf '%s\n' "$current_cron"; printf '%s\n' '17 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >/dev/null 2>&1'; } | crontab -
        }
    fi
}

install_acme() {
    if [ ! -x /root/.acme.sh/acme.sh ]; then
        msg '安装 acme.sh（用于 DNS-01 证书和自动续期）……'
        if [ -n "$1" ]; then
            curl -fsSL https://get.acme.sh | HOME=/root sh -s email="$1"
        else
            curl -fsSL https://get.acme.sh | HOME=/root sh
        fi
    fi
    [ -x /root/.acme.sh/acme.sh ] || err 'acme.sh 安装失败。'
    start_cron
}

issue_cloudflare_cert() {
    domain=$1
    [ -s "$CF_TOKEN_FILE" ] || err 'Cloudflare API Token 文件不存在。'
    token=$(cat "$CF_TOKEN_FILE")
    [ -n "$token" ] || err 'Cloudflare API Token 为空。'
    install_acme ''
    msg "通过 Cloudflare DNS-01 为 $domain 申请/更新证书……"
    zone_id=$(cat "$CF_ZONE_ID_FILE" 2>/dev/null || true)
    if [ -n "$zone_id" ]; then
        CF_Token="$token" CF_Zone_ID="$zone_id" /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null || return 1
        CF_Token="$token" CF_Zone_ID="$zone_id" /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --keylength ec-256 || return 1
        CF_Token="$token" CF_Zone_ID="$zone_id" /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
            --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" --reloadcmd "$RELOAD_HOOK" || return 1
    else
        CF_Token="$token" /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null || return 1
        CF_Token="$token" /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --keylength ec-256 || return 1
        CF_Token="$token" /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
            --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" --reloadcmd "$RELOAD_HOOK" || return 1
    fi
    chown root:sing-box "$CERT_FILE" "$KEY_FILE"
    chmod 0644 "$CERT_FILE"
    chmod 0640 "$KEY_FILE"
    check_cert_pair "$CERT_FILE" "$KEY_FILE" "$domain"
}

check_cert_pair() {
    cert=$1
    key=$2
    domain=$3
    [ -r "$cert" ] || err "证书文件不可读：$cert"
    [ -r "$key" ] || err "私钥文件不可读：$key"
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || err '证书 PEM 格式无效。'
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || err '私钥 PEM 格式无效或带有不受支持的口令。'
    openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 || err "证书不包含域名 $domain。"
    cert_pub=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')
    key_pub=$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | awk '{print $1}')
    [ "$cert_pub" = "$key_pub" ] || err '证书和私钥不匹配。'
}

install_manual_cert() {
    domain=$1
    ask_value '请输入 fullchain.pem / 证书链文件路径' ''
    src_cert=$REPLY
    ask_value '请输入 privkey.pem / 私钥文件路径' ''
    src_key=$REPLY
    check_cert_pair "$src_cert" "$src_key" "$domain"
    cp "$src_cert" "$CERT_FILE"
    cp "$src_key" "$KEY_FILE"
    chown root:sing-box "$CERT_FILE" "$KEY_FILE"
    chmod 0644 "$CERT_FILE"
    chmod 0640 "$KEY_FILE"
    CERT_MODE=manual
}

save_state() {
    tmp="$STATE_FILE.tmp.$$"
    jq -n \
      --arg origin_addr "$ORIGIN_ADDR" \
      --arg preferred_ip "$PREFERRED_IP" \
      --arg tls_domain "$TLS_DOMAIN" \
      --arg ws_host "$WS_HOST" \
      --arg reality_sni "$REALITY_SNI" \
      --arg anytls_port "$ANYTLS_PORT" \
      --arg ws_port "$WS_PORT" \
      --arg reality_port "$REALITY_PORT" \
      --arg anytls_password "$ANYTLS_PASSWORD" \
      --arg ws_uuid "$WS_UUID" \
      --arg reality_uuid "$REALITY_UUID" \
      --arg reality_private "$REALITY_PRIVATE" \
      --arg reality_public "$REALITY_PUBLIC" \
      --arg reality_sid "$REALITY_SID" \
      --arg ws_path "$WS_PATH" \
      --arg cert_file "$CERT_FILE" \
      --arg key_file "$KEY_FILE" \
      --arg cert_mode "$CERT_MODE" \
      '{origin_addr:$origin_addr,preferred_ip:$preferred_ip,tls_domain:$tls_domain,ws_host:$ws_host,reality_sni:$reality_sni,anytls_port:($anytls_port|tonumber),ws_port:($ws_port|tonumber),reality_port:($reality_port|tonumber),anytls_password:$anytls_password,ws_uuid:$ws_uuid,reality_uuid:$reality_uuid,reality_private:$reality_private,reality_public:$reality_public,reality_sid:$reality_sid,ws_path:$ws_path,cert_file:$cert_file,key_file:$key_file,cert_mode:$cert_mode}' > "$tmp"
    chmod 0600 "$tmp"
    chown root:root "$tmp"
    mv "$tmp" "$STATE_FILE"
}

load_state() {
    [ -s "$STATE_FILE" ] || err '没有找到配置。请先运行安装向导。'
    ORIGIN_ADDR=$(jq -r '.origin_addr' "$STATE_FILE")
    PREFERRED_IP=$(jq -r '.preferred_ip' "$STATE_FILE")
    TLS_DOMAIN=$(jq -r '.tls_domain' "$STATE_FILE")
    WS_HOST=$(jq -r '.ws_host' "$STATE_FILE")
    REALITY_SNI=$(jq -r '.reality_sni' "$STATE_FILE")
    ANYTLS_PORT=$(jq -r '.anytls_port' "$STATE_FILE")
    WS_PORT=$(jq -r '.ws_port' "$STATE_FILE")
    REALITY_PORT=$(jq -r '.reality_port' "$STATE_FILE")
    ANYTLS_PASSWORD=$(jq -r '.anytls_password' "$STATE_FILE")
    WS_UUID=$(jq -r '.ws_uuid' "$STATE_FILE")
    REALITY_UUID=$(jq -r '.reality_uuid' "$STATE_FILE")
    REALITY_PRIVATE=$(jq -r '.reality_private' "$STATE_FILE")
    REALITY_PUBLIC=$(jq -r '.reality_public' "$STATE_FILE")
    REALITY_SID=$(jq -r '.reality_sid' "$STATE_FILE")
    WS_PATH=$(jq -r '.ws_path' "$STATE_FILE")
    CERT_FILE=$(jq -r '.cert_file' "$STATE_FILE")
    KEY_FILE=$(jq -r '.key_file' "$STATE_FILE")
    CERT_MODE=$(jq -r '.cert_mode' "$STATE_FILE")
}

write_config_temp() {
    tmp="$CONFIG_FILE.tmp.$$"
    jq -n \
      --arg tls_domain "$TLS_DOMAIN" \
      --arg reality_sni "$REALITY_SNI" \
      --arg cert_file "$CERT_FILE" \
      --arg key_file "$KEY_FILE" \
      --arg anytls_password "$ANYTLS_PASSWORD" \
      --arg ws_uuid "$WS_UUID" \
      --arg reality_uuid "$REALITY_UUID" \
      --arg reality_private "$REALITY_PRIVATE" \
      --arg reality_sid "$REALITY_SID" \
      --arg ws_path "$WS_PATH" \
      --arg anytls_port "$ANYTLS_PORT" \
      --arg ws_port "$WS_PORT" \
      --arg reality_port "$REALITY_PORT" \
      '{log:{level:"info",timestamp:true},inbounds:[
        {type:"anytls",tag:"anytls-in",listen:"::",listen_port:($anytls_port|tonumber),users:[{name:"primary",password:$anytls_password}],tls:{enabled:true,server_name:$tls_domain,certificate_path:$cert_file,key_path:$key_file}},
        {type:"vless",tag:"vless-ws-tls-in",listen:"::",listen_port:($ws_port|tonumber),users:[{uuid:$ws_uuid}],tls:{enabled:true,server_name:$tls_domain,certificate_path:$cert_file,key_path:$key_file},transport:{type:"ws",path:$ws_path}},
        {type:"vless",tag:"vless-reality-in",listen:"::",listen_port:($reality_port|tonumber),users:[{uuid:$reality_uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$reality_sni,reality:{enabled:true,handshake:{server:$reality_sni,server_port:443},private_key:$reality_private,short_id:[$reality_sid]}}}
      ],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp"
    if ! "$SB_BIN" check -c "$tmp"; then
        rm -f "$tmp"
        err 'sing-box 配置检查失败，原配置未更改。'
    fi
    chown root:sing-box "$tmp"
    chmod 0640 "$tmp"
}

build_config() {
    had_old_config=0
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
        had_old_config=1
    fi

    attempt=1
    max_attempts=6
    while [ "$attempt" -le "$max_attempts" ]; do
        write_config_temp
        mv "$CONFIG_FILE.tmp.$$" "$CONFIG_FILE"
        if service_restart; then
            save_state
            msg '配置已检查并应用，sing-box 已重启。'
            return 0
        fi

        warn "第 $attempt/$max_attempts 次启动失败；可能是端口冲突，正在重新随机分配端口。"
        if [ "$attempt" -lt "$max_attempts" ]; then
            PREVIOUS_PORTS="${PREVIOUS_PORTS-} $ANYTLS_PORT $WS_PORT $REALITY_PORT"
            choose_random_ports
            attempt=$((attempt + 1))
            continue
        fi
        break
    done

    warn '多次尝试仍无法启动，正在恢复原配置。'
    if [ "$had_old_config" -eq 1 ]; then
        cp "$CONFIG_FILE.bak" "$CONFIG_FILE"
        service_restart || true
    else
        rm -f "$CONFIG_FILE"
        if [ "$SERVICE_KIND" = systemd ]; then systemctl stop sing-box >/dev/null 2>&1 || true; fi
        if [ "$SERVICE_KIND" = openrc ]; then rc-service sing-box stop >/dev/null 2>&1 || true; fi
    fi
    err '服务启动失败，已回滚配置（如果存在旧配置）。请查看服务日志。'
}

show_nodes() {
    ORIGIN_URI=$(uri_host "$ORIGIN_ADDR")
    PREFERRED_URI=$(uri_host "$PREFERRED_IP")
    WS_PATH_ENC=$(printf '%s' "$WS_PATH" | sed 's#/#%2F#g')
    ANYTLS_LINK="anytls://${ANYTLS_PASSWORD}@${ORIGIN_URI}:${ANYTLS_PORT}/?sni=${TLS_DOMAIN}#AnyTLS"
    WS_LINK="vless://${WS_UUID}@${PREFERRED_URI}:${WS_PORT}?encryption=none&security=tls&sni=${TLS_DOMAIN}&type=ws&host=${WS_HOST}&path=${WS_PATH_ENC}#VLESS-WS-TLS"
    REALITY_LINK="vless://${REALITY_UUID}@${ORIGIN_URI}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&type=tcp#VLESS-Reality"
    cat > "$APP_DIR/nodes.txt" <<EOF_NODES
AnyTLS:
$ANYTLS_LINK

VLESS + WS + TLS:
$WS_LINK

VLESS + Reality:
$REALITY_LINK
EOF_NODES
    chmod 0600 "$APP_DIR/nodes.txt"
    msg '================ 节点信息 ================'
    printf '\n[1] AnyTLS\n%s\n' "$ANYTLS_LINK"
    printf '\n[2] VLESS + WebSocket + TLS\n%s\n' "$WS_LINK"
    printf '\n[3] VLESS + Reality\n%s\n' "$REALITY_LINK"
    printf '\n节点文件：%s/nodes.txt\n' "$APP_DIR"
    printf '===========================================\n'
}

install_wizard() {
    need_root
    # 重装时读取旧端口，确保同一主机下一次安装不会复用上一轮端口。
    PREVIOUS_PORTS="${ANYTLS_PORT-} ${WS_PORT-} ${REALITY_PORT-}"
    install_dependencies_and_core
    ensure_service_account
    create_service
    setup_reload_hook

    msg '========== sing-box 一键安装向导 =========='
    detected_ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    ask_value '源站公网 IP（AnyTLS / Reality 直连地址）' "$detected_ip"
    ORIGIN_ADDR=$REPLY
    valid_host "$ORIGIN_ADDR" || err '源站地址格式不正确。'

    ask_value 'VLESS WS TLS 优选 IP（默认与源站相同）' "$ORIGIN_ADDR"
    PREFERRED_IP=$REPLY
    valid_host "$PREFERRED_IP" || err '优选 IP / 地址格式不正确。'

    ask_value 'TLS 证书域名 / AnyTLS 与 WS 的 SNI' ''
    TLS_DOMAIN=$REPLY
    valid_domain "$TLS_DOMAIN" || err '请输入有效的完整域名，例如 node.example.com。'

    ask_value 'VLESS WS Host 域名' "$TLS_DOMAIN"
    WS_HOST=$REPLY
    valid_domain "$WS_HOST" || err '请输入有效的 Host 域名。'

    ask_value 'Reality SNI / 握手目标域名' 'www.microsoft.com'
    REALITY_SNI=$REPLY
    valid_domain "$REALITY_SNI" || err 'Reality SNI 必须是有效域名。'

    choose_random_ports

    msg '证书方式：输入 Cloudflare DNS API Token 可自动申请证书并自动续期；不使用 Cloudflare 则选择手动证书。'
    ask_value 'Cloudflare API Token（留空表示手动证书）' ''
    cf_token=$REPLY
    if [ -n "$cf_token" ]; then
        printf '%s' "$cf_token" > "$CF_TOKEN_FILE"
        chmod 0600 "$CF_TOKEN_FILE"
        chown root:root "$CF_TOKEN_FILE"
        CERT_MODE=cloudflare
        ask_value '证书账户邮箱（可留空）' ''
        cert_email=$REPLY
        rm -f "$CF_ZONE_ID_FILE"
        ask_value 'Cloudflare Zone ID（可选；填写后 Token 只需 Zone:DNS:Edit 权限）' ''
        zone_id=$REPLY
        if [ -n "$zone_id" ]; then
            case "$zone_id" in *[!A-Fa-f0-9]*|'') err 'Zone ID 必须是 32 位十六进制字符串。' ;; esac
            [ "${#zone_id}" -eq 32 ] || err 'Zone ID 必须是 32 位十六进制字符串。'
            printf '%s' "$zone_id" > "$CF_ZONE_ID_FILE"
            chmod 0600 "$CF_ZONE_ID_FILE"
        fi
        install_acme "$cert_email"
        issue_cloudflare_cert "$TLS_DOMAIN"
    else
        CERT_MODE=manual
        install_manual_cert "$TLS_DOMAIN"
    fi

    ANYTLS_PASSWORD=$(openssl rand -hex 24)
    WS_UUID=$("$SB_BIN" generate uuid)
    REALITY_UUID=$("$SB_BIN" generate uuid)
    keypair=$("$SB_BIN" generate reality-keypair)
    REALITY_PRIVATE=$(printf '%s\n' "$keypair" | awk '/PrivateKey/ {print $2}')
    REALITY_PUBLIC=$(printf '%s\n' "$keypair" | awk '/PublicKey/ {print $2}')
    [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || err 'Reality 密钥生成失败。'
    REALITY_SID=$("$SB_BIN" generate rand --hex 8)
    WS_PATH="/ws-$(openssl rand -hex 8)"

    build_config
    save_state
    msg '安装完成。正在显示三个节点……'
    show_nodes
    msg '请在云厂商安全组和系统防火墙放行以下 TCP 端口：'
    printf '  %s/tcp\n  %s/tcp\n  %s/tcp\n' "$ANYTLS_PORT" "$WS_PORT" "$REALITY_PORT"
    msg '管理命令：/usr/local/sbin/sb-manager'
}

change_tls_sni() {
    ask_value '新的 TLS SNI 域名（AnyTLS + VLESS WS TLS）' "$TLS_DOMAIN"
    new_domain=$REPLY
    valid_domain "$new_domain" || { warn '域名格式无效。'; return; }
    old_domain=$TLS_DOMAIN
    TLS_DOMAIN=$new_domain
    if [ "$CERT_MODE" = cloudflare ] && [ -s "$CF_TOKEN_FILE" ]; then
        if ! issue_cloudflare_cert "$TLS_DOMAIN"; then
            TLS_DOMAIN=$old_domain
            warn '证书签发失败，SNI 未修改。请检查 Cloudflare Token 权限和 DNS 区域。'
            return 0
        fi
    else
        if ! openssl x509 -in "$CERT_FILE" -noout -checkhost "$TLS_DOMAIN" >/dev/null 2>&1; then
            TLS_DOMAIN=$old_domain
            warn '现有证书不包含这个域名。请先更换证书，或使用 Cloudflare DNS-01 自动签发。'
            return 0
        fi
    fi
    build_config
}

change_reality_sni() {
    ask_value '新的 Reality SNI / 握手目标域名' "$REALITY_SNI"
    new_sni=$REPLY
    valid_domain "$new_sni" || { warn '域名格式无效。'; return; }
    REALITY_SNI=$new_sni
    build_config
}

change_preferred_ip() {
    ask_value '新的 VLESS WS TLS 优选 IP / 地址' "$PREFERRED_IP"
    new_ip=$REPLY
    valid_host "$new_ip" || { warn '地址格式无效。'; return; }
    PREFERRED_IP=$new_ip
    save_state
    show_nodes
}

change_ws_host() {
    ask_value '新的 VLESS WS Host 域名（需在 DNS/CDN 中正确配置）' "$WS_HOST"
    new_host=$REPLY
    valid_domain "$new_host" || { warn '域名格式无效。'; return; }
    WS_HOST=$new_host
    save_state
    show_nodes
}

randomize_ports() {
    msg '正在为三个节点重新随机分配端口……'
    # 排除当前端口，保证每次重新分配后都与上一组不同。
    PREVIOUS_PORTS="$ANYTLS_PORT $WS_PORT $REALITY_PORT"
    choose_random_ports
    build_config
    show_nodes
    msg '请同步更新云厂商安全组和系统防火墙中的 TCP 端口规则。'
}
show_logs() {
    if [ "$SERVICE_KIND" = systemd ]; then
        journalctl -u sing-box -n 80 --no-pager || true
    else
        tail -n 80 /var/log/messages 2>/dev/null || true
        rc-service sing-box status || true
    fi
}

menu() {
    need_root
    load_state
    while :; do
        printf '\n========== sing-box 节点管理 ==========' 
        printf '\n源站：%s | 优选 IP：%s' "$ORIGIN_ADDR" "$PREFERRED_IP"
        printf '\nTLS SNI：%s | WS Host：%s | Reality SNI：%s' "$TLS_DOMAIN" "$WS_HOST" "$REALITY_SNI"
        printf '\n端口：AnyTLS %s | WS TLS %s | Reality %s' "$ANYTLS_PORT" "$WS_PORT" "$REALITY_PORT"
        printf '\n---------------------------------------\n'
        printf '1. 查看/重新生成三个节点\n'
        printf '2. 修改 AnyTLS + WS TLS 的 SNI（自动检查/更新证书）\n'
        printf '3. 修改 Reality SNI\n'
        printf '4. 修改 VLESS WS TLS 优选 IP\n'
        printf '5. 修改绑定到优选 IP 的 WS Host 域名\n'
        printf '6. 重新随机分配三个节点端口（与当前端口不同）\n'
        printf '7. 重启 sing-box\n'
        printf '8. 查看服务状态\n'
        printf '9. 查看最近日志\n'
        printf '0. 退出\n'
        printf '请选择：'
        IFS= read -r choice || choice=0
        case "$choice" in
            1) show_nodes ;;
            2) change_tls_sni ;;
            3) change_reality_sni ;;
            4) change_preferred_ip ;;
            5) change_ws_host ;;
            6) randomize_ports ;;
            7) service_restart && msg '服务已重启。' ;;
            8) service_status ;;
            9) show_logs ;;
            0) exit 0 ;;
            *) warn '无效选项。' ;;
        esac
    done
}

install_manager_command() {
    case "$0" in
        /dev/*|/proc/*) return 0 ;;
    esac
    if [ "$0" != /usr/local/sbin/sb-manager ] && [ -f "$0" ]; then
        install -m 0700 "$0" /usr/local/sbin/sb-manager
    fi
}

main() {
    need_root
    install_manager_command
    if [ -f "$STATE_FILE" ]; then
        load_state
        if [ -f /etc/alpine-release ]; then OS_FAMILY=alpine; SERVICE_KIND=openrc; else OS_FAMILY=debian; SERVICE_KIND=systemd; fi
        SB_BIN="$(command -v sing-box 2>/dev/null || printf /usr/bin/sing-box)"
        case "${1:-}" in install|--install) install_wizard ;; *) menu ;; esac
    else
        install_wizard
    fi
}

main "$@"
