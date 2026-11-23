#!/bin/sh
# sing-box single-VPS multi-protocol manager for Debian + Alpine
# AnyTLS + AnyTLS/Reality + VLESS/WS/TLS + VLESS/Reality + NaiveProxy
# IPv4 + IPv6 dual-stack listeners and separate address-family node links
# Occupied manual ports automatically fall back to free protocol-supported ports; Cloudflare DNS-01 or HTTP-01
# WEB_CONFIG_MODE=1; web single-server configuration; overlay install preserves existing settings
# WEB_CONFIG_SCHEMA=8; selective protocol installation, Argo Tunnel, VLESS XHTTP+ECH, Snell and SS2022
# v1.0.6; generated one-command installer preinstalls protocol-specific cores before protocol setup
# Node labels accept Unicode (including Chinese); URI fragments are percent-encoded
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
NODE_LABEL=""
NAIVE_PORT=""
NAIVE_USERNAME=""
NAIVE_PASSWORD=""
WS_SERVER=""
# Selective protocol installation. Missing flags in old manager.json are treated as enabled.
ENABLE_ANYTLS=1
ENABLE_WS_TLS=1
ENABLE_VLESS_REALITY=1
ENABLE_NAIVE=1
ENABLE_ANYTLS_REALITY=1
WS_MODE=direct
ARGO_HOST=""
ARGO_TUNNEL_NAME=""
ARGO_TOKEN=""
ARGO_TOKEN_FILE="$APP_DIR/cloudflared.token"
CLOUDFLARED_BIN=/usr/local/libexec/sb-manager/cloudflared
CLOUDFLARED_RUN=/usr/local/sbin/sb-cloudflared-run
CLOUDFLARED_SERVICE=cloudflared-sb-tunnel
# Xray is deliberately isolated from sing-box: it owns only VLESS + XHTTP + ECH.
XRAY_DIR=/etc/xray
XRAY_CONFIG_FILE="$XRAY_DIR/config.json"
XRAY_BIN=/usr/local/libexec/sb-manager/xray
XRAY_SERVICE=xray
XRAY_ECH_KEYS_FILE="$APP_DIR/xray-ech-server-keys"
XRAY_ECH_CONFIG_FILE="$APP_DIR/xray-ech-config-list"
XRAY_CLIENT_CONFIG_FILE="$APP_DIR/xray-xhttp-client.json"
SNELL_CLIENT_CONFIG_FILE="$APP_DIR/snell-client.json"
ENABLE_XHTTP=0
XHTTP_PORT=""
XHTTP_UUID=""
XHTTP_PATH=""
XHTTP_MODE=auto
XHTTP_ECH_PUBLIC_NAME=cloudflare-ech.com
ENABLE_SNELL=0
SNELL_PORT=""
SNELL_VERSION=5
SNELL_PSK=""
SNELL_USERKEY=""
SNELL_OBFS_MODE=http
SNELL_OBFS_HOST=www.bing.com
SNELL_MODE=default
ENABLE_SS2022=0
SS2022_PORT=""
SS2022_METHOD="2022-blake3-aes-256-gcm"
SS2022_PASSWORD=""
PREVIOUS_ANYTLS_PORT=""
PREVIOUS_WS_PORT=""
PREVIOUS_REALITY_PORT=""
PREVIOUS_NAIVE_PORT=""
PREVIOUS_ANYREALITY_PORT=""
PREVIOUS_XHTTP_PORT=""
PREVIOUS_SNELL_PORT=""
NEED_CERT=0
NEED_ORIGIN=1
BBR_SYSCTL_FILE=/etc/sysctl.d/99-sb-manager-bbr.conf
BBR_MODULES_FILE=/etc/modules-load.d/sb-manager-bbr.conf
BBR_BACKUP_FILE="$APP_DIR/bbr-previous.conf"
RELOAD_HOOK=/usr/local/sbin/sing-box-cert-reload
SB_BIN="$(command -v sing-box 2>/dev/null || printf /usr/bin/sing-box)"
OS_FAMILY=""
SERVICE_KIND=""

msg() { printf '\n%s\n' "$*"; }
err() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
warn() { printf '[警告] %s\n' "$*" >&2; }
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

read_sysctl_value() {
    key=$1
    if command -v sysctl >/dev/null 2>&1; then
        sysctl -n "$key" 2>/dev/null && return 0
    fi
    proc_path="/proc/sys/$(printf '%s' "$key" | tr '.' '/')"
    [ -r "$proc_path" ] && cat "$proc_path" 2>/dev/null
}

bbr_available() {
    available=$(read_sysctl_value net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    case " $available " in
        *" bbr "*) return 0 ;;
    esac
    return 1
}

write_alpine_sysctl_block() {
    sysctl_conf=/etc/sysctl.conf
    tmp_sysctl="${sysctl_conf}.sb-manager.$$"
    [ -f "$sysctl_conf" ] || : > "$sysctl_conf"
    awk '
        $0 == "# BEGIN SB-MANAGER BBR" { skip=1; next }
        $0 == "# END SB-MANAGER BBR" { skip=0; next }
        !skip { print }
    ' "$sysctl_conf" > "$tmp_sysctl"
    {
        cat "$tmp_sysctl"
        printf '%s\n' '# BEGIN SB-MANAGER BBR'
        if [ "$BBR_FQ_ENABLED" = 1 ]; then
            printf '%s\n' 'net.core.default_qdisc=fq'
        fi
        printf '%s\n' 'net.ipv4.tcp_congestion_control=bbr' '# END SB-MANAGER BBR'
    } > "${tmp_sysctl}.new"
    cat "${tmp_sysctl}.new" > "$sysctl_conf"
    rm -f "$tmp_sysctl" "${tmp_sysctl}.new"
}

write_alpine_modules_block() {
    modules_conf=/etc/modules
    tmp_modules="${modules_conf}.sb-manager.$$"
    [ -f "$modules_conf" ] || : > "$modules_conf"
    awk '
        $0 == "# BEGIN SB-MANAGER BBR" { skip=1; next }
        $0 == "# END SB-MANAGER BBR" { skip=0; next }
        !skip { print }
    ' "$modules_conf" > "$tmp_modules"
    {
        cat "$tmp_modules"
        printf '%s\n' '# BEGIN SB-MANAGER BBR'
        for module in $BBR_MODULES; do
            printf '%s\n' "$module"
        done
        printf '%s\n' '# END SB-MANAGER BBR'
    } > "${tmp_modules}.new"
    cat "${tmp_modules}.new" > "$modules_conf"
    rm -f "$tmp_modules" "${tmp_modules}.new"
}

persist_bbr_modules() {
    [ -n "$BBR_MODULES" ] || return 0
    if [ "$OS_FAMILY" = alpine ] || [ -f /etc/alpine-release ]; then
        write_alpine_modules_block
    else
        install -d -m 0755 /etc/modules-load.d
        modules_tmp="${BBR_MODULES_FILE}.tmp.$$"
        : > "$modules_tmp"
        for module in $BBR_MODULES; do
            printf '%s\n' "$module" >> "$modules_tmp"
        done
        chmod 0644 "$modules_tmp"
        mv "$modules_tmp" "$BBR_MODULES_FILE"
    fi
}

remove_bbr_modules_config() {
    rm -f "$BBR_MODULES_FILE"
    if [ -f /etc/alpine-release ] && [ -f /etc/modules ]; then
        tmp_modules="/etc/modules.sb-manager.$$"
        awk '
            $0 == "# BEGIN SB-MANAGER BBR" { skip=1; next }
            $0 == "# END SB-MANAGER BBR" { skip=0; next }
            !skip { print }
        ' /etc/modules > "$tmp_modules"
        cat "$tmp_modules" > /etc/modules
        rm -f "$tmp_modules"
    fi
}

enable_bbr() {
    msg '正在检查并尝试启用 TCP BBR 加速……'
    command -v sysctl >/dev/null 2>&1 || {
        warn '系统没有可用的 sysctl 命令，无法自动配置 BBR；sing-box 安装将继续。'
        return 0
    }

    BBR_MODULES=""
    if command -v modprobe >/dev/null 2>&1; then
        if modprobe tcp_bbr >/dev/null 2>&1; then
            BBR_MODULES="tcp_bbr"
        fi
        if modprobe sch_fq >/dev/null 2>&1; then
            BBR_MODULES="$BBR_MODULES sch_fq"
        fi
    fi
    if ! bbr_available; then
        warn '当前 VPS 内核没有提供 BBR 拥塞控制算法（tcp_available_congestion_control 中找不到 bbr）。'
        warn '不会强行修改网络参数；请向 VPS 商家确认内核是否启用 CONFIG_TCP_CONG_BBR，或升级到支持 BBR 的内核。'
        return 0
    fi

    if [ ! -s "$BBR_BACKUP_FILE" ]; then
        previous_cc=$(read_sysctl_value net.ipv4.tcp_congestion_control 2>/dev/null || true)
        previous_qdisc=$(read_sysctl_value net.core.default_qdisc 2>/dev/null || true)
        if [ -n "$previous_cc" ] && [ -n "$previous_qdisc" ]; then
            umask 077
            {
                printf 'previous_cc=%s\n' "$previous_cc"
                printf 'previous_qdisc=%s\n' "$previous_qdisc"
            } > "$BBR_BACKUP_FILE"
            chmod 0600 "$BBR_BACKUP_FILE"
        else
            warn '无法读取原有 TCP 拥塞控制参数；为避免卸载时无法恢复，跳过 BBR 自动修改。'
            return 0
        fi
    fi

    if command -v modprobe >/dev/null 2>&1; then
        modprobe sch_fq >/dev/null 2>&1 || true
    fi

    BBR_FQ_ENABLED=0
    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        current_qdisc=$(read_sysctl_value net.core.default_qdisc 2>/dev/null || true)
        [ "$current_qdisc" = fq ] && BBR_FQ_ENABLED=1
    else
        warn '内核不支持 fq 默认队列规则，继续尝试启用 BBR；可能无法获得完整 pacing 效果。'
    fi

    if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        previous_qdisc=$(sed -n 's/^previous_qdisc=//p' "$BBR_BACKUP_FILE" | tail -n 1)
        [ -n "$previous_qdisc" ] && sysctl -w "net.core.default_qdisc=$previous_qdisc" >/dev/null 2>&1 || true
        warn '内核拒绝启用 TCP BBR；已恢复原默认 qdisc，未写入 BBR 持久化配置。'
        return 0
    fi
    current_cc=$(read_sysctl_value net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [ "$current_cc" != bbr ]; then
        warn 'BBR 设置后校验未通过；不会写入持久化配置。'
        return 0
    fi

    install -d -m 0755 /etc/sysctl.d
    sysctl_tmp="${BBR_SYSCTL_FILE}.tmp.$$"
    {
        printf '%s\n' '# Managed by sb-manager; remove this file to disable these settings.'
        if [ "$BBR_FQ_ENABLED" = 1 ]; then
            printf '%s\n' 'net.core.default_qdisc=fq'
        fi
        printf '%s\n' 'net.ipv4.tcp_congestion_control=bbr'
    } > "$sysctl_tmp"
    chmod 0644 "$sysctl_tmp"
    mv "$sysctl_tmp" "$BBR_SYSCTL_FILE"

    if [ "$OS_FAMILY" = alpine ] || [ -f /etc/alpine-release ]; then
        write_alpine_sysctl_block
    fi
    persist_bbr_modules

    msg 'TCP BBR 已启用，并已配置开机加载所需内核模块及持久化 sysctl 参数。'
    printf '当前 TCP congestion control：%s\n' "$current_cc"
    printf '当前默认 qdisc：%s\n' "$(read_sysctl_value net.core.default_qdisc 2>/dev/null || printf unknown)"
}

show_bbr_status() {
    current_cc=$(read_sysctl_value net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)
    current_qdisc=$(read_sysctl_value net.core.default_qdisc 2>/dev/null || printf unknown)
    available=$(read_sysctl_value net.ipv4.tcp_available_congestion_control 2>/dev/null || printf unknown)
    printf '\n========== TCP BBR 状态 ==========\n'
    printf '当前拥塞控制算法：%s\n' "$current_cc"
    printf '当前默认队列规则：%s\n' "$current_qdisc"
    printf '内核可用算法：%s\n' "$available"
    if [ "$current_cc" = bbr ]; then
        printf '%s\n' '状态：BBR 已启用'
    else
        printf '%s\n' '状态：BBR 未启用'
    fi
    if [ -f "$BBR_SYSCTL_FILE" ]; then
        printf '持久化配置：%s\n' "$BBR_SYSCTL_FILE"
    else
        printf '%s\n' '持久化配置：未找到本脚本配置文件'
    fi
}

restore_bbr() {
    msg '正在恢复安装前的 TCP 拥塞控制设置……'
    if [ -s "$BBR_BACKUP_FILE" ] && command -v sysctl >/dev/null 2>&1; then
        previous_cc=$(sed -n 's/^previous_cc=//p' "$BBR_BACKUP_FILE" | tail -n 1)
        previous_qdisc=$(sed -n 's/^previous_qdisc=//p' "$BBR_BACKUP_FILE" | tail -n 1)
        if [ -n "$previous_qdisc" ]; then
            sysctl -w "net.core.default_qdisc=$previous_qdisc" >/dev/null 2>&1 || warn "无法恢复原默认 qdisc：$previous_qdisc"
        fi
        if [ -n "$previous_cc" ]; then
            sysctl -w "net.ipv4.tcp_congestion_control=$previous_cc" >/dev/null 2>&1 || warn "无法恢复原 TCP 拥塞控制算法：$previous_cc"
        fi
    fi
    rm -f "$BBR_SYSCTL_FILE"
    remove_bbr_modules_config
    if [ -f /etc/alpine-release ] && [ -f /etc/sysctl.conf ]; then
        tmp_sysctl="/etc/sysctl.conf.sb-manager.$$"
        awk '
            $0 == "# BEGIN SB-MANAGER BBR" { skip=1; next }
            $0 == "# END SB-MANAGER BBR" { skip=0; next }
            !skip { print }
        ' /etc/sysctl.conf > "$tmp_sysctl"
        cat "$tmp_sysctl" > /etc/sysctl.conf
        rm -f "$tmp_sysctl"
    fi
    msg 'BBR 持久化配置已移除；已尝试恢复原有运行时参数。'
}


valid_argo_token() {
    token_value=$1
    [ "${#token_value}" -ge 40 ] && [ "${#token_value}" -le 8192 ] || return 1
    case "$token_value" in eyJ*) ;; *) return 1 ;; esac
    case "$token_value" in *[!A-Za-z0-9+/=_-]*) return 1 ;; esac
    return 0
}

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

valid_ipv4_address() {
    printf '%s\n' "$1" | awk -F. 'NF == 4 {
        for (i = 1; i <= NF; i++) if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i > 255) next
        valid = 1
    } END { exit !(NR == 1 && valid) }'
}

valid_ipv6_literal() {
    printf '%s\n' "$1" | awk '
      function group_ok(g) { return length(g) >= 1 && length(g) <= 4 && g ~ /^[0-9A-Fa-f]+$/ }
      {
        s=$0
        if (s !~ /^[0-9A-Fa-f:]+$/ || s ~ /:::/) exit 1
        d=index(s,"::")
        n=0
        if (d > 0) {
          left=substr(s,1,d-1); right=substr(s,d+2)
          if (index(right,"::") > 0) exit 1
          if (left != "") { nl=split(left,a,":"); n+=nl; for(i=1;i<=nl;i++) if(!group_ok(a[i])) exit 1 }
          if (right != "") { nr=split(right,b,":"); n+=nr; for(i=1;i<=nr;i++) if(!group_ok(b[i])) exit 1 }
          if (n >= 8) exit 1
        } else {
          n=split(s,a,":")
          if (n != 8) exit 1
          for(i=1;i<=n;i++) if(!group_ok(a[i])) exit 1
        }
        exit 0
      }
    '
}

valid_ipv6_address() {
    valid_ipv6_literal "$1" || return 1
    command -v ip >/dev/null 2>&1 || return 1
    ip -6 route get "$1" >/dev/null 2>&1
}

valid_port() {
    p=$1
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    [ "$p" -ge 1024 ] 2>/dev/null && [ "$p" -le 65535 ] 2>/dev/null
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
    available_ws_ports=""
    for ws_candidate in 2053 2083 2087 2096 8443; do
        if port_is_available "$ws_candidate" "$@"; then
            available_ws_ports="$available_ws_ports $ws_candidate"
        fi
    done
    set -- $available_ws_ports
    [ "$#" -gt 0 ] || return 1
    index=$(random_between 0 "$(($# - 1))") || return 1
    shift "$index"
    printf '%s\n' "$1"
}

manual_port_available() {
    candidate=$1
    shift
    if port_listening "$candidate"; then
        for old_port in "$@"; do
            [ -n "$old_port" ] || continue
            [ "$candidate" = "$old_port" ] && return 0
        done
        return 1
    fi
    return 0
}

normalize_optional_port() {
    port_input=$(trim_value "$1")
    [ -n "$port_input" ] || return 0
    valid_port "$port_input" || err "$2 端口必须是 1024–65535 的整数。"
    printf '%s\n' "$port_input" | sed 's/^0*//'
}

requested_or_random_port() {
    requested_port=$1
    protocol_name=$2
    shift 2
    if [ -n "$requested_port" ]; then
        printf '%s\n' "$requested_port"
    elif [ "$protocol_name" = 'VLESS WS TLS' ]; then
        pick_random_ws_port "$@" || err 'WS TLS 无可用的 Cloudflare HTTPS 代理端口（2053、2083、2087、2096、8443）。DNS Only 直连时可手动指定 1024–65535 中的空闲端口。'
    else
        pick_random_range_port 10000 65535 "$@" || err "无法为 $protocol_name 分配可用的随机端口。"
    fi
}

assign_ports() {
    ANYTLS_PORT=$(normalize_optional_port "$ANYTLS_PORT" 'AnyTLS') || exit 1
    WS_PORT=$(normalize_optional_port "$WS_PORT" 'VLESS WS TLS') || exit 1
    REALITY_PORT=$(normalize_optional_port "$REALITY_PORT" 'VLESS Reality') || exit 1
    NAIVE_PORT=$(normalize_optional_port "$NAIVE_PORT" 'NaiveProxy') || exit 1
    ANYREALITY_PORT=$(normalize_optional_port "$ANYREALITY_PORT" 'AnyTLS + Reality') || exit 1
    XHTTP_PORT=$(normalize_optional_port "$XHTTP_PORT" 'VLESS XHTTP + ECH') || exit 1
    SNELL_PORT=$(normalize_optional_port "$SNELL_PORT" 'Snell') || exit 1
    SS2022_PORT=$(normalize_optional_port "$SS2022_PORT" 'SS2022') || exit 1

    [ "$ENABLE_ANYTLS" = 1 ] || ANYTLS_PORT=""
    [ "$ENABLE_WS_TLS" = 1 ] || WS_PORT=""
    [ "$ENABLE_VLESS_REALITY" = 1 ] || REALITY_PORT=""
    [ "$ENABLE_NAIVE" = 1 ] || NAIVE_PORT=""
    [ "$ENABLE_ANYTLS_REALITY" = 1 ] || ANYREALITY_PORT=""
    [ "$ENABLE_XHTTP" = 1 ] || XHTTP_PORT=""
    [ "$ENABLE_SNELL" = 1 ] || SNELL_PORT=""
    [ "$ENABLE_SS2022" = 1 ] || SS2022_PORT=""

    used_ports=""
    PORT_FALLBACK_USED=0
    for protocol_name in 'AnyTLS' 'VLESS WS TLS' 'VLESS Reality' 'NaiveProxy' 'AnyTLS + Reality' 'VLESS XHTTP + ECH' 'Snell' 'Shadowsocks 2022'; do
        case "$protocol_name" in
            'AnyTLS') enabled=$ENABLE_ANYTLS; item_port=$ANYTLS_PORT ;;
            'VLESS WS TLS') enabled=$ENABLE_WS_TLS; item_port=$WS_PORT ;;
            'VLESS Reality') enabled=$ENABLE_VLESS_REALITY; item_port=$REALITY_PORT ;;
            'NaiveProxy') enabled=$ENABLE_NAIVE; item_port=$NAIVE_PORT ;;
            'AnyTLS + Reality') enabled=$ENABLE_ANYTLS_REALITY; item_port=$ANYREALITY_PORT ;;
            'VLESS XHTTP + ECH') enabled=$ENABLE_XHTTP; item_port=$XHTTP_PORT ;;
            'Snell') enabled=$ENABLE_SNELL; item_port=$SNELL_PORT ;;
            'Shadowsocks 2022') enabled=$ENABLE_SS2022; item_port=$SS2022_PORT ;;
        esac
        [ "$enabled" = 1 ] || continue

        if [ -n "$item_port" ]; then
            case " $used_ports " in
                *" $item_port "*)
                    warn "$protocol_name 指定端口 $item_port 与已选择协议重复；将自动随机分配。"
                    item_port=""
                    PORT_FALLBACK_USED=1
                    ;;
                *)
                    if ! manual_port_available "$item_port" \
                        "$PREVIOUS_ANYTLS_PORT" "$PREVIOUS_WS_PORT" "$PREVIOUS_REALITY_PORT" \
                        "$PREVIOUS_NAIVE_PORT" "$PREVIOUS_ANYREALITY_PORT" "$PREVIOUS_XHTTP_PORT" "$PREVIOUS_SNELL_PORT" "$SS2022_PORT"; then
                        warn "$protocol_name 指定 TCP 端口 $item_port 已被其他程序占用；将自动随机分配。"
                        item_port=""
                        PORT_FALLBACK_USED=1
                    fi
                    ;;
            esac
        fi

        if [ -z "$item_port" ]; then
            case "$protocol_name" in
                'VLESS WS TLS')
                    if [ "$WS_MODE" = argo ]; then
                        item_port=$(pick_random_range_port 10000 65535 $used_ports) || err '无法为 Argo Tunnel 本机 WS 服务分配空闲端口。'
                    else
                        item_port=$(pick_random_ws_port $used_ports) || err 'WS TLS 无可用的 Cloudflare HTTPS 代理端口。'
                    fi
                    ;;
                *) item_port=$(pick_random_range_port 10000 65535 $used_ports) || err "无法为 $protocol_name 分配可用端口。" ;;
            esac
        fi
        used_ports="$used_ports $item_port"
        case "$protocol_name" in
            'AnyTLS') ANYTLS_PORT=$item_port ;;
            'VLESS WS TLS') WS_PORT=$item_port ;;
            'VLESS Reality') REALITY_PORT=$item_port ;;
            'NaiveProxy') NAIVE_PORT=$item_port ;;
            'AnyTLS + Reality') ANYREALITY_PORT=$item_port ;;
            'VLESS XHTTP + ECH') XHTTP_PORT=$item_port ;;
            'Snell') SNELL_PORT=$item_port ;;
            'Shadowsocks 2022') SS2022_PORT=$item_port ;;
        esac
    done

    msg "已选择协议端口：AnyTLS=${ANYTLS_PORT:-未安装}，WS TLS=${WS_PORT:-未安装}，VLESS Reality=${REALITY_PORT:-未安装}，NaiveProxy=${NAIVE_PORT:-未安装}，AnyTLS Reality=${ANYREALITY_PORT:-未安装}，XHTTP=${XHTTP_PORT:-未安装}，Snell=${SNELL_PORT:-未安装}，SS2022=${SS2022_PORT:-未安装}"
    if [ "$PORT_FALLBACK_USED" -eq 1 ]; then
        warn '至少一个手动端口发生冲突，已自动改用空闲随机端口。请检查 NAT 映射和防火墙。'
    fi
}

ask_ports() {
    msg 'TCP 端口可留空随机分配；手动填写时可用范围为 1024–65535。'
    if [ "$ENABLE_ANYTLS" = 1 ]; then
        ask_value 'AnyTLS TCP 端口（留空随机选 10000–65535）' "${ANYTLS_PORT:-}"
        ANYTLS_PORT=$REPLY
    else ANYTLS_PORT=""; fi
    if [ "$ENABLE_WS_TLS" = 1 ]; then
        if [ "$WS_MODE" = argo ]; then
            ask_value 'Argo Tunnel 本机 WS 端口（留空随机选 10000–65535）' "${WS_PORT:-}"
        else
            msg '直连 WS TLS 如使用 Cloudflare 橙云，端口必须为 443、2053、2083、2087、2096 或 8443。'
            ask_value 'VLESS WS TLS TCP 端口（留空随机选 Cloudflare 支持端口）' "${WS_PORT:-}"
        fi
        WS_PORT=$REPLY
    else WS_PORT=""; fi
    if [ "$ENABLE_VLESS_REALITY" = 1 ]; then
        ask_value 'VLESS Reality TCP 端口（留空随机选 10000–65535）' "${REALITY_PORT:-}"
        REALITY_PORT=$REPLY
    else REALITY_PORT=""; fi
    if [ "$ENABLE_NAIVE" = 1 ]; then
        ask_value 'NaiveProxy TCP 端口（留空随机选 10000–65535）' "${NAIVE_PORT:-}"
        NAIVE_PORT=$REPLY
    else NAIVE_PORT=""; fi
    if [ "$ENABLE_ANYTLS_REALITY" = 1 ]; then
        ask_value 'AnyTLS + Reality TCP 端口（留空随机选 10000–65535）' "${ANYREALITY_PORT:-}"
        ANYREALITY_PORT=$REPLY
    else ANYREALITY_PORT=""; fi
    if [ "$ENABLE_XHTTP" = 1 ]; then
        ask_value 'VLESS XHTTP + ECH TCP 端口（留空随机选 10000–65535）' "${XHTTP_PORT:-}"
        XHTTP_PORT=$REPLY
    else XHTTP_PORT=""; fi
    if [ "$ENABLE_SNELL" = 1 ]; then
        ask_value 'Snell TCP 端口（留空随机选 10000–65535）' "${SNELL_PORT:-}"
        SNELL_PORT=$REPLY
    else SNELL_PORT=""; fi
    if [ "$ENABLE_SS2022" = 1 ]; then
        ask_value 'Shadowsocks 2022 TCP 端口（留空随机选 10000–65535）' "${SS2022_PORT:-}"
        SS2022_PORT=$REPLY
    else SS2022_PORT=""; fi
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

trim_value() {
    printf '%s\n' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
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

write_argo_token_file() {
    token_value=$1
    valid_argo_token "$token_value" || return 1
    [ -d "$APP_DIR" ] || return 1
    grep -q '^sing-box:' /etc/group 2>/dev/null || return 1
    token_old_umask=$(umask)
    umask 077
    token_tmp=$(mktemp "$APP_DIR/.cloudflared.token.XXXXXX") || {
        umask "$token_old_umask"
        return 1
    }
    if ! printf '%s' "$token_value" > "$token_tmp"; then
        rm -f "$token_tmp"
        umask "$token_old_umask"
        return 1
    fi
    if ! chown root:sing-box "$token_tmp" || ! chmod 0640 "$token_tmp" || ! mv -f "$token_tmp" "$ARGO_TOKEN_FILE"; then
        rm -f "$token_tmp"
        umask "$token_old_umask"
        return 1
    fi
    umask "$token_old_umask"
    return 0
}

sing_box_version_from() {
    candidate_bin=$1
    [ -x "$candidate_bin" ] || return 1
    version_output=$("$candidate_bin" version 2>&1 || true)
    # Handle upstream, distro and BusyBox environments without non-POSIX awk
    # match(..., array). Only accept a version found on a line identifying
    # sing-box/version; never infer a version from unrelated build metadata.
    version_value=$(printf '%s\n' "$version_output" | grep -Ei 'sing[- ]?[Bb]ox|[Vv]ersion' | grep -Eo '[vV]?[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/^[vV]//' | sed -n '1p')
    [ -n "$version_value" ] || return 1
    printf '%s\n' "$version_value"
}

version_at_least() {
    [ -n "${1:-}" ] || return 1
    required=$2
    awk -v v="$1" -v r="$required" 'BEGIN {
        split(v,a,"."); split(r,b,".");
        for (i=1; i<=3; i++) {
            x=a[i]+0; y=b[i]+0;
            if (x>y) exit 0;
            if (x<y) exit 1;
        }
        exit 0;
    }'
}

version_supports_snell() { version_at_least "${1:-}" 1.14.0; }

version_supports_naive() {
    [ -n "${1:-}" ] || return 1
    awk -v v="$1" 'BEGIN {
        n = split(v, a, ".");
        if (n < 2) exit 1;
        major = a[1] + 0;
        minor = a[2] + 0;
        if (major > 1 || (major == 1 && minor >= 13)) exit 0;
        exit 1;
    }'
}

resolve_sing_box_binary() {
    # Choose the highest parseable version when both a package-managed binary
    # and an upstream /usr/local binary exist. Path precedence alone can leave
    # an older local binary shadowing a newly upgraded Debian package.
    local_best=""
    local_best_version=""
    for candidate in /usr/local/bin/sing-box /usr/bin/sing-box; do
        [ -x "$candidate" ] || continue
        candidate_version=$(sing_box_version_from "$candidate" || true)
        [ -n "$candidate_version" ] || continue
        if [ -z "$local_best" ] || version_at_least "$candidate_version" "$local_best_version"; then
            local_best=$candidate
            local_best_version=$candidate_version
        fi
    done
    if [ -n "$local_best" ]; then
        printf '%s\n' "$local_best"
        return 0
    fi
    command -v sing-box 2>/dev/null
}

install_alpine_official_release() {
    msg '安装 sing-box 官方最新稳定版（Alpine APK 版本不作为最终版本依据）……'
    release_json=$(curl -fsSL --retry 2 --connect-timeout 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest) ||
        err '无法访问 GitHub Releases API；请检查 VPS 网络后重试。'
    tag=$(printf '%s\n' "$release_json" | jq -r '.tag_name // empty') || err '无法解析 sing-box 最新版本信息。'
    case "$tag" in ''|null) err 'GitHub 未返回 sing-box 最新稳定版 tag。' ;; esac
    ver=${tag#v}
    case "$(uname -m)" in
        x86_64|amd64) rel_arch=amd64 ;;
        aarch64|arm64) rel_arch=arm64 ;;
        armv7l|armv7) rel_arch=armv7 ;;
        *) err "暂不支持此 CPU 架构：$(uname -m)" ;;
    esac
    archive="sing-box-${ver}-linux-${rel_arch}.tar.gz"
    asset_url=$(printf '%s\n' "$release_json" | jq -r --arg n "$archive" '.assets[]? | select(.name==$n) | .browser_download_url' | sed -n '1p')
    asset_digest=$(printf '%s\n' "$release_json" | jq -r --arg n "$archive" '.assets[]? | select(.name==$n) | .digest // empty' | sed -n '1p')
    [ -n "$asset_url" ] || err "官方最新版本 $tag 未提供架构文件 $archive。"
    unpack_dir=$(mktemp -d /tmp/sing-box-unpack.XXXXXX) || err '无法创建 sing-box 临时解压目录。'
    if ! curl -fL --retry 2 --connect-timeout 15 "$asset_url" -o "$unpack_dir/$archive"; then
        rm -rf "$unpack_dir"; err "下载 sing-box 官方发布版失败：$archive。"
    fi
    case "$asset_digest" in
        sha256:*)
            expected_digest=${asset_digest#sha256:}
            actual_digest=$(sha256sum "$unpack_dir/$archive" | awk '{print $1}')
            [ "$actual_digest" = "$expected_digest" ] || { rm -rf "$unpack_dir"; err 'sing-box 发布包 SHA-256 校验失败，拒绝安装。'; }
            ;;
        *) warn 'GitHub API 未提供该资产 SHA-256 digest；已通过 HTTPS 下载，继续安装。' ;;
    esac
    tar -xzf "$unpack_dir/$archive" -C "$unpack_dir" || { rm -rf "$unpack_dir"; err '解压 sing-box 官方发布版失败。'; }
    binary="$unpack_dir/sing-box-${ver}-linux-${rel_arch}/sing-box"
    [ -x "$binary" ] || { rm -rf "$unpack_dir"; err '官方发布包中没有找到 sing-box 可执行文件。'; }
    install -d -m 0755 /usr/local/bin
    install -m 0755 "$binary" /usr/local/bin/sing-box || { rm -rf "$unpack_dir"; err '安装 sing-box 官方二进制失败。'; }
    rm -rf "$unpack_dir"
    SB_BIN=/usr/local/bin/sing-box
    release_version=$(sing_box_version_from "$SB_BIN" || true)
    [ -n "$release_version" ] || err "官方 sing-box 版本无法识别；路径：$SB_BIN；输出：$("$SB_BIN" version 2>&1 | sed -n '1,4p' | tr '\n' ' ')。已停止后续安装。"
    version_at_least "$release_version" 1.13.0 || err "sing-box $release_version 低于项目最低要求 1.13.0。"
    if [ "$ENABLE_SNELL" = 1 ]; then version_supports_snell "$release_version" || err "Snell 需要 sing-box >=1.14.0；当前 $release_version。"; fi
    msg "sing-box 官方最新稳定版安装完成：$release_version ($SB_BIN)"
}

enable_cron_scheduler() {
    if [ "$OS_FAMILY" = debian ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y cron
        if command -v systemctl >/dev/null 2>&1; then systemctl enable --now cron; else service cron start; fi
        command -v crontab >/dev/null 2>&1 || err 'cron 已安装但找不到 crontab；ACME 自动续期无法保证。'
    elif [ "$OS_FAMILY" = alpine ]; then
        apk add --no-cache cronie
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || pgrep crond >/dev/null 2>&1 || err '无法启动 Alpine crond；ACME 自动续期无法保证。'
        command -v crontab >/dev/null 2>&1 || err 'cronie 已安装但找不到 crontab；ACME 自动续期无法保证。'
    fi
}

install_dependencies_and_core() {
    if [ -f /etc/alpine-release ]; then
        OS_FAMILY=alpine
        SERVICE_KIND=openrc
        msg '检测到 Alpine Linux，先安装核心依赖，再安装 sing-box 官方最新稳定版……'
        apk update
        apk add --no-cache ca-certificates curl jq openssl iproute2 tar gzip kmod unzip coreutils cronie
        update-ca-certificates 2>/dev/null || true
        enable_cron_scheduler
        install_alpine_official_release
    elif [ -f /etc/debian_version ]; then
        OS_FAMILY=debian
        SERVICE_KIND=systemd
        msg '检测到 Debian / Ubuntu，先安装核心依赖，再安装 sing-box 官方 APT 仓库最新版本……'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq openssl iproute2 gpg procps kmod unzip cron
        enable_cron_scheduler
        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL --retry 2 https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
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
        SB_BIN=$(command -v sing-box 2>/dev/null || true)
    else
        err '仅支持 Debian / Ubuntu 和 Alpine Linux。'
    fi

    [ -n "$SB_BIN" ] && [ -x "$SB_BIN" ] || err 'sing-box 核心安装失败：没有找到可执行文件。'
    version=$(sing_box_version_from "$SB_BIN" || true)
    [ -n "$version" ] || err "无法解析 sing-box 版本；路径：$SB_BIN；原始输出：$("$SB_BIN" version 2>&1 | sed -n '1,4p' | tr '\n' ' ')。请勿继续安装协议。"
    version_at_least "$version" 1.13.0 || err "sing-box $version 低于本项目最低版本 1.13.0。"
    if [ "$ENABLE_SNELL" = 1 ]; then version_supports_snell "$version" || err "Snell 需要 sing-box >=1.14.0；当前 $version。"; fi
    if [ "$ENABLE_NAIVE" = 1 ]; then version_supports_naive "$version" || err "NaiveProxy 需要 sing-box >=1.13.0；当前 $version。"; fi
    SB_BIN=$(resolve_sing_box_binary 2>/dev/null || printf '%s' "$SB_BIN")
    msg "核心阶段完成：sing-box $version ($SB_BIN)；协议配置尚未写入。"
}

require_naive_version() {
    version=$(sing_box_version_from "$SB_BIN" || true)
    [ -n "$version" ] || err "无法读取 sing-box 版本；路径：$SB_BIN。"
    version_at_least "$version" 1.13.0 || err "当前 sing-box 版本 $version 低于项目最低版本 1.13.0。"
    if [ "$ENABLE_NAIVE" = 1 ]; then version_supports_naive "$version" || err "NaiveProxy 需要 sing-box >=1.13.0；当前 $version。"; fi
    if [ "$ENABLE_SNELL" = 1 ]; then version_supports_snell "$version" || err "Snell 需要 sing-box >=1.14.0；当前 $version。"; fi
}

install_xray_core() {
    [ "$ENABLE_XHTTP" = 1 ] || return 0
    if [ -x "$XRAY_BIN" ]; then
        existing_version=$("$XRAY_BIN" version 2>/dev/null | sed -n '1p' || true)
        if [ -n "$existing_version" ] && "$XRAY_BIN" tls ech --serverName cloudflare-ech.com >/dev/null 2>&1; then
            msg "复用已安装且支持 ECH 的独立 Xray-core：$existing_version"
            return 0
        fi
        warn '现有 Xray-core 无法执行 ECH 密钥生成，将升级脚本专用 Xray-core。'
    fi
    msg '正在下载 Xray-core 官方发布版（仅供 VLESS XHTTP + ECH 使用）……'
    release_json=$(curl -fsSL --max-time 30 https://api.github.com/repos/XTLS/Xray-core/releases/latest) || err '无法读取 Xray-core 官方 Releases；请检查 GitHub 网络连接。'
    tag=$(printf '%s' "$release_json" | jq -r '.tag_name // empty')
    [ -n "$tag" ] || err 'Xray-core Releases 未返回 tag_name。'
    case "$(uname -m)" in
        x86_64|amd64) asset_name=Xray-linux-64.zip ;;
        aarch64|arm64) asset_name=Xray-linux-arm64-v8a.zip ;;
        armv7l|armv7) asset_name=Xray-linux-arm32-v7a.zip ;;
        *) err "暂不支持 Xray-core 的 CPU 架构：$(uname -m)" ;;
    esac
    asset_url=$(printf '%s' "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name==$n) | .browser_download_url' | sed -n '1p')
    asset_digest=$(printf '%s' "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name==$n) | .digest // empty' | sed -n '1p')
    [ -n "$asset_url" ] || err "Xray-core $tag 未提供架构文件 $asset_name。"
    tmp_dir=$(mktemp -d /tmp/sb-manager-xray.XXXXXX) || err '无法创建 Xray 临时目录。'
    if ! curl -fL --retry 2 --connect-timeout 15 "$asset_url" -o "$tmp_dir/xray.zip"; then
        rm -rf "$tmp_dir"
        err '下载 Xray-core 官方二进制失败。'
    fi
    case "$asset_digest" in
        sha256:*)
            expected_digest=${asset_digest#sha256:}
            actual_digest=$(sha256sum "$tmp_dir/xray.zip" | awk '{print $1}')
            [ "$actual_digest" = "$expected_digest" ] || { rm -rf "$tmp_dir"; err 'Xray-core 压缩包 SHA-256 校验失败，拒绝安装。'; }
            ;;
        *) warn 'GitHub 未提供该资产的 SHA-256 字段；继续安装并依赖 HTTPS 下载校验。' ;;
    esac
    if ! unzip -oq "$tmp_dir/xray.zip" -d "$tmp_dir/unpacked"; then
        rm -rf "$tmp_dir"
        err 'Xray-core 压缩包解压失败。'
    fi
    xray_file=$(find "$tmp_dir/unpacked" -type f -name xray 2>/dev/null | sed -n '1p')
    [ -n "$xray_file" ] && [ -x "$xray_file" ] || { rm -rf "$tmp_dir"; err '官方压缩包中没有找到可执行的 xray 文件。'; }
    install -d -m 0755 "${XRAY_BIN%/*}"
    install -m 0755 "$xray_file" "$XRAY_BIN" || { rm -rf "$tmp_dir"; err '安装 Xray-core 二进制失败。'; }
    rm -rf "$tmp_dir"
    "$XRAY_BIN" version | sed -n '1p'
    "$XRAY_BIN" tls ech --serverName cloudflare-ech.com >/dev/null 2>&1 || err '下载的 Xray-core 不支持 ECH；请稍后重试官方更新版。'
}

create_xray_service() {
    [ "$ENABLE_XHTTP" = 1 ] || return 0
    install -d -o root -g sing-box -m 0750 "$XRAY_DIR"
    if [ "$OS_FAMILY" = debian ] && command -v systemctl >/dev/null 2>&1; then
        cat > "/etc/systemd/system/${XRAY_SERVICE}.service" <<EOF_XRAY_SERVICE
[Unit]
Description=Xray-core VLESS XHTTP ECH service (managed by sb-manager)
Wants=network-online.target
After=network-online.target

[Service]
User=sing-box
Group=sing-box
Type=simple
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF_XRAY_SERVICE
        systemctl daemon-reload
        systemctl enable "$XRAY_SERVICE" >/dev/null
    elif command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        cat > "/etc/init.d/${XRAY_SERVICE}" <<EOF_XRAY_SERVICE
#!/sbin/openrc-run
description="Xray-core VLESS XHTTP ECH service"
command="$XRAY_BIN"
command_args="run -config $XRAY_CONFIG_FILE"
command_user="sing-box:sing-box"
command_background="yes"
pidfile="/run/xray.pid"
depend() { need net; after firewall; }
EOF_XRAY_SERVICE
        chmod 0755 "/etc/init.d/${XRAY_SERVICE}"
        rc-update add "$XRAY_SERVICE" default >/dev/null 2>&1 || true
    else
        err '未检测到可用的 systemd 或 OpenRC，无法创建 Xray 服务。'
    fi
}

xray_service_restart() {
    [ "$ENABLE_XHTTP" = 1 ] || return 0
    if [ "$SERVICE_KIND" = systemd ]; then
        systemctl restart "$XRAY_SERVICE"
    elif [ "$SERVICE_KIND" = openrc ]; then
        rc-service "$XRAY_SERVICE" restart >/dev/null 2>&1 || rc-service "$XRAY_SERVICE" start
    else
        return 1
    fi
}

xray_service_status() {
    [ "$ENABLE_XHTTP" = 1 ] || { msg '当前未安装 VLESS XHTTP + ECH。'; return 0; }
    if [ "$SERVICE_KIND" = systemd ]; then systemctl --no-pager --full status "$XRAY_SERVICE" || true
    elif [ "$SERVICE_KIND" = openrc ]; then rc-service "$XRAY_SERVICE" status || true; fi
}

generate_xhttp_ech_keys() {
    [ "$ENABLE_XHTTP" = 1 ] || return 0
    valid_domain "$XHTTP_ECH_PUBLIC_NAME" || { warn 'ECH Public Name 必须是有效域名。'; return 1; }
    ech_output=$("$XRAY_BIN" tls ech --serverName "$XHTTP_ECH_PUBLIC_NAME" 2>/dev/null) || {
        warn 'Xray-core 生成 ECH 密钥失败。'
        return 1
    }
    ech_config=$(printf '%s\n' "$ech_output" | awk '/^ECH config list:/ {getline; gsub(/[[:space:]]/, ""); print; exit}')
    ech_keys=$(printf '%s\n' "$ech_output" | awk '/^ECH server keys:/ {getline; gsub(/[[:space:]]/, ""); print; exit}')
    case "$ech_config" in ''|*[!A-Za-z0-9+/=]*) warn 'Xray-core 未返回有效 ECH Config List。'; return 1 ;; esac
    case "$ech_keys" in ''|*[!A-Za-z0-9+/=]*) warn 'Xray-core 未返回有效 ECH Server Keys。'; return 1 ;; esac
    umask 077
    printf '%s' "$ech_keys" > "$XRAY_ECH_KEYS_FILE.tmp.$$"
    printf '%s' "$ech_config" > "$XRAY_ECH_CONFIG_FILE.tmp.$$"
    chown root:sing-box "$XRAY_ECH_KEYS_FILE.tmp.$$" "$XRAY_ECH_CONFIG_FILE.tmp.$$"
    chmod 0640 "$XRAY_ECH_KEYS_FILE.tmp.$$" "$XRAY_ECH_CONFIG_FILE.tmp.$$"
    mv -f "$XRAY_ECH_KEYS_FILE.tmp.$$" "$XRAY_ECH_KEYS_FILE"
    mv -f "$XRAY_ECH_CONFIG_FILE.tmp.$$" "$XRAY_ECH_CONFIG_FILE"
    msg 'ECH Server Keys 和客户端 ECH Config 已生成并分别安全保存。'
}

build_xray_config() {
    [ "$ENABLE_XHTTP" = 1 ] || return 0
    [ -s "$XRAY_ECH_KEYS_FILE" ] && [ -s "$XRAY_ECH_CONFIG_FILE" ] || { warn 'ECH 密钥文件缺失，请重新生成 ECH 密钥。'; return 1; }
    check_cert_pair "$CERT_FILE" "$KEY_FILE" "$TLS_DOMAIN" || return 1
    tmp="$XRAY_CONFIG_FILE.tmp.$$"
    listen_addr=0.0.0.0
    ipv6_kernel_enabled && listen_addr='::'
    ech_keys=$(cat "$XRAY_ECH_KEYS_FILE")
    if ! jq -n \
      --arg listen "$listen_addr" --arg port "$XHTTP_PORT" --arg uuid "$XHTTP_UUID" \
      --arg path "$XHTTP_PATH" --arg mode "$XHTTP_MODE" --arg cert "$CERT_FILE" \
      --arg key "$KEY_FILE" --arg ech_keys "$ech_keys" \
      '{log:{loglevel:"warning"},inbounds:[{listen:$listen,port:($port|tonumber),protocol:"vless",settings:{clients:[{id:$uuid}],decryption:"none"},streamSettings:{method:"xhttp",security:"tls",xhttpSettings:{path:$path,mode:$mode},tlsSettings:{certificates:[{certificateFile:$cert,keyFile:$key}],echServerKeys:$ech_keys}}}],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"blocked"}]}' > "$tmp"; then
        rm -f "$tmp"; warn '无法生成 Xray 配置。'; return 1
    fi
    if ! "$XRAY_BIN" run -test -config "$tmp"; then
        rm -f "$tmp"; warn 'Xray 配置检查失败；原配置未更改。'; return 1
    fi
    backup="$XRAY_CONFIG_FILE.rollback.$$"
    had_old=0
    if [ -f "$XRAY_CONFIG_FILE" ]; then cp -p "$XRAY_CONFIG_FILE" "$backup" || { rm -f "$tmp"; return 1; }; had_old=1; fi
    chown root:sing-box "$tmp" && chmod 0640 "$tmp" && mv -f "$tmp" "$XRAY_CONFIG_FILE" || {
        rm -f "$tmp" "$backup"; warn '无法安全写入 Xray 配置。'; return 1;
    }
    if ! xray_service_restart; then
        warn 'Xray 服务启动失败，恢复旧配置。'
        if [ "$had_old" = 1 ]; then cp -p "$backup" "$XRAY_CONFIG_FILE"; else rm -f "$XRAY_CONFIG_FILE"; fi
        xray_service_restart || true
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
    return 0
}

write_xhttp_client_json() {
    [ "$ENABLE_XHTTP" = 1 ] || { rm -f "$XRAY_CLIENT_CONFIG_FILE"; return 0; }
    [ -s "$XRAY_ECH_CONFIG_FILE" ] || return 1
    ech_config=$(cat "$XRAY_ECH_CONFIG_FILE")
    client_tmp="$XRAY_CLIENT_CONFIG_FILE.tmp.$$"
    jq -n --arg server "$TLS_DOMAIN" --arg port "$XHTTP_PORT" --arg uuid "$XHTTP_UUID" \
      --arg path "$XHTTP_PATH" --arg mode "$XHTTP_MODE" --arg sni "$TLS_DOMAIN" --arg ech "$ech_config" \
      '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:10808,protocol:"socks",settings:{udp:true}}],outbounds:[{tag:"proxy",protocol:"vless",settings:{vnext:[{address:$server,port:($port|tonumber),users:[{id:$uuid,encryption:"none"}]}]},streamSettings:{method:"xhttp",xhttpSettings:{path:$path,mode:$mode},security:"tls",tlsSettings:{serverName:$sni,fingerprint:"chrome",echConfigList:$ech}}},{tag:"direct",protocol:"freedom",settings:{}},{tag:"blocked",protocol:"blackhole",settings:{}}]}' > "$client_tmp" || { rm -f "$client_tmp"; return 1; }
    chown root:root "$client_tmp" && chmod 0600 "$client_tmp" && mv -f "$client_tmp" "$XRAY_CLIENT_CONFIG_FILE"
}

write_snell_client_json() {
    [ "$ENABLE_SNELL" = 1 ] || { rm -f "$SNELL_CLIENT_CONFIG_FILE"; return 0; }
    client_server=${ORIGIN_ADDR:-$ORIGIN_IPV6}
    [ -n "$client_server" ] || return 1
    client_tmp="$SNELL_CLIENT_CONFIG_FILE.tmp.$$"
    if [ "$SNELL_VERSION" = 5 ]; then
        jq -n --arg server "$client_server" --arg port "$SNELL_PORT" --arg psk "$SNELL_PSK" --arg userkey "$SNELL_USERKEY" --arg obfs "$SNELL_OBFS_MODE" --arg host "$SNELL_OBFS_HOST" \
          '{type:"snell",tag:"snell-out",server:$server,server_port:($port|tonumber),version:4,psk:$psk,userkey:$userkey,reuse:false,network:"tcp",obfs_mode:$obfs,obfs_host:(if $obfs=="http" then $host else null end)} | with_entries(select(.value!=null))' > "$client_tmp"
    else
        jq -n --arg server "$client_server" --arg port "$SNELL_PORT" --arg psk "$SNELL_PSK" --arg userkey "$SNELL_USERKEY" --arg mode "$SNELL_MODE" \
          '{type:"snell",tag:"snell-out",server:$server,server_port:($port|tonumber),version:6,psk:$psk,userkey:$userkey,reuse:false,network:"tcp",mode:$mode}' > "$client_tmp"
    fi
    chown root:root "$client_tmp" && chmod 0600 "$client_tmp" && mv -f "$client_tmp" "$SNELL_CLIENT_CONFIG_FILE"
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
    else err '服务管理器尚未初始化。'; fi
    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ]; then
        start_cloudflared_service || warn 'sing-box 已重启，但 Cloudflare Tunnel 重启失败。'
    fi
    if [ "$ENABLE_XHTTP" = 1 ] && [ -s "$XRAY_CONFIG_FILE" ]; then xray_service_restart || warn 'sing-box 已重启，但 Xray 服务重启失败。'; fi
}

service_status() {
    if [ "$SERVICE_KIND" = systemd ]; then systemctl --no-pager --full status sing-box || true
    elif [ "$SERVICE_KIND" = openrc ]; then rc-service sing-box status || true; fi
    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ]; then cloudflared_status; fi
    if [ "$ENABLE_XHTTP" = 1 ]; then xray_service_status; fi
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
  systemctl restart sing-box || true
  [ ! -f /etc/xray/config.json ] || systemctl restart xray || true
elif command -v rc-service >/dev/null 2>&1; then
  rc-service sing-box restart || true
  [ ! -f /etc/xray/config.json ] || rc-service xray restart || true
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

cloudflared_supports_token_file() {
    cf_candidate=$1
    cf_version=$("$cf_candidate" --version 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="version") {print $(i+1); exit}}' | sed 's/[^0-9.].*$//')
    [ -n "$cf_version" ] || return 1
    awk -F. -v v="$cf_version" 'BEGIN {
        n=split(v,a,"."); if(n<2) exit 1;
        year=a[1]+0; minor=a[2]+0;
        if(year>2025 || (year==2025 && minor>=4)) exit 0;
        exit 1;
    }'
}

install_cloudflared() {
    if [ -x "$CLOUDFLARED_BIN" ] && cloudflared_supports_token_file "$CLOUDFLARED_BIN"; then
        return 0
    fi
    existing_cf=$(command -v cloudflared 2>/dev/null || true)
    if [ -n "$existing_cf" ] && [ -x "$existing_cf" ] && cloudflared_supports_token_file "$existing_cf"; then
        CLOUDFLARED_BIN=$existing_cf
        msg "使用系统已有 cloudflared：$CLOUDFLARED_BIN"
        return 0
    fi

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) asset=cloudflared-linux-amd64 ;;
        aarch64|arm64) asset=cloudflared-linux-arm64 ;;
        armv7l|armv6l) asset=cloudflared-linux-arm ;;
        *) err "暂不支持自动安装 cloudflared 的 CPU 架构：$arch" ;;
    esac
    if [ "$OS_FAMILY" = alpine ]; then apk add --no-cache gcompat >/dev/null 2>&1 || true; fi
    install -d -m 0755 /usr/local/libexec/sb-manager
    tmp_cf=$(mktemp)
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/$asset" -o "$tmp_cf"; then
        rm -f "$tmp_cf"
        err '下载 cloudflared 官方发布版失败；请检查 VPS 出站网络后重试。'
    fi
    chmod 0755 "$tmp_cf"
    if ! cloudflared_supports_token_file "$tmp_cf"; then
        rm -f "$tmp_cf"
        err '下载的 cloudflared 版本无法运行或低于 2025.4.0（不支持安全的 --token-file）。'
    fi
    install -m 0755 "$tmp_cf" "$CLOUDFLARED_BIN"
    rm -f "$tmp_cf"
    printf 'managed-by-sb-manager\n' > "$APP_DIR/cloudflared-managed"
    chmod 0600 "$APP_DIR/cloudflared-managed"
    msg "cloudflared 已安装：$CLOUDFLARED_BIN ($arch)"
}

create_cloudflared_service() {
    [ -s "$ARGO_TOKEN_FILE" ] || err "Cloudflare Tunnel Token 文件不存在：$ARGO_TOKEN_FILE"
    cat > "$CLOUDFLARED_RUN" <<EOF_RUN
#!/bin/sh
set -eu
TOKEN_FILE='$ARGO_TOKEN_FILE'
[ -s "\$TOKEN_FILE" ] || { echo 'Cloudflare Tunnel Token 文件不存在。' >&2; exit 1; }
exec '$CLOUDFLARED_BIN' tunnel --no-autoupdate run --token-file "\$TOKEN_FILE"
EOF_RUN
    chown root:sing-box "$CLOUDFLARED_RUN"
    chmod 0750 "$CLOUDFLARED_RUN"

    if [ "$SERVICE_KIND" = systemd ]; then
        cat > "/etc/systemd/system/$CLOUDFLARED_SERVICE.service" <<EOF_CF_SERVICE
[Unit]
Description=Cloudflare Tunnel for sing-box VLESS WS
Wants=network-online.target
After=network-online.target sing-box.service

[Service]
Type=simple
User=sing-box
Group=sing-box
ExecStart=$CLOUDFLARED_RUN
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF_CF_SERVICE
        systemctl daemon-reload
        systemctl enable "$CLOUDFLARED_SERVICE" >/dev/null
    elif [ "$SERVICE_KIND" = openrc ]; then
        cat > "/etc/init.d/$CLOUDFLARED_SERVICE" <<EOF_CF_SERVICE
#!/sbin/openrc-run
description="Cloudflare Tunnel for sing-box VLESS WS"
command="$CLOUDFLARED_RUN"
command_user="sing-box:sing-box"
command_background="yes"
pidfile="/run/$CLOUDFLARED_SERVICE.pid"

depend() {
    need net
    after sing-box
}
EOF_CF_SERVICE
        chmod 0755 "/etc/init.d/$CLOUDFLARED_SERVICE"
        rc-update add "$CLOUDFLARED_SERVICE" default >/dev/null 2>&1 || true
    else
        err '无法识别 systemd / OpenRC，不能创建 Cloudflare Tunnel 服务。'
    fi
}

start_cloudflared_service() {
    [ -s "$ARGO_TOKEN_FILE" ] || return 1
    if [ "$SERVICE_KIND" = systemd ]; then
        systemctl restart "$CLOUDFLARED_SERVICE" 2>/dev/null || systemctl start "$CLOUDFLARED_SERVICE"
    elif [ "$SERVICE_KIND" = openrc ]; then
        rc-service "$CLOUDFLARED_SERVICE" restart >/dev/null 2>&1 || rc-service "$CLOUDFLARED_SERVICE" start
    else return 1; fi
}

cloudflared_status() {
    msg '========== Cloudflare 固定 Tunnel 状态 =========='
    printf 'Tunnel 备注：%s\n' "${ARGO_TUNNEL_NAME:-未设置}"
    printf 'Public Hostname：%s\n' "${ARGO_HOST:-未设置}"
    if [ -s "$ARGO_TOKEN_FILE" ]; then
        token_meta=$(stat -c '%a %U:%G' "$ARGO_TOKEN_FILE" 2>/dev/null || ls -l "$ARGO_TOKEN_FILE" 2>/dev/null || true)
        printf 'Tunnel Token：已配置（内容隐藏；权限：%s）\n' "${token_meta:-未知}"
    else
        printf 'Tunnel Token：缺失\n'
    fi
    if [ -x "$CLOUDFLARED_BIN" ]; then
        "$CLOUDFLARED_BIN" --version 2>/dev/null | sed -n '1p' || true
    fi
    if [ "$SERVICE_KIND" = systemd ]; then
        systemctl --no-pager --full status "$CLOUDFLARED_SERVICE" 2>/dev/null || true
    elif [ "$SERVICE_KIND" = openrc ]; then
        rc-service "$CLOUDFLARED_SERVICE" status 2>/dev/null || true
    else
        warn '尚未识别 systemd / OpenRC。'
    fi
    msg '提示：服务进程 active 不等于 Cloudflare 控制台已 Healthy；最终请检查 Tunnel 的 Connector 状态。'
}

save_state() {
    tmp="$STATE_FILE.tmp.$$"
    if ! jq -n \
      --arg origin_addr "$ORIGIN_ADDR" \
      --arg origin_ipv6 "$ORIGIN_IPV6" \
      --arg preferred_ip "$PREFERRED_IP" \
      --arg preferred_ipv6 "$PREFERRED_IPV6" \
      --arg ws_server "$WS_SERVER" \
      --arg ws_mode "$WS_MODE" \
      --arg argo_host "$ARGO_HOST" \
      --arg argo_tunnel_name "$ARGO_TUNNEL_NAME" \
      --arg tls_domain "$TLS_DOMAIN" \
      --arg ws_host "$WS_HOST" \
      --arg reality_sni "$REALITY_SNI" \
      --arg anytls_port "$ANYTLS_PORT" \
      --arg ws_port "$WS_PORT" \
      --arg reality_port "$REALITY_PORT" \
      --arg naive_port "$NAIVE_PORT" \
      --arg naive_username "$NAIVE_USERNAME" \
      --arg naive_password "$NAIVE_PASSWORD" \
      --arg anyreality_port "$ANYREALITY_PORT" \
      --arg anyreality_password "$ANYREALITY_PASSWORD" \
      --arg anyreality_private "$ANYREALITY_PRIVATE" \
      --arg anyreality_public "$ANYREALITY_PUBLIC" \
      --arg anyreality_sid "$ANYREALITY_SID" \
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
      --arg node_label "$NODE_LABEL" \
      --arg enable_anytls "$ENABLE_ANYTLS" \
      --arg enable_ws_tls "$ENABLE_WS_TLS" \
      --arg enable_vless_reality "$ENABLE_VLESS_REALITY" \
      --arg enable_naive "$ENABLE_NAIVE" \
      --arg enable_anytls_reality "$ENABLE_ANYTLS_REALITY" \
      --arg enable_xhttp "$ENABLE_XHTTP" --arg xhttp_port "$XHTTP_PORT" --arg xhttp_uuid "$XHTTP_UUID" \
      --arg xhttp_path "$XHTTP_PATH" --arg xhttp_mode "$XHTTP_MODE" --arg xhttp_ech_public_name "$XHTTP_ECH_PUBLIC_NAME" \
      --arg enable_snell "$ENABLE_SNELL" --arg snell_port "$SNELL_PORT" --arg snell_version "$SNELL_VERSION" \
      --arg snell_psk "$SNELL_PSK" --arg snell_userkey "$SNELL_USERKEY" --arg snell_obfs_mode "$SNELL_OBFS_MODE" \
      --arg snell_obfs_host "$SNELL_OBFS_HOST" --arg snell_mode "$SNELL_MODE" \
      --arg enable_ss2022 "$ENABLE_SS2022" --arg ss2022_port "$SS2022_PORT" --arg ss2022_method "$SS2022_METHOD" --arg ss2022_password "$SS2022_PASSWORD" \
      '{origin_addr:$origin_addr,origin_ipv6:$origin_ipv6,preferred_ip:$preferred_ip,preferred_ipv6:$preferred_ipv6,ws_server:$ws_server,ws_mode:$ws_mode,argo_host:$argo_host,argo_tunnel_name:$argo_tunnel_name,tls_domain:$tls_domain,ws_host:$ws_host,reality_sni:$reality_sni,enabled_anytls:($enable_anytls=="1"),enabled_ws_tls:($enable_ws_tls=="1"),enabled_vless_reality:($enable_vless_reality=="1"),enabled_naive:($enable_naive=="1"),enabled_anytls_reality:($enable_anytls_reality=="1"),anytls_port:(if $enable_anytls=="1" then ($anytls_port|tonumber) else null end),ws_port:(if $enable_ws_tls=="1" then ($ws_port|tonumber) else null end),reality_port:(if $enable_vless_reality=="1" then ($reality_port|tonumber) else null end),naive_port:(if $enable_naive=="1" then ($naive_port|tonumber) else null end),anyreality_port:(if $enable_anytls_reality=="1" then ($anyreality_port|tonumber) else null end),naive_username:$naive_username,naive_password:$naive_password,anyreality_password:$anyreality_password,anyreality_private:$anyreality_private,anyreality_public:$anyreality_public,anyreality_sid:$anyreality_sid,anytls_password:$anytls_password,ws_uuid:$ws_uuid,reality_uuid:$reality_uuid,reality_private:$reality_private,reality_public:$reality_public,reality_sid:$reality_sid,ws_path:$ws_path,cert_file:$cert_file,key_file:$key_file,cert_mode:$cert_mode,cf_zone_name:$cf_zone_name,node_label:$node_label,enabled_xhttp:($enable_xhttp=="1"),xhttp_port:(if $enable_xhttp=="1" then ($xhttp_port|tonumber) else null end),xhttp_uuid:$xhttp_uuid,xhttp_path:$xhttp_path,xhttp_mode:$xhttp_mode,xhttp_ech_public_name:$xhttp_ech_public_name,enabled_snell:($enable_snell=="1"),snell_port:(if $enable_snell=="1" then ($snell_port|tonumber) else null end),snell_version:($snell_version|tonumber),snell_psk:$snell_psk,snell_userkey:$snell_userkey,snell_obfs_mode:$snell_obfs_mode,snell_obfs_host:$snell_obfs_host,snell_mode:$snell_mode,enabled_ss2022:($enable_ss2022=="1"),ss2022_port:(if $enable_ss2022=="1" then ($ss2022_port|tonumber) else null end),ss2022_method:$ss2022_method,ss2022_password:$ss2022_password}' > "$tmp"; then
        rm -f "$tmp"
        warn '无法生成 manager.json；原有管理状态未更改。'
        return 1
    fi
    # Keep extension keys from older/custom manager state files. Known fields
    # from the current manager take precedence; unknown user fields survive.
    if [ -s "$STATE_FILE" ]; then
        state_merged="$tmp.merge.$$"
        if ! jq -s '.[1] as $old | .[0] as $new | $old + $new' "$tmp" "$STATE_FILE" > "$state_merged"; then
            rm -f "$tmp" "$state_merged"
            warn '无法合并旧 manager.json 扩展字段；原有管理状态未更改。'
            return 1
        fi
        mv -f "$state_merged" "$tmp"
    fi
    if ! chmod 0600 "$tmp" || ! chown root:root "$tmp" || ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        warn '无法安全写入 manager.json；原有管理状态未更改。'
        return 1
    fi
    return 0
}

load_state() {
    [ -s "$STATE_FILE" ] || err '没有找到配置。请先运行安装向导。'
    ORIGIN_ADDR=$(jq -r '.origin_addr // ""' "$STATE_FILE")
    ORIGIN_IPV6=$(jq -r '.origin_ipv6 // ""' "$STATE_FILE")
    PREFERRED_IP=$(jq -r '.preferred_ip // ""' "$STATE_FILE")
    PREFERRED_IPV6=$(jq -r '.preferred_ipv6 // ""' "$STATE_FILE")
    WS_SERVER=$(jq -r '.ws_server // ""' "$STATE_FILE")
    TLS_DOMAIN=$(jq -r '.tls_domain // ""' "$STATE_FILE")
    WS_HOST=$(jq -r '.ws_host // ""' "$STATE_FILE")
    REALITY_SNI=$(jq -r '.reality_sni // "www.bing.com"' "$STATE_FILE")
    ENABLE_ANYTLS=$(jq -r 'if has("enabled_anytls") then (if .enabled_anytls then "1" else "0" end) else "1" end' "$STATE_FILE")
    ENABLE_WS_TLS=$(jq -r 'if has("enabled_ws_tls") then (if .enabled_ws_tls then "1" else "0" end) else "1" end' "$STATE_FILE")
    ENABLE_VLESS_REALITY=$(jq -r 'if has("enabled_vless_reality") then (if .enabled_vless_reality then "1" else "0" end) else "1" end' "$STATE_FILE")
    ENABLE_NAIVE=$(jq -r 'if has("enabled_naive") then (if .enabled_naive then "1" else "0" end) else "1" end' "$STATE_FILE")
    ENABLE_ANYTLS_REALITY=$(jq -r 'if has("enabled_anytls_reality") then (if .enabled_anytls_reality then "1" else "0" end) else "1" end' "$STATE_FILE")
    WS_MODE=$(jq -r '.ws_mode // "direct"' "$STATE_FILE")
    ARGO_HOST=$(jq -r '.argo_host // ""' "$STATE_FILE")
    ARGO_TUNNEL_NAME=$(jq -r '.argo_tunnel_name // ""' "$STATE_FILE")
    if [ -z "$WS_SERVER" ]; then
        if [ -n "$PREFERRED_IP" ]; then WS_SERVER=$PREFERRED_IP
        elif [ -n "$PREFERRED_IPV6" ]; then WS_SERVER=$PREFERRED_IPV6
        elif [ "$WS_MODE" = argo ]; then WS_SERVER=$ARGO_HOST
        else WS_SERVER=$TLS_DOMAIN; fi
    fi
    ANYTLS_PORT=$(jq -r '.anytls_port // ""' "$STATE_FILE")
    WS_PORT=$(jq -r '.ws_port // ""' "$STATE_FILE")
    REALITY_PORT=$(jq -r '.reality_port // ""' "$STATE_FILE")
    NAIVE_PORT=$(jq -r '.naive_port // ""' "$STATE_FILE")
    NAIVE_USERNAME=$(jq -r '.naive_username // ""' "$STATE_FILE")
    NAIVE_PASSWORD=$(jq -r '.naive_password // ""' "$STATE_FILE")
    ANYREALITY_PORT=$(jq -r '.anyreality_port // ""' "$STATE_FILE")
    ANYREALITY_PASSWORD=$(jq -r '.anyreality_password // ""' "$STATE_FILE")
    ANYREALITY_PRIVATE=$(jq -r '.anyreality_private // ""' "$STATE_FILE")
    ANYREALITY_PUBLIC=$(jq -r '.anyreality_public // ""' "$STATE_FILE")
    ANYREALITY_SID=$(jq -r '.anyreality_sid // ""' "$STATE_FILE")
    ANYTLS_PASSWORD=$(jq -r '.anytls_password // ""' "$STATE_FILE")
    WS_UUID=$(jq -r '.ws_uuid // ""' "$STATE_FILE")
    REALITY_UUID=$(jq -r '.reality_uuid // ""' "$STATE_FILE")
    REALITY_PRIVATE=$(jq -r '.reality_private // ""' "$STATE_FILE")
    REALITY_PUBLIC=$(jq -r '.reality_public // ""' "$STATE_FILE")
    REALITY_SID=$(jq -r '.reality_sid // ""' "$STATE_FILE")
    WS_PATH=$(jq -r '.ws_path // ""' "$STATE_FILE")
    CERT_FILE=$(jq -r '.cert_file // ""' "$STATE_FILE")
    KEY_FILE=$(jq -r '.key_file // ""' "$STATE_FILE")
    CERT_MODE=$(jq -r '.cert_mode // "none"' "$STATE_FILE")
    CF_ZONE_NAME=$(jq -r '.cf_zone_name // ""' "$STATE_FILE")
    NODE_LABEL=$(jq -r '.node_label // ""' "$STATE_FILE")
    ENABLE_XHTTP=$(jq -r 'if .enabled_xhttp == true then "1" else "0" end' "$STATE_FILE")
    XHTTP_PORT=$(jq -r '.xhttp_port // ""' "$STATE_FILE")
    XHTTP_UUID=$(jq -r '.xhttp_uuid // ""' "$STATE_FILE")
    XHTTP_PATH=$(jq -r '.xhttp_path // ""' "$STATE_FILE")
    XHTTP_MODE=$(jq -r '.xhttp_mode // "auto"' "$STATE_FILE")
    XHTTP_ECH_PUBLIC_NAME=$(jq -r '.xhttp_ech_public_name // "cloudflare-ech.com"' "$STATE_FILE")
    ENABLE_SNELL=$(jq -r 'if .enabled_snell == true then "1" else "0" end' "$STATE_FILE")
    SNELL_PORT=$(jq -r '.snell_port // ""' "$STATE_FILE")
    SNELL_VERSION=$(jq -r '.snell_version // 5' "$STATE_FILE")
    SNELL_PSK=$(jq -r '.snell_psk // ""' "$STATE_FILE")
    SNELL_USERKEY=$(jq -r '.snell_userkey // ""' "$STATE_FILE")
    SNELL_OBFS_MODE=$(jq -r '.snell_obfs_mode // "http"' "$STATE_FILE")
    SNELL_OBFS_HOST=$(jq -r '.snell_obfs_host // "www.bing.com"' "$STATE_FILE")
    SNELL_MODE=$(jq -r '.snell_mode // "default"' "$STATE_FILE")
    ENABLE_SS2022=$(jq -r 'if .enabled_ss2022 == true then "1" else "0" end' "$STATE_FILE")
    SS2022_PORT=$(jq -r '.ss2022_port // ""' "$STATE_FILE")
    SS2022_METHOD=$(jq -r '.ss2022_method // "2022-blake3-aes-256-gcm"' "$STATE_FILE")
    SS2022_PASSWORD=$(jq -r '.ss2022_password // ""' "$STATE_FILE")
    [ -s "$ARGO_TOKEN_FILE" ] && ARGO_TOKEN=$(cat "$ARGO_TOKEN_FILE") || ARGO_TOKEN=""
}

derive_runtime_needs() {
    NEED_CERT=0
    NEED_ORIGIN=0
    [ "$ENABLE_ANYTLS" = 1 ] && NEED_CERT=1 && NEED_ORIGIN=1
    [ "$ENABLE_NAIVE" = 1 ] && NEED_CERT=1 && NEED_ORIGIN=1
    [ "$ENABLE_VLESS_REALITY" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_ANYTLS_REALITY" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_SNELL" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_SS2022" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_XHTTP" = 1 ] && NEED_CERT=1
    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = direct ]; then NEED_CERT=1; fi
}

build_config() {
    tmp="$CONFIG_FILE.tmp.$$"
    if ipv6_kernel_enabled; then listen_addr="::"; else listen_addr="0.0.0.0"; fi
    ws_listen="$listen_addr"
    [ "$WS_MODE" = argo ] && ws_listen="127.0.0.1"

    jq -n \
      --arg listen_addr "$listen_addr" \
      --arg ws_listen "$ws_listen" \
      --arg ws_mode "$WS_MODE" \
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
      --arg naive_port "$NAIVE_PORT" \
      --arg naive_username "$NAIVE_USERNAME" \
      --arg naive_password "$NAIVE_PASSWORD" \
      --arg anyreality_port "$ANYREALITY_PORT" \
      --arg anyreality_password "$ANYREALITY_PASSWORD" \
      --arg anyreality_private "$ANYREALITY_PRIVATE" \
      --arg anyreality_sid "$ANYREALITY_SID" \
      --arg snell_port "$SNELL_PORT" --arg snell_version "$SNELL_VERSION" --arg snell_psk "$SNELL_PSK" \
      --arg snell_userkey "$SNELL_USERKEY" --arg snell_obfs_mode "$SNELL_OBFS_MODE" --arg snell_mode "$SNELL_MODE" \
      --arg ss2022_port "$SS2022_PORT" --arg ss2022_method "$SS2022_METHOD" --arg ss2022_password "$SS2022_PASSWORD" \
      --argjson enable_ss2022 "$([ "$ENABLE_SS2022" = 1 ] && printf true || printf false)" \
      --argjson enable_snell "$([ "$ENABLE_SNELL" = 1 ] && printf true || printf false)" \
      --argjson enable_anytls "$([ "$ENABLE_ANYTLS" = 1 ] && printf true || printf false)" \
      --argjson enable_ws_tls "$([ "$ENABLE_WS_TLS" = 1 ] && printf true || printf false)" \
      --argjson enable_vless_reality "$([ "$ENABLE_VLESS_REALITY" = 1 ] && printf true || printf false)" \
      --argjson enable_naive "$([ "$ENABLE_NAIVE" = 1 ] && printf true || printf false)" \
      --argjson enable_anytls_reality "$([ "$ENABLE_ANYTLS_REALITY" = 1 ] && printf true || printf false)" \
      '{log:{level:"info",timestamp:true},inbounds:[
        (if $enable_anytls then {type:"anytls",tag:"anytls-in",listen:$listen_addr,listen_port:($anytls_port|tonumber),users:[{name:"primary",password:$anytls_password}],tls:{enabled:true,server_name:$tls_domain,certificate_path:$cert_file,key_path:$key_file}} else empty end),
        (if $enable_ws_tls then (if $ws_mode == "argo" then {type:"vless",tag:"vless-ws-argo-in",listen:$ws_listen,listen_port:($ws_port|tonumber),users:[{uuid:$ws_uuid}],transport:{type:"ws",path:$ws_path}} else {type:"vless",tag:"vless-ws-tls-in",listen:$ws_listen,listen_port:($ws_port|tonumber),users:[{uuid:$ws_uuid}],tls:{enabled:true,server_name:$tls_domain,certificate_path:$cert_file,key_path:$key_file},transport:{type:"ws",path:$ws_path}} end) else empty end),
        (if $enable_vless_reality then {type:"vless",tag:"vless-reality-in",listen:$listen_addr,listen_port:($reality_port|tonumber),users:[{uuid:$reality_uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$reality_sni,reality:{enabled:true,handshake:{server:$reality_sni,server_port:443},private_key:$reality_private,short_id:[$reality_sid]}}} else empty end),
        (if $enable_naive then {type:"naive",tag:"naive-in",network:"tcp",listen:$listen_addr,listen_port:($naive_port|tonumber),users:[{username:$naive_username,password:$naive_password}],tls:{enabled:true,certificate_path:$cert_file,key_path:$key_file}} else empty end),
        (if $enable_anytls_reality then {type:"anytls",tag:"anytls-reality-in",listen:$listen_addr,listen_port:($anyreality_port|tonumber),users:[{name:"primary",password:$anyreality_password}],tls:{enabled:true,server_name:$reality_sni,reality:{enabled:true,handshake:{server:$reality_sni,server_port:443},private_key:$anyreality_private,short_id:[$anyreality_sid]}}} else empty end),
        (if $enable_ss2022 then {type:"shadowsocks",tag:"ss2022-in",listen:$listen_addr,listen_port:($ss2022_port|tonumber),method:$ss2022_method,password:$ss2022_password} else empty end),
        (if $enable_snell then (if $snell_version=="5" then {type:"snell",tag:"snell-in",listen:$listen_addr,listen_port:($snell_port|tonumber),version:5,psk:$snell_psk,users:[{name:"primary",userkey:$snell_userkey}],obfs_mode:$snell_obfs_mode} else {type:"snell",tag:"snell-in",listen:$listen_addr,listen_port:($snell_port|tonumber),version:6,psk:$snell_psk,users:[{name:"primary",userkey:$snell_userkey}],mode:$snell_mode} end) else empty end)
      ],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp" || {
        rm -f "$tmp"
        warn '无法生成 sing-box 配置；原配置未更改。'
        return 1
    }
    # Preserve inbounds/outbounds not owned by this manager. This is critical
    # for user-added protocols such as Shadowsocks 2022: rebuilding a managed
    # Snell/AnyTLS/etc. inbound must never silently erase unrelated entries.
    if [ -s "$CONFIG_FILE" ]; then
        if ! jq -e 'type == "object" and (.inbounds|type == "array")' "$CONFIG_FILE" >/dev/null 2>&1; then
            rm -f "$tmp"
            warn '现有 config.json 无法解析；为防止丢失 SS2022 或其他自定义节点，已停止重建。请先修复原配置。'
            return 1
        fi
        merged="$tmp.merge.$$"
        if [ "$ENABLE_SS2022" = 1 ] || { [ -s "$STATE_FILE" ] && jq -e '.enabled_ss2022 == true' "$STATE_FILE" >/dev/null 2>&1; }; then
            manage_ss2022_tag=true
        else
            manage_ss2022_tag=false
        fi
        if ! jq -s --argjson manage_ss2022 "$manage_ss2022_tag" '
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
        ' "$tmp" "$CONFIG_FILE" > "$merged"; then
            rm -f "$tmp" "$merged"
            warn '合并现有自定义协议配置失败；原配置未更改。'
            return 1
        fi
        mv -f "$merged" "$tmp"
    fi
    if ! "$SB_BIN" check -c "$tmp"; then
        rm -f "$tmp"
        warn 'sing-box 配置检查失败，原配置未更改。'
        return 1
    fi

    config_backup="$CONFIG_FILE.rollback.$$"
    state_backup="$STATE_FILE.rollback.$$"
    had_config=0
    had_state=0
    if [ -f "$CONFIG_FILE" ]; then
        cp -p "$CONFIG_FILE" "$config_backup" || { rm -f "$tmp" "$config_backup"; warn '无法备份现有 config.json；原配置未更改。'; return 1; }
        had_config=1
    fi
    if [ -f "$STATE_FILE" ]; then
        cp -p "$STATE_FILE" "$state_backup" || { rm -f "$tmp" "$config_backup" "$state_backup"; warn '无法备份现有 manager.json；原配置未更改。'; return 1; }
        had_state=1
    fi
    if ! chown root:sing-box "$tmp" || ! chmod 0640 "$tmp" || ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        [ "$had_config" -eq 0 ] || cp -p "$config_backup" "$CONFIG_FILE"
        rm -f "$config_backup" "$state_backup"
        warn '无法安全写入 config.json；原配置已保留。'
        return 1
    fi
    if ! service_restart; then
        warn '新配置启动失败，正在恢复旧配置和管理状态。'
        if [ "$had_config" -eq 1 ]; then cp -p "$config_backup" "$CONFIG_FILE"; else rm -f "$CONFIG_FILE"; fi
        if [ "$had_state" -eq 1 ]; then cp -p "$state_backup" "$STATE_FILE"; else rm -f "$STATE_FILE"; fi
        service_restart || true
        rm -f "$config_backup" "$state_backup"
        return 1
    fi
    if ! save_state; then
        warn '管理状态写入失败，正在恢复旧配置和管理状态。'
        if [ "$had_config" -eq 1 ]; then cp -p "$config_backup" "$CONFIG_FILE"; else rm -f "$CONFIG_FILE"; fi
        if [ "$had_state" -eq 1 ]; then cp -p "$state_backup" "$STATE_FILE"; else rm -f "$STATE_FILE"; fi
        service_restart || true
        rm -f "$config_backup" "$state_backup"
        return 1
    fi
    rm -f "$config_backup" "$state_backup"
    msg '配置已检查并应用，sing-box 已重启。'
}

node_tag() {
    family=$1
    address=$2
    protocol=$3
    family_lc=$(printf '%s' "$family" | tr '[:upper:]' '[:lower:]')
    if [ "$family_lc" = ipv4 ]; then
        case "$address" in *[!0-9.]*) family_lc=domain ;; esac
    fi
    tag="${family_lc}-${address}"
    [ -z "$NODE_LABEL" ] || tag="${tag}-${NODE_LABEL}"
    printf '%s-%s' "$tag" "$protocol"
}

node_tag_single() {
    protocol=$1
    case "$WS_SERVER" in
        *:*) family_lc=ipv6 ;;
        *[!0-9.]*) family_lc=domain ;;
        *) family_lc=ipv4 ;;
    esac
    tag="${family_lc}-${WS_SERVER}"
    [ -z "$NODE_LABEL" ] || tag="${tag}-${NODE_LABEL}"
    printf '%s-%s' "$tag" "$protocol"
}

change_node_label() {
    printf '\n当前节点辨识符：%s\n' "${NODE_LABEL:-（未设置）}"
    msg '该辨识符会添加到地址之后、协议名称之前；WS TLS 仍只有一个节点。'
    msg '示例：填写 KC 后，节点名称变为 ipv4-23.147.232.192-KC-anytls、ipv6-2602:...-KC-anytls、ipv4-23.147.232.192-KC-vless+ws+tls。'
    msg '支持中文、英文字母和数字，可使用点、下划线、短横线；最多 20 个 Unicode 字符。'
    msg '示例：香港、东京、日本01、KC、LAX-01。留空可清除辨识符。'
    ask_value '新的节点辨识符（留空清除）' ''
    new_label=$REPLY
    if [ -n "$new_label" ]; then
        label_length=$(jq -nr --arg node_label "$new_label" '$node_label | length')
        [ "$label_length" -le 20 ] || { warn '辨识符最多 20 个字符（中文按一个字符计算）。'; return 0; }
        jq -ne --arg node_label "$new_label" '$node_label | test("^[\\p{L}\\p{N}._-]+$")' >/dev/null 2>&1 ||
            { warn '格式无效。支持中文、英文字母、数字、点、下划线和短横线；不支持空格及特殊符号。'; return 0; }
    fi
    NODE_LABEL=$new_label
    save_state
    msg "节点辨识符已保存：${NODE_LABEL:-（未设置）}"
    show_nodes
}

write_anyreality_client_json() {
    [ "$ENABLE_ANYTLS_REALITY" = 1 ] || { rm -f "$APP_DIR/anytls-reality-client.json"; return 0; }
    client_server=${ORIGIN_ADDR:-$ORIGIN_IPV6}
    [ -n "$client_server" ] || return 0
    client_json_tmp="$APP_DIR/anytls-reality-client.json.tmp.$$"
    jq -n \
      --arg server "$client_server" \
      --arg server_port "$ANYREALITY_PORT" \
      --arg password "$ANYREALITY_PASSWORD" \
      --arg server_name "$REALITY_SNI" \
      --arg public_key "$ANYREALITY_PUBLIC" \
      --arg short_id "$ANYREALITY_SID" \
      '{type:"anytls",tag:"anytls-reality",server:$server,server_port:($server_port|tonumber),password:$password,tls:{enabled:true,server_name:$server_name,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$public_key,short_id:$short_id}}}' > "$client_json_tmp" || { rm -f "$client_json_tmp"; return 1; }
    chmod 0600 "$client_json_tmp"
    chown root:root "$client_json_tmp"
    mv "$client_json_tmp" "$APP_DIR/anytls-reality-client.json"
}

show_nodes() {
    WS_PATH_ENC=$(printf '%s' "$WS_PATH" | sed 's#/#%2F#g')
    nodes_tmp="$APP_DIR/nodes.txt.tmp.$$"
    {
        printf 'sing-box 节点信息（仅显示已安装协议）\n辨识符：%s\n\n' "${NODE_LABEL:-未设置}"

        if [ -n "$ORIGIN_ADDR" ]; then
            origin_uri=$(uri_host "$ORIGIN_ADDR")
            if [ "$ENABLE_ANYTLS" = 1 ]; then
                tag=$(node_tag IPv4 "$ORIGIN_ADDR" anytls); tag_uri=$(jq -nr --arg tag "$tag" '$tag | @uri')
                ANYTLS_LINK="anytls://${ANYTLS_PASSWORD}@${origin_uri}:${ANYTLS_PORT}/?sni=${TLS_DOMAIN}#${tag_uri}"
                printf '[%s] AnyTLS | 地址：%s | TCP：%s\n%s\n\n' "$tag" "$ORIGIN_ADDR" "$ANYTLS_PORT" "$ANYTLS_LINK"
            fi
            if [ "$ENABLE_ANYTLS_REALITY" = 1 ]; then
                tag=$(node_tag IPv4 "$ORIGIN_ADDR" anytls+reality); tag_uri=$(jq -nr --arg tag "$tag" '$tag | @uri')
                ANYREALITY_LINK="anytls://${ANYREALITY_PASSWORD}@${origin_uri}:${ANYREALITY_PORT}?security=reality&type=tcp&sni=${REALITY_SNI}&fp=chrome&pbk=${ANYREALITY_PUBLIC}&sid=${ANYREALITY_SID}#${tag_uri}"
                printf '[%s] AnyTLS + Reality | 地址：%s | TCP：%s\n%s\n\n' "$tag" "$ORIGIN_ADDR" "$ANYREALITY_PORT" "$ANYREALITY_LINK"
            fi
            if [ "$ENABLE_VLESS_REALITY" = 1 ]; then
                tag=$(node_tag IPv4 "$ORIGIN_ADDR" vless+reality); tag_uri=$(jq -nr --arg tag "$tag" '$tag | @uri')
                REALITY_LINK="vless://${REALITY_UUID}@${origin_uri}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&type=tcp#${tag_uri}"
                printf '[%s] VLESS + Reality | 地址：%s | TCP：%s\n%s\n\n' "$tag" "$ORIGIN_ADDR" "$REALITY_PORT" "$REALITY_LINK"
            fi
            if [ "$ENABLE_NAIVE" = 1 ]; then
                tag=$(node_tag IPv4 "$ORIGIN_ADDR" naiveproxy); tag_uri=$(jq -nr --arg tag "$tag" '$tag | @uri')
                NAIVE_LINK="naive+https://${NAIVE_USERNAME}:${NAIVE_PASSWORD}@${origin_uri}:${NAIVE_PORT}/?sni=${TLS_DOMAIN}#${tag_uri}"
                printf '[%s] NaiveProxy | 地址：%s | TCP：%s\n%s\n\n' "$tag" "$ORIGIN_ADDR" "$NAIVE_PORT" "$NAIVE_LINK"
            fi
        fi

        if [ "$ENABLE_WS_TLS" = 1 ] && [ -n "$WS_SERVER" ]; then
            ws_server_uri=$(uri_host "$WS_SERVER")
            tag=$(node_tag_single vless+ws+tls); tag_uri=$(jq -nr --arg tag "$tag" '$tag | @uri')
            if [ "$WS_MODE" = argo ]; then
                ws_link_port=443
                ws_link_sni=$ARGO_HOST
                ws_link_host=$ARGO_HOST
            else
                ws_link_port=$WS_PORT
                ws_link_sni=$TLS_DOMAIN
                ws_link_host=$WS_HOST
            fi
            WS_LINK="vless://${WS_UUID}@${ws_server_uri}:${ws_link_port}?encryption=none&security=tls&sni=${ws_link_sni}&type=ws&host=${ws_link_host}&path=${WS_PATH_ENC}#${tag_uri}"
            printf '[%s] VLESS + WebSocket + TLS%s | 地址：%s | 客户端端口：%s | 本机端口：%s\n%s\n\n' "$tag" "$([ "$WS_MODE" = argo ] && printf ' (Cloudflare Tunnel)' || true)" "$WS_SERVER" "$ws_link_port" "$WS_PORT" "$WS_LINK"
        fi

        if [ "$ENABLE_XHTTP" = 1 ]; then
            xhttp_path_uri=$(jq -nr --arg p "$XHTTP_PATH" '$p | @uri')
            xhttp_tag="domain-${TLS_DOMAIN}"
            [ -z "$NODE_LABEL" ] || xhttp_tag="${xhttp_tag}-${NODE_LABEL}"
            xhttp_tag="${xhttp_tag}-vless+xhttp+ech"
            xhttp_tag_uri=$(jq -nr --arg tag "$xhttp_tag" '$tag | @uri')
            xhttp_link="vless://${XHTTP_UUID}@${TLS_DOMAIN}:${XHTTP_PORT}?encryption=none&security=tls&sni=${TLS_DOMAIN}&type=xhttp&path=${xhttp_path_uri}&mode=${XHTTP_MODE}&fp=chrome#${xhttp_tag_uri}"
            printf '[%s] VLESS + XHTTP + TLS + ECH | 地址：%s | TCP：%s\n%s\n' "$xhttp_tag" "$TLS_DOMAIN" "$XHTTP_PORT" "$xhttp_link"
            printf 'ECH Config List（客户端启用 ECH 必填）：\n%s\n' "$(cat "$XRAY_ECH_CONFIG_FILE" 2>/dev/null || true)"
            printf '完整 Xray 客户端配置：%s\n' "$XRAY_CLIENT_CONFIG_FILE"
            printf '提示：VLESS 分享链接本身不包含 ECH Config；需要导入上述 JSON，或在客户端手动填写 ECH Config List。\n\n'
        fi
        if [ "$ENABLE_SS2022" = 1 ]; then
            ss_server=${ORIGIN_ADDR:-$ORIGIN_IPV6}
            ss_tag="${ss_server}"; [ -z "$NODE_LABEL" ] || ss_tag="${ss_tag}-${NODE_LABEL}"
            ss_host_uri=$(uri_host "$ss_server")
            ss_tag_uri=$(jq -nr --arg tag "${ss_tag}-ss2022" '$tag | @uri')
            ss_userinfo=$(printf '%s' "$SS2022_METHOD:$SS2022_PASSWORD" | base64 | tr -d '\r\n')
            SS2022_LINK="ss://${ss_userinfo}@${ss_host_uri}:${SS2022_PORT}#${ss_tag_uri}"
            printf '[%s-ss2022] Shadowsocks 2022 | 地址：%s | TCP：%s | method：%s\n密码：%s\n%s\n\n' "$ss_tag" "$ss_server" "$SS2022_PORT" "$SS2022_METHOD" "$SS2022_PASSWORD" "$SS2022_LINK"
        fi
        if [ "$ENABLE_SNELL" = 1 ]; then
            snell_server=${ORIGIN_ADDR:-$ORIGIN_IPV6}
            snell_tag="${snell_server}"
            [ -z "$NODE_LABEL" ] || snell_tag="${snell_tag}-${NODE_LABEL}"
            printf '[%s-snell] Snell v%s | 地址：%s | TCP：%s\n' "$snell_tag" "$SNELL_VERSION" "$snell_server" "$SNELL_PORT"
            printf 'PSK：%s\nUserKey：%s\n' "$SNELL_PSK" "$SNELL_USERKEY"
            if [ "$SNELL_VERSION" = 5 ]; then printf 'HTTP 混淆：%s | Host：%s\n' "$SNELL_OBFS_MODE" "$SNELL_OBFS_HOST"; else printf 'Traffic shaping：%s\n' "$SNELL_MODE"; fi
            printf 'sing-box 客户端配置片段：%s\n\n' "$SNELL_CLIENT_CONFIG_FILE"
        fi
        if [ -n "$ORIGIN_IPV6" ]; then
            origin6_uri=$(uri_host "$ORIGIN_IPV6")
            if [ "$ENABLE_ANYTLS" = 1 ]; then
                tag=$(node_tag IPv6 "$ORIGIN_IPV6" anytls); tag_uri=$(jq -nr --arg tag "$tag" '$tag | @uri')
                ANYTLS6_LINK="anytls://${ANYTLS_PASSWORD}@${origin6_uri}:${ANYTLS_PORT}/?sni=${TLS_DOMAIN}#${tag_uri}"
                printf '[%s] AnyTLS | 地址：[%s] | TCP：%s\n%s\n\n' "$tag" "$ORIGIN_IPV6" "$ANYTLS_PORT" "$ANYTLS6_LINK"
            fi
            if [ "$ENABLE_ANYTLS_REALITY" = 1 ]; then
                tag=$(node_tag IPv6 "$ORIGIN_IPV6" anytls+reality); tag_uri=$(jq -nr --arg tag "$tag" '$tag | @uri')
                ANYREALITY6_LINK="anytls://${ANYREALITY_PASSWORD}@${origin6_uri}:${ANYREALITY_PORT}?security=reality&type=tcp&sni=${REALITY_SNI}&fp=chrome&pbk=${ANYREALITY_PUBLIC}&sid=${ANYREALITY_SID}#${tag_uri}"
                printf '[%s] AnyTLS + Reality | 地址：[%s] | TCP：%s\n%s\n\n' "$tag" "$ORIGIN_IPV6" "$ANYREALITY_PORT" "$ANYREALITY6_LINK"
            fi
            if [ "$ENABLE_VLESS_REALITY" = 1 ]; then
                tag=$(node_tag IPv6 "$ORIGIN_IPV6" vless+reality); tag_uri=$(jq -nr --arg tag "$tag" '$tag | @uri')
                REALITY6_LINK="vless://${REALITY_UUID}@${origin6_uri}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&type=tcp#${tag_uri}"
                printf '[%s] VLESS + Reality | 地址：[%s] | TCP：%s\n%s\n\n' "$tag" "$ORIGIN_IPV6" "$REALITY_PORT" "$REALITY6_LINK"
            fi
            if [ "$ENABLE_NAIVE" = 1 ]; then
                tag=$(node_tag IPv6 "$ORIGIN_IPV6" naiveproxy); tag_uri=$(jq -nr --arg tag "$tag" '$tag | @uri')
                NAIVE6_LINK="naive+https://${NAIVE_USERNAME}:${NAIVE_PASSWORD}@${origin6_uri}:${NAIVE_PORT}/?sni=${TLS_DOMAIN}#${tag_uri}"
                printf '[%s] NaiveProxy | 地址：[%s] | TCP：%s\n%s\n\n' "$tag" "$ORIGIN_IPV6" "$NAIVE_PORT" "$NAIVE6_LINK"
            fi
        fi
        if [ "$ENABLE_WS_TLS" = 0 ] && [ "$ENABLE_ANYTLS" = 0 ] && [ "$ENABLE_VLESS_REALITY" = 0 ] && [ "$ENABLE_NAIVE" = 0 ] && [ "$ENABLE_ANYTLS_REALITY" = 0 ] && [ "$ENABLE_XHTTP" = 0 ] && [ "$ENABLE_SNELL" = 0 ]; then
            printf '没有启用任何协议。\n'
        fi
    } > "$nodes_tmp"
    chmod 0600 "$nodes_tmp"
    mv "$nodes_tmp" "$APP_DIR/nodes.txt"
    if [ "$ENABLE_ANYTLS_REALITY" = 1 ]; then
        if write_anyreality_client_json; then printf 'AnyTLS + Reality 客户端配置片段：%s/anytls-reality-client.json\n' "$APP_DIR"; else warn 'AnyTLS + Reality 客户端 JSON 片段生成失败。'; fi
    else rm -f "$APP_DIR/anytls-reality-client.json"; fi
    if [ "$ENABLE_XHTTP" = 1 ]; then write_xhttp_client_json || warn 'XHTTP 客户端 JSON 生成失败。'; fi
    if [ "$ENABLE_SNELL" = 1 ]; then write_snell_client_json || warn 'Snell 客户端 JSON 生成失败。'; fi
    msg '================ 节点信息 ================'
    cat "$APP_DIR/nodes.txt"
    printf '节点文件：%s/nodes.txt\n' "$APP_DIR"
    printf '===========================================\n'
}

overlay_install() {
    need_root
    msg '========== sing-box 覆盖安装（保留所选协议和现有凭据） =========='
    [ -s "$STATE_FILE" ] || err '找不到现有 manager.json，不能执行覆盖安装。'
    manager_state_is_valid || err '现有 manager.json 缺少已启用协议所需参数；为避免破坏原配置，停止覆盖安装。'

    selected_count=$((ENABLE_ANYTLS + ENABLE_WS_TLS + ENABLE_VLESS_REALITY + ENABLE_NAIVE + ENABLE_ANYTLS_REALITY + ENABLE_XHTTP + ENABLE_SNELL + ENABLE_SS2022))
    [ "$selected_count" -gt 0 ] || err '当前没有启用的协议。'
    NEED_CERT=0; NEED_ORIGIN=0
    [ "$ENABLE_ANYTLS" = 1 ] && NEED_CERT=1 && NEED_ORIGIN=1
    [ "$ENABLE_NAIVE" = 1 ] && NEED_CERT=1 && NEED_ORIGIN=1
    [ "$ENABLE_VLESS_REALITY" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_ANYTLS_REALITY" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_SNELL" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_SS2022" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_XHTTP" = 1 ] && NEED_CERT=1
    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = direct ]; then NEED_CERT=1; fi
    if [ "$NEED_CERT" = 1 ]; then
        [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ] || err '现有 TLS 证书缺失；覆盖升级不会自动重新申请证书。'
        check_cert_pair "$CERT_FILE" "$KEY_FILE" "$TLS_DOMAIN" || err '现有 TLS 证书或私钥无效。'
        if [ "$CERT_MODE" = cloudflare ]; then
            [ -s "$CF_TOKEN_FILE" ] || err 'Cloudflare DNS API Token 文件缺失，停止覆盖升级。'
        fi
        setup_reload_hook
    fi
    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ]; then
        [ -s "$ARGO_TOKEN_FILE" ] || err 'Cloudflare Tunnel Token 文件缺失，停止覆盖升级。'
    fi

    if [ "${SB_CORE_PREPARED:-0}" != 1 ]; then
        install_dependencies_and_core
    else
        msg '核心已由网页一键命令预装并通过版本检查，跳过重复安装。'
    fi
    ensure_service_account
    enable_bbr
    create_service
    if [ "$ENABLE_XHTTP" = 1 ]; then
        install_xray_core
        create_xray_service
        [ -s "$XRAY_ECH_KEYS_FILE" ] && [ -s "$XRAY_ECH_CONFIG_FILE" ] || generate_xhttp_ech_keys || err 'XHTTP ECH 密钥初始化失败。'
    fi
    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ]; then
        install_cloudflared
        create_cloudflared_service
    fi
    build_config || err '覆盖安装未能应用当前所选协议配置。'
    save_state || err '覆盖安装成功但管理状态保存失败。'
    if [ "$ENABLE_XHTTP" = 1 ]; then build_xray_config || err 'Xray XHTTP 配置未能应用；sing-box 原节点保持不变。'; fi
    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ]; then
        start_cloudflared_service || warn 'Cloudflare Tunnel 服务启动失败，请检查 Token 和 cloudflared 日志。'
        msg "Cloudflare Tunnel 公网主机名：$ARGO_HOST → http://127.0.0.1:$WS_PORT"
    fi
    msg '覆盖升级完成：保留原有已选协议、UUID、密码、密钥、端口和节点路径。'
    show_nodes
}

install_wizard() {
    need_root
    ORIGIN_ADDR=""; ORIGIN_IPV6=""; WS_SERVER=""; WS_HOST=""
    ENABLE_ANYTLS=0; ENABLE_WS_TLS=0; ENABLE_VLESS_REALITY=0; ENABLE_NAIVE=0; ENABLE_ANYTLS_REALITY=0; ENABLE_XHTTP=0; ENABLE_SNELL=0; ENABLE_SS2022=0
    msg '========== sing-box 选择性安装向导 =========='
    ask_value '安装普通 AnyTLS？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_ANYTLS=1 ;; esac
    ask_value '安装 VLESS + WS？(y/N)' 'y'; case "$REPLY" in y|Y|yes|YES) ENABLE_WS_TLS=1 ;; esac
    ask_value '安装 VLESS + Reality？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_VLESS_REALITY=1 ;; esac
    ask_value '安装 NaiveProxy？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_NAIVE=1 ;; esac
    ask_value '安装 AnyTLS + Reality？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_ANYTLS_REALITY=1 ;; esac
    ask_value '安装 VLESS + XHTTP + ECH？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_XHTTP=1 ;; esac
    ask_value '安装 Snell？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_SNELL=1 ;; esac
    ask_value '安装 Shadowsocks 2022（SS2022）？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_SS2022=1 ;; esac
    SS2022_METHOD=2022-blake3-aes-256-gcm; SS2022_PASSWORD=""; SS2022_PORT=""
    if [ "$ENABLE_SS2022" = 1 ]; then
        ask_value 'SS2022 加密方式（128/256）' '256'
        case "$(trim_value "$REPLY")" in 128) SS2022_METHOD=2022-blake3-aes-128-gcm ;; 256) SS2022_METHOD=2022-blake3-aes-256-gcm ;; *) err 'SS2022 仅支持 128 或 256。' ;; esac
    fi
    selected_count=$((ENABLE_ANYTLS + ENABLE_WS_TLS + ENABLE_VLESS_REALITY + ENABLE_NAIVE + ENABLE_ANYTLS_REALITY + ENABLE_XHTTP + ENABLE_SNELL + ENABLE_SS2022))
    [ "$selected_count" -gt 0 ] || err '至少选择一种协议。'

    WS_MODE=direct; ARGO_HOST=""; ARGO_TUNNEL_NAME=""; ARGO_TOKEN=""
    XHTTP_ECH_PUBLIC_NAME=cloudflare-ech.com
    XHTTP_MODE=auto
    XHTTP_PATH=""
    if [ "$ENABLE_XHTTP" = 1 ]; then
        msg 'VLESS XHTTP + ECH 使用独立 Xray-core；需要真实 TLS 证书、DNS Only 域名和可直达的 TCP 入站端口。'
        ask_value 'ECH Public Name（外层 ClientHello 显示的公开名称；默认 cloudflare-ech.com）' 'cloudflare-ech.com'
        XHTTP_ECH_PUBLIC_NAME=$(trim_value "$REPLY")
        valid_domain "$XHTTP_ECH_PUBLIC_NAME" || err 'ECH Public Name 必须是有效域名。'
        ask_value 'XHTTP 模式（auto / packet-up / stream-up / stream-one）' 'auto'
        XHTTP_MODE=$(trim_value "$REPLY")
        case "$XHTTP_MODE" in auto|packet-up|stream-up|stream-one) ;; *) err '不支持的 XHTTP 模式。' ;; esac
    fi
    SNELL_VERSION=5; SNELL_OBFS_MODE=http; SNELL_OBFS_HOST=www.bing.com; SNELL_MODE=default
    if [ "$ENABLE_SNELL" = 1 ]; then
        msg 'Snell 入站由 sing-box 1.14.0 或更新版本提供。推荐 v5 以兼容常见 Snell 客户端。'
        ask_value 'Snell 版本（5/6）' '5'
        SNELL_VERSION=$(trim_value "$REPLY")
        case "$SNELL_VERSION" in
            5) ask_value 'Snell v5 HTTP 混淆（http/none）' 'http'; SNELL_OBFS_MODE=$(trim_value "$REPLY"); case "$SNELL_OBFS_MODE" in http|none) ;; *) err 'Snell v5 混淆仅支持 http 或 none。' ;; esac ;;
            6) ask_value 'Snell v6 流量整形（default/unshaped/unsafe-raw）' 'default'; SNELL_MODE=$(trim_value "$REPLY"); case "$SNELL_MODE" in default|unshaped|unsafe-raw) ;; *) err 'Snell v6 mode 无效。' ;; esac ;;
            *) err 'Snell 版本只能选择 5 或 6。' ;;
        esac
    fi
    if [ "$ENABLE_WS_TLS" = 1 ]; then
        ask_value 'VLESS + WS 接入方式：1=直连 TLS，2=Cloudflare Tunnel（Argo）' '2'
        case "$REPLY" in 1) WS_MODE=direct ;; 2) WS_MODE=argo ;; *) err '请选择 1 或 2。' ;; esac
        if [ "$WS_MODE" = argo ]; then
            ask_value 'Cloudflare 固定 Tunnel 公网主机名（例如 ws.example.com）' ''
            ARGO_HOST=$(trim_value "$REPLY")
            ask_value 'Tunnel 备注名（可选，仅在本机管理菜单显示）' ''
            ARGO_TUNNEL_NAME=$(trim_value "$REPLY")
            ask_secret 'Cloudflare Tunnel Token（Zero Trust → Networks → Tunnels → Add a replica）'
            ARGO_TOKEN=$(trim_value "$REPLY")
            valid_argo_token "$ARGO_TOKEN" || err 'Cloudflare Tunnel Token 格式无效；请粘贴 Add a replica 命令中的完整 eyJ... Token。'
            ask_value '客户端连接地址/优选 IP（可留空，默认 Argo 主机名）' "$ARGO_HOST"
            WS_SERVER=$(trim_value "$REPLY")
        fi
    fi

    NEED_CERT=0
    [ "$ENABLE_ANYTLS" = 1 ] && NEED_CERT=1
    [ "$ENABLE_NAIVE" = 1 ] && NEED_CERT=1
    [ "$ENABLE_XHTTP" = 1 ] && NEED_CERT=1
    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = direct ]; then NEED_CERT=1; fi
    if [ "$NEED_CERT" = 1 ]; then
        msg '所选协议需要 TLS 证书。证书方式：1=Cloudflare DNS-01，2=HTTP-01，3=手动导入。'
        ask_value '请选择证书方式（1/2/3）' '1'
        case "$REPLY" in 1) CERT_MODE=cloudflare ;; 2) CERT_MODE=standalone ;; 3) CERT_MODE=manual ;; *) err '证书方式只能选择 1、2 或 3。' ;; esac
        if [ "$CERT_MODE" = cloudflare ]; then
            ask_value 'Cloudflare DNS 区域根域名（例如 example.com）' ''
            CF_ZONE_NAME=$(trim_value "$REPLY")
            ask_value 'TLS 证书域名（例如 node.example.com）' "$CF_ZONE_NAME"
            TLS_DOMAIN=$(trim_value "$REPLY")
            ask_secret 'Cloudflare DNS API Token（Zone:DNS:Edit）'
            cf_token=$(trim_value "$REPLY")
            ask_value '证书账户邮箱（可留空）' ''; cert_email=$(trim_value "$REPLY")
            ask_value 'Cloudflare Zone ID（可选）' ''; zone_id=$(trim_value "$REPLY")
        else
            CF_ZONE_NAME=""
            ask_value 'TLS 证书域名（例如 node.example.com）' ''
            TLS_DOMAIN=$(trim_value "$REPLY")
            if [ "$CERT_MODE" = manual ]; then
                msg '稍后会要求输入现有证书链和私钥文件路径。'
            fi
        fi
    else
        CERT_MODE=none; TLS_DOMAIN=""; CF_ZONE_NAME=""; cf_token=""; cert_email=""; zone_id=""
    fi

    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = direct ]; then
        ask_value 'WS 客户端连接地址/优选 IP（可留空使用 TLS 域名）' "$TLS_DOMAIN"
        WS_SERVER=$(trim_value "$REPLY")
    fi
    if [ "$ENABLE_VLESS_REALITY" = 1 ] || [ "$ENABLE_ANYTLS_REALITY" = 1 ]; then
        ask_value 'Reality SNI / 握手目标域名' 'www.bing.com'
        REALITY_SNI=$(trim_value "$REPLY")
    else REALITY_SNI=""; fi
    ask_value '节点辨识符（支持中文；可留空）' ''
    NODE_LABEL=$(trim_value "$REPLY")
    ask_ports
    install_from_config
}

resolve_install_domains() {
    if [ "$NEED_CERT" = 1 ]; then
        case "$CERT_MODE" in
            cloudflare)
                valid_cert_domain "$CF_ZONE_NAME" || err '请输入有效的 Cloudflare DNS 区域根域名。'
                TLS_DOMAIN=${TLS_DOMAIN:-$CF_ZONE_NAME}
                domain_belongs_to_zone "$TLS_DOMAIN" "$CF_ZONE_NAME" || err "TLS 证书域名 $TLS_DOMAIN 必须属于 Cloudflare 区域 $CF_ZONE_NAME。"
                ;;
            standalone|manual) valid_cert_domain "$TLS_DOMAIN" || err '请输入有效的 TLS 证书域名。' ;;
            *) err '所选协议需要 TLS 证书，但证书方式无效。' ;;
        esac
    else
        TLS_DOMAIN=""
        WS_HOST=""
    fi

    if [ "$ENABLE_WS_TLS" = 1 ]; then
        if [ "$WS_MODE" = argo ]; then
            valid_cert_domain "$ARGO_HOST" || err '请输入有效且已接入 Cloudflare 的 Argo 公网主机名。'
            WS_HOST=$ARGO_HOST
            WS_SERVER=${WS_SERVER:-$ARGO_HOST}
        else
            WS_SERVER=${WS_SERVER:-$TLS_DOMAIN}
            WS_HOST=${WS_HOST:-$TLS_DOMAIN}
            valid_domain "$WS_HOST" || err 'WS HTTP Host 必须是有效域名。'
        fi
    else
        WS_SERVER=""
        WS_HOST=""
    fi
}

resolve_install_addresses() {
    if [ "$NEED_ORIGIN" = 1 ] && [ -z "$ORIGIN_ADDR" ] && [ -z "$ORIGIN_IPV6" ]; then
        ORIGIN_ADDR=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
        if ! valid_ipv4_address "$ORIGIN_ADDR"; then ORIGIN_ADDR=""; fi
        if ipv6_kernel_enabled; then
            ORIGIN_IPV6=$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)
            if ! valid_ipv6_address "$ORIGIN_IPV6"; then ORIGIN_IPV6=""; fi
        fi
    fi
    [ "$ORIGIN_ADDR" = "-" ] && ORIGIN_ADDR=""
    [ "$ORIGIN_IPV6" = "-" ] && ORIGIN_IPV6=""
    if [ "$NEED_ORIGIN" = 1 ]; then
        if [ -n "$ORIGIN_ADDR" ]; then valid_main_address "$ORIGIN_ADDR" || err '源站主地址必须是 IPv4 地址或域名。'; fi
        if [ -n "$ORIGIN_IPV6" ]; then
            ipv6_kernel_enabled || err '检测到系统未启用 IPv6，不能配置 IPv6 源站地址。'
            valid_ipv6_address "$ORIGIN_IPV6" || err '源站 IPv6 地址格式不正确，或服务器没有到该地址的 IPv6 路由。'
        fi
        [ -n "$ORIGIN_ADDR" ] || [ -n "$ORIGIN_IPV6" ] || err '所选直连协议需要公网 IPv4 或 IPv6；未能检测到源站地址。'
    else
        ORIGIN_ADDR=""
        ORIGIN_IPV6=""
    fi

    PREFERRED_IP=""
    PREFERRED_IPV6=""
    if [ "$ENABLE_WS_TLS" = 1 ] && [ -n "$WS_SERVER" ]; then
        case "$WS_SERVER" in
            *:*)
                valid_ipv6_literal "$WS_SERVER" || err 'WS 客户端 IPv6 地址格式不正确。'
                PREFERRED_IPV6=$WS_SERVER
                ;;
            *)
                valid_main_address "$WS_SERVER" || err 'WS TLS 地址应为 IPv4 或域名；IPv6 请填写不带方括号的 IPv6 地址。'
                PREFERRED_IP=$WS_SERVER
                ;;
        esac
    fi
    msg "源站地址：IPv4=${ORIGIN_ADDR:-不需要/未检测到}，IPv6=${ORIGIN_IPV6:-未设置}"
}

install_from_config() {
    selected_count=0
    for enabled in "$ENABLE_ANYTLS" "$ENABLE_WS_TLS" "$ENABLE_VLESS_REALITY" "$ENABLE_NAIVE" "$ENABLE_ANYTLS_REALITY" "$ENABLE_XHTTP" "$ENABLE_SNELL" "$ENABLE_SS2022"; do
        [ "$enabled" = 1 ] && selected_count=$((selected_count + 1))
    done
    [ "$selected_count" -gt 0 ] || err '至少选择一种协议。'

    NEED_CERT=0
    NEED_ORIGIN=0
    [ "$ENABLE_ANYTLS" = 1 ] && NEED_CERT=1 && NEED_ORIGIN=1
    [ "$ENABLE_NAIVE" = 1 ] && NEED_CERT=1 && NEED_ORIGIN=1
    [ "$ENABLE_VLESS_REALITY" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_ANYTLS_REALITY" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_SNELL" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_SS2022" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_XHTTP" = 1 ] && NEED_CERT=1
    if [ "$ENABLE_WS_TLS" = 1 ]; then
        case "$WS_MODE" in
            argo)
                valid_domain "$ARGO_HOST" || err 'Cloudflare 固定 Tunnel 的 Public Hostname 格式无效。'
                valid_argo_token "$ARGO_TOKEN" || err 'Cloudflare Tunnel Token 格式无效；请粘贴完整的 eyJ... Token。'
                ;;
            direct) NEED_CERT=1 ;;
            *) err "不支持的 WS 接入方式：$WS_MODE" ;;
        esac
    fi

    if [ "$NEED_CERT" = 1 ]; then
        resolve_install_domains
        case "$CERT_MODE" in
            cloudflare)
                [ -n "$cf_token" ] || err 'Cloudflare DNS-01 API Token 不能为空。'
                [ -z "$cert_email" ] || valid_email "$cert_email" || err '证书账户邮箱格式不正确。'
                if [ -n "$zone_id" ]; then
                    case "$zone_id" in *[!A-Fa-f0-9]*) err 'Zone ID 必须是 32 位十六进制字符串。' ;; esac
                    [ "${#zone_id}" -eq 32 ] || err 'Zone ID 必须是 32 位十六进制字符串。'
                fi
                ;;
            standalone|manual) ;;
            *) err '所选协议需要 TLS 证书，请选择 Cloudflare DNS-01、HTTP-01 或手动证书。' ;;
        esac
    else
        CERT_MODE=none
        TLS_DOMAIN=""
        CF_ZONE_NAME=""
        cf_token=""
        cert_email=""
        zone_id=""
    fi

    if [ "$ENABLE_VLESS_REALITY" = 1 ] || [ "$ENABLE_ANYTLS_REALITY" = 1 ]; then
        REALITY_SNI=${REALITY_SNI:-www.bing.com}
        valid_domain "$REALITY_SNI" || err 'Reality SNI 必须是有效域名。'
    else REALITY_SNI=""; fi

    resolve_install_domains
    resolve_install_addresses

    if [ ! -e "$STATE_FILE" ] && [ -d "$APP_DIR" ]; then backup_existing_install; fi
    if [ "${SB_CORE_PREPARED:-0}" != 1 ]; then
        install_dependencies_and_core
    else
        msg '核心已由网页一键命令预装并通过版本检查，跳过重复安装。'
    fi
    PREVIOUS_ANYTLS_PORT=""; PREVIOUS_WS_PORT=""; PREVIOUS_REALITY_PORT=""; PREVIOUS_NAIVE_PORT=""; PREVIOUS_ANYREALITY_PORT=""; PREVIOUS_XHTTP_PORT=""; PREVIOUS_SNELL_PORT=""
    assign_ports

    if [ -n "$NODE_LABEL" ]; then
        label_length=$(jq -nr --arg node_label "$NODE_LABEL" '$node_label | length')
        [ "$label_length" -le 20 ] || err '节点辨识符最多 20 个字符。'
        jq -ne --arg node_label "$NODE_LABEL" '$node_label | test("^[\\p{L}\\p{N}._-]+$")' >/dev/null 2>&1 || err '节点辨识符仅支持中文、英文字母、数字、点、下划线和短横线。'
    fi

    ensure_service_account
    enable_bbr
    create_service
    if [ "$NEED_CERT" = 1 ]; then
        setup_reload_hook
        case "$CERT_MODE" in
            cloudflare)
                printf '%s' "$cf_token" > "$CF_TOKEN_FILE"; chmod 0600 "$CF_TOKEN_FILE"; chown root:root "$CF_TOKEN_FILE"
                rm -f "$CF_ZONE_ID_FILE"
                if [ -n "$zone_id" ]; then printf '%s' "$zone_id" > "$CF_ZONE_ID_FILE"; chmod 0600 "$CF_ZONE_ID_FILE"; fi
                install_acme "$cert_email"
                issue_cloudflare_cert "$TLS_DOMAIN" || err 'Cloudflare DNS-01 证书处理失败；请检查 Token 权限、Zone ID 和域名托管状态。'
                ;;
            standalone)
                CF_ZONE_NAME=""; rm -f "$CF_TOKEN_FILE" "$CF_ZONE_ID_FILE"
                issue_http_cert "$TLS_DOMAIN" || err 'HTTP-01 证书申请失败；请确认域名解析到 VPS，且公网 TCP 80 可访问。'
                ;;
            manual)
                CF_ZONE_NAME=""; rm -f "$CF_TOKEN_FILE" "$CF_ZONE_ID_FILE"
                install_manual_cert "$TLS_DOMAIN"
                ;;
        esac
    else
        rm -f "$CF_TOKEN_FILE" "$CF_ZONE_ID_FILE"
    fi

    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ]; then
        write_argo_token_file "$ARGO_TOKEN" || err '无法安全写入 Cloudflare Tunnel Token 文件；请检查 /etc/sing-box 权限。'
    fi

    ANYTLS_PASSWORD=""; WS_UUID=""; REALITY_UUID=""; REALITY_PRIVATE=""; REALITY_PUBLIC=""; REALITY_SID=""
    NAIVE_USERNAME=""; NAIVE_PASSWORD=""; ANYREALITY_PASSWORD=""; ANYREALITY_PRIVATE=""; ANYREALITY_PUBLIC=""; ANYREALITY_SID=""
    WS_PATH=""
    [ "$ENABLE_ANYTLS" = 0 ] || ANYTLS_PASSWORD=$(openssl rand -hex 24)
    if [ "$ENABLE_WS_TLS" = 1 ]; then WS_UUID=$("$SB_BIN" generate uuid); WS_PATH="/ws-$(openssl rand -hex 8)"; fi
    if [ "$ENABLE_VLESS_REALITY" = 1 ]; then
        REALITY_UUID=$("$SB_BIN" generate uuid); keypair=$("$SB_BIN" generate reality-keypair)
        REALITY_PRIVATE=$(printf '%s\n' "$keypair" | awk '/PrivateKey/ {print $2}')
        REALITY_PUBLIC=$(printf '%s\n' "$keypair" | awk '/PublicKey/ {print $2}')
        REALITY_SID=$("$SB_BIN" generate rand --hex 8)
        [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] && [ -n "$REALITY_SID" ] || err 'VLESS Reality 密钥生成失败。'
    fi
    if [ "$ENABLE_NAIVE" = 1 ]; then NAIVE_USERNAME="naive-$(openssl rand -hex 6)"; NAIVE_PASSWORD=$(openssl rand -hex 24); fi
    if [ "$ENABLE_SNELL" = 1 ]; then
        SNELL_PSK=$(openssl rand -hex 32)
        SNELL_USERKEY=$(openssl rand -hex 24)
    fi
    if [ "$ENABLE_SS2022" = 1 ]; then
        [ -n "$SS2022_PASSWORD" ] || SS2022_PASSWORD=$(openssl rand -base64 "$( [ "$SS2022_METHOD" = 2022-blake3-aes-128-gcm ] && printf 16 || printf 32 )")
        case "$SS2022_METHOD:$SS2022_PASSWORD" in
          2022-blake3-aes-128-gcm:????????????????????????|2022-blake3-aes-256-gcm:????????????????????????????????????????????) ;;
          *) err 'SS2022 密码长度与加密方式不匹配；请使用正确长度的 Base64 密钥。' ;;
        esac
    fi
    if [ "$ENABLE_XHTTP" = 1 ]; then
        XHTTP_UUID=$("$XRAY_BIN" uuid 2>/dev/null || "$SB_BIN" generate uuid)
        XHTTP_PATH=${XHTTP_PATH:-"/xhttp-$(openssl rand -hex 10)"}
        install_xray_core
        generate_xhttp_ech_keys || err 'XHTTP ECH 密钥生成失败。'
    fi
    if [ "$ENABLE_ANYTLS_REALITY" = 1 ]; then
        ANYREALITY_PASSWORD=$(openssl rand -hex 24); anyreality_keypair=$("$SB_BIN" generate reality-keypair)
        ANYREALITY_PRIVATE=$(printf '%s\n' "$anyreality_keypair" | awk '/PrivateKey/ {print $2}')
        ANYREALITY_PUBLIC=$(printf '%s\n' "$anyreality_keypair" | awk '/PublicKey/ {print $2}')
        ANYREALITY_SID=$("$SB_BIN" generate rand --hex 8)
        [ -n "$ANYREALITY_PRIVATE" ] && [ -n "$ANYREALITY_PUBLIC" ] && [ -n "$ANYREALITY_SID" ] || err 'AnyTLS + Reality 密钥生成失败。'
    fi

    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ]; then
        install_cloudflared
        create_cloudflared_service
    fi

    if [ "$ENABLE_XHTTP" = 1 ]; then create_xray_service; fi
    build_config || err '配置未能成功应用，请检查 sing-box 日志。'
    save_state || err 'sing-box 已启动，但管理状态保存失败；请检查磁盘空间和 /etc/sing-box 权限。'
    if [ "$ENABLE_XHTTP" = 1 ]; then build_xray_config || err 'Xray XHTTP 配置启动失败；请查看 xray 服务日志。'; fi

    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ]; then
        if start_cloudflared_service; then
            msg 'Cloudflare Tunnel 服务已启动。'
        else
            warn 'Cloudflare Tunnel 未能启动；请检查 cloudflared 日志和 Token。'
        fi
        msg "Cloudflare Tunnel 路由必须设置：Public Hostname $ARGO_HOST → http://127.0.0.1:$WS_PORT"
        msg 'Argo 模式客户端使用 TLS 443；本机 WS 监听端口不需要 NAT 入站映射。'
    fi

    msg '安装完成。仅显示已选择的协议节点：'
    show_nodes
    msg '需要公网入站放行的 TCP 端口（Argo WS 不需要 NAT 入站端口）：'
    [ "$ENABLE_ANYTLS" = 0 ] || printf '  AnyTLS: %s/tcp\n' "$ANYTLS_PORT"
    [ "$ENABLE_VLESS_REALITY" = 0 ] || printf '  VLESS Reality: %s/tcp\n' "$REALITY_PORT"
    [ "$ENABLE_NAIVE" = 0 ] || printf '  NaiveProxy: %s/tcp\n' "$NAIVE_PORT"
    [ "$ENABLE_ANYTLS_REALITY" = 0 ] || printf '  AnyTLS Reality: %s/tcp\n' "$ANYREALITY_PORT"
    [ "$ENABLE_XHTTP" = 0 ] || printf '  VLESS XHTTP + ECH: %s/tcp\n' "$XHTTP_PORT"
    [ "$ENABLE_SNELL" = 0 ] || printf '  Snell: %s/tcp\n' "$SNELL_PORT"
    [ "$ENABLE_WS_TLS" = 0 ] || { [ "$WS_MODE" != argo ] || msg '  VLESS WS Argo: 无需公网入站端口（cloudflared 主动出站连接）'; }
    msg '管理命令：/usr/local/sbin/sb-manager'
}

web_string() {
    trim_value "$(jq -r --arg key "$1" '.[$key] // ""' "$web_cfg")"
}

backup_existing_install() {
    [ -d "$APP_DIR" ] || return 0

    backup_root=/var/backups/sb-manager
    backup_stamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf unknown)
    backup_dir="$backup_root/pre-install-$backup_stamp-$$"
    install -d -m 0700 "$backup_root" || err "无法创建备份目录：$backup_root"
    install -d -m 0700 "$backup_dir" || err "无法创建备份目录：$backup_dir"

    if ! cp -a "$APP_DIR" "$backup_dir/sing-box"; then
        rm -rf "$backup_dir"
        err '备份现有 /etc/sing-box 失败；为避免覆盖数据，已停止安装。'
    fi
    [ ! -f /etc/systemd/system/sing-box.service ] || cp -p /etc/systemd/system/sing-box.service "$backup_dir/systemd-sing-box.service" || {
        rm -rf "$backup_dir"
        err '备份现有 systemd 服务文件失败；为避免覆盖数据，已停止安装。'
    }
    [ ! -f /etc/init.d/sing-box ] || cp -p /etc/init.d/sing-box "$backup_dir/openrc-sing-box" || {
        rm -rf "$backup_dir"
        err '备份现有 OpenRC 服务文件失败；为避免覆盖数据，已停止安装。'
    }
    [ ! -f "$RELOAD_HOOK" ] || cp -p "$RELOAD_HOOK" "$backup_dir/sing-box-cert-reload" || {
        rm -rf "$backup_dir"
        err '备份现有证书重载钩子失败；为避免覆盖数据，已停止安装。'
    }
    chmod -R go-rwx "$backup_dir" 2>/dev/null || true
    msg "已备份原有 sing-box 数据及服务文件：$backup_dir"
}

manager_state_is_valid() {
    [ -s "$STATE_FILE" ] || return 1
    jq -e '
      def enabled($k): if has($k) then .[$k] == true else true end;
      def nonempty($v): ($v | type == "string" and length > 0);
      type == "object" and
      ((enabled("enabled_anytls") | not) or (nonempty(.anytls_password) and (.anytls_port | type == "number"))) and
      ((enabled("enabled_ws_tls") | not) or (nonempty(.ws_uuid) and (.ws_port | type == "number") and nonempty(.ws_path) and
        (if .ws_mode == "argo" then nonempty(.argo_host) else nonempty(.tls_domain) and nonempty(.ws_host) end))) and
      ((enabled("enabled_vless_reality") | not) or (nonempty(.reality_uuid) and nonempty(.reality_private) and nonempty(.reality_public) and nonempty(.reality_sid) and (.reality_port | type == "number") and nonempty(.reality_sni))) and
      ((enabled("enabled_naive") | not) or (nonempty(.naive_username) and nonempty(.naive_password) and (.naive_port | type == "number") and nonempty(.tls_domain))) and
      ((enabled("enabled_anytls_reality") | not) or (nonempty(.anyreality_password) and nonempty(.anyreality_private) and nonempty(.anyreality_public) and nonempty(.anyreality_sid) and (.anyreality_port | type == "number") and nonempty(.reality_sni))) and
      ((.enabled_xhttp != true) or (nonempty(.xhttp_uuid) and nonempty(.xhttp_path) and (.xhttp_port | type == "number") and nonempty(.tls_domain) and nonempty(.xhttp_ech_public_name))) and
      ((.enabled_ss2022 != true) or (.ss2022_method as $m | nonempty(.ss2022_password) and (.ss2022_port | type == "number") and (["2022-blake3-aes-128-gcm","2022-blake3-aes-256-gcm"] | index($m) != null))) and
      ((.enabled_snell != true) or (nonempty(.snell_psk) and nonempty(.snell_userkey) and (.snell_port | type == "number") and ((.snell_version == 5) or (.snell_version == 6)))) and
      (if (enabled("enabled_anytls") or enabled("enabled_naive") or enabled("enabled_vless_reality") or enabled("enabled_anytls_reality") or (.enabled_snell == true) or (.enabled_ss2022 == true)) then (nonempty(.origin_addr) or nonempty(.origin_ipv6)) else true end) and
      (if (enabled("enabled_anytls") or enabled("enabled_naive") or (.enabled_xhttp == true) or (enabled("enabled_ws_tls") and (.ws_mode // "direct") == "direct")) then nonempty(.tls_domain) and nonempty(.cert_file) and nonempty(.key_file) and nonempty(.cert_mode) else true end)
    ' "$STATE_FILE" >/dev/null 2>&1
}

install_web_config() {
    need_root
    web_cfg=${1:-}
    [ -n "$web_cfg" ] && [ -s "$web_cfg" ] || err '请提供网页生成的 JSON 配置文件。'
    if ! command -v jq >/dev/null 2>&1; then
        if [ -f /etc/alpine-release ]; then apk add --no-cache jq curl openssl ca-certificates
        elif [ -f /etc/debian_version ]; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl openssl ca-certificates
        else err '网页配置安装仅支持 Debian/Ubuntu 和 Alpine。'; fi
    fi
    if [ -e "$STATE_FILE" ]; then
        if ! manager_state_is_valid; then backup_existing_install; err '现有 manager.json 无效；已备份原目录，停止覆盖。'; fi
        load_state
        overlay_install
        return 0
    fi

    jq -e '
      def text: type == "string" and (explode | all(. != 0 and . != 10 and . != 13));
      type == "object" and (.schema == 8) and
      (.protocols | type == "object") and
      ([.origin_ipv4,.origin_ipv6,.ws_server,.ws_mode,.argo_host,.argo_tunnel_name,.argo_token,.tls_domain,.ws_host,.reality_sni,.node_label,.cert_mode,.cf_zone_name,.cf_token,.cf_email,.cf_zone_id,.xhttp_mode,.xhttp_path,.xhttp_ech_public_name,.snell_obfs_mode,.snell_obfs_host,.snell_mode,.ss2022_method]
        | all(. == null or text)) and
      (.ports | type == "object")
    ' "$web_cfg" >/dev/null 2>&1 || err '网页配置 JSON 格式不正确或版本不匹配，请刷新最新版 HTML 后重新生成命令。'

    ENABLE_ANYTLS=$(jq -r 'if .protocols.anytls == true then "1" else "0" end' "$web_cfg")
    ENABLE_WS_TLS=$(jq -r 'if .protocols.ws_tls == true then "1" else "0" end' "$web_cfg")
    ENABLE_VLESS_REALITY=$(jq -r 'if .protocols.vless_reality == true then "1" else "0" end' "$web_cfg")
    ENABLE_NAIVE=$(jq -r 'if .protocols.naive == true then "1" else "0" end' "$web_cfg")
    ENABLE_ANYTLS_REALITY=$(jq -r 'if .protocols.anytls_reality == true then "1" else "0" end' "$web_cfg")
    ENABLE_XHTTP=$(jq -r 'if .protocols.xhttp == true then "1" else "0" end' "$web_cfg")
    ENABLE_SNELL=$(jq -r 'if .protocols.snell == true then "1" else "0" end' "$web_cfg")
    ENABLE_SS2022=$(jq -r 'if .protocols.ss2022 == true then "1" else "0" end' "$web_cfg")
    WS_MODE=$(web_string ws_mode); WS_MODE=${WS_MODE:-direct}
    ARGO_HOST=$(web_string argo_host)
    ARGO_TUNNEL_NAME=$(web_string argo_tunnel_name)
    ARGO_TOKEN=$(web_string argo_token)
    ORIGIN_ADDR=$(web_string origin_ipv4); ORIGIN_IPV6=$(web_string origin_ipv6)
    WS_SERVER=$(web_string ws_server)
    TLS_DOMAIN=$(web_string tls_domain); WS_HOST=$(web_string ws_host)
    REALITY_SNI=$(web_string reality_sni); NODE_LABEL=$(web_string node_label)
    XHTTP_MODE=$(web_string xhttp_mode); XHTTP_MODE=${XHTTP_MODE:-auto}
    XHTTP_PATH=$(web_string xhttp_path)
    XHTTP_ECH_PUBLIC_NAME=$(web_string xhttp_ech_public_name); XHTTP_ECH_PUBLIC_NAME=${XHTTP_ECH_PUBLIC_NAME:-cloudflare-ech.com}
    SNELL_VERSION=$(jq -r '.snell_version // 5' "$web_cfg")
    SNELL_OBFS_MODE=$(web_string snell_obfs_mode); SNELL_OBFS_MODE=${SNELL_OBFS_MODE:-http}
    SNELL_OBFS_HOST=$(web_string snell_obfs_host); SNELL_OBFS_HOST=${SNELL_OBFS_HOST:-www.bing.com}
    SNELL_MODE=$(web_string snell_mode); SNELL_MODE=${SNELL_MODE:-default}
    ANYTLS_PORT=$(jq -r '.ports.anytls // ""' "$web_cfg")
    WS_PORT=$(jq -r '.ports.ws_tls // ""' "$web_cfg")
    REALITY_PORT=$(jq -r '.ports.vless_reality // ""' "$web_cfg")
    NAIVE_PORT=$(jq -r '.ports.naive // ""' "$web_cfg")
    ANYREALITY_PORT=$(jq -r '.ports.anytls_reality // ""' "$web_cfg")
    XHTTP_PORT=$(jq -r '.ports.xhttp // ""' "$web_cfg")
    SNELL_PORT=$(jq -r '.ports.snell // ""' "$web_cfg")
    SS2022_PORT=$(jq -r '.ports.ss2022 // ""' "$web_cfg")
    SS2022_METHOD=$(jq -r '.ss2022_method // "2022-blake3-aes-256-gcm"' "$web_cfg")
    cert_mode=$(web_string cert_mode); CF_ZONE_NAME=$(web_string cf_zone_name)
    cf_token=$(web_string cf_token); cert_email=$(web_string cf_email); zone_id=$(web_string cf_zone_id)
    case "$cert_mode" in cloudflare) CERT_MODE=cloudflare ;; http01) CERT_MODE=standalone ;; none|'') CERT_MODE=none ;; *) err '不支持的证书方式。' ;; esac

    selected_count=$((ENABLE_ANYTLS + ENABLE_WS_TLS + ENABLE_VLESS_REALITY + ENABLE_NAIVE + ENABLE_ANYTLS_REALITY + ENABLE_XHTTP + ENABLE_SNELL + ENABLE_SS2022))
    [ "$selected_count" -gt 0 ] || err '请至少选择一种协议。'
    NEED_CERT=0
    [ "$ENABLE_ANYTLS" = 1 ] && NEED_CERT=1
    [ "$ENABLE_NAIVE" = 1 ] && NEED_CERT=1
    [ "$ENABLE_XHTTP" = 1 ] && NEED_CERT=1
    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = direct ]; then NEED_CERT=1; fi
    if [ "$ENABLE_XHTTP" = 1 ]; then
        valid_domain "$XHTTP_ECH_PUBLIC_NAME" || err 'ECH Public Name 必须是有效域名。'
        case "$XHTTP_MODE" in auto|packet-up|stream-up|stream-one) ;; *) err 'XHTTP mode 无效。' ;; esac
        [ -z "$XHTTP_PATH" ] || case "$XHTTP_PATH" in /*) ;; *) err 'XHTTP Path 必须以 / 开头。' ;; esac
    fi
    if [ "$ENABLE_SS2022" = 1 ]; then
        case "$SS2022_METHOD" in 2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm) ;; *) err 'SS2022 method 无效。' ;; esac
        valid_port "$SS2022_PORT" || SS2022_PORT=$(pick_random_range_port 10000 65535 "$ANYTLS_PORT $WS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT $XHTTP_PORT $SNELL_PORT")
    fi
    if [ "$ENABLE_SNELL" = 1 ]; then
        case "$SNELL_VERSION" in 5) case "$SNELL_OBFS_MODE" in http|none) ;; *) err 'Snell v5 obfs_mode 无效。' ;; esac ;; 6) case "$SNELL_MODE" in default|unshaped|unsafe-raw) ;; *) err 'Snell v6 mode 无效。' ;; esac ;; *) err 'Snell version 只能是 5 或 6。' ;; esac
    fi
    if [ "$NEED_CERT" = 1 ] && [ "$CERT_MODE" = cloudflare ] && [ -z "$cf_token" ]; then
        ask_secret 'Cloudflare DNS API Token（网页未提供；输入时不会显示）'; cf_token=$(trim_value "$REPLY")
    fi
    msg '正在使用网页选择的协议和参数启动 sing-box 安装流程……'
    install_from_config
}

change_tls_sni() {
    if [ "$NEED_CERT" = 0 ]; then warn '当前所选协议不使用源站 TLS 证书；Argo WS 的 TLS SNI 由 Argo 公网主机名决定。'; return 0; fi
    msg '此域名用于 AnyTLS、直连 VLESS + WS + TLS、NaiveProxy 和 VLESS XHTTP + ECH 的 TLS SNI，必须是你拥有/获准管理且有匹配证书的域名。'
    msg 'www.bing.com 只作为 Reality SNI 默认值；不能用它申请 AnyTLS / WS TLS 证书。'
    ask_value '新的 TLS 证书域名 / TLS SNI（自己的域名）' "$TLS_DOMAIN"
    new_domain=$REPLY
    valid_cert_domain "$new_domain" || { warn 'TLS 证书域名格式无效；请输入你管理的 DNS 域名，不能填写 IP 或第三方域名。'; return 0; }
    if [ "$CERT_MODE" = cloudflare ]; then
        [ -n "$CF_ZONE_NAME" ] || { warn '缺少 Cloudflare 区域主域名，请先使用菜单 6 设置 Cloudflare 绑定区域。'; return 0; }
        domain_belongs_to_zone "$new_domain" "$CF_ZONE_NAME" || { warn "新域名必须属于 Cloudflare 区域 $CF_ZONE_NAME。"; return 0; }
    fi
    msg "将为 $new_domain 使用 TLS 证书。请确保你拥有或获准管理该域名。"

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
    new_zone=$(trim_value "$REPLY")
    new_zone=${new_zone:-$CF_ZONE_NAME}
    valid_cert_domain "$new_zone" || { warn 'Cloudflare 区域域名无效。'; return 0; }

    ask_value '已解析到本机的完整域名（留空使用根域名）' "$new_zone"
    new_cert_domain=$(trim_value "$REPLY")
    new_cert_domain=${new_cert_domain:-$new_zone}
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
    new_zone_id=$(trim_value "$REPLY")
    case "$new_zone_id" in
        ''|*[!A-Fa-f0-9]*) warn 'Zone ID 必须是 32 位十六进制字符串。'; return 0 ;;
    esac
    [ "${#new_zone_id}" -eq 32 ] || { warn 'Zone ID 必须是 32 位十六进制字符串。'; return 0; }

    msg "将为 $new_cert_domain 使用新的 Cloudflare DNS 区域签发 TLS 证书。请确保你拥有或获准管理该域名。"

    backup_dir=$(mktemp -d) || { warn '无法创建临时备份目录。'; return 0; }
    cp -p "$CERT_FILE" "$backup_dir/fullchain.pem" 2>/dev/null || true
    cp -p "$KEY_FILE" "$backup_dir/privkey.pem" 2>/dev/null || true
    cp -p "$CF_ZONE_ID_FILE" "$backup_dir/zone-id" 2>/dev/null || true

    old_zone=$CF_ZONE_NAME
    old_tls_domain=$TLS_DOMAIN
    old_ws_host=$WS_HOST
    old_ws_server=$WS_SERVER
    old_preferred_ip=$PREFERRED_IP

    printf '%s' "$new_zone_id" > "$CF_ZONE_ID_FILE"
    chmod 0600 "$CF_ZONE_ID_FILE"
    chown root:root "$CF_ZONE_ID_FILE"
    CF_ZONE_NAME=$new_zone
    TLS_DOMAIN=$new_cert_domain
    WS_HOST=$new_ws_host
    if [ "$WS_SERVER" = "$old_tls_domain" ]; then
        WS_SERVER=$new_cert_domain
        PREFERRED_IP=$new_cert_domain
    fi

    if ! issue_cloudflare_cert "$TLS_DOMAIN"; then
        CF_ZONE_NAME=$old_zone
        TLS_DOMAIN=$old_tls_domain
        WS_HOST=$old_ws_host
        WS_SERVER=$old_ws_server
        PREFERRED_IP=$old_preferred_ip
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
        WS_SERVER=$old_ws_server
        PREFERRED_IP=$old_preferred_ip
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
    if [ "$ENABLE_VLESS_REALITY" = 0 ] && [ "$ENABLE_ANYTLS_REALITY" = 0 ]; then warn '当前没有安装 Reality 协议。'; return 0; fi
    ask_value '新的 Reality SNI / 握手目标域名' "$REALITY_SNI"
    new_sni=$REPLY
    valid_domain "$new_sni" || { warn '域名格式无效。'; return; }
    old_sni=$REALITY_SNI
    REALITY_SNI=$new_sni
    if ! build_config; then
        REALITY_SNI=$old_sni
        return 0
    fi
    msg "Reality SNI 已更新：VLESS Reality 和 AnyTLS + Reality 现在共用 $REALITY_SNI"
    show_nodes
}

change_preferred_ip() {
    [ "$ENABLE_WS_TLS" = 1 ] || { warn '当前未安装 VLESS + WS。'; return 0; }
    ask_value '新的 VLESS WS TLS 单一连接地址（IPv4 / IPv6 / 域名；输入 - 恢复证书域名）' "$WS_SERVER"
    new_ws_server=$REPLY
    if [ "$new_ws_server" = "-" ]; then
        new_ws_server=""
    fi
    if [ -z "$new_ws_server" ]; then
        if [ "$WS_MODE" = argo ]; then WS_SERVER=$ARGO_HOST; else WS_SERVER=$TLS_DOMAIN; fi
        PREFERRED_IP=""
        PREFERRED_IPV6=""
        save_state
        show_nodes
        msg "WS TLS 连接地址已恢复为证书域名：$TLS_DOMAIN"
        return 0
    fi

    case "$new_ws_server" in
        *:*)
            ipv6_kernel_enabled || { warn '系统内核未启用 IPv6。'; return; }
            valid_ipv6_address "$new_ws_server" || { warn 'IPv6 地址格式无效，或服务器没有到该地址的 IPv6 路由。'; return; }
            PREFERRED_IP=""
            PREFERRED_IPV6=$new_ws_server
            ;;
        *)
            valid_main_address "$new_ws_server" || { warn 'IPv4 地址 / 域名格式无效。'; return; }
            PREFERRED_IP=$new_ws_server
            PREFERRED_IPV6=""
            ;;
    esac

    WS_SERVER=$new_ws_server
    save_state
    show_nodes
}

change_argo_binding() {
    [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ] || {
        warn '当前未启用 VLESS + WS 固定 Argo Tunnel。'
        return 0
    }
    [ -s "$ARGO_TOKEN_FILE" ] || {
        warn '当前 Tunnel Token 文件缺失；请先重新安装 Argo 模式，或使用安装向导配置 Token。'
        return 0
    }

    msg '修改固定 Tunnel 的 Public Hostname、备注名或轮换 Token。'
    msg 'Token 留空表示保留当前 Token；不会显示或回显现有 Token。'
    old_argo_host=$ARGO_HOST
    old_argo_name=$ARGO_TUNNEL_NAME
    old_ws_server=$WS_SERVER
    old_ws_host=$WS_HOST
    backup_dir=$(mktemp -d) || { warn '无法创建临时备份目录。'; return 0; }
    if ! cp -p "$ARGO_TOKEN_FILE" "$backup_dir/cloudflared.token"; then
        rm -rf "$backup_dir"
        warn '无法备份当前 Tunnel Token；没有修改任何配置。'
        return 0
    fi

    ask_value '新的固定 Tunnel Public Hostname' "$ARGO_HOST"
    new_argo_host=$(trim_value "$REPLY")
    valid_cert_domain "$new_argo_host" || {
        rm -rf "$backup_dir"
        warn 'Public Hostname 格式无效；请输入你在 Cloudflare 管理的域名，例如 ws.example.com。'
        return 0
    }
    ask_value 'Tunnel 备注名（仅本机显示，可留空）' "$ARGO_TUNNEL_NAME"
    new_argo_name=$(trim_value "$REPLY")
    ask_secret '新的 Cloudflare Tunnel Token（直接回车保留当前 Token）'
    new_argo_token=$(trim_value "$REPLY")
    if [ -n "$new_argo_token" ] && ! valid_argo_token "$new_argo_token"; then
        rm -rf "$backup_dir"
        warn '新 Tunnel Token 格式无效；没有修改任何配置。'
        return 0
    fi

    ARGO_HOST=$new_argo_host
    ARGO_TUNNEL_NAME=$new_argo_name
    WS_HOST=$new_argo_host
    if [ -z "$old_ws_server" ] || [ "$old_ws_server" = "$old_argo_host" ]; then
        WS_SERVER=$new_argo_host
        PREFERRED_IP=""
        PREFERRED_IPV6=""
    fi

    if [ -n "$new_argo_token" ]; then
        if ! write_argo_token_file "$new_argo_token"; then
            ARGO_HOST=$old_argo_host
            ARGO_TUNNEL_NAME=$old_argo_name
            WS_SERVER=$old_ws_server
            WS_HOST=$old_ws_host
            rm -rf "$backup_dir"
            warn '新 Token 无法安全写入；原配置保持不变。'
            return 0
        fi
        if ! start_cloudflared_service; then
            cp -p "$backup_dir/cloudflared.token" "$ARGO_TOKEN_FILE"
            chown root:sing-box "$ARGO_TOKEN_FILE" 2>/dev/null || true
            chmod 0640 "$ARGO_TOKEN_FILE" 2>/dev/null || true
            start_cloudflared_service >/dev/null 2>&1 || true
            ARGO_HOST=$old_argo_host
            ARGO_TUNNEL_NAME=$old_argo_name
            WS_SERVER=$old_ws_server
            WS_HOST=$old_ws_host
            rm -rf "$backup_dir"
            warn 'Tunnel 服务重启失败，已恢复本机旧 Token 文件和旧节点参数。若你已在 Cloudflare 控制台执行 Rotate Token，旧 Token 可能已失效，请重新输入新 Token。'
            return 0
        fi
        sleep 3
        if [ "$SERVICE_KIND" = systemd ]; then
            if ! systemctl is-active --quiet "$CLOUDFLARED_SERVICE"; then
                cp -p "$backup_dir/cloudflared.token" "$ARGO_TOKEN_FILE"
                chown root:sing-box "$ARGO_TOKEN_FILE" 2>/dev/null || true
                chmod 0640 "$ARGO_TOKEN_FILE" 2>/dev/null || true
                start_cloudflared_service >/dev/null 2>&1 || true
                ARGO_HOST=$old_argo_host
                ARGO_TUNNEL_NAME=$old_argo_name
                WS_SERVER=$old_ws_server
                WS_HOST=$old_ws_host
                rm -rf "$backup_dir"
                warn '新 Token 启动后服务未处于 active，已恢复本机旧 Token 文件和旧节点参数。若 Cloudflare 已轮换 Token，旧 Token 可能已失效。'
                return 0
            fi
        elif [ "$SERVICE_KIND" = openrc ]; then
            if ! rc-service "$CLOUDFLARED_SERVICE" status >/dev/null 2>&1; then
                cp -p "$backup_dir/cloudflared.token" "$ARGO_TOKEN_FILE"
                chown root:sing-box "$ARGO_TOKEN_FILE" 2>/dev/null || true
                chmod 0640 "$ARGO_TOKEN_FILE" 2>/dev/null || true
                start_cloudflared_service >/dev/null 2>&1 || true
                ARGO_HOST=$old_argo_host
                ARGO_TUNNEL_NAME=$old_argo_name
                WS_SERVER=$old_ws_server
                WS_HOST=$old_ws_host
                rm -rf "$backup_dir"
                warn '新 Token 启动后 OpenRC 服务未运行，已恢复本机旧 Token 文件和旧节点参数。若 Cloudflare 已轮换 Token，旧 Token 可能已失效。'
                return 0
            fi
        fi
    fi

    if ! save_state; then
        cp -p "$backup_dir/cloudflared.token" "$ARGO_TOKEN_FILE"
        chown root:sing-box "$ARGO_TOKEN_FILE" 2>/dev/null || true
        chmod 0640 "$ARGO_TOKEN_FILE" 2>/dev/null || true
        start_cloudflared_service >/dev/null 2>&1 || true
        ARGO_HOST=$old_argo_host
        ARGO_TUNNEL_NAME=$old_argo_name
        WS_SERVER=$old_ws_server
        WS_HOST=$old_ws_host
        rm -rf "$backup_dir"
        warn '保存管理状态失败；已尽力恢复旧 Token 和节点参数。'
        return 0
    fi

    rm -rf "$backup_dir"
    show_nodes
    if [ "$old_argo_host" != "$ARGO_HOST" ]; then
        msg "Public Hostname 已更新为 $ARGO_HOST。请在 Cloudflare Zero Trust 的该 Tunnel 中同步添加/修改 Public Hostname，并将 Service URL 指向 http://127.0.0.1:$WS_PORT。"
    fi
    if [ -n "$new_argo_token" ]; then
        msg '新 Tunnel Token 已写入受限权限文件并重启 cloudflared。请在 Cloudflare 控制台确认 Connector 状态为 Healthy。'
    else
        msg 'Tunnel 节点参数已保存；现有 Token 保持不变。'
    fi
}

change_ws_host() {
    if [ "$WS_MODE" = argo ]; then warn 'Argo 模式的 WS Host 必须与 Cloudflare Tunnel Public Hostname 一致；如需更换，请在 Cloudflare Tunnel 路由中同步修改并重新部署。'; return 0; fi
    msg 'WS HTTP Host 是 WebSocket HTTP 请求头，不是 TLS SNI。默认建议与 TLS 证书域名相同。'
    ask_value '新的 VLESS WS HTTP Host（不是 SNI）' "$WS_HOST"
    new_host=$REPLY
    valid_domain "$new_host" || { warn '域名格式无效。'; return; }
    WS_HOST=$new_host
    save_state
    show_nodes
}


change_single_port() {
    printf '\n当前协议端口：\n'
    printf '1. AnyTLS              %s/tcp\n' "$ANYTLS_PORT"
    printf '2. VLESS + WS + TLS    %s/tcp\n' "$WS_PORT"
    printf '3. VLESS + Reality     %s/tcp\n' "$REALITY_PORT"
    printf '4. NaiveProxy          %s/tcp\n' "$NAIVE_PORT"
    printf '5. AnyTLS + Reality    %s/tcp\n' "$ANYREALITY_PORT"
    printf '6. VLESS XHTTP + ECH  %s/tcp\n' "$XHTTP_PORT"
    printf '7. Snell               %s/tcp\n' "$SNELL_PORT"
    printf '8. Shadowsocks 2022    %s/tcp\n' "$SS2022_PORT"
    printf '0. 返回\n'
    printf '请选择要修改端口的单个节点：'
    IFS= read -r selected_choice || selected_choice=0

    case "$selected_choice" in
        1)
            [ "$ENABLE_ANYTLS" = 1 ] || { warn '当前未安装 AnyTLS。'; return 0; }
            selected_name='AnyTLS'
            selected_current=$ANYTLS_PORT
            other_ports="$WS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT $XHTTP_PORT $SNELL_PORT $SS2022_PORT"
            selected_kind=range
            ;;
        2)
            [ "$ENABLE_WS_TLS" = 1 ] || { warn '当前未安装 VLESS + WS + TLS。'; return 0; }
            selected_name='VLESS + WS + TLS'
            selected_current=$WS_PORT
            other_ports="$ANYTLS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT $XHTTP_PORT $SNELL_PORT $SS2022_PORT"
            if [ "$WS_MODE" = argo ]; then selected_kind=argo; else selected_kind=ws; fi
            ;;
        3)
            [ "$ENABLE_VLESS_REALITY" = 1 ] || { warn '当前未安装 VLESS + Reality。'; return 0; }
            selected_name='VLESS + Reality'
            selected_current=$REALITY_PORT
            other_ports="$ANYTLS_PORT $WS_PORT $NAIVE_PORT $ANYREALITY_PORT $XHTTP_PORT $SNELL_PORT $SS2022_PORT"
            selected_kind=range
            ;;
        4)
            [ "$ENABLE_NAIVE" = 1 ] || { warn '当前未安装 NaiveProxy。'; return 0; }
            selected_name='NaiveProxy'
            selected_current=$NAIVE_PORT
            other_ports="$ANYTLS_PORT $WS_PORT $REALITY_PORT $ANYREALITY_PORT $XHTTP_PORT $SNELL_PORT $SS2022_PORT"
            selected_kind=range
            ;;
        5)
            [ "$ENABLE_ANYTLS_REALITY" = 1 ] || { warn '当前未安装 AnyTLS + Reality。'; return 0; }
            selected_name='AnyTLS + Reality'
            selected_current=$ANYREALITY_PORT
            other_ports="$ANYTLS_PORT $WS_PORT $REALITY_PORT $NAIVE_PORT $XHTTP_PORT $SNELL_PORT $SS2022_PORT"
            selected_kind=range
            ;;
        6)
            [ "$ENABLE_XHTTP" = 1 ] || { warn '当前未安装 VLESS XHTTP + ECH。'; return 0; }
            selected_name='VLESS XHTTP + ECH'
            selected_current=$XHTTP_PORT
            other_ports="$ANYTLS_PORT $WS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT $SNELL_PORT"
            selected_kind=xhttp
            ;;
        7)
            [ "$ENABLE_SNELL" = 1 ] || { warn '当前未安装 Snell。'; return 0; }
            selected_name='Snell'
            selected_current=$SNELL_PORT
            other_ports="$ANYTLS_PORT $WS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT $XHTTP_PORT $SS2022_PORT"
            selected_kind=range
            ;;
        8)
            [ "$ENABLE_SS2022" = 1 ] || { warn '当前未安装 SS2022。'; return 0; }
            selected_name='Shadowsocks 2022'
            selected_current=$SS2022_PORT
            other_ports="$ANYTLS_PORT $WS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT $XHTTP_PORT $SNELL_PORT"
            selected_kind=ss2022
            ;;
        0) return 0 ;;
        *) warn '无效选择。'; return 0 ;;
    esac

    printf '\n当前 %s 端口：%s/tcp\n' "$selected_name" "$selected_current"
    if [ "$selected_kind" = ws ]; then
        msg '直连 Cloudflare 橙云 WS TLS 端口请使用 443、2053、2083、2087、2096 或 8443。'
        ask_value '输入新端口（留空自动随机）' ''
    elif [ "$selected_kind" = argo ]; then
        msg 'Argo 模式该端口是 VPS 本机 127.0.0.1 监听端口，不是公网端口。修改后需同步更新 Cloudflare Tunnel Public Hostname 的 Service URL。'
        ask_value '输入新的本机 WS 端口（留空自动随机）' ''
    elif [ "$selected_kind" = xhttp ]; then
        ask_value '输入新的 XHTTP TCP 端口（1024–65535；留空自动随机）' ''
    elif [ "$selected_kind" = range ] || [ "$selected_kind" = ss2022 ]; then
        ask_value '输入新端口（1024–65535；留空自动随机）' ''
    fi
    requested_port=$(trim_value "$REPLY")

    if [ -n "$requested_port" ]; then
        if ! valid_port "$requested_port"; then
            warn '端口必须是 1024–65535 的整数；没有修改任何配置。'
            return 0
        fi
        requested_port=$(printf '%s\n' "$requested_port" | sed 's/^0*//')
        if [ "$requested_port" = "$selected_current" ]; then
            msg "$selected_name 已经使用端口 $selected_current，无需修改。"
            return 0
        fi

        case " $other_ports " in
            *" $requested_port "*)
                warn "端口 $requested_port 已被本脚本的其他协议使用；将为 $selected_name 自动选择备用端口。"
                requested_port=""
                ;;
        esac
    fi

    if [ -n "$requested_port" ] && port_listening "$requested_port"; then
        warn "TCP 端口 $requested_port 已被其他进程监听；将为 $selected_name 自动选择备用端口。"
        requested_port=""
    fi

    if [ -z "$requested_port" ]; then
        if [ "$selected_kind" = ws ]; then
            if ! selected_new_port=$(pick_random_ws_port $other_ports "$selected_current"); then
                warn '没有可用的 Cloudflare WS TLS 代理端口（2053、2083、2087、2096、8443）；原配置保持不变。'
                return 0
            fi
        else
            if ! selected_new_port=$(pick_random_range_port 10000 65535 $other_ports "$selected_current"); then
                warn "无法为 $selected_name 找到空闲端口；原配置保持不变。"
                return 0
            fi
        fi
        msg "$selected_name 的新端口已自动分配：$selected_new_port/tcp"
    else
        selected_new_port=$requested_port
    fi

    if [ "$selected_kind" = ws ]; then
        case " 443 2053 2083 2087 2096 8443 " in
            *" $selected_new_port "*) ;;
            *)
                warn "端口 $selected_new_port 不在 Cloudflare 橙云 HTTPS 代理端口列表内；仅适合 DNS Only/直连，橙云代理可能无法连接。"
                ;;
        esac
    fi

    old_selected_port=$selected_current
    case "$selected_choice" in
        1) ANYTLS_PORT=$selected_new_port ;;
        2) WS_PORT=$selected_new_port ;;
        3) REALITY_PORT=$selected_new_port ;;
        4) NAIVE_PORT=$selected_new_port ;;
        5) ANYREALITY_PORT=$selected_new_port ;;
        6) XHTTP_PORT=$selected_new_port ;;
        7) SNELL_PORT=$selected_new_port ;;
        8) SS2022_PORT=$selected_new_port ;;
    esac

    msg "正在仅修改 $selected_name 端口，并检查对应配置……"
    if [ "$selected_choice" = 6 ]; then
        if ! build_xray_config; then XHTTP_PORT=$old_selected_port; return 0; fi
        save_state || { XHTTP_PORT=$old_selected_port; build_xray_config || true; return 0; }
    elif ! build_config; then
        case "$selected_choice" in
            1) ANYTLS_PORT=$old_selected_port ;;
            2) WS_PORT=$old_selected_port ;;
            3) REALITY_PORT=$old_selected_port ;;
            4) NAIVE_PORT=$old_selected_port ;;
            5) ANYREALITY_PORT=$old_selected_port ;;
            6) XHTTP_PORT=$old_selected_port ;;
            7) SNELL_PORT=$old_selected_port ;;
            8) SS2022_PORT=$old_selected_port ;;
        esac
        warn "$selected_name 端口修改失败；已恢复原端口 $old_selected_port，其他节点参数未修改。"
        return 0
    fi

    msg "$selected_name 端口修改成功：$old_selected_port → $selected_new_port"
    show_nodes
    if [ "$selected_choice" = 2 ] && [ "$WS_MODE" = argo ]; then msg "请在 Cloudflare Tunnel Public Hostname 中将 $ARGO_HOST 的 Service URL 更新为 http://127.0.0.1:$WS_PORT。Argo WS 本机端口不需要 NAT 入站映射。"; else msg '请同步更新系统防火墙、云安全组及 NAT 服务商公网端口映射。'; fi
}

change_ports() {
    printf '当前端口：AnyTLS=%s, WS+TLS=%s, VLESS Reality=%s, NaiveProxy=%s, AnyTLS Reality=%s, XHTTP=%s, Snell=%s, SS2022=%s\n' "$ANYTLS_PORT" "$WS_PORT" "$REALITY_PORT" "$NAIVE_PORT" "$ANYREALITY_PORT" "$XHTTP_PORT" "$SNELL_PORT" "$SS2022_PORT"
    old_anytls=$ANYTLS_PORT
    old_ws=$WS_PORT
    old_reality=$REALITY_PORT
    old_naive=$NAIVE_PORT
    old_anyreality=$ANYREALITY_PORT
    old_xhttp=$XHTTP_PORT
    old_snell=$SNELL_PORT
    old_ss2022=$SS2022_PORT
    PREVIOUS_ANYTLS_PORT=$old_anytls
    PREVIOUS_WS_PORT=$old_ws
    PREVIOUS_REALITY_PORT=$old_reality
    PREVIOUS_NAIVE_PORT=$old_naive
    PREVIOUS_ANYREALITY_PORT=$old_anyreality
    PREVIOUS_XHTTP_PORT=$XHTTP_PORT
    PREVIOUS_SNELL_PORT=$SNELL_PORT
    ask_ports
    assign_ports
    if ! build_config; then
        ANYTLS_PORT=$old_anytls
        WS_PORT=$old_ws
        REALITY_PORT=$old_reality
        NAIVE_PORT=$old_naive
        ANYREALITY_PORT=$old_anyreality
        XHTTP_PORT=$old_xhttp
        SNELL_PORT=$old_snell
        SS2022_PORT=$old_ss2022
        return 0
    fi
    if [ "$ENABLE_XHTTP" = 1 ] && [ "$XHTTP_PORT" != "$old_xhttp" ]; then
        if ! build_xray_config; then XHTTP_PORT=$old_xhttp; build_xray_config || true; save_state || true; return 0; fi
        save_state || true
    fi
    show_nodes
    if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ]; then msg "如 WS 本机端口发生变化，请将 Cloudflare Tunnel Service URL 更新为 http://127.0.0.1:$WS_PORT。Argo WS 不需要公网入站映射。"; fi
    msg '请同步修改其他已安装直连协议的云安全组、系统防火墙和 NAT 映射。'
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
    msg '========== 即将立即卸载 sing-box 管理器 =========='
    printf '%s\n' '将删除：/etc/sing-box、/etc/xray、/usr/local/sbin/sb-manager、sing-box / Xray 服务文件、Argo 专用 cloudflared 服务及本脚本安装的软件包/二进制。'
    printf '%s\n' '不会删除：/root/.acme.sh、系统依赖包、系统防火墙规则、云厂商安全组或其他 cron 任务。'
    printf '%s\n' '卸载将直接继续执行；请确认当前连接的是正确的 VPS。'
    cf_managed=0; [ ! -f "$APP_DIR/cloudflared-managed" ] || cf_managed=1
    msg '正在停止 sing-box / Cloudflare Tunnel / Xray 服务……'
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$CLOUDFLARED_SERVICE" >/dev/null 2>&1 || true
        systemctl disable --now "$XRAY_SERVICE" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$CLOUDFLARED_SERVICE.service" "/etc/systemd/system/$XRAY_SERVICE.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$CLOUDFLARED_SERVICE" stop >/dev/null 2>&1 || true
        rc-update del "$CLOUDFLARED_SERVICE" default >/dev/null 2>&1 || true
        rc-service "$XRAY_SERVICE" stop >/dev/null 2>&1 || true
        rc-update del "$XRAY_SERVICE" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/$CLOUDFLARED_SERVICE" "/etc/init.d/$XRAY_SERVICE"
    fi
    rm -f "$CLOUDFLARED_RUN"
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
    restore_bbr

    msg '正在删除 sing-box 配置、证书副本和管理脚本……'
    rm -f "$RELOAD_HOOK"
    rm -rf "$APP_DIR" "$XRAY_DIR"
    [ "$cf_managed" -eq 0 ] || rm -f "$CLOUDFLARED_BIN"
    rm -f "$XRAY_BIN"
    rmdir "${XRAY_BIN%/*}" 2>/dev/null || true
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
        if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ]; then journalctl -u "$CLOUDFLARED_SERVICE" -n 80 --no-pager || true; fi
        if [ "$ENABLE_XHTTP" = 1 ]; then journalctl -u "$XRAY_SERVICE" -n 80 --no-pager || true; fi
    else
        tail -n 80 /var/log/messages 2>/dev/null || true
        rc-service sing-box status || true
        if [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ]; then tail -n 80 /var/log/messages 2>/dev/null | grep -i cloudflared || true; rc-service "$CLOUDFLARED_SERVICE" status || true; fi
    fi
}


diagnose_naive() {
    [ "$ENABLE_NAIVE" = 1 ] || { warn '当前未安装 NaiveProxy。'; return 1; }
    need_root
    msg '========== NaiveProxy 本机诊断 =========='
    printf '端口：%s/tcp\nTLS 域名：%s\n' "$NAIVE_PORT" "$TLS_DOMAIN"

    if ! port_listening "$NAIVE_PORT"; then
        warn "本机没有检测到 NaiveProxy TCP 监听端口 $NAIVE_PORT。请查看 sing-box 状态和日志。"
        return 1
    fi
    msg "本机 TCP 监听：正常（$NAIVE_PORT/tcp）"

    probe_tmp=$(mktemp)
    if run_with_timeout 10 openssl s_client \
        -connect "127.0.0.1:$NAIVE_PORT" \
        -servername "$TLS_DOMAIN" \
        -alpn h2 \
        -verify_hostname "$TLS_DOMAIN" \
        -verify_return_error \
        -brief </dev/null > "$probe_tmp" 2>&1; then
        cat "$probe_tmp"
        if grep -qi 'ALPN protocol: h2' "$probe_tmp"; then
            msg 'NaiveProxy 本机检查通过：TLS 证书验证成功，ALPN 协商为 HTTP/2（h2）。'
        else
            warn 'TLS 握手成功，但未看到 HTTP/2（h2）协商结果；请检查 sing-box 版本和日志。'
        fi
        rm -f "$probe_tmp"
        return 0
    else
        cat "$probe_tmp"
        rm -f "$probe_tmp"
        warn '本机 TLS/证书验证失败。请检查证书是否过期、域名是否匹配、证书链是否完整。'
        return 1
    fi
}


configure_xhttp_certificate() {
    if [ -n "$TLS_DOMAIN" ] && [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ] && check_cert_pair "$CERT_FILE" "$KEY_FILE" "$TLS_DOMAIN"; then
        [ -n "$CERT_MODE" ] && [ "$CERT_MODE" != none ] || CERT_MODE=manual
        msg "复用现有 TLS 证书：$TLS_DOMAIN"
        return 0
    fi
    ask_value 'XHTTP TLS 证书域名（必须由你管理并解析到本 VPS）' "${TLS_DOMAIN:-}"
    TLS_DOMAIN=$(trim_value "$REPLY")
    valid_cert_domain "$TLS_DOMAIN" || { warn 'TLS 证书域名无效。'; return 1; }
    msg '证书方式：1=Cloudflare DNS-01（推荐 NAT VPS），2=HTTP-01（公网 TCP 80），3=手动导入。'
    ask_value '请选择证书方式（1/2/3）' '1'
    case "$REPLY" in
        1)
            CERT_MODE=cloudflare
            ask_value 'Cloudflare DNS 区域根域名（例如 example.com）' "${CF_ZONE_NAME:-}"
            CF_ZONE_NAME=$(trim_value "$REPLY")
            valid_cert_domain "$CF_ZONE_NAME" && domain_belongs_to_zone "$TLS_DOMAIN" "$CF_ZONE_NAME" || { warn 'TLS 域名必须属于 Cloudflare 区域根域名。'; return 1; }
            ask_secret 'Cloudflare DNS API Token（需要 Zone:DNS:Edit；输入不会显示）'
            cf_token=$(trim_value "$REPLY")
            [ -n "$cf_token" ] || { warn 'Cloudflare DNS API Token 不能为空。'; return 1; }
            ask_value 'Cloudflare Zone ID（可选，32 位十六进制）' "$(cat "$CF_ZONE_ID_FILE" 2>/dev/null || true)"
            zone_id=$(trim_value "$REPLY")
            if [ -n "$zone_id" ]; then
                case "$zone_id" in *[!A-Fa-f0-9]*) warn 'Zone ID 格式无效。'; return 1 ;; esac
                [ "${#zone_id}" -eq 32 ] || { warn 'Zone ID 必须为 32 位十六进制。'; return 1; }
            fi
            printf '%s' "$cf_token" > "$CF_TOKEN_FILE"; chmod 0600 "$CF_TOKEN_FILE"; chown root:root "$CF_TOKEN_FILE"
            if [ -n "$zone_id" ]; then printf '%s' "$zone_id" > "$CF_ZONE_ID_FILE"; chmod 0600 "$CF_ZONE_ID_FILE"; else rm -f "$CF_ZONE_ID_FILE"; fi
            setup_reload_hook
            install_acme ''
            issue_cloudflare_cert "$TLS_DOMAIN" || { warn 'Cloudflare DNS-01 证书签发失败。'; return 1; }
            ;;
        2)
            CERT_MODE=standalone; CF_ZONE_NAME=""; rm -f "$CF_TOKEN_FILE" "$CF_ZONE_ID_FILE"
            setup_reload_hook
            issue_http_cert "$TLS_DOMAIN" || { warn 'HTTP-01 证书签发失败；请确认 TCP 80 端口可用。'; return 1; }
            ;;
        3)
            CERT_MODE=manual; CF_ZONE_NAME=""; rm -f "$CF_TOKEN_FILE" "$CF_ZONE_ID_FILE"
            install_manual_cert "$TLS_DOMAIN" || return 1
            setup_reload_hook
            ;;
        *) warn '证书方式只能选择 1、2 或 3。'; return 1 ;;
    esac
    check_cert_pair "$CERT_FILE" "$KEY_FILE" "$TLS_DOMAIN" || return 1
}

choose_free_added_port() {
    # IMPORTANT: call this function in the current shell, never as $(...):
    # command substitution creates a subshell and makes interactive stdin
    # handling fragile in SSH terminal clients. The selected port is returned
    # through CHOSEN_PORT; stdout remains free of prompts and data.
    CHOSEN_PORT=""
    printf '新节点 TCP 端口（留空自动分配 10000–65535）: '
    if ! IFS= read -r requested_input; then
        warn '终端输入流已关闭，已取消添加节点；没有修改任何配置。'
        return 1
    fi
    requested=$(normalize_optional_port "$requested_input" '新节点') || return 1
    other="$ANYTLS_PORT $WS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT $XHTTP_PORT $SNELL_PORT $SS2022_PORT"
    if [ -n "$requested" ]; then
        case " $other " in *" $requested "*) warn '该端口已被本脚本其他节点占用。'; return 1 ;; esac
        if port_listening "$requested"; then warn "端口 $requested 已被其他进程监听。"; return 1; fi
        CHOSEN_PORT=$requested
    else
        CHOSEN_PORT=$(pick_random_range_port 10000 65535 $other) || return 1
    fi
    valid_port "$CHOSEN_PORT" || { CHOSEN_PORT=""; warn '端口分配结果无效；已取消添加。'; return 1; }
    return 0
}

remove_xhttp_node() {
    [ "$ENABLE_XHTTP" = 1 ] || { warn '当前未安装 XHTTP。'; return 0; }
    ask_value '确认移除 VLESS XHTTP + ECH 节点？输入 yes 确认' 'no'
    [ "$REPLY" = yes ] || { msg '已取消。'; return 0; }
    if [ "$SERVICE_KIND" = systemd ]; then
        systemctl disable --now "$XRAY_SERVICE" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${XRAY_SERVICE}.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
    elif [ "$SERVICE_KIND" = openrc ]; then
        rc-service "$XRAY_SERVICE" stop >/dev/null 2>&1 || true
        rc-update del "$XRAY_SERVICE" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/${XRAY_SERVICE}"
    fi
    rm -f "$XRAY_CONFIG_FILE" "$XRAY_ECH_KEYS_FILE" "$XRAY_ECH_CONFIG_FILE" "$XRAY_CLIENT_CONFIG_FILE"
    ENABLE_XHTTP=0; XHTTP_PORT=""; XHTTP_UUID=""; XHTTP_PATH=""
    save_state || { warn '管理状态保存失败。'; return 1; }
    msg 'XHTTP 节点已移除。原有 sing-box 节点和 TLS 证书未删除。'
}

manage_xhttp_node() {
    if [ "$ENABLE_XHTTP" = 1 ]; then
        printf '\nVLESS XHTTP + ECH 已安装：%s:%s\n' "$TLS_DOMAIN" "$XHTTP_PORT"
        printf '1. 重新生成 ECH 密钥\n2. 移除 XHTTP 节点\n0. 返回\n请选择：'
        IFS= read -r subchoice || subchoice=0
        case "$subchoice" in 1) rotate_xhttp_ech_keys ;; 2) remove_xhttp_node ;; 0) return 0 ;; *) warn '无效选择。' ;; esac
        return 0
    fi
    msg '========== 添加 VLESS + XHTTP + ECH =========='
    configure_xhttp_certificate || { warn 'TLS 证书准备失败；没有启用 XHTTP。'; return 1; }
    ask_value 'ECH Public Name（外层 ClientHello 公开名称）' "${XHTTP_ECH_PUBLIC_NAME:-cloudflare-ech.com}"
    XHTTP_ECH_PUBLIC_NAME=$(trim_value "$REPLY")
    valid_domain "$XHTTP_ECH_PUBLIC_NAME" || { warn 'ECH Public Name 格式无效。'; return 1; }
    ask_value 'XHTTP 模式（auto / packet-up / stream-up / stream-one）' "${XHTTP_MODE:-auto}"
    XHTTP_MODE=$(trim_value "$REPLY")
    case "$XHTTP_MODE" in auto|packet-up|stream-up|stream-one) ;; *) warn 'XHTTP mode 无效。'; return 1 ;; esac
    choose_free_added_port || { warn '无法分配端口；没有启用 XHTTP。'; return 1; }
    new_port=$CHOSEN_PORT
    install_xray_core || return 1
    ensure_service_account
    XHTTP_PORT=$new_port
    XHTTP_UUID=$("$XRAY_BIN" uuid 2>/dev/null || "$SB_BIN" generate uuid)
    XHTTP_PATH="/xhttp-$(openssl rand -hex 10)"
    ENABLE_XHTTP=1
    if ! generate_xhttp_ech_keys; then ENABLE_XHTTP=0; return 1; fi
    create_xray_service
    if ! build_xray_config; then
        ENABLE_XHTTP=0; XHTTP_PORT=""; XHTTP_UUID=""; XHTTP_PATH=""
        if [ "$SERVICE_KIND" = systemd ]; then
            systemctl disable --now "$XRAY_SERVICE" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${XRAY_SERVICE}.service"
            systemctl daemon-reload >/dev/null 2>&1 || true
        else
            rc-service "$XRAY_SERVICE" stop >/dev/null 2>&1 || true
            rc-update del "$XRAY_SERVICE" default >/dev/null 2>&1 || true
            rm -f "/etc/init.d/${XRAY_SERVICE}"
        fi
        rm -f "$XRAY_CONFIG_FILE" "$XRAY_ECH_KEYS_FILE" "$XRAY_ECH_CONFIG_FILE"
        return 1
    fi
    if ! save_state; then
        ENABLE_XHTTP=0
        if [ "$SERVICE_KIND" = systemd ]; then
            systemctl disable --now "$XRAY_SERVICE" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${XRAY_SERVICE}.service"
            systemctl daemon-reload >/dev/null 2>&1 || true
        else
            rc-service "$XRAY_SERVICE" stop >/dev/null 2>&1 || true
            rc-update del "$XRAY_SERVICE" default >/dev/null 2>&1 || true
            rm -f "/etc/init.d/${XRAY_SERVICE}"
        fi
        rm -f "$XRAY_CONFIG_FILE" "$XRAY_ECH_KEYS_FILE" "$XRAY_ECH_CONFIG_FILE" "$XRAY_CLIENT_CONFIG_FILE"
        return 1
    fi
    write_xhttp_client_json || warn 'XHTTP 客户端 JSON 生成失败。'
    show_nodes
    msg "XHTTP 已安装。请放行 VPS / 云安全组 / NAT 的 TCP $XHTTP_PORT。"
    msg 'ECH 需要客户端使用输出的 ECH Config List；域名 DNS 应使用 DNS Only，不能让普通 CDN 代替本机 ECH TLS 端点。'
}

remove_snell_node() {
    [ "$ENABLE_SNELL" = 1 ] || { warn '当前未安装 Snell。'; return 0; }
    ask_value '确认移除 Snell 节点？输入 yes 确认' 'no'
    [ "$REPLY" = yes ] || { msg '已取消。'; return 0; }
    old_enabled=$ENABLE_SNELL; old_port=$SNELL_PORT; old_psk=$SNELL_PSK; old_userkey=$SNELL_USERKEY
    ENABLE_SNELL=0; SNELL_PORT=""; SNELL_PSK=""; SNELL_USERKEY=""
    if ! build_config; then ENABLE_SNELL=$old_enabled; SNELL_PORT=$old_port; SNELL_PSK=$old_psk; SNELL_USERKEY=$old_userkey; return 1; fi
    rm -f "$SNELL_CLIENT_CONFIG_FILE"
    msg 'Snell 节点已移除；其他 sing-box 节点保持不变。'
}

manage_snell_node() {
    if [ "$ENABLE_SNELL" = 1 ]; then
        printf '\nSnell v%s 已安装：%s/tcp\n1. 移除 Snell 节点\n0. 返回\n请选择：' "$SNELL_VERSION" "$SNELL_PORT"
        IFS= read -r subchoice || subchoice=0
        case "$subchoice" in 1) remove_snell_node ;; 0) return 0 ;; *) warn '无效选择。' ;; esac
        return 0
    fi
    msg '========== 添加 Snell 入站 =========='
    msg 'Snell v5 兼容性通常更好；Snell v6 使用 traffic shaping，客户端也必须支持 v6。'
    ask_value 'Snell 版本（5/6）' '5'
    SNELL_VERSION=$(trim_value "$REPLY")
    case "$SNELL_VERSION" in
        5)
            ask_value 'Snell v5 HTTP 混淆（http/none）' 'http'; SNELL_OBFS_MODE=$(trim_value "$REPLY")
            case "$SNELL_OBFS_MODE" in http|none) ;; *) warn 'obfs_mode 只能为 http 或 none。'; return 1 ;; esac
            SNELL_MODE=default
            ;;
        6)
            ask_value 'Snell v6 mode（default/unshaped/unsafe-raw）' 'default'; SNELL_MODE=$(trim_value "$REPLY")
            case "$SNELL_MODE" in default|unshaped|unsafe-raw) ;; *) warn 'Snell v6 mode 无效。'; return 1 ;; esac
            SNELL_OBFS_MODE=none
            ;;
        *) warn 'Snell 版本只能选择 5 或 6。'; return 1 ;;
    esac
    version=$(sing_box_version_from "$SB_BIN" || true)
    version_supports_snell "$version" || { warn "当前 sing-box $version 不支持 Snell；需要 1.14.0 或更新版本。请先运行覆盖升级。"; return 1; }
    choose_free_added_port || { warn '无法分配端口；没有启用 Snell。'; return 1; }
    new_port=$CHOSEN_PORT
    old_port=$SNELL_PORT; old_psk=$SNELL_PSK; old_userkey=$SNELL_USERKEY; old_enabled=$ENABLE_SNELL
    SNELL_PORT=$new_port; SNELL_PSK=$(openssl rand -hex 32); SNELL_USERKEY=$(openssl rand -hex 24); ENABLE_SNELL=1
    if ! build_config; then ENABLE_SNELL=$old_enabled; SNELL_PORT=$old_port; SNELL_PSK=$old_psk; SNELL_USERKEY=$old_userkey; return 1; fi
    write_snell_client_json || warn 'Snell 客户端配置片段生成失败。'
    show_nodes
    msg "Snell 已安装。请放行 VPS / 云安全组 / NAT 的 TCP $SNELL_PORT。"
}

# Unified terminal management for every protocol implemented by this script.
# Add/remove is transactional via build_config(); credentials are retained in
# manager.json when a node is disabled, and unrelated config entries survive.
protocol_flag() {
    case "$1" in
        1) printf '%s' "$ENABLE_ANYTLS" ;; 2) printf '%s' "$ENABLE_WS_TLS" ;;
        3) printf '%s' "$ENABLE_VLESS_REALITY" ;; 4) printf '%s' "$ENABLE_NAIVE" ;;
        5) printf '%s' "$ENABLE_ANYTLS_REALITY" ;; 6) printf '%s' "$ENABLE_XHTTP" ;;
        7) printf '%s' "$ENABLE_SNELL" ;; 8) printf '%s' "$ENABLE_SS2022" ;; esac
}
protocol_name() {
    case "$1" in 1) printf AnyTLS ;; 2) printf 'VLESS WS' ;; 3) printf 'VLESS Reality' ;; 4) printf NaiveProxy ;; 5) printf 'AnyTLS Reality' ;; 6) printf 'VLESS XHTTP ECH' ;; 7) printf Snell ;; 8) printf 'Shadowsocks 2022' ;; esac
}

add_base_protocol() {
    kind=$1
    choose_free_added_port || { warn '端口输入中断或无可用端口；已取消。'; return 1; }
    p=$CHOSEN_PORT
    case "$kind" in
      1)
        [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ] || { warn 'AnyTLS 需要有效 TLS 证书；请先完成证书配置。'; return 1; }
        ANYTLS_PORT=$p; ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-$(openssl rand -hex 24)}; ENABLE_ANYTLS=1 ;;
      2)
        if [ "$WS_MODE" = direct ]; then [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ] || { warn '直连 WS TLS 需要有效证书；请先完成证书配置。'; return 1; }; fi
        WS_PORT=$p; WS_UUID=${WS_UUID:-$($SB_BIN generate uuid)}; WS_PATH=${WS_PATH:-"/ws-$(openssl rand -hex 8)"}; ENABLE_WS_TLS=1 ;;
      3)
        REALITY_PORT=$p
        REALITY_UUID=${REALITY_UUID:-$($SB_BIN generate uuid)}
        if [ -z "$REALITY_PRIVATE" ] || [ -z "$REALITY_PUBLIC" ]; then
          kp=$($SB_BIN generate reality-keypair) || return 1
          REALITY_PRIVATE=$(printf '%s\n' "$kp" | awk '/PrivateKey/ {print $2}')
          REALITY_PUBLIC=$(printf '%s\n' "$kp" | awk '/PublicKey/ {print $2}')
        fi
        REALITY_SID=${REALITY_SID:-$(openssl rand -hex 4)}
        ENABLE_VLESS_REALITY=1 ;;
      4)
        [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ] || { warn 'NaiveProxy 需要有效 TLS 证书；请先完成证书配置。'; return 1; }
        NAIVE_PORT=$p; NAIVE_USERNAME=${NAIVE_USERNAME:-"naive-$(openssl rand -hex 6)"}; NAIVE_PASSWORD=${NAIVE_PASSWORD:-$(openssl rand -hex 24)}; ENABLE_NAIVE=1 ;;
      5)
        ANYREALITY_PORT=$p; ANYREALITY_PASSWORD=${ANYREALITY_PASSWORD:-$(openssl rand -hex 24)}
        if [ -z "$ANYREALITY_PRIVATE" ] || [ -z "$ANYREALITY_PUBLIC" ]; then
          kp=$($SB_BIN generate reality-keypair) || return 1
          ANYREALITY_PRIVATE=$(printf '%s\n' "$kp" | awk '/PrivateKey/ {print $2}')
          ANYREALITY_PUBLIC=$(printf '%s\n' "$kp" | awk '/PublicKey/ {print $2}')
        fi
        ANYREALITY_SID=${ANYREALITY_SID:-$(openssl rand -hex 4)}
        ENABLE_ANYTLS_REALITY=1 ;;
      *) return 1 ;;
    esac
    if ! build_config; then
      case "$kind" in 1) ENABLE_ANYTLS=0 ;; 2) ENABLE_WS_TLS=0 ;; 3) ENABLE_VLESS_REALITY=0 ;; 4) ENABLE_NAIVE=0 ;; 5) ENABLE_ANYTLS_REALITY=0 ;; esac
      return 1
    fi
    show_nodes
    msg "$(protocol_name "$kind") 已添加；端口 $p/tcp。请检查防火墙和 NAT 映射。"
}

remove_base_protocol() {
    kind=$1
    case "$kind" in
      1) old=$ENABLE_ANYTLS; ENABLE_ANYTLS=0 ;;
      2) old=$ENABLE_WS_TLS; ENABLE_WS_TLS=0 ;;
      3) old=$ENABLE_VLESS_REALITY; ENABLE_VLESS_REALITY=0 ;;
      4) old=$ENABLE_NAIVE; ENABLE_NAIVE=0 ;;
      5) old=$ENABLE_ANYTLS_REALITY; ENABLE_ANYTLS_REALITY=0 ;;
    esac
    [ "$old" = 1 ] || { warn "$(protocol_name "$kind") 当前未安装。"; return 0; }
    ask_value "确认移除 $(protocol_name "$kind")？输入 yes 确认" no
    [ "$REPLY" = yes ] || { case "$kind" in 1) ENABLE_ANYTLS=1 ;; 2) ENABLE_WS_TLS=1 ;; 3) ENABLE_VLESS_REALITY=1 ;; 4) ENABLE_NAIVE=1 ;; 5) ENABLE_ANYTLS_REALITY=1 ;; esac; msg '已取消。'; return 0; }
    if ! build_config; then
      case "$kind" in 1) ENABLE_ANYTLS=1 ;; 2) ENABLE_WS_TLS=1 ;; 3) ENABLE_VLESS_REALITY=1 ;; 4) ENABLE_NAIVE=1 ;; 5) ENABLE_ANYTLS_REALITY=1 ;; esac
      return 1
    fi
    msg "$(protocol_name "$kind") 已移除；其他节点和自定义入站保持不变。"
}

modify_base_protocol() {
    kind=$1
    old_anytls_password=$ANYTLS_PASSWORD; old_ws_path=$WS_PATH; old_reality_uuid=$REALITY_UUID
    old_naive_password=$NAIVE_PASSWORD; old_anyreality_password=$ANYREALITY_PASSWORD
    case "$kind" in
      1) [ "$ENABLE_ANYTLS" = 1 ] || { warn 'AnyTLS 未安装。'; return 1; }; ask_value 'AnyTLS 密码（留空保持不变；输入 rotate 自动生成）' ''; v=$REPLY; [ "$v" = rotate ] && ANYTLS_PASSWORD=$(openssl rand -hex 24) || { [ -z "$v" ] || ANYTLS_PASSWORD=$v; } ;;
      2) [ "$ENABLE_WS_TLS" = 1 ] || { warn 'VLESS WS 未安装。'; return 1; }; ask_value 'WS Path（留空保持不变；输入 rotate 自动生成）' ''; v=$REPLY; [ "$v" = rotate ] && WS_PATH="/ws-$(openssl rand -hex 8)" || { [ -z "$v" ] || WS_PATH=$v; } ;;
      3) [ "$ENABLE_VLESS_REALITY" = 1 ] || { warn 'VLESS Reality 未安装。'; return 1; }; ask_value 'Reality UUID（留空保持不变；输入 rotate 自动生成）' ''; v=$REPLY; [ "$v" = rotate ] && REALITY_UUID=$($SB_BIN generate uuid) || { [ -z "$v" ] || REALITY_UUID=$v; } ;;
      4) [ "$ENABLE_NAIVE" = 1 ] || { warn 'NaiveProxy 未安装。'; return 1; }; ask_value 'NaiveProxy 密码（留空保持不变；输入 rotate 自动生成）' ''; v=$REPLY; [ "$v" = rotate ] && NAIVE_PASSWORD=$(openssl rand -hex 24) || { [ -z "$v" ] || NAIVE_PASSWORD=$v; } ;;
      5) [ "$ENABLE_ANYTLS_REALITY" = 1 ] || { warn 'AnyTLS Reality 未安装。'; return 1; }; ask_value 'AnyTLS Reality 密码（留空保持不变；输入 rotate 自动生成）' ''; v=$REPLY; [ "$v" = rotate ] && ANYREALITY_PASSWORD=$(openssl rand -hex 24) || { [ -z "$v" ] || ANYREALITY_PASSWORD=$v; } ;;
    esac
    if build_config; then save_state && show_nodes && msg "$(protocol_name "$kind") 参数已更新。"; else
      ANYTLS_PASSWORD=$old_anytls_password; WS_PATH=$old_ws_path; REALITY_UUID=$old_reality_uuid
      NAIVE_PASSWORD=$old_naive_password; ANYREALITY_PASSWORD=$old_anyreality_password
      warn '修改失败，配置已回滚。'; return 1
    fi
}

modify_xhttp_node() {
    [ "$ENABLE_XHTTP" = 1 ] || { warn 'XHTTP 未安装。'; return 1; }
    old_mode=$XHTTP_MODE; old_path=$XHTTP_PATH; old_public=$XHTTP_ECH_PUBLIC_NAME
    ask_value 'XHTTP Mode（auto/packet-up/stream-up/stream-one；留空保持）' "$XHTTP_MODE"
    v=$(trim_value "$REPLY")
    case "$v" in auto|packet-up|stream-up|stream-one) XHTTP_MODE=$v ;; *) warn 'XHTTP Mode 无效。'; return 1 ;; esac
    ask_value 'XHTTP Path（留空保持；输入 rotate 自动生成）' "$XHTTP_PATH"
    v=$(trim_value "$REPLY")
    if [ "$v" = rotate ]; then XHTTP_PATH="/xhttp-$(openssl rand -hex 10)"; elif [ -n "$v" ]; then case "$v" in /*) XHTTP_PATH=$v ;; *) warn 'XHTTP Path 必须以 / 开头。'; return 1 ;; esac; fi
    ask_value 'ECH Public Name（留空保持）' "$XHTTP_ECH_PUBLIC_NAME"
    v=$(trim_value "$REPLY")
    valid_domain "$v" || { warn 'ECH Public Name 格式无效。'; return 1; }
    XHTTP_ECH_PUBLIC_NAME=$v
    if ! build_xray_config || ! save_state; then
      XHTTP_MODE=$old_mode; XHTTP_PATH=$old_path; XHTTP_ECH_PUBLIC_NAME=$old_public
      build_xray_config || true
      warn 'XHTTP 修改失败，已恢复原参数。'; return 1
    fi
    write_xhttp_client_json || warn 'XHTTP 客户端 JSON 更新失败。'
    show_nodes
}

add_ss2022() {
    [ "$ENABLE_SS2022" = 0 ] || { warn 'SS2022 已安装。'; return 1; }
    old_method=$SS2022_METHOD; old_password=$SS2022_PASSWORD; old_port=$SS2022_PORT
    # Adopt one existing unmanaged SS2022 inbound instead of silently replacing
    # its credentials/port when the user upgrades to first-class management.
    if [ -s "$CONFIG_FILE" ]; then
      existing_count=$(jq '[.inbounds[]? | select(.type == "shadowsocks" and (.method // "" | startswith("2022-blake3-")))] | length' "$CONFIG_FILE" 2>/dev/null || printf 0)
      if [ "$existing_count" = 1 ]; then
        existing_ss=$(jq -c '[.inbounds[]? | select(.type == "shadowsocks" and (.method // "" | startswith("2022-blake3-")))][0]' "$CONFIG_FILE")
        existing_method=$(printf '%s' "$existing_ss" | jq -r '.method')
        existing_port=$(printf '%s' "$existing_ss" | jq -r '.listen_port')
        existing_password=$(printf '%s' "$existing_ss" | jq -r '.password // ""')
        if [ -n "$existing_password" ] && valid_port "$existing_port"; then
          case "$existing_method" in 2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm) ;; *) existing_password="" ;; esac
          if [ -n "$existing_password" ]; then
            SS2022_METHOD=$existing_method; SS2022_PORT=$existing_port; SS2022_PASSWORD=$existing_password
            ENABLE_SS2022=1
            if build_config; then
              show_nodes
              msg "已接管现有 SS2022 入站，原端口 $SS2022_PORT、method 和密码均保留。"
              return 0
            fi
            ENABLE_SS2022=0; SS2022_METHOD=$old_method; SS2022_PASSWORD=$old_password; SS2022_PORT=$old_port
            warn '接管现有 SS2022 失败，原配置保持不变。'; return 1
          fi
        fi
      elif [ "$existing_count" -gt 1 ]; then
        warn '检测到多个未托管 SS2022 入站。为避免选错节点，请先手动确定要接管的入站，当前未做任何修改。'
        return 1
      fi
    fi
    choose_free_added_port || { warn '端口输入中断或无可用端口；已取消。'; return 1; }
    p=$CHOSEN_PORT
    ask_value 'SS2022 加密方式（2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm）' "${SS2022_METHOD:-2022-blake3-aes-256-gcm}"
    method=$(trim_value "$REPLY")
    case "$method" in
      2022-blake3-aes-128-gcm) key_bytes=16 ;;
      2022-blake3-aes-256-gcm) key_bytes=32 ;;
      *) warn 'SS2022 加密方式无效。'; return 1 ;;
    esac
    SS2022_METHOD=$method; SS2022_PORT=$p
    SS2022_PASSWORD=$(openssl rand -base64 "$key_bytes")
    ENABLE_SS2022=1
    if build_config && save_state; then
      show_nodes
      msg "Shadowsocks 2022 已添加：TCP $SS2022_PORT；method=$SS2022_METHOD。密码已保存至 manager.json（权限 0600）。"
    else
      ENABLE_SS2022=0; SS2022_METHOD=$old_method; SS2022_PASSWORD=$old_password; SS2022_PORT=$old_port
      warn 'SS2022 添加失败，已回滚。'; return 1
    fi
}

remove_ss2022() {
    [ "$ENABLE_SS2022" = 1 ] || { warn 'SS2022 当前未由管理器托管。若 config.json 中存在自定义 SS2022，将保持不变。'; return 0; }
    ask_value '确认移除 Shadowsocks 2022？输入 yes 确认' no
    [ "$REPLY" = yes ] || { msg '已取消。'; return 0; }
    old=$ENABLE_SS2022; ENABLE_SS2022=0
    if build_config && save_state; then msg 'SS2022 已移除；其他节点不受影响。'
    else ENABLE_SS2022=$old; warn 'SS2022 删除失败，已恢复。'; return 1; fi
}

modify_ss2022() {
    [ "$ENABLE_SS2022" = 1 ] || { warn 'SS2022 未安装。'; return 1; }
    old_method=$SS2022_METHOD; old_password=$SS2022_PASSWORD; old_port=$SS2022_PORT
    ask_value 'SS2022 method（留空保持；128/256）' "$SS2022_METHOD"
    v=$(trim_value "$REPLY")
    case "$v" in
      128|2022-blake3-aes-128-gcm) SS2022_METHOD=2022-blake3-aes-128-gcm; bytes=16 ;;
      256|2022-blake3-aes-256-gcm) SS2022_METHOD=2022-blake3-aes-256-gcm; bytes=32 ;;
      '') bytes=$([ "$SS2022_METHOD" = 2022-blake3-aes-128-gcm ] && printf 16 || printf 32) ;;
      *) warn 'method 仅支持 128 或 256。'; return 1 ;;
    esac
    if [ "$SS2022_METHOD" != "$old_method" ]; then SS2022_PASSWORD=$(openssl rand -base64 "$bytes"); fi
    ask_value 'SS2022 TCP 端口（留空保持；输入 auto 自动分配）' "$SS2022_PORT"
    v=$(trim_value "$REPLY")
    if [ "$v" = auto ]; then
      choose_free_added_port || return 1; SS2022_PORT=$CHOSEN_PORT
    elif [ -n "$v" ]; then
      valid_port "$v" || { warn '端口无效。'; return 1; }
      case " $ANYTLS_PORT $WS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT $XHTTP_PORT $SNELL_PORT " in *" $v "*) warn '该端口已被其他节点占用。'; return 1 ;; esac
      if port_listening "$v" && [ "$v" != "$SS2022_PORT" ]; then warn '该端口已被其他进程监听。'; return 1; fi
      SS2022_PORT=$v
    fi
    ask_value 'SS2022 密码（留空保持；输入 rotate 重新生成）' ''
    v=$(trim_value "$REPLY")
    if [ "$v" = rotate ]; then SS2022_PASSWORD=$(openssl rand -base64 "$bytes"); elif [ -n "$v" ]; then SS2022_PASSWORD=$v; fi
    case "$SS2022_METHOD:$SS2022_PASSWORD" in
      2022-blake3-aes-128-gcm:????????????????????????|2022-blake3-aes-256-gcm:????????????????????????????????????????????) ;;
      *) warn 'SS2022 密码必须是与所选 AES 方法匹配的 Base64 密钥；输入 rotate 自动生成。'; SS2022_METHOD=$old_method; SS2022_PASSWORD=$old_password; SS2022_PORT=$old_port; return 1 ;;
    esac
    if build_config && save_state; then show_nodes; msg 'SS2022 参数已更新。';
    else SS2022_METHOD=$old_method; SS2022_PASSWORD=$old_password; SS2022_PORT=$old_port; warn '修改失败，已回滚。'; return 1; fi
}

manage_all_protocols() {
    while :; do
      printf '\n========== 全协议终端管理（添加 / 删除 / 修改） ==========\n'
      for n in 1 2 3 4 5 6 7 8; do
        f=$(protocol_flag "$n"); [ "$f" = 1 ] && st=已安装 || st=未安装
        printf '%s. %-22s %s\n' "$n" "$(protocol_name "$n")" "$st"
      done
      printf '0. 返回\n选择协议：'
      IFS= read -r k || return 0
      case "$k" in 1|2|3|4|5|6|7|8) ;; 0) return 0 ;; *) warn '无效选择。'; continue ;; esac
      f=$(protocol_flag "$k")
      if [ "$f" = 1 ]; then
        printf '1. 修改参数 / 凭据\n2. 删除节点\n0. 返回\n选择操作：'
        IFS= read -r op || return 0
        case "$op" in
          1) case "$k" in 1|2|3|4|5) modify_base_protocol "$k" ;; 8) modify_ss2022 ;; 6) modify_xhttp_node ;; 7) modify_snell_node ;; esac ;;
          2) case "$k" in 1|2|3|4|5) remove_base_protocol "$k" ;; 8) remove_ss2022 ;; 6) remove_xhttp_node ;; 7) remove_snell_node ;; esac ;;
          0) : ;; *) warn '无效操作。' ;;
        esac
      else
        case "$k" in 1|2|3|4|5) add_base_protocol "$k" ;; 8) add_ss2022 ;; 6) manage_xhttp_node ;; 7) manage_snell_node ;; esac
      fi
    done
}

modify_snell_node() {
    [ "$ENABLE_SNELL" = 1 ] || return 1
    old_snell_version=$SNELL_VERSION; old_snell_mode=$SNELL_MODE; old_snell_obfs=$SNELL_OBFS_MODE
    old_snell_psk=$SNELL_PSK; old_snell_userkey=$SNELL_USERKEY
    printf '当前 Snell v%s，mode=%s，obfs=%s\n' "$SNELL_VERSION" "$SNELL_MODE" "$SNELL_OBFS_MODE"
    ask_value 'Snell 版本（5/6；留空保持不变）' "$SNELL_VERSION"
    v=$(trim_value "$REPLY")
    case "$v" in
      5) SNELL_VERSION=5; ask_value 'Snell v5 obfs（http/none）' "$SNELL_OBFS_MODE"; SNELL_OBFS_MODE=$(trim_value "$REPLY"); case "$SNELL_OBFS_MODE" in http|none) ;; *) warn '无效 obfs。'; return 1 ;; esac ;;
      6) SNELL_VERSION=6; ask_value 'Snell v6 mode（default/unshaped/unsafe-raw）' "$SNELL_MODE"; SNELL_MODE=$(trim_value "$REPLY"); case "$SNELL_MODE" in default|unshaped|unsafe-raw) ;; *) warn '无效 mode。'; return 1 ;; esac; SNELL_OBFS_MODE=none ;;
      '') : ;; *) warn '版本只能是 5 或 6。'; return 1 ;;
    esac
    ask_value 'PSK（留空保持不变；输入 rotate 重新生成）' ''; v=$REPLY; [ "$v" = rotate ] && SNELL_PSK=$(openssl rand -hex 32) || { [ -z "$v" ] || SNELL_PSK=$v; }
    ask_value 'UserKey（留空保持不变；输入 rotate 重新生成）' ''; v=$REPLY; [ "$v" = rotate ] && SNELL_USERKEY=$(openssl rand -hex 24) || { [ -z "$v" ] || SNELL_USERKEY=$v; }
    if build_config; then write_snell_client_json || true; show_nodes; else
      SNELL_VERSION=$old_snell_version; SNELL_MODE=$old_snell_mode; SNELL_OBFS_MODE=$old_snell_obfs
      SNELL_PSK=$old_snell_psk; SNELL_USERKEY=$old_snell_userkey
      warn 'Snell 修改失败，已恢复原参数。'; return 1
    fi
}

rotate_xhttp_ech_keys() {
    [ "$ENABLE_XHTTP" = 1 ] || { warn '当前未安装 XHTTP。'; return 1; }
    backup=$(mktemp -d) || return 1
    cp -p "$XRAY_ECH_KEYS_FILE" "$backup/keys" 2>/dev/null || true
    cp -p "$XRAY_ECH_CONFIG_FILE" "$backup/config" 2>/dev/null || true
    ask_value 'ECH Public Name（回车保持当前值）' "$XHTTP_ECH_PUBLIC_NAME"
    new_name=$(trim_value "$REPLY")
    valid_domain "$new_name" || { rm -rf "$backup"; warn 'ECH Public Name 格式无效。'; return 1; }
    old_name=$XHTTP_ECH_PUBLIC_NAME
    XHTTP_ECH_PUBLIC_NAME=$new_name
    if ! generate_xhttp_ech_keys || ! build_xray_config; then
        XHTTP_ECH_PUBLIC_NAME=$old_name
        [ ! -s "$backup/keys" ] || cp -p "$backup/keys" "$XRAY_ECH_KEYS_FILE"
        [ ! -s "$backup/config" ] || cp -p "$backup/config" "$XRAY_ECH_CONFIG_FILE"
        build_xray_config || true
        rm -rf "$backup"
        warn 'ECH 轮换失败，已恢复旧密钥。'
        return 1
    fi
    save_state || true
    write_xhttp_client_json || true
    rm -rf "$backup"
    msg 'ECH 密钥已轮换。旧客户端的 ECH Config 将不再匹配，请重新导入新的客户端 JSON。'
    show_nodes
}

menu() {
    need_root
    load_state
    derive_runtime_needs
    enable_bbr
    while :; do
        printf '\n========== sing-box 节点管理 ==========' 
        printf '\n源站 IPv4/域名：%s | 源站 IPv6：%s' "${ORIGIN_ADDR:-未设置}" "${ORIGIN_IPV6:-未设置}"
        printf '\nWS 单一连接地址：%s' "${WS_SERVER:-未设置}"
        printf '\nTLS 证书域名 / TLS SNI（证书协议）：%s' "${TLS_DOMAIN:-不需要（Argo WS 使用 $ARGO_HOST）}"
        printf '\nWS HTTP Host：%s | WS 接入：%s' "${WS_HOST:-未设置}" "$WS_MODE"
        if [ "$WS_MODE" = argo ] && [ "$ENABLE_WS_TLS" = 1 ]; then
            printf '\n固定 Tunnel：%s | Public Hostname：%s' "${ARGO_TUNNEL_NAME:-未命名}" "${ARGO_HOST:-未设置}"
        fi
        printf '\nReality SNI（VLESS Reality + AnyTLS Reality；默认 www.bing.com）：%s' "$REALITY_SNI" 
        printf '\n节点辨识符：%s' "${NODE_LABEL:-未设置}"
        printf '\n端口：AnyTLS %s | WS TLS %s | VLESS Reality %s | NaiveProxy %s/TCP | AnyTLS Reality %s | XHTTP %s | Snell %s | SS2022 %s' "$ANYTLS_PORT" "$WS_PORT" "$REALITY_PORT" "$NAIVE_PORT" "$ANYREALITY_PORT" "$XHTTP_PORT" "$SNELL_PORT" "$SS2022_PORT"
        printf '\n---------------------------------------\n'
        printf '1. 查看已安装协议节点链接\n'
        printf '2. 修改 TLS 证书域名 / TLS SNI（AnyTLS + 直连 WS + NaiveProxy）\n'
        printf '3. 修改 Reality SNI（VLESS Reality + AnyTLS Reality；新安装默认 www.bing.com）\n'
        printf '4. 修改 VLESS WS TLS / Argo 客户端连接地址（优选 IP/域名）\n'
        printf '5. 修改 VLESS WS HTTP Host（直连模式；Argo Host 由 Tunnel 主机名决定）\n'
        printf '6. 修改 Cloudflare DNS 区域 / TLS 证书域名（WS Host 自动跟随）\n'
        printf '7. 选择单个协议节点并修改端口（其他节点不变）\n'
        printf '8. 重启 sing-box\n'
        printf '9. 查看服务状态\n'
        printf '10. 查看最近日志\n'
        printf '11. 卸载 sing-box 和本脚本配置\n'
        printf '12. 查看 TCP BBR 加速状态\n'
        printf '13. 自定义节点辨识符\n'
        printf '14. 诊断 NaiveProxy（本机监听 / TLS 证书 / HTTP2）\n'
        printf '15. 批量修改已安装协议端口（留空随机）\n'
        printf '16. 查看 Cloudflare Tunnel 状态（Argo 模式）\n'
        printf '17. 修改固定 Argo Tunnel 域名 / 备注 / Token\n'
        printf '18. 添加 / 移除 VLESS XHTTP + ECH 节点\n'
        printf '19. 添加 / 移除 Snell 节点\n'
        printf '20. 重新生成 XHTTP ECH 密钥（会更新客户端配置）\n'
        printf '21. 查看 Xray 服务状态\n'
        printf '22. 查看 Xray 最近日志\n'
        printf '23. 全协议终端管理（添加 / 删除 / 修改）\n'
        printf '24. Shadowsocks 2022 专项管理（添加 / 删除 / 修改）\n'
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
            7) change_single_port ;;
            15) change_ports ;;
            8) service_restart && msg '服务已重启。' ;;
            9) service_status ;;
            10) show_logs ;;
            11) uninstall_manager || true; exit 0 ;;
            12) show_bbr_status ;;
            13) change_node_label ;;
            14) [ "$ENABLE_NAIVE" = 1 ] && diagnose_naive || warn '当前未安装 NaiveProxy。' ;;
            16) [ "$ENABLE_WS_TLS" = 1 ] && [ "$WS_MODE" = argo ] && cloudflared_status || warn '当前未启用 Argo Tunnel。' ;;
            17) change_argo_binding ;;
            18) manage_xhttp_node ;;
            19) manage_snell_node ;;
            20) rotate_xhttp_ech_keys ;;
            21) xray_service_status ;;
            22) [ "$ENABLE_XHTTP" = 1 ] && { if [ "$SERVICE_KIND" = systemd ]; then journalctl -u "$XRAY_SERVICE" -n 80 --no-pager || true; else tail -n 80 /var/log/messages 2>/dev/null | grep -i xray || true; fi; } || warn '当前未安装 XHTTP/Xray。' ;;
            23) manage_all_protocols ;;
            24) manage_all_protocols ;;
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


prepare_web_config_core() {
    need_root
    web_cfg=${1:-}
    [ -n "$web_cfg" ] && [ -s "$web_cfg" ] || err '用法：sb-manager prepare-web-config-core /path/to/config.json'

    # Bootstrap only the small tools needed to inspect the generated config.
    if [ -f /etc/alpine-release ]; then
        apk add --no-cache ca-certificates curl jq openssl tar gzip unzip coreutils cronie
        OS_FAMILY=alpine; SERVICE_KIND=openrc
    elif [ -f /etc/debian_version ]; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq openssl tar gzip unzip cron gpg
        OS_FAMILY=debian; SERVICE_KIND=systemd
    else
        err '仅支持 Debian / Ubuntu 和 Alpine Linux。'
    fi
    jq -e '.schema == 8 and (.protocols | type == "object")' "$web_cfg" >/dev/null 2>&1 || err '网页配置 JSON 格式不正确或版本不匹配，无法预装对应核心。'

    ENABLE_ANYTLS=$(jq -r 'if .protocols.anytls == true then 1 else 0 end' "$web_cfg")
    ENABLE_WS_TLS=$(jq -r 'if .protocols.ws_tls == true then 1 else 0 end' "$web_cfg")
    ENABLE_VLESS_REALITY=$(jq -r 'if .protocols.vless_reality == true then 1 else 0 end' "$web_cfg")
    ENABLE_NAIVE=$(jq -r 'if .protocols.naive == true then 1 else 0 end' "$web_cfg")
    ENABLE_ANYTLS_REALITY=$(jq -r 'if .protocols.anytls_reality == true then 1 else 0 end' "$web_cfg")
    ENABLE_XHTTP=$(jq -r 'if .protocols.xhttp == true then 1 else 0 end' "$web_cfg")
    ENABLE_SNELL=$(jq -r 'if .protocols.snell == true then 1 else 0 end' "$web_cfg")
    ENABLE_SS2022=$(jq -r 'if .protocols.ss2022 == true then 1 else 0 end' "$web_cfg")

    msg '========== 第一阶段：安装本次所选协议需要的核心 =========='
    install_dependencies_and_core
    if [ "$ENABLE_XHTTP" = 1 ]; then
        msg '检测到 VLESS + XHTTP + ECH，预装独立 Xray-core……'
        install_xray_core
    fi
    msg '========== 核心预装完成，开始进入协议配置阶段 =========='
    msg "sing-box：$SB_BIN"
    "$SB_BIN" version | sed -n '1,2p'
    if [ "$ENABLE_XHTTP" = 1 ]; then "$XRAY_BIN" version | sed -n '1,2p'; fi
}

prepare_core_only() {
    need_root
    ENABLE_ANYTLS=0; ENABLE_WS_TLS=0; ENABLE_VLESS_REALITY=0; ENABLE_NAIVE=0
    ENABLE_ANYTLS_REALITY=0; ENABLE_XHTTP=0; ENABLE_SNELL=0; ENABLE_SS2022=0
    install_dependencies_and_core
    if [ "${1:-}" = --xhttp ]; then
        ENABLE_XHTTP=1
        install_xray_core
        msg "Xray-core 前置安装完成：$XRAY_BIN"
    elif [ -n "${1:-}" ]; then
        err '用法：sb-manager prepare-core [--xhttp]'
    fi
    msg '核心前置环境已准备完成。现在可以运行网页生成的 install-web-config 命令，或重新运行脚本进行协议向导安装。'
    msg '注意：此阶段只安装核心、系统依赖和 cron 定时服务，不创建代理入站、不覆盖现有节点配置。'
}

main() {
    need_root
    if [ "${1:-}" = prepare-web-config-core ]; then
        [ "$#" -eq 2 ] || err '用法：sb-manager prepare-web-config-core /path/to/config.json'
        prepare_web_config_core "$2"
        return 0
    fi
    if [ "${1:-}" = prepare-core ] || [ "${1:-}" = bootstrap-core ]; then
        shift
        prepare_core_only "${1:-}"
        return 0
    fi
    if [ "${1:-}" = bbr ] || [ "${1:-}" = bbr-status ]; then
        if [ -f /etc/alpine-release ]; then
            OS_FAMILY=alpine
            apk add --no-cache kmod >/dev/null
        elif [ -f /etc/debian_version ]; then
            OS_FAMILY=debian
            DEBIAN_FRONTEND=noninteractive apt-get install -y procps kmod >/dev/null
        else
            err '仅支持 Debian 和 Alpine Linux。'
        fi
        install -d -m 0750 "$APP_DIR"
        if [ "${1:-}" = bbr ]; then
            enable_bbr
        fi
        show_bbr_status
        return 0
    fi
    if [ "${1:-}" = uninstall ] || [ "${1:-}" = remove ]; then
        uninstall_manager "${2:-}"
        return 0
    fi
    if [ "${1:-}" = install-web-config ]; then
        [ "$#" -eq 2 ] || err '用法：sb-manager install-web-config /path/to/config.json'
        install_web_config "$2"
        return 0
    fi
    if [ "${1:-}" = nodes ]; then
        load_state
        show_nodes
        return 0
    fi
    install_manager_command
    if [ -e "$STATE_FILE" ]; then
        if ! manager_state_is_valid; then
            backup_existing_install
            err "检测到现有 manager.json 为空或格式损坏。原数据已备份；为避免丢失节点凭据，未自动重置。请先检查备份后再决定如何恢复。"
        fi
        load_state
        derive_runtime_needs
        if [ -f /etc/alpine-release ]; then OS_FAMILY=alpine; SERVICE_KIND=openrc; else OS_FAMILY=debian; SERVICE_KIND=systemd; fi
        SB_BIN="$(resolve_sing_box_binary 2>/dev/null || printf /usr/bin/sing-box)"
        case "${1:-}" in
            install|--install) overlay_install ;;
            *) menu ;;
        esac
    else
        install_wizard
    fi
}

main "$@"
