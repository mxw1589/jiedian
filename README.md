sing-box 多协议节点管理脚本
快速安装（可直接复制）
在 Debian / Alpine VPS 上以 root 身份执行：
# 一键安装命令
```
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh -o "$tmp" && head -n 1 "$tmp" | grep -qx '#!/bin/sh' && grep -q 'overlay_install()' "$tmp" && grep -q 'change_node_label()' "$tmp" && grep -q 'node_label:$node_label' "$tmp" && install -m 700 "$tmp" /usr/local/sbin/sb-manager && rm -f "$tmp" && /usr/local/sbin/sb-manager install

```
# 一键卸载命令
```
/usr/local/sbin/sb-manager uninstall --yes
```
下面是你目前最新版的 sing-box 双栈管理脚本的一键安装、覆盖更新和卸载命令。
1. 完整 SH 文件
sb-manager-debian-alpine.sh

最新版 · Debian / Ubuntu / Alpine

完整脚本

 下载完整 SH 文件

GitHub 文件路径保持不变：

mxw1589/jiedian/main/sb-manager-debian-alpine.sh

先上传新版文件覆盖 GitHub 原文件。
2. 一键安装 / 覆盖安装命令
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh -o "$tmp" && head -n 1 "$tmp" | grep -qx '#!/bin/sh' && grep -q 'overlay_install()' "$tmp" && grep -q 'change_node_label()' "$tmp" && grep -q 'node_label:$node_label' "$tmp" && install -m 700 "$tmp" /usr/local/sbin/sb-manager && rm -f "$tmp" && /usr/local/sbin/sb-manager install


 复制一键安装命令
- 已安装过：自动覆盖安装，保留原有配置，不重新询问域名、SNI、Token 等。
- 首次安装：自动进入初始化向导。
- 安装完成：自动显示全部可用节点。
3. 一键卸载命令
正常卸载（需要输入 YES）
/usr/local/sbin/sb-manager uninstall


 复制正常卸载命令
直接卸载（无需确认）
/usr/local/sbin/sb-manager uninstall --yes


 复制直接卸载命令
卸载内容：
- 停止并删除 sing-box 服务。
- 删除本脚本配置、节点文件和证书副本。
- 卸载 sing-box 软件包。
- 移除本脚本创建的 BBR 配置，并尝试恢复原网络参数。
- 删除管理脚本。
保留 /root/.acme.sh、系统依赖、系统用户/组、防火墙规则及云安全组。
4. 脚本功能说明
功能	说明
三种协议	AnyTLS、VLESS WS TLS、VLESS Reality
双栈支持	IPv4 + IPv6
随机端口	自动分配，检测端口冲突
Reality SNI	默认 www.bing.com
TLS 证书	Cloudflare DNS-01、HTTP-01、手动导入
自动续期	支持 ACME 证书自动续期
BBR	自动检测、启用和持久化
覆盖安装	保留原有域名、Token、证书、密钥和节点参数
节点辨识符	自定义 KC、LAX、VN 等标识
节点管理	查看、修改域名、SNI、优选 IP、端口
自动生成节点	安装完成后显示全部 IPv4/IPv6 节点

5. 管理菜单
安装完成后运行：
/usr/local/sbin/sb-manager


常用菜单：
菜单	功能
1	查看全部节点
3	修改 Reality SNI
4	修改优选 IP / 域名
6	修改 Cloudflare 域名
7	随机更换端口
12	查看 BBR 状态
13	自定义节点辨识符

节点名称示例：
IPv4-KC-AnyTLS
IPv4-KC-VLESS-Reality
IPv4-KC-VLESS-WS-TLS

IPv6-KC-AnyTLS
IPv6-KC-VLESS-Reality
IPv6-KC-VLESS-WS-TLS


其中 KC 可以通过菜单 13 随时修改。

注意： 上传 GitHub 后才能使用安装命令下载最新版本。脚本已通过 Shell 语法检查，但尚未完成真实 VPS 部署测试。
