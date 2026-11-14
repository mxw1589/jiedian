sing-box 多协议节点管理脚本
快速安装（可直接复制）
在 Debian / Alpine VPS 上以 root 身份执行：
# 一键安装命令
```
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh -o "$tmp" && head -n 1 "$tmp" | grep -qx '#!/bin/sh' && grep -q 'change_cloudflare_zone' "$tmp" && grep -q "ask_value 'Reality SNI / 握手目标域名' 'www.bing.com'" "$tmp" && install -m 700 "$tmp" /usr/local/sbin/sb-manager && rm -f "$tmp" && /usr/local/sbin/sb-manager install
```
# 一键卸载命令
```
/usr/local/sbin/sb-manager uninstall --yes
```
sing-box 多协议节点管理脚本
快速安装（可直接复制）
在 Debian / Alpine VPS 上以 root 身份执行：
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh -o "$tmp" && head -n 1 "$tmp" | grep -qx '#!/bin/sh' && grep -q 'change_cloudflare_zone' "$tmp" && grep -q "ask_value 'Reality SNI / 握手目标域名' 'www.bing.com'" "$tmp" && install -m 700 "$tmp" /usr/local/sbin/sb-manager && rm -f "$tmp" && /usr/local/sbin/sb-manager install
这条命令会先下载到临时文件，并检查第一行确实是 Shell
shebang，再安装脚本，避免把 GitHub HTML 页面误当作脚本执行。

注意： 必须先把最新版 sb-manager-debian-alpine.sh
上传并覆盖到本仓库 main 分支的同一路径，然后再运行命令。GitHub 的
/blob/ 是网页地址，不能用作脚本下载地址；脚本下载必须使用
raw.githubusercontent.com。

在 GitHub README
页面中，代码块右上角会显示复制图标。点击即可复制整条命令，再粘贴到 VPS
的 SSH 终端执行。

适用于 Debian 和 Alpine Linux 的 sing-box
一键安装与管理脚本，自动配置以下三种入站协议：
- AnyTLS
- VLESS + WebSocket + TLS
- VLESS + Reality（Vision）
脚本支持随机分配端口、检测本机 TCP
监听端口冲突、生成节点分享链接，以及三种 TLS 证书配置方式。
本 README 按当前仓库中的 sb-manager-debian-alpine.sh
编写。部署前请先确认 VPS 系统、域名解析和云厂商安全组符合下文要求。

功能概览
功能	说明
系统支持	Debian、Alpine Linux
网络协议	IPv4 + IPv6 双栈监听；可分别生成 IPv4/IPv6 节点链接
协议	AnyTLS、VLESS/WS/TLS、VLESS/Reality
端口分配	安装时随机分配；管理菜单可再次随机更换
端口冲突检测	检查本机当前监听的 TCP 端口，发现冲突后重新抽取
WS TLS 端口	从 2053、`2083`、`2087`、`2096`、`8443` 中随机选择
证书	Cloudflare DNS-01、Let’s Encrypt HTTP-01、手动导入
证书续期	ACME 自动续期任务（适用于脚本配置的自动签发方式）
域名管理	菜单可修改 Cloudflare DNS 区域、TLS 证书域名、WS Host
优选地址管理	菜单可修改 VLESS WS TLS IPv4/IPv6 IP 或域名
服务管理	Debian 使用 systemd；Alpine 使用 OpenRC
节点输出	终端显示，并保存到 /etc/sing-box/nodes.txt
配置校验	应用配置前调用 sing-box check


IPv4 + IPv6 双栈支持
脚本支持 IPv4 和 IPv6 双栈：三个入站协议（AnyTLS、VLESS + WS +
TLS、VLESS + Reality）都会使用通配监听地址。检测到系统内核启用 IPv6
时，配置使用 listen: "::"；在 Linux/Go
的双栈监听能力可用时，同一监听端口可同时接受 IPv6 和 IPv4-mapped
连接。若系统内核禁用了 IPv6，脚本会回退到 0.0.0.0，并提示当前只能使用
IPv4。

安装向导会尝试自动检测：
- IPv4：通过 IPv4 网络查询公网地址。
- IPv6：通过 IPv6 网络查询公网地址；检测不到时可以手动填写，也可以留空。
- VLESS WS TLS：可分别填写主地址（IPv4 或域名）和 IPv6 优选地址。
如果同时填写 IPv4 和 IPv6
地址，安装完成后最多生成六条节点链接：三个协议各一条主地址链接和一条
IPv6 链接。若只填写域名，且该域名同时有正确的 A 与 AAAA
记录，也可以使用同一域名链接由客户端解析选择地址族。

IPv6 生效的前提： VPS 服务商必须为实例分配公网
IPv6，系统网络接口必须配置 IPv6
地址和默认路由；云安全组及系统防火墙也必须允许 IPv6 入站 TCP 流量。仅有
listen: "::" 并不能替代服务商分配 IPv6 地址或配置路由。

建议在服务器检查：
# 查看系统是否有全局 IPv6 地址
ip -6 addr show scope global

# 检查公网 IPv4 / IPv6 出口
curl -4 https://api.ipify.org
curl -6 https://api64.ipify.org

# 查看 sing-box 监听端口
ss -lntp
放行端口时，除了 IPv4 规则（例如
0.0.0.0/0），还要在云安全组和系统防火墙中配置相应 IPv6 来源范围（例如
::/0，按你的安全策略收窄）。IPv4 放行规则不会自动放行 IPv6。
端口随机分配规则
脚本为三个入站分别分配 TCP 端口：
协议	端口范围 / 候选端口
AnyTLS	10000–65535
VLESS + WS + TLS	2053、`2083`、`2087`、`2096`、`8443`
VLESS + Reality	10000–65535


随机分配时：
1. 三个协议使用不同端口。
2. 检查端口是否已被本机 TCP 服务监听。
3. 如果端口已被占用，则重新随机选择。
4. 重新安装或在管理菜单中更换端口时，会避开上一轮保存的三个端口。
5. 新端口写入 sing-box 配置和状态文件；普通重启不会改变端口。
重要限制：
- 端口检测使用本机 ss 检查当前 TCP
  监听状态，不代表能够检测云厂商预留端口、上游网络限制或安全组规则。
- 脚本不会自动修改 UFW、nftables、iptables 或云厂商安全组。
- 更换端口后，必须在 VPS 防火墙和云厂商控制台放行新的 TCP
  端口，并更新客户端节点链接。
- WS TLS 被限制在上述五个端口，是为了兼容 Cloudflare 代理支持的 HTTPS
  端口范围；若五个候选端口都不可用，脚本会停止并提示错误。
环境要求
- Debian 或 Alpine Linux。
- 使用 root 用户执行。
- VPS 具有可用的公网网络连接。
- 有一个可用于 TLS 的域名。
- 域名 DNS 记录应按所选证书方式正确配置。
- 云厂商安全组允许所需 TCP 入站流量。
脚本会自动安装 sing-box 和所需依赖：
- Debian：通过 sing-box 官方软件源安装。
- Alpine：优先通过 apk 安装；若仓库没有 sing-box 包，则尝试下载 sing-box
  官方 Linux 发布版。
一键安装
仓库脚本地址：

https://github.com/mxw1589/jiedian/blob/main/sb-manager-debian-alpine.sh

在服务器上执行以下命令。该命令使用 GitHub raw
地址下载，并检查文件首行，防止下载到 HTML：
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh -o "$tmp" && head -n 1 "$tmp" | grep -qx '#!/bin/sh' && grep -q 'change_cloudflare_zone' "$tmp" && grep -q "ask_value 'Reality SNI / 握手目标域名' 'www.bing.com'" "$tmp" && install -m 700 "$tmp" /usr/local/sbin/sb-manager && rm -f "$tmp" && /usr/local/sbin/sb-manager install
blob 是 GitHub 网页查看地址，会返回 HTML；不能将它保存成 .sh
后直接执行。请使用 raw.githubusercontent.com。
安装向导
运行安装命令后，脚本会依次询问：
1. 源站 IPv4 地址 / 域名：AnyTLS 和 Reality
   节点的主连接地址；脚本会尝试自动检测 IPv4。
2. 源站 IPv6 地址：可选；脚本会尝试自动检测
   IPv6，也可手动填写。IPv6 地址请勿加方括号。
3. VLESS WS TLS 优选 IPv4 地址 / 域名：WS TLS
   节点主连接地址，默认与源站主地址相同。
4. VLESS WS TLS 优选 IPv6 地址：可选，默认与源站 IPv6 地址相同。
5. TLS 证书域名：必须填写你自己拥有或获准管理的域名，例如
   node.example.com，用于 AnyTLS 和 VLESS WS TLS 的证书及 SNI。
6. 域名所有权确认：脚本会要求输入大写
   YES，确认你有权为该域名申请证书。
7. VLESS WS Host 域名：写入 WS 节点链接的 Host 参数。
8. Reality SNI：Reality 握手目标域名，新安装默认值为
   www.bing.com。这个字段只用于 VLESS Reality，不用于申请 TLS 证书。
9. 证书申请方式：选择 Cloudflare DNS-01、HTTP-01 或手动导入。
重要区别： www.bing.com 是新安装时 VLESS Reality 的默认
SNI/握手目标；它不是你的 TLS 证书域名。AnyTLS 和 VLESS WS TLS
仍必须使用你自己拥有或获准管理的证书域名。
证书方式
方式 1：Cloudflare DNS-01
- 需要 Cloudflare API Token。
- 通过 Cloudflare DNS API 完成域名验证。
- 不依赖 VPS 的 TCP 80 端口空闲。
- 脚本配置 ACME 自动续期任务。
- 向导会要求填写 Cloudflare DNS 区域主域名，例如
  example.com；证书域名必须是该区域本身或其子域名，例如
  node.example.com。
- 可选填写 Cloudflare Zone ID。填写后 Token 只需要
  Zone: DNS: Edit；如果 Zone ID 留空，Token 还需要
  Zone: Zone: Read，供 acme.sh 查询区域。
- 脚本会在申请证书前检查证书域名是否属于填写的 Cloudflare 区域。
- 后续可在管理菜单选择 6 修改 Cloudflare 绑定区域、TLS 证书域名、WS
  Host 和 Zone ID。更换区域时必须填写新区域的 Zone ID，且现有 Token
  必须获准编辑新区域 DNS；若 Token 只授权旧区域，需要在 Cloudflare
  中调整 Token 的 Zone Resources 或创建新 Token。
Cloudflare Token 仅用于自动操作 DNS 验证记录，不是 sing-box
协议本身的必需配置。
方式 2：Let’s Encrypt HTTP-01（默认选项）
- 不需要 Cloudflare Token。
- 域名必须解析到当前 VPS。
- 公网 TCP 80 必须能够从互联网访问。
- 申请证书时，本机 TCP 80 端口必须空闲；如果已有 Web 服务占用 80
  端口，需先停止该服务或选择其他证书方式。
- 脚本使用 ACME standalone 模式申请证书，并配置自动续期任务。
如果 HTTP-01 申请失败，请检查域名 A/AAAA 记录、云安全组、防火墙，以及
TCP 80 是否被其他程序占用。
方式 3：手动导入证书
需要提供：
- fullchain.pem：证书链文件路径。
- privkey.pem：私钥文件路径。
脚本会检查证书 PEM
格式、域名是否匹配，以及证书和私钥是否配对。手动导入方式不会替你自动续签证书；证书更新后需要重新导入。

证书用途说明： AnyTLS 和 VLESS WS TLS 使用这组 TLS 证书；VLESS
Reality 使用 Reality 密钥，不依赖这组常规 TLS 证书。
安装完成后
安装完成后，脚本会：
- 生成 AnyTLS 密码。
- 生成两个 VLESS UUID。
- 生成 Reality 密钥对和 Short ID。
- 生成随机 WS 路径。
- 写入 sing-box 配置。
- 执行 sing-box check 校验配置。
- 启动或重启 sing-box 服务。
- 按已填写的地址显示三个协议的 IPv4/主地址及 IPv6 分享链接（最多六条）。
- 将节点链接保存到：
/etc/sing-box/nodes.txt
如果分别填写了 IPv4/主地址和 IPv6
地址，文件会分别列出对应的节点链接；只填写一个地址族时，只生成该地址族的链接。若主地址使用同时配置了
A 和 AAAA 记录的域名，也可以让客户端通过域名解析选择 IPv4 或 IPv6。

安装结束时会列出三个 TCP
端口。请将这三个端口加入云厂商安全组和系统防火墙的入站放行规则。
管理命令
安装完成后，使用：
/usr/local/sbin/sb-manager
管理菜单：
菜单	功能
1	查看三个协议的 IPv4/IPv6 节点链接（最多六条）
2	修改 TLS 证书域名 / AnyTLS + WS SNI，并重新申请或检查证书
3	修改 VLESS Reality SNI（新安装默认 www.bing.com）
4	修改 VLESS WS TLS 优选 IPv4/IPv6 地址（可填写 IP 或域名）
5	修改 VLESS WS Host 域名
6	修改 Cloudflare 绑定 DNS 区域、TLS 证书域名、WS Host 和 Zone ID
7	随机更换三个节点端口，自动避开本机监听端口及上一轮端口
8	重启 sing-box
9	查看服务状态
10	查看最近日志
11	卸载 sing-box 和本脚本配置
0	退出


修改 Cloudflare 绑定域名
使用菜单 6。脚本会依次要求输入新的 Cloudflare DNS 区域主域名、TLS
证书域名、WS Host 和 Zone ID，然后通过 Cloudflare DNS-01
重新申请证书并更新配置。
- 新 TLS 证书域名必须是新 Cloudflare 区域本身或其子域名。
- 新 Zone ID 必须是该 Cloudflare 区域对应的 32 位 Zone ID。
- Cloudflare Token 必须对新区域具有 Zone: DNS: Edit 权限；如果 Token
  只授权旧区域，修改会失败，需要先调整 Token 权限或创建新 Token。
- 修改成功后会重新生成节点链接；修改失败时脚本会尽力恢复旧证书、旧 Zone
  ID 和旧配置。
修改优选 IP / 域名
使用菜单 4，分别输入 VLESS WS TLS 的 IPv4 地址/域名和 IPv6 地址。IPv6
可留空；输入 -
可清空某个地址。至少保留一个可用地址。修改后脚本会更新节点分享链接，不会改变服务监听端口或
Reality/AnyTLS 的源站地址。
随机更换端口
在菜单中选择 7：
7. 随机更换三个节点端口（自动避开占用端口）
脚本会重新分配三个端口、校验并应用配置，然后重新显示 IPv4/IPv6
节点链接（取决于填写的地址）。

端口更换后请务必：
1. 在云厂商安全组放行新端口。
2. 在 VPS 系统防火墙放行新端口。
3. 将新节点链接重新导入客户端。
4. 不再使用旧端口对应的节点链接。
普通重启（菜单 8）不会改变端口，避免客户端配置无故失效。
一键卸载
已正确安装管理脚本时，执行：
/usr/local/sbin/sb-manager uninstall
卸载前会要求输入大写 YES 确认。若要跳过确认并直接卸载：
/usr/local/sbin/sb-manager uninstall --yes
卸载流程会停止并禁用 sing-box 服务，删除本脚本的 /etc/sing-box
配置和证书副本、管理命令、服务文件及本脚本添加的 acme.sh
定时续期任务，并尝试卸载 sing-box 软件包。

卸载时会保留：
- /root/.acme.sh 目录，避免删除可能被其他域名或服务共用的 ACME
  账户与证书。
- 系统依赖包、`sing-box` 系统用户/组。
- UFW、nftables、iptables 规则和云厂商安全组设置。
- 其他 cron 定时任务。
卸载不会自动关闭或删除防火墙规则；如不再需要，请自行检查并清理对应端口规则。
文件与目录
路径	用途
/usr/local/sbin/sb-manager	管理脚本
/etc/sing-box/config.json	sing-box 运行配置
/etc/sing-box/manager.json	管理器状态、端口和节点参数
/etc/sing-box/nodes.txt	节点分享链接
/etc/sing-box/cert/fullchain.pem	TLS 证书链
/etc/sing-box/cert/privkey.pem	TLS 私钥
/etc/sing-box/cloudflare.token	Cloudflare Token（仅 DNS-01 模式使用）
/etc/sing-box/cloudflare-zone-id	可选 Cloudflare Zone ID
/usr/local/sbin/sing-box-cert-reload	证书更新后的服务重载脚本


配置和状态文件包含敏感信息。请勿公开分享
manager.json、`config.json`、Token 文件或节点分享链接。
服务管理
Debian（systemd）
systemctl status sing-box
systemctl restart sing-box
journalctl -u sing-box -n 80 --no-pager
Alpine（OpenRC）
rc-service sing-box status
rc-service sing-box restart
常见问题
0. 为什么不能用 www.bing.com 作为 TLS 证书域名？
Let’s Encrypt 只能为你拥有或获准管理的域名签发证书。`www.bing.com`
属于微软，不能拿来给自己的 VPS 申请证书。

请区分两个字段：
- TLS 证书域名 / AnyTLS 与 WS 的 SNI：填写你自己的域名，例如
  node.example.com。
- Reality SNI / 握手目标域名：新安装默认使用
  www.bing.com，可在管理菜单 3 修改；它不用于申请 TLS 证书。
选择 Cloudflare DNS-01 时，还需要填写 Cloudflare DNS 区域主域名，例如
example.com。脚本会检查证书域名是否为该区域或其子域名；不匹配时会在联系
Let’s Encrypt 之前停止。后续可通过管理菜单 6 更换 Cloudflare
区域和证书域名。
1. 为什么还需要 Cloudflare Token？
并不是必须。Token 只在选择 Cloudflare DNS-01 自动验证时需要。

如果不想使用 Token，可以选择：
- HTTP-01：域名解析到 VPS，公网 TCP 80 可访问且空闲。
- 手动证书：提供已有证书链和私钥文件。
2. HTTP-01 证书申请失败
依次检查：
- 域名 A 记录是否指向 VPS 公网 IPv4。
- 如果配置了 AAAA 记录，IPv6 是否也能正确访问该 VPS。
- 云安全组是否放行 TCP 80。
- 系统防火墙是否放行 TCP 80。
- 本机是否有其他程序监听 TCP 80。
3. 提示随机端口无法分配
- 检查服务器上是否有大量 TCP 端口被监听。
- WS TLS 只能从五个候选端口中选择；如果都被占用，需要先释放其中一个。
- 确认 iproute2 已安装，且 ss 命令可用。
4. 节点能生成但客户端无法连接
- 检查三个新 TCP 端口是否已在云安全组和系统防火墙放行。
- 确认客户端使用的是最新节点链接。
- 检查域名、SNI、WS Host 和优选 IP 是否配置正确。
- 使用管理菜单 9 查看服务状态，菜单 10 查看日志。
5. 重启后端口没有变化
这是预期行为。端口只在首次安装、重新运行安装向导或主动选择菜单 7
时重新分配。普通重启不会改变端口。
6. 执行脚本时出现 <!DOCTYPE html> 或 syntax error
这是因为下载了 GitHub 的网页地址，例如：

https://github.com/mxw1589/jiedian/blob/main/sb-manager-debian-alpine.sh

该地址返回 HTML，不是 Shell 源码。请改用：

https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh

并使用上方带首行检查的一键安装命令。确认 GitHub main
分支已更新为最新版脚本后再执行。
安全提示
- 只在自己拥有或获准管理的服务器上部署。
- 建议先阅读脚本，再以 root 身份运行。
- 不要把 Cloudflare Token、TLS 私钥、AnyTLS 密码、Reality
  私钥或节点链接发布到公开位置。
- 更换端口后及时更新安全组和防火墙规则。
- 定期检查 sing-box 服务状态、证书有效期和系统更新。
许可证与支持
本 README
描述的是仓库中的安装管理脚本行为。若仓库没有单独声明许可证，请不要自行假定代码采用某种开源许可证。

仓库：

https://github.com/mxw1589/jiedian

脚本：

https://github.com/mxw1589/jiedian/blob/main/sb-manager-debian-alpine.sh
