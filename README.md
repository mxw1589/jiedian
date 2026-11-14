sing-box 多协议节点管理脚本
快速安装（可直接复制）
在 Debian / Alpine VPS 上以 root 身份执行：
```
curl -fsSL https://github.com/mxw1589/jiedian/blob/main/sb-manager-debian-alpine.sh -o /usr/local/sbin/sb-manager && chmod 700 /usr/local/sbin/sb-manager && /usr/local/sbin/sb-manager install
```
在 GitHub README
页面中，代码块右上角会显示复制图标。点击即可复制整条命令，再粘贴到 VPS
的 SSH 终端执行。
执行前请确认 GitHub 仓库 main 分支中的脚本已经更新为准备部署的版本。

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
协议	AnyTLS、VLESS/WS/TLS、VLESS/Reality
端口分配	安装时随机分配；管理菜单可再次随机更换
端口冲突检测	检查本机当前监听的 TCP 端口，发现冲突后重新抽取
WS TLS 端口	从 2053、`2083`、`2087`、`2096`、`8443` 中随机选择
证书	Cloudflare DNS-01、Let’s Encrypt HTTP-01、手动导入
证书续期	ACME 自动续期任务（适用于脚本配置的自动签发方式）
服务管理	Debian 使用 systemd；Alpine 使用 OpenRC
节点输出	终端显示，并保存到 /etc/sing-box/nodes.txt
配置校验	应用配置前调用 sing-box check


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

在服务器上执行以下命令。安装命令使用 GitHub 的 raw 地址下载脚本内容：
curl -fsSL https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh \
  -o /usr/local/sbin/sb-manager \
  && chmod 700 /usr/local/sbin/sb-manager \
  && /usr/local/sbin/sb-manager install
请确认 GitHub 仓库中的脚本已经更新为你准备部署的版本。`blob`
是网页查看地址，服务器下载脚本时使用 raw.githubusercontent.com 地址。
安装向导
运行安装命令后，脚本会依次询问：
1. 源站公网 IP：AnyTLS 和 Reality
   节点使用的连接地址。脚本会尝试自动检测 IPv4 地址，可按需修改。
2. VLESS WS TLS 优选 IP：WS TLS
   节点使用的连接地址，默认与源站地址相同。
3. TLS 证书域名：用于 AnyTLS 和 VLESS WS TLS 的证书域名及 SNI。
4. VLESS WS Host 域名：写入 WS 节点链接的 Host 参数。
5. Reality SNI：Reality 握手目标域名，默认值为
   www.microsoft.com。
6. 证书申请方式：选择 Cloudflare DNS-01、HTTP-01 或手动导入。
7. 随机端口：脚本自动分配，不需要手动填写。
证书方式
方式 1：Cloudflare DNS-01
- 需要 Cloudflare API Token。
- 通过 Cloudflare DNS API 完成域名验证。
- 不依赖 VPS 的 TCP 80 端口空闲。
- 脚本配置 ACME 自动续期任务。
- 可选填写 Cloudflare Zone ID；向导会提示相应 Token 权限要求。
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
- 显示三个节点的分享链接。
- 将节点链接保存到：
/etc/sing-box/nodes.txt
安装结束时会列出三个 TCP
端口。请将这三个端口加入云厂商安全组和系统防火墙的入站放行规则。
管理命令
安装完成后，使用：
/usr/local/sbin/sb-manager
管理菜单：
菜单	功能
1	查看三个节点分享链接
2	修改 AnyTLS + WS TLS 的 SNI，并按证书模式检查或更新证书
3	修改 Reality SNI
4	修改 VLESS WS TLS 优选 IP
5	修改 VLESS WS Host 域名
6	随机更换三个节点端口，自动避开本机监听端口及上一轮端口
7	重启 sing-box
8	查看服务状态
9	查看最近日志
0	退出


随机更换端口
在菜单中选择 6：
6. 随机更换三个节点端口（自动避开占用端口）
脚本会重新分配三个端口、校验并应用配置，然后重新显示节点链接。

端口更换后请务必：
1. 在云厂商安全组放行新端口。
2. 在 VPS 系统防火墙放行新端口。
3. 将新节点链接重新导入客户端。
4. 不再使用旧端口对应的节点链接。
普通重启（菜单 7）不会改变端口，避免客户端配置无故失效。
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
- 使用管理菜单 8 查看服务状态，菜单 9 查看日志。
5. 重启后端口没有变化
这是预期行为。端口只在首次安装、重新运行安装向导或主动选择菜单 6
时重新分配。普通重启不会改变端口。
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
