sing-box WARP 域名分流 - 使用说明
=====================================

文件
----
- sb-manager-debian-alpine.sh：更新后的 VPS 安装 / 管理脚本
- index.html：更新后的网页配置面板

功能
----
- 使用 sing-box WireGuard endpoint 连接 Cloudflare WARP。
- 指定域名及其子域名走 WARP。
- 其他流量继续走 direct，不创建系统级全局 WireGuard 默认路由。
- 匹配域名的 DNS 查询使用 Cloudflare DoH，并通过 WARP 发送；其他域名继续使用系统 DNS。
- 支持 IPv4；填写 WARP IPv6 地址后同时支持 IPv6。
- VPS 管理菜单新增 21：Cloudflare WARP 域名分流设置。

部署
----
1. 将压缩包内的 sb-manager-debian-alpine.sh 替换到你仓库原来的同名路径。
2. 将 index.html 替换到网页面板原来的路径。
3. 网页中的 RAW_URL 仍指向原仓库脚本路径，因此必须先更新仓库里的 Shell 脚本，再使用新网页生成安装命令。
4. 已安装 VPS：先把 GitHub 中的新脚本更新到本机（不会重新安装节点，也不会重置 manager.json）：
   curl -fsSL https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh -o /tmp/sb-manager.new && \
   head -n 1 /tmp/sb-manager.new | grep -qx '#!/bin/sh' && \
   grep -q 'Manager menu 21' /tmp/sb-manager.new && \
   install -m 700 /tmp/sb-manager.new /usr/local/sbin/sb-manager && \
   rm -f /tmp/sb-manager.new
5. 更新后运行：
   /usr/local/sbin/sb-manager
   选择菜单 21，按提示配置或关闭 WARP。

WARP 参数
---------
请准备你自己的 Cloudflare WARP WireGuard 配置。网页 / 菜单需要：
- PrivateKey：WireGuard 配置 [Interface] 下的 PrivateKey。
- IPv4 Address：必须使用你配置中的 IPv4 主机地址 /32，例如 172.16.0.2/32。
- IPv6 Address：可选；如果填写，必须使用 IPv6 主机地址 /128；留空时仅对 IPv4 目标应用 WARP 规则。
- Endpoint：WireGuard 配置 [Peer] 下 Endpoint 的 IP 地址；默认 162.159.192.1。
- UDP 端口：默认 2408。
- Reserved：账号分配的三个十进制字节，例如 12,34,56。必须使用你自己配置里的实际值。
- 域名：每行一个，或用逗号分隔；不要填写 https://、端口或路径。

域名规则
--------
例如填写：
  google.com
  openai.com

则 google.com、www.google.com、api.google.com、openai.com 及其子域名都会走 WARP。匹配域名的 DNS 也经 WARP 的 Cloudflare DoH 解析；未匹配域名走 direct，DNS 使用系统解析器。
如果客户端先把域名解析成 IP 再发送给 VPS，服务器只能尝试从 TLS SNI / HTTP Host 嗅探域名；其他协议无法保证识别。请优先让客户端把目标域名交给代理服务器处理。IPv6 地址留空时，指定域名按 IPv4-only 解析；如果某域名没有 A 记录，该连接可能失败，不会自动改走 direct。

注意
----
- 此实现针对普通消费者 Cloudflare WARP WireGuard 配置，不是 Zero Trust MASQUE 配置。
- VPS 必须允许向 WARP Endpoint 的 UDP 端口出站；如果 UDP 2408 不通，可填写你实际可用的 Endpoint / 端口。
- WARP PrivateKey 会进入 VPS 配置。网页生成的安装命令包含该私钥的 Base64 编码（不是加密），不要公开分享。
- “导出 JSON（不含密钥）”会清空 WARP PrivateKey，不可直接用于安装启用 WARP 的配置。
- 旧版网页 schema 5/6/7 仍按旧版覆盖升级路径处理；要修改 WARP 请使用新版 schema 8 网页或 VPS 菜单 21。
