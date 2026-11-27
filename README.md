# Jiedian 管理器 NaiveProxy + HTTP-01 稳定增强版 1.4.7

本包基于 1.4.6 稳定增强版继续修复，保留网页配置 Schema 8、现有协议数据、节点凭据、端口历史及安装回滚机制。1.4.7 专项修复 NaiveProxy 的标准分享链接、TLS SNI / HTTP/2 ALPN、双栈域名连接和 sing-box UDP-over-TCP 客户端配置，并扩展本机证书、监听与 DNS 诊断。本版本不更换协议内核，不会自动修改 Cloudflare DNS 代理状态，也不会声称 IPv6-only VPS 能直接接受公网 IPv4 入站。

## 1.4.7 本次优化：NaiveProxy 专项修复

- **标准分享链接**：NaiveProxy 分享链接改用证书域名作为 URI 主机，例如 `naive+https://user:pass@proxy.example.com:PORT/`；移除不属于标准 Naive URI 约定的 `?sni=` 参数。域名同时用于 TLS SNI 和证书主机名校验，避免“IP 作为 URL 主机、证书却签给域名”导致客户端证书验证失败。
- **单一域名节点**：NaiveProxy 不再按 IPv4 / IPv6 源站地址重复输出两条 IP 分享链接，而是输出一条域名链接，由 DNS A / AAAA 选择可用地址。
- **服务端 TLS**：Naive 入站显式设置 `server_name` 和 `alpn:["h2"]`，固定使用标准 HTTP/2 over TCP；仍不启用 QUIC/HTTP/3。
- **双客户端配置**：生成 `naive-client.json`（TCP）和 `naive-client-uot.json`（sing-box UDP-over-TCP v2）。两个文件均使用 TLS 域名作为连接地址和 SNI，权限为 `0600`。
- **NaiveProxy 诊断**：检查证书域名、有效期、证书/私钥匹配、TCP 监听、HTTP/2 ALPN；同时检查 DNS A / AAAA 是否包含已配置的源站地址，并对疑似 CDN / 代理解析不匹配给出提示。
- **IPv6-only 提示**：如果 VPS 只有 IPv6，AAAA 必须指向 VPS IPv6。没有公网 IPv4 的情况下，IPv4-only 客户端不能直接连接；需要额外 IPv4 入站网关 / 端口映射，NAT64 出站不能替代 IPv4 入站。
- **Cloudflare 提示**：标准 NaiveProxy 需要域名直接连接源站 TCP 端口；使用 Cloudflare 橙云代理时，不能假设任意 Naive TCP 端口都能被普通 CDN 代理，应使用 DNS only 或专用 TCP 代理产品。

### NaiveProxy 使用边界
完整的服务端条件、客户端文件、IPv6-only 限制和排障流程见 [`docs/NAIVEPROXY_CN.md`](docs/NAIVEPROXY_CN.md)。


- `naive+https://` 分享链接适用于支持该 URI 约定的客户端；URI 主机必须是与证书匹配的域名，不使用 IP + `sni` 查询参数。
- 原生 NaiveProxy 主要承载 TCP。若要让 sing-box 客户端通过 Naive 承载 UDP，请导入 `naive-client-uot.json`；它使用 sing-box 专有 UDP-over-TCP v2，客户端和服务端都需使用兼容版本。并非所有支持 Naive 分享链接的应用都支持 UoT。
- sing-box Naive 出站只在特定平台 / 构建中可用。Linux 客户端需要包含 `libcronet.so` 的兼容构建；Windows 客户端需要 `libcronet.dll` 随程序放置。服务端只运行 Naive 入站，不代表任意客户端 sing-box 构建都支持 Naive 出站。
- 域名应使用 DNS only 并正确配置 A / AAAA；证书必须由公开信任 CA 签发并覆盖该域名；Naive TCP 端口必须在 VPS 防火墙和服务商安全组放行。
- “本机 TLS/H2 检查通过”不等于公网客户端已经可达。仍需从另一条网络实际导入节点并测试 TCP；UDP-over-TCP 则需另行测试 UDP 应用。

## 1.4.6 本次优化

- **NAT64 出站检测**：IPv6-only / 无原生 IPv4 源站地址时，使用 IPv6 强制访问 IPv4-only 检测站点；若返回 IPv4 地址，明确报告 NAT64 出站成功。
- **避免地址误用**：NAT64 共享出口 IPv4 只作为出站诊断结果，绝不写入 `ORIGIN_ADDR`、监听地址或节点源站地址。
- **Cloudflare 521 专项诊断**：保留 ACME 实时输出；失败时记录受限权限的诊断日志，识别 521 / 522 并提示 AAAA、源站 IPv6、TCP 80、防火墙和 Cloudflare 代理检查方向。
- **区分入站与出站**：明确提示 NAT64 出站成功不代表公网 IPv4 入站可达，也不能修复 HTTP-01 521。
- **最小化 Debian 依赖**：Cron、socat、acme.sh 使用 `--no-install-recommends`，避免安装 Cron 时顺带拉入 Exim4 / mailx 等非必要邮件服务；Cron 仍由管理器显式安装和管理。
- **部署完整性**：网页版本号、必需功能标记、Shell SHA-256 和回归测试同步更新。

## 1.4.5 本次优化

- **明确的预检诊断**：GitHub 下载失败、空文件、错误 HTML、Shell 版本不匹配、缺少功能标记、Shell 语法错误和 SHA-256 不匹配均显示独立错误原因。
- **版本回显**：报告网页期望版本与 GitHub 实际返回版本，避免静默 `grep` 退出。
- **校验值回显**：SHA-256 不匹配时同时显示网页期望值和实际下载值。
- **缓存规避**：Shell 下载 URL 增加版本查询参数，降低网页更新后命中旧缓存的概率。
- **一致性要求**：Shell 增加 `WEB_INSTALL_DIAGNOSTICS=1` 标记；网页必须确认该标记后才允许替换管理器。

## 1.4.4 本次优化

- **ACME 多源安装**：优先下载 acme.sh 官方 GitHub 源码；主入口失败时尝试 `codeload.github.com` 官方源码分发入口。
- **Debian / Ubuntu 软件源回退**：官方源码入口均不可用时，检查当前 APT 软件源是否提供 `acme.sh`，若可用则通过 `apt-get install --no-install-recommends acme.sh` 安装。
- **Alpine 软件源回退**：官方源码入口均不可用时，尝试通过 Alpine APK 软件源安装 `acme.sh`。
- **统一安装目录**：无论使用源码还是系统包，最终都通过 acme.sh 自带安装器安装到 `/root/.acme.sh/`，并使用 `--nocron`，由管理器原有的 Cron 所有权逻辑统一创建续期任务。
- **包内容检查**：系统包安装后检查 `/usr/share/acme.sh/acme.sh` 和 `dnsapi/` 文件树；不完整时拒绝继续，避免出现只能签 HTTP-01 却无法使用 DNS API 的半安装状态。
- **失败清理**：临时下载目录始终在尝试系统包回退前清理；若所有安装源均失败，明确提示检查 GitHub 443 出站连接和 APT/APK 软件源。
- **完整性校验同步**：网页安装器版本号、Shell SHA-256、测试断言和校验清单同步更新。

## 保留的既有功能

- AnyTLS、AnyTLS + Reality、VLESS + WS + TLS（直连 / Argo）、VLESS + Reality、NaiveProxy、Shadowsocks 2022。
- Debian / Ubuntu 与 Alpine；POSIX `sh`、dash、BusyBox ash。
- HTTP-01 / Cloudflare DNS-01 / 手动证书处理、证书与私钥匹配校验、证书安装回滚。
- Schema 8 端口重复 / 占用检查、手动端口预留、旧版状态迁移和端口历史复用。
- systemd / OpenRC 服务管理、Cloudflare Tunnel、BBR 配置、节点链接与客户端配置导出。

## 测试

在 Linux、macOS 或 WSL 中，安装 POSIX `sh`、Python 3、OpenSSL；Node.js 可选。运行：

```sh
./tests/run-tests.sh
```

新增 ACME 安装回退测试覆盖：
- GitHub 主源码入口不可用时自动尝试官方 codeload 入口。
- Debian / Ubuntu APT 软件源回退及 `--home /root/.acme.sh --nocron` 参数传递。
- Alpine APK 软件源回退。
- 系统包目录缺少 acme.sh 主程序或 DNS API 目录时拒绝使用。

新增 1.4.6 测试覆盖 NAT64 IPv4-only 出站探测、NAT64 出口地址不被误当作源站 IPv4、Cloudflare 521 / 522 错误提示，以及 ACME 输出实时转发和原始退出码保留。
新增 1.4.7 NaiveProxy 测试覆盖标准域名分享链接、服务端 TLS SNI / HTTP/2 ALPN、TCP-only 与 UDP-over-TCP v2 客户端 JSON、凭据文件权限及 IPv6 DNS 诊断标记。

既有测试继续覆盖：
- POSIX sh、dash、BusyBox ash 语法检查。
- 网页内联 JavaScript 语法、HTML ID / DOM 引用、Schema 8 和版本标记。
- IPv4 / IPv6 节点输出及 Shadowsocks 2022 SIP002 分享链接。
- Schema 8 重复端口、占用端口和后续手动端口预留。
- HTTP-01 签发、未到续期时间复用、证书域名 / 私钥错误、ACME 部分安装回滚。
- 证书重载钩子、手动证书暂存和替换回滚。
- Cloudflare Token / Zone ID 安全写入。
- 首次 DNS-01 失败时的 ACME 配置回滚。
- Cron 管理区块幂等写入、卸载仅删除本项目区块、旧版未标记任务保护。
- 并发锁、失效锁回收和 systemd / OpenRC 运行态识别。
- 网页安装器 SHA-256 / 版本校验、逐项预检错误诊断、Shell 语法检查、原子替换和失败恢复路径。

## 当前 VPS 日志诊断与部署检查

你提供的 Debian 13 日志确认 GitHub 与 codeload 均不可达，但 Debian APT 已成功安装 acme.sh；之后的 HTTP-01 验证收到 Cloudflare 521。1.4.6 增加 NAT64 出站检测和 521 专项诊断。

上传到 GitHub 后，可先在 VPS 执行以下只读检查，确认远端 Shell 已更新：

```sh
curl -fsSL 'https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh?v=1.4.7' -o /tmp/sb-manager-check.sh
grep '^# PROJECT_VERSION=' /tmp/sb-manager-check.sh
sha256sum /tmp/sb-manager-check.sh
```

预期版本为 `1.4.7`，预期 SHA-256 为本 README 最下方的 Shell 校验值。若不匹配，不要继续执行网页安装命令；先确认 GitHub `main` 上的 Shell 文件上传完成，再刷新网页。

**部署顺序：** 先上传 `sb-manager-debian-alpine.sh`，再上传 `index.html`。网页安装命令会打印具体的下载、版本、功能标记、Shell 语法或 SHA-256 失败原因。

首次日志已经显示 sing-box 1.14.4、socat 和 BBR 配置步骤完成，但管理器安装在 ACME 阶段退出。管理器回滚只恢复管理器脚本，不会自动卸载已安装的系统软件包或撤销所有 sysctl / systemd 更改。重新执行前建议检查：

```sh
systemctl status sing-box --no-pager
sing-box check -c /etc/sing-box/config.json
```

如果希望先独立安装 Debian 官方 acme.sh 包，可使用上方手动恢复命令；完成后再运行已通过版本与 SHA-256 检查的管理器安装命令。

## 当前 VPS 的手动恢复方式（仅在仍使用旧版脚本时需要）

如果 Debian 13 的旧版安装刚刚因 GitHub 443 不可达而中止，可先运行：

```sh
apt-get update
apt-get install -y --no-install-recommends acme.sh
cd /usr/share/acme.sh
HOME=/root sh ./acme.sh --install --home /root/.acme.sh --nocron
```

然后重新运行管理器安装命令。新版会检测 `/root/.acme.sh/acme.sh`，不会重复下载源码。Debian 软件包的文件树位于 `/usr/share/acme.sh/`；安装命令必须从该目录运行，避免发行版打包脚本的相对路径问题。

## 部署

1. 先备份 VPS 当前的 `/usr/local/sbin/sb-manager`、`/etc/sing-box/` 和 `/root/.acme.sh/`。
2. **先**将本包 `sb-manager-debian-alpine.sh` 同步到 GitHub 仓库 `mxw1589/jiedian` 的 `main` 分支。
3. **再**部署本包 `index.html`。网页生成的命令会检查远端 Shell 的版本、补丁标记和 SHA-256；若 HTML 与 Shell 不是同一版本，会停止安装，不会覆盖现有管理器。
4. 使用网页生成 SSH 命令执行安装 / 更新。

升级继续使用 Schema 8，不主动重置已有协议凭据、节点名称、端口历史或旧版配置。首次部署前仍建议备份。

## 验证边界

本包自动化测试覆盖模拟的 GitHub 下载失败和 APT/APK 软件包回退、NAT64 出站检测及 Cloudflare 521 错误分支，但**不代表已在你的 VPS 上实机运行**。没有连接 Let's Encrypt、没有执行真实公网 HTTP-01 验证，也没有在独立 Debian / Ubuntu / Alpine VPS 镜像上执行包管理器安装和完整服务生命周期测试。真实环境仍需确认域名解析、TCP 80、防火墙 / NAT 映射、Cloudflare Tunnel 健康状态及客户端连通性。

## Shell 脚本 SHA-256

```text
2333225bd8f05ff86f7e9d44501734a2693a700321a42d70b4e43176f4ceb9df
```


## HTTP-01 521 的处理边界

如果 ACME 输出 `Invalid response ...: 521`，说明 Let's Encrypt 请求到达了 Cloudflare 边缘，但 Cloudflare 无法连接源站。该状态不是 NAT64 出站失败的证据。检查 DNS 记录的 AAAA 是否指向当前 VPS IPv6、TCP 80 是否公网可达，以及 VPS / 服务商防火墙是否允许入站。可在验证期间将记录临时切换为 DNS only（灰云），让 AAAA 直接指向 VPS IPv6；或者使用 Cloudflare DNS-01。项目不会擅自修改 Cloudflare DNS 代理状态。

如果 NAT64 检测显示 IPv4 出口地址，这只证明该 VPS 能通过 IPv6/DNS64/NAT64 主动访问 IPv4-only 服务，不代表存在可被外部访问的公网 IPv4。

手动复测可运行：

```sh
curl -6 -fsS --connect-timeout 5 --max-time 10 https://ipv4.icanhazip.com/
```

若输出有效 IPv4 地址，则该次 IPv6 → DNS64/NAT64 → IPv4-only 服务的出站链路成功；若失败，不能据此断言公网 IPv6 不通，只能说明该 NAT64 探测路径没有成功。

失败的 HTTP-01 诊断日志保留在 `/tmp/sb-manager-http01.*`，权限受当前 root umask 保护；证书成功或有效证书复用时自动删除日志。
