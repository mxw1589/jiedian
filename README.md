> 🌐 **在线打开 HTML 配置面板：** [https://mxw1589.github.io/jiedian/](https://mxw1589.github.io/jiedian/)  
> 直接点击链接即可在浏览器中使用，无需下载 HTML。

---

# sing-box 单 VPS 可视化安装与管理工具

本项目用于在**单台 VPS** 上安装和管理 sing-box。

## 项目文件

- `index.html`：静态网页配置面板，可填写一台 VPS 的参数、预览节点名称并生成一键安装命令。
- `sb-manager-debian-alpine.sh`：服务端安装与管理脚本，支持 Debian / Ubuntu、Alpine。
- `README.md`：安装、卸载和 GitHub Pages 发布说明。
- `一键push到github.bat`：如果仓库中保留此文件，可在 Windows 上将项目文件推送到指定 GitHub 仓库。

网页不需要数据库或后端服务，可通过 GitHub Pages 免费发布。

## 功能简介

### 网页配置面板

- 浅色响应式界面（浅色背景、深色文字），支持电脑和手机浏览器。
- 当前网页面板用于配置一台 VPS。
- 五种协议：
  - AnyTLS
  - AnyTLS + Reality
  - VLESS + WS + TLS
  - VLESS + Reality
  - NaiveProxy
- 支持 IPv4 / IPv6 双栈监听，安装脚本自动检测 VPS 公网地址。
- 手动端口支持 `1024–65535`，五种协议的端口必须互不相同。留空时在 VPS 上随机分配可用端口；手动端口若被其他程序占用，脚本会自动改用该协议支持范围内的空闲端口。
- VLESS + WS + TLS 自动从 Cloudflare 支持的 HTTPS 端口 `2053`、`2083`、`2087`、`2096`、`8443` 中选择；其余协议随机使用 `10000–65535`。
- 支持 Cloudflare DNS-01 和 HTTP-01 两种网页证书方式。
- 可填写 Reality SNI、节点辨识符和 WS 连接地址。“优选 IP/域名”只改变 VLESS + WS + TLS 节点的客户端连接地址，不改变 TLS 证书域名、SNI 或 WS Host。
- 可预览节点名称，生成单台 VPS 的一键安装命令，并导出不含 Cloudflare Token 的单机配置 JSON。
- 网页表单内容仅在当前浏览器中参与命令生成，不会自动发送到 GitHub Pages。

### 服务端脚本

- 支持 Debian / Ubuntu 和 Alpine；Alpine 仓库没有 sing-box 包时，会自动改用官方 Linux 发布版。
- 支持 IPv4 / IPv6 双栈监听。
- 支持 Cloudflare DNS-01 自动申请和续期、HTTP-01 证书，以及 Shell 交互式安装中的手动导入证书。
- 自动尝试启用 TCP BBR。
- 自动生成五种协议节点链接。
- 支持修改节点辨识符、WS Host、TLS 域名、Reality SNI 和端口。
- 支持 NaiveProxy 本机监听、TLS 证书及 HTTP/2 诊断。
- 覆盖升级保留已有配置、证书、密钥、Cloudflare Token、Zone ID、UUID、密码、节点路径和端口。
- 覆盖升级前检查新配置；启动或状态写入失败时会尝试恢复旧配置与旧管理状态。
- 首次接管已有 `/etc/sing-box` 目录、但没有本脚本 `manager.json` 的 VPS 时，会先备份原目录，再继续安装。
- 提供服务状态、日志、重启和卸载功能。

## 一、不通过 HTML 直接安装

这种方式不需要打开网页，也不需要先生成网页命令。SSH 登录目标 VPS 后，以 `root` 身份执行下面整段命令。若当前不是 root，先执行 `sudo -i`，再粘贴命令。

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

脚本启动后会进入交互式安装向导，依次询问：

1. 证书方式：Cloudflare DNS-01、HTTP-01 或手动导入已有证书。
2. TLS 证书域名；Cloudflare 模式还需填写 DNS 区域根域名。
3. WS 优选 IP / 域名。
4. Reality SNI 和节点辨识符。
5. 五种协议的 TCP 端口；留空则自动分配。
6. Cloudflare 模式下的 API Token、证书邮箱和可选 Zone ID。

安装完成后，脚本会显示节点链接和需要放行的 TCP 端口，并安装管理命令：

```bash
/usr/local/sbin/sb-manager
```

**注意：** Cloudflare DNS-01 要求域名由你拥有或获准管理，并由 Cloudflare 托管。HTTP-01 要求证书域名解析到当前 VPS，且公网 TCP 80 可访问。手动导入证书时，请准备好证书文件和私钥文件。

## 二、通过 HTML 网页生成安装命令

1. 打开本项目的 GitHub Pages 网站（发布步骤见下文）。
2. 填写当前 VPS 的节点辨识符、域名、协议端口和证书信息。
3. 选择 Cloudflare DNS-01 时，填写 Cloudflare 根域名和 API Token；选择 HTTP-01 时，填写 TLS 证书域名。
4. 点击 **生成一键安装命令**。
5. 点击 **复制一键安装命令**，以 root 登录目标 VPS，将整段命令粘贴到 SSH 终端执行。
6. 安装结束后，节点信息会显示在终端，并保存到 `/etc/sing-box/nodes.txt`。

网页生成命令会下载本仓库的 Shell 脚本并传入网页配置。若 VPS 已存在本脚本的有效管理状态，命令会执行覆盖升级并保留已有配置；网页新填写的参数不会覆盖现有节点设置。

## 三、NAT VPS 使用 Cloudflare 优选 IP（详细步骤）

**可以使用，但主要适用于 VLESS + WebSocket + TLS 节点。** 本项目的“优选 IP/域名”只写入该 WS 节点的客户端连接地址；TLS SNI 仍使用证书域名，WebSocket Host 仍使用该证书域名。AnyTLS、VLESS Reality、AnyTLS + Reality 和 NaiveProxy 不会因为填写这个字段就自动走 Cloudflare 橙云代理。

### 先确认 NAT 端口映射条件

本脚本目前将协议的本机监听端口和节点分享链接端口设为同一个值。因此 NAT 服务商的**公网映射端口必须与 VPS 本机监听端口相同**。例如公网 `2053/TCP` 映射到 VPS 本机 `2053/TCP`，才符合当前脚本的端口模型；如果服务商只允许公网 `35867` 转发到本机 `2053` 这种“外部端口与内部端口不同”的映射，当前脚本不能正确生成这种端口转换节点，需要先让服务商提供同号映射端口。

Cloudflare 默认代理的 HTTPS 端口包括 `443`、`2053`、`2083`、`2087`、`2096` 和 `8443`。本项目的 WS TLS 自动端口池使用其中五个非 443 端口：`2053`、`2083`、`2087`、`2096`、`8443`。NAT 服务商必须实际分配其中一个端口，并允许它映射到 VPS 本机同号端口，才能让 WS TLS 走 Cloudflare 橙云代理。<https://developers.cloudflare.com/fundamentals/reference/network-ports/>

如果 NAT 服务商只给了其他端口（例如 `35867`），则可将 DNS 记录设为 **DNS only（灰云）**，让客户端直接连接 NAT 公网 IP 和服务商分配的端口；这种方式不能使用 Cloudflare 优选 IP 作为代理入口。普通 Cloudflare HTTP 代理不会转发任意 TCP 端口；额外的 TCP/UDP 代理需要 Cloudflare Spectrum 等相应产品。<https://developers.cloudflare.com/dns/proxy-status/limitations/>

### Cloudflare 橙云 + 优选 IP 操作步骤

1. **从 NAT 服务商面板确认信息。** 记录 NAT 公网 IPv4、已分配的公网 TCP 端口，并确认每个公网端口映射到 VPS 本机的同号端口。WS TLS 必须有 `2053`、`2083`、`2087`、`2096`、`8443` 中的一个可用映射端口。
2. **准备自己的域名。** 将域名 DNS 托管到 Cloudflare，并确认 Zone 状态为 Active。以下用 `example.com` 举例。
3. **添加 DNS 记录。** 在 Cloudflare → DNS → Records 添加 `A` 记录：Name 填 `node`，IPv4 address 填 NAT 服务商提供的公网 IPv4。将 Proxy status 设为 **Proxied（橙云）**。实际证书域名就是 `node.example.com`。Cloudflare 橙云会向客户端返回 Cloudflare Anycast 地址，再由 Cloudflare 将 HTTP/HTTPS 流量转发到源站。<https://developers.cloudflare.com/dns/proxy-status/>
4. **在网页填写证书参数。** 打开 [sing-box 网页面板](https://mxw1589.github.io/jiedian/)，Cloudflare 根域名填 `example.com`，Cloudflare 证书域名填 `node.example.com`，证书方式选择 Cloudflare DNS-01，并填写有 `Zone:DNS:Edit` 权限的 API Token。DNS-01 使用 TXT 验证，不要求 NAT VPS 的 TCP 80 入站可用。
5. **填写“优选 IP/域名”。** 这里填你测试可用的 Cloudflare 优选 IP（IPv4 或 IPv6），不是 NAT 服务商的公网 IP。若没有可靠的优选 IP，留空即可，客户端会使用 `node.example.com`。优选 IP 只作为客户端连接 Cloudflare 边缘的目标地址；节点的 TLS SNI 和 WS Host 仍应为 `node.example.com`。
6. **填写端口。** WS + TLS 填服务商分配的 Cloudflare 支持端口（例如 `2053`），并确认 NAT 公网 `2053` 映射到本机 `2053`。其余协议端口也必须使用服务商已分配的端口；不要在 NAT VPS 上对未分配端口使用自动随机值。
7. **生成并安装。** 生成网页命令，在 VPS root 终端执行。安装结束后，检查生成的 VLESS + WS + TLS 节点：地址应为优选 IP，端口为映射端口，`sni` 和 `host` 应为 `node.example.com`。
8. **检查 Cloudflare 和 NAT 防火墙。** 确认 WebSockets 在 Cloudflare Network 设置中启用；NAT 服务商防火墙/本机防火墙允许 Cloudflare 回源访问对应 TCP 端口。Cloudflare WebSockets 官方说明：<https://developers.cloudflare.com/network/websockets/>。
9. **测试节点。** 先用默认域名连接测试，再把“优选 IP/域名”换成优选 IP 重新生成/更新节点测试。若默认域名能连接而优选 IP 不能连接，说明该优选 IP 或其网络路由不可用，换一个已验证的 Cloudflare IP，或留空使用域名。

### NAT 端口冲突的特别注意

脚本现在遇到手动端口被其他进程占用时，会自动选择一个该协议支持范围内的空闲端口，并在终端显示最终端口。但**随机换出的端口不代表 NAT 服务商已经为它创建了公网映射**。如果发生自动换端口，必须同步在 NAT 服务商面板把新的公网端口映射到 VPS 本机同号端口，并更新防火墙规则；如果服务商无法分配新端口，就不要继续使用这个随机结果，应先从服务商取得新的可用映射端口。

### 优选 IP 的适用范围

- **适用：** VLESS + WS + TLS，且 DNS 记录为 Cloudflare Proxied（橙云），WS 端口为 Cloudflare 支持的 HTTPS 端口。
- **不适用：** 仅填写优选 IP 并不会让 AnyTLS、VLESS Reality、AnyTLS + Reality、NaiveProxy 通过 Cloudflare 普通橙云代理。它们应使用 NAT 服务商实际分配的公网 IP/端口直连，或使用专门支持 TCP 代理的服务。
- **域名参数不要混淆：** 优选 IP = 客户端连接目标；TLS 域名/SNI = 证书域名；WS Host = HTTP WebSocket Host。对本项目默认配置，这三个概念中后两者通常都是 `node.example.com`。

## 四、服务端管理命令

进入交互式管理菜单：

```bash
/usr/local/sbin/sb-manager
```

常用命令：

```bash
# 查看节点链接
/usr/local/sbin/sb-manager nodes

# 查看 BBR 状态
/usr/local/sbin/sb-manager bbr-status

# 重启服务
systemctl restart sing-box

# 卸载 sing-box 管理器
/usr/local/sbin/sb-manager uninstall
```

Alpine 使用 OpenRC 管理服务；可通过管理菜单执行重启和状态检查。

### 后期修改参数，确保节点同步

安装后应通过 `/usr/local/sbin/sb-manager` 管理菜单修改参数，不要直接编辑 `/etc/sing-box/config.json` 或 `manager.json`。

- 修改 TLS 证书域名：脚本会申请/检查新证书；如果 WS Host 原本跟随旧 TLS 域名，会自动同步更新。证书或配置应用失败时会尝试恢复旧证书和旧设置。
- 修改 Reality SNI：会同时更新 VLESS Reality 与 AnyTLS + Reality 两种节点。
- 修改 WS 连接地址（优选 IP）：只更新 VLESS + WS + TLS 客户端节点地址，不改服务端监听配置、TLS SNI 或 WS Host。在管理菜单提示中输入 `-`，可清除优选 IP 并恢复使用证书域名。
- 修改 WS Host：更新 VLESS + WS + TLS 节点中的 Host 参数。
- 修改五种协议端口：脚本会重新检查端口、生成完整 sing-box 配置、运行 `sing-box check`，然后重启服务；新配置启动失败时会尝试恢复旧配置和旧管理状态。成功后会重新生成 `/etc/sing-box/nodes.txt` 中的全部节点链接。

端口修改成功后，必须同步更新云安全组、本机防火墙和 NAT 服务商端口映射，并重新导入最新节点链接。NAT VPS 的公网映射端口必须与本机监听端口同号；随机换出的端口也必须在服务商面板完成映射。

### 卸载范围

在需要卸载的 VPS 上，以 root 身份执行：

```bash
/usr/local/sbin/sb-manager uninstall
```

卸载命令会立即执行，不再要求输入大写确认文本。执行前请确认 SSH 连接的是正确的 VPS，并备份仍需保留的节点信息和配置。

- **将删除：** `/etc/sing-box` 管理目录及其中的配置和证书副本、`/usr/local/sbin/sb-manager`、sing-box 服务文件、证书重载钩子，以及本脚本安装的 sing-box 软件包。脚本还会清理自己创建的 BBR 持久化配置，并尝试恢复安装前的 TCP 拥塞控制参数。
- **不会删除：** `/root/.acme.sh`、系统依赖包、sing-box 系统用户/组、系统防火墙规则、云厂商安全组或其他 cron 任务。

卸载操作不可直接撤销；如需重新使用，必须重新安装并重新配置服务。

## 五、发布到 GitHub Pages，并在线打开 HTML

本项目仓库：<https://github.com/mxw1589/jiedian>

### 1. 确认文件位置

仓库根目录应包含：

```text
jiedian/
├── index.html
├── README.md
└── sb-manager-debian-alpine.sh
```

如果仓库原本有 `一键push到github.bat`，可以继续保留。`index.html` 必须放在你准备发布的目录顶层；这里使用仓库根目录。

### 2. 上传或更新文件

1. 登录 GitHub，打开：<https://github.com/mxw1589/jiedian>。
2. 点击仓库页面的 **Add file → Upload files**。
3. 将更新后的 `index.html`、`README.md` 和 `sb-manager-debian-alpine.sh` 三个文件拖入上传区域。
4. 等待文件上传完成，滚动到页面下方 **Commit changes**。
5. 填写提交说明，例如 `Simplify single VPS installer`。
6. 选择提交到 `main` 分支，然后点击 **Commit changes**。

不要上传 Cloudflare Token、SSH 私钥、证书私钥、节点订阅链接或 VPS 导出的敏感配置。

### 3. 开启 GitHub Pages

1. 在仓库顶部点击 **Settings**。如果看不到 Settings，请确认当前账号对仓库有管理员或维护者权限。
2. 在左侧菜单找到 **Code and automation → Pages**。
3. 在 **Build and deployment** 区域，将 **Source** 设为 **Deploy from a branch**。
4. 在 **Branch** 下拉框选择 `main`。
5. 右侧目录选择 `/(root)`。
6. 点击 **Save**。
7. 提交后 GitHub Pages 会自动触发发布。不需要从 Actions 模板中选择 Next.js / Jekyll，也不需要手动创建工作流。若要查看部署状态，可在仓库顶部 **Actions** 中查看 GitHub Pages 自动生成的部署任务。
8. 回到 **Settings → Pages**，发布成功后点击 **Visit site**。

### 4. 在线打开网页

本项目预期的在线网页地址是：

**<https://mxw1589.github.io/jiedian/>**

以后只要把新的 `index.html` 提交到 `main` 分支的仓库根目录，GitHub Pages 就会自动重新发布。网页显示旧版本时，在浏览器按 `Ctrl + F5` 强制刷新，或稍等部署完成后再打开。

### 5. 区分三个不同地址

- **真正运行网页：** <https://mxw1589.github.io/jiedian/>
- **GitHub 源码页面：** <https://github.com/mxw1589/jiedian/blob/main/index.html>（这里显示 HTML 代码，不是网页效果）
- **Shell 脚本原始下载地址：** <https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh>

GitHub Pages 的入口文件必须是 `index.html`，并且放在所选发布目录的顶层。GitHub Pages 网站会公开在互联网上；发布前请检查仓库和网页中没有任何敏感凭据。

### 6. 视频教程

- **GitHub 官方入门视频：** [Getting started with GitHub Pages for beginners](https://www.youtube.com/watch?v=b2r9Cdvssi0)。视频章节：00:55 从分支发布；01:26 使用 GitHub Actions；02:44 自定义域名；03:15 强制 HTTPS。
- **2026 年图文同步视频：** [Host Your First Website FREE with GitHub Pages (2026)](https://www.youtube.com/watch?v=LnNHdc562Xg)。包含上传 `index.html`、设置 `main` + `/(root)`、等待构建和打开网页的屏幕演示。
- **GitHub 官方文档：** [Configuring a publishing source for your GitHub Pages site](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)。

## 六、安全说明

- HTML 是静态前端，表单参数只在当前浏览器中处理，不会自动发送到 GitHub Pages。
- 网页生成的单机安装命令会把 Cloudflare API Token 进行 Base64 编码。Base64 不是加密；任何拿到该命令的人都可以解码 Token。请只在自己的 VPS root 终端使用，不要公开分享或提交到 GitHub。
- 如果不希望 Token 出现在生成命令中，可以改用 HTTP-01；但必须满足域名解析和公网 TCP 80 可访问的要求。
- 不要把 Cloudflare Token、SSH 私钥、证书私钥、节点链接或导出的敏感配置提交到公开仓库。
- 只在自己拥有或获准管理的 VPS 和域名上使用。
