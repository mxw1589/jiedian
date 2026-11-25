# Jiedian 管理器 HTTP-01 证书修复版 1.4.1

本包基于此前 1.4.0 网页/管理器版本，修复用户 VPS 日志中出现的 HTTP-01 证书续期误报。

## 本次修复

acme.sh 对已经签发、但尚未到续期时间的证书会输出类似：

```text
Domains not changed.
Skipping. Next renewal time is: ...
```

旧版 `issue_http_cert()` 把 `--issue` 的任何非零退出码都当成失败，因此把“无需续期”错误地报告为“HTTP-01 证书申请失败”。

新版处理方式：

- 退出码 `0`：签发/更新成功，继续安装证书。
- 退出码 `2`：仅在 ACME 内部 ECC 证书与私钥都存在，并通过域名、有效期、PEM 和公私钥匹配检查后，才复用证书。
- 其他退出码：视为真正失败，不会跳过校验。
- 不再在调用 ACME 前一律拒绝 TCP 80 被占用的情况。若证书无需续期，则根本不需要 HTTP-01 challenge；若确实需要续期，ACME 会在 standalone challenge 阶段返回真实错误。
- ACME issue 操作增加 300 秒超时。
- 安装到 sing-box 证书目录后，再次检查证书域名、有效期及证书/私钥匹配，并设置权限。

## 文件

- `index.html`：1.4.0 网页版本，保留原有字段/命令生成逻辑。
- `sb-manager-debian-alpine.sh`：1.4.1 修复版服务器管理脚本。
- `tests/`：语法、网页/节点回归及 HTTP-01 行为测试。

## 测试

在 Linux、macOS 或 WSL 中安装 POSIX sh、Python 3、OpenSSL、Node.js（Node 可选）后运行：

```sh
./tests/run-tests.sh
```

HTTP-01 行为测试会在临时目录中生成自签名测试证书，并用 mock acme.sh 模拟退出码；不会连接 Let's Encrypt，也不会修改真实 `/root/.acme.sh` 或 VPS 配置。

## 部署

1. 先备份 VPS 当前的 `/usr/local/sbin/sb-manager`、`/etc/sing-box/` 和 `/root/.acme.sh/`。
2. 将包内 `sb-manager-debian-alpine.sh` 同步到 GitHub 仓库 `mxw1589/jiedian` 的 `main` 分支。
3. 部署包内 `index.html`（如网页当前已是 1.4.0，可保持不变）。
4. 再用网页生成 SSH 命令运行安装/更新。

注意：真实续期仍要求域名解析正确、TCP 80 可达和 ACME 验证成功。此修复解决的是“证书未到续期时间却被误判失败”，不会绕过真实的 HTTP-01 验证。

本包不代表已在用户 VPS 上实机运行或完成客户端连接测试。
