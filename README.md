# Jiedian sing-box 管理器修正版 1.4.0

本包基于本次用户上传的 `index.html` 和 `sb-manager-debian-alpine.sh` 修改。

## 本次修改
- 网页移除 Cloudflare DNS 根域名、DNS API Token、Zone ID、证书邮箱输入项。
- 网页需要证书的协议统一使用 Let's Encrypt HTTP-01。证书域名仍需填写；域名须解析到 VPS，公网 TCP 80 必须可访问。
- Argo Tunnel Token 保留，因为它是 Tunnel 连接器凭据，与 DNS API Token 不同。
- “节点辨识符”改为“节点前缀”，节点命名调整为 `前缀-地址族-地址-协议`。
- Shell 管理器读取新 `node_prefix`，同时兼容旧状态中的 `node_label`。
- 升级网页配置 Schema 到 8，安装命令校验 Schema 8。
- 修正 Shadowsocks 2022 的分享链接：采用 SIP002 的 Base64URL `method:password@host:port` 格式，并正确为 IPv6 加方括号。

## 重要限制：Snell
本次上传的 Shell 文件中没有 Snell 实现：没有 Snell 入站、Snell 服务端二进制安装、服务管理或 Surge Snell 客户端配置导出。现有的 Shadowsocks 2022 不是 Snell，二者不能互换。本包不会伪造 Snell 链接，也不宣称 Snell 已修复/可用。真正加入 Snell 需要额外集成独立 Snell server 进程及其服务管理；它不是 sing-box 当前配置中的一个 inbound。

## 安装前
1. 将包内 `sb-manager-debian-alpine.sh` 同步到你的 GitHub 仓库 `mxw1589/jiedian` 的 `main` 分支。
2. 部署 `index.html` 到网页托管位置。
3. 网页生成的 SSH 命令会下载 `https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh`。
4. HTTP-01 证书签发需要公网 TCP 80 可达；NAT VPS 必须正确映射 TCP 80，否则需先准备已有证书或选择不需要 TLS 证书的协议。

## 测试
在 Linux / macOS / WSL 安装 Python 3、POSIX sh、Node.js（可选）后执行：

```sh
./tests/run-tests.sh
```

测试仅覆盖本地语法、网页 DOM 引用、配置 Schema、节点命名和 Shadowsocks 2022 链接格式。没有在真实 VPS 上安装服务、申请证书或进行客户端连通性测试。
