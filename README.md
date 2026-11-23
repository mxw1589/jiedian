> 🌐 **在线打开 HTML 配置面板：** https://mxw1589.github.io/jiedian/
>
> 本版本支持按需选择协议、自动生成安装命令、Cloudflare 固定 Tunnel（Argo）、VLESS XHTTP + ECH 和 Snell。

# sing-box / Xray 多协议节点选择性安装与管理工具

> **v1.0.6 修复说明：** SS2022 成为一等托管协议，支持网页选择、端口同栏填写、终端增删改和密码轮换；接管已有 SS2022 时优先保留端口、method、password。每个协议端口输入框已移动到协议选择项右侧。Alpine / 官方 sing-box 版本识别增加兼容解析和失败诊断。

**v1.0.2 修复说明：** Snell / XHTTP 添加节点时，端口输入不再放在命令替换子 Shell 中执行，而是在当前交互 Shell 读取。若 SSH 输入流中断，会安全取消，不会把 EOF 当作空输入而误触发自动分配。留空（正常按 Enter）才会自动分配端口。

适用于 Debian / Ubuntu / Alpine 的 sing-box + Xray 安装脚本和静态网页配置面板。当前版本 v1.0.6。无需安装全部协议；只勾选需要的协议，网页会根据选择启用相关字段、禁用无关字段，并在填写完成后自动更新一键安装命令。

## 项目文件

```text
jiedian/
├── index.html
├── README.md
└── sb-manager-debian-alpine.sh
```

- `index.html`：静态配置面板，可发布到 GitHub Pages。
- `README.md`：安装、Argo Tunnel 配置、管理和卸载说明。
- `sb-manager-debian-alpine.sh`：Debian / Ubuntu / Alpine 安装及管理脚本（sing-box + 独立 Xray-core）。
- `tests/test-added-port-input.sh`：端口交互回归测试（手动端口、自动分配、EOF 安全取消）。
- `tests/test-config-preservation.sh`：配置合并回归测试（SS2022、outbounds、route、DNS 自定义配置保留及接管）。
- `tests/test-version-parser.sh`：sing-box 上游 / Alpine 版本输出解析测试。

## 功能简介

### 选择性安装

支持以下八种协议，可任意单选或多选：

| 协议 | 源站 TLS 证书 | NAT 公网入站 | 参数要求 |
|---|---|---|---|
| AnyTLS | 需要 | 需要 TCP 映射 | TLS 域名、证书方式；Cloudflare DNS-01 还需要 DNS API Token |
| VLESS + WebSocket | 视接入方式而定 | Argo 模式不需要；直连模式需要 | Argo：Tunnel 主机名和 Tunnel Token；直连：TLS 域名和证书 |
| VLESS + Reality | 不需要 | 需要 TCP 映射 | Reality SNI；源站地址可由 VPS 自动检测 |
| NaiveProxy | 需要 | 需要 TCP 映射 | TLS 域名、证书方式；Cloudflare DNS-01 还需要 DNS API Token |
| AnyTLS + Reality | 不需要 | 需要 TCP 映射 | Reality SNI；源站地址可由 VPS 自动检测 |
| VLESS + XHTTP + ECH | 需要 | 需要 TCP 映射 / NAT 端口映射 | TLS 域名、证书；ECH Public Name；XHTTP 模式 / Path |
| Snell v5 / v6 | 不需要 | 需要 TCP 映射 | v5 HTTP 混淆或 v6 流量整形；PSK / UserKey 自动生成 |
| Shadowsocks 2022 | 不需要 | 需要 TCP 映射 | AES-128-GCM / AES-256-GCM；密钥按方法自动生成 |

不需要的字段会在网页中隐藏或禁用，不会写入最终配置。未选择的协议不会创建入站、分配端口或生成节点链接。

### 网页配置面板

- 协议选择变化时，相关输入项立即启用/禁用；每个协议的 TCP 端口输入框紧邻对应协议选择项，留空自动分配。
- 固定 Argo Tunnel / 直连 WS 模式可切换；Tunnel 备注名只用于本机显示，不改变 Cloudflare 中的 Tunnel 身份。
- 只有所选协议需要的 TLS 域名、证书、Reality SNI、Tunnel Token 和端口输入项才会启用。
- **安装命令随表单输入自动生成，不需要点击“生成命令”。**
- 端口留空由 VPS 自动分配；只为启用的协议分配端口。端口输入框位于每个协议选择项右侧。
- 支持导出不含 Token 的配置 JSON。
- 页面是静态前端，表单内容只在当前浏览器处理，不会自动上传到 GitHub Pages。

### 服务端脚本

- 支持 Debian / Ubuntu 和 Alpine，使用 systemd 或 OpenRC。
- Debian / Ubuntu 使用 SagerNet 官方 APT 源安装/升级 sing-box；Alpine 直接使用 SagerNet 官方 GitHub Releases 最新稳定版。项目最低要求 sing-box `1.13.0`，选择 Snell 时要求 `1.14.0` 或更新版本。
- Snell v5 / v6 由 sing-box 原生 inbound 提供，PSK 和 UserKey 在服务器本机生成。
- Shadowsocks 2022 由 sing-box 原生 shadowsocks inbound 提供，支持 `2022-blake3-aes-128-gcm` 和 `2022-blake3-aes-256-gcm`；密码在服务器生成并以 0600 权限保存在 manager.json。
- VLESS XHTTP + ECH 使用独立 Xray-core，独立配置、服务、日志和 ECH 密钥；不会把 XHTTP 伪装成 sing-box WS。
- Xray-core 从官方 GitHub Releases 下载；若 GitHub API 提供 SHA-256 digest，则安装前校验下载包。
- 只创建所选协议的 sing-box inbound；XHTTP 则只创建独立 Xray inbound。
- 支持 Cloudflare DNS-01、HTTP-01 和手动证书（交互式安装）。
- 支持 Cloudflare **固定 Tunnel（Argo）** 承载 VLESS + WebSocket：使用 Cloudflare Zero Trust 中创建的 remotely-managed Tunnel 和固定 Tunnel Token，不使用临时 Quick Tunnel；VPS 本机只监听 `127.0.0.1`，由 `cloudflared` 主动连接 Cloudflare。
- `cloudflared` 作为独立 systemd / OpenRC 服务运行；使用 `2025.4.0` 或更新版本的 `--token-file` 功能读取权限受限的 `/etc/sing-box/cloudflared.token`，避免把 Tunnel Token 放在进程命令行中，也不会写入公开节点链接。
- 管理菜单支持查看固定 Tunnel 信息，以及轮换 / 更换 Tunnel Token；Token 原子写入、权限设为 `0640 root:sing-box`，不写入 `manager.json`。
- 支持 IPv4 / IPv6 源站地址自动检测；Argo-only 安装不需要填写源站公网 IP。
- 端口冲突时自动更换可用端口；配置检查或服务重启失败时尝试回滚。
- 管理菜单支持单个协议修改端口、批量修改端口、查看节点、日志、固定 Tunnel 状态、Tunnel Token 轮换、BBR 状态和卸载。
- 菜单 `23` 提供统一终端协议管理：对脚本支持的 AnyTLS、VLESS WS/Argo、VLESS Reality、NaiveProxy、AnyTLS Reality、VLESS XHTTP + ECH、Snell、Shadowsocks 2022 执行增量添加、删除和参数修改。
- 每次重建 sing-box 配置时保留所有非 sb-manager 管理的 inbound/outbound 和额外顶层配置；例如自定义 SS2022 入站的端口、method、password 不会因添加/删除 Snell 而被清除。通过终端首次接管单个旧 SS2022 入站时，会导入原端口、method 和密码，避免重复创建。若旧 config.json 无法解析，脚本会停止操作而不是覆盖。
- `sb-manager` 可在已有安装上增量添加 / 移除 XHTTP + ECH 和 Snell，不会重置现有协议凭据。
- XHTTP ECH Server Keys 和客户端 ECH Config List 分开保存；ECH 轮换后会重新生成客户端配置。

## 网页生成命令会自动安装对应协议核心

无需先手动执行 `prepare-core`。网页生成的一键命令会自动完成两个阶段：

1. **核心阶段**：读取本次勾选的协议，安装/升级 sing-box、系统依赖和 cron/cronie；若勾选 VLESS + XHTTP + ECH，则同时安装独立 Xray-core。
2. **协议阶段**：核心版本检查通过后，再申请/检查证书、生成协议配置、写入节点信息并启动服务。

生成命令执行期间会显示“第一阶段：预装本次所选协议的核心”和“第二阶段：安装证书、协议配置和节点服务”。任一核心安装或版本检查失败都会停止，不会继续写入新协议配置。原有手动 `prepare-core` 命令仍可用于提前单独准备环境。

## 核心前置环境分阶段安装（推荐）

如果你希望先把所需核心和系统依赖安装好，再通过网页命令部署协议，可以先执行核心预装阶段。该阶段不会创建代理入站，也不会覆盖现有 `config.json` / `manager.json`。

**仅预装 sing-box 和系统依赖：**

```bash
curl -fsSL 'https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh' -o /tmp/sb-manager-debian-alpine.sh
sh -n /tmp/sb-manager-debian-alpine.sh || exit 1
sh /tmp/sb-manager-debian-alpine.sh prepare-core
```

**如果后续还要部署 VLESS + XHTTP + ECH，同时预装 Xray-core：**

```bash
sh /tmp/sb-manager-debian-alpine.sh prepare-core --xhttp
```

核心预装行为：

- Debian / Ubuntu：安装基础依赖、cron，并配置 SagerNet 官方 APT 源，安装/升级该源当前最新稳定版 sing-box。
- Alpine：安装基础依赖、cronie，并从 SagerNet 官方 GitHub Releases 获取最新稳定版 sing-box 二进制，避免旧 APK 包导致 NaiveProxy / Snell 版本不足。
- `--xhttp`：额外下载并安装 Xray-core 官方最新稳定版；此阶段不启动 Xray 服务、不创建节点配置。
- 安装后会显示 sing-box 版本和实际二进制路径。版本解析失败或低于项目最低要求时立即停止，不会继续写入协议配置。
- cron / cronie 会被安装并启用，供后续 acme.sh 自动续期使用。

核心预装成功后，再打开网页选择协议并运行网页生成的安装命令。正式安装阶段会再次检查核心版本和依赖；已安装的最新版会复用或按官方源升级，然后才生成证书、节点配置和服务。

## 一、不通过 HTML 直接安装

SSH 登录目标 VPS，以 `root` 身份执行下面命令。脚本会进入交互式向导，先让你选择需要安装的协议，然后只询问这些协议需要的参数。

```bash
set -eu
if [ "$(id -u)" -ne 0 ]; then
  echo '请先以 root 身份登录，或先执行 sudo -i。'
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  if [ -f /etc/alpine-release ]; then
    apk add --no-cache curl
  elif [ -f /etc/debian_version ]; then
    apt-get update
    apt-get install -y curl
  else
    echo '仅支持 Debian / Ubuntu 和 Alpine。'
    exit 1
  fi
fi
curl -fsSL 'https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh' -o /tmp/sb-manager-debian-alpine.sh
chmod 700 /tmp/sb-manager-debian-alpine.sh
/tmp/sb-manager-debian-alpine.sh
```

交互式安装的顺序：

1. 选择 AnyTLS、VLESS + WS、VLESS Reality、NaiveProxy、AnyTLS + Reality、VLESS XHTTP + ECH、Snell、Shadowsocks 2022 中需要的协议。
2. 如果选择 VLESS + WS，选择直连 TLS 或 Cloudflare 固定 Tunnel（Argo）。
3. 固定 Tunnel 模式填写 Public Hostname、可选的本机备注名和 Tunnel Token；不询问源站证书。
4. 选择 XHTTP + ECH 时填写 ECH Public Name 和 XHTTP 模式；需要为 TLS 域名签发证书。ECH Public Name 默认 `cloudflare-ech.com`。
5. 选择 Snell 时选择 v5 或 v6；PSK 和 UserKey 自动生成。v5 默认 HTTP 混淆。
6. 只有选择普通 AnyTLS、NaiveProxy、直连 WS 或 XHTTP 时，才询问源站 TLS 证书域名和证书方式。
7. 只有选择 Reality 协议时，才询问 Reality SNI。
8. 只询问已选择协议的端口。留空时自动分配。

安装完成后，管理命令为：

```bash
/usr/local/sbin/sb-manager
```

## 二、通过 HTML 自动生成安装命令

1. 打开 [sing-box 在线配置面板](https://mxw1589.github.io/jiedian/)。
2. 勾选需要安装的协议。默认预选 VLESS + WebSocket + Argo，可按需取消或增加协议。
3. 选择 WS 接入方式：NAT VPS 使用 Cloudflare 固定 Tunnel（Argo）；有可用公网入站和源站证书时才考虑直连 TLS。
4. 根据当前选择填写已启用的字段。未选择协议对应的输入框会禁用；不需要证书的组合不会要求填写证书域名或 DNS API Token。
5. 表单完整后，安装命令自动显示在“自动生成的一键安装命令”区域。无需点击生成按钮。
6. 点击“复制自动生成的安装命令”，以 root 登录目标 VPS，将命令粘贴到 SSH 终端执行。

网页命令会携带 Base64 编码的 JSON 配置。Base64 不是加密；命令中可能包含 Cloudflare DNS API Token 或 Tunnel Token。不要公开分享命令、截图或提交到 GitHub。

如果 VPS 已经存在本脚本的有效安装，网页安装入口会执行覆盖升级并保留原有节点凭据和配置，不会使用网页新参数覆盖现有节点。已安装节点需要更换固定 Tunnel Token 时，请使用管理菜单 `17`；XHTTP / Snell 可使用菜单 `18` / `19`，也可从菜单 `23` 统一管理全部脚本支持的协议。

## 三、v1.0.4：SS2022 托管与端口界面调整（历史版本说明）

### SS2022 和自定义配置保留

- 添加、删除或修改 Snell / 其他脚本协议时，脚本会把当前 `config.json` 中非 sb-manager 管理的 inbound 原样合并回候选配置。因此手动添加的 Shadowsocks 2022 inbound（包括 `listen_port`、`method`、`password`、用户字段等）不会被覆盖。
- 非管理的 outbounds，以及 `route`、`dns` 等其他顶层配置也会保留。
- 旧配置中的脚本托管 inbound 会由当前管理器生成的版本替换，避免重复监听或重复 tag。
- 如果旧 `config.json` 不是有效 JSON，管理器会停止修改并保留原文件，不会继续生成一个缺少自定义节点的新配置。
- `manager.json` 中当前版本不认识的扩展字段也会保留；当前管理器拥有的字段以本次配置为准。
- SS2022 已成为正式托管协议：菜单 23 可添加、删除和修改；若检测到单个旧 SS2022 inbound，首次接管会导入原端口、method 和 password。多个旧 SS2022 inbound 时会停止并提示手动处理，避免误接管。

### 终端菜单 23：全协议添加 / 删除 / 修改

执行 `/usr/local/sbin/sb-manager`，选择 `23`，然后选择协议。脚本支持的八种协议均可通过终端管理：

| 协议 | 添加 | 删除 | 修改 |
|---|---|---|---|
| AnyTLS | 自动生成凭据和端口；复用已有 TLS 证书 | 支持 | 修改密码；端口用菜单 7 / 15 |
| VLESS + WS / Argo | 自动生成 UUID、Path 和端口；直连模式复用证书 | 支持 | 修改 Path；端口用菜单 7 / 15 |
| VLESS + Reality | 自动生成 UUID、Reality 密钥和端口 | 支持 | 修改 UUID；端口用菜单 7 / 15 |
| NaiveProxy | 自动生成用户名、密码和端口；复用已有 TLS 证书 | 支持 | 修改密码；端口用菜单 7 / 15 |
| AnyTLS + Reality | 自动生成密码、Reality 密钥和端口 | 支持 | 修改密码；端口用菜单 7 / 15 |
| VLESS XHTTP + ECH | 调用独立 Xray 安装流程 | 支持 | 修改 XHTTP Mode / Path / ECH Public Name，或轮换 ECH Key |
| Snell v5 / v6 | 自动生成 PSK、UserKey 和端口 | 支持 | 修改版本、混淆 / traffic shaping、PSK、UserKey |
| Shadowsocks 2022 | 自动生成 AES-128/256 对应 Base64 密钥和端口；可接管单个旧 SS2022 | 支持 | 修改 method、password、port |

添加时如果端口输入留空，会自动选择空闲端口。网页中每种协议的端口输入框均放在该协议选择项右侧，不再需要滚动到独立端口区域。需要 TLS 证书的协议在证书不存在时会拒绝添加，不会伪造证书或破坏现有节点。每次变更均先做配置校验；校验或服务重启失败时回滚原配置。

**部署 v1.0.6 脚本：** 将 ZIP 内 `sb-manager-debian-alpine.sh` 上传并覆盖 GitHub 仓库同名文件后，在 VPS 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh' -o /tmp/sb-manager.new
sh -n /tmp/sb-manager.new || exit 1
install -m 700 /tmp/sb-manager.new /usr/local/sbin/sb-manager
/usr/local/sbin/sb-manager
```

也可以先将现有配置备份：

```bash
cp -a /etc/sing-box/config.json /etc/sing-box/config.json.before-v1.0.6
cp -a /etc/sing-box/manager.json /etc/sing-box/manager.json.before-v1.0.6
```

## 三、VLESS + XHTTP + ECH 与 Snell

### 1. VLESS + XHTTP + ECH

本项目使用独立 Xray-core 运行该节点，避免 sing-box 与 Xray 的传输层配置混用。

- Xray 服务：`xray`（systemd）或 OpenRC 同名服务。
- 服务配置：`/etc/xray/config.json`。
- ECH Server Keys：`/etc/sing-box/xray-ech-server-keys`（仅服务器使用，权限受限）。
- ECH Config List：`/etc/sing-box/xray-ech-config-list`（提供给客户端）。
- 完整 Xray 客户端配置：`/etc/sing-box/xray-xhttp-client.json`。
- 节点分享链接：由 `sb-manager` 输出，但分享 URI 本身不包含 ECH Config List；若要真正启用 ECH，应导入生成的完整客户端 JSON，或在支持 ECH 的客户端中手动填入 ECH Config List。

**DNS / 网络要求：**

1. TLS 域名的 A / AAAA 记录解析到 VPS 公网地址（NAT VPS 则解析到服务商提供的公网入口）。
2. 域名使用 Cloudflare 时必须设为 **DNS Only（灰云）**，让客户端 TLS / ECH 直接到达 Xray。普通 Cloudflare 橙云代理会在边缘终止 TLS，不适合直接使用本机生成的 ECH Server Keys。
3. 放行服务器端 XHTTP TCP 端口，并在 NAT 服务商配置相同的公网 TCP 端口映射。
4. TLS 证书的域名是客户端内层 SNI；ECH Public Name 是外层 ClientHello 暴露的公开名称，两者不是同一个字段。默认 Public Name 为 `cloudflare-ech.com`，可以按需修改。
5. 本脚本使用静态 ECH Config List 写入 Xray 客户端 JSON，不会自动创建 DNS HTTPS / SVCB 记录。

**客户端：**

- 优先导入 `/etc/sing-box/xray-xhttp-client.json` 到支持 Xray-core 与 ECH 的客户端。
- 若使用分享链接导入，需要额外把 `/etc/sing-box/xray-ech-config-list` 的内容填入客户端 TLS ECH Config List 字段；仅导入普通 VLESS XHTTP URI 不会自动启用 ECH。
- 客户端必须支持 XHTTP 和 TLS ECH；不支持 ECH 的客户端只能使用不带 ECH 的普通 TLS 连接（服务器仍允许非 ECH TLS，除非客户端策略强制 ECH）。

### 2. Snell v5 / v6

Snell 入站由 sing-box `1.14.0` 或更新版本提供，不会安装第二个 Snell 服务。

- v5：默认推荐，HTTP 混淆默认开启；sing-box 客户端使用 v4 outbound（sing-box 服务端 v5 与 v4 的 TCP 线路兼容；v5 QUIC Proxy 不由 sing-box 实现）。
- v6：使用 traffic shaping；客户端也必须明确支持 Snell v6。默认 `mode=default`。
- PSK 和 UserKey 由服务器随机生成，不需要在网页输入。
- 服务端节点信息会显示地址、端口、版本、PSK 和 UserKey。
- sing-box 客户端 outbound 配置片段保存在 `/etc/sing-box/snell-client.json`。将该 outbound 对象合并到客户端 sing-box 配置的 `outbounds` 数组中。
- Snell 需要公网 TCP 入站；NAT VPS 需要配置服务商端口映射及云安全组 / 系统防火墙。

### 3. 在已有 sb-manager 上增量添加和管理

运行：

```bash
/usr/local/sbin/sb-manager
```

- `18`：添加 / 移除 VLESS XHTTP + ECH；已安装时可轮换 ECH 密钥。
- `19`：添加 / 移除 Snell。
- `20`：重新生成 XHTTP ECH 密钥，并更新客户端 JSON。轮换后旧 ECH Config 不再匹配，必须重新导入客户端配置。
- `21`：查看 Xray 服务状态。
- `22`：查看 Xray 最近日志。
- `23`：统一管理全部八种脚本支持的协议。选择协议后，已安装节点可修改参数或删除；未安装节点可添加。基础 AnyTLS、VLESS WS、VLESS Reality、NaiveProxy、AnyTLS Reality 会自动生成凭据；需要证书的协议会复用已有证书，证书缺失时拒绝添加并提示先完成证书配置。XHTTP 和 Snell 调用各自完整的安装/删除/修改流程；SS2022 可单独修改加密方式、密码及端口。

修改端口仍使用菜单 `7`（单节点）或 `15`（批量）。`rotate` 可在支持的凭据输入项中重新生成随机凭据。

添加 XHTTP 时，如果当前已有匹配的 TLS 证书，会优先复用；否则会引导选择 Cloudflare DNS-01、HTTP-01 或手动证书。添加 Snell 时会检查 sing-box 版本，不足时提示升级。

## 四、NAT VPS 使用 Cloudflare Tunnel（Argo）为 VLESS + WS 接入

### 为什么 NAT VPS 使用 Argo

普通 VLESS + WS + TLS 直连方案要求 Cloudflare 边缘支持客户端访问的公网端口，而且 NAT 服务商还必须把公网端口正确映射到 VPS 内部监听端口。若 NAT 服务商只分配了 `52053 → 2053` 这样的端口映射，Cloudflare 普通橙云不支持任意 `52053` HTTPS 代理端口，因此不能直接把该公网端口当作 Cloudflare 优选 IP 入口。

Cloudflare Tunnel 的连接方向不同：VPS 上的 `cloudflared` 主动向 Cloudflare 建立出站连接，Cloudflare 再将客户端 HTTPS / WebSocket 请求转发到 VPS 的本机 HTTP WebSocket 入站。Argo 模式下，VLESS + WS 客户端使用 Cloudflare HTTPS 边缘端口 `443`，而 VPS 内部 WS 端口只供 `cloudflared` 回源使用，不需要 NAT 公网端口映射。

官方说明：

- [Cloudflare Tunnel 入门与发布应用](https://developers.cloudflare.com/tunnel/get-started/)
- [Tunnel Token](https://developers.cloudflare.com/tunnel/reference/tunnel-tokens/)
- [Tunnel 运行参数（`--token-file` 要求 2025.4.0+）](https://developers.cloudflare.com/tunnel/reference/run-parameters/)
- [Tunnel 路由概念](https://developers.cloudflare.com/tunnel/concepts/routing/)
- [Cloudflare Tunnel 网络连接要求](https://developers.cloudflare.com/tunnel/troubleshooting/)

### 1. 在 Cloudflare 创建固定 Tunnel

1. 登录 Cloudflare Zero Trust 控制台。
2. 打开 **Networks → Tunnels**（部分界面显示为 Networks → Connectors → Cloudflare Tunnels）。
3. 点击 **Create Tunnel**，选择 Cloudflared，创建一个 remotely-managed 固定 Tunnel。不要选择临时 Quick Tunnel；Quick Tunnel 使用临时 `trycloudflare.com` 域名，不适合固定节点。
4. 选择 Linux 对应系统和 CPU 架构，进入安装步骤。
5. 不必直接执行页面给出的安装命令；只复制其中 `--token` 后面的完整长字符串。该字符串通常以 `eyJ` 开头，就是 Tunnel Token。
6. 保留 Tunnel 页面，稍后添加 Public Hostname 路由。Tunnel Token 绑定这个固定 Tunnel；同一 Token 重启后仍连接原 Tunnel。

Tunnel Token 和 Cloudflare DNS API Token 是两种不同凭据：

- **Tunnel Token**：让 VPS 上的 `cloudflared` 连接到这个 Tunnel。
- **DNS API Token**：只在安装 AnyTLS、NaiveProxy 或直连 WS 等需要源站证书的协议，并选择 DNS-01 自动签发时使用。

Argo-only 的 VLESS + WS 安装只需要 Tunnel Token，不需要源站证书，也不需要 DNS API Token。

### 2. 在 HTML 选择 Argo 模式

1. 勾选 **VLESS + WebSocket**。
2. WS 接入方式选择 **Cloudflare Tunnel（Argo）**。
3. 填写 Argo 公网主机名，例如 `ws.example.com`。该主机名必须属于你拥有或获准管理、并已接入 Cloudflare 的域名区域。
4. 可填写一个本机备注名，便于在管理菜单中区分 VPS；该备注不等于 Cloudflare Tunnel ID。
5. 填写刚才复制的固定 Tunnel Token。
6. 客户端连接地址可以留空，默认使用 `ws.example.com`。如果你有经过实际线路测试的 Cloudflare 优选 IP 或优选域名，可以填在这里；该字段只改变客户端连接目标，不会改变 TLS SNI 或 WS Host。
7. WS 本机端口可以留空自动分配，也可以指定一个 `1024–65535` 的空闲端口。
8. 不要填写源站 TLS 证书域名、证书 API Token 或 NAT 公网端口。固定 Tunnel 模式的这些字段不需要。
9. 命令会在参数填写完整后自动生成，复制到 VPS root 终端执行。

### 3. 配置 Tunnel Public Hostname 路由

安装完成后，终端会显示类似：

```text
Cloudflare Tunnel 路由必须设置：Public Hostname ws.example.com → http://127.0.0.1:23456
```

其中 `23456` 是实际随机分配或手动填写的 WS 本机端口。然后在 Cloudflare Zero Trust：

1. 打开 **Networks → Tunnels**，选择刚才创建的 Tunnel。
2. 打开 **Public Hostnames** 或 **Routes**，添加一条 Published application / Public Hostname。
3. Hostname 填 `ws.example.com`。
4. Service Type 选择 `HTTP`。
5. Service URL 填终端显示的完整地址，例如 `http://127.0.0.1:23456`。
6. 保存路由。

Cloudflare 会为该 Tunnel 主机名建立指向 Tunnel 的 DNS 路由（通常是指向 `<TUNNEL_ID>.cfargotunnel.com` 的 CNAME）。如果该主机名已有冲突的 A、AAAA 或 CNAME 记录，需要先检查并处理冲突记录。

### 4. 检查 Tunnel 状态

VPS 上可执行：

```bash
/usr/local/sbin/sb-manager
```

管理菜单中：

- `9`：查看 sing-box 和 Argo Tunnel 服务状态。
- `10`：查看 sing-box 与 cloudflared 最近日志。
- `16`：单独查看 Cloudflare 固定 Tunnel 状态；只显示 Token 是否存在和文件权限，不显示 Token 内容。
- `17`：修改固定 Tunnel 的 Public Hostname / 本机备注名，或粘贴新的 Tunnel Token。Token 留空表示保留当前 Token。

Cloudflare 控制台中的 Tunnel 应显示 **Healthy** 或有在线 Connector。若 Tunnel 不在线，检查 VPS 出站网络和 DNS。Cloudflare Tunnel 默认需要访问 Cloudflare 的连接端口 `7844`（QUIC 使用 UDP；HTTP/2 回退使用 TCP），请确保 VPS 出站策略允许。

### 5. 更换 / 轮换固定 Tunnel Token

如果在 Cloudflare 控制台执行了 **Rotate token**，需要把新 Token 更新到 VPS：

1. Cloudflare Zero Trust → Networks → Tunnels，选择原来的固定 Tunnel。
2. 执行 **Rotate token**，然后进入 **Add a replica**，复制新安装命令中的完整 Token（只复制 `eyJ...` 字符串）。
3. VPS 执行 `/usr/local/sbin/sb-manager`，选择菜单 `17`。
4. 确认 Public Hostname；备注名可修改或留空；在隐藏输入提示中粘贴新的 Tunnel Token。
5. 脚本会先备份旧 Token，再以原子方式写入新 Token，设置 `0640 root:sing-box` 权限并重启 `cloudflared`。不会把 Token 写入 `manager.json` 或显示在状态输出中。
6. 最后到 Cloudflare 控制台确认 Connector 为 **Healthy**。如果 Token 已在 Cloudflare 端轮换，旧 Token 可能已失效；若新 Token 粘贴错误，需要重新输入 Cloudflare 当前有效的 Token。

Cloudflare 官方说明：轮换 Token 后，旧 Token 不能用于建立新连接；已有 Connector 会继续运行到重启。若同一个 Tunnel 还有其他 VPS / replicas，也要逐台更新新 Token，建议分批操作。

注意：菜单 `17` 修改的是 VPS 本地的 Tunnel 凭据和节点域名。它不会通过 Cloudflare API 自动创建 Tunnel、修改 Dashboard Public Hostname 路由或 DNS 记录；更换域名，或把 Token 换成另一个 Tunnel 的 Token 后，都要在 Cloudflare 控制台确认该 Tunnel 的 Public Hostname 路由指向 `http://127.0.0.1:<WS_PORT>`。

### 6. Argo 模式客户端节点参数

Argo 模式生成的 VLESS + WS 节点使用以下逻辑：

| 客户端参数 | 值 |
|---|---|
| Address | HTML 中的客户端连接地址；留空则使用 Argo 公网主机名 |
| Port | `443` |
| TLS | 开启 |
| SNI | Argo 公网主机名，例如 `ws.example.com` |
| Network | WebSocket |
| Host | 与 Argo 公网主机名相同，例如 `ws.example.com` |
| Path | 安装脚本自动生成的随机 WS 路径 |

如果填写优选 IP：Address 使用优选 IP，**SNI 和 Host 仍必须保持 Argo 公网主机名**。不要把优选 IP 填入 SNI，也不要把 `edge` 优选域名误填成 Tunnel 的 Public Hostname。

Argo 模式的客户端公网端口固定为 `443`；VPS 本机的 WS 监听端口是另一回事，只是 Tunnel 回源端口。修改本机 WS 端口后，必须同步把 Cloudflare Tunnel Service URL 改成新的 `http://127.0.0.1:新端口`。

### 7. 其他协议在 NAT VPS 上的限制

Cloudflare Tunnel 当前只用于本项目的 VLESS + WebSocket HTTP 流量，不会自动把 AnyTLS、VLESS Reality、NaiveProxy 或 AnyTLS + Reality 变成 Tunnel 流量。若同时选择这些协议，仍需要 NAT 服务商为相应协议提供可用的公网 TCP 端口映射，并确保公网端口与脚本生成的节点端口匹配。本脚本不负责把其他协议映射成 Cloudflare Tunnel TCP 服务。

## 五、端口分配与后期修改

- Argo WS：本机监听 `127.0.0.1:<WS_PORT>`，客户端端口固定 `443`，不需要 NAT 公网入站映射。
- 直连 WS TLS：本机监听端口也是客户端端口；使用 Cloudflare 橙云时需选择 Cloudflare 支持的 HTTPS 代理端口（例如 `443`、`2053`、`2083`、`2087`、`2096`、`8443`）。
- AnyTLS、VLESS Reality、NaiveProxy、AnyTLS + Reality：使用各自 TCP 监听端口。NAT VPS 必须确认服务商已经提供对应公网映射。
- 端口留空时由脚本自动分配；手动端口被占用或与已选协议重复时，脚本会自动改选空闲端口。随机端口不代表 NAT 服务商已经自动创建公网映射。

进入管理菜单：

```bash
/usr/local/sbin/sb-manager
```

常用菜单：

- `1` 查看当前已安装协议的节点链接。
- `4` 修改 VLESS + WS / Argo 的客户端连接地址（优选 IP / 域名）。
- `7` 选择单个已安装协议并修改端口，其他协议端口不变。
- `8` 重启 sing-box；Argo 模式会同时尝试重启 Tunnel。
- `9` 查看服务状态。
- `10` 查看最近日志。
- `16` 查看 Cloudflare 固定 Tunnel 状态。
- `17` 修改固定 Tunnel 的 Public Hostname、备注名或轮换 Token。
- `18` 增加 / 移除 VLESS XHTTP + ECH。
- `19` 增加 / 移除 Snell。
- `20` 重新生成 ECH 密钥。
- `21` 查看 Xray 服务状态。
- `22` 查看 Xray 日志。

修改 Argo WS 本机端口后，记得更新 Cloudflare Tunnel Public Hostname 的 Service URL。修改其他直连协议端口后，记得更新系统防火墙、云安全组和 NAT 服务商端口映射。

## 六、卸载

在需要卸载的 VPS 上以 root 身份执行：

```bash
/usr/local/sbin/sb-manager uninstall
```

卸载会删除本脚本管理的 `/etc/sing-box` 和 `/etc/xray` 配置目录、sing-box / Xray 服务、管理脚本、证书重载钩子，以及本脚本创建的 `cloudflared-sb-tunnel` 专用服务和 Tunnel Token 文件。如果 `cloudflared` 二进制是本脚本下载的，也会删除；如果系统原本已有 cloudflared，则保留该二进制。

卸载不会删除 Cloudflare 控制台中的 Tunnel、Public Hostname、DNS 记录，也不会删除 NAT 服务商端口映射或云厂商安全组。需要时应在 Cloudflare 控制台单独清理 Tunnel 和 DNS 路由。

## 七、发布到 GitHub Pages

仓库：<https://github.com/mxw1589/jiedian>

1. 打开仓库，点击 **Add file → Upload files**。
2. 上传并覆盖根目录的 `index.html`、`README.md` 和 `sb-manager-debian-alpine.sh`。
3. 点击 **Commit changes**，提交到 `main` 分支。
4. 打开 **Settings → Pages**。
5. Source 选择 **Deploy from a branch**；Branch 选择 `main`，目录选择 `/(root)`，点击 Save。
6. 等待 Pages 部署完成后打开：<https://mxw1589.github.io/jiedian/>。
7. 页面仍显示旧版本时，按 `Ctrl + F5` 强制刷新。

无需选择 Next.js、Jekyll 或其他 Actions 工作流。GitHub Pages 直接发布仓库根目录中的静态 `index.html`。

## 七、安全说明与限制

- Cloudflare Tunnel Token 和 DNS API Token 都是敏感凭据。网页生成命令中 Token 使用 Base64 编码，Base64 不是加密。不要公开分享安装命令。
- 不要将 Token、节点链接、证书私钥或 VPS 配置 JSON 上传到公开仓库。
- Cloudflare Tunnel 只处理本项目的 VLESS + WebSocket HTTP 流量；其他协议仍需自己的公网 TCP 映射。
- Argo Tunnel 的公网 hostname / Service URL 路由必须在 Cloudflare 控制台创建或维护。安装脚本能安装和运行 cloudflared，但不会仅凭 Tunnel Token 自动创建 Cloudflare 控制台中的路由。
- 仅在自己拥有或获准管理的 VPS、域名和 Cloudflare 账户上使用。
