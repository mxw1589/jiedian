sing-box 多协议节点管理脚本
快速安装（可直接复制）
在 Debian / Alpine VPS 上以 root 身份执行：
# 一键安装命令
```
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh -o "$tmp" && head -n 1 "$tmp" | grep -qx '#!/bin/sh' && grep -q 'diagnose_naive' "$tmp" && grep -q 'WS TLS 仅输出一个节点' "$tmp" && install -m 700 "$tmp" /usr/local/sbin/sb-manager && rm -f "$tmp" && /usr/local/sbin/sb-manager install

```
# 一键卸载命令
```
/usr/local/sbin/sb-manager uninstall --yes
```
sing-box 多协议节点管理脚本
适用于 Debian / Ubuntu 和 Alpine Linux 的 sing-box 一键安装与管理脚本。

脚本文件名保持不变：

sb-manager-debian-alpine.sh

GitHub 地址：

https://github.com/mxw1589/jiedian/blob/main/sb-manager-debian-alpine.sh
功能简介
1. 支持五种协议
- AnyTLS：标准 TLS。
- AnyTLS + Reality（Any-Reality）：独立 Reality 密钥、密码和 Short ID。
- VLESS + WebSocket + TLS：只生成一个 WS 节点，不再分别生成 IPv4 / IPv6 两个节点。
- VLESS + Reality：TCP + Reality。
- NaiveProxy：TLS 加密的 Naive 入站。
2. IPv4 / IPv6 双栈
- 支持配置源站 IPv4 和 IPv6。
- AnyTLS、AnyTLS + Reality、VLESS + Reality、NaiveProxy 按可用地址分别生成 IPv4 / IPv6 节点。
- VLESS WS TLS 只生成一个节点，可使用 IPv4、IPv6 或域名作为连接地址。
- 系统内核未启用 IPv6 时，脚本会提示并退回 IPv4 监听。
3. 随机端口与冲突检查
- AnyTLS、VLESS Reality、NaiveProxy、AnyTLS + Reality：随机分配 TCP 端口（10000–65535）。
- VLESS WS TLS：从 Cloudflare 代理支持的 HTTPS 端口中随机选择（2053、2083、2087、2096、8443）。
- 分配时检查协议端口冲突及当前 TCP 监听占用。
- 管理菜单支持一次性随机更换五个协议端口。
更换端口后，需同步放行云厂商安全组和 VPS 防火墙中的新 TCP 端口。
4. TLS 证书管理
支持三种证书方式：
1. Cloudflare DNS-01：使用 Cloudflare API Token 自动申请和续期。
2. HTTP-01：不需要 Cloudflare Token；域名需解析到本机，公网 TCP 80 必须可访问且未被占用。
3. 手动导入：使用已有证书和私钥。
普通 AnyTLS、VLESS WS TLS 和 NaiveProxy 共用 TLS 证书域名。VLESS Reality 与 AnyTLS + Reality 共用 Reality SNI；新安装默认 www.bing.com，可在菜单中修改。
5. 覆盖安装与配置保留
检测到本脚本已有安装状态时，执行安装命令会进入覆盖安装流程。

覆盖安装会读取已保存的域名、SNI、WS Host、Cloudflare 凭据、证书、账号、密钥、端口和节点辨识符；不会再次要求输入这些原有信息，也不会主动重新申请证书。缺少必要状态或证书校验失败时会停止，避免用空值覆盖原配置。
6. 其他功能
- 自动尝试启用并持久化 TCP BBR。
- 支持自定义节点辨识符，包含中文等 Unicode 字符。
- 自动生成节点分享链接并显示全部节点。
- 保存节点列表至 /etc/sing-box/nodes.txt。
- 生成 AnyTLS + Reality 客户端手动配置片段：`/etc/sing-box/anytls-reality-client.json`。
- 提供服务重启、状态查看和日志查看。
- 提供 NaiveProxy 本机监听、TLS 证书及 HTTP/2（h2）诊断。
一键安装 / 覆盖安装
先将新版脚本上传到 GitHub，覆盖仓库中的同名文件。然后以 root 身份在 VPS 执行：
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh -o "$tmp" && head -n 1 "$tmp" | grep -qx '#!/bin/sh' && grep -q 'diagnose_naive' "$tmp" && grep -q 'WS TLS 仅输出一个节点' "$tmp" && install -m 700 "$tmp" /usr/local/sbin/sb-manager && rm -f "$tmp" && /usr/local/sbin/sb-manager install
首次安装会启动交互式向导；已有安装则执行覆盖安装并保留原有配置。
管理命令
/usr/local/sbin/sb-manager
主要菜单：
菜单	功能
1	查看五种协议节点（WS TLS 仅一个节点）
2	修改 TLS 证书域名 / TLS SNI
3	修改 Reality SNI
4	修改 WS TLS 单一连接地址
5	修改 WS HTTP Host
6	修改 Cloudflare DNS 区域 / TLS 证书域名
7	随机更换五个协议端口
8–10	重启服务、查看状态、查看日志
11	卸载
12	查看 TCP BBR 状态
13	修改节点辨识符
14	诊断 NaiveProxy


单独启用 / 查看 BBR：
/usr/local/sbin/sb-manager bbr
/usr/local/sbin/sb-manager bbr-status
卸载
/usr/local/sbin/sb-manager uninstall
卸载会停止并尝试卸载 sing-box，删除本脚本的 /etc/sing-box 配置、证书副本和管理脚本，并尝试恢复原有 BBR 参数。

卸载不会删除 /root/.acme.sh、系统依赖包、sing-box 系统用户/组、系统防火墙规则或云厂商安全组；请按需自行检查和清理。
使用注意
- 请使用自己拥有或获准管理的域名申请 TLS 证书。
- Cloudflare DNS-01 需要正确的 API Token 权限和 DNS Zone。
- 随机端口必须在 VPS 防火墙及云厂商安全组中放行。
- 使用 Cloudflare 橙云代理时，随机高端口通常不能直接通过普通代理转发；需要根据协议和端口选择 DNS Only 或受支持的代理端口。
- NaiveProxy 客户端必须支持 Naive，并正确验证 TLS 证书；不要通过跳过证书验证来规避证书错误。
- AnyTLS + Reality 的分享链接解析取决于客户端支持情况；若客户端不能识别 Reality 参数，请使用脚本生成的 anytls-reality-client.json 中的参数，在支持该组合的 sing-box 客户端中手动配置。
- 脚本会在应用配置前运行 sing-box check，但仍应在实际 VPS 和客户端上测试连接。
- 脚本不会自动修改云厂商安全组。
