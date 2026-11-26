# Jiedian 管理器 HTTP-01 稳定增强版 1.4.3

本包基于 1.4.2 稳定性增强版继续修复，保留网页配置 Schema 8、原有协议数据和旧版状态兼容。1.4.3 重点加强并发执行保护、ACME 凭据回滚、Cron 所有权、OpenRC 运行态识别，以及网页安装器的脚本完整性校验。

## 1.4.3 本次优化

- **管理器并发锁**：安装、菜单修改、节点导出和卸载等管理器入口统一取得运行锁；检测到其他实例正在执行时停止第二个写入者，避免并发覆盖配置。异常退出后可识别并回收失效 PID 锁。
- **OpenRC 运行态识别**：除了检查 `rc-service` / `rc-update` 命令，还要求存在 OpenRC 运行目录；避免只安装了工具但实际由其他 init 系统管理时误判。
- **Cron 所有权标记**：新建的 ACME 续期任务使用独立 BEGIN/END 标记区块；卸载只删除本管理器标记区块，不删除其他 Cron 任务。
- **旧版 Cron 保护**：1.4.2 及更早版本创建的未标记 ACME Cron 行无法可靠判断所有者，因此卸载时保留并提示，不冒险删除用户任务。
- **首次 DNS-01 失败回滚**：如果本次运行首次创建 ACME 域名配置，签发或后续安装失败时删除新建的域名配置，避免遗留本次传入的 DNS API Token；原本已有配置则恢复备份。
- **网页安装脚本完整性**：生成的安装命令固定要求 1.4.3 版本及本包 Shell 文件 SHA-256 一致，并执行 `sh -n` 语法检查。
- **原管理器保护**：下载脚本先在临时文件中检查，再复制到 `/usr/local/sbin` 同目录暂存并原子替换；安装失败或被中断时尽量恢复原管理器，恢复失败时保留备份文件。

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

测试覆盖：

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
- 网页安装器 SHA-256 / 版本校验、Shell 语法检查、原子替换和失败恢复路径。

## 部署

1. 先备份 VPS 当前的 `/usr/local/sbin/sb-manager`、`/etc/sing-box/` 和 `/root/.acme.sh/`。
2. **先**将本包 `sb-manager-debian-alpine.sh` 同步到 GitHub 仓库 `mxw1589/jiedian` 的 `main` 分支。
3. **再**部署本包 `index.html`。网页生成的命令会检查远端 Shell 的版本、补丁标记和 SHA-256；若 HTML 与 Shell 不是同一版本，会停止安装，不会覆盖现有管理器。
4. 使用网页生成 SSH 命令执行安装 / 更新。

升级继续使用 Schema 8，不主动重置已有协议凭据、节点名称、端口历史或旧版配置。首次部署前仍建议备份。

## 验证边界

本包自动化测试在当前构建环境通过，但**不代表已在你的 VPS 上实机运行**。没有连接 Let's Encrypt、没有执行真实公网 HTTP-01 验证，也没有在独立 Debian / Ubuntu / Alpine VPS 镜像上执行包管理器安装和完整服务生命周期测试。真实环境仍需确认域名解析、TCP 80、防火墙 / NAT 映射、Cloudflare Tunnel 健康状态及客户端连通性。

## Shell 脚本 SHA-256

```text
0a10941a4bcb41171f119e20f9dc353b0f426cbdb7835d49a1f2645d7eea482e
```
