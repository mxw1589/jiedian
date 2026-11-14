# sing-box 多 VPS 可视化部署工具

本仓库包含：

- `index.html`：静态网页配置面板，可在浏览器中填写多台 VPS 配置、生成单机命令和批量部署脚本。
- `sb-manager-debian-alpine.sh`：sing-box 服务端安装与管理脚本，支持 Debian / Ubuntu、Alpine。
- 网页不需要数据库或后端服务，可直接通过 GitHub Pages 发布。

## 功能简介

### 网页配置面板

- 深色双栏界面，支持电脑和手机浏览器。
- 可添加多台 VPS，每台 VPS 独立填写 SSH 地址、SSH 端口、IPv4、IPv6、WS 连接地址和节点辨识符。
- 五种协议全部启用，每台 VPS 手动指定五个 TCP 监听端口：
  - AnyTLS
  - AnyTLS + Reality
  - VLESS + WS + TLS
  - VLESS + Reality
  - NaiveProxy
- 端口范围为 `1024–65535`；同一台 VPS 的五个端口必须互不相同。
- 全局配置包括默认 TLS 证书域名、默认 WS HTTP Host、Reality SNI、证书方式和 Cloudflare 区域信息；每台 VPS 也可以单独覆盖 TLS 域名和 WS Host。
- Reality SNI 默认 `www.bing.com`。
- 可预览各 VPS 将生成的节点名称。
- 可生成单台 VPS 的一键安装命令。
- 可生成 `deploy-multi.sh`，从本机通过 SSH 密钥批量部署多台 VPS。
- 批量部署成功后，将每台 VPS 的完整节点清单合并到 `all-nodes.txt`。

### 节点命名规则

节点名包含地址、可选自定义辨识符和协议名。例如：

```text
ipv4-8.8.8.8-vless+ws+tls
ipv4-8.8.8.8-Tokyo01-anytls
ipv6-2602:f8c0::1234-vless+reality
domain-edge.example.com-naiveproxy
```

自定义辨识符支持中文、英文字母、数字、点、下划线和短横线，最多 20 个字符。多 VPS 使用 Cloudflare DNS-01 时，建议每台 VPS 使用不同的 TLS 子域名（例如 `vps1.example.com`、`vps2.example.com`），在对应 VPS 卡片中填写“TLS 域名覆盖”，以避免反复为相同域名申请重复证书触发 CA 签发限制。

VLESS WS TLS 仍然只生成一个节点，不拆成 IPv4 / IPv6 两个节点；节点名前缀根据填写的 WS 单一连接地址自动识别为 `ipv4-`、`ipv6-` 或 `domain-`。

### 服务端脚本

- 支持 IPv4 / IPv6 双栈监听。
- 网页批量部署时由用户为五种协议分别指定端口；直接运行 Shell 交互式安装时，仍可选择随机端口或手动端口。
- 端口检查：范围检查、同机重复检查、当前 TCP 监听占用检查。
- 支持 Cloudflare DNS-01 自动申请和续期，或 HTTP-01 证书方式；Shell 交互式安装另外保留手动导入证书选项。
- 自动尝试启用 TCP BBR。
- 自动生成五种协议节点链接。
- 支持节点辨识符修改、WS Host 修改、TLS 域名和 Reality SNI 修改。
- 支持 NaiveProxy 本机监听、TLS 证书及 HTTP/2 诊断。
- 覆盖安装保留已有配置、证书、密钥、Token 和端口。
- 提供服务状态、日志、重启和卸载功能。

## 发布到 GitHub Pages

把以下文件放在现有仓库 `mxw1589/jiedian` 的根目录：

```text
jiedian/
├── index.html
├── README.md
└── sb-manager-debian-alpine.sh
```

保持 Shell 文件路径和名称不变：

`sb-manager-debian-alpine.sh`

网页中使用的脚本下载地址：

`https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh`

### GitHub 网页操作

1. 打开仓库：<https://github.com/mxw1589/jiedian>
2. 点击 **Add file → Upload files**。如果仓库根目录已经有 `index.html`，先备份它，避免覆盖现有网站首页。
3. 上传 `index.html`、更新后的 `sb-manager-debian-alpine.sh` 和 `README.md`。
4. 提交到 `main` 分支。
5. 打开仓库 **Settings → Pages**。
6. 在 **Build and deployment** 中选择 **Deploy from a branch**。
7. Branch 选择 `main`，目录选择 `/(root)`，点击 **Save**。
8. 等待 GitHub Pages 发布完成。

网页地址：

<https://mxw1589.github.io/jiedian/>

如果 Pages 尚未启用，或仓库权限/可见性不符合 GitHub Pages 当前计划要求，需要先在仓库 Settings 中完成相应设置。

## 单台 VPS 部署

1. 打开 GitHub Pages 网页。
2. 添加一台 VPS，填写 `root@服务器IP`、SSH 端口、公网 IPv4 / IPv6、WS 连接地址。
3. 为五种协议分别填写端口。
4. 填写全局默认 TLS 证书域名、Reality SNI 和证书方式；多 VPS 建议为每台 VPS 设置独立 TLS 子域名覆盖。网页批量模式使用手动端口。
5. 点击对应 VPS 卡片的 **单机命令**。
6. 复制命令，在目标 VPS 的 root SSH 终端粘贴执行。
7. 如果选择 Cloudflare DNS-01，命令执行时会在 VPS 终端安全提示输入 API Token。
8. 安装结束后，脚本会在终端显示全部节点，并保存到 `/etc/sing-box/nodes.txt`。

## 多 VPS 批量部署

网页生成的 `deploy-multi.sh` 需要下载到你自己的电脑运行，不是在 GitHub Pages 服务器上运行。

### 环境要求

- Linux、macOS 或 Windows WSL。
- Bash、SSH 客户端、curl、base64。
- 使用 Cloudflare DNS-01 时，本机还需要 `jq`。
- 每台 VPS 都需要允许 root 使用 SSH 公钥登录；网页不会保存 SSH 密码或私钥。

Ubuntu / Debian / WSL 可安装本机依赖：

```bash
sudo apt update
sudo apt install -y openssh-client curl jq coreutils
```

### 执行步骤

1. 在网页中添加全部 VPS，并填写每台 VPS 的 SSH 登录目标，例如 `root@23.147.232.192`。
2. 每台 VPS 分别填写五个端口；同一 VPS 内不能重复，不同 VPS 之间可以使用相同端口。
3. 点击 **生成多 VPS 部署脚本**，网页会下载 `deploy-multi.sh`。
4. 在本机终端进入下载目录，执行：

```bash
chmod 700 deploy-multi.sh
./deploy-multi.sh
```

5. 按提示选择 SSH 私钥路径；留空则使用 ssh-agent 或默认 SSH 密钥。
6. 如果证书方式为 Cloudflare DNS-01，在本机提示时输入一次 Cloudflare API Token。
7. 脚本通过 SSH 把每台 VPS 的配置传送到远端，再下载 GitHub 上的 Shell 安装脚本并执行。
8. 成功部署的节点链接会合并保存为当前目录下的 `all-nodes.txt`。

`all-nodes.txt` 包含节点密码、UUID 和 Reality 公钥等敏感连接信息。请妥善保管，不要上传到公开仓库或发送给不可信的人。

### 批量部署注意事项

- 批量部署要求 SSH 公钥认证；不建议把 VPS root 密码写进脚本。
- 目前批量模式面向**首次安装**。如果目标 VPS 已经存在本脚本的管理配置，脚本会拒绝覆盖，避免误覆盖原有节点。
- Cloudflare DNS-01 可让多台 VPS 共用同一个 Cloudflare DNS Zone 和 API Token；但每台 VPS 最好使用不同的 TLS 子域名。若多台机器连续为完全相同的域名分别申请证书，可能触发 CA 的重复证书签发限制。
- HTTP-01 要求每台 VPS 的证书域名分别解析到对应 VPS，且公网 TCP 80 可访问；多 VPS 请为每台 VPS 使用独立域名。Cloudflare DNS-01 可共用一个 Zone 和 Token，但建议仍为每台 VPS 使用独立子域名。
- 如果 WS TLS 使用 Cloudflare 橙云代理，必须使用 Cloudflare 支持代理的 HTTPS 端口；自定义的其他端口通常应使用 DNS Only（灰云）直连，或采用适合的代理产品。
- 网页只能做格式和重复值预检；VPS 上还会检查端口范围、同机端口冲突和监听占用。
- 服务端不会自动修改云厂商安全组。请在云平台和 VPS 防火墙中开放五个 TCP 端口。
- 当前脚本只接受 `1024–65535`，因为 sing-box 以非 root 用户运行，不直接绑定 `1–1023` 特权端口。
- NAT 模式按“公网端口 = VPS 本机监听端口”处理；如果服务商把公网端口映射到不同的内网端口，本版本不能自动处理这种端口转换。

网页批量配置目前提供 Cloudflare DNS-01 和 HTTP-01 两种证书模式；如果要使用目标 VPS 上已经存在的手动证书，请直接在 VPS 运行 Shell 交互式安装向导。

## 服务端管理命令

安装完成后：

```bash
/usr/local/sbin/sb-manager
```

常用命令：

```bash
/usr/local/sbin/sb-manager nodes
/usr/local/sbin/sb-manager bbr-status
/usr/local/sbin/sb-manager uninstall
```

## 安全说明

- 网页是纯静态文件，表单数据不会自动发送到 GitHub Pages，也不会保存到网页服务器。
- 单机命令只包含服务器参数，不包含 Cloudflare API Token；执行时在 VPS 终端输入 Token。
- 批量部署脚本不预置 Token；运行时在本机输入一次，再通过 SSH 输入流传送给目标 VPS。
- 不要把 Cloudflare Token、SSH 私钥、证书私钥或 `all-nodes.txt` 提交到 GitHub。
- 只在自己拥有或获准管理的 VPS 和域名上使用。
