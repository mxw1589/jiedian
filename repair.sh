#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[错误] 请使用 root 运行：bash repair.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/usr/bin/sb"
PATCHER="$SCRIPT_DIR/patch_sb.py"

if [[ ! -f "$TARGET" ]]; then
  echo "[错误] 找不到 $TARGET。此工具不会安装 Sing-box-yg。" >&2
  exit 1
fi
if [[ ! -f "$PATCHER" ]]; then
  echo "[错误] 找不到 patch_sb.py。请重新解压完整 Repair Kit。" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y python3
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3
  else
    echo "[错误] 缺少 Python 3，且未识别可用包管理器。" >&2
    exit 1
  fi
fi

# Validate version and exact source anchors BEFORE installing any other packages.
echo "[1/4] 检查 Sing-box-yg 版本及补丁适用性……"
python3 "$PATCHER" --check

missing=0
for cmd in jq curl wget openssl socat busybox iptables tar expect xxd python3 qrencode git ip ss ping crontab; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing=1
    break
  fi
done

if [[ "$missing" -eq 1 ]]; then
  echo "[2/4] 检测到运行依赖缺失，开始补齐……"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
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
else
  echo "[2/4] 检查到依赖已齐全，无需安装软件包。"
fi

for cmd in jq curl wget; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[错误] 关键依赖 $cmd 仍不可用；停止修复。" >&2
    exit 1
  fi
done

echo "[3/4] 应用定点补丁（自动备份并执行语法检查）……"
python3 "$PATCHER"

echo "[4/4] 修复完成。可执行：sb"
