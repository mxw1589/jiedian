#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[错误] 请使用 root 运行：bash repair.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/usr/bin/sb"

if [[ ! -f "$TARGET" ]]; then
  echo "[错误] 找不到 $TARGET。未执行安装或修改。" >&2
  exit 1
fi

if [[ ! -x "$(command -v python3 2>/dev/null || true)" ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y python3
  else
    echo "[错误] 缺少 python3；请先安装 Python 3。" >&2
    exit 1
  fi
fi

missing=0
for cmd in jq curl wget openssl socat busybox iptables tar expect xxd python3 qrencode git ip ss ping crontab; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing=1
    break
  fi
done

if [[ "$missing" -eq 1 ]]; then
  echo "[信息] 检测到运行依赖缺失，开始补齐……"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y jq cron socat busybox iptables-persistent coreutils util-linux curl openssl iptables tar expect wget xxd python3 qrencode git iproute2 iputils-ping virt-what
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash jq openssl procps busybox-extras iproute2 iputils coreutils expect git socat iptables grep tar tzdata util-linux curl wget python3 qrencode
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y jq cronie socat busybox iptables-services coreutils util-linux curl openssl iptables tar expect wget xxd python3 qrencode git iproute iputils virt-what
  elif command -v yum >/dev/null 2>&1; then
    yum install -y jq cronie socat busybox iptables-services coreutils util-linux curl openssl iptables tar expect wget xxd python3 qrencode git iproute iputils virt-what
  else
    echo "[错误] 未识别的包管理器，无法自动补齐依赖。" >&2
    exit 1
  fi
fi

for cmd in jq curl wget; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[错误] 关键依赖 $cmd 仍不可用；停止修复。" >&2
    exit 1
  fi
done

python3 "$SCRIPT_DIR/patch_sb.py"
