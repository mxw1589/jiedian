# ArgoSBX 命令生成器 + sing-box / Xray 节点管理器

本项目以你上传的 `jiedian2.zip` 为基础整理。主入口是 ArgoSBX V26.11.20 参数生成器；原有自建 sing-box / Xray 管理器继续保留为独立页面。两套工具的协议栈、参数名、配置文件和服务管理逻辑不同，不能混用命令。

## 文件结构

- `index.html`：主入口。ArgoSBX 官方 SSH 命令生成器，包含 15 种协议、15 种 WARP 出站组合、CDN、TLS、订阅、Argo 和快捷命令。
- `generator.js`：生成器核心，负责依赖联动、输入校验、风险提示、Shell 安全转义、命令生成和旧命令导入。
- `manager.html`：原有自建 sing-box / Xray 管理器前端。
- `sb-manager-debian-alpine.sh`：原有 Debian / Ubuntu / Alpine 管理脚本快照。
- `tests/`：生成器、两个页面、节点分享链接、配置保留、SS2022 管理菜单和 Shell 语法回归测试。
- `CHANGELOG.md`：版本修改记录。
- `VERSION.txt`、`BUILD-INFO.md`：版本号、构建与验证范围。
- `SHA256SUMS.txt`：文件 SHA-256 校验清单。

## 主生成器怎么用

1. 解压 ZIP，在浏览器打开 `index.html`。
2. 勾选一个或多个协议。协议右侧的端口框可以留空，让上游脚本随机分配；也可以手动填端口。
3. 只填写自己确实需要的全局配置。大多数选项可保持默认或留空。
4. 选择 `curl` 或 `wget`，复制生成的 SSH 命令。
5. 在目标 VPS 的 Bash 终端执行。下载内核、安装服务、生成节点分享链接和订阅由 ArgoSBX 上游脚本完成。

命令调用的上游脚本：

`https://raw.githubusercontent.com/yonggekkk/argosbx/main/argosbx.sh`

注意：页面标注 V26.11.20，但命令使用 GitHub `main` 分支的实时脚本，不是固定到某个 Git commit。上游更新后，实际执行的代码也可能更新。VPS 必须能访问 GitHub。

## 每个输入项应该填什么

### 协议与端口

- 勾选协议 = 启用该协议；可以多选。
- 端口留空 = 上游脚本自动分配。
- 手动端口 = `1–65535` 的整数；建议选择未被占用的端口，并在云安全组、系统防火墙和 NAT 映射中放行对应 TCP / UDP。
- 页面会拦截重复端口。为避免监听冲突，校验按同一数字端口保守处理。
- 自动内核组：Hysteria2、VMess WS、SOCKS5 由上游按协议组合分配。选择任意 Xray 专属协议时，自动组节点使用 Xray；没有 Xray、但选择了 Sing-box 专属协议时，自动组节点使用 Sing-box；如果只选择自动组，上游 V26.11.20 默认走 Xray 分支。
- NaiveProxy 必须同时开启 `alns=y`。

### 全局配置

| 参数 | 怎么填 | 什么时候可以留空 |
|---|---|---|
| `uuid` | 标准 UUID；也可点“生成 UUID”。 | 通常留空，由服务器生成。 |
| `reym` | Reality 握手域名，例如 `apple.com`；不要加协议头或端口。 | 没有启用 VLESS Reality、XHTTP Reality、Any-reality 时留空；启用时留空使用上游默认值。 |
| `cfip` | 1–2 个 CDN 优选 IP 域名，以空格分隔，不是 IP 地址。 | 没有使用对应 CDN 优选方案时留空；上游默认值为 `www.shopify.com icook.tw`。适用 VMess WS、VLESS XHTTP/WS-Enc、XHTTP TLS-TCP/UDP。 |
| `alns` | `y` 表示启用域名/IP 证书 TLS。若 `/root/ygkkkca/private.key` 不存在，上游会调用 Acme-yg 尝试申请证书。 | 默认关闭；NaiveProxy 必须开启。若证书申请失败或证书文件未生成，上游会回退到自签证书。 |
| `hyjpt` | Hysteria2 UDP 跳跃端口，支持单端口和范围，例如 `123:456 789`。页面还会检查范围是否覆盖 TUIC、XHTTP-UDP、SS2022、SOCKS5 等可能使用 UDP 的监听端口。 | 不使用端口跳跃时留空。**高风险提醒见下方。** |
| `cdnym` | Cloudflare CDN 回源 Host 域名，例如 `origin.example.com`。 | 不使用 VMess WS / VLESS XHTTP-Enc / VLESS WS-Enc 的对应 CDN 回源方案时留空。 |
| `warp` | 选择 Sing-box 与 Xray 的 WARP IPv4/IPv6 出站组合。默认是 VPS 本地 IP。 | 不需要 WARP 出站时保持默认。 |
| `ippz` | `自动`、`4`（IPv4）或 `6`（IPv6），控制节点信息导出地址族。 | 通常保持自动。 |
| `oap` | `y` 会执行上游的开放端口操作。 | **强烈建议关闭。**它不是只开放代理端口。 |
| `name` | 节点名称前缀，支持中文、字母、数字、点、下划线、短横线；首尾使用字母或数字。 | 不需要自定义节点名称时留空。 |

### 需要特别注意的三个选项

1. **`oap=y`：** 上游脚本会把 IPv4 `iptables` 的 INPUT / FORWARD / OUTPUT 默认策略设为 ACCEPT，并清空整个 filter 规则表。这可能删除已有防火墙规则，也可能暴露 SSH、数据库或其他服务。除非你明确知道影响并准备好恢复规则，否则不要开启。
2. **`hyjpt`：** 上游脚本配置 HY2 端口跳跃时，会先清空 IPv4 和 IPv6 的 NAT `PREROUTING` 规则，再写入跳跃端口 DNAT 规则。若 VPS 使用 Docker、端口转发或其他自定义 NAT 规则，不要随意启用；先备份并确认这些规则可以重建。
3. **`sub=y`：** 上游通过普通 HTTP 提供 Clash/Mihomo、Sing-box 和聚合订阅，订阅密码放在 URL 路径中。不要公开分享订阅地址；如果需要加密传输，应放在可信的 HTTPS 反向代理后。

### 订阅参数

- `sub`：开启后生成 Clash/Mihomo、Sing-box 和聚合单节点订阅。
- `subid`：订阅 URL 路径密码；留空时使用 UUID。为避免路径问题，使用英文字母/数字开头和结尾，中间可用点、下划线、短横线。
- `subpt`：订阅 HTTP 服务端口；留空自动分配。不要与已填写的代理端口重复。

### Argo 临时 / 固定隧道

- `argo`：选择 VMess WS、VLESS WS-Enc 或 VLESS XHTTP-Enc 作为 Argo 主协议；选择后页面会自动勾选对应协议。
- `agqc`：默认 TCP（Cloudflared HTTP/2）；选择 UDP 时使用 QUIC。
- 临时隧道：只选择 `argo` 主协议，`agn` 和 `agk` 都留空。
- 固定隧道：`agn` 填 Cloudflare Tunnel 的 Public Hostname，`agk` 粘贴完整 Tunnel Token；两项必须同时填写。
- VLESS XHTTP-Enc 的 Argo 模式仅支持固定隧道。

## 已安装脚本的快捷命令

- `list`：显示当前节点；可保留 IPv4 / IPv6 导出选择。
- `del`：卸载 ArgoSBX。注意：上游脚本在 Alpine / OpenRC 清理分支会清空 IPv4 和 IPv6 的 NAT `PREROUTING` 规则；若 VPS 使用 Docker 或自定义端口转发，执行前请备份规则。
- `upx` / `ups` / `upa`：升级 Xray、Sing-box、Argo 内核。
- `res`：重启服务。
- `rep`：按当前填写的协议和变量重置/更新；必须至少选择一种协议。

可把之前保存的完整 SSH 命令粘贴到导入区域，恢复页面识别的协议与参数。导入后请再次检查字段，再执行命令。

## 原有自建管理器

`manager.html` 是另一套独立的 sing-box / Xray 管理器，包含 AnyTLS、VLESS WS、VLESS Reality、NaiveProxy、AnyTLS Reality、XHTTP + ECH、Snell 和 SS2022。它不是 ArgoSBX 的 15 协议生成器。

- `manager.html` 的 WS 客户端连接地址/优选 IP 字段会在启用 WS 时显示；可填写 IP，同时保留独立的 TLS SNI 和 WS Host。WS/Argo 若使用域名或 Cloudflare 地址，会归入域名 / Argo 分组；不会伪造第二个地址族节点。
- 注意：主页面 `index.html` 的 ArgoSBX 上游 `ippz` 仍按上游定义选择自动、仅 IPv4 或仅 IPv6；本次紧凑双栈同时导出的功能属于独立的 `manager.html` 管理器，不会向上游传入未经支持的 `ippz=46`。
- 安装后在 VPS 管理菜单选择 `1. 查看已安装协议节点链接`，可查看紧凑双栈输出。复制导入时，优先使用 `/etc/sing-box/nodes-ipv4.txt` 或 `/etc/sing-box/nodes-ipv6.txt`；Snell 使用同目录下对应的 `snell-client-ipv4.json` / `snell-client-ipv6.json`。
- 生成的安装命令会从 `https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh` 下载服务器端脚本。ZIP 内脚本为 v1.0.8；执行安装前，必须先把 ZIP 内的 `sb-manager-debian-alpine.sh` 上传覆盖到该 GitHub 仓库的 `main` 分支。网页现在同时检查 `WEB_CONFIG_SCHEMA=8` 和 v1.0.8 标记，旧版远程脚本会被拒绝，避免误装旧节点逻辑。
- 若 VPS 已存在本管理器的 `manager.json`，网页安装命令会走保留现有配置的覆盖安装流程，不会把网页新填参数自动覆盖到已有节点。已安装节点请通过 VPS 上的 `/usr/local/sbin/sb-manager` 管理菜单修改。
- 卸载命令会删除 `/etc/sing-box` 和 `/etc/xray`；现在必须输入大写 `YES` 才会继续。若这两个目录包含其他程序或手工配置，卸载前必须自行备份。
- 菜单 23 为全协议管理；菜单 24 为 SS2022 专项管理。
- 节点导出采用紧凑单行格式：`nodes.txt` 按 IPv4、IPv6、域名 / Argo 分组；另生成 `nodes-ipv4.txt`、`nodes-ipv6.txt`、`nodes-domain.txt`。这三个分组文件只含可直接复制的分享 URI，每行一个，没有标题或额外说明；IPv6 URI 自动使用方括号包裹地址。
- Snell 和 AnyTLS Reality 会额外生成按地址族区分的客户端 JSON（`*-ipv4.json` / `*-ipv6.json`）。Snell 没有通用分享 URI，因此不写入纯 URI 文本文件，而是在 `nodes.txt` 中列出对应 JSON 路径。XHTTP + ECH 仍使用证书域名连接，并在节点清单中提示额外导入 ECH Config。

## 安全说明

- 生成的 SSH 命令可能包含 UUID、Cloudflare Tunnel Token、DNS API Token 和订阅密码。Base64 不是加密，不要公开分享命令或截图。
- 页面只在本地浏览器生成命令，不会自动连接 VPS；真正执行的是命令引用的远程脚本。主生成器负责参数联动、校验和命令生成，ArgoSBX 服务端协议配置仍由上游脚本负责；本地自动化测试不能替代真实 VPS、Cloudflare Tunnel 和 ACME 证书申请验证。
- 先确认目标 VPS、协议、端口和防火墙规则，再执行安装。建议先在测试 VPS 验证客户端连接。

## 回归测试

在 Linux、WSL 或安装 Node.js 的环境中，从解压目录执行：

```sh
bash tests/run-all.sh
```

测试覆盖：15 种协议开关、15 种 WARP 组合、变量映射、参数依赖、端口与 Token 校验、命令导入/导出、动态警告、两个页面的 UI 联动、SSH 安装命令生成、SS2022 管理菜单、节点分享链接、IPv4/IPv6 地址格式、配置保留以及 Shell 语法。


## IPv4 + IPv6 一起导入

执行 `list` 或菜单中的节点显示功能后，会生成 `nodes-dualstack.txt`。该文件把 IPv4、IPv6（以及域名/Argo）分享 URI 合并为一个紧凑列表，IPv4 在前、IPv6 在后，每行一个可独立导入的节点。标准分享 URI 通常只支持一个 server 地址，因此双栈会以两个节点条目呈现，而不是伪造一个同时含两个地址的 URI。原有 `nodes-ipv4.txt`、`nodes-ipv6.txt` 和 `nodes-domain.txt` 仍保留。Snell 等不具备通用分享 URI 的协议仍使用对应 JSON 配置文件。
