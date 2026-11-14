#!/bin/sh
# sing-box multi-protocol manager for Debian + Alpine
# AnyTLS + VLESS/WS/TLS + VLESS/Reality
# IPv4 + IPv6 dual-stack listeners and separate address-family node links
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
CF_ZONE_NAME=""
RELOAD_HOOK=/usr/local/sbin/sing-box-cert-reload
SB_BIN="$(command -v sing-box 2>/dev/null || printf /usr/bin/sing-box)"
OS_FAMILY=""
SERVICE_KIND=""

msg() { printf '\n%s\n' "$*"; }
err() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
warn() { printf '[警告] %s\\n' "$*" >&2; }
run_with_timeout() {
    timeout_seconds=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" "$@"
        return $?
    fi
    if command -v busybox >/dev/null 2>&1; then
        busybox timeout "$timeout_seconds" "$@"
        return $?
    fi
    warn '系统缺少 timeout 命令，无法为 ACME 网络请求设置超时。'
    return 127
}
need_root() { [ "$(id -u)" -eq 0 ] || err '请使用 root 运行。'; }

valid_domain() {
    v=$1
    [ -n "$v" ] || return 1
    [ "${#v}" -le 253 ] || return 1
    case "$v" in *[!A-Za-z0-9.-]*|.*|*..*|*.) return 1 ;; esac
    case "$v" in *-.*|*.-* ) return 1 ;; esac
    printf '%s\n' "$v" | awk -F. 'NF >= 2 { for (i=1;i<=NF;i++) if (length($i)<1 || length($i)>63 || $i ~ /^-/ || $i ~ /-$/) exit 1; exit 0 } { exit 1 }'
}

valid_cert_domain() {
    valid_domain "$1" || return 1
    # Do not let the known Reality default / third-party examples be mistaken
    # for a certificate hostname. Reality SNI is validated separately.
    cert_domain_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$cert_domain_lc" in
        bing.com|www.bing.com|microsoft.com|www.microsoft.com) return 1 ;;
    esac
    # A dotted numeric address is not a DNS hostname suitable for a public TLS certificate.
    case "$1" in *[!0-9.]*) return 0 ;; *) return 1 ;; esac
}

# Ensure a certificate hostname is a subdomain of the Cloudflare zone the
# operator actually controls. This catches common mistakes such as entering
# www.bing.com as the TLS certificate domain while managing example.com.
domain_belongs_to_zone() {
    cert_domain=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    zone_domain=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    [ -n "$cert_domain" ] && [ -n "$zone_domain" ] || return 1
    case "$cert_domain" in
        "$zone_domain"|*."$zone_domain") return 0 ;;
        *) return 1 ;;
    esac
}

confirm_domain_control() {
    domain_to_confirm=$1
    printf '\n即将为域名 %s 申请 TLS 证书。\n' "$domain_to_confirm"
    printf '请确认这是你拥有或获准管理的域名，而不是 www.bing.com / www.microsoft.com 等第三方域名。\n'
    ask_value '确认请输入大写 YES' ''
    [ "$REPLY" = "YES" ] || { warn '未确认域名所有权，已停止证书申请。'; return 1; }
    return 0
}

valid_host() {
    v=$1
    [ -n "$v" ] || return 1
    [ "${#v}" -le 253 ] || return 1
    case "$v" in *[!A-Za-z0-9.:-]*|.*|*..*|*.) return 1 ;; esac
    return 0
}

valid_main_address() {
    case "$1" in *:*) return 1 ;; esac
    valid_host "$1"
}

valid_ipv6_address() {
    case "$1" in *:*) ;; *) return 1 ;; esac
    command -v ip >/dev/null 2>&1 || return 1
    ip -6 route get "$1" >/dev/null 2>&1
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
        case "$index" in
            1) candidate=2053 ;;
            2) candidate=2083 ;;
            3) candidate=2087 ;;
            4) candidate=2096 ;;
            5) candidate=8443 ;;
        esac
        if port_is_available "$candidate" "$@"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        tries=$((tries + 1))
    done
    return 1
}

choose_random_ports() {
    previous_anytls=${1-}
    previous_ws=${2-}
    previous_reality=${3-}

    new_anytls=$(pick_random_range_port 10000 65535 \
        "$previous_anytls" "$previous_ws" "$previous_reality") ||
        err '无法找到可用的 AnyTLS 随机端口。'

    new_ws=$(pick_random_ws_port \
        "$previous_anytls" "$previous_ws" "$previous_reality" "$new_anytls") ||
        err 'Cloudflare 兼容的 WS TLS 端口均被占用，无法分配新端口。'

    new_reality=$(pick_random_range_port 10000 65535 \
        "$previous_anytls" "$previous_ws" "$previous_reality" "$new_anytls" "$new_ws") ||
        err '无法找到可用的 Reality 随机端口。'

    ANYTLS_PORT=$new_anytls
    WS_PORT=$new_ws
    REALITY_PORT=$new_reality
    msg "随机端口分配完成：AnyTLS=$ANYTLS_PORT，WS TLS=$WS_PORT，Reality=$REALITY_PORT"
}

ipv6_kernel_enabled() {
    [ -r /proc/net/if_inet6 ] || return 1
    if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
        [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "0" ] || return 1
    fi
    return 0
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

valid_email() {
    case "$1" in
        *@*.*) return 0 ;;
        *) return 1 ;;
    esac
}

ask_secret() {
    prompt=$1
    printf '%s: ' "$prompt"
    if [ -t 0 ] && command -v stty >/dev/null 2>&1; then
        stty -echo
        IFS= read -r REPLY || REPLY=""
        stty echo
        printf '\n'
    else
        IFS= read -r REPLY || REPLY=""
    fi
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
        systemctl restart sing-box
    elif [ "$SERVICE_KIND" = openrc ]; then
        rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start
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
        msg '安装 acme.sh（用于自动申请和续期证书）……'
        if [ -n "$1" ]; then
            curl -fsSL https://get.acme.sh | HOME=/root sh -s email="$1"
        else
            curl -fsSL https://get.acme.sh | HOME=/root sh
        fi
    fi
    [ -x /root/.acme.sh/acme.sh ] || err 'acme.sh 安装失败。'
    start_cron
}

acme_conf_value() {
    conf_file=$1
    conf_key=$2
    [ -r "$conf_file" ] || return 0
    sed -n "s/^${conf_key}='\(.*\)'$/\1/p" "$conf_file" | tail -n 1
}

acme_cf_credentials_match() {
    check_domain=$1
    check_token=$2
    check_zone_id=$3

    if [ -n "$check_zone_id" ]; then
        domain_conf="/root/.acme.sh/${check_domain}_ecc/${check_domain}.conf"
        saved_token=$(acme_conf_value "$domain_conf" CF_Token)
        saved_zone_id=$(acme_conf_value "$domain_conf" CF_Zone_ID)
        [ "$saved_token" = "$check_token" ] && [ "$saved_zone_id" = "$check_zone_id" ]
    else
        account_conf=/root/.acme.sh/account.conf
        saved_token=$(acme_conf_value "$account_conf" SAVED_CF_Token)
        [ -n "$saved_token" ] || saved_token=$(acme_conf_value "$account_conf" CF_Token)
        [ "$saved_token" = "$check_token" ]
    fi
}

issue_cloudflare_cert() {
    domain=$1
    valid_cert_domain "$domain" || { warn '证书域名格式无效；请填写你控制的 DNS 域名，不要填写 IP 地址。'; return 1; }
    [ -n "$CF_ZONE_NAME" ] || { warn '缺少 Cloudflare DNS 区域主域名；请重新运行安装向导并填写你管理的域名。'; return 1; }
    if ! domain_belongs_to_zone "$domain" "$CF_ZONE_NAME"; then
        warn "证书域名 $domain 不属于 Cloudflare 区域 $CF_ZONE_NAME。"
        warn '请填写你自己管理的域名下的主机名；Reality SNI（例如 www.bing.com）不能作为 TLS 证书域名。'
        return 1
    fi
    [ -s "$CF_TOKEN_FILE" ] || { warn 'Cloudflare API Token 文件不存在。'; return 1; }
    token=$(cat "$CF_TOKEN_FILE")
    [ -n "$token" ] || { warn 'Cloudflare API Token 为空。'; return 1; }

    zone_id=$(cat "$CF_ZONE_ID_FILE" 2>/dev/null || true)
    if [ -n "$zone_id" ]; then
        case "$zone_id" in *[!A-Fa-f0-9]*) warn 'Cloudflare Zone ID 格式无效。'; return 1 ;; esac
        [ "${#zone_id}" -eq 32 ] || { warn 'Cloudflare Zone ID 必须是 32 位十六进制字符串。'; return 1; }
    fi

    [ -x /root/.acme.sh/acme.sh ] || { warn '找不到 acme.sh，请重新运行安装向导安装 ACME 客户端。'; return 1; }
    msg "通过 Cloudflare DNS-01 为 $domain 申请/检查证书……"

    # acme.sh returns 2 (RENEW_SKIP) when a valid certificate is not due yet.
    # That is a normal skip, but cached ACME authorizations can also prevent
    # dns_cf_add() from running. In that case a newly rotated CF token/Zone ID
    # would not be saved for future renewals. Compare the saved credentials;
    # if they differ, deactivate the cached authorization (bounded timeout),
    # then force one visible DNS challenge so acme.sh persists new credentials.
    if [ -n "$zone_id" ]; then
        CF_Token="$token" CF_Zone_ID="$zone_id" /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null || return 1
    else
        CF_Token="$token" /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null || return 1
    fi

    acme_issue_status=0
    if [ -n "$zone_id" ]; then
        CF_Token="$token" CF_Zone_ID="$zone_id" /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --keylength ec-256 || acme_issue_status=$?
    else
        CF_Token="$token" /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --keylength ec-256 || acme_issue_status=$?
    fi

    case "$acme_issue_status" in
        0|2)
            if [ "$acme_issue_status" -eq 2 ]; then
                acme_internal_dir="/root/.acme.sh/${domain}_ecc"
                acme_internal_cert="$acme_internal_dir/fullchain.cer"
                acme_internal_key="$acme_internal_dir/${domain}.key"
                if [ ! -s "$acme_internal_cert" ] || [ ! -s "$acme_internal_key" ]; then
                    warn 'acme.sh 表示证书无需续期，但找不到完整的现有 ECC 证书/私钥文件。'
                    warn '请检查 /root/.acme.sh 中该域名的证书目录；不要删除该目录。'
                    return 1
                fi
                if ! openssl x509 -in "$acme_internal_cert" -noout -checkhost "$domain" >/dev/null 2>&1 ||
                   ! openssl x509 -in "$acme_internal_cert" -noout -checkend 0 >/dev/null 2>&1; then
                    warn 'acme.sh 现有证书不匹配当前域名或已经过期，拒绝安装。'
                    return 1
                fi
                msg 'acme.sh 检测到证书尚未到续期时间；将检查并复用现有证书。'
            else
                msg 'acme.sh 已成功签发或更新证书。'
            fi
            ;;
        *)
            warn "acme.sh 证书申请失败，退出码：$acme_issue_status。"
            warn '请检查 Cloudflare Token、Zone ID、区域权限、域名 DNS 托管状态及 acme.sh 日志。'
            return 1
            ;;
    esac

    if ! acme_cf_credentials_match "$domain" "$token" "$zone_id"; then
        msg '检测到 acme.sh 尚未保存当前 Cloudflare Token / Zone ID。'
        msg '为确保后续自动续期使用新凭据，将刷新该域名的 ACME DNS 验证状态并执行一次强制 DNS 验证。'
        msg '正在联系 Let’s Encrypt 清理旧授权；本步骤最多等待 90 秒，并显示详细进度。'
        deactivate_status=0
        run_with_timeout 90 /root/.acme.sh/acme.sh --deactivate -d "$domain" --server letsencrypt --debug 2 || deactivate_status=$?
        if [ "$deactivate_status" -ne 0 ]; then
            warn "清理旧 ACME authorization 失败或超时，退出码：$deactivate_status。"
            warn '为避免继续使用旧的 Cloudflare DNS 授权，安装已安全停止。请检查到 Let’s Encrypt 的网络连接后重试。'
            return 1
        fi
        msg '旧 ACME authorization 已清理。现在使用本次输入的 Cloudflare Token / Zone ID 执行强制 DNS 验证。'
        force_issue_status=0
        if [ -n "$zone_id" ]; then
            run_with_timeout 300 env CF_Token="$token" CF_Zone_ID="$zone_id" /root/.acme.sh/acme.sh --issue --force --dns dns_cf -d "$domain" --keylength ec-256 --debug 2 || force_issue_status=$?
        else
            run_with_timeout 300 env CF_Token="$token" /root/.acme.sh/acme.sh --issue --force --dns dns_cf -d "$domain" --keylength ec-256 --debug 2 || force_issue_status=$?
        fi
        [ "$force_issue_status" -eq 0 ] || {
            warn "使用新 Cloudflare 凭据强制 DNS 验证失败，退出码：$force_issue_status。"
            return 1
        }
        acme_cf_credentials_match "$domain" "$token" "$zone_id" || {
            warn 'acme.sh 签发后仍未保存当前 Cloudflare Token / Zone ID；为避免未来自动续期失败，停止安装。'
            return 1
        }
    else
        msg 'acme.sh 中保存的 Cloudflare Token / Zone ID 与本次输入一致。'
    fi

    if [ -n "$zone_id" ]; then
        CF_Token="$token" CF_Zone_ID="$zone_id" /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
            --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" --reloadcmd "$RELOAD_HOOK" || return 1
    else
        CF_Token="$token" /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
            --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" --reloadcmd "$RELOAD_HOOK" || return 1
    fi

    chown root:sing-box "$CERT_FILE" "$KEY_FILE"
    chmod 0644 "$CERT_FILE"
    chmod 0640 "$KEY_FILE"
    check_cert_pair "$CERT_FILE" "$KEY_FILE" "$domain" || return 1
}
issue_http_cert() {
    domain=$1
    if port_listening 80; then
        warn 'HTTP-01 自动验证需要 TCP 80 端口空闲。请暂时停止占用 80 端口的服务，或改用 Cloudflare DNS-01 / 手动证书。'
        return 1
    fi
    install_acme ''
    msg "通过 Let's Encrypt HTTP-01 为 $domain 申请/更新证书（不需要 Cloudflare Token）……"
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null || return 1
    /root/.acme.sh/acme.sh --issue --standalone -d "$domain" --keylength ec-256 || return 1
    /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
        --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" --reloadcmd "$RELOAD_HOOK" || return 1
    chown root:sing-box "$CERT_FILE" "$KEY_FILE"
    chmod 0644 "$CERT_FILE"
    chmod 0640 "$KEY_FILE"
    check_cert_pair "$CERT_FILE" "$KEY_FILE" "$domain" || return 1
}

check_cert_pair() {
    cert=$1
    key=$2
    domain=$3
    [ -r "$cert" ] || { warn "证书文件不可读：$cert"; return 1; }
    [ -r "$key" ] || { warn "私钥文件不可读：$key"; return 1; }
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || { warn '证书 PEM 格式无效。'; return 1; }
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || { warn '私钥 PEM 格式无效或带有不受支持的口令。'; return 1; }
    openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 || { warn "证书不包含域名 $domain。"; return 1; }
    cert_pub=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}') || return 1
    key_pub=$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | awk '{print $1}') || return 1
    [ "$cert_pub" = "$key_pub" ] || { warn '证书和私钥不匹配。'; return 1; }
    return 0
}

install_manual_cert() {
    domain=$1
    ask_value '请输入 fullchain.pem / 证书链文件路径' ''
    src_cert=$REPLY
    ask_value '请输入 privkey.pem / 私钥文件路径' ''
    src_key=$REPLY
    check_cert_pair "$src_cert" "$src_key" "$domain" || err '手动证书校验失败。'
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
      --arg origin_ipv6 "$ORIGIN_IPV6" \
      --arg preferred_ip "$PREFERRED_IP" \
      --arg preferred_ipv6 "$PREFERRED_IPV6" \
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
      --arg cf_zone_name "$CF_ZONE_NAME" \
      '{origin_addr:$origin_addr,origin_ipv6:$origin_ipv6,preferred_ip:$preferred_ip,preferred_ipv6:$preferred_ipv6,tls_domain:$tls_domain,ws_host:$ws_host,reality_sni:$reality_sni,anytls_port:($anytls_port|tonumber),ws_port:($ws_port|tonumber),reality_port:($reality_port|tonumber),anytls_password:$anytls_password,ws_uuid:$ws_uuid,reality_uuid:$reality_uuid,reality_private:$reality_private,reality_public:$reality_public,reality_sid:$reality_sid,ws_path:$ws_path,cert_file:$cert_file,key_file:$key_file,cert_mode:$cert_mode,cf_zone_name:$cf_zone_name}' > "$tmp"
    chmod 0600 "$tmp"
    chown root:root "$tmp"
    mv "$tmp" "$STATE_FILE"
}

load_state() {
    [ -s "$STATE_FILE" ] || err '没有找到配置。请先运行安装向导。'
    ORIGIN_ADDR=$(jq -r '.origin_addr // ""' "$STATE_FILE")
    ORIGIN_IPV6=$(jq -r '.origin_ipv6 // ""' "$STATE_FILE")
    PREFERRED_IP=$(jq -r '.preferred_ip // ""' "$STATE_FILE")
    PREFERRED_IPV6=$(jq -r '.preferred_ipv6 // ""' "$STATE_FILE")
    TLS_DOMAIN=$(jq -r '.tls_domain' "$STATE_FILE")
    WS_HOST=$(jq -r '.ws_host' "$STATE_FILE")
    REALITY_SNI=$(jq -r '.reality_sni // "www.bing.com"' "$STATE_FILE")
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
    CF_ZONE_NAME=$(jq -r '.cf_zone_name // ""' "$STATE_FILE")
}

build_config() {
    tmp="$CONFIG_FILE.tmp.$$"
    if ipv6_kernel_enabled; then
        # sing-box uses the generic TCP network for the IPv6 unspecified address.
        # On Linux/Go this creates a dual-stack wildcard listener (IPv4-mapped + IPv6)
        # when the kernel supports IPv4-mapped IPv6 sockets.
        listen_addr="::"
        msg 'IPv6 内核已启用：使用 :: 通配监听，支持 IPv4 + IPv6 双栈。'
    else
        listen_addr="0.0.0.0"
        warn '系统内核未启用 IPv6，当前配置只能监听 IPv4。若需要双栈，请先在 VPS 系统/内核中启用 IPv6。'
    fi
    jq -n \
      --arg listen_addr "$listen_addr" \
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
        {type:"anytls",tag:"anytls-in",listen:$listen_addr,listen_port:($anytls_port|tonumber),users:[{name:"primary",password:$anytls_password}],tls:{enabled:true,server_name:$tls_domain,certificate_path:$cert_file,key_path:$key_file}},
        {type:"vless",tag:"vless-ws-tls-in",listen:$listen_addr,listen_port:($ws_port|tonumber),users:[{uuid:$ws_uuid}],tls:{enabled:true,server_name:$tls_domain,certificate_path:$cert_file,key_path:$key_file},transport:{type:"ws",path:$ws_path}},
        {type:"vless",tag:"vless-reality-in",listen:$listen_addr,listen_port:($reality_port|tonumber),users:[{uuid:$reality_uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$reality_sni,reality:{enabled:true,handshake:{server:$reality_sni,server_port:443},private_key:$reality_private,short_id:[$reality_sid]}}}
      ],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp"
    if ! "$SB_BIN" check -c "$tmp"; then
        rm -f "$tmp"
        warn 'sing-box 配置检查失败，原配置未更改。'
        return 1
    fi
    if [ -f "$CONFIG_FILE" ]; then cp "$CONFIG_FILE" "$CONFIG_FILE.bak"; fi
    chown root:sing-box "$tmp"
    chmod 0640 "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    if ! service_restart; then
        warn '新配置启动失败，正在回滚。'
        if [ -f "$CONFIG_FILE.bak" ]; then cp "$CONFIG_FILE.bak" "$CONFIG_FILE"; fi
        service_restart || true
        warn '服务重启失败，已尝试恢复旧配置。请查看服务日志。'
        return 1
    fi
    save_state
    msg '配置已检查并应用，sing-box 已重启。'
}

show_nodes() {
    WS_PATH_ENC=$(printf '%s' "$WS_PATH" | sed 's#/#%2F#g')
    nodes_tmp="$APP_DIR/nodes.txt.tmp.$$"
    {
        printf 'sing-box 节点信息（节点名称以 IPv4- / IPv6- 明确区分地址族）\n\n'

        if [ -n "$ORIGIN_ADDR" ]; then
            origin_uri=$(uri_host "$ORIGIN_ADDR")
            ANYTLS_LINK="anytls://${ANYTLS_PASSWORD}@${origin_uri}:${ANYTLS_PORT}/?sni=${TLS_DOMAIN}#IPv4-AnyTLS"
            printf '[IPv4-AnyTLS] AnyTLS | 地址：%s | 端口：%s\n%s\n\n' "$ORIGIN_ADDR" "$ANYTLS_PORT" "$ANYTLS_LINK"

            REALITY_LINK="vless://${REALITY_UUID}@${origin_uri}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&type=tcp#IPv4-VLESS-Reality"
            printf '[IPv4-VLESS-Reality] VLESS + Reality | 地址：%s | 端口：%s\n%s\n\n' "$ORIGIN_ADDR" "$REALITY_PORT" "$REALITY_LINK"
        fi

        if [ -n "$PREFERRED_IP" ]; then
            preferred_uri=$(uri_host "$PREFERRED_IP")
            WS_LINK="vless://${WS_UUID}@${preferred_uri}:${WS_PORT}?encryption=none&security=tls&sni=${TLS_DOMAIN}&type=ws&host=${WS_HOST}&path=${WS_PATH_ENC}#IPv4-VLESS-WS-TLS"
            printf '[IPv4-VLESS-WS-TLS] VLESS + WebSocket + TLS | 地址：%s | 端口：%s\n%s\n\n' "$PREFERRED_IP" "$WS_PORT" "$WS_LINK"
        fi

        if [ -n "$ORIGIN_IPV6" ]; then
            origin6_uri=$(uri_host "$ORIGIN_IPV6")
            ANYTLS6_LINK="anytls://${ANYTLS_PASSWORD}@${origin6_uri}:${ANYTLS_PORT}/?sni=${TLS_DOMAIN}#IPv6-AnyTLS"
            printf '[IPv6-AnyTLS] AnyTLS | 地址：[%s] | 端口：%s\n%s\n\n' "$ORIGIN_IPV6" "$ANYTLS_PORT" "$ANYTLS6_LINK"

            REALITY6_LINK="vless://${REALITY_UUID}@${origin6_uri}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&type=tcp#IPv6-VLESS-Reality"
            printf '[IPv6-VLESS-Reality] VLESS + Reality | 地址：[%s] | 端口：%s\n%s\n\n' "$ORIGIN_IPV6" "$REALITY_PORT" "$REALITY6_LINK"
        fi

        if [ -n "$PREFERRED_IPV6" ]; then
            preferred6_uri=$(uri_host "$PREFERRED_IPV6")
            WS6_LINK="vless://${WS_UUID}@${preferred6_uri}:${WS_PORT}?encryption=none&security=tls&sni=${TLS_DOMAIN}&type=ws&host=${WS_HOST}&path=${WS_PATH_ENC}#IPv6-VLESS-WS-TLS"
            printf '[IPv6-VLESS-WS-TLS] VLESS + WebSocket + TLS | 地址：[%s] | 端口：%s\n%s\n\n' "$PREFERRED_IPV6" "$WS_PORT" "$WS6_LINK"
        fi
    } > "$nodes_tmp"
    chmod 0600 "$nodes_tmp"
    mv "$nodes_tmp" "$APP_DIR/nodes.txt"
    msg '================ 节点信息 ================'
    cat "$APP_DIR/nodes.txt"
    printf '节点文件：%s/nodes.txt\n' "$APP_DIR"
    printf '===========================================\n'
}

install_wizard() {
    need_root
    PREVIOUS_ANYTLS_PORT=${ANYTLS_PORT:-}
    PREVIOUS_WS_PORT=${WS_PORT:-}
    PREVIOUS_REALITY_PORT=${REALITY_PORT:-}
    install_dependencies_and_core
    ensure_service_account
    create_service
    setup_reload_hook

    msg '========== sing-box 一键安装向导（IPv4 + IPv6 双栈） =========='
    detected_ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    detected_ipv6=""
    if ipv6_kernel_enabled; then
        detected_ipv6=$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)
    else
        warn '当前系统内核未启用 IPv6；可继续安装 IPv4 节点，但 IPv6 需要先由 VPS 提供商/系统启用。'
    fi

    ask_value '源站 IPv4 地址 / 域名（没有可留空；输入 - 可清空自动检测值）' "$detected_ip"
    ORIGIN_ADDR=$REPLY
    [ "$ORIGIN_ADDR" = "-" ] && ORIGIN_ADDR=""
    if [ -n "$ORIGIN_ADDR" ]; then valid_main_address "$ORIGIN_ADDR" || err '源站主地址应填写 IPv4 或域名；IPv6 请填写在下一项。'; fi

    ask_value '源站 IPv6 地址（可留空；请勿输入方括号）' "$detected_ipv6"
    ORIGIN_IPV6=$REPLY
    [ "$ORIGIN_IPV6" = "-" ] && ORIGIN_IPV6=""
    if [ -n "$ORIGIN_IPV6" ]; then
        ipv6_kernel_enabled || err '检测到系统未启用 IPv6，不能配置 IPv6 源站地址。'
        valid_ipv6_address "$ORIGIN_IPV6" || err '源站 IPv6 地址格式不正确，或服务器没有到该地址的 IPv6 路由。'
    fi
    [ -n "$ORIGIN_ADDR" ] || [ -n "$ORIGIN_IPV6" ] || err '至少需要填写一个源站地址（IPv4/域名或 IPv6）。'

    ask_value 'VLESS WS TLS 优选 IPv4 地址 / 域名（可留空）' "$ORIGIN_ADDR"
    PREFERRED_IP=$REPLY
    [ "$PREFERRED_IP" = "-" ] && PREFERRED_IP=""
    if [ -n "$PREFERRED_IP" ]; then valid_main_address "$PREFERRED_IP" || err 'WS TLS 主地址应填写 IPv4 或域名；IPv6 请填写在下一项。'; fi

    ask_value 'VLESS WS TLS 优选 IPv6 地址（可留空；请勿输入方括号）' "$ORIGIN_IPV6"
    PREFERRED_IPV6=$REPLY
    [ "$PREFERRED_IPV6" = "-" ] && PREFERRED_IPV6=""
    if [ -n "$PREFERRED_IPV6" ]; then
        ipv6_kernel_enabled || err '检测到系统未启用 IPv6，不能配置 IPv6 优选地址。'
        valid_ipv6_address "$PREFERRED_IPV6" || err 'WS TLS 优选 IPv6 地址格式不正确，或服务器没有到该地址的 IPv6 路由。'
    fi
    [ -n "$PREFERRED_IP" ] || [ -n "$PREFERRED_IPV6" ] || err '至少需要填写一个 VLESS WS TLS 优选地址。'

    msg '重要：这里只填写你自己拥有/获准管理的 TLS 证书域名，例如 node.example.com。'
    msg '不要填写 www.bing.com；它是 Reality SNI 默认值，不是 TLS 证书域名。'
    ask_value '你的 TLS 证书域名（AnyTLS + WS TLS 共用；必须是自己的域名）' ''
    TLS_DOMAIN=$REPLY
    valid_cert_domain "$TLS_DOMAIN" || err '请输入有效的完整 DNS 域名，例如 node.example.com；不能填写 IP 地址。'
    confirm_domain_control "$TLS_DOMAIN" || err '未确认域名所有权，已停止证书申请。'

    msg "AnyTLS + VLESS WS TLS 的 TLS 证书域名 / TLS SNI 将统一使用：$TLS_DOMAIN"
    msg "VLESS WS HTTP Host 将自动使用：$TLS_DOMAIN（它是 HTTP Host，不是 SNI）"
    msg '只有 VLESS Reality SNI 默认使用：www.bing.com（可在管理菜单 3 修改）'
    msg '不要把 www.bing.com 填入 TLS 证书域名：公共 CA 不会为你签发第三方域名证书。'

    # By default, the WebSocket HTTP Host follows the certificate hostname.
    # It is not a TLS SNI field. Advanced users can change it later from menu 5.
    WS_HOST=$TLS_DOMAIN
    msg "VLESS WS HTTP Host 默认跟随 TLS 证书域名：$WS_HOST"
    msg '注意：WS Host 是 HTTP Host，不是 SNI；如需自定义，可在安装后使用管理菜单 5 修改。'

    ask_value 'Reality SNI / 握手目标域名' 'www.bing.com'
    REALITY_SNI=$REPLY
    valid_domain "$REALITY_SNI" || err 'Reality SNI 必须是有效域名。'

    choose_random_ports "$PREVIOUS_ANYTLS_PORT" "$PREVIOUS_WS_PORT" "$PREVIOUS_REALITY_PORT"

    msg '证书方式：'
    printf '  1. Cloudflare DNS-01：需要 API Token，可自动签发和续期。\n'
    printf '  2. HTTP-01：不需要 Token，但域名必须解析到本机，公网 TCP 80 必须可访问且空闲。\n'
    printf '  3. 手动导入已有证书。\n'
    ask_value '请选择证书方式（1/2/3）' '2'
    cert_choice=$REPLY
    case "$cert_choice" in
        1)
            msg '请填写 Cloudflare 中实际管理的 DNS 区域主域名，例如 example.com。'
            msg 'TLS 证书域名必须等于该域名或属于其子域名，例如 node.example.com。'
            ask_value 'Cloudflare DNS 区域主域名（必须是你管理的域名）' ''
            CF_ZONE_NAME=$REPLY
            valid_cert_domain "$CF_ZONE_NAME" || err 'Cloudflare 区域主域名格式无效；请填写你在 Cloudflare 中管理的 DNS 域名。'
            domain_belongs_to_zone "$TLS_DOMAIN" "$CF_ZONE_NAME" || err "证书域名 $TLS_DOMAIN 不属于 Cloudflare 区域 $CF_ZONE_NAME；请检查是否把 Reality SNI 填成了证书域名。"
            ask_secret 'Cloudflare API Token（输入时不会显示；不要填写 Zone ID）'
            cf_token=$REPLY
            [ -n "$cf_token" ] || err 'Cloudflare Token 不能为空。'
            printf '%s' "$cf_token" > "$CF_TOKEN_FILE"
            chmod 0600 "$CF_TOKEN_FILE"
            chown root:root "$CF_TOKEN_FILE"
            CERT_MODE=cloudflare

            while :; do
                ask_value '证书账户邮箱（可直接留空；只填写真实邮箱，不能填写 Token 或 Zone ID）' ''
                cert_email=$REPLY
                [ -z "$cert_email" ] && break
                valid_email "$cert_email" && break
                warn '邮箱格式不正确。请填写真实邮箱地址，或直接按 Enter 留空。'
            done
            rm -f "$CF_ZONE_ID_FILE"
            ask_value 'Cloudflare Zone ID（可选；填写后 Token 只需 Zone:DNS:Edit；留空则还需要 Zone:Zone:Read）' ''
            zone_id=$REPLY
            if [ -n "$zone_id" ]; then
                case "$zone_id" in *[!A-Fa-f0-9]*|'') err 'Zone ID 必须是 32 位十六进制字符串。' ;; esac
                [ "${#zone_id}" -eq 32 ] || err 'Zone ID 必须是 32 位十六进制字符串。'
                printf '%s' "$zone_id" > "$CF_ZONE_ID_FILE"
                chmod 0600 "$CF_ZONE_ID_FILE"
            fi
            install_acme "$cert_email"
            issue_cloudflare_cert "$TLS_DOMAIN" || err 'Cloudflare DNS-01 证书处理失败。请检查 Token 是否有效、Zone ID 是否属于该区域、Token 是否有该区域 DNS Edit 权限，以及该域名是否真的由 Cloudflare 托管。'
            ;;
        2)
            CERT_MODE=standalone
            CF_ZONE_NAME=""
            rm -f "$CF_TOKEN_FILE" "$CF_ZONE_ID_FILE"
            issue_http_cert "$TLS_DOMAIN" || err 'HTTP-01 证书申请失败。请确认域名 A/AAAA 记录、TCP 80 入站和端口占用情况。'
            ;;
        3)
            CERT_MODE=manual
            CF_ZONE_NAME=""
            rm -f "$CF_TOKEN_FILE" "$CF_ZONE_ID_FILE"
            install_manual_cert "$TLS_DOMAIN"
            ;;
        *) err '证书方式只能选择 1、2 或 3。' ;;
    esac

    ANYTLS_PASSWORD=$(openssl rand -hex 24)
    WS_UUID=$("$SB_BIN" generate uuid)
    REALITY_UUID=$("$SB_BIN" generate uuid)
    keypair=$("$SB_BIN" generate reality-keypair)
    REALITY_PRIVATE=$(printf '%s\n' "$keypair" | awk '/PrivateKey/ {print $2}')
    REALITY_PUBLIC=$(printf '%s\n' "$keypair" | awk '/PublicKey/ {print $2}')
    [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || err 'Reality 密钥生成失败。'
    REALITY_SID=$("$SB_BIN" generate rand --hex 8)
    WS_PATH="/ws-$(openssl rand -hex 8)"

    build_config || err '配置未能成功应用，请检查 sing-box 日志。'
    save_state
    msg '安装完成。正在显示三个节点……'
    show_nodes
    msg '请在云厂商安全组和系统防火墙放行以下 TCP 端口：'
    printf '  %s/tcp\n  %s/tcp\n  %s/tcp\n' "$ANYTLS_PORT" "$WS_PORT" "$REALITY_PORT"
    msg '管理命令：/usr/local/sbin/sb-manager'
}

change_tls_sni() {
    msg '此域名用于 AnyTLS 和 VLESS + WS + TLS 的 TLS SNI，必须是你拥有/获准管理且有匹配证书的域名。'
    msg 'www.bing.com 只作为 Reality SNI 默认值；不能用它申请 AnyTLS / WS TLS 证书。'
    ask_value '新的 TLS 证书域名 / TLS SNI（自己的域名）' "$TLS_DOMAIN"
    new_domain=$REPLY
    valid_cert_domain "$new_domain" || { warn 'TLS 证书域名格式无效；请输入你管理的 DNS 域名，不能填写 IP 或第三方域名。'; return 0; }
    if [ "$CERT_MODE" = cloudflare ]; then
        [ -n "$CF_ZONE_NAME" ] || { warn '缺少 Cloudflare 区域主域名，请先使用菜单 6 设置 Cloudflare 绑定区域。'; return 0; }
        domain_belongs_to_zone "$new_domain" "$CF_ZONE_NAME" || { warn "新域名必须属于 Cloudflare 区域 $CF_ZONE_NAME。"; return 0; }
    fi
    confirm_domain_control "$new_domain" || { warn '未确认域名所有权，未修改 TLS 域名。'; return 0; }

    old_domain=$TLS_DOMAIN
    old_ws_host=$WS_HOST
    backup_dir=$(mktemp -d) || { warn '无法创建临时证书备份目录。'; return 0; }
    cp -p "$CERT_FILE" "$backup_dir/fullchain.pem" 2>/dev/null || true
    cp -p "$KEY_FILE" "$backup_dir/privkey.pem" 2>/dev/null || true

    TLS_DOMAIN=$new_domain
    # If WS Host was following the old TLS domain, keep the two synchronized.
    # Preserve a deliberately customized Host value.
    if [ "$WS_HOST" = "$old_domain" ]; then
        WS_HOST=$new_domain
    fi

    if [ "$CERT_MODE" = cloudflare ] && [ -s "$CF_TOKEN_FILE" ]; then
        if ! issue_cloudflare_cert "$TLS_DOMAIN"; then
            TLS_DOMAIN=$old_domain
            WS_HOST=$old_ws_host
            [ ! -s "$backup_dir/fullchain.pem" ] || cp -p "$backup_dir/fullchain.pem" "$CERT_FILE"
            [ ! -s "$backup_dir/privkey.pem" ] || cp -p "$backup_dir/privkey.pem" "$KEY_FILE"
            chown root:sing-box "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
            chmod 0644 "$CERT_FILE" 2>/dev/null || true
            chmod 0640 "$KEY_FILE" 2>/dev/null || true
            service_restart || true
            rm -rf "$backup_dir"
            warn '证书签发失败，已恢复旧证书、TLS 域名和 WS Host。请检查 Cloudflare Token 权限、Zone ID 和 DNS。'
            return 0
        fi
    elif [ "$CERT_MODE" = standalone ]; then
        if ! issue_http_cert "$TLS_DOMAIN"; then
            TLS_DOMAIN=$old_domain
            WS_HOST=$old_ws_host
            [ ! -s "$backup_dir/fullchain.pem" ] || cp -p "$backup_dir/fullchain.pem" "$CERT_FILE"
            [ ! -s "$backup_dir/privkey.pem" ] || cp -p "$backup_dir/privkey.pem" "$KEY_FILE"
            chown root:sing-box "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
            chmod 0644 "$CERT_FILE" 2>/dev/null || true
            chmod 0640 "$KEY_FILE" 2>/dev/null || true
            service_restart || true
            rm -rf "$backup_dir"
            warn 'HTTP-01 证书签发失败，已恢复旧证书、TLS 域名和 WS Host。请检查域名解析和 TCP 80 端口。'
            return 0
        fi
    else
        if ! openssl x509 -in "$CERT_FILE" -noout -checkhost "$TLS_DOMAIN" >/dev/null 2>&1; then
            TLS_DOMAIN=$old_domain
            WS_HOST=$old_ws_host
            rm -rf "$backup_dir"
            warn '现有证书不包含这个域名。请先更换证书，或使用 Cloudflare / HTTP 自动证书签发。'
            return 0
        fi
    fi

    if ! build_config; then
        TLS_DOMAIN=$old_domain
        WS_HOST=$old_ws_host
        [ ! -s "$backup_dir/fullchain.pem" ] || cp -p "$backup_dir/fullchain.pem" "$CERT_FILE"
        [ ! -s "$backup_dir/privkey.pem" ] || cp -p "$backup_dir/privkey.pem" "$KEY_FILE"
        chown root:sing-box "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
        chmod 0644 "$CERT_FILE" 2>/dev/null || true
        chmod 0640 "$KEY_FILE" 2>/dev/null || true
        service_restart || true
        rm -rf "$backup_dir"
        warn '新 TLS 配置应用失败，已恢复旧证书、TLS 域名和 WS Host。'
        return 0
    fi
    rm -rf "$backup_dir"
    msg "TLS SNI 已更新为：$TLS_DOMAIN"
    msg "WS HTTP Host 当前为：$WS_HOST（若原来跟随 TLS 域名，已自动同步）"
}

change_cloudflare_zone() {
    if [ "$CERT_MODE" != cloudflare ]; then
        warn '当前证书模式不是 Cloudflare DNS-01。请先使用 Cloudflare DNS-01 申请证书，才能修改 Cloudflare 绑定区域。'
        return 0
    fi
    [ -s "$CF_TOKEN_FILE" ] || { warn 'Cloudflare Token 文件不存在，请重新配置 Cloudflare DNS-01。'; return 0; }

    msg '修改 Cloudflare 绑定域名会重新申请 TLS 证书。脚本只管理 ACME 验证 TXT 记录，不会自动修改 A/AAAA 解析记录。'
    msg 'Token 必须具有新区域的 Zone:DNS:Edit 权限；若 Token 只授权旧区域，申请会失败。'
    ask_value '新的 Cloudflare DNS 区域主域名（例如 example.com）' "$CF_ZONE_NAME"
    new_zone=$REPLY
    valid_cert_domain "$new_zone" || { warn 'Cloudflare 区域域名无效。'; return 0; }

    if domain_belongs_to_zone "$TLS_DOMAIN" "$new_zone"; then
        cert_default=$TLS_DOMAIN
    else
        cert_default="node.$new_zone"
    fi
    ask_value '新的 TLS 证书域名 / TLS SNI（必须属于新 Cloudflare 区域）' "$cert_default"
    new_cert_domain=$REPLY
    valid_cert_domain "$new_cert_domain" || { warn 'TLS 证书域名无效；不能填写 IP。'; return 0; }
    domain_belongs_to_zone "$new_cert_domain" "$new_zone" || {
        warn "证书域名 $new_cert_domain 不属于 Cloudflare 区域 $new_zone。"
        return 0
    }

    # Keep a custom WS Host only if it remains within the new zone.
    # If it was following the old TLS hostname (or falls outside the new zone),
    # automatically follow the new TLS certificate hostname.
    if [ "$WS_HOST" = "$TLS_DOMAIN" ] || ! domain_belongs_to_zone "$WS_HOST" "$new_zone"; then
        new_ws_host=$new_cert_domain
    else
        new_ws_host=$WS_HOST
    fi
    msg "新的 WS HTTP Host 将设置为：$new_ws_host"
    msg 'WS Host 是 HTTP Host，不是 SNI；如需自定义，可在管理菜单 5 修改。'

    if [ "$new_zone" = "$CF_ZONE_NAME" ]; then
        current_zone_id=$(cat "$CF_ZONE_ID_FILE" 2>/dev/null || true)
    else
        current_zone_id=""
    fi
    ask_value '新 Cloudflare Zone ID（建议填写；更换区域时必须填写）' "$current_zone_id"
    new_zone_id=$REPLY
    case "$new_zone_id" in
        ''|*[!A-Fa-f0-9]*) warn 'Zone ID 必须是 32 位十六进制字符串。'; return 0 ;;
    esac
    [ "${#new_zone_id}" -eq 32 ] || { warn 'Zone ID 必须是 32 位十六进制字符串。'; return 0; }

    confirm_domain_control "$new_cert_domain" || { warn '未确认域名所有权，未修改 Cloudflare 配置。'; return 0; }

    backup_dir=$(mktemp -d) || { warn '无法创建临时备份目录。'; return 0; }
    cp -p "$CERT_FILE" "$backup_dir/fullchain.pem" 2>/dev/null || true
    cp -p "$KEY_FILE" "$backup_dir/privkey.pem" 2>/dev/null || true
    cp -p "$CF_ZONE_ID_FILE" "$backup_dir/zone-id" 2>/dev/null || true

    old_zone=$CF_ZONE_NAME
    old_tls_domain=$TLS_DOMAIN
    old_ws_host=$WS_HOST

    printf '%s' "$new_zone_id" > "$CF_ZONE_ID_FILE"
    chmod 0600 "$CF_ZONE_ID_FILE"
    chown root:root "$CF_ZONE_ID_FILE"
    CF_ZONE_NAME=$new_zone
    TLS_DOMAIN=$new_cert_domain
    WS_HOST=$new_ws_host

    if ! issue_cloudflare_cert "$TLS_DOMAIN"; then
        CF_ZONE_NAME=$old_zone
        TLS_DOMAIN=$old_tls_domain
        WS_HOST=$old_ws_host
        if [ -s "$backup_dir/fullchain.pem" ]; then cp -p "$backup_dir/fullchain.pem" "$CERT_FILE"; fi
        if [ -s "$backup_dir/privkey.pem" ]; then cp -p "$backup_dir/privkey.pem" "$KEY_FILE"; fi
        if [ -s "$backup_dir/zone-id" ]; then cp -p "$backup_dir/zone-id" "$CF_ZONE_ID_FILE"; else rm -f "$CF_ZONE_ID_FILE"; fi
        chown root:sing-box "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
        chmod 0644 "$CERT_FILE" 2>/dev/null || true
        chmod 0640 "$KEY_FILE" 2>/dev/null || true
        service_restart || true
        rm -rf "$backup_dir"
        warn 'Cloudflare 区域/域名修改失败，已恢复原证书和原设置。请检查 Token 是否授权新区域、Zone ID 是否正确、DNS 是否托管在 Cloudflare。'
        return 0
    fi

    if ! build_config; then
        CF_ZONE_NAME=$old_zone
        TLS_DOMAIN=$old_tls_domain
        WS_HOST=$old_ws_host
        if [ -s "$backup_dir/fullchain.pem" ]; then cp -p "$backup_dir/fullchain.pem" "$CERT_FILE"; fi
        if [ -s "$backup_dir/privkey.pem" ]; then cp -p "$backup_dir/privkey.pem" "$KEY_FILE"; fi
        if [ -s "$backup_dir/zone-id" ]; then cp -p "$backup_dir/zone-id" "$CF_ZONE_ID_FILE"; else rm -f "$CF_ZONE_ID_FILE"; fi
        chown root:sing-box "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
        chmod 0644 "$CERT_FILE" 2>/dev/null || true
        chmod 0640 "$KEY_FILE" 2>/dev/null || true
        service_restart || true
        rm -rf "$backup_dir"
        warn '新配置未能应用，已恢复原 Cloudflare 区域、证书和节点设置。'
        return 0
    fi
    rm -rf "$backup_dir"
    show_nodes
    msg 'Cloudflare 绑定区域、TLS 证书域名和 WS Host 已更新。'
}

change_reality_sni() {
    ask_value '新的 Reality SNI / 握手目标域名' "$REALITY_SNI"
    new_sni=$REPLY
    valid_domain "$new_sni" || { warn '域名格式无效。'; return; }
    old_sni=$REALITY_SNI
    REALITY_SNI=$new_sni
    if ! build_config; then
        REALITY_SNI=$old_sni
        return 0
    fi
}

change_preferred_ip() {
    ask_value '新的 VLESS WS TLS 主地址（IPv4 / 域名；输入 - 清空）' "$PREFERRED_IP"
    new_ip=$REPLY
    [ "$new_ip" = "-" ] && new_ip=""
    if [ -n "$new_ip" ]; then valid_main_address "$new_ip" || { warn 'IPv4 地址 / 域名格式无效。'; return; }; fi

    ask_value '新的 VLESS WS TLS IPv6 地址（输入 - 清空）' "$PREFERRED_IPV6"
    new_ipv6=$REPLY
    [ "$new_ipv6" = "-" ] && new_ipv6=""
    if [ -n "$new_ipv6" ]; then
        ipv6_kernel_enabled || { warn '系统内核未启用 IPv6。'; return; }
        valid_ipv6_address "$new_ipv6" || { warn 'IPv6 地址格式无效，或服务器没有到该地址的 IPv6 路由。'; return; }
    fi
    [ -n "$new_ip" ] || [ -n "$new_ipv6" ] || { warn '至少保留一个优选地址。'; return; }
    PREFERRED_IP=$new_ip
    PREFERRED_IPV6=$new_ipv6
    save_state
    show_nodes
}

change_ws_host() {
    msg 'WS HTTP Host 是 WebSocket HTTP 请求头，不是 TLS SNI。默认建议与 TLS 证书域名相同。'
    ask_value '新的 VLESS WS HTTP Host（不是 SNI）' "$WS_HOST"
    new_host=$REPLY
    valid_domain "$new_host" || { warn '域名格式无效。'; return; }
    WS_HOST=$new_host
    save_state
    show_nodes
}

change_ports() {
    msg '随机更换三个节点端口；新端口会避开当前端口、上一轮端口和正在监听的 TCP 端口。'
    printf '当前端口：AnyTLS=%s, WS+TLS=%s, Reality=%s\n' "$ANYTLS_PORT" "$WS_PORT" "$REALITY_PORT"
    old_anytls=$ANYTLS_PORT
    old_ws=$WS_PORT
    old_reality=$REALITY_PORT
    choose_random_ports "$old_anytls" "$old_ws" "$old_reality"
    if ! build_config; then
        ANYTLS_PORT=$old_anytls
        WS_PORT=$old_ws
        REALITY_PORT=$old_reality
        return 0
    fi
    show_nodes
    msg '请同步修改云安全组和系统防火墙规则。'
}

confirm_uninstall() {
    if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
        return 0
    fi
    printf '\n即将卸载 sing-box，并删除本脚本的配置、证书副本和节点信息。\n'
    printf '同时会尝试卸载 sing-box 软件包；不会删除系统防火墙规则、云安全组、其他 cron 任务或 /root/.acme.sh。\n'
    printf '确认卸载请输入大写 YES：'
    IFS= read -r answer || answer=""
    [ "$answer" = "YES" ] || {
        msg '已取消卸载。'
        return 1
    }
    return 0
}

remove_acme_cron_entry() {
    command -v crontab >/dev/null 2>&1 || return 0
    current_cron=$(crontab -l 2>/dev/null || true)
    filtered_cron=$(printf '%s\n' "$current_cron" | grep -vF '/root/.acme.sh/acme.sh --cron --home /root/.acme.sh' || true)
    if [ -n "$filtered_cron" ]; then
        printf '%s\n' "$filtered_cron" | crontab - || warn '无法更新 root crontab；请手动检查 acme.sh 续期任务。'
    else
        crontab -r >/dev/null 2>&1 || true
    fi
}

uninstall_manager() {
    need_root
    confirm_uninstall "${1:-}" || return 0

    msg '正在停止 sing-box 服务……'
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now sing-box >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed sing-box >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box stop >/dev/null 2>&1 || true
        rc-update del sing-box default >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box
    fi

    remove_acme_cron_entry

    msg '正在删除 sing-box 配置、证书副本和管理脚本……'
    rm -f "$RELOAD_HOOK"
    rm -rf "$APP_DIR"
    rm -f /usr/local/sbin/sb-manager

    if [ -f /etc/alpine-release ]; then
        if command -v apk >/dev/null 2>&1 && apk info -e sing-box >/dev/null 2>&1; then
            apk del sing-box || warn 'sing-box apk 软件包卸载失败，请检查 apk 日志。'
        fi
        # The script's Alpine fallback release binary is installed at this path.
        rm -f /usr/local/bin/sing-box
        rm -f /etc/init.d/sing-box
    elif [ -f /etc/debian_version ]; then
        if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' sing-box 2>/dev/null | grep -q 'install ok installed'; then
            DEBIAN_FRONTEND=noninteractive apt-get purge -y sing-box || warn 'sing-box apt 软件包卸载失败，请手动执行 apt-get purge sing-box。'
        fi
        rm -f /etc/systemd/system/sing-box.service
        rm -f /etc/apt/sources.list.d/sagernet.sources
        rm -f /etc/apt/keyrings/sagernet.asc
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    msg '卸载流程已完成。'
    printf '%s\n' '保留说明：未删除 /root/.acme.sh、系统依赖包、sing-box 系统用户/组、系统防火墙规则或云厂商安全组。'
    printf '%s\n' '如需恢复服务，需要重新运行安装命令。'
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
        printf '\n源站 IPv4/域名：%s | 源站 IPv6：%s' "${ORIGIN_ADDR:-未设置}" "${ORIGIN_IPV6:-未设置}"
        printf '\nWS 优选 IPv4/域名：%s | WS 优选 IPv6：%s' "${PREFERRED_IP:-未设置}" "${PREFERRED_IPV6:-未设置}"
        printf '\nTLS 证书域名 / TLS SNI（AnyTLS + WS TLS，必须是自己的域名）：%s' "$TLS_DOMAIN"
        printf '\nWS HTTP Host（不是 SNI，默认跟随 TLS 证书域名）：%s' "$WS_HOST"
        printf '\nReality SNI（新装默认 www.bing.com）：%s' "$REALITY_SNI" 
        printf '\n端口：AnyTLS %s | WS TLS %s | Reality %s' "$ANYTLS_PORT" "$WS_PORT" "$REALITY_PORT"
        printf '\n---------------------------------------\n'
        printf '1. 查看三个协议的 IPv4/IPv6 节点链接\n'
        printf '2. 修改 TLS 证书域名 / TLS SNI（AnyTLS + WS TLS；必须是自己的域名）\n'
        printf '3. 修改 Reality SNI（新安装默认 www.bing.com）\n'
        printf '4. 修改 VLESS WS TLS 优选地址（IPv4/IPv6）\n'
        printf '5. 修改 VLESS WS HTTP Host（不是 SNI；默认跟随 TLS 域名）\n'
        printf '6. 修改 Cloudflare DNS 区域 / TLS 证书域名（WS Host 自动跟随）\n'
        printf '7. 随机更换三个节点端口（自动避开占用端口）\n'
        printf '8. 重启 sing-box\n'
        printf '9. 查看服务状态\n'
        printf '10. 查看最近日志\n'
        printf '11. 卸载 sing-box 和本脚本配置\n'
        printf '0. 退出\n'
        printf '请选择：'
        IFS= read -r choice || choice=0
        case "$choice" in
            1) show_nodes ;;
            2) change_tls_sni ;;
            3) change_reality_sni ;;
            4) change_preferred_ip ;;
            5) change_ws_host ;;
            6) change_cloudflare_zone ;;
            7) change_ports ;;
            8) service_restart && msg '服务已重启。' ;;
            9) service_status ;;
            10) show_logs ;;
            11) uninstall_manager || true; exit 0 ;;
            0) exit 0 ;;
            *) warn '无效选项。' ;;
        esac
    done
}

install_manager_command() {
    case "$0" in
        /dev/*|/proc/*|sh|/bin/sh|/usr/bin/sh) return 0 ;;
    esac
    script_name=${0##*/}
    case "$script_name" in
        sb-manager|sb-manager-debian-alpine.sh) ;;
        *) return 0 ;;
    esac
    if [ "$0" != /usr/local/sbin/sb-manager ] && [ -f "$0" ]; then
        install -m 0700 "$0" /usr/local/sbin/sb-manager
    fi
}

main() {
    need_root
    if [ "${1:-}" = uninstall ] || [ "${1:-}" = remove ]; then
        uninstall_manager "${2:-}"
        return 0
    fi
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
