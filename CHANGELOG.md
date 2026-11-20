# 更新记录

## 2026-11-19 — 协议增删与按协议参数管理

- 命令菜单新增 `19` 删除指定协议：只移除所选入站、端口和凭据，其他协议配置保持不变；删除 Argo WS 时停止并移除本机 Tunnel 服务和 Token 文件，不触碰 Cloudflare 控制台资源。
- 命令菜单新增 `20` 按协议修改：先选择已安装协议，再修改适用的 SNI / TLS 域名、源站地址或 WS 优选 IP、Cloudflare Zone / Argo Public Hostname、端口及协议专属凭据和可选参数。
- 增加协议参数说明，明确 TLS 域名在 AnyTLS / Naive / 直连 WS 间共享，Reality SNI 在两种 Reality 协议间共享；源站 IPv4 / IPv6 也是直连协议共用值。
- 支持修改 AnyTLS / Naive 凭据、WS HTTP Host / Path / UUID、VLESS Reality UUID / 密钥、AnyTLS + Reality 密码 / 密钥。
- Cloudflare DNS-01 管理支持轮换 DNS API Token；Zone ID 可清除并交由 acme.sh 自动查询；Token 缺失时可在菜单中重新补录。
- Argo 管理允许在本机 Token 文件缺失时重新补录 Tunnel Token。
- 保留 Debian / Alpine 兼容性，服务配置仍自动识别 systemd / OpenRC。

## 2026-11-19 — Linux 环境与紧凑表单优化

- 面板定位调整为 Linux VPS，重点面向 Debian / Alpine；移除不适用于当前 Linux 服务端部署流程的桌面端辅助文件和说明。
- 表单改为紧凑双栏布局，移动端自动切换为单栏，减少不必要的纵向滚动。
- 每个参数明确标注必填、可选或默认值；当前协议组合不需要的字段直接隐藏。
- 源站 IPv4 / IPv6 留空时自动检测；Reality SNI 留空使用 `www.bing.com`；协议端口留空自动分配。
- 将直连 WS 的自定义 HTTP Host 改为可选覆盖值，默认使用 TLS 证书域名，避免重复填写。
- 安装命令和卸载命令在同一区域同时显示、分别生成、分别复制；增加分隔 TXT 下载。
- 将 Argo 配置步骤收进折叠说明，删除网页中的冗长交互式安装命令和桌面端客户端核心区。
- 保留 NaiveProxy 服务端 sing-box 1.13.0+ 版本检查，以及 Linux sing-box 客户端配置 `naive-client.json`。

## 2026-11-19 — NaiveProxy 服务端与客户端配置

- 启用 NaiveProxy 时，生成独立的 sing-box 1.13.0+ 客户端配置 `/etc/sing-box/naive-client.json`，权限设为 `0600`。
- 修改 TLS 域名后，重新生成节点链接和 Naive 客户端 JSON，避免旧 SNI 留在导出配置中。
- Debian 使用 sing-box 官方软件源；Alpine 在仓库版本低于 1.13.0 或不可用时回退到官方 Linux 发布版。

## 安全与兼容性说明

- `naive-client.json` 含认证凭据，必须通过 SSH / SCP 等安全方式传输，不能公开分享。
- NAT 公网映射端口若与 VPS 内部监听端口不同，客户端 JSON 的 `server_port` 必须改为公网映射端口。
- Cloudflare Tunnel Token 和 DNS API Token 都是敏感凭据。网页生成命令中的 Token 使用 Base64 编码，Base64 不是加密。
