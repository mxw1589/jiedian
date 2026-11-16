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

- 深色响应式界面，支持电脑和手机浏览器。
- 当前网页面板用于配置一台 VPS。
- 五种协议：
  - AnyTLS
  - AnyTLS + Reality
  - VLESS + WS + TLS
  - VLESS + Reality
  - NaiveProxy
- 支持 IPv4 / IPv6 双栈监听，安装脚本自动检测 VPS 公网地址。
- 手动端口支持 `1024–65535`，五种协议的端口必须互不相同。留空时在 VPS 上随机分配可用端口。
- VLESS + WS + TLS 自动从 Cloudflare 支持的 HTTPS 端口 `2053`、`2083`、`2087`、`2096`、`8443` 中选择；其余协议随机使用 `10000–65535`。
- 支持 Cloudflare DNS-01 和 HTTP-01 两种网页证书方式。
- 可填写 Reality SNI、节点辨识符和 WS 连接地址。
- 可预览节点名称，生成单台 VPS 的一键安装命令，并导出不含 Cloudflare Token 的单机配置 JSON。
- 网页表单内容仅在当前浏览器中参与命令生成，不会自动发送到 GitHub Pages。

### 服务端脚本

- 支持 Debian / Ubuntu 和 Alpine。
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

## 三、服务端管理命令

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

### 卸载范围

在需要卸载的 VPS 上，以 root 身份执行：

```bash
/usr/local/sbin/sb-manager uninstall
```

卸载命令会立即执行，不再要求输入大写确认文本。执行前请确认 SSH 连接的是正确的 VPS，并备份仍需保留的节点信息和配置。

- **将删除：** `/etc/sing-box` 管理目录及其中的配置和证书副本、`/usr/local/sbin/sb-manager`、sing-box 服务文件、证书重载钩子，以及本脚本安装的 sing-box 软件包。脚本还会清理自己创建的 BBR 持久化配置，并尝试恢复安装前的 TCP 拥塞控制参数。
- **不会删除：** `/root/.acme.sh`、系统依赖包、sing-box 系统用户/组、系统防火墙规则、云厂商安全组或其他 cron 任务。

卸载操作不可直接撤销；如需重新使用，必须重新安装并重新配置服务。

## 四、发布到 GitHub Pages，并在线打开 HTML

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
3. 将更新后的 `index.html` 和 `README.md` 拖入上传区域。若 Shell 脚本本次没有修改，不必重新上传；若也更新了脚本，则同时上传 `sb-manager-debian-alpine.sh`。
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
7. 打开仓库顶部的 **Actions**，等待名为 Pages build and deployment 的工作流运行成功。
8. 回到 **Settings → Pages**，点击 **Visit site**。

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

## 五、安全说明

- HTML 是静态前端，表单参数只在当前浏览器中处理，不会自动发送到 GitHub Pages。
- 网页生成的单机安装命令会把 Cloudflare API Token 进行 Base64 编码。Base64 不是加密；任何拿到该命令的人都可以解码 Token。请只在自己的 VPS root 终端使用，不要公开分享或提交到 GitHub。
- 如果不希望 Token 出现在生成命令中，可以改用 HTTP-01；但必须满足域名解析和公网 TCP 80 可访问的要求。
- 不要把 Cloudflare Token、SSH 私钥、证书私钥、节点链接或导出的敏感配置提交到公开仓库。
- 只在自己拥有或获准管理的 VPS 和域名上使用。
