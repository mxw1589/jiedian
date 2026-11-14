sing-box 多协议节点管理脚本
快速安装（可直接复制）
在 Debian / Alpine VPS 上以 root 身份执行：
# 一键安装命令
```
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh -o "$tmp" && head -n 1 "$tmp" | grep -qx '#!/bin/sh' && grep -q 'type:"naive"' "$tmp" && grep -q 'naive+https://' "$tmp" && grep -q 'NAIVE_PORT' "$tmp" && grep -q 'overlay_install()' "$tmp" && install -m 700 "$tmp" /usr/local/sbin/sb-manager && rm -f "$tmp" && /usr/local/sbin/sb-manager install


```
# 一键卸载命令
```
/usr/local/sbin/sb-manager uninstall --yes
```
sing-box 双栈四协议管理脚本
适用于 Debian / Ubuntu / Alpine。主脚本路径保持不变：

sb-manager-debian-alpine.sh
协议
- AnyTLS
- VLESS + WebSocket + TLS
- VLESS + Reality
- NaiveProxy（TCP / HTTP/2）
NaiveProxy 使用现有 TLS 证书，自动生成独立用户名和密码，并随机分配 10000–65535 范围内未占用的 TCP 端口。Naive 入站使用 sing-box type: naive、用户名/密码和 TLS 配置；TCP 模式不额外开放 UDP/QUIC 端口。sing-box 需要 1.13.0 或更新版本。
IPv4 / IPv6 与端口
- 支持 IPv4、IPv6 双栈监听，并分别生成节点链接。
- 四种协议使用不同端口；随机分配时检查已有端口和当前 TCP 监听。
- 管理菜单 7 可随机更换四个协议的端口。
- 安装完成后显示所有可用节点，并保存到 /etc/sing-box/nodes.txt。
- 节点名称支持中文辨识符，例如 IPv4-香港-NaiveProxy。
NaiveProxy 分享链接格式：

naive+https://用户名:密码@服务器:端口/?sni=证书域名#节点名称
一键安装 / 覆盖更新
先将新版 sb-manager-debian-alpine.sh 上传并覆盖 GitHub 仓库中的原文件：

https://github.com/mxw1589/jiedian/blob/main/sb-manager-debian-alpine.sh

然后在 VPS 以 root 执行：
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh -o "$tmp" && head -n 1 "$tmp" | grep -qx '#!/bin/sh' && grep -q 'type:"naive"' "$tmp" && grep -q 'naive+https://' "$tmp" && grep -q 'NAIVE_PORT' "$tmp" && grep -q 'overlay_install()' "$tmp" && install -m 700 "$tmp" /usr/local/sbin/sb-manager && rm -f "$tmp" && /usr/local/sbin/sb-manager install
- 首次安装：进入初始化向导。
- 已安装旧版：执行覆盖安装，保留原域名、SNI、Cloudflare Token、证书、UUID、Reality 密钥和原有端口；自动补充 NaiveProxy 端口及凭据，不要求重新输入原配置。
- 安装后管理命令：`/usr/local/sbin/sb-manager`
管理与卸载
/usr/local/sbin/sb-manager
/usr/local/sbin/sb-manager uninstall
卸载时按提示输入 YES。该脚本不会自动修改云厂商安全组；请手动放行四个 TCP 端口。
说明
NaiveProxy 的 TLS 使用脚本已部署的证书，因此节点连接地址中的 sni 应与证书域名匹配。若使用 IPv4/IPv6 直连，确保对应地址可从客户端访问。NaiveProxy 的 naive+https:// 分享链接需要客户端支持该链接格式。
