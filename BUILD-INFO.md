# 构建与验证记录

- 项目包：ArgoSBX V26.11.20 命令生成器 + 独立 sing-box / Xray 节点管理器
- 本地项目修订：1.2.0
- 节点管理后端：v1.0.8
- 构建日期：2026-11-24
- 基础文件：用户上传的 `jiedian2.zip`，在上一轮已验证的 1.1.1 包上继续修改

## 本次节点导出改动

- `nodes.txt` 按 IPv4、IPv6、域名 / Argo 三组显示；每个节点一行。
- `nodes-ipv4.txt`、`nodes-ipv6.txt`、`nodes-domain.txt` 只写可直接复制的分享 URI，每行一个，不混入说明文字。
- IPv6 URI 使用标准方括号地址格式，名称片段按 URI 规则编码。
- Snell 与 AnyTLS Reality 额外生成独立 IPv4 / IPv6 sing-box JSON；Snell 没有通用分享 URI，故通过 JSON 导入。
- XHTTP + ECH 保留 TLS 域名接入，并在节点清单中提示 ECH Config 与完整客户端配置文件路径。
- WS / Argo 节点按实际客户端连接地址分类；域名或 Argo 公网主机名不会被伪装成 IPv4 和 IPv6 两个节点。

## 已执行检查

- `bash -n`、`dash -n`、BusyBox `sh -n`：服务器 Shell 脚本通过。
- Node.js `--check` 与 HTML 内联脚本检查：通过。
- `bash tests/run-all.sh`：15 个自动化测试文件全部通过。
- 覆盖 IPv4 / IPv6 / 域名分组、纯 URI 紧凑文件、IPv6 方括号、Snell / AnyTLS Reality 双栈 JSON、旧地址族文件清理、SS2022 / Snell-only 场景。
- ZIP 压缩完整性及解压后再次执行测试。

## 外部依赖与限制

1. `index.html` 生成的 ArgoSBX SSH 命令会从 `yonggekkk/argosbx` 的 `main` 分支下载上游 `argosbx.sh`。上游脚本没有打包进本项目，实际运行内容可能随上游更新而变化；其 `ippz` 仍由上游控制。
2. `manager.html` 从 `mxw1589/jiedian` 的 `main` 分支下载服务器端脚本。ZIP 内本地版本为 v1.0.8；必须先同步到该 GitHub 仓库的 `main` 分支，否则版本保护会拒绝安装。
3. 本次验证范围为静态检查、命令生成测试、双栈节点导出回归测试和 ZIP 完整性；没有在真实 VPS 上执行安装、修改防火墙或启动服务。真实运行仍需在目标系统上验证网络、证书、端口和内核兼容性。
