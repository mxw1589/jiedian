# Jiedian 管理器 1.5.0 — 节点 IPv4 / IPv6 类型选择

本版本基于 Jiedian Manager 1.4.9 继续开发，保留现有协议、Snell v6、NaiveProxy、Argo Tunnel、证书管理、端口历史、状态备份和安装回滚逻辑，并新增 **节点 IPv4 / IPv6 类型选择**。

项目主页：<https://mxw1589.github.io/jiedian/>  
GitHub：<https://github.com/mxw1589/jiedian/>

## 1.5.0 更新内容

### 节点 IP 类型选择

网页新增三个互斥选项，第一个默认选中：

- **IPv4 + IPv6 双栈节点（默认）**：为直接使用 IP 的协议分别生成 IPv4 与 IPv6 节点；需要可用的两种源站地址。
- **仅 IPv4 节点**：只生成 IPv4 地址节点。
- **仅 IPv6 节点**：只生成 IPv6 地址节点。

该选项只影响节点链接和客户端配置文件中的连接地址，不修改 sing-box 服务端监听地址、协议入站、端口或防火墙。选择的地址族缺少对应源站地址时，安装器会停止并给出提示，不会生成一个不可连接的假节点。

TLS 域名型节点（例如 NaiveProxy，以及 WS / Argo 使用域名连接地址时）仍以域名输出，因为 TLS 证书和 SNI 需要域名；域名的 A / AAAA 解析由客户端 DNS 和网络环境决定，不能仅凭 URI 强制所有客户端只用某个地址族。若 WS / Argo 手动填写 IP 字面量，网页会检查它是否与所选地址族匹配。

节点 IP 类型会写入 `/etc/sing-box/manager.json`，后续管理器重新生成节点信息时继续沿用。旧版 manager.json 未记录该字段时默认双栈。

网页配置升级到 Schema 11；后端继续兼容 Schema 5–10。旧协议保留 / 替换按钮仍默认选择“保留以前的协议”。

### ZIP 解压与测试

将发布 ZIP 上传到 VPS 后执行（文件名按实际下载名称调整）：

```bash
apt-get update
apt-get install -y unzip python3 jq
mkdir -p /opt/jiedian
unzip -o Jiedian_HTTP01_1.5.0_NodeIPModes.zip -d /opt/jiedian
cd /opt/jiedian/Jiedian_HTTP01_1.5.0_NodeIPModes
sha256sum -c SHA256SUMS.txt
sh tests/run-tests.sh
```

以上只解压和测试源码，不会自动覆盖运行中的管理器。网页安装仍须通过同版本 `index.html` 生成的命令，远端 Shell 版本和 SHA-256 必须匹配。

## 1.4.9 更新内容

### 旧协议处理按钮

网页新增两个互斥选项：

- **保留以前的协议（默认）**：本次勾选的协议新增或更新；旧安装中已存在但本次未勾选的协议继续保留。
- **不保留以前的协议**：只保留本次勾选的协议；未勾选的旧协议会从 sing-box 配置和 manager.json 状态中移除。

保留模式会继续使用旧协议已有端口和凭据。若旧协议共享 TLS 证书域名或 Reality SNI，且本次只更新其中一部分，安装器会拒绝不兼容的共享参数更改，避免悄悄破坏未勾选的旧节点。首次安装时没有旧节点，两种方式效果相同。

网页配置升级到 Schema 10。Shell 后端仍兼容旧 Schema 5–9；旧版本配置按原来的替换同步语义处理。

### ZIP 解压与测试

将发布 ZIP 上传到 VPS 后执行（文件名按实际下载名称调整）：

```bash
apt-get update
apt-get install -y unzip python3 jq
mkdir -p /opt/jiedian
unzip -o Jiedian_HTTP01_1.4.9_ProtocolPolicy.zip -d /opt/jiedian
cd /opt/jiedian/Jiedian_HTTP01_1.4.9_ProtocolPolicy
sha256sum -c SHA256SUMS.txt
sh tests/run-tests.sh
```

以上只解压和测试源码，不会自动覆盖运行中的管理器。网页安装仍须通过同版本 `index.html` 生成的命令，远端 Shell 版本和 SHA-256 必须匹配。

## 1.4.8 更新内容

### Snell v6

- 新增 Snell v6 服务端入站配置，使用 sing-box 内置协议实现，不需要另外下载独立 Snell 服务端。
- Snell v6 从 **sing-box 1.14.0** 开始支持。安装器会在选择 Snell v6 时检查最低内核版本；低于 1.14.0 时会尝试安装满足要求的官方内核，不会把旧内核误报为兼容。
- 服务端自动生成 32 字节随机 PSK（64 个十六进制字符）；PSK 不写入网页静态文件，也不会放入公开链接。
- 提供 `default`（推荐）和 `unshaped` 两种模式。`default` 使用流量整形；`unshaped` 关闭整形但仍保留 AEAD 加密。不在网页中提供会移除加密层的 `unsafe-raw`。
- 管理器生成权限为 `0600` 的 sing-box 客户端 JSON：`/etc/sing-box/snell-v6-client-primary.json`，若设置了独立 IPv6 地址，还会生成 `snell-v6-client-ipv6.json`。
- 管理菜单支持增量添加、删除、修改端口、修改 mode、轮换 PSK 和重新生成客户端配置。
- 端口与其他协议共同参与冲突检测和端口历史管理。Snell v6 使用一个 TCP 监听端口。
- 不生成虚构的 `snell://` 分享 URI。通过 sing-box 客户端 JSON 导入，或在兼容客户端中手动填写服务器地址、端口、版本、PSK 和 mode。

官方配置依据：
- [sing-box Snell inbound](https://sing-box.sagernet.org/configuration/inbound/snell/) — Snell v6 结构及最低版本。
- [sing-box Snell outbound](https://sing-box.sagernet.org/configuration/outbound/snell/) — 客户端出站结构。

### 网页界面

- 所有协议的勾选框、协议名称和端口输入框现在放在同一行。
- 采用浅色背景、紧凑卡片、双列响应式布局；窄屏自动改为单列，但每个协议的端口仍与名称同行。
- 新增 Snell v6 勾选项和 mode 选择。
- 网页配置升级为 Schema 9；管理器仍兼容旧 Schema 5–8 配置。Schema 9 对启用协议的端口重复和占用继续严格失败关闭。
- 网页安装器固定校验 Shell 版本、功能标记、POSIX Shell 语法和 SHA-256；不匹配时不会替换现有管理器。

### 保留的协议与功能

- AnyTLS
- AnyTLS + Reality
- VLESS + WebSocket + TLS（直连 / Cloudflare Argo）
- VLESS + Reality
- Shadowsocks 2022
- NaiveProxy（标准域名分享链接、TLS SNI、HTTP/2 ALPN、TCP / sing-box UDP-over-TCP 客户端配置）
- **Snell v6**
- Debian / Ubuntu / Alpine；POSIX `sh`、dash、BusyBox ash
- HTTP-01 / Cloudflare DNS-01 / 手动证书、证书校验和回滚
- systemd / OpenRC、Cloudflare Tunnel、BBR、节点导出、端口历史

## Snell v6 使用方法

### 需要准备的信息

1. **服务器地址**：可以是 VPS 公网 IPv4、IPv6 或直连 DNS 域名。域名应解析到 VPS 源站，不要把 Cloudflare 橙云代理地址当作任意 TCP 代理入口。
2. **TCP 端口**：网页中可以手动填写 1024–65535 的端口；留空则优先复用历史端口，否则自动分配。
3. **PSK**：由管理器自动生成，无需提前准备。安装后可在菜单 20 的 Snell v6 专属参数中查看 / 轮换。
4. **版本**：Snell `version=6`，服务端和客户端 sing-box 均需 1.14.0 或更新版本。
5. **mode**：默认 `default`；可选 `unshaped`。建议先用 `default`。

Snell v6 不需要 TLS 证书、TLS SNI、Reality SNI、Cloudflare Token 或单独的 Snell 二进制。标准 Snell v6 的 UDP 流量由 TCP 连接承载，服务器防火墙通常只需放行所选 TCP 端口；客户端需启用 UDP 网络支持。

### 网页安装步骤

1. 打开 <https://mxw1589.github.io/jiedian/>。
2. 勾选 **Snell v6**。端口框与协议名称在同一行；留空代表自动分配。注意网页默认预选 Argo WS；如果只需要 Snell，请取消 Argo WS 勾选，否则安装器还会要求 Cloudflare Tunnel Token。
3. 在“Snell v6 参数”中选择 `default`（推荐）或 `unshaped`。
4. 在“节点 IP 类型”中选择双栈、仅 IPv4 或仅 IPv6。IPv6-only VPS 应选择“仅 IPv6”，并在源站 IPv6 项填写公网 IPv6；客户端网络必须具备 IPv6 连通性。双栈选项要求两种地址均可用。
5. 复制网页自动生成的安装 / 同步命令，在 VPS root SSH 终端执行。
6. 安装完成后执行 `/usr/local/sbin/sb-manager`，查看节点信息；管理器会输出 TCP 端口、PSK 和客户端 JSON 文件位置。
7. 在 VPS 防火墙及服务商安全组放行该 TCP 端口。如果使用 NAT VPS，还需要把公网映射端口映射到该 VPS 的本机 TCP 监听端口。

### 导入客户端

安装完成后，客户端配置文件位于：

```text
/etc/sing-box/snell-v6-client-primary.json
/etc/sing-box/snell-v6-client-ipv6.json   # 仅在存在独立 IPv6 地址时生成
```

通过 SSH/SFTP 安全下载，例如：

```bash
scp root@YOUR_SERVER:/etc/sing-box/snell-v6-client-primary.json ./snell-v6-client.json
```

然后在支持 sing-box 1.14.0+ 的客户端中选择“导入配置文件 / 从文件导入”，选择 `snell-v6-client.json`，再启用该配置。该完整配置默认创建本机 `127.0.0.1:2080` mixed（HTTP/SOCKS）入站，并将出站路由到 Snell v6。若客户端已有自己的完整配置，不要直接覆盖；请将 JSON 中的 Snell outbound 合并到现有 `outbounds`，并按自己的路由需求设置 `route.final`。
手动合并时的 Snell outbound 结构示例：

```json
{
  "type": "snell",
  "tag": "snell-v6",
  "server": "2001:db8::1234",
  "server_port": 23456,
  "version": 6,
  "psk": "替换为管理器生成的PSK",
  "mode": "default"
}
```

本项目不生成非标准或未经验证的 `snell://` 分享链接。

客户端 JSON 包含 PSK，服务器端文件权限为 `0600`。请勿把 JSON、PSK 或网页生成的安装命令提交到公开 GitHub、截图或群聊。若怀疑泄露，请在管理菜单 20 轮换 PSK，并重新导入新配置。

### IPv6-only VPS 的重要限制

如果 VPS 只有公网 IPv6（没有公网 IPv4），Snell v6 仍可正常提供 IPv6 入站，但连接它的客户端也必须能访问 IPv6。**IPv4-only 客户端不能直接连接 IPv6-only VPS。** NAT64 只可能解决 VPS 主动访问 IPv4 网站的出站问题，不会凭空提供 IPv4 入站地址。若需要 IPv4-only 客户端连接，必须另行提供 IPv4 网关 / NAT 端口转发或独立公网 IPv4。

## ZIP 下载、解压与测试

### 从 GitHub Pages 对应仓库下载 main 分支 ZIP（发布到 GitHub 后使用）

```bash
apt-get update
apt-get install -y curl unzip python3 jq
curl -fL --retry 3 --connect-timeout 10 \
  https://github.com/mxw1589/jiedian/archive/refs/heads/main.zip \
  -o /tmp/jiedian-main.zip
mkdir -p /opt/jiedian
unzip -o /tmp/jiedian-main.zip -d /opt/jiedian
cd /opt/jiedian/jiedian-main
sha256sum -c SHA256SUMS.txt
sh tests/run-tests.sh
```

### 使用本次发布包 ZIP

将本发布包下载到本地或 VPS 后，使用以下命令解压：

```bash
apt-get update
apt-get install -y unzip python3 jq
mkdir -p /opt/jiedian
unzip -o Jiedian_HTTP01_1.5.0_NodeIPModes.zip -d /opt/jiedian
cd /opt/jiedian/Jiedian_HTTP01_1.5.0_NodeIPModes
sha256sum -c SHA256SUMS.txt
sh tests/run-tests.sh
```

这一步是解压项目源码并运行测试，不会自动覆盖 VPS 正在运行的 `/usr/local/sbin/sb-manager`。实际安装 / 更新仍应通过网页生成的、带版本和 SHA-256 校验的命令执行。
当前网页固定校验的管理脚本 SHA-256：`89ced94889fc21b64c78918102dffcb95630dabc17e66d951af4afd71d0be243`。若修改 `sb-manager-debian-alpine.sh`，必须同步更新 `index.html` 中的 `EXPECTED_SHA256`，否则网页会安全拒绝安装。

## 发布到 GitHub Pages

将 ZIP 解压到本地，然后将项目文件同步到仓库 `mxw1589/jiedian` 的 `main` 分支。示例（假设 ZIP 和解压目录位于当前用户目录）：

```bash
unzip -o Jiedian_HTTP01_1.5.0_NodeIPModes.zip -d /tmp/jiedian-release

git clone https://github.com/mxw1589/jiedian.git /tmp/jiedian-repo
cp -a /tmp/jiedian-release/Jiedian_HTTP01_1.5.0_NodeIPModes/. /tmp/jiedian-repo/
cd /tmp/jiedian-repo
sha256sum -c SHA256SUMS.txt

git add index.html sb-manager-debian-alpine.sh README.md CHANGELOG.md AUDIT.md docs tests SHA256SUMS.txt VERSION
git commit -m "Release Jiedian Manager v1.5.0 with node IP family selection"
git push origin main
```

注意：GitHub 仓库如果不存在 `README_CN.md`，`git add` 命令中的该文件名可删除。建议先在 GitHub 仓库确认 Pages 的发布源是 `main` 分支根目录。部署顺序上，Shell 和 HTML 应来自同一个 ZIP；网页会校验远端 Shell 的精确 SHA-256。

## 回归测试

在 Linux、macOS 或 WSL 中运行：

```sh
./tests/run-tests.sh
```

测试覆盖 POSIX Shell / dash / BusyBox ash、网页 HTML ID 与 JavaScript 引用、网页安装器完整性、端口冲突、NaiveProxy 配置、Snell v6 版本门槛和客户端 JSON、证书 / ACME 回滚、Cloudflare 凭据、NAT64 / HTTP-01 诊断、Cron 所有权、管理器锁和 systemd / OpenRC 检测。

## 验证边界

自动化测试验证本地生成逻辑、JSON 结构、版本门槛、端口冲突和文件权限；并不等于已在所有 Debian / Ubuntu / Alpine 发行版、所有客户端 App 或用户实际 VPS 上完成真实外网连接和吞吐量测试。发布前请在测试 VPS 上运行 sing-box `check`，并从独立 IPv6 网络实际导入客户端测试 TCP 连接和 DNS。

## 旧协议保留 / 替换模式使用说明

在网页协议列表下方选择旧协议处理方式：

1. **保留以前的协议**（默认）：未勾选的旧节点仍保持启用；勾选的协议可以新增或更新。
2. **不保留以前的协议**：仅保留本次勾选的协议，未勾选的旧节点会被移除。

保留模式会尽量复用旧端口、密码、UUID、PSK、证书和 Argo 凭据。由于 AnyTLS、NaiveProxy、直连 WS 共用 TLS 域名 / 证书，两个 Reality 入站共用 Reality SNI，如果保留的旧协议依赖这些共享参数，安装器会阻止对其进行不兼容的更改。此时可恢复原参数，或选择替换模式后再修改。

选择结果会写入网页生成的 Schema 10 JSON，并由服务器端管理器执行；不是仅改变网页提示。

## 节点 IP 类型选择说明

- **IPv4 + IPv6 双栈**（默认）：对 AnyTLS、Reality、Shadowsocks 2022、Snell v6 等直接使用源站 IP 的协议，分别生成 IPv4 和 IPv6 地址节点；相应源站地址必须都可用。
- **仅 IPv4**：只输出 IPv4 IP 字面量节点。
- **仅 IPv6**：只输出 IPv6 IP 字面量节点。

选择只影响 `nodes.txt`、Snell v6 / AnyTLS + Reality 客户端 JSON 的服务器地址，不改变服务端监听和网络栈。WS / Argo / Naive 等基于 TLS 域名的节点继续输出域名，因为证书校验与 SNI 依赖域名；客户端会根据自己的 DNS / 网络环境选择 A 或 AAAA。域名并不等同于强制 IPv4 或 IPv6。

若所选模式需要 IPv4 或 IPv6，而 VPS 没有对应可用地址，安装器会提示补充地址或切换模式，不会把 NAT64 出口地址误当作 IPv4 入站地址。节点 IP 类型保存在 manager.json，旧安装默认按双栈显示。
