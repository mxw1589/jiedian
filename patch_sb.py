#!/usr/bin/env python3
# Safe, targeted repair for the upstream Sing-box-yg v26.4.11 script.
from pathlib import Path
import datetime
import os
import re
import shutil
import subprocess
import sys
import tempfile

TARGET = Path("/usr/bin/sb")
VERSION_FILE = Path("/etc/s-box/v")
EXPECTED_VERSION = "v26.4.11"

STTY_OLD = r"stty erase $'\b' 2>/dev/null || stty erase '^H' 2>/dev/null"
STTY_NEW = r"""if [[ -t 0 && -t 1 ]]; then
    stty erase $'\b' 2>/dev/null || stty erase '^H' 2>/dev/null
fi"""

# The upstream v26.4.11 script may contain zero or more blank lines between
# the first-run marker's closing `fi` and the OpenVZ branch. Match only this
# narrow structural sequence; do not skip non-blank statements or accept
# multiple candidates. This handles the exact layout reported by users:
#   touch sbyg_update
#   fi
#
#   if [[ $vi = openvz ]]; then
DEPS_ANCHOR_RE = re.compile(
    r"(?m)^(?P<prefix>[ \t]*touch[ \t]+sbyg_update[ \t]*\r?\n"
    r"[ \t]*fi[ \t]*\r?\n)"
    r"(?:[ \t]*\r?\n)*"
    r"(?P<openvz>[ \t]*if[ \t]+\[\[[ \t]*\$vi[ \t]*=[ \t]*openvz[ \t]*\]\];[ \t]*then[ \t]*\r?)$"
)

DEPS_NEW = """touch sbyg_update
fi

# BEGIN SING-BOX-YG RUNTIME DEPENDENCY SELF-HEAL
# Do not rely solely on the first-run sbyg_update marker: packages can be
# removed later, so verify critical commands on every invocation.
_sbyg_missing=0
for _sbyg_cmd in jq curl wget openssl socat busybox iptables tar expect xxd python3 qrencode git ip ss ping crontab; do
    if ! command -v "$_sbyg_cmd" >/dev/null 2>&1; then
        _sbyg_missing=1
        break
    fi
done
if [[ "$_sbyg_missing" = "1" ]]; then
    green "检测到运行依赖缺失，正在自动补齐……"
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
        red "无法识别包管理器；请手动安装 jq、curl、wget 等运行依赖。"
        exit 1
    fi
fi
for _sbyg_cmd in jq curl wget; do
    if ! command -v "$_sbyg_cmd" >/dev/null 2>&1; then
        red "关键依赖 $_sbyg_cmd 仍未安装；停止运行，避免配置读取失败。"
        exit 1
    fi
done
unset _sbyg_missing _sbyg_cmd
# END SING-BOX-YG RUNTIME DEPENDENCY SELF-HEAL

if [[ $vi = openvz ]]; then"""

ARGO_OLD = """cfargo_ym(){
tls=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[1].tls.enabled')
if [[ "$tls" = "false" ]]; then"""

ARGO_NEW = """cfargo_ym(){
# Fail clearly if jq/config is unavailable. Never interpret an empty result as TLS enabled.
if ! command -v jq >/dev/null 2>&1; then
red "缺少 jq，无法读取 VMess TLS 状态；请先安装 jq"
return 1
fi
if [[ ! -s /etc/s-box/sb.json ]]; then
red "配置文件 /etc/s-box/sb.json 不存在或为空，无法判断 VMess TLS 状态"
return 1
fi
tls=$(jq -r '.inbounds[1].tls.enabled // empty' /etc/s-box/sb.json 2>/dev/null || true)
if [[ "$tls" != "true" && "$tls" != "false" ]]; then
red "无法准确读取 VMess TLS 状态；未执行 Argo 修改，请先检查 sb.json"
return 1
fi
if [[ "$tls" = "false" ]]; then"""

MARKER = "# BEGIN SING-BOX-YG RUNTIME DEPENDENCY SELF-HEAL"

def patch_text(source: str):
    original_source = source
    is_crlf = "\r\n" in source and source.count("\n") == source.count("\r\n")
    # Normalize only in memory for matching; restore the original newline
    # convention after constructing the patch. No on-disk file is touched here.
    if is_crlf:
        source = source.replace("\r\n", "\n")

    if MARKER in source:
        required = [
            "if [[ -t 0 && -t 1 ]]; then",
            "# END SING-BOX-YG RUNTIME DEPENDENCY SELF-HEAL",
            "Never interpret an empty result as TLS enabled.",
            "jq -r '.inbounds[1].tls.enabled // empty'",
        ]
        if not all(item in source for item in required):
            raise RuntimeError("检测到不完整的旧补丁；为避免重复或错误修改，已停止。")
        return original_source, False

    stty_count = source.count(STTY_OLD)
    if stty_count != 1:
        raise RuntimeError(
            f"stty 原始代码未能唯一匹配（匹配数：{stty_count}）；"
            "文件可能不是预期的 v26.4.11 结构。"
        )

    dependency_matches = list(DEPS_ANCHOR_RE.finditer(source))
    if len(dependency_matches) != 1:
        raise RuntimeError(
            "首次依赖安装区结构未能唯一匹配 "
            f"（匹配数：{len(dependency_matches)}）。"
            "补丁支持 touch sbyg_update、fi 与 OpenVZ 判断之间存在空行的布局；"
            "若仍不匹配，说明源码结构不同或被修改，已停止。"
        )

    argo_count = source.count(ARGO_OLD)
    if argo_count != 1:
        raise RuntimeError(
            f"Argo TLS 判断区未能唯一匹配（匹配数：{argo_count}）；"
            "文件可能已被修改或版本不同。"
        )

    result = source.replace(STTY_OLD, STTY_NEW, 1)
    dependency_match = DEPS_ANCHOR_RE.search(result)
    if dependency_match is None:
        raise RuntimeError("依赖区锚点在补丁过程中丢失；未写入目标文件。")
    dependency_replacement = DEPS_NEW
    result = (
        result[:dependency_match.start()]
        + dependency_replacement
        + result[dependency_match.end():]
    )
    result = result.replace(ARGO_OLD, ARGO_NEW, 1)
    if is_crlf:
        result = result.replace("\n", "\r\n")
    return result, True

def load_and_validate():
    if not TARGET.is_file():
        raise RuntimeError(f"找不到 {TARGET}；未修改任何文件。")

    if VERSION_FILE.is_file():
        installed_version = VERSION_FILE.read_text(errors="replace").strip()
        if installed_version and installed_version != EXPECTED_VERSION:
            raise RuntimeError(
                f"/etc/s-box/v 显示 {installed_version}，"
                f"本补丁仅针对 {EXPECTED_VERSION}；未修改任何文件。"
            )

    original = TARGET.read_text(encoding="utf-8", errors="strict")
    updated, changed = patch_text(original)
    return original, updated, changed


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Targeted Sing-box-yg v26.4.11 repair")
    parser.add_argument(
        "--check", action="store_true",
        help="仅检查目标版本和源代码锚点，不修改文件、不创建备份。",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        print("[错误] 请使用 root 运行。", file=sys.stderr)
        return 1

    try:
        original, updated, changed = load_and_validate()
    except Exception as exc:
        print(f"[错误] {exc}", file=sys.stderr)
        return 1

    if args.check:
        if changed:
            print("[预检通过] 目标脚本符合 v26.4.11 补丁锚点；尚未修改文件。")
        else:
            print("[预检通过] 目标脚本已包含完整补丁；无需重复修改。")
        return 0

    if not changed:
        check = subprocess.run(["bash", "-n", str(TARGET)])
        if check.returncode:
            print("[错误] 文件已带补丁标记，但 bash -n 未通过。", file=sys.stderr)
            return 1
        print("[正常] /usr/bin/sb 已应用本修复，无需重复修改。")
        return 0

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_dir = Path("/var/backups/sing-box-yg")
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup = backup_dir / f"sb.v26.4.11.before-repair.{stamp}.bak"
    shutil.copy2(TARGET, backup)

    mode = TARGET.stat().st_mode
    fd, temp_name = tempfile.mkstemp(prefix=".sb.repair.", dir=str(TARGET.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(updated)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_name, mode)
        os.replace(temp_name, TARGET)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)

    check = subprocess.run(["bash", "-n", str(TARGET)])
    if check.returncode:
        shutil.copy2(backup, TARGET)
        print("[错误] bash -n 检查失败，已从备份恢复原脚本。", file=sys.stderr)
        return 1

    print("[成功] Sing-box-yg v26.4.11 补丁已应用。")
    print(f"[备份] {backup}")
    print("[检查] bash -n 通过。")
    print("[保护] 未修改 /etc/s-box/sb.json、UUID、端口、证书或节点数据。")
    print("[说明] VMess TLS=true 时，原脚本仍按设计禁用 Argo；本补丁只修复误判。")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
