# Jiedian 管理器 HTTP-01 稳定增强版 1.4.5

本包基于 1.4.3 稳定性增强版继续修复，保留网页配置 Schema 8、原有协议数据和旧版状态兼容。1.4.5 在 1.4.4 的 ACME 多源安装基础上，增加安装预检诊断；1.4.4 的 ACME 备用安装机制继续保留。重点解决 GitHub 不可访问时 ACME 客户端无法安装的问题，同时保留既有证书、凭据和管理器回滚保护。

## 1.4.5 本次优化

- **明确的预检诊断**：GitHub 下载失败、空文件、错误 HTML、Shell 版本不匹配、缺少功能标记、Shell 语法错误和 SHA-256 不匹配均显示独立错误原因。
- **版本回显**：报告网页期望版本与 GitHub 实际返回版本，避免静默 `grep` 退出。
- **校验值回显**：SHA-256 不匹配时同时显示网页期望值和实际下载值。
- **缓存规避**：Shell 下载 URL 增加版本查询参数，降低网页更新后命中旧缓存的概率。
- **一致性要求**：Shell 增加 `WEB_INSTALL_DIAGNOSTICS=1` 标记；网页必须确认该标记后才允许替换管理器。

## 1.4.4 本次优化

- **ACME 多源安装**：优先下载 acme.sh 官方 GitHub 源码；主入口失败时尝试 `codeload.github.com` 官方源码分发入口。
- **Debian / Ubuntu 软件源回退**：官方源码入口均不可用时，检查当前 APT 软件源是否提供 `acme.sh`，若可用则通过 `apt-get install acme.sh` 安装。
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

你提供的 Debian 13 日志中，首次失败仍显示旧版 1.4.3 的单一 GitHub 下载逻辑；后续命令只显示通用失败信息。1.4.5 已将网页预检改为逐项报错。

上传到 GitHub 后，可先在 VPS 执行以下只读检查，确认远端 Shell 已更新：

```sh
curl -fsSL 'https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh?v=1.4.5' -o /tmp/sb-manager-check.sh
grep '^# PROJECT_VERSION=' /tmp/sb-manager-check.sh
sha256sum /tmp/sb-manager-check.sh
```

预期版本为 `1.4.5`，预期 SHA-256 为本 README 最下方的 Shell 校验值。若不匹配，不要继续执行网页安装命令；先确认 GitHub `main` 上的 Shell 文件上传完成，再刷新网页。

**部署顺序：** 先上传 `sb-manager-debian-alpine.sh`，再上传 `index.html`。网页安装命令会打印具体的下载、版本、功能标记、Shell 语法或 SHA-256 失败原因。

首次日志已经显示 sing-box 1.14.4、socat 和 BBR 配置步骤完成，但管理器安装在 ACME 阶段退出。管理器回滚只恢复管理器脚本，不会自动卸载已安装的系统软件包或撤销所有 sysctl / systemd 更改。重新执行前建议检查：

```sh
systemctl status sing-box --no-pager
sing-box check -c /etc/sing-box/config.json
```

如果希望先独立安装 Debian 官方 acme.sh 包，可使用 1.4.4 README 中的手动恢复命令；完成后再运行已通过版本与 SHA-256 检查的管理器安装命令。

## 当前 VPS 的手动恢复方式（仅在仍使用旧版脚本时需要）

如果 Debian 13 的旧版安装刚刚因 GitHub 443 不可达而中止，可先运行：

```sh
apt-get update
apt-get install -y acme.sh
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

本包自动化测试覆盖模拟的 GitHub 下载失败和 APT/APK 软件包回退，但**不代表已在你的 VPS 上实机运行**。没有连接 Let's Encrypt、没有执行真实公网 HTTP-01 验证，也没有在独立 Debian / Ubuntu / Alpine VPS 镜像上执行包管理器安装和完整服务生命周期测试。真实环境仍需确认域名解析、TCP 80、防火墙 / NAT 映射、Cloudflare Tunnel 健康状态及客户端连通性。

## Shell 脚本 SHA-256

```text
0a7fef2fa62fc0df07076e61e660f959dcdb46904d807883330eb3871463212c
```
