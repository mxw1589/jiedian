> 🌐 **在线打开 HTML 配置面板：** https://mxw1589.github.io/jiedian/
>
> 本版本支持按需选择协议、自动生成安装命令，以及 NAT VPS 的 Cloudflare 固定 Tunnel（Argo）接入方式。

# sing-box 单 VPS 选择性安装与管理工具

适用于 Debian / Ubuntu / Alpine 的 sing-box 安装脚本和静态网页配置面板。无需安装全部协议；只勾选需要的协议，网页会根据选择显示所需字段、隐藏完全无关字段，并在填写完成后自动更新一键安装命令。

## 项目文件

```text
jiedian/
├── index.html
├── README.md
├── CHANGELOG.md
└── sb-manager-debian-alpine.sh
```

- `index.html`：紧凑型静态配置面板，可发布到 GitHub Pages。
- `README.md`：安装、字段说明、Argo Tunnel 配置、管理和卸载说明。
- `CHANGELOG.md`：本次修复与版本变更记录。
- `sb-manager-debian-alpine.sh`：Debian / Ubuntu / Alpine 安装及管理脚本；自动识别系统、CPU 架构和服务管理器。

### Windows 一键推送

在项目的 `main` 分支双击 `一键push到github.bat`，脚本会提交整个仓库中新增、修改和删除的文件，并推送到 [GitHub](https://github.com/mxw1589/jiedian)。没有新改动时也会推送尚未上传的提交。首次使用请按 Git for Windows 的提示登录有写权限的 GitHub 账号。

未跟踪、且被 `.gitignore` 忽略的文件不会上传。请勿把已跟踪文件当作存放密钥的地方。脚本会在推送前合并远端更新；若有冲突，会取消自动合并并保留本地提交，不会强推。

## 功能简介

### 选择性安装

支持以下七个选项，可任意单选或多选：

| 协议 | 源站 TLS 证书 | NAT 公网入站 | 参数要求 |
|---|---|---|---|
| AnyTLS | 需要 | 需要 TCP 映射 | TLS 域名、证书方式；Cloudflare DNS-01 还需要 DNS API Token |
| VLESS + WS + TLS 直连 | 需要 | 需要 TCP 映射 | TLS 域名和证书 |
| VLESS + WS + TLS Argo | 不需要 | 不需要 | Tunnel Public Hostname 和 Tunnel Token |
| Shadowsocks 2022 | 不需要 | 需要同一端口的 TCP / UDP 映射 | 自动生成密钥；源站地址可由 VPS 自动检测 |
| VLESS + Reality | 不需要 | 需要 TCP 映射 | Reality SNI；源站地址可由 VPS 自动检测 |
| NaiveProxy | 需要 | 需要 TCP 映射 | TLS 域名、证书方式；Cloudflare DNS-01 还需要 DNS API Token |
| AnyTLS + Reality | 不需要 | 需要 TCP 映射 | Reality SNI；源站地址可由 VPS 自动检测 |

不需要的字段会在网页中隐藏或禁用，不会写入最终配置。未选择的协议不会创建入站、分配端口或生成节点链接。

两条 WS 线路独立：都不选（需选择其他协议，例如 Shadowsocks 2022）、只选直连、只选 Argo、两条都选都可以。同时启用时，各自拥有独立端口、UUID、路径和节点链接。

### 网页配置面板

- 页面改为紧凑双栏布局；桌面端减少纵向滚动，手机端自动单栏排列。
- 每个字段标注“必填 / 可选 / 默认”；当前协议完全不需要的字段直接隐藏，不只是灰显。
- 协议选择变化时，相关字段即时显示或隐藏；隐藏字段不会写入配置。
- **安装命令和卸载命令同时显示、分开生成、分别复制**；安装命令随表单实时更新，卸载命令固定显示。
- 网页端口留空时，新节点自动分配空闲端口，旧节点保留原端口；源站 IP 留空由 VPS 自动检测；Reality SNI 留空使用默认值。
- 操作系统、CPU 架构和 systemd / OpenRC 不需要手动选择，脚本自动识别。
- 支持导出不含 Token 的配置 JSON，以及下载分隔显示的安装 / 卸载命令 TXT。
- 页面是静态前端，表单内容只在当前浏览器处理，不会自动上传到 GitHub Pages。

### 表单字段：哪些要填，哪些不用填

| 字段 | 标记 | 什么时候需要 / 留空行为 |
|---|---|---|
| Tunnel Public Hostname | 必填 | 仅选择 VLESS + WS / Argo 时填写，例如 `ws.example.com` |
| Cloudflare Tunnel Token | 必填 | 仅 Argo 模式填写完整 Token |
| Tunnel 备注名 | 可选 | 仅用于本机菜单显示；留空即可 |
| 优选域名 / IP | 可选 | 勾选直连 WS 或 Argo 后分别显示。首次留空使用 TLS 证书域名或 Tunnel Public Hostname；同步时留空保留旧优选地址，填 `-` 恢复默认 |
| 自定义 WS HTTP Host | 可选 | 仅直连 WS 高级设置；首次留空使用 TLS 域名，同步留空保留旧自定义 Host，填 `-` 恢复默认 |
| 源站 IPv4 / IPv6 | 可选 | AnyTLS、Reality、NaiveProxy、Shadowsocks 2022 使用；两项都留空时自动检测 |
| Reality SNI | 可选 / 默认 | 仅 Reality 协议需要；留空默认 `www.bing.com` |
| TLS 证书域名 | 必填 | 仅 AnyTLS、NaiveProxy、直连 WS 需要 |
| 证书签发方式 | 默认 | 默认 Cloudflare DNS-01；也可选择 HTTP-01 |
| Cloudflare 根域名 | 必填 | 仅 DNS-01 需要，例如 `example.com` |
| Cloudflare DNS API Token | 必填 | 仅 DNS-01 需要；与 Tunnel Token 不同 |
| Cloudflare Zone ID | 可选 | DNS-01 可自动查询；留空即可 |
| 证书邮箱 | 可选 | 留空即可，不影响 DNS-01 申请 |
| 节点辨识符 | 可选 | 仅用于区分节点；留空使用默认名称 |
| 各协议端口 | 可选 | 网页留空时新节点自动分配、旧节点保留；需要指定内网监听端口时才填 |

**完全不需要填写的项目：** 不选 Argo 就不需要 Tunnel 参数；不选 Reality，就不需要 Reality SNI；不选 AnyTLS / Naive / 直连 WS，就不需要 TLS 证书或 Cloudflare DNS API；Argo-only 不需要源站 IP 和源站证书。系统版本、CPU 架构、服务管理器都由脚本自动判断。

### TLS 证书域名怎么填

- 填你拥有或获准管理的根域名或完整子域名，例如 `example.com`、`direct.example.com`。只填域名，不带 `https://`、端口、路径、尾点或 `*.`；不要填 IP、优选 IP 或 Reality 的 `www.bing.com`。
- **Cloudflare DNS-01**：填 Cloudflare Zone 本身或其子域名，例如 Zone 是 `example.com`，可填 `direct.example.com`。**HTTP-01**：域名需解析到 VPS，且公网 TCP `80` 可访问。**手动导入**：填证书 SAN 覆盖的具体域名；即使导入通配符证书，也填写具体子域名。
- **Argo** 不使用这个字段。两条 WS 都开时，建议直连填 `direct.example.com`，Tunnel Public Hostname 填 `tunnel.example.com`，各自配置 DNS 路由。Argo 客户端走 Cloudflare TLS `443`，Tunnel 回源到 `http://127.0.0.1:<Argo 本机端口>`。

### 服务端脚本

- 支持 Debian / Ubuntu 和 Alpine，使用 systemd 或 OpenRC。
- Alpine 仓库版本低于 NaiveProxy 所需的 sing-box `1.13.0` 时，自动尝试官方 Linux 发布版，并在后续管理时优先使用 `/usr/local/bin/sing-box`。
- 只创建所选协议的 sing-box inbound。
- 支持 Cloudflare DNS-01、HTTP-01 和手动证书（交互式安装）。
- 支持 Cloudflare **固定 Tunnel（Argo）** 承载 VLESS + WebSocket：使用 Cloudflare Zero Trust 中创建的 remotely-managed Tunnel 和固定 Tunnel Token，不使用临时 Quick Tunnel；VPS 本机只监听 `127.0.0.1`，由 `cloudflared` 主动连接 Cloudflare。
- `cloudflared` 作为独立 systemd / OpenRC 服务运行；使用 `2025.4.0` 或更新版本的 `--token-file` 功能读取权限受限的 `/etc/sing-box/cloudflared.token`，避免把 Tunnel Token 放在进程命令行中，也不会写入公开节点链接。
- 管理菜单支持查看固定 Tunnel 信息，以及轮换 / 更换 Tunnel Token；Token 原子写入、权限设为 `0640 root:sing-box`，不写入 `manager.json`。
- 支持 IPv4 / IPv6 源站地址自动检测；Argo-only 安装不需要填写源站公网 IP。
- 端口冲突时自动更换可用端口；配置检查或服务重启失败时尝试回滚。
- 管理菜单支持单个协议修改端口、查看节点、日志、固定 Tunnel 状态、Tunnel Token 轮换、BBR 状态和卸载。
- **增量添加节点**：已安装后可通过菜单 `18`（或 `sb-manager add`）安装尚未部署的协议；自动跳过已有协议，只为新增协议生成凭据和端口，保留旧节点 UUID、密码、Reality 密钥、端口、WS 路径和 Tunnel 配置。
- 启用 NaiveProxy 时，节点展示流程会额外生成 `/etc/sing-box/naive-client.json`，供 sing-box 1.13.0+ 客户端使用；该文件含认证信息，权限限制为 `0600`。

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

1. 选择需要的协议；独立回答是否安装直连 WS、Argo WS 和 Shadowsocks 2022。
2. 选中 Argo 时填写 Public Hostname、可选的本机备注名和 Tunnel Token。
3. 若只选了 Argo 或 Shadowsocks 2022，不询问源站证书。
4. 只有选择普通 AnyTLS、NaiveProxy 或直连 WS 时，才询问源站 TLS 证书域名和证书方式。
5. 只有选择 Reality 协议时，才询问 Reality SNI。
6. 只询问已选择协议的端口。留空时自动分配。

安装完成后，管理命令为：

```bash
/usr/local/sbin/sb-manager
```

## 二、通过 HTML 自动生成安装命令

1. 打开 [sing-box 在线配置面板](https://mxw1589.github.io/jiedian/)。
2. 勾选需要安装的协议。默认预选 VLESS + WebSocket + Argo，可按需取消或增加协议。
3. 分别勾选直连 WS 和 Argo WS。NAT VPS 通常优先选 Argo；直连需要可用公网入站和源站证书。
4. 根据当前选择填写标有“必填”的字段；“可选”字段可以留空，“默认”字段已有预设值。当前协议完全不需要的字段会直接隐藏。
5. 页面下方会同时显示安装命令和卸载命令。安装命令随参数自动更新；卸载命令单独显示，不会与安装命令混在一起。
6. 只复制“安装命令”，以 root 登录目标 VPS 后粘贴执行。卸载命令仅在以后确实需要卸载时单独使用；不要连续执行两条命令。

网页命令会携带 Base64 编码的 JSON 配置。Base64 不是加密；命令中可能包含 Cloudflare DNS API Token 或 Tunnel Token。不要公开分享命令、截图或提交到 GitHub。

如果 VPS 已经有本脚本的安装，新版网页命令会先做本机备份，再按当前勾选同步：**未安装的所选协议会新增，已安装的所选协议会使用网页值更新，未勾选的旧协议会移除**。要保留的协议都要勾选。更新旧节点时保留密码、UUID、密钥和 WS 路径；网页端口留空则保留原端口，填写端口则使用指定值。有冲突时停止，不会悄悄改用其他端口。

勾选 Argo 就会生成独立的 Argo 节点链接（客户端端口 `443`）。按终端显示的回源地址配置 Cloudflare Tunnel 的 Service URL。取消勾选 Argo 会移除本机专用 Tunnel 服务，但不会删除 Cloudflare 控制台里的 Tunnel 或 DNS 路由。同步完成后请用新输出更新客户端连接；参数变动可能导致旧链接不再可用。

## 三、NAT VPS 使用 Cloudflare Tunnel（Argo）为 VLESS + WS 接入

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

1. 勾选 **VLESS + WS + TLS Argo**。
2. 不需要直连时，让 **VLESS + WS + TLS 直连** 保持未勾选。
3. 填写 Argo 公网主机名，例如 `ws.example.com`。该主机名必须属于你拥有或获准管理、并已接入 Cloudflare 的域名区域。
4. 可填写一个本机备注名，便于在管理菜单中区分 VPS；该备注不等于 Cloudflare Tunnel ID。
5. 填写刚才复制的固定 Tunnel Token。
6. **Argo 优选域名 / IP** 可以留空。首次安装默认使用 `ws.example.com`，同步已有节点时留空保留旧优选值，填 `-` 恢复默认。优选地址只改变客户端连接目标，不会改变 TLS SNI 或 WS Host。
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

## 四、通过 sb-manager 增量添加此前未部署的节点

如果首次安装时只启用了一条 WS，之后可以直接增量添加另一条，也可以增加 Shadowsocks 2022 或其他协议，无需卸载或重新安装。

1. SSH 登录 VPS，执行：
   ```bash
   /usr/local/sbin/sb-manager
   ```
2. 选择菜单 `18. 添加尚未部署的协议节点`。
3. 脚本会显示各协议的安装状态，只询问尚未安装的协议；已经部署的协议不会再次选择，也不会重新生成密码、UUID、Reality 密钥、端口或 WS 路径。
4. 如果新增协议需要 TLS 证书，优先检查并复用当前证书。没有可用证书时，可选择 Cloudflare DNS-01、HTTP-01 或手动导入。Cloudflare DNS-01 使用 **DNS API Token**，不是 Argo Tunnel Token；如果已有 Token，可直接回车保留，也可输入新 Token 更新。
5. 如果新增协议需要源站公网地址，脚本会保留已有地址；首次需要时允许手动填写 IPv4 / IPv6，留空则尝试自动检测。
6. 新增协议端口留空时自动分配；手动指定时会检查是否与现有节点端口或其他监听进程冲突。增量添加不会为了新节点而改变旧节点端口。
7. 配置通过 sing-box 检查并成功重启后，脚本会显示全部节点链接和本次新增协议的 TCP 端口。需要公网入站的节点还要在 VPS 防火墙、安全组和 NAT 服务商面板中配置相应端口映射。

也可以直接进入增量添加向导：

```bash
/usr/local/sbin/sb-manager add
```

如果菜单 `18` 显示所有协议均已安装，说明所有协议选项都已部署，无需重复添加。若新增 Argo WS，仍需在 Cloudflare Zero Trust 中把 Public Hostname 的 Service URL 指向脚本显示的 `http://127.0.0.1:<本机 WS 端口>`。

只想新增节点、不改旧节点配置，也不删除其他节点时，使用菜单 `18` 或 `sb-manager add`。新版网页的命令顶部会列出本次勾选的协议，并同步整个选择；旧版命令只在勾选与现有协议一致时允许覆盖升级，否则停止并提示刷新页面重新生成。

## 五、NaiveProxy 与 Linux 客户端

本项目的 NaiveProxy 服务端由 **sing-box 内置 Naive 入站**提供，不需要在 VPS 上另外安装独立的 Naive 服务端。脚本会检查 sing-box 版本至少为 `1.13.0`：

- Debian / Ubuntu：通过 sing-box 官方软件源安装。
- Alpine：优先检查仓库版本；若版本低于 `1.13.0` 或不可用，则自动下载官方 Linux 发布版。
- 启用 NaiveProxy 后，查看节点时会生成 `/etc/sing-box/naive-client.json`，供 Linux 上的 sing-box `1.13.0+` 客户端使用。

如果某个 Linux 图形客户端提示“找不到 `Naive` 核心”，那通常是**客户端应用自身没有配置外部 Naive 核心路径**，不等于 VPS 服务端缺少核心。可以改用官方 sing-box 客户端读取 `naive-client.json`，也可以按该图形客户端的 Linux 版说明单独配置其核心路径；本项目不提供桌面端专用核心安装器。

客户端配置文件包含 Naive 用户名和密码，默认权限为 `0600`。请通过 SSH / SCP 等安全方式传输，不要公开分享。若 NAT 服务商的公网映射端口与 VPS 内部监听端口不同，请把 JSON 中 `server_port` 改成服务商分配的公网端口；脚本默认写入的是 VPS 内部监听端口。

官方 sing-box Naive 出站说明：<https://sing-box.sagernet.org/configuration/outbound/naive/>。

## 六、端口分配与后期修改

- Argo WS：本机监听 `127.0.0.1:<WS_PORT>`，客户端端口固定 `443`，不需要 NAT 公网入站映射。
- 直连 WS TLS：本机监听端口也是客户端端口；使用 Cloudflare 橙云时需选择 Cloudflare 支持的 HTTPS 代理端口（例如 `443`、`2053`、`2083`、`2087`、`2096`、`8443`）。
- WS 节点测速超时时，先用实际 TLS 域名（直连）或 Tunnel Public Hostname（Argo）作客户端地址测试；如果只有换成优选地址才超时，检查该地址能否访问对应的端口。若 Argo 用默认地址也失败，检查 Tunnel Connector 和 Service URL；直连则检查证书、入站防火墙与 NAT 公网映射。源站和公网端口不同的 NAT 直连节点，客户端需手动使用实际公网端口。
- AnyTLS、VLESS Reality、NaiveProxy、AnyTLS + Reality：使用各自 TCP 监听端口。NAT VPS 必须确认服务商已经提供对应公网映射。
- 新版网页命令发现端口被占用或重复时会停止，不会更换指定端口。随机端口不代表 NAT 服务商已经自动创建公网映射。

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
- `18` 增量添加尚未部署的协议节点，不重新生成现有节点凭据。
- `19` 删除一个已安装协议；只移除所选协议的入站、端口和凭据，其他协议保留。不能删除最后一个协议；如需移除整个程序，使用菜单 `11` 或 `sb-manager uninstall`。
- `20` 先选择一个已安装协议，再修改该协议的 SNI / TLS 域名、连接地址或 WS 优选 IP、Cloudflare 绑定域名 / Argo Public Hostname、端口，以及协议专属凭据和可选参数。

### Shadowsocks 2022

勾选 **Shadowsocks 2022** 或通过菜单 `18` 增量添加。脚本使用 `2022-blake3-aes-128-gcm` 并自动生成密钥。客户端需支持该加密方式，可导入脚本生成的 `ss://` 链接；不需要 TLS 域名或 Cloudflare Token。请在防火墙、安全组和 NAT 服务商处为节点端口同时放行 TCP 和 UDP。菜单 `20` 可单独修改端口或轮换密钥。

### 菜单 20：按协议修改参数

菜单 `20` 会先列出当前已安装协议，再进入该协议的修改菜单：

1. **SNI / TLS 域名**：AnyTLS、NaiveProxy、直连 WS 共用同一套源站 TLS 证书和 `TLS_DOMAIN`；修改其中一个协议的 TLS 域名时，会同步影响其他使用这张证书的协议。VLESS Reality 与 AnyTLS + Reality 当前共用 `REALITY_SNI`，修改任意一个时会同步影响另一个。
2. **连接地址 / WS 优选 IP**：WS 协议只修改自己的客户端连接地址；其他协议修改的是共用源站 IPv4 / IPv6，影响所有使用源站地址的直连协议。源站地址留空保持原值，输入 `-` 清除此地址，输入 `auto` 尝试自动检测。NAT VPS 的自动检测结果可能是出站 IP，不一定等于服务商分配的入站映射地址。
3. **Cloudflare 绑定域名**：Argo WS 修改 Tunnel Public Hostname、可选备注名及可选轮换的 Tunnel Token；备注名输入 `-` 可清除。DNS-01 TLS 协议修改 Cloudflare Zone、证书域名、可选 Zone ID 和可选 DNS API Token。Zone ID 输入 `-` 表示清除固定 ID、让 acme.sh 自动查询；DNS API Token 留空表示保留当前值。
4. **端口**：只修改当前选择的协议。留空自动分配；修改后必须同步检查 NAT 映射和防火墙。Argo WS 的本机端口变化后，还要把 Cloudflare Tunnel Service URL 改成 `http://127.0.0.1:<新端口>`。
5. **协议专属值**：AnyTLS / Naive 凭据可自定义或随机生成；WS 可修改 HTTP Host、Path、UUID；Reality 协议可修改 UUID 或重新生成密钥对 / Short ID。密码输入留空保持原值，输入 `-` 随机生成。WS Host 输入 `-` 恢复默认域名，WS Path 输入 `-` 随机生成。

直连 WS（编号 `2`）、Argo WS（编号 `6`）和 Shadowsocks 2022（编号 `7`）可分别添加、删除和编辑。切换 WS 线路时，可先添加另一条，确认可连后再删除旧线路。旧版单线路配置升级时会保留原端口、UUID、路径和连接地址。TLS 证书签发模式也不会因修改域名而自动切换；菜单可更新当前 DNS-01 的 Zone / Token / Zone ID，HTTP-01 和手动证书仍按原签发方式管理。

### 菜单 19：删除协议

删除时必须输入 `DELETE` 二次确认。删除 Argo WS 会停止并移除 VPS 本机的 `cloudflared-sb-tunnel` 服务和 Token 文件，但不会删除 Cloudflare 控制台里的 Tunnel、Public Hostname 或 DNS 记录。删除其他协议不会更改剩余协议的凭据、端口和证书。最后一个协议不能单独删除；如需清空整个安装，请使用完整卸载。

修改 Argo WS 本机端口后，记得更新 Cloudflare Tunnel Public Hostname 的 Service URL。修改其他直连协议端口后，记得更新系统防火墙、云安全组和 NAT 服务商端口映射。

## 七、卸载

在需要卸载的 VPS 上以 root 身份执行：

```bash
/usr/local/sbin/sb-manager uninstall
```

卸载会删除本脚本管理的 `/etc/sing-box` 配置目录、sing-box 服务、管理脚本、证书重载钩子，以及本脚本创建的 `cloudflared-sb-tunnel` 专用服务和 Tunnel Token 文件。如果 `cloudflared` 二进制是本脚本下载的，也会删除；如果系统原本已有 cloudflared，则保留该二进制。

卸载不会删除 Cloudflare 控制台中的 Tunnel、Public Hostname、DNS 记录，也不会删除 NAT 服务商端口映射或云厂商安全组。需要时应在 Cloudflare 控制台单独清理 Tunnel 和 DNS 路由。

## 八、发布到 GitHub Pages

仓库：<https://github.com/mxw1589/jiedian>

1. 打开仓库，点击 **Add file → Upload files**。
2. 上传并覆盖根目录的 `index.html`、`README.md`、`CHANGELOG.md` 和 `sb-manager-debian-alpine.sh`。本版本只需上传上述四个根目录文件。
3. 点击 **Commit changes**，提交到 `main` 分支。
4. 打开 **Settings → Pages**。
5. Source 选择 **Deploy from a branch**；Branch 选择 `main`，目录选择 `/(root)`，点击 Save。
6. 等待 Pages 部署完成后打开：<https://mxw1589.github.io/jiedian/>。
7. 页面仍显示旧版本时，按 `Ctrl + F5` 强制刷新。

无需选择 Next.js、Jekyll 或其他 Actions 工作流。GitHub Pages 直接发布仓库根目录中的静态 `index.html`。

## 九、安全说明与限制

- Cloudflare Tunnel Token 和 DNS API Token 都是敏感凭据。网页生成命令中 Token 使用 Base64 编码，Base64 不是加密。不要公开分享安装命令。
- 不要将 Token、节点链接、证书私钥或 VPS 配置 JSON 上传到公开仓库。
- Cloudflare Tunnel 只处理本项目的 VLESS + WebSocket HTTP 流量；其他协议仍需自己的公网 TCP 映射。
- Argo Tunnel 的公网 hostname / Service URL 路由必须在 Cloudflare 控制台创建或维护。安装脚本能安装和运行 cloudflared，但不会仅凭 Tunnel Token 自动创建 Cloudflare 控制台中的路由。
- 仅在自己拥有或获准管理的 VPS、域名和 Cloudflare 账户上使用。
