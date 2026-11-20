#!/bin/sh
# sing-box single-VPS multi-protocol manager for Debian + Alpine
# AnyTLS + AnyTLS/Reality + VLESS/WS/TLS + VLESS/Reality + NaiveProxy
# IPv4 + IPv6 dual-stack listeners and separate address-family node links
# Occupied manual ports automatically fall back to free protocol-supported ports; Cloudflare DNS-01 or HTTP-01
# WEB_CONFIG_MODE=1; web single-server configuration; overlay install preserves existing settings
# WEB_CONFIG_SCHEMA=7; WEB_CONFIG_SCHEMA=6; WEB_CONFIG_SCHEMA=5
# WEB_WS_PREFERENCES=1
# Manager menu 18 / sb-manager add: additive installation of missing protocol nodes
# Manager menu 19: remove one protocol; menu 20: protocol-scoped SNI/IP/Cloudflare/port/credential editor
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
SS2022_PORT=""
SS2022_PASSWORD=""
SS2022_METHOD=2022-blake3-aes-128-gcm
ENABLE_SS2022=0
# Selective protocol installation. Missing flags in old manager.json are treated as enabled.
ENABLE_ANYTLS=1
ENABLE_WS_TLS=1
ENABLE_VLESS_REALITY=1
ENABLE_NAIVE=1
ENABLE_ANYTLS_REALITY=1
ENABLE_WS_ARGO=0
ARGO_PORT=""
ARGO_SERVER=""
ARGO_UUID=""
ARGO_PATH=""
ARGO_HOST=""
ARGO_TUNNEL_NAME=""
ARGO_TOKEN=""
ARGO_TOKEN_FILE="$APP_DIR/cloudflared.token"
CLOUDFLARED_BIN=/usr/local/libexec/sb-manager/cloudflared
CLOUDFLARED_RUN=/usr/local/sbin/sb-cloudflared-run
CLOUDFLARED_SERVICE=cloudflared-sb-tunnel
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
        if (s ~ /\./) {
          ipv4_start=match(s, /[^:]+$/)
          if (ipv4_start <= 1 || split(substr(s,ipv4_start),octets,/[.]/) != 4) exit 1
          for (octet_index=1;octet_index<=4;octet_index++) {
            octet=octets[octet_index]
            if (octet !~ /^(0|[1-9][0-9]*)$/ || length(octet) > 3 || octet+0 > 255) exit 1
          }
          s=substr(s,1,ipv4_start-1) sprintf("%x:%x",256*octets[1]+octets[2],256*octets[3]+octets[4])
        }
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
    if ss -H -lnt 2>/dev/null | awk -v suffix=":$p" '$4 ~ (suffix "$") {found=1} END {exit !found}'; then return 0; fi
    [ "${check_udp_port:-0}" = 1 ] &&
        ss -H -lnu 2>/dev/null | awk -v suffix=":$p" '$4 ~ (suffix "$") {found=1} END {exit !found}'
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
    SS2022_PORT=$(normalize_optional_port "$SS2022_PORT" 'Shadowsocks 2022') || exit 1
    ARGO_PORT=$(normalize_optional_port "$ARGO_PORT" 'VLESS WS Argo') || exit 1
    WS_PORT=$(normalize_optional_port "$WS_PORT" 'VLESS WS TLS') || exit 1
    REALITY_PORT=$(normalize_optional_port "$REALITY_PORT" 'VLESS Reality') || exit 1
    NAIVE_PORT=$(normalize_optional_port "$NAIVE_PORT" 'NaiveProxy') || exit 1
    ANYREALITY_PORT=$(normalize_optional_port "$ANYREALITY_PORT" 'AnyTLS + Reality') || exit 1

    [ "$ENABLE_ANYTLS" = 1 ] || ANYTLS_PORT=""
    [ "$ENABLE_WS_TLS" = 1 ] || WS_PORT=""
    [ "$ENABLE_WS_ARGO" = 1 ] || ARGO_PORT=""
    [ "$ENABLE_SS2022" = 1 ] || SS2022_PORT=""
    [ "$ENABLE_VLESS_REALITY" = 1 ] || REALITY_PORT=""
    [ "$ENABLE_NAIVE" = 1 ] || NAIVE_PORT=""
    [ "$ENABLE_ANYTLS_REALITY" = 1 ] || ANYREALITY_PORT=""

    used_ports=""
    reserved_ports=""
    if [ "${web_schema:-}" = 7 ]; then
        reserved_ports="$ANYTLS_PORT $WS_PORT $ARGO_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT $SS2022_PORT"
    fi
    PORT_FALLBACK_USED=0
    for protocol_name in 'AnyTLS' 'VLESS WS TLS' 'VLESS WS Argo' 'VLESS Reality' 'NaiveProxy' 'AnyTLS + Reality' 'Shadowsocks 2022'; do
        case "$protocol_name" in
            'AnyTLS') enabled=$ENABLE_ANYTLS; item_port=$ANYTLS_PORT ;;
            'VLESS WS TLS') enabled=$ENABLE_WS_TLS; item_port=$WS_PORT ;;
            'VLESS WS Argo') enabled=$ENABLE_WS_ARGO; item_port=$ARGO_PORT ;;
            'Shadowsocks 2022') enabled=$ENABLE_SS2022; item_port=$SS2022_PORT ;;
            'VLESS Reality') enabled=$ENABLE_VLESS_REALITY; item_port=$REALITY_PORT ;;
            'NaiveProxy') enabled=$ENABLE_NAIVE; item_port=$NAIVE_PORT ;;
            'AnyTLS + Reality') enabled=$ENABLE_ANYTLS_REALITY; item_port=$ANYREALITY_PORT ;;
        esac
        [ "$enabled" = 1 ] || continue

        if [ -n "$item_port" ]; then
            case " $used_ports " in
                *" $item_port "*)
                    [ "${web_schema:-}" != 7 ] || err "$protocol_name 的端口 $item_port 与其他所选协议重复。请修改网页端口后重试。"
                    warn "$protocol_name 指定端口 $item_port 与已选择协议重复；将自动随机分配。"
                    item_port=""
                    PORT_FALLBACK_USED=1
                    ;;
                *)
                    if ! check_udp_port="$([ "$protocol_name" = 'Shadowsocks 2022' ] && printf 1 || printf 0)" manual_port_available "$item_port" \
                        "$PREVIOUS_ANYTLS_PORT" "$PREVIOUS_WS_PORT" "$PREVIOUS_REALITY_PORT" \
                        "$PREVIOUS_NAIVE_PORT" "$PREVIOUS_ANYREALITY_PORT" "${PREVIOUS_ARGO_PORT:-}" "${PREVIOUS_SS2022_PORT:-}"; then
                        [ "${web_schema:-}" != 7 ] || err "$protocol_name 的端口 $item_port 已被占用。请修改网页端口后重试。"
                        warn "$protocol_name 指定 TCP 端口 $item_port 已被其他程序占用；将自动随机分配。"
                        item_port=""
                        PORT_FALLBACK_USED=1
                    fi
                    ;;
            esac
        fi

        if [ -z "$item_port" ]; then
            case "$protocol_name" in
                'VLESS WS TLS') item_port=$(pick_random_ws_port $used_ports $reserved_ports) || err 'WS TLS 无可用的 Cloudflare HTTPS 代理端口。' ;;
                'Shadowsocks 2022') item_port=$(check_udp_port=1 pick_random_range_port 10000 65535 $used_ports $reserved_ports) || err '无法为 Shadowsocks 2022 分配空闲 TCP/UDP 端口。' ;;
                'VLESS WS Argo') item_port=$(pick_random_range_port 10000 65535 $used_ports $reserved_ports) || err '无法为 Argo 本机 WS 分配空闲端口。' ;;
                *) item_port=$(pick_random_range_port 10000 65535 $used_ports $reserved_ports) || err "无法为 $protocol_name 分配可用端口。" ;;
            esac
        fi
        used_ports="$used_ports $item_port"
        case "$protocol_name" in
            'AnyTLS') ANYTLS_PORT=$item_port ;;
            'VLESS WS TLS') WS_PORT=$item_port ;;
            'VLESS WS Argo') ARGO_PORT=$item_port ;;
            'Shadowsocks 2022') SS2022_PORT=$item_port ;;
            'VLESS Reality') REALITY_PORT=$item_port ;;
            'NaiveProxy') NAIVE_PORT=$item_port ;;
            'AnyTLS + Reality') ANYREALITY_PORT=$item_port ;;
        esac
    done

    msg "已选择协议端口：AnyTLS=${ANYTLS_PORT:-未安装}，WS TLS=${WS_PORT:-未安装}，Argo=${ARGO_PORT:-未安装}，VLESS Reality=${REALITY_PORT:-未安装}，NaiveProxy=${NAIVE_PORT:-未安装}，AnyTLS Reality=${ANYREALITY_PORT:-未安装}，Shadowsocks 2022=${SS2022_PORT:-未安装}"
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
        ask_value '直连 VLESS WS TLS TCP 端口（留空自动分配 Cloudflare 支持端口）' "${WS_PORT:-}"
        WS_PORT=$REPLY
    else WS_PORT=""; fi
    if [ "$ENABLE_WS_ARGO" = 1 ]; then
        ask_value 'Argo 本机 WS 端口（留空自动分配；无需公网入站）' "$ARGO_PORT"
        ARGO_PORT=$REPLY
    else ARGO_PORT=""; fi
    if [ "$ENABLE_SS2022" = 1 ]; then
        ask_value 'Shadowsocks 2022 TCP/UDP 端口（留空自动分配）' "$SS2022_PORT"
        SS2022_PORT=$REPLY
    else SS2022_PORT=""; fi
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

normalize_tunnel_name() {
    trim_value "$1" | sed 's/  */ /g'
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
    case "$REPLY" in
        *[![:blank:]]*) ;;
        *) REPLY=$default ;;
    esac
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
    version_line=$("$candidate_bin" version 2>/dev/null | sed -n '1p' || true)
    printf '%s\n' "$version_line" |
        sed -n 's/.*version[[:space:]]*v\{0,1\}\([0-9][0-9.]*\).*/\1/p'
}

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
    # Prefer the upstream binary installed under /usr/local/bin. On Alpine,
    # an older APK binary may still exist under /usr/bin after fallback.
    if [ -x /usr/local/bin/sing-box ]; then
        printf '%s\n' /usr/local/bin/sing-box
        return 0
    fi
    command -v sing-box 2>/dev/null
}

install_alpine_official_release() {
    msg 'Alpine 仓库中的 sing-box 不存在或版本低于 1.13.0，改用 sing-box 官方 Linux 发布版……'
    if ! release_json=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest); then
        err '无法访问 GitHub Releases API；请检查 VPS 网络后重试。'
    fi
    tag=$(printf '%s\n' "$release_json" | jq -r '.tag_name // empty') ||
        err '无法解析 GitHub 最新 sing-box 版本信息。'
    case "$tag" in ''|null) err 'GitHub 未返回 sing-box 最新版本号。' ;; esac
    ver=${tag#v}
    case "$(uname -m)" in
        x86_64) rel_arch=amd64 ;;
        aarch64) rel_arch=arm64 ;;
        armv7l|armv7) rel_arch=armv7 ;;
        *) err "暂不支持此 Alpine CPU 架构：$(uname -m)" ;;
    esac
    archive="sing-box-${ver}-linux-${rel_arch}.tar.gz"
    unpack_dir=$(mktemp -d /tmp/sing-box-unpack.XXXXXX) || err '无法创建 sing-box 临时解压目录。'
    if ! curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/${tag}/${archive}" -o "/tmp/${archive}"; then
        rm -rf "$unpack_dir" "/tmp/${archive}"
        err "下载 sing-box 官方发布版失败（${archive}）；请检查 GitHub 网络连接后重试。"
    fi
    if ! tar -xzf "/tmp/${archive}" -C "$unpack_dir"; then
        rm -rf "$unpack_dir" "/tmp/${archive}"
        err '解压 sing-box 官方发布版失败。'
    fi
    mkdir -p /usr/local/bin
    if ! install -m 0755 "$unpack_dir/sing-box-${ver}-linux-${rel_arch}/sing-box" /usr/local/bin/sing-box; then
        rm -rf "$unpack_dir" "/tmp/${archive}"
        err '安装 sing-box 官方 Linux 二进制文件失败。'
    fi
    rm -rf "$unpack_dir" "/tmp/${archive}"

    # Pin the manager/service to the official binary explicitly. Do not let an
    # older /usr/bin/sing-box from Alpine's APK package shadow this version.
    SB_BIN=/usr/local/bin/sing-box
    release_version=$(sing_box_version_from "$SB_BIN" || true)
    version_supports_naive "$release_version" ||
        err "官方发布版版本检查失败（检测到：${release_version:-无法识别}）；NaiveProxy 需要 sing-box 1.13.0 或更新版本。"
    msg "已安装官方 sing-box：$release_version（满足 NaiveProxy 最低版本要求）。"
}

install_dependencies_and_core() {
    if [ -f /etc/alpine-release ]; then
        OS_FAMILY=alpine
        msg '检测到 Alpine Linux，安装 sing-box 和依赖……'
        apk update
        apk add --no-cache ca-certificates curl jq openssl iproute2 tar gzip kmod

        # Some Alpine repositories provide sing-box, but older branches may
        # package a release below 1.13.0. Naive inbound requires >= 1.13.0.
        # Install the APK when available, inspect its actual binary version,
        # and fall back to the upstream release whenever it is absent, broken,
        # or too old.
        if apk search -x sing-box 2>/dev/null | grep -q .; then
            if ! apk add --no-cache sing-box; then
                warn 'Alpine sing-box APK 安装失败；将尝试官方 Linux 发布版。'
            fi
        fi

        candidate_bin=$(command -v sing-box 2>/dev/null || true)
        candidate_version=""
        if [ -n "$candidate_bin" ]; then
            candidate_version=$(sing_box_version_from "$candidate_bin" || true)
        fi

        if [ -n "$candidate_bin" ] && version_supports_naive "$candidate_version"; then
            SB_BIN=$candidate_bin
            msg "使用 Alpine 仓库 sing-box：$candidate_version（满足 NaiveProxy 最低版本要求）。"
        else
            if [ -n "$candidate_bin" ]; then
                warn "Alpine 仓库提供的 sing-box 版本为 ${candidate_version:-无法识别}，低于 NaiveProxy 所需的 1.13.0；自动切换到官方新版。"
            else
                warn 'Alpine 仓库没有可用的 sing-box 二进制；自动切换到官方新版。'
            fi
            install_alpine_official_release
        fi
        update-ca-certificates 2>/dev/null || true
    elif [ -f /etc/debian_version ]; then
        OS_FAMILY=debian
        msg '检测到 Debian，安装 sing-box 官方仓库和依赖……'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq openssl iproute2 gpg procps kmod
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
        SB_BIN="$(command -v sing-box 2>/dev/null || true)"
    else
        err '仅支持 Debian 和 Alpine Linux。'
    fi

    [ -n "$SB_BIN" ] && [ -x "$SB_BIN" ] ||
        err 'sing-box 安装失败：没有找到可执行文件。请检查软件源或网络后重试。'
    "$SB_BIN" version | head -n 1 || true
    require_naive_version
}

require_naive_version() {
    version=$(sing_box_version_from "$SB_BIN" || true)
    [ -n "$version" ] || err '无法读取 sing-box 版本，无法确认 Naive 入站兼容性。'
    version_supports_naive "$version" ||
        err "当前 sing-box 版本 $version 过旧；NaiveProxy 入站需要 sing-box 1.13.0 或更新版本。"
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
    elif [ "$SERVICE_KIND" = openrc ]; then
        rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start || return 1
    else err '服务管理器尚未初始化。'; fi
    if [ "$ENABLE_WS_ARGO" = 1 ] && ! start_cloudflared_service; then
        warn 'sing-box 已重启，但 Cloudflare Tunnel 重启失败。'
        [ "${web_protocol_sync:-0}" = 0 ] || return 1
    fi
}

service_status() {
    if [ "$SERVICE_KIND" = systemd ]; then systemctl --no-pager --full status sing-box || true
    elif [ "$SERVICE_KIND" = openrc ]; then rc-service sing-box status || true; fi
    if [ "$ENABLE_WS_ARGO" = 1 ]; then cloudflared_status; fi
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
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || { warn "证书已过期：$domain。"; return 1; }
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
      --arg enable_ss2022 "$ENABLE_SS2022" \
      --arg ss2022_port "$SS2022_PORT" \
      --arg ss2022_password "$SS2022_PASSWORD" \
      --arg enable_ws_argo "$ENABLE_WS_ARGO" \
      --arg argo_port "$ARGO_PORT" \
      --arg argo_server "$ARGO_SERVER" \
      --arg argo_uuid "$ARGO_UUID" \
      --arg argo_path "$ARGO_PATH" \
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
      '{origin_addr:$origin_addr,origin_ipv6:$origin_ipv6,preferred_ip:$preferred_ip,preferred_ipv6:$preferred_ipv6,ws_server:$ws_server,enabled_ws_argo:($enable_ws_argo=="1"),enabled_ss2022:($enable_ss2022=="1"),ss2022_port:(if $enable_ss2022=="1" then ($ss2022_port|tonumber) else null end),ss2022_password:$ss2022_password,argo_port:(if $enable_ws_argo=="1" then ($argo_port|tonumber) else null end),argo_server:$argo_server,argo_uuid:$argo_uuid,argo_path:$argo_path,argo_host:$argo_host,argo_tunnel_name:$argo_tunnel_name,tls_domain:$tls_domain,ws_host:$ws_host,reality_sni:$reality_sni,enabled_anytls:($enable_anytls=="1"),enabled_ws_tls:($enable_ws_tls=="1"),enabled_vless_reality:($enable_vless_reality=="1"),enabled_naive:($enable_naive=="1"),enabled_anytls_reality:($enable_anytls_reality=="1"),anytls_port:(if $enable_anytls=="1" then ($anytls_port|tonumber) else null end),ws_port:(if $enable_ws_tls=="1" then ($ws_port|tonumber) else null end),reality_port:(if $enable_vless_reality=="1" then ($reality_port|tonumber) else null end),naive_port:(if $enable_naive=="1" then ($naive_port|tonumber) else null end),anyreality_port:(if $enable_anytls_reality=="1" then ($anyreality_port|tonumber) else null end),naive_username:$naive_username,naive_password:$naive_password,anyreality_password:$anyreality_password,anyreality_private:$anyreality_private,anyreality_public:$anyreality_public,anyreality_sid:$anyreality_sid,anytls_password:$anytls_password,ws_uuid:$ws_uuid,reality_uuid:$reality_uuid,reality_private:$reality_private,reality_public:$reality_public,reality_sid:$reality_sid,ws_path:$ws_path,cert_file:$cert_file,key_file:$key_file,cert_mode:$cert_mode,cf_zone_name:$cf_zone_name,node_label:$node_label}' > "$tmp"; then
        rm -f "$tmp"
        warn '无法生成 manager.json；原有管理状态未更改。'
        return 1
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
    ENABLE_SS2022=$(jq -r 'if .enabled_ss2022 == true then "1" else "0" end' "$STATE_FILE")
    SS2022_PORT=$(jq -r '.ss2022_port // ""' "$STATE_FILE")
    SS2022_PASSWORD=$(jq -r '.ss2022_password // ""' "$STATE_FILE")
    ENABLE_WS_ARGO=$(jq -r 'if .enabled_ws_argo == true then "1" else "0" end' "$STATE_FILE")
    ARGO_PORT=$(jq -r '.argo_port // ""' "$STATE_FILE")
    ARGO_SERVER=$(jq -r '.argo_server // ""' "$STATE_FILE")
    ARGO_UUID=$(jq -r '.argo_uuid // ""' "$STATE_FILE")
    ARGO_PATH=$(jq -r '.argo_path // ""' "$STATE_FILE")
    ARGO_HOST=$(jq -r '.argo_host // ""' "$STATE_FILE")
    ARGO_TUNNEL_NAME=$(jq -r '.argo_tunnel_name // ""' "$STATE_FILE")
    if [ -z "$WS_SERVER" ]; then
        if [ -n "$PREFERRED_IP" ]; then WS_SERVER=$PREFERRED_IP
        elif [ -n "$PREFERRED_IPV6" ]; then WS_SERVER=$PREFERRED_IPV6
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
    if [ "$ENABLE_WS_TLS" = 1 ] && jq -e 'has("enabled_ws_argo") | not' "$STATE_FILE" >/dev/null &&
        [ "$(jq -r '.ws_mode // "direct"' "$STATE_FILE")" = argo ]; then
        legacy_ws_server=$(jq -r '.ws_server // ""' "$STATE_FILE")
        migrate_legacy_argo
    fi
    [ "$ENABLE_WS_TLS" = 1 ] || { WS_SERVER=""; WS_HOST=""; }
    [ "$ENABLE_WS_ARGO" = 0 ] || ARGO_SERVER=${ARGO_SERVER:-$ARGO_HOST}
    [ -s "$ARGO_TOKEN_FILE" ] && ARGO_TOKEN=$(cat "$ARGO_TOKEN_FILE") || ARGO_TOKEN=""
}

migrate_legacy_argo() {
    ENABLE_WS_TLS=0
    ENABLE_WS_ARGO=1
    ARGO_SERVER=${legacy_ws_server:-${PREFERRED_IP:-${PREFERRED_IPV6:-$ARGO_HOST}}}
    ARGO_PORT=$WS_PORT
    ARGO_UUID=${WS_UUID:-}
    ARGO_PATH=${WS_PATH:-}
    WS_SERVER=""; WS_HOST=""; WS_PORT=""; WS_UUID=""; WS_PATH=""
    PREFERRED_IP=""; PREFERRED_IPV6=""
}

derive_runtime_needs() {
    NEED_CERT=0
    NEED_ORIGIN=0
    [ "$ENABLE_ANYTLS" = 1 ] && NEED_CERT=1 && NEED_ORIGIN=1
    [ "$ENABLE_NAIVE" = 1 ] && NEED_CERT=1 && NEED_ORIGIN=1
    [ "$ENABLE_VLESS_REALITY" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_ANYTLS_REALITY" = 1 ] && NEED_ORIGIN=1
    [ "$ENABLE_SS2022" = 1 ] && NEED_ORIGIN=1
    if [ "$ENABLE_WS_TLS" = 1 ]; then NEED_CERT=1; fi
}

build_config() {
    tmp="$CONFIG_FILE.tmp.$$"
    if ipv6_kernel_enabled; then listen_addr="::"; else listen_addr="0.0.0.0"; fi

    jq -n \
      --arg listen_addr "$listen_addr" \
      --arg ss2022_port "$SS2022_PORT" \
      --arg ss2022_method "$SS2022_METHOD" \
      --arg ss2022_password "$SS2022_PASSWORD" \
      --argjson enable_ss2022 "$([ "$ENABLE_SS2022" = 1 ] && printf true || printf false)" \
      --arg argo_port "$ARGO_PORT" \
      --arg argo_uuid "$ARGO_UUID" \
      --arg argo_path "$ARGO_PATH" \
      --argjson enable_ws_argo "$([ "$ENABLE_WS_ARGO" = 1 ] && printf true || printf false)" \
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
      --argjson enable_anytls "$([ "$ENABLE_ANYTLS" = 1 ] && printf true || printf false)" \
      --argjson enable_ws_tls "$([ "$ENABLE_WS_TLS" = 1 ] && printf true || printf false)" \
      --argjson enable_vless_reality "$([ "$ENABLE_VLESS_REALITY" = 1 ] && printf true || printf false)" \
      --argjson enable_naive "$([ "$ENABLE_NAIVE" = 1 ] && printf true || printf false)" \
      --argjson enable_anytls_reality "$([ "$ENABLE_ANYTLS_REALITY" = 1 ] && printf true || printf false)" \
      '{log:{level:"info",timestamp:true},inbounds:[
        (if $enable_anytls then {type:"anytls",tag:"anytls-in",listen:$listen_addr,listen_port:($anytls_port|tonumber),users:[{name:"primary",password:$anytls_password}],tls:{enabled:true,server_name:$tls_domain,certificate_path:$cert_file,key_path:$key_file}} else empty end),
        (if $enable_ws_tls then {type:"vless",tag:"vless-ws-tls-in",listen:$listen_addr,listen_port:($ws_port|tonumber),users:[{uuid:$ws_uuid}],tls:{enabled:true,server_name:$tls_domain,certificate_path:$cert_file,key_path:$key_file},transport:{type:"ws",path:$ws_path}} else empty end),
        (if $enable_ss2022 then {type:"shadowsocks",tag:"ss2022-in",listen:$listen_addr,listen_port:($ss2022_port|tonumber),method:$ss2022_method,password:$ss2022_password} else empty end),
        (if $enable_ws_argo then {type:"vless",tag:"vless-ws-argo-in",listen:"127.0.0.1",listen_port:($argo_port|tonumber),users:[{name:"primary",uuid:$argo_uuid}],transport:{type:"ws",path:$argo_path}} else empty end),
        (if $enable_vless_reality then {type:"vless",tag:"vless-reality-in",listen:$listen_addr,listen_port:($reality_port|tonumber),users:[{uuid:$reality_uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$reality_sni,reality:{enabled:true,handshake:{server:$reality_sni,server_port:443},private_key:$reality_private,short_id:[$reality_sid]}}} else empty end),
        (if $enable_naive then {type:"naive",tag:"naive-in",network:"tcp",listen:$listen_addr,listen_port:($naive_port|tonumber),users:[{username:$naive_username,password:$naive_password}],tls:{enabled:true,certificate_path:$cert_file,key_path:$key_file}} else empty end),
        (if $enable_anytls_reality then {type:"anytls",tag:"anytls-reality-in",listen:$listen_addr,listen_port:($anyreality_port|tonumber),users:[{name:"primary",password:$anyreality_password}],tls:{enabled:true,server_name:$reality_sni,reality:{enabled:true,handshake:{server:$reality_sni,server_port:443},private_key:$anyreality_private,short_id:[$anyreality_sid]}}} else empty end)
      ],outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp" || {
        rm -f "$tmp"
        warn '无法生成 sing-box 配置；原配置未更改。'
        return 1
    }
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
    case "$2" in
        *:*) family_lc=ipv6 ;;
        *[!0-9.]*) family_lc=domain ;;
        *) family_lc=ipv4 ;;
    esac
    node_tag "$family_lc" "$2" "$1"
}

change_node_label() {
    printf '\n当前节点辨识符：%s\n' "${NODE_LABEL:-（未设置）}"
    msg '该辨识符会添加到地址之后、协议名称之前；每条启用的 WS 线路各生成一个节点。'
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

# Build a standalone sing-box client configuration for NaiveProxy.
# This is deliberately separate from the server config.json and contains
# credentials, so it is written with owner-only permissions.
write_naive_client_json() {
    [ "$ENABLE_NAIVE" = 1 ] || { rm -f "$APP_DIR/naive-client.json"; return 0; }
    client_server=${ORIGIN_ADDR:-$ORIGIN_IPV6}
    [ -n "$client_server" ] || return 1
    client_json_tmp="$APP_DIR/naive-client.json.tmp.$$"
    if ! jq -n \
      --arg server "$client_server" \
      --arg server_port "$NAIVE_PORT" \
      --arg username "$NAIVE_USERNAME" \
      --arg password "$NAIVE_PASSWORD" \
      --arg server_name "$TLS_DOMAIN" \
      '{log:{level:"info",timestamp:true},inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}],outbounds:[{type:"naive",tag:"naive-proxy",server:$server,server_port:($server_port|tonumber),username:$username,password:$password,tls:{enabled:true,server_name:$server_name}},{type:"direct",tag:"direct"}],route:{final:"naive-proxy"}}' > "$client_json_tmp"; then
        rm -f "$client_json_tmp"
        return 1
    fi
    chmod 0600 "$client_json_tmp" || { rm -f "$client_json_tmp"; return 1; }
    chown root:root "$client_json_tmp" || { rm -f "$client_json_tmp"; return 1; }
    mv -f "$client_json_tmp" "$APP_DIR/naive-client.json"
}

show_ss2022_node() {
    ss_tag=$(node_tag "$1" "$2" ss2022)
    ss_tag_uri=$(jq -nr --arg value "$ss_tag" '$value | @uri')
    ss_key_uri=$(jq -nr --arg value "$SS2022_PASSWORD" '$value | @uri')
    printf '[%s] Shadowsocks 2022 | TCP/UDP：%s\nss://%s:%s@%s:%s#%s\n\n' \
        "$ss_tag" "$SS2022_PORT" "$SS2022_METHOD" "$ss_key_uri" "$(uri_host "$2")" "$SS2022_PORT" "$ss_tag_uri"
}

show_nodes() {
    WS_PATH_ENC=$(printf '%s' "$WS_PATH" | sed 's#/#%2F#g')
    nodes_tmp="$APP_DIR/nodes.txt.tmp.$$"
    {
        printf 'sing-box 节点信息（仅显示已安装协议）\n辨识符：%s\n\n' "${NODE_LABEL:-未设置}"

        if [ -n "$ORIGIN_ADDR" ]; then
            origin_uri=$(uri_host "$ORIGIN_ADDR")
            [ "$ENABLE_SS2022" = 0 ] || show_ss2022_node IPv4 "$ORIGIN_ADDR"
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

        if [ "$ENABLE_WS_TLS" = 1 ]; then
            ws_server_uri=$(uri_host "$WS_SERVER")
            tag=$(node_tag_single vless+ws+tls "$WS_SERVER"); tag_uri=$(jq -nr --arg tag "$tag" '$tag | @uri')
            WS_LINK="vless://${WS_UUID}@${ws_server_uri}:${WS_PORT}?encryption=none&security=tls&sni=${TLS_DOMAIN}&type=ws&host=${WS_HOST}&path=${WS_PATH_ENC}#${tag_uri}"
            printf '[%s] VLESS + WebSocket + TLS（直连） | 端口：%s\n%s\n\n' "$tag" "$WS_PORT" "$WS_LINK"
        fi
        if [ "$ENABLE_WS_ARGO" = 1 ]; then
            argo_server_uri=$(uri_host "$ARGO_SERVER")
            argo_path_enc=$(printf '%s' "$ARGO_PATH" | sed 's#/#%2F#g')
            tag=$(node_tag_single vless+ws+tls-argo "$ARGO_SERVER"); tag_uri=$(jq -nr --arg tag "$tag" '$tag | @uri')
            ARGO_LINK="vless://${ARGO_UUID}@${argo_server_uri}:443?encryption=none&security=tls&sni=${ARGO_HOST}&type=ws&host=${ARGO_HOST}&path=${argo_path_enc}#${tag_uri}"
            printf '[%s] VLESS + WebSocket + TLS（Argo） | 客户端端口：443 | 本机端口：%s\n%s\n\n' "$tag" "$ARGO_PORT" "$ARGO_LINK"
        fi

        if [ -n "$ORIGIN_IPV6" ]; then
            origin6_uri=$(uri_host "$ORIGIN_IPV6")
            [ "$ENABLE_SS2022" = 0 ] || show_ss2022_node IPv6 "$ORIGIN_IPV6"
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
        if [ "$ENABLE_WS_TLS" = 0 ] && [ "$ENABLE_WS_ARGO" = 0 ] && [ "$ENABLE_SS2022" = 0 ] && [ "$ENABLE_ANYTLS" = 0 ] && [ "$ENABLE_VLESS_REALITY" = 0 ] && [ "$ENABLE_NAIVE" = 0 ] && [ "$ENABLE_ANYTLS_REALITY" = 0 ]; then
            printf '没有启用任何协议。\n'
        fi
    } > "$nodes_tmp"
    chmod 0600 "$nodes_tmp"
    mv "$nodes_tmp" "$APP_DIR/nodes.txt"
    if [ "$ENABLE_ANYTLS_REALITY" = 1 ]; then
        if write_anyreality_client_json; then printf 'AnyTLS + Reality 客户端配置片段：%s/anytls-reality-client.json\n' "$APP_DIR"; else warn 'AnyTLS + Reality 客户端 JSON 片段生成失败。'; fi
    else rm -f "$APP_DIR/anytls-reality-client.json"; fi
    if [ "$ENABLE_NAIVE" = 1 ]; then
        if write_naive_client_json; then
            printf 'NaiveProxy sing-box 1.13+ 客户端配置：%s/naive-client.json\n' "$APP_DIR"
            printf '注意：该 JSON 含 Naive 用户名和密码，请仅通过安全方式传到自己的客户端。\n'
        else
            warn 'NaiveProxy 客户端 JSON 生成失败；节点链接仍可用，请检查地址和凭据。'
        fi
    else
        rm -f "$APP_DIR/naive-client.json"
    fi
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

    selected_count=$((ENABLE_ANYTLS + ENABLE_WS_TLS + ENABLE_WS_ARGO + ENABLE_VLESS_REALITY + ENABLE_NAIVE + ENABLE_ANYTLS_REALITY + ENABLE_SS2022))
    [ "$selected_count" -gt 0 ] || err '当前没有启用的协议。'
    derive_runtime_needs
    if [ "$NEED_CERT" = 1 ]; then
        [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ] || err '现有 TLS 证书缺失；覆盖升级不会自动重新申请证书。'
        check_cert_pair "$CERT_FILE" "$KEY_FILE" "$TLS_DOMAIN" || err '现有 TLS 证书或私钥无效。'
        if [ "$CERT_MODE" = cloudflare ]; then
            [ -s "$CF_TOKEN_FILE" ] || err 'Cloudflare DNS API Token 文件缺失，停止覆盖升级。'
        fi
        setup_reload_hook
    fi
    if [ "$ENABLE_WS_ARGO" = 1 ]; then
        [ -s "$ARGO_TOKEN_FILE" ] || err 'Cloudflare Tunnel Token 文件缺失，停止覆盖升级。'
    fi

    install_dependencies_and_core
    ensure_service_account
    enable_bbr
    create_service
    if [ "$ENABLE_WS_ARGO" = 1 ]; then
        install_cloudflared
        create_cloudflared_service
    fi
    build_config || err '覆盖安装未能应用当前所选协议配置。'
    save_state || err '覆盖安装成功但管理状态保存失败。'
    if [ "$ENABLE_WS_ARGO" = 1 ]; then
        start_cloudflared_service || warn 'Cloudflare Tunnel 服务启动失败，请检查 Token 和 cloudflared 日志。'
        msg "Cloudflare Tunnel 公网主机名：$ARGO_HOST → http://127.0.0.1:$ARGO_PORT"
    fi
    msg '覆盖升级完成：保留原有已选协议、UUID、密码、密钥、端口和节点路径。'
    show_nodes
}

add_pick_port() {
    add_requested=$1
    add_protocol=$2
    add_port_mode=$3
    add_reserved=$4

    set -- $add_reserved
    if [ -n "$add_requested" ]; then
        add_requested=$(normalize_optional_port "$add_requested" "$add_protocol") ||
            err "$add_protocol 端口必须是 1024–65535 的整数。"
        if ! check_udp_port="$([ "$add_port_mode" = ss2022 ] && printf 1 || printf 0)" port_is_available "$add_requested" "$@"; then
            err "$add_protocol 端口 $add_requested 已被现有节点或其他进程占用；为避免修改旧节点，请选择其他端口。"
        fi
        printf '%s\n' "$add_requested"
        return 0
    fi

    if [ "$add_port_mode" = ws-direct ]; then
        pick_random_ws_port "$@" || err '没有可用的 VLESS + WS 直连端口（2053、2083、2087、2096、8443）。'
    elif [ "$add_port_mode" = ss2022 ]; then
        check_udp_port=1 pick_random_range_port 10000 65535 "$@" || err '无法分配新的 Shadowsocks 2022 TCP/UDP 端口。'
    else
        pick_random_range_port 10000 65535 "$@" || err "无法为 $add_protocol 分配新的空闲 TCP 端口。"
    fi
}

write_cf_credentials_for_add() {
    add_cf_value=$1
    add_zone_value=$2

    if [ -n "$add_cf_value" ]; then
        add_cf_tmp="${CF_TOKEN_FILE}.tmp.$$"
        (umask 077; printf '%s' "$add_cf_value" > "$add_cf_tmp") || {
            rm -f "$add_cf_tmp"
            return 1
        }
        chown root:root "$add_cf_tmp" && chmod 0600 "$add_cf_tmp" &&
            mv -f "$add_cf_tmp" "$CF_TOKEN_FILE" || {
                rm -f "$add_cf_tmp"
                return 1
            }
    fi

    if [ -n "$add_zone_value" ]; then
        add_zone_tmp="${CF_ZONE_ID_FILE}.tmp.$$"
        (umask 077; printf '%s' "$add_zone_value" > "$add_zone_tmp") || {
            rm -f "$add_zone_tmp"
            return 1
        }
        chown root:root "$add_zone_tmp" && chmod 0600 "$add_zone_tmp" &&
            mv -f "$add_zone_tmp" "$CF_ZONE_ID_FILE" || {
                rm -f "$add_zone_tmp"
                return 1
            }
    else
        rm -f "$CF_ZONE_ID_FILE"
    fi
}

prepare_add_certificate() {
    CERT_FILE=${CERT_FILE:-$CERT_DIR/fullchain.pem}
    KEY_FILE=${KEY_FILE:-$CERT_DIR/privkey.pem}
    add_cert_valid=0

    if [ -n "$TLS_DOMAIN" ] &&
       check_cert_pair "$CERT_FILE" "$KEY_FILE" "$TLS_DOMAIN" >/dev/null 2>&1; then
        add_cert_valid=1
    fi

    if [ "$add_cert_valid" -eq 1 ] && { [ "$CERT_MODE" = none ] || [ -z "$CERT_MODE" ]; }; then
        CERT_MODE=manual
    fi

    if [ "$add_cert_valid" -eq 0 ]; then
        if [ "$add_old_need_cert" -eq 0 ]; then
            msg '当前安装没有可复用的有效源站 TLS 证书，需要为新节点配置证书。'
            ask_value '证书方式：1=Cloudflare DNS-01，2=HTTP-01，3=手动导入' '1'
            case "$REPLY" in
                1) CERT_MODE=cloudflare ;;
                2) CERT_MODE=standalone ;;
                3) CERT_MODE=manual ;;
                *) err '证书方式只能选择 1、2 或 3。' ;;
            esac
            if [ "$CERT_MODE" = cloudflare ]; then
                ask_value 'Cloudflare DNS 区域根域名（例如 mouwei.dpdns.org）' "$CF_ZONE_NAME"
                CF_ZONE_NAME=$(trim_value "$REPLY")
            else
                CF_ZONE_NAME=""
            fi
            ask_value 'TLS 证书域名（例如 hinet.mouwei.dpdns.org）' "$TLS_DOMAIN"
            TLS_DOMAIN=$(trim_value "$REPLY")
        else
            valid_cert_domain "$TLS_DOMAIN" ||
                err '现有 TLS 节点的证书域名无效；为保护现有节点，不允许在增量添加时擅自更换域名。'
            if [ "$CERT_MODE" = none ] || [ -z "$CERT_MODE" ]; then
                msg '现有 TLS 节点没有记录证书签发方式。'
                ask_value '请选择证书方式：1=Cloudflare DNS-01，2=HTTP-01，3=手动导入' '1'
                case "$REPLY" in
                    1) CERT_MODE=cloudflare ;;
                    2) CERT_MODE=standalone ;;
                    3) CERT_MODE=manual ;;
                    *) err '证书方式只能选择 1、2 或 3。' ;;
                esac
            fi
            if [ "$CERT_MODE" = cloudflare ] && [ -z "$CF_ZONE_NAME" ]; then
                ask_value 'Cloudflare DNS 区域根域名' ''
                CF_ZONE_NAME=$(trim_value "$REPLY")
            fi
        fi
    fi

    valid_cert_domain "$TLS_DOMAIN" || err 'TLS 证书域名无效；请输入你拥有或获准管理的域名。'

    case "$CERT_MODE" in
        cloudflare)
            if [ -z "$CF_ZONE_NAME" ]; then
                ask_value 'Cloudflare DNS 区域根域名' ''
                CF_ZONE_NAME=$(trim_value "$REPLY")
            fi
            valid_cert_domain "$CF_ZONE_NAME" || err 'Cloudflare 区域根域名格式无效。'
            domain_belongs_to_zone "$TLS_DOMAIN" "$CF_ZONE_NAME" ||
                err "TLS 证书域名 $TLS_DOMAIN 不属于 Cloudflare 区域 $CF_ZONE_NAME。"

            add_cf_existing=""
            [ ! -s "$CF_TOKEN_FILE" ] || add_cf_existing=$(cat "$CF_TOKEN_FILE")
            ask_secret 'Cloudflare DNS API Token（直接回车保留现有；不是 Tunnel Token）'
            add_cf_new=$(trim_value "$REPLY")
            if [ -z "$add_cf_new" ] && [ -z "$add_cf_existing" ]; then
                err 'Cloudflare DNS API Token 不能为空。'
            fi

            add_zone_existing=$(cat "$CF_ZONE_ID_FILE" 2>/dev/null || true)
            ask_value 'Cloudflare Zone ID（可留空自动识别）' "$add_zone_existing"
            add_zone_new=$(trim_value "$REPLY")
            if [ -n "$add_zone_new" ]; then
                case "$add_zone_new" in *[!A-Fa-f0-9]*) err 'Cloudflare Zone ID 必须是 32 位十六进制字符串。' ;; esac
                [ "${#add_zone_new}" -eq 32 ] || err 'Cloudflare Zone ID 必须是 32 位十六进制字符串。'
            fi

            setup_reload_hook
            install_acme ""

            add_cf_backup_dir=""
            add_cf_token_had_old=0
            add_cf_zone_had_old=0
            if [ -n "$add_cf_new" ] || [ "$add_zone_new" != "$add_zone_existing" ]; then
                add_cf_backup_dir=$(mktemp -d) || err '无法创建 Cloudflare 凭据备份目录。'
                if [ -s "$CF_TOKEN_FILE" ]; then
                    cp -p "$CF_TOKEN_FILE" "$add_cf_backup_dir/cloudflare.token" ||
                        { rm -rf "$add_cf_backup_dir"; err '无法备份原 DNS API Token；没有修改凭据。'; }
                    add_cf_token_had_old=1
                fi
                if [ -s "$CF_ZONE_ID_FILE" ]; then
                    cp -p "$CF_ZONE_ID_FILE" "$add_cf_backup_dir/cloudflare-zone-id" ||
                        { rm -rf "$add_cf_backup_dir"; err '无法备份原 Zone ID；没有修改凭据。'; }
                    add_cf_zone_had_old=1
                fi
                if ! write_cf_credentials_for_add "$add_cf_new" "$add_zone_new"; then
                    if [ "$add_cf_token_had_old" -eq 1 ]; then cp -p "$add_cf_backup_dir/cloudflare.token" "$CF_TOKEN_FILE"; else rm -f "$CF_TOKEN_FILE"; fi
                    if [ "$add_cf_zone_had_old" -eq 1 ]; then cp -p "$add_cf_backup_dir/cloudflare-zone-id" "$CF_ZONE_ID_FILE"; else rm -f "$CF_ZONE_ID_FILE"; fi
                    rm -rf "$add_cf_backup_dir"
                    err '无法安全保存 Cloudflare DNS API 凭据；已恢复原凭据。'
                fi
            fi

            add_cf_current=$(cat "$CF_TOKEN_FILE" 2>/dev/null || true)
            add_zone_current=$(cat "$CF_ZONE_ID_FILE" 2>/dev/null || true)
            if [ "$add_cert_valid" -eq 0 ] ||
               [ -n "$add_cf_new" ] ||
               [ "$add_zone_new" != "$add_zone_existing" ] ||
               ! acme_cf_credentials_match "$TLS_DOMAIN" "$add_cf_current" "$add_zone_current"; then
                add_cert_backup_dir=$(mktemp -d) || err '无法创建证书备份目录。'
                [ ! -s "$CERT_FILE" ] || cp -p "$CERT_FILE" "$add_cert_backup_dir/fullchain.pem" ||
                    { rm -rf "$add_cert_backup_dir"; err '无法备份现有证书；停止 DNS-01 更新。'; }
                [ ! -s "$KEY_FILE" ] || cp -p "$KEY_FILE" "$add_cert_backup_dir/privkey.pem" ||
                    { rm -rf "$add_cert_backup_dir"; err '无法备份现有私钥；停止 DNS-01 更新。'; }
                if ! issue_cloudflare_cert "$TLS_DOMAIN"; then
                    if [ -s "$add_cert_backup_dir/fullchain.pem" ]; then cp -p "$add_cert_backup_dir/fullchain.pem" "$CERT_FILE"; fi
                    if [ -s "$add_cert_backup_dir/privkey.pem" ]; then cp -p "$add_cert_backup_dir/privkey.pem" "$KEY_FILE"; fi
                    chown root:sing-box "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
                    chmod 0644 "$CERT_FILE" 2>/dev/null || true
                    chmod 0640 "$KEY_FILE" 2>/dev/null || true
                    if [ -n "$add_cf_backup_dir" ]; then
                        if [ "$add_cf_token_had_old" -eq 1 ]; then cp -p "$add_cf_backup_dir/cloudflare.token" "$CF_TOKEN_FILE"; else rm -f "$CF_TOKEN_FILE"; fi
                        if [ "$add_cf_zone_had_old" -eq 1 ]; then cp -p "$add_cf_backup_dir/cloudflare-zone-id" "$CF_ZONE_ID_FILE"; else rm -f "$CF_ZONE_ID_FILE"; fi
                        rm -rf "$add_cf_backup_dir"
                    fi
                    rm -rf "$add_cert_backup_dir"
                    err 'Cloudflare DNS-01 证书处理失败。请检查 DNS API Token 的 Zone:DNS:Edit 权限、Zone ID、DNS 托管状态及 ACME 日志。'
                fi
                rm -rf "$add_cert_backup_dir"
            fi
            [ -z "$add_cf_backup_dir" ] || rm -rf "$add_cf_backup_dir"
            ;;
        standalone)
            if [ "$add_cert_valid" -eq 0 ]; then
                setup_reload_hook
                issue_http_cert "$TLS_DOMAIN" ||
                    err 'HTTP-01 证书申请失败；请确认域名解析到 VPS 且公网 TCP 80 可访问。'
            fi
            ;;
        manual)
            if [ "$add_cert_valid" -eq 0 ]; then
                setup_reload_hook
                install_manual_cert "$TLS_DOMAIN"
            fi
            ;;
        *)
            err '当前证书签发方式无效，请重新选择 Cloudflare DNS-01、HTTP-01 或手动导入。'
            ;;
    esac

    check_cert_pair "$CERT_FILE" "$KEY_FILE" "$TLS_DOMAIN" ||
        err '新节点使用的 TLS 证书校验失败；没有继续修改 sing-box 配置。'
}

add_missing_protocols() {
    need_root
    [ -s "$STATE_FILE" ] || err '找不到现有 manager.json；请先完成首次安装。'
    manager_state_is_valid || err '现有 manager.json 无效；为避免覆盖或丢失节点凭据，停止增量添加。'

    load_state
    derive_runtime_needs

    add_old_anytls=$ENABLE_ANYTLS
    add_old_ws=$ENABLE_WS_TLS
    add_old_reality=$ENABLE_VLESS_REALITY
    add_old_naive=$ENABLE_NAIVE
    add_old_anyreality=$ENABLE_ANYTLS_REALITY
    add_old_need_cert=$NEED_CERT
    add_old_need_origin=$NEED_ORIGIN
    add_old_anytls_port=$ANYTLS_PORT
    add_old_ws_port=$WS_PORT
    add_old_reality_port=$REALITY_PORT
    add_old_naive_port=$NAIVE_PORT
    add_old_anyreality_port=$ANYREALITY_PORT

    add_anytls=0
    add_argo=0
    add_ss2022=0
    add_ws=0
    add_reality=0
    add_naive=0
    add_anyreality=0

    msg '========== 增量添加 sing-box 节点 =========='
    msg '只会添加尚未部署的协议；现有节点的密码、UUID、密钥、端口和 WS 路径不会重新生成。'
    printf '当前状态：AnyTLS=%s，直连 WS=%s，VLESS Reality=%s，NaiveProxy=%s，AnyTLS Reality=%s\n' \
        "$([ "$ENABLE_ANYTLS" = 1 ] && printf 已安装 || printf 未安装)" \
        "$([ "$ENABLE_WS_TLS" = 1 ] && printf 已安装 || printf 未安装)" \
        "$([ "$ENABLE_VLESS_REALITY" = 1 ] && printf 已安装 || printf 未安装)" \
        "$([ "$ENABLE_NAIVE" = 1 ] && printf 已安装 || printf 未安装)" \
        "$([ "$ENABLE_ANYTLS_REALITY" = 1 ] && printf 已安装 || printf 未安装)"

    printf 'Argo WS：%s；Shadowsocks 2022：%s\n' \
        "$([ "$ENABLE_WS_ARGO" = 1 ] && printf 已安装 || printf 未安装)" \
        "$([ "$ENABLE_SS2022" = 1 ] && printf 已安装 || printf 未安装)"

    if [ "$ENABLE_ANYTLS" = 0 ]; then
        ask_value '添加普通 AnyTLS？(y/N)' 'n'
        case "$REPLY" in y|Y|yes|YES) add_anytls=1; ENABLE_ANYTLS=1 ;; esac
    fi
    if [ "$ENABLE_SS2022" = 0 ]; then
        ask_value '添加 Shadowsocks 2022？(y/N)' 'n'
        case "$REPLY" in y|Y|yes|YES) add_ss2022=1; ENABLE_SS2022=1 ;; esac
    fi
    if [ "$ENABLE_WS_ARGO" = 0 ]; then
        ask_value '添加 VLESS + WS + TLS Argo？(y/N)' 'n'
        case "$REPLY" in y|Y|yes|YES) add_argo=1; ENABLE_WS_ARGO=1 ;; esac
    fi
    if [ "$ENABLE_WS_TLS" = 0 ]; then
        ask_value '添加 VLESS + WS + TLS 直连？(y/N)' 'n'
        case "$REPLY" in y|Y|yes|YES) add_ws=1; ENABLE_WS_TLS=1 ;; esac
    fi
    if [ "$ENABLE_VLESS_REALITY" = 0 ]; then
        ask_value '添加 VLESS + Reality？(y/N)' 'n'
        case "$REPLY" in y|Y|yes|YES) add_reality=1; ENABLE_VLESS_REALITY=1 ;; esac
    fi
    if [ "$ENABLE_NAIVE" = 0 ]; then
        ask_value '添加 NaiveProxy？(y/N)' 'n'
        case "$REPLY" in y|Y|yes|YES) add_naive=1; ENABLE_NAIVE=1 ;; esac
    fi
    if [ "$ENABLE_ANYTLS_REALITY" = 0 ]; then
        ask_value '添加 AnyTLS + Reality？(y/N)' 'n'
        case "$REPLY" in y|Y|yes|YES) add_anyreality=1; ENABLE_ANYTLS_REALITY=1 ;; esac
    fi

    add_selected=$((add_anytls + add_ws + add_argo + add_reality + add_naive + add_anyreality + add_ss2022))
    if [ "$add_selected" -eq 0 ]; then
        msg '没有选择新增协议，现有配置保持不变。'
        return 0
    fi

    [ "$add_argo" -eq 0 ] || ask_argo_install_fields
    if [ "$add_ws" -eq 1 ]; then
        ask_value '直连客户端连接地址 / 优选 IP（留空使用证书域名）' ''
        WS_SERVER=$(trim_value "$REPLY")
    fi

    derive_runtime_needs

    if [ "$add_reality" -eq 1 ] || [ "$add_anyreality" -eq 1 ]; then
        if [ "$add_old_reality" = 0 ] && [ "$add_old_anyreality" = 0 ]; then
            ask_value 'Reality SNI / 握手目标域名' "${REALITY_SNI:-www.bing.com}"
            REALITY_SNI=$(trim_value "$REPLY")
        fi
        valid_domain "$REALITY_SNI" || err 'Reality SNI 必须是有效域名。'
    fi

    if [ "$NEED_ORIGIN" = 1 ] && [ "$add_old_need_origin" -eq 0 ]; then
        msg '新节点需要源站公网地址。留空时脚本会尝试通过 IPv4 / IPv6 外部检测服务自动识别。'
        ask_value '源站 IPv4 / 域名（留空自动检测）' "$ORIGIN_ADDR"
        ORIGIN_ADDR=$(trim_value "$REPLY")
        ask_value '源站 IPv6（留空自动检测）' "$ORIGIN_IPV6"
        ORIGIN_IPV6=$(trim_value "$REPLY")
    fi

    install_dependencies_and_core
    ensure_service_account
    enable_bbr
    SB_BIN=$(resolve_sing_box_binary 2>/dev/null || printf '%s' "$SB_BIN")
    [ -x "$SB_BIN" ] || err '找不到可执行的 sing-box。'

    if [ "$NEED_CERT" = 1 ]; then
        prepare_add_certificate
        resolve_install_domains
        setup_reload_hook
    else
        resolve_install_domains
    fi

    if [ "$add_ws" -eq 1 ]; then
        ask_value 'VLESS + WS HTTP Host（默认使用 TLS 证书域名）' "$TLS_DOMAIN"
        WS_HOST=$(trim_value "$REPLY")
        valid_domain "$WS_HOST" || err 'VLESS + WS HTTP Host 格式无效。'
        [ -n "$WS_SERVER" ] || WS_SERVER=$TLS_DOMAIN
    fi

    resolve_install_addresses

    add_reserved_ports="$ARGO_PORT $SS2022_PORT"
    [ "$add_old_anytls" = 0 ] || add_reserved_ports="$add_reserved_ports $add_old_anytls_port"
    [ "$add_old_ws" = 0 ] || add_reserved_ports="$add_reserved_ports $add_old_ws_port"
    [ "$add_old_reality" = 0 ] || add_reserved_ports="$add_reserved_ports $add_old_reality_port"
    [ "$add_old_naive" = 0 ] || add_reserved_ports="$add_reserved_ports $add_old_naive_port"
    [ "$add_old_anyreality" = 0 ] || add_reserved_ports="$add_reserved_ports $add_old_anyreality_port"

    if [ "$add_anytls" -eq 1 ]; then
        ask_value '新增 AnyTLS TCP 端口（留空自动分配）' ''
        ANYTLS_PORT=$(add_pick_port "$(trim_value "$REPLY")" 'AnyTLS' tcp "$add_reserved_ports")
        add_reserved_ports="$add_reserved_ports $ANYTLS_PORT"
    fi
    if [ "$add_ws" -eq 1 ]; then
        ask_value '新增 VLESS + WS 直连 TCP 端口（留空自动分配）' ''
        WS_PORT=$(add_pick_port "$(trim_value "$REPLY")" 'VLESS + WS 直连' ws-direct "$add_reserved_ports")
        add_reserved_ports="$add_reserved_ports $WS_PORT"
    fi
    if [ "$add_argo" -eq 1 ]; then
        ask_value '新增 Argo 本机 WS 端口（留空自动分配）' ''
        ARGO_PORT=$(add_pick_port "$(trim_value "$REPLY")" 'VLESS + WS Argo' argo "$add_reserved_ports")
        add_reserved_ports="$add_reserved_ports $ARGO_PORT"
    fi
    if [ "$add_reality" -eq 1 ]; then
        ask_value '新增 VLESS Reality TCP 端口（留空自动分配）' ''
        REALITY_PORT=$(add_pick_port "$(trim_value "$REPLY")" 'VLESS Reality' tcp "$add_reserved_ports")
        add_reserved_ports="$add_reserved_ports $REALITY_PORT"
    fi
    if [ "$add_naive" -eq 1 ]; then
        ask_value '新增 NaiveProxy TCP 端口（留空自动分配）' ''
        NAIVE_PORT=$(add_pick_port "$(trim_value "$REPLY")" 'NaiveProxy' tcp "$add_reserved_ports")
        add_reserved_ports="$add_reserved_ports $NAIVE_PORT"
    fi
    if [ "$add_anyreality" -eq 1 ]; then
        ask_value '新增 AnyTLS + Reality TCP 端口（留空自动分配）' ''
        ANYREALITY_PORT=$(add_pick_port "$(trim_value "$REPLY")" 'AnyTLS + Reality' tcp "$add_reserved_ports")
        add_reserved_ports="$add_reserved_ports $ANYREALITY_PORT"
    fi

    if [ "$add_ss2022" -eq 1 ]; then
        ask_value '新增 Shadowsocks 2022 TCP/UDP 端口（留空自动分配）' ''
        SS2022_PORT=$(add_pick_port "$(trim_value "$REPLY")" 'Shadowsocks 2022' ss2022 "$add_reserved_ports")
        SS2022_PASSWORD=$(openssl rand -base64 16)
    fi
    if [ "$add_anytls" -eq 1 ]; then
        ANYTLS_PASSWORD=$(openssl rand -hex 24)
    fi
    if [ "$add_argo" -eq 1 ]; then
        ARGO_UUID=$("$SB_BIN" generate uuid)
        ARGO_PATH="/ws-$(openssl rand -hex 8)"
    fi
    if [ "$add_ws" -eq 1 ]; then
        WS_UUID=$("$SB_BIN" generate uuid)
        WS_PATH="/ws-$(openssl rand -hex 8)"
    fi
    if [ "$add_reality" -eq 1 ]; then
        REALITY_UUID=$("$SB_BIN" generate uuid)
        add_reality_keypair=$("$SB_BIN" generate reality-keypair)
        REALITY_PRIVATE=$(printf '%s\n' "$add_reality_keypair" | awk '/PrivateKey/ {print $2}')
        REALITY_PUBLIC=$(printf '%s\n' "$add_reality_keypair" | awk '/PublicKey/ {print $2}')
        REALITY_SID=$("$SB_BIN" generate rand --hex 8)
        [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] && [ -n "$REALITY_SID" ] ||
            err 'VLESS Reality 密钥生成失败。'
    fi
    if [ "$add_naive" -eq 1 ]; then
        NAIVE_USERNAME="naive-$(openssl rand -hex 6)"
        NAIVE_PASSWORD=$(openssl rand -hex 24)
    fi
    if [ "$add_anyreality" -eq 1 ]; then
        ANYREALITY_PASSWORD=$(openssl rand -hex 24)
        add_anyreality_keypair=$("$SB_BIN" generate reality-keypair)
        ANYREALITY_PRIVATE=$(printf '%s\n' "$add_anyreality_keypair" | awk '/PrivateKey/ {print $2}')
        ANYREALITY_PUBLIC=$(printf '%s\n' "$add_anyreality_keypair" | awk '/PublicKey/ {print $2}')
        ANYREALITY_SID=$("$SB_BIN" generate rand --hex 8)
        [ -n "$ANYREALITY_PRIVATE" ] && [ -n "$ANYREALITY_PUBLIC" ] && [ -n "$ANYREALITY_SID" ] ||
            err 'AnyTLS + Reality 密钥生成失败。'
    fi

    add_argo_token_backup=""
    add_argo_token_had_old=0
    if [ "$add_argo" -eq 1 ]; then
        install_cloudflared
        if [ -s "$ARGO_TOKEN_FILE" ]; then
            add_argo_token_backup="${ARGO_TOKEN_FILE}.add-backup.$$"
            cp -p "$ARGO_TOKEN_FILE" "$add_argo_token_backup" ||
                err '无法备份现有 Tunnel Token；为避免丢失凭据，停止添加。'
            add_argo_token_had_old=1
        fi
        write_argo_token_file "$ARGO_TOKEN" || err '无法安全保存 Cloudflare Tunnel Token。'
    fi

    create_service
    if ! build_config; then
        if [ "$add_argo" -eq 1 ]; then
            if [ "$add_argo_token_had_old" -eq 1 ]; then
                cp -p "$add_argo_token_backup" "$ARGO_TOKEN_FILE"
                chown root:sing-box "$ARGO_TOKEN_FILE" 2>/dev/null || true
                chmod 0640 "$ARGO_TOKEN_FILE" 2>/dev/null || true
            else
                rm -f "$ARGO_TOKEN_FILE"
            fi
            rm -f "$add_argo_token_backup"
        fi
        load_state
        derive_runtime_needs
        warn '新增协议未能通过配置检查或启动检查；原有 manager.json 和 sing-box 配置已回滚。'
        return 0
    fi

    if [ "$add_argo" -eq 1 ]; then
        rm -f "$add_argo_token_backup"
        create_cloudflared_service
        if start_cloudflared_service; then
            msg '新增的 Cloudflare Tunnel 服务已启动。'
        else
            warn 'Argo WS 配置已写入，但 cloudflared 未能启动；请检查 Tunnel Token、出站网络及日志。'
        fi
        msg "请在 Cloudflare Zero Trust 添加/确认 Public Hostname：$ARGO_HOST → http://127.0.0.1:$ARGO_PORT"
    fi

    msg '增量添加完成。旧节点参数保持不变；以下为当前全部已安装节点：'
    show_nodes
    msg '新增协议需要在防火墙 / NAT 服务商开放或映射的 TCP 端口：'
    [ "$add_anytls" -eq 0 ] || printf '  AnyTLS：%s/tcp\n' "$ANYTLS_PORT"
    [ "$add_reality" -eq 0 ] || printf '  VLESS Reality：%s/tcp\n' "$REALITY_PORT"
    [ "$add_naive" -eq 0 ] || printf '  NaiveProxy：%s/tcp\n' "$NAIVE_PORT"
    [ "$add_anyreality" -eq 0 ] || printf '  AnyTLS + Reality：%s/tcp\n' "$ANYREALITY_PORT"
    [ "$add_ss2022" -eq 0 ] || printf '  Shadowsocks 2022：%s/tcp + udp\n' "$SS2022_PORT"
    [ "$add_ws" -eq 0 ] || printf '  VLESS + WS 直连：%s/tcp\n' "$WS_PORT"
    [ "$add_argo" -eq 0 ] || msg 'VLESS + WS Argo 客户端公网端口为 443；本机 WS 端口不需要 NAT 入站映射。'
}

ask_argo_install_fields() {
    ask_value 'Cloudflare Tunnel Public Hostname（例如 tunnel.example.com）' ''
    ARGO_HOST=$(trim_value "$REPLY")
    ask_value 'Tunnel 备注名（可选）' ''
    ARGO_TUNNEL_NAME=$(trim_value "$REPLY")
    ask_secret 'Cloudflare Tunnel Token（粘贴完整 eyJ... Token；不是 DNS API Token）'
    ARGO_TOKEN=$(trim_value "$REPLY")
    valid_argo_token "$ARGO_TOKEN" || err 'Cloudflare Tunnel Token 格式无效。'
    ask_value 'Argo 客户端连接地址 / 优选 IP（留空使用 Public Hostname）' "$ARGO_HOST"
    ARGO_SERVER=$(trim_value "$REPLY")
}

install_wizard() {
    need_root
    ORIGIN_ADDR=""; ORIGIN_IPV6=""; WS_SERVER=""; WS_HOST=""
    ENABLE_ANYTLS=0; ENABLE_WS_TLS=0; ENABLE_WS_ARGO=0; ENABLE_SS2022=0; ENABLE_VLESS_REALITY=0; ENABLE_NAIVE=0; ENABLE_ANYTLS_REALITY=0
    msg '========== sing-box 选择性安装向导 =========='
    ask_value '安装普通 AnyTLS？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_ANYTLS=1 ;; esac
    ask_value '安装 VLESS + WS + TLS 直连？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_WS_TLS=1 ;; esac
    ask_value '安装 VLESS + WS + TLS Argo？(Y/n)' 'y'; case "$REPLY" in y|Y|yes|YES) ENABLE_WS_ARGO=1 ;; esac
    ask_value '安装 VLESS + Reality？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_VLESS_REALITY=1 ;; esac
    ask_value '安装 NaiveProxy？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_NAIVE=1 ;; esac
    ask_value '安装 Shadowsocks 2022？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_SS2022=1 ;; esac
    ask_value '安装 AnyTLS + Reality？(y/N)' 'n'; case "$REPLY" in y|Y|yes|YES) ENABLE_ANYTLS_REALITY=1 ;; esac
    selected_count=$((ENABLE_ANYTLS + ENABLE_WS_TLS + ENABLE_WS_ARGO + ENABLE_VLESS_REALITY + ENABLE_NAIVE + ENABLE_ANYTLS_REALITY + ENABLE_SS2022))
    [ "$selected_count" -gt 0 ] || err '至少选择一种协议。'

    ARGO_HOST=""; ARGO_TUNNEL_NAME=""; ARGO_TOKEN=""; ARGO_SERVER=""
    [ "$ENABLE_WS_ARGO" = 0 ] || ask_argo_install_fields

    derive_runtime_needs
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

    if [ "$ENABLE_WS_TLS" = 1 ]; then
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
                valid_cert_domain "$TLS_DOMAIN" || err '请输入有效的 TLS 证书域名。'
                domain_belongs_to_zone "$TLS_DOMAIN" "$CF_ZONE_NAME" || err "TLS 证书域名 $TLS_DOMAIN 必须属于 Cloudflare 区域 $CF_ZONE_NAME。"
                ;;
            standalone|manual) valid_cert_domain "$TLS_DOMAIN" || err '请输入有效的 TLS 证书域名。' ;;
            *) err '所选协议需要 TLS 证书，但证书方式无效。' ;;
        esac
    else
        TLS_DOMAIN=""
        WS_HOST=""
    fi

    if [ "$ENABLE_WS_ARGO" = 1 ]; then
        valid_cert_domain "$ARGO_HOST" || err '请输入有效且已接入 Cloudflare 的 Argo 公网主机名。'
        ARGO_SERVER=${ARGO_SERVER:-$ARGO_HOST}
        ARGO_TUNNEL_NAME=$(normalize_tunnel_name "$ARGO_TUNNEL_NAME")
    else ARGO_SERVER=""; fi
    if [ "$ENABLE_WS_TLS" = 1 ]; then
        WS_SERVER=${WS_SERVER:-$TLS_DOMAIN}
        WS_HOST=${WS_HOST:-$TLS_DOMAIN}
        valid_domain "$WS_HOST" || err 'WS HTTP Host 必须是有效域名。'
        if [ "$ENABLE_WS_ARGO" = 1 ] && [ "$(printf '%s' "$ARGO_HOST" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$WS_HOST" | tr '[:upper:]' '[:lower:]')" ]; then
            warn '两条线路使用相同的 WS Host；若均通过 DNS 访问，请为直连和 Argo 分别配置不同的主机名。'
        fi
    else
        WS_SERVER=""; WS_HOST=""
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
    if [ "$ENABLE_WS_ARGO" = 1 ]; then
        case "$ARGO_SERVER" in
            *:*) valid_ipv6_literal "$ARGO_SERVER" || err 'Argo 客户端 IPv6 地址格式不正确。' ;;
            *) valid_main_address "$ARGO_SERVER" || err 'Argo 客户端连接地址应为 IPv4、IPv6 或域名。' ;;
        esac
    fi
    msg "源站地址：IPv4=${ORIGIN_ADDR:-不需要/未检测到}，IPv6=${ORIGIN_IPV6:-未设置}"
}

generate_install_credentials() {
    if [ "$ENABLE_ANYTLS" = 0 ]; then ANYTLS_PASSWORD=""
    elif [ -z "${PREVIOUS_ANYTLS_PORT:-}" ]; then ANYTLS_PASSWORD=$(openssl rand -hex 24); fi
    if [ "$ENABLE_SS2022" = 0 ]; then SS2022_PASSWORD=""
    elif [ -z "${PREVIOUS_SS2022_PORT:-}" ]; then SS2022_PASSWORD=$(openssl rand -base64 16); fi
    if [ "$ENABLE_WS_TLS" = 0 ]; then WS_UUID=""; WS_PATH=""
    elif [ -z "${PREVIOUS_WS_PORT:-}" ]; then WS_UUID=$("$SB_BIN" generate uuid); WS_PATH="/ws-$(openssl rand -hex 8)"; fi
    if [ "$ENABLE_WS_ARGO" = 0 ]; then ARGO_UUID=""; ARGO_PATH=""; ARGO_HOST=""; ARGO_TUNNEL_NAME=""
    elif [ -z "${PREVIOUS_ARGO_PORT:-}" ]; then ARGO_UUID=$("$SB_BIN" generate uuid); ARGO_PATH="/ws-$(openssl rand -hex 8)"; fi
    if [ "$ENABLE_NAIVE" = 0 ]; then NAIVE_USERNAME=""; NAIVE_PASSWORD=""
    elif [ -z "${PREVIOUS_NAIVE_PORT:-}" ]; then NAIVE_USERNAME="naive-$(openssl rand -hex 6)"; NAIVE_PASSWORD=$(openssl rand -hex 24); fi

    if [ "$ENABLE_VLESS_REALITY" = 0 ]; then REALITY_UUID=""; REALITY_PRIVATE=""; REALITY_PUBLIC=""; REALITY_SID=""
    elif [ -z "${PREVIOUS_REALITY_PORT:-}" ]; then
        REALITY_UUID=$("$SB_BIN" generate uuid); keypair=$("$SB_BIN" generate reality-keypair)
        REALITY_PRIVATE=$(printf '%s\n' "$keypair" | awk '/PrivateKey/ {print $2}')
        REALITY_PUBLIC=$(printf '%s\n' "$keypair" | awk '/PublicKey/ {print $2}')
        REALITY_SID=$("$SB_BIN" generate rand --hex 8)
        [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] && [ -n "$REALITY_SID" ] || err 'VLESS Reality 密钥生成失败。'
    fi
    if [ "$ENABLE_ANYTLS_REALITY" = 0 ]; then ANYREALITY_PASSWORD=""; ANYREALITY_PRIVATE=""; ANYREALITY_PUBLIC=""; ANYREALITY_SID=""
    elif [ -z "${PREVIOUS_ANYREALITY_PORT:-}" ]; then
        ANYREALITY_PASSWORD=$(openssl rand -hex 24); anyreality_keypair=$("$SB_BIN" generate reality-keypair)
        ANYREALITY_PRIVATE=$(printf '%s\n' "$anyreality_keypair" | awk '/PrivateKey/ {print $2}')
        ANYREALITY_PUBLIC=$(printf '%s\n' "$anyreality_keypair" | awk '/PublicKey/ {print $2}')
        ANYREALITY_SID=$("$SB_BIN" generate rand --hex 8)
        [ -n "$ANYREALITY_PRIVATE" ] && [ -n "$ANYREALITY_PUBLIC" ] && [ -n "$ANYREALITY_SID" ] || err 'AnyTLS + Reality 密钥生成失败。'
    fi
}

reuse_web_certificate() {
    [ "${web_protocol_sync:-0}" = 1 ] &&
        [ "$TLS_DOMAIN" = "$web_previous_tls_domain" ] && [ "$CERT_MODE" = "$web_previous_cert_mode" ] || return 1
    if [ "$CERT_MODE" = cloudflare ]; then
        [ "$CF_ZONE_NAME" = "$web_previous_cf_zone" ] &&
            [ "$cf_token" = "$(cat "$CF_TOKEN_FILE" 2>/dev/null || true)" ] &&
            [ "$zone_id" = "$(cat "$CF_ZONE_ID_FILE" 2>/dev/null || true)" ] || return 1
    fi
    check_cert_pair "$CERT_FILE" "$KEY_FILE" "$TLS_DOMAIN" >/dev/null 2>&1
}

install_from_config() {
    selected_count=0
    for enabled in "$ENABLE_ANYTLS" "$ENABLE_WS_TLS" "$ENABLE_WS_ARGO" "$ENABLE_VLESS_REALITY" "$ENABLE_NAIVE" "$ENABLE_ANYTLS_REALITY" "$ENABLE_SS2022"; do
        [ "$enabled" = 1 ] && selected_count=$((selected_count + 1))
    done
    [ "$selected_count" -gt 0 ] || err '至少选择一种协议。'

    derive_runtime_needs
    if [ "$ENABLE_WS_ARGO" = 1 ]; then
        valid_argo_token "$ARGO_TOKEN" || err 'Cloudflare Tunnel Token 格式无效；请粘贴完整的 eyJ... Token。'
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
    install_dependencies_and_core
    PREVIOUS_ANYTLS_PORT=${PREVIOUS_ANYTLS_PORT:-}; PREVIOUS_WS_PORT=${PREVIOUS_WS_PORT:-}
    PREVIOUS_REALITY_PORT=${PREVIOUS_REALITY_PORT:-}; PREVIOUS_NAIVE_PORT=${PREVIOUS_NAIVE_PORT:-}; PREVIOUS_ANYREALITY_PORT=${PREVIOUS_ANYREALITY_PORT:-}
    assign_ports

    if [ -n "$NODE_LABEL" ]; then
        label_length=$(jq -nr --arg node_label "$NODE_LABEL" '$node_label | length')
        [ "$label_length" -le 20 ] || err '节点辨识符最多 20 个字符。'
        jq -ne --arg node_label "$NODE_LABEL" '$node_label | test("^[\\p{L}\\p{N}._-]+$")' >/dev/null 2>&1 || err '节点辨识符仅支持中文、英文字母、数字、点、下划线和短横线。'
    fi

    generate_install_credentials
    web_sync_modified=1
    ensure_service_account
    enable_bbr
    create_service
    if [ "$NEED_CERT" = 1 ] && ! reuse_web_certificate; then
        CERT_FILE="$CERT_DIR/fullchain.pem"; KEY_FILE="$CERT_DIR/privkey.pem"
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
    elif [ "$NEED_CERT" = 0 ] && [ "${web_protocol_sync:-0}" = 0 ]; then
        rm -f "$CF_TOKEN_FILE" "$CF_ZONE_ID_FILE"
    fi

    if [ "$ENABLE_WS_ARGO" = 1 ]; then
        web_argo_touched=1
        write_argo_token_file "$ARGO_TOKEN" || err '无法安全写入 Cloudflare Tunnel Token 文件；请检查 /etc/sing-box 权限。'
    fi

    if [ "$ENABLE_WS_ARGO" = 1 ]; then
        install_cloudflared
        create_cloudflared_service
    fi

    build_config || err '配置未能成功应用，请检查 sing-box 日志。'
    if [ "${web_previous_argo:-0}" = 1 ] && [ "$ENABLE_WS_ARGO" = 0 ]; then
        remove_cloudflared_local_service
        msg '已移除本机 Argo 服务；Cloudflare 控制台中的 Tunnel 和 DNS 路由未更改。'
    fi
    web_sync_modified=0

    if [ "$ENABLE_WS_ARGO" = 1 ]; then
        msg '请在 Cloudflare 控制台确认 Tunnel Connector 已连接。'
        msg "Cloudflare Tunnel 路由必须设置：Public Hostname $ARGO_HOST → http://127.0.0.1:$ARGO_PORT"
        msg 'Argo 模式客户端使用 TLS 443；本机 WS 监听端口不需要 NAT 入站映射。'
    fi

    msg '安装完成。仅显示已选择的协议节点：'
    show_nodes
    msg '需要公网入站放行的 TCP 端口（Argo WS 不需要 NAT 入站端口）：'
    [ "$ENABLE_ANYTLS" = 0 ] || printf '  AnyTLS: %s/tcp\n' "$ANYTLS_PORT"
    [ "$ENABLE_VLESS_REALITY" = 0 ] || printf '  VLESS Reality: %s/tcp\n' "$REALITY_PORT"
    [ "$ENABLE_NAIVE" = 0 ] || printf '  NaiveProxy: %s/tcp\n' "$NAIVE_PORT"
    [ "$ENABLE_ANYTLS_REALITY" = 0 ] || printf '  AnyTLS Reality: %s/tcp\n' "$ANYREALITY_PORT"
    [ "$ENABLE_SS2022" = 0 ] || printf '  Shadowsocks 2022: %s/tcp + udp\n' "$SS2022_PORT"
    [ "$ENABLE_WS_TLS" = 0 ] || printf '  VLESS WS TLS: %s/tcp\n' "$WS_PORT"
    [ "$ENABLE_WS_ARGO" = 0 ] || msg '  VLESS WS Argo: 无需公网入站端口（cloudflared 主动出站连接）'
    msg '管理命令：/usr/local/sbin/sb-manager'
}

web_string() {
    trim_value "$(jq -r --arg key "$1" '.[$key] // ""' "$web_cfg")"
}

web_ws_setting() {
    web_ws_input=$(web_string "$1")
    case "$web_ws_input" in
        -) ;;
        '') printf '%s' "$2" ;;
        *) printf '%s' "$web_ws_input" ;;
    esac
}

web_port() {
    web_port_value=$(trim_value "$(jq -r --arg key "$1" '.ports[$key] // ""' "$web_cfg")")
    printf '%s\n' "${web_port_value:-${2:-}}"
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
    if [ "${web_protocol_sync:-0}" = 0 ]; then chmod -R go-rwx "$backup_dir" 2>/dev/null || true; fi
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
      ((.enabled_ss2022 != true) or (nonempty(.ss2022_password) and (.ss2022_port | type == "number"))) and
      ((.enabled_ws_argo != true) or (nonempty(.argo_host) and nonempty(.argo_uuid) and (.argo_port | type == "number") and nonempty(.argo_path))) and
      ((enabled("enabled_vless_reality") | not) or (nonempty(.reality_uuid) and nonempty(.reality_private) and nonempty(.reality_public) and nonempty(.reality_sid) and (.reality_port | type == "number") and nonempty(.reality_sni))) and
      ((enabled("enabled_naive") | not) or (nonempty(.naive_username) and nonempty(.naive_password) and (.naive_port | type == "number") and nonempty(.tls_domain))) and
      ((enabled("enabled_anytls_reality") | not) or (nonempty(.anyreality_password) and nonempty(.anyreality_private) and nonempty(.anyreality_public) and nonempty(.anyreality_sid) and (.anyreality_port | type == "number") and nonempty(.reality_sni))) and
      (if (.enabled_ss2022 == true or enabled("enabled_anytls") or enabled("enabled_naive") or enabled("enabled_vless_reality") or enabled("enabled_anytls_reality")) then (nonempty(.origin_addr) or nonempty(.origin_ipv6)) else true end) and
      (if (enabled("enabled_anytls") or enabled("enabled_naive") or (enabled("enabled_ws_tls") and (.ws_mode // "direct") == "direct")) then nonempty(.tls_domain) and nonempty(.cert_file) and nonempty(.key_file) and nonempty(.cert_mode) else true end)
    ' "$STATE_FILE" >/dev/null 2>&1
}

capture_web_state() {
    PREVIOUS_ANYTLS_PORT=""; PREVIOUS_WS_PORT=""; PREVIOUS_ARGO_PORT=""
    PREVIOUS_REALITY_PORT=""; PREVIOUS_NAIVE_PORT=""; PREVIOUS_ANYREALITY_PORT=""; PREVIOUS_SS2022_PORT=""
    [ "$ENABLE_ANYTLS" = 0 ] || PREVIOUS_ANYTLS_PORT=$ANYTLS_PORT
    [ "$ENABLE_WS_TLS" = 0 ] || PREVIOUS_WS_PORT=$WS_PORT
    [ "$ENABLE_WS_ARGO" = 0 ] || PREVIOUS_ARGO_PORT=$ARGO_PORT
    [ "$ENABLE_VLESS_REALITY" = 0 ] || PREVIOUS_REALITY_PORT=$REALITY_PORT
    [ "$ENABLE_NAIVE" = 0 ] || PREVIOUS_NAIVE_PORT=$NAIVE_PORT
    [ "$ENABLE_ANYTLS_REALITY" = 0 ] || PREVIOUS_ANYREALITY_PORT=$ANYREALITY_PORT
    [ "$ENABLE_SS2022" = 0 ] || PREVIOUS_SS2022_PORT=$SS2022_PORT
    web_previous_argo=$ENABLE_WS_ARGO
    web_previous_tls_domain=$TLS_DOMAIN
    web_previous_cert_mode=$CERT_MODE
    web_previous_cf_zone=$CF_ZONE_NAME
    web_previous_ws_server=""; web_previous_ws_host=""; web_previous_argo_server=""
    if [ "$ENABLE_WS_TLS" = 1 ]; then
        [ "$WS_SERVER" = "$TLS_DOMAIN" ] || web_previous_ws_server=$WS_SERVER
        [ "$WS_HOST" = "$TLS_DOMAIN" ] || web_previous_ws_host=$WS_HOST
    fi
    if [ "$ENABLE_WS_ARGO" = 1 ] && [ "$ARGO_SERVER" != "$ARGO_HOST" ]; then
        web_previous_argo_server=$ARGO_SERVER
    fi
}

restore_web_file() {
    if [ -f "$1" ]; then cp -p "$1" "$2"; else rm -f "$2"; fi
}

restore_web_sync() {
    web_exit_status=$1
    trap - 0
    if [ "$web_exit_status" -ne 0 ] && [ "$web_sync_modified" = 1 ]; then
        warn '同步失败，正在恢复原配置、凭据和服务。'
        web_restore_failed=0
        if [ "$web_previous_argo" = 0 ] && [ "$web_argo_touched" = 1 ]; then
            remove_cloudflared_local_service || web_restore_failed=1
        fi
        for web_restore_file in config.json manager.json cloudflare.token cloudflare-zone-id cloudflared.token cert/fullchain.pem cert/privkey.pem; do
            restore_web_file "$web_backup/sing-box/$web_restore_file" "$APP_DIR/$web_restore_file" || web_restore_failed=1
        done
        restore_web_file "$web_backup/sing-box-cert-reload" "$RELOAD_HOOK" || web_restore_failed=1
        restore_web_file "$web_backup/cloudflared-run" "$CLOUDFLARED_RUN" || web_restore_failed=1
        if [ "$SERVICE_KIND" = systemd ]; then
            restore_web_file "$web_backup/systemd-sing-box.service" /etc/systemd/system/sing-box.service || web_restore_failed=1
            restore_web_file "$web_backup/systemd-cloudflared.service" "/etc/systemd/system/$CLOUDFLARED_SERVICE.service" || web_restore_failed=1
            systemctl daemon-reload || web_restore_failed=1
            if [ "$web_previous_argo" = 1 ]; then systemctl enable "$CLOUDFLARED_SERVICE" >/dev/null || web_restore_failed=1; fi
        elif [ "$SERVICE_KIND" = openrc ]; then
            restore_web_file "$web_backup/openrc-sing-box" /etc/init.d/sing-box || web_restore_failed=1
            restore_web_file "$web_backup/openrc-cloudflared" "/etc/init.d/$CLOUDFLARED_SERVICE" || web_restore_failed=1
            if [ "$web_previous_argo" = 1 ]; then rc-update add "$CLOUDFLARED_SERVICE" default >/dev/null || web_restore_failed=1; fi
        fi
        if [ -n "$SERVICE_KIND" ]; then ENABLE_WS_ARGO=$web_previous_argo service_restart || web_restore_failed=1; fi
        if [ "$web_restore_failed" = 1 ]; then warn "未能完全恢复服务；原文件备份位于 $web_backup。"; fi
    fi
    exit "$web_exit_status"
}

apply_web_selection() (
    backup_existing_install
    web_backup=$backup_dir
    [ ! -f "$CLOUDFLARED_RUN" ] || cp -p "$CLOUDFLARED_RUN" "$web_backup/cloudflared-run"
    [ ! -f "/etc/systemd/system/$CLOUDFLARED_SERVICE.service" ] || cp -p "/etc/systemd/system/$CLOUDFLARED_SERVICE.service" "$web_backup/systemd-cloudflared.service"
    [ ! -f "/etc/init.d/$CLOUDFLARED_SERVICE" ] || cp -p "/etc/init.d/$CLOUDFLARED_SERVICE" "$web_backup/openrc-cloudflared"
    web_sync_modified=0
    web_argo_touched=0
    trap 'restore_web_sync "$?"' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    msg '正在按网页勾选同步：新增所选协议、更新保留节点，并移除未勾选协议。'
    install_from_config
)

legacy_web_selection_matches() {
    jq -e \
      --arg anytls "$ENABLE_ANYTLS" --arg ws_tls "$ENABLE_WS_TLS" --arg ws_argo "$ENABLE_WS_ARGO" \
      --arg reality "$ENABLE_VLESS_REALITY" --arg naive "$ENABLE_NAIVE" \
      --arg anyreality "$ENABLE_ANYTLS_REALITY" --arg ss2022 "$ENABLE_SS2022" '
        def selected($key): .protocols[$key] == true;
        def legacy_argo: .schema == 5 and selected("ws_tls") and .ws_mode == "argo";
        selected("anytls") == ($anytls == "1") and
        (selected("ws_tls") and (legacy_argo | not)) == ($ws_tls == "1") and
        (legacy_argo or (.schema == 6 and selected("ws_argo"))) == ($ws_argo == "1") and
        selected("vless_reality") == ($reality == "1") and
        selected("naive") == ($naive == "1") and
        selected("anytls_reality") == ($anyreality == "1") and
        (.schema == 6 and selected("ss2022")) == ($ss2022 == "1")
      ' "$web_cfg" >/dev/null
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
    jq -e '
      def text: type == "string" and (explode | all(. != 0 and . != 10 and . != 13));
      type == "object" and (.schema == 5 or .schema == 6 or .schema == 7) and
      (.protocols | type == "object") and
      (if .schema == 7 then
        .protocols | [.anytls,.ws_tls,.ws_argo,.vless_reality,.naive,.anytls_reality,.ss2022] | all(type == "boolean")
       else true end) and
      ([.origin_ipv4,.origin_ipv6,.ws_server,.argo_server,.ws_mode,.argo_host,.argo_tunnel_name,.argo_token,.tls_domain,.ws_host,.reality_sni,.node_label,.cert_mode,.cf_zone_name,.cf_token,.cf_email,.cf_zone_id]
        | all(. == null or text)) and
      (.ports | type == "object")
    ' "$web_cfg" >/dev/null 2>&1 || err '网页配置 JSON 格式不正确或版本不匹配，请刷新最新版 HTML 后重新生成命令。'

    web_schema=$(jq -r '.schema' "$web_cfg")
    web_protocol_sync=0
    if [ -e "$STATE_FILE" ]; then
        if ! manager_state_is_valid; then backup_existing_install; err '现有 manager.json 无效；已备份原目录，停止覆盖。'; fi
        load_state
        if [ "$web_schema" != 7 ]; then
            legacy_web_selection_matches || err '旧版网页命令的协议勾选与现有节点不同，未修改 VPS 配置。请刷新配置页，重新勾选需要保留的协议并复制新版命令。'
            warn '旧版网页命令只执行覆盖升级，不会同步协议勾选；请刷新页面重新生成命令。'
            overlay_install
            return 0
        fi
        web_protocol_sync=1
        capture_web_state
    fi

    ENABLE_ANYTLS=$(jq -r 'if .protocols.anytls == true then "1" else "0" end' "$web_cfg")
    ENABLE_WS_TLS=$(jq -r 'if .protocols.ws_tls == true then "1" else "0" end' "$web_cfg")
    ENABLE_VLESS_REALITY=$(jq -r 'if .protocols.vless_reality == true then "1" else "0" end' "$web_cfg")
    ENABLE_NAIVE=$(jq -r 'if .protocols.naive == true then "1" else "0" end' "$web_cfg")
    ENABLE_ANYTLS_REALITY=$(jq -r 'if .protocols.anytls_reality == true then "1" else "0" end' "$web_cfg")
    ENABLE_SS2022=$(jq -r 'if .schema >= 6 and .protocols.ss2022 == true then "1" else "0" end' "$web_cfg")
    SS2022_PORT=$(web_port ss2022 "${PREVIOUS_SS2022_PORT:-}")
    ENABLE_WS_ARGO=$(jq -r 'if .schema >= 6 and .protocols.ws_argo == true then "1" else "0" end' "$web_cfg")
    ARGO_HOST=$(web_string argo_host)
    ARGO_TUNNEL_NAME=$(web_string argo_tunnel_name)
    ARGO_TOKEN=$(web_string argo_token)
    ORIGIN_ADDR=$(web_string origin_ipv4); ORIGIN_IPV6=$(web_string origin_ipv6)
    WS_SERVER=$(web_ws_setting ws_server "${web_previous_ws_server:-}")
    TLS_DOMAIN=$(web_string tls_domain); WS_HOST=$(web_ws_setting ws_host "${web_previous_ws_host:-}")
    REALITY_SNI=$(web_string reality_sni); NODE_LABEL=$(web_string node_label)
    ANYTLS_PORT=$(web_port anytls "${PREVIOUS_ANYTLS_PORT:-}")
    WS_PORT=$(web_port ws_tls "${PREVIOUS_WS_PORT:-}")
    ARGO_PORT=$(web_port ws_argo "${PREVIOUS_ARGO_PORT:-}")
    ARGO_SERVER=$(web_ws_setting argo_server "${web_previous_argo_server:-}")
    if [ "$web_schema" = 5 ] && [ "$ENABLE_WS_TLS" = 1 ]; then
        case "$(web_string ws_mode)" in
            argo) legacy_ws_server=$WS_SERVER; migrate_legacy_argo ;;
            direct|'') ;;
            *) err '不支持的旧版 WS 接入方式。' ;;
        esac
    fi
    REALITY_PORT=$(web_port vless_reality "${PREVIOUS_REALITY_PORT:-}")
    NAIVE_PORT=$(web_port naive "${PREVIOUS_NAIVE_PORT:-}")
    ANYREALITY_PORT=$(web_port anytls_reality "${PREVIOUS_ANYREALITY_PORT:-}")
    cert_mode=$(web_string cert_mode); CF_ZONE_NAME=$(web_string cf_zone_name)
    cf_token=$(web_string cf_token); cert_email=$(web_string cf_email); zone_id=$(web_string cf_zone_id)
    case "$cert_mode" in cloudflare) CERT_MODE=cloudflare ;; http01) CERT_MODE=standalone ;; none|'') CERT_MODE=none ;; *) err '不支持的证书方式。' ;; esac

    selected_count=$((ENABLE_ANYTLS + ENABLE_WS_TLS + ENABLE_WS_ARGO + ENABLE_VLESS_REALITY + ENABLE_NAIVE + ENABLE_ANYTLS_REALITY + ENABLE_SS2022))
    [ "$selected_count" -gt 0 ] || err '请至少选择一种协议。'
    derive_runtime_needs
    if [ "$NEED_CERT" = 1 ] && [ "$CERT_MODE" = cloudflare ] && [ -z "$cf_token" ]; then
        ask_secret 'Cloudflare DNS API Token（网页未提供；输入时不会显示）'; cf_token=$(trim_value "$REPLY")
    fi
    if [ "$web_protocol_sync" = 1 ]; then
        apply_web_selection
    else
        msg '正在使用网页选择的协议和参数启动 sing-box 安装流程……'
        install_from_config
    fi
}

change_tls_sni() {
    if [ "$NEED_CERT" = 0 ]; then warn '当前所选协议不使用源站 TLS 证书；Argo WS 的 TLS SNI 由 Argo 公网主机名决定。'; return 0; fi
    msg '此域名用于普通 AnyTLS、直连 VLESS + WS + TLS 和 NaiveProxy 的 TLS SNI，必须是你拥有/获准管理且有匹配证书的域名。'
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
    # Refresh share links and the generated Naive client JSON with the new SNI.
    show_nodes
}

change_cloudflare_zone() {
    if [ "$CERT_MODE" != cloudflare ]; then
        warn '当前证书模式不是 Cloudflare DNS-01。请先使用 Cloudflare DNS-01 申请证书，才能修改 Cloudflare 绑定区域。'
        return 0
    fi
    cf_token_exists=0
    [ ! -s "$CF_TOKEN_FILE" ] || cf_token_exists=1

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
    ask_value '新 Cloudflare Zone ID（留空保留当前；输入 - 自动查询）' "$current_zone_id"
    new_zone_id=$(trim_value "$REPLY")
    [ "$new_zone_id" = '-' ] && new_zone_id=""
    if [ -n "$new_zone_id" ]; then
        case "$new_zone_id" in *[!A-Fa-f0-9]*) warn 'Zone ID 必须是 32 位十六进制字符串。'; return 0 ;; esac
        [ "${#new_zone_id}" -eq 32 ] || { warn 'Zone ID 必须是 32 位十六进制字符串，或留空自动查询。'; return 0; }
    fi
    ask_secret '新的 Cloudflare DNS API Token（留空保留当前 Token；若当前缺失则必须填写）'
    new_cf_token=$(trim_value "$REPLY")
    if [ -z "$new_cf_token" ] && [ "$cf_token_exists" -eq 0 ]; then
        warn '当前没有保存 Cloudflare DNS API Token；必须输入新 Token 才能申请证书。'
        return 0
    fi

    msg "将为 $new_cert_domain 使用 Cloudflare DNS-01 签发 TLS 证书。Zone ID 可自动查询；DNS API Token 留空则沿用当前 Token。"

    backup_dir=$(mktemp -d) || { warn '无法创建临时证书备份目录。'; return 0; }
    cp -p "$CERT_FILE" "$backup_dir/fullchain.pem" 2>/dev/null || true
    cp -p "$KEY_FILE" "$backup_dir/privkey.pem" 2>/dev/null || true
    cp -p "$CF_ZONE_ID_FILE" "$backup_dir/zone-id" 2>/dev/null || true
    cp -p "$CF_TOKEN_FILE" "$backup_dir/cloudflare.token" 2>/dev/null || true

    old_zone=$CF_ZONE_NAME
    old_tls_domain=$TLS_DOMAIN
    old_ws_host=$WS_HOST
    old_ws_server=$WS_SERVER
    old_preferred_ip=$PREFERRED_IP

    if [ -n "$new_zone_id" ]; then
        printf '%s' "$new_zone_id" > "$CF_ZONE_ID_FILE"
        chmod 0600 "$CF_ZONE_ID_FILE"
        chown root:root "$CF_ZONE_ID_FILE"
    else
        rm -f "$CF_ZONE_ID_FILE"
    fi
    if [ -n "$new_cf_token" ]; then
        token_tmp="$CF_TOKEN_FILE.tmp.$$"
        printf '%s' "$new_cf_token" > "$token_tmp" || {
            rm -f "$token_tmp"
            if [ -s "$backup_dir/zone-id" ]; then cp -p "$backup_dir/zone-id" "$CF_ZONE_ID_FILE"; else rm -f "$CF_ZONE_ID_FILE"; fi
            if [ -s "$backup_dir/cloudflare.token" ]; then cp -p "$backup_dir/cloudflare.token" "$CF_TOKEN_FILE"; else rm -f "$CF_TOKEN_FILE"; fi
            rm -rf "$backup_dir"
            warn '无法写入新的 Cloudflare DNS API Token；已恢复原凭据。'
            return 0
        }
        chmod 0600 "$token_tmp"
        chown root:root "$token_tmp"
        mv -f "$token_tmp" "$CF_TOKEN_FILE"
    fi
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
        if [ -s "$backup_dir/cloudflare.token" ]; then cp -p "$backup_dir/cloudflare.token" "$CF_TOKEN_FILE"; else rm -f "$CF_TOKEN_FILE"; fi
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
        if [ -s "$backup_dir/cloudflare.token" ]; then cp -p "$backup_dir/cloudflare.token" "$CF_TOKEN_FILE"; else rm -f "$CF_TOKEN_FILE"; fi
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
        WS_SERVER=$TLS_DOMAIN
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

change_argo_address() {
    ask_value '新的 Argo 连接地址（IPv4 / IPv6 / 域名；输入 - 恢复 Public Hostname）' "$ARGO_SERVER"
    new_argo_server=$(trim_value "$REPLY")
    [ "$new_argo_server" != '-' ] || new_argo_server=$ARGO_HOST
    case "$new_argo_server" in
        *:*) valid_ipv6_literal "$new_argo_server" || { warn 'IPv6 地址格式无效。'; return 0; } ;;
        *) valid_main_address "$new_argo_server" || { warn 'IPv4 地址 / 域名格式无效。'; return 0; } ;;
    esac
    old_argo_server=$ARGO_SERVER
    ARGO_SERVER=$new_argo_server
    if ! save_state; then ARGO_SERVER=$old_argo_server; return 0; fi
    show_nodes
}

change_argo_binding() {
    [ "$ENABLE_WS_ARGO" = 1 ] || {
        warn '当前未启用 VLESS + WS 固定 Argo Tunnel。'
        return 0
    }
    old_argo_token_exists=0
    [ ! -s "$ARGO_TOKEN_FILE" ] || old_argo_token_exists=1

    msg '修改固定 Tunnel 的 Public Hostname、备注名或轮换 Token。'
    msg 'Token 留空表示保留当前 Token；不会显示或回显现有 Token。'
    old_argo_host=$ARGO_HOST
    old_argo_name=$ARGO_TUNNEL_NAME
    old_argo_server=$ARGO_SERVER
    backup_dir=$(mktemp -d) || { warn '无法创建临时备份目录。'; return 0; }
    if [ "$old_argo_token_exists" -eq 1 ] && ! cp -p "$ARGO_TOKEN_FILE" "$backup_dir/cloudflared.token"; then
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
    ask_value 'Tunnel 备注名（留空保持；输入 - 清除备注）' "$ARGO_TUNNEL_NAME"
    new_argo_name=$(normalize_tunnel_name "$REPLY")
    [ "$new_argo_name" = '-' ] && new_argo_name=""
    ask_secret '新的 Cloudflare Tunnel Token（留空保留当前 Token；若当前缺失则必须填写）'
    new_argo_token=$(trim_value "$REPLY")
    if [ -z "$new_argo_token" ] && [ "$old_argo_token_exists" -eq 0 ]; then
        rm -rf "$backup_dir"
        warn '当前 Tunnel Token 缺失；必须输入新的 Tunnel Token。'
        return 0
    fi
    if [ -n "$new_argo_token" ] && ! valid_argo_token "$new_argo_token"; then
        rm -rf "$backup_dir"
        warn '新 Tunnel Token 格式无效；没有修改任何配置。'
        return 0
    fi

    ARGO_HOST=$new_argo_host
    ARGO_TUNNEL_NAME=$new_argo_name
    if [ -z "$old_argo_server" ] || [ "$old_argo_server" = "$old_argo_host" ]; then
        ARGO_SERVER=$new_argo_host
        PREFERRED_IP=""
        PREFERRED_IPV6=""
    fi

    if [ -n "$new_argo_token" ]; then
        if ! write_argo_token_file "$new_argo_token"; then
            ARGO_HOST=$old_argo_host
            ARGO_TUNNEL_NAME=$old_argo_name
            ARGO_SERVER=$old_argo_server
            rm -rf "$backup_dir"
            warn '新 Token 无法安全写入；原配置保持不变。'
            return 0
        fi
        if ! start_cloudflared_service; then
            if [ "$old_argo_token_exists" -eq 1 ]; then cp -p "$backup_dir/cloudflared.token" "$ARGO_TOKEN_FILE"; else rm -f "$ARGO_TOKEN_FILE"; fi
            chown root:sing-box "$ARGO_TOKEN_FILE" 2>/dev/null || true
            chmod 0640 "$ARGO_TOKEN_FILE" 2>/dev/null || true
            start_cloudflared_service >/dev/null 2>&1 || true
            ARGO_HOST=$old_argo_host
            ARGO_TUNNEL_NAME=$old_argo_name
            ARGO_SERVER=$old_argo_server
            rm -rf "$backup_dir"
            warn 'Tunnel 服务重启失败，已恢复本机旧 Token 文件和旧节点参数。若你已在 Cloudflare 控制台执行 Rotate Token，旧 Token 可能已失效，请重新输入新 Token。'
            return 0
        fi
        sleep 3
        if [ "$SERVICE_KIND" = systemd ]; then
            if ! systemctl is-active --quiet "$CLOUDFLARED_SERVICE"; then
                if [ "$old_argo_token_exists" -eq 1 ]; then cp -p "$backup_dir/cloudflared.token" "$ARGO_TOKEN_FILE"; else rm -f "$ARGO_TOKEN_FILE"; fi
                chown root:sing-box "$ARGO_TOKEN_FILE" 2>/dev/null || true
                chmod 0640 "$ARGO_TOKEN_FILE" 2>/dev/null || true
                start_cloudflared_service >/dev/null 2>&1 || true
                ARGO_HOST=$old_argo_host
                ARGO_TUNNEL_NAME=$old_argo_name
                ARGO_SERVER=$old_argo_server
                rm -rf "$backup_dir"
                warn '新 Token 启动后服务未处于 active，已恢复本机旧 Token 文件和旧节点参数。若 Cloudflare 已轮换 Token，旧 Token 可能已失效。'
                return 0
            fi
        elif [ "$SERVICE_KIND" = openrc ]; then
            if ! rc-service "$CLOUDFLARED_SERVICE" status >/dev/null 2>&1; then
                if [ "$old_argo_token_exists" -eq 1 ]; then cp -p "$backup_dir/cloudflared.token" "$ARGO_TOKEN_FILE"; else rm -f "$ARGO_TOKEN_FILE"; fi
                chown root:sing-box "$ARGO_TOKEN_FILE" 2>/dev/null || true
                chmod 0640 "$ARGO_TOKEN_FILE" 2>/dev/null || true
                start_cloudflared_service >/dev/null 2>&1 || true
                ARGO_HOST=$old_argo_host
                ARGO_TUNNEL_NAME=$old_argo_name
                ARGO_SERVER=$old_argo_server
                rm -rf "$backup_dir"
                warn '新 Token 启动后 OpenRC 服务未运行，已恢复本机旧 Token 文件和旧节点参数。若 Cloudflare 已轮换 Token，旧 Token 可能已失效。'
                return 0
            fi
        fi
    fi

    if ! save_state; then
        if [ "$old_argo_token_exists" -eq 1 ]; then cp -p "$backup_dir/cloudflared.token" "$ARGO_TOKEN_FILE"; else rm -f "$ARGO_TOKEN_FILE"; fi
        chown root:sing-box "$ARGO_TOKEN_FILE" 2>/dev/null || true
        chmod 0640 "$ARGO_TOKEN_FILE" 2>/dev/null || true
        start_cloudflared_service >/dev/null 2>&1 || true
        ARGO_HOST=$old_argo_host
        ARGO_TUNNEL_NAME=$old_argo_name
        ARGO_SERVER=$old_argo_server
        rm -rf "$backup_dir"
        warn '保存管理状态失败；已尽力恢复旧 Token 和节点参数。'
        return 0
    fi

    rm -rf "$backup_dir"
    show_nodes
    if [ "$old_argo_host" != "$ARGO_HOST" ]; then
        msg "Public Hostname 已更新为 $ARGO_HOST。请在 Cloudflare Zero Trust 的该 Tunnel 中同步添加/修改 Public Hostname，并将 Service URL 指向 http://127.0.0.1:$ARGO_PORT。"
    fi
    if [ -n "$new_argo_token" ]; then
        msg '新 Tunnel Token 已写入受限权限文件并重启 cloudflared。请在 Cloudflare 控制台确认 Connector 状态为 Healthy。'
    else
        msg 'Tunnel 节点参数已保存；现有 Token 保持不变。'
    fi
}

change_ws_host() {
    [ "$ENABLE_WS_TLS" = 1 ] || { warn '当前未安装直连 WS；Argo 的 Host 由 Public Hostname 决定。'; return 0; }
    msg 'WS HTTP Host 是 WebSocket HTTP 请求头，不是 TLS SNI。默认建议与 TLS 证书域名相同。'
    ask_value '新的 VLESS WS HTTP Host（留空保持；输入 - 恢复默认域名）' "$WS_HOST"
    new_host=$(trim_value "$REPLY")
    [ "$new_host" = '-' ] && new_host=$TLS_DOMAIN
    valid_domain "$new_host" || { warn '域名格式无效。'; return; }
    old_host=$WS_HOST
    WS_HOST=$new_host
    if ! save_state; then WS_HOST=$old_host; warn '保存 WS Host 失败，原值保持不变。'; return 0; fi
    show_nodes
}


change_single_port() {
    selected_choice=${1:-}
    if [ -z "$selected_choice" ]; then
        printf '\n当前协议端口：\n'
        printf '1. AnyTLS              %s/tcp\n' "$ANYTLS_PORT"
        printf '2. VLESS + WS + TLS 直连 %s/tcp\n' "$WS_PORT"
        printf '3. VLESS + Reality     %s/tcp\n' "$REALITY_PORT"
        printf '4. NaiveProxy          %s/tcp\n' "$NAIVE_PORT"
        printf '5. AnyTLS + Reality    %s/tcp\n' "$ANYREALITY_PORT"
        printf '6. VLESS + WS + TLS Argo %s/tcp（本机）\n' "$ARGO_PORT"
        printf '7. Shadowsocks 2022     %s/tcp + udp\n' "$SS2022_PORT"
        printf '0. 返回\n'
        printf '请选择要修改端口的单个节点：'
        IFS= read -r selected_choice || selected_choice=0
    fi

    case "$selected_choice" in
        1)
            [ "$ENABLE_ANYTLS" = 1 ] || { warn '当前未安装 AnyTLS。'; return 0; }
            selected_name='AnyTLS'
            selected_current=$ANYTLS_PORT
            other_ports="$SS2022_PORT $ARGO_PORT $WS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT"
            selected_kind=range
            ;;
        2)
            [ "$ENABLE_WS_TLS" = 1 ] || { warn '当前未安装 VLESS + WS + TLS。'; return 0; }
            selected_name='VLESS + WS + TLS'
            selected_current=$WS_PORT
            other_ports="$SS2022_PORT $ARGO_PORT $ANYTLS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT"
            selected_kind=ws
            ;;
        6)
            [ "$ENABLE_WS_ARGO" = 1 ] || { warn '当前未安装 Argo WS。'; return 0; }
            selected_name='VLESS + WS + TLS Argo'
            selected_current=$ARGO_PORT
            other_ports="$SS2022_PORT $ANYTLS_PORT $WS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT"
            selected_kind=argo
            ;;
        3)
            [ "$ENABLE_VLESS_REALITY" = 1 ] || { warn '当前未安装 VLESS + Reality。'; return 0; }
            selected_name='VLESS + Reality'
            selected_current=$REALITY_PORT
            other_ports="$SS2022_PORT $ARGO_PORT $ANYTLS_PORT $WS_PORT $NAIVE_PORT $ANYREALITY_PORT"
            selected_kind=range
            ;;
        4)
            [ "$ENABLE_NAIVE" = 1 ] || { warn '当前未安装 NaiveProxy。'; return 0; }
            selected_name='NaiveProxy'
            selected_current=$NAIVE_PORT
            other_ports="$SS2022_PORT $ARGO_PORT $ANYTLS_PORT $WS_PORT $REALITY_PORT $ANYREALITY_PORT"
            selected_kind=range
            ;;
        5)
            [ "$ENABLE_ANYTLS_REALITY" = 1 ] || { warn '当前未安装 AnyTLS + Reality。'; return 0; }
            selected_name='AnyTLS + Reality'
            selected_current=$ANYREALITY_PORT
            other_ports="$SS2022_PORT $ARGO_PORT $ANYTLS_PORT $WS_PORT $REALITY_PORT $NAIVE_PORT"
            selected_kind=range
            ;;
        7)
            [ "$ENABLE_SS2022" = 1 ] || { warn '当前未安装 Shadowsocks 2022。'; return 0; }
            selected_name='Shadowsocks 2022'
            selected_current=$SS2022_PORT
            other_ports="$ARGO_PORT $ANYTLS_PORT $WS_PORT $REALITY_PORT $NAIVE_PORT $ANYREALITY_PORT"
            selected_kind=ss2022
            ;;
        0) return 0 ;;
        *) warn '无效选择。'; return 0 ;;
    esac

    selected_udp=0
    selected_transport=tcp
    if [ "$selected_kind" = ss2022 ]; then selected_udp=1; selected_transport='tcp + udp'; fi
    printf '\n当前 %s 端口：%s/%s\n' "$selected_name" "$selected_current" "$selected_transport"
    if [ "$selected_kind" = ws ]; then
        msg '直连 Cloudflare 橙云 WS TLS 端口请使用 443、2053、2083、2087、2096 或 8443。'
        ask_value '输入新端口（留空自动随机）' ''
    elif [ "$selected_kind" = argo ]; then
        msg 'Argo 模式该端口是 VPS 本机 127.0.0.1 监听端口，不是公网端口。修改后需同步更新 Cloudflare Tunnel Public Hostname 的 Service URL。'
        ask_value '输入新的本机 WS 端口（留空自动随机）' ''
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

    if [ -n "$requested_port" ] && check_udp_port="$selected_udp" port_listening "$requested_port"; then
        warn "端口 $requested_port 已被其他进程监听；将为 $selected_name 自动选择备用端口。"
        requested_port=""
    fi

    if [ -z "$requested_port" ]; then
        if [ "$selected_kind" = ws ]; then
            if ! selected_new_port=$(pick_random_ws_port $other_ports "$selected_current"); then
                warn '没有可用的 Cloudflare WS TLS 代理端口（2053、2083、2087、2096、8443）；原配置保持不变。'
                return 0
            fi
        else
            if ! selected_new_port=$(check_udp_port="$selected_udp" pick_random_range_port 10000 65535 $other_ports "$selected_current"); then
                warn "无法为 $selected_name 找到空闲端口；原配置保持不变。"
                return 0
            fi
        fi
        msg "$selected_name 的新端口已自动分配：$selected_new_port/$selected_transport"
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
        6) ARGO_PORT=$selected_new_port ;;
        7) SS2022_PORT=$selected_new_port ;;
        3) REALITY_PORT=$selected_new_port ;;
        4) NAIVE_PORT=$selected_new_port ;;
        5) ANYREALITY_PORT=$selected_new_port ;;
    esac

    msg "正在仅修改 $selected_name 端口，并检查完整 sing-box 配置……"
    if ! build_config; then
        case "$selected_choice" in
            1) ANYTLS_PORT=$old_selected_port ;;
            2) WS_PORT=$old_selected_port ;;
            6) ARGO_PORT=$old_selected_port ;;
            7) SS2022_PORT=$old_selected_port ;;
            3) REALITY_PORT=$old_selected_port ;;
            4) NAIVE_PORT=$old_selected_port ;;
            5) ANYREALITY_PORT=$old_selected_port ;;
        esac
        warn "$selected_name 端口修改失败；已恢复原端口 $old_selected_port，其他节点参数未修改。"
        return 0
    fi

    msg "$selected_name 端口修改成功：$old_selected_port → $selected_new_port"
    show_nodes
    if [ "$selected_choice" = 6 ]; then msg "请在 Cloudflare Tunnel Public Hostname 中将 $ARGO_HOST 的 Service URL 更新为 http://127.0.0.1:$ARGO_PORT。Argo WS 本机端口不需要 NAT 入站映射。"; else msg '请同步更新系统防火墙、云安全组及 NAT 服务商公网端口映射。'; fi
}

change_ports() {
    [ "$ENABLE_WS_ARGO" = 0 ] || printf 'Argo 本机端口：%s/tcp\n' "$ARGO_PORT"
    [ "$ENABLE_SS2022" = 0 ] || printf 'Shadowsocks 2022 端口：%s/tcp + udp\n' "$SS2022_PORT"
    printf '当前端口：AnyTLS=%s, WS+TLS=%s, VLESS Reality=%s, NaiveProxy=%s, AnyTLS Reality=%s\n' "$ANYTLS_PORT" "$WS_PORT" "$REALITY_PORT" "$NAIVE_PORT" "$ANYREALITY_PORT"
    old_anytls=$ANYTLS_PORT
    old_ws=$WS_PORT
    old_argo=$ARGO_PORT
    old_ss2022=$SS2022_PORT
    old_reality=$REALITY_PORT
    old_naive=$NAIVE_PORT
    old_anyreality=$ANYREALITY_PORT
    PREVIOUS_ANYTLS_PORT=$old_anytls
    PREVIOUS_WS_PORT=$old_ws
    PREVIOUS_ARGO_PORT=$old_argo
    PREVIOUS_SS2022_PORT=$old_ss2022
    PREVIOUS_REALITY_PORT=$old_reality
    PREVIOUS_NAIVE_PORT=$old_naive
    PREVIOUS_ANYREALITY_PORT=$old_anyreality
    ask_ports
    assign_ports
    if ! build_config; then
        ANYTLS_PORT=$old_anytls
        WS_PORT=$old_ws
        ARGO_PORT=$old_argo
        SS2022_PORT=$old_ss2022
        REALITY_PORT=$old_reality
        NAIVE_PORT=$old_naive
        ANYREALITY_PORT=$old_anyreality
        return 0
    fi
    show_nodes
    if [ "$ENABLE_WS_ARGO" = 1 ]; then msg "如 WS 本机端口发生变化，请将 Cloudflare Tunnel Service URL 更新为 http://127.0.0.1:$ARGO_PORT。Argo WS 不需要公网入站映射。"; fi
    msg '请同步修改其他已安装直连协议的云安全组、系统防火墙和 NAT 映射。'
}

change_origin_addresses() {
    [ "$NEED_ORIGIN" = 1 ] || { warn '当前已安装协议不需要源站地址。'; return 0; }
    msg '源站 IPv4 / IPv6 是直连协议共用的连接地址；修改后会影响 AnyTLS、NaiveProxy、Reality 等使用源站地址的节点。'
    msg '留空保持当前值；输入 - 清除此地址；输入 auto 重新自动检测该地址。'
    old_ipv4=$ORIGIN_ADDR
    old_ipv6=$ORIGIN_IPV6
    ask_value '新的源站 IPv4 / 域名' "$ORIGIN_ADDR"
    new_ipv4=$(trim_value "$REPLY")
    ask_value '新的源站 IPv6' "$ORIGIN_IPV6"
    new_ipv6=$(trim_value "$REPLY")

    if [ "$new_ipv4" = '-' ]; then new_ipv4=""; fi
    if [ "$new_ipv6" = '-' ]; then new_ipv6=""; fi
    if [ "$new_ipv4" = 'auto' ]; then
        new_ipv4=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)
        valid_ipv4_address "$new_ipv4" || new_ipv4=""
    fi
    if [ "$new_ipv6" = 'auto' ]; then
        if ipv6_kernel_enabled; then
            new_ipv6=$(curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null || true)
            valid_ipv6_address "$new_ipv6" || new_ipv6=""
        else new_ipv6=""; fi
    fi
    [ -n "$new_ipv4" ] || [ -n "$new_ipv6" ] || {
        warn '至少需要一个可用的源站 IPv4 / IPv6 地址；NAT VPS 请填写服务商提供的实际公网入口地址。'
        return 0
    }
    if [ -n "$new_ipv4" ]; then
        valid_main_address "$new_ipv4" || { warn '源站 IPv4 / 域名格式无效。'; return 0; }
    fi
    if [ -n "$new_ipv6" ]; then
        ipv6_kernel_enabled || { warn '系统未启用 IPv6，不能设置 IPv6 地址。'; return 0; }
        valid_ipv6_address "$new_ipv6" || { warn '源站 IPv6 格式无效，或 VPS 没有到该地址的 IPv6 路由。'; return 0; }
    fi
    ORIGIN_ADDR=$new_ipv4
    ORIGIN_IPV6=$new_ipv6
    if ! save_state; then
        ORIGIN_ADDR=$old_ipv4
        ORIGIN_IPV6=$old_ipv6
        warn '保存源站地址失败；已保留旧地址。'
        return 0
    fi
    show_nodes
    msg '源站地址已更新。注意：NAT VPS 的出站检测 IP 不一定等于服务商分配的入站映射 IP，请核对公网映射。'
}

print_protocol_field_guide() {
    case "$1" in
        1)
            msg 'AnyTLS 参数说明：'
            printf '  必填：TLS 证书域名 / SNI（与 Naive、直连 WS 共用证书域名）。\n'
            printf '  必填：至少一个源站 IPv4 / IPv6（可尝试自动检测；NAT 映射地址建议手动填写）。\n'
            printf '  自动生成：AnyTLS 密码。可在“专属参数”中自定义或重新生成。\n'
            printf '  可选：TCP 监听端口；留空时自动分配。Cloudflare Zone ID 可自动查询。\n' ;;
        2)
            msg '直连 VLESS WS TLS：需要源站 TLS 证书，可修改连接地址、HTTP Host、端口、UUID 和路径。' ;;
        6)
            msg 'Argo VLESS WS TLS：需要 Tunnel Public Hostname 和 Token，可修改连接地址、备注、本机端口、UUID 和路径。'
            msg '客户端使用 Cloudflare TLS 443；源站不需要 TLS 证书或公网入站端口。' ;;
        7) msg 'Shadowsocks 2022 不需要证书或 SNI；使用源站地址与 TCP/UDP 端口，密钥可在专属参数中轮换。' ;;
        3)
            msg 'VLESS + Reality 参数说明：'
            printf '  必填：Reality SNI / 握手目标域名；默认 www.bing.com。\n'
            printf '  必填：至少一个源站 IPv4 / IPv6（可尝试自动检测）。\n'
            printf '  自动生成：UUID、Reality 密钥对和 Short ID。\n'
            printf '  可选：TCP 监听端口；留空时自动分配。\n'
            if [ "$ENABLE_ANYTLS_REALITY" = 1 ]; then printf '  注意：当前 Reality SNI 与 AnyTLS + Reality 共用。\n'; fi ;;
        4)
            msg 'NaiveProxy 参数说明：'
            printf '  必填：TLS 证书域名 / SNI 和有效证书。\n'
            printf '  必填：至少一个源站 IPv4 / IPv6（可尝试自动检测）。\n'
            printf '  自动生成：Naive 用户名和密码；可在“专属参数”中自定义或重新生成。\n'
            printf '  可选：TCP 监听端口；留空时自动分配。\n' ;;
        5)
            msg 'AnyTLS + Reality 参数说明：'
            printf '  必填：Reality SNI / 握手目标域名；默认 www.bing.com。\n'
            printf '  必填：至少一个源站 IPv4 / IPv6（可尝试自动检测）。\n'
            printf '  自动生成：密码、Reality 密钥对和 Short ID。\n'
            printf '  可选：TCP 监听端口；留空时自动分配。\n'
            if [ "$ENABLE_VLESS_REALITY" = 1 ]; then printf '  注意：当前 Reality SNI 与 VLESS + Reality 共用。\n'; fi ;;
    esac
}

change_protocol_extra_settings() {
    selected_protocol=$1
    case "$selected_protocol" in
        1)
            old_secret=$ANYTLS_PASSWORD
            ask_secret '新的 AnyTLS 密码（留空保持；输入 - 随机生成）'
            new_secret=$(trim_value "$REPLY")
            [ -n "$new_secret" ] || return 0
            if [ "$new_secret" = '-' ]; then new_secret=$(openssl rand -hex 24); fi
            case "$new_secret" in *[!A-Za-z0-9._~-]*) warn '密码只允许字母、数字、点、下划线、波浪线和短横线。'; return 0 ;; esac
            [ "${#new_secret}" -ge 8 ] && [ "${#new_secret}" -le 128 ] || { warn '密码长度必须为 8–128 个字符。'; return 0; }
            ANYTLS_PASSWORD=$new_secret
            ;;
        7)
            ask_value '重新生成 Shadowsocks 2022 密钥？旧客户端需要更新节点。(y/N)' 'n'
            case "$REPLY" in y|Y|yes|YES) SS2022_PASSWORD=$(openssl rand -base64 16) ;; *) return 0 ;; esac
            ;;
        2|6)
            if [ "$selected_protocol" = 2 ]; then
                ask_value 'WS HTTP Host（留空保持；输入 - 恢复 TLS 域名默认值）' "$WS_HOST"
                new_host=$(trim_value "$REPLY")
                [ "$new_host" = '-' ] && new_host=$TLS_DOMAIN
                valid_domain "$new_host" || { warn 'WS HTTP Host 必须是有效域名。'; return 0; }
                WS_HOST=$new_host
            else
                msg 'Argo 模式的 HTTP Host 与 Public Hostname 绑定，不能单独修改；请修改 Cloudflare Tunnel Public Hostname。'
            fi
            if [ "$selected_protocol" = 6 ]; then current_ws_path=$ARGO_PATH; current_ws_uuid=$ARGO_UUID
            else current_ws_path=$WS_PATH; current_ws_uuid=$WS_UUID; fi
            ask_value 'WS Path（留空保持；输入 - 随机生成）' "$current_ws_path"
            new_path=$(trim_value "$REPLY")
            if [ "$new_path" = '-' ]; then new_path="/ws-$(openssl rand -hex 8)"; fi
            case "$new_path" in /*) ;; *) warn 'WS Path 必须以 / 开头。'; return 0 ;; esac
            case "$new_path" in *[!A-Za-z0-9/_~-]*) warn 'WS Path 只允许字母、数字、斜线、下划线、短横线和波浪线。'; return 0 ;; esac
            [ "${#new_path}" -le 160 ] || { warn 'WS Path 最长 160 个字符。'; return 0; }
            ask_value 'WS UUID（留空保持；输入 - 自动生成新 UUID）' "$current_ws_uuid"
            new_uuid=$(trim_value "$REPLY")
            if [ "$new_uuid" = '-' ]; then new_uuid=$("$SB_BIN" generate uuid); fi
            if [ -n "$new_uuid" ]; then
                printf '%s\n' "$new_uuid" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-8][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$' || { warn 'UUID 格式无效。'; return 0; }
            fi
            if [ "$selected_protocol" = 6 ]; then ARGO_PATH=$new_path; ARGO_UUID=${new_uuid:-$current_ws_uuid}
            else WS_PATH=$new_path; WS_UUID=${new_uuid:-$current_ws_uuid}; fi
            ;;
        3)
            ask_value 'VLESS Reality UUID（留空保持；输入 - 自动生成）' "$REALITY_UUID"
            new_uuid=$(trim_value "$REPLY")
            if [ "$new_uuid" = '-' ]; then new_uuid=$("$SB_BIN" generate uuid); fi
            if [ -n "$new_uuid" ]; then
                printf '%s\n' "$new_uuid" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-8][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$' || { warn 'UUID 格式无效。'; return 0; }
                REALITY_UUID=$new_uuid
            fi
            ask_value '是否重新生成 Reality 密钥对和 Short ID？(y/N)' 'n'
            case "$REPLY" in
                y|Y|yes|YES)
                    pair=$($SB_BIN generate reality-keypair)
                    new_private=$(printf '%s\n' "$pair" | awk '/PrivateKey/ {print $2}')
                    new_public=$(printf '%s\n' "$pair" | awk '/PublicKey/ {print $2}')
                    new_sid=$($SB_BIN generate rand --hex 8)
                    [ -n "$new_private" ] && [ -n "$new_public" ] && [ -n "$new_sid" ] || { warn 'Reality 密钥生成失败。'; return 0; }
                    REALITY_PRIVATE=$new_private; REALITY_PUBLIC=$new_public; REALITY_SID=$new_sid
                    msg 'Reality 密钥已轮换；所有使用旧公钥的客户端必须更新节点。'
                    ;;
            esac
            ;;
        4)
            ask_value 'NaiveProxy 用户名（留空保持；输入 - 随机生成）' "$NAIVE_USERNAME"
            new_username=$(trim_value "$REPLY")
            if [ "$new_username" = '-' ]; then new_username="naive-$(openssl rand -hex 6)"; fi
            if [ -n "$new_username" ]; then
                case "$new_username" in *[!A-Za-z0-9._-]*) warn '用户名只允许字母、数字、点、下划线和短横线。'; return 0 ;; esac
                [ "${#new_username}" -ge 3 ] && [ "${#new_username}" -le 64 ] || { warn '用户名长度必须为 3–64 个字符。'; return 0; }
                NAIVE_USERNAME=$new_username
            fi
            ask_secret 'NaiveProxy 密码（留空保持；输入 - 随机生成）'
            new_secret=$(trim_value "$REPLY")
            if [ "$new_secret" = '-' ]; then new_secret=$(openssl rand -hex 24); fi
            if [ -n "$new_secret" ]; then
                case "$new_secret" in *[!A-Za-z0-9._~-]*) warn '密码只允许字母、数字、点、下划线、波浪线和短横线。'; return 0 ;; esac
                [ "${#new_secret}" -ge 8 ] && [ "${#new_secret}" -le 128 ] || { warn '密码长度必须为 8–128 个字符。'; return 0; }
                NAIVE_PASSWORD=$new_secret
            fi
            ;;
        5)
            ask_secret '新的 AnyTLS + Reality 密码（留空保持；输入 - 随机生成）'
            new_secret=$(trim_value "$REPLY")
            if [ "$new_secret" = '-' ]; then new_secret=$(openssl rand -hex 24); fi
            if [ -n "$new_secret" ]; then
                case "$new_secret" in *[!A-Za-z0-9._~-]*) warn '密码只允许字母、数字、点、下划线、波浪线和短横线。'; return 0 ;; esac
                [ "${#new_secret}" -ge 8 ] && [ "${#new_secret}" -le 128 ] || { warn '密码长度必须为 8–128 个字符。'; return 0; }
                ANYREALITY_PASSWORD=$new_secret
            fi
            ask_value '是否重新生成 AnyTLS + Reality 密钥对和 Short ID？(y/N)' 'n'
            case "$REPLY" in
                y|Y|yes|YES)
                    pair=$($SB_BIN generate reality-keypair)
                    new_private=$(printf '%s\n' "$pair" | awk '/PrivateKey/ {print $2}')
                    new_public=$(printf '%s\n' "$pair" | awk '/PublicKey/ {print $2}')
                    new_sid=$($SB_BIN generate rand --hex 8)
                    [ -n "$new_private" ] && [ -n "$new_public" ] && [ -n "$new_sid" ] || { warn 'AnyTLS + Reality 密钥生成失败。'; return 0; }
                    ANYREALITY_PRIVATE=$new_private; ANYREALITY_PUBLIC=$new_public; ANYREALITY_SID=$new_sid
                    msg 'AnyTLS + Reality 密钥已轮换；客户端必须更新公钥和 Short ID。'
                    ;;
            esac
            ;;
        *) warn '未知协议。'; return 0 ;;
    esac

    if ! build_config; then
        load_state
        derive_runtime_needs
        warn '新参数未能通过配置检查或服务启动检查；已恢复原配置。'
        return 0
    fi
    show_nodes
}

remove_cloudflared_local_service() {
    if [ "$SERVICE_KIND" = systemd ]; then
        systemctl disable --now "$CLOUDFLARED_SERVICE" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$CLOUDFLARED_SERVICE.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
    elif [ "$SERVICE_KIND" = openrc ]; then
        rc-service "$CLOUDFLARED_SERVICE" stop >/dev/null 2>&1 || true
        rc-update del "$CLOUDFLARED_SERVICE" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/$CLOUDFLARED_SERVICE"
    fi
    rm -f "$CLOUDFLARED_RUN" "$ARGO_TOKEN_FILE"
}

remove_protocol() {
    need_root
    removed_argo=0
    load_state
    derive_runtime_needs
    msg '========== 删除已安装协议 =========='
    printf '1. AnyTLS              %s\n' "$([ "$ENABLE_ANYTLS" = 1 ] && printf 已安装 || printf 未安装)"
    printf '2. VLESS WS TLS 直连   %s\n' "$([ "$ENABLE_WS_TLS" = 1 ] && printf 已安装 || printf 未安装)"
    printf '3. VLESS + Reality     %s\n' "$([ "$ENABLE_VLESS_REALITY" = 1 ] && printf 已安装 || printf 未安装)"
    printf '4. NaiveProxy          %s\n' "$([ "$ENABLE_NAIVE" = 1 ] && printf 已安装 || printf 未安装)"
    printf '5. AnyTLS + Reality    %s\n' "$([ "$ENABLE_ANYTLS_REALITY" = 1 ] && printf 已安装 || printf 未安装)"
    printf '6. VLESS WS TLS Argo   %s\n' "$([ "$ENABLE_WS_ARGO" = 1 ] && printf 已安装 || printf 未安装)"
    printf '7. Shadowsocks 2022    %s\n' "$([ "$ENABLE_SS2022" = 1 ] && printf 已安装 || printf 未安装)"
    printf '0. 返回\n'
    printf '选择要删除的协议：'
    IFS= read -r remove_choice || remove_choice=0
    case "$remove_choice" in
        1) [ "$ENABLE_ANYTLS" = 1 ] || { warn 'AnyTLS 当前未安装。'; return 0; }; ENABLE_ANYTLS=0; ANYTLS_PORT=""; ANYTLS_PASSWORD="" ;;
        2) [ "$ENABLE_WS_TLS" = 1 ] || { warn '直连 WS 当前未安装。'; return 0; }; ENABLE_WS_TLS=0; WS_PORT=""; WS_UUID=""; WS_PATH=""; WS_SERVER=""; WS_HOST=""; PREFERRED_IP=""; PREFERRED_IPV6="" ;;
        6) [ "$ENABLE_WS_ARGO" = 1 ] || { warn 'Argo WS 当前未安装。'; return 0; }; ENABLE_WS_ARGO=0; removed_argo=1; ARGO_PORT=""; ARGO_UUID=""; ARGO_PATH=""; ARGO_SERVER=""; ARGO_HOST=""; ARGO_TUNNEL_NAME=""; ARGO_TOKEN="" ;;
        7) [ "$ENABLE_SS2022" = 1 ] || { warn 'Shadowsocks 2022 当前未安装。'; return 0; }; ENABLE_SS2022=0; SS2022_PORT=""; SS2022_PASSWORD="" ;;
        3) [ "$ENABLE_VLESS_REALITY" = 1 ] || { warn 'VLESS + Reality 当前未安装。'; return 0; }; ENABLE_VLESS_REALITY=0; REALITY_PORT=""; REALITY_UUID=""; REALITY_PRIVATE=""; REALITY_PUBLIC=""; REALITY_SID="" ;;
        4) [ "$ENABLE_NAIVE" = 1 ] || { warn 'NaiveProxy 当前未安装。'; return 0; }; ENABLE_NAIVE=0; NAIVE_PORT=""; NAIVE_USERNAME=""; NAIVE_PASSWORD="" ;;
        5) [ "$ENABLE_ANYTLS_REALITY" = 1 ] || { warn 'AnyTLS + Reality 当前未安装。'; return 0; }; ENABLE_ANYTLS_REALITY=0; ANYREALITY_PORT=""; ANYREALITY_PASSWORD=""; ANYREALITY_PRIVATE=""; ANYREALITY_PUBLIC=""; ANYREALITY_SID="" ;;
        0) return 0 ;;
        *) warn '无效选择。'; return 0 ;;
    esac

    remaining_protocols=$((ENABLE_ANYTLS + ENABLE_WS_TLS + ENABLE_WS_ARGO + ENABLE_VLESS_REALITY + ENABLE_NAIVE + ENABLE_ANYTLS_REALITY + ENABLE_SS2022))
    if [ "$remaining_protocols" -eq 0 ]; then
        load_state
        derive_runtime_needs
        warn '不能删除最后一个协议。若要移除整个 sing-box 安装，请使用菜单 11 或执行 sb-manager uninstall。'
        return 0
    fi
    if [ "$ENABLE_VLESS_REALITY" = 0 ] && [ "$ENABLE_ANYTLS_REALITY" = 0 ]; then REALITY_SNI=www.bing.com; fi
    msg '即将只删除所选协议；其他协议的 UUID、密码、密钥、端口和证书配置保持不变。'
    ask_value '确认删除？输入 DELETE 继续' ''
    [ "$REPLY" = DELETE ] || { load_state; derive_runtime_needs; msg '已取消删除。'; return 0; }
    if ! build_config; then
        load_state
        derive_runtime_needs
        warn '删除未能通过配置检查或服务重启检查；已恢复原协议状态。'
        return 0
    fi
    if [ "${removed_argo:-0}" -eq 1 ]; then
        remove_cloudflared_local_service
        msg '已停止并移除本机 Cloudflare Tunnel 服务和 Token 文件；Cloudflare 控制台中的 Tunnel / DNS 路由不会被删除。'
    fi
    derive_runtime_needs
    show_nodes
    msg '协议删除完成。'
}

edit_selected_protocol() {
    need_root
    load_state
    derive_runtime_needs
    msg '========== 选择协议并修改参数 =========='
    printf '1. AnyTLS              %s\n' "$([ "$ENABLE_ANYTLS" = 1 ] && printf 已安装 || printf 未安装)"
    printf '2. VLESS WS TLS 直连   %s\n' "$([ "$ENABLE_WS_TLS" = 1 ] && printf 已安装 || printf 未安装)"
    printf '3. VLESS + Reality     %s\n' "$([ "$ENABLE_VLESS_REALITY" = 1 ] && printf 已安装 || printf 未安装)"
    printf '4. NaiveProxy          %s\n' "$([ "$ENABLE_NAIVE" = 1 ] && printf 已安装 || printf 未安装)"
    printf '5. AnyTLS + Reality    %s\n' "$([ "$ENABLE_ANYTLS_REALITY" = 1 ] && printf 已安装 || printf 未安装)"
    printf '6. VLESS WS TLS Argo   %s\n' "$([ "$ENABLE_WS_ARGO" = 1 ] && printf 已安装 || printf 未安装)"
    printf '7. Shadowsocks 2022    %s\n' "$([ "$ENABLE_SS2022" = 1 ] && printf 已安装 || printf 未安装)"
    printf '0. 返回\n'
    printf '选择要修改的协议：'
    IFS= read -r selected_protocol || selected_protocol=0
    case "$selected_protocol" in
        1) [ "$ENABLE_ANYTLS" = 1 ] || { warn 'AnyTLS 当前未安装。'; return 0; } ;;
        2) [ "$ENABLE_WS_TLS" = 1 ] || { warn '直连 WS 当前未安装。'; return 0; } ;;
        6) [ "$ENABLE_WS_ARGO" = 1 ] || { warn 'Argo WS 当前未安装。'; return 0; } ;;
        7) [ "$ENABLE_SS2022" = 1 ] || { warn 'Shadowsocks 2022 当前未安装。'; return 0; } ;;
        3) [ "$ENABLE_VLESS_REALITY" = 1 ] || { warn 'VLESS + Reality 当前未安装。'; return 0; } ;;
        4) [ "$ENABLE_NAIVE" = 1 ] || { warn 'NaiveProxy 当前未安装。'; return 0; } ;;
        5) [ "$ENABLE_ANYTLS_REALITY" = 1 ] || { warn 'AnyTLS + Reality 当前未安装。'; return 0; } ;;
        0) return 0 ;;
        *) warn '无效选择。'; return 0 ;;
    esac

    print_protocol_field_guide "$selected_protocol"
    while :; do
        printf '\n---------- 协议参数修改 ----------\n'
        printf '1. 修改 SNI / TLS 证书域名\n'
        printf '2. 修改连接地址 / WS 优选 IP\n'
        printf '3. 修改 Cloudflare 绑定域名 / Tunnel Public Hostname\n'
        printf '4. 修改该协议端口\n'
        printf '5. 修改该协议专属必填值 / 可选值 / 凭据\n'
        printf '0. 返回协议列表\n'
        printf '请选择：'
        IFS= read -r edit_choice || edit_choice=0
        case "$edit_choice" in
            1)
                case "$selected_protocol" in
                    1|4) change_tls_sni ;;
                    2) change_tls_sni ;;
                    6) change_argo_binding ;;
                    3|5) change_reality_sni ;;
                    7) msg 'Shadowsocks 2022 不使用 TLS 证书或 SNI。' ;;
                esac
                ;;
            2)
                case "$selected_protocol" in 2) change_preferred_ip ;; 6) change_argo_address ;; *) change_origin_addresses ;; esac
                ;;
            3)
                if [ "$selected_protocol" = 6 ]; then
                    change_argo_binding
                elif [ "$CERT_MODE" = cloudflare ] && { [ "$selected_protocol" = 1 ] || [ "$selected_protocol" = 4 ] || [ "$selected_protocol" = 2 ]; }; then
                    change_cloudflare_zone
                else
                    warn '当前协议没有可编辑的 Cloudflare 域名绑定：Argo WS 修改 Public Hostname；DNS-01 TLS 协议修改 Cloudflare Zone / 证书域名。'
                fi
                ;;
            4) change_single_port "$selected_protocol" ;;
            5) change_protocol_extra_settings "$selected_protocol" ;;
            0) return 0 ;;
            *) warn '无效选项。' ;;
        esac
        load_state
        derive_runtime_needs
    done
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
    printf '%s\n' '将删除：/etc/sing-box、/usr/local/sbin/sb-manager、sing-box 服务文件、Argo 专用 cloudflared 服务及本脚本安装的软件包/二进制。'
    printf '%s\n' '不会删除：/root/.acme.sh、系统依赖包、系统防火墙规则、云厂商安全组或其他 cron 任务。'
    printf '%s\n' '卸载将直接继续执行；请确认当前连接的是正确的 VPS。'
    cf_managed=0; [ ! -f "$APP_DIR/cloudflared-managed" ] || cf_managed=1
    msg '正在停止 sing-box / Cloudflare Tunnel 服务……'
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$CLOUDFLARED_SERVICE" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$CLOUDFLARED_SERVICE.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$CLOUDFLARED_SERVICE" stop >/dev/null 2>&1 || true
        rc-update del "$CLOUDFLARED_SERVICE" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/$CLOUDFLARED_SERVICE"
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
    rm -rf "$APP_DIR"
    [ "$cf_managed" -eq 0 ] || rm -f "$CLOUDFLARED_BIN"
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
        if [ "$ENABLE_WS_ARGO" = 1 ]; then journalctl -u "$CLOUDFLARED_SERVICE" -n 80 --no-pager || true; fi
    else
        tail -n 80 /var/log/messages 2>/dev/null || true
        rc-service sing-box status || true
        if [ "$ENABLE_WS_ARGO" = 1 ]; then tail -n 80 /var/log/messages 2>/dev/null | grep -i cloudflared || true; rc-service "$CLOUDFLARED_SERVICE" status || true; fi
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
        printf '\n直连 WS HTTP Host：%s' "${WS_HOST:-未设置}"
        if [ "$ENABLE_WS_ARGO" = 1 ]; then
            printf '\n固定 Tunnel：%s | Public Hostname：%s | 连接地址：%s | 本机端口：%s' "${ARGO_TUNNEL_NAME:-未命名}" "$ARGO_HOST" "$ARGO_SERVER" "$ARGO_PORT"
        fi
        [ "$ENABLE_SS2022" = 0 ] || printf '\nShadowsocks 2022：%s/tcp + udp' "$SS2022_PORT"
        printf '\nReality SNI（VLESS Reality + AnyTLS Reality；默认 www.bing.com）：%s' "$REALITY_SNI" 
        printf '\n节点辨识符：%s' "${NODE_LABEL:-未设置}"
        printf '\n端口：AnyTLS %s | WS TLS %s | VLESS Reality %s | NaiveProxy %s/TCP | AnyTLS Reality %s' "$ANYTLS_PORT" "$WS_PORT" "$REALITY_PORT" "$NAIVE_PORT" "$ANYREALITY_PORT"
        printf '\n---------------------------------------\n'
        printf '1. 查看已安装协议节点链接\n'
        printf '2. 修改 TLS 证书域名 / TLS SNI（AnyTLS + 直连 WS + NaiveProxy）\n'
        printf '3. 修改 Reality SNI（VLESS Reality + AnyTLS Reality；新安装默认 www.bing.com）\n'
        printf '4. 修改直连 VLESS WS TLS 客户端连接地址（优选 IP/域名）\n'
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
        printf '18. 添加尚未部署的协议节点（增量添加，不影响现有节点）\n'
        printf '19. 删除已安装协议（只删除所选协议，不影响其他节点）\n'
        printf '20. 选择协议修改 SNI / WS 优选 IP / Cloudflare 域名 / 端口 / 凭据\n'
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
            16) [ "$ENABLE_WS_ARGO" = 1 ] && cloudflared_status || warn '当前未启用 Argo Tunnel。' ;;
            17) change_argo_binding ;;
            18) add_missing_protocols ;;
            19) remove_protocol ;;
            20) edit_selected_protocol ;;
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
            add|add-node|add-nodes) add_missing_protocols ;;
            *) menu ;;
        esac
    else
        case "${1:-}" in
            add|add-node|add-nodes) err '增量添加需要已有 sing-box 安装；请先完成首次安装。' ;;
            *) install_wizard ;;
        esac
    fi
}

main "$@"
