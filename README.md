# ArgoSBX SSH 命令生成器 + 旧版 sing-box/Xray 管理器

本压缩包以原 `jiedian2.zip` 为基础整理，主入口升级为 ArgoSBX V26.11.20 参数生成器，同时保留原有自建 sing-box/Xray 管理器作为独立备用页面。

## 文件说明

- `index.html`：主入口。生成 ArgoSBX 官方脚本所需的 SSH 命令，包含 15 种协议、15 种 WARP 组合、CDN、证书、订阅、Argo 隧道和快捷命令。
- `generator.js`：参数校验、依赖判断、Shell 安全转义、命令生成和旧命令解析逻辑。
- `manager.html`：原有自建 sing-box/Xray 管理器页面，独立保留。
- `sb-manager-debian-alpine.sh`：原有 Debian/Ubuntu/Alpine 管理脚本，修复 SS2022 端口占用判断及 SS2022/Snell 双栈节点导出问题。
- `tests/`：原回归测试与新增生成器/节点逻辑测试。

## 使用主生成器

1. 解压 ZIP，在浏览器中打开 `index.html`。
2. 勾选需要安装的协议。每个协议右侧都可以填写端口；**端口留空表示让服务器随机分配**。
3. 按实际需求填写全局配置。大多数字段都可以留空，页面会按官方脚本默认逻辑处理。
4. 选择 curl 或 wget，复制生成的 SSH 命令。
5. 在目标 VPS 的 Bash 终端执行。安装、下载内核、生成节点链接和订阅由 ArgoSBX 官方脚本在服务器上完成。

生成命令调用的远程脚本地址：

`https://raw.githubusercontent.com/yonggekkk/argosbx/main/argosbx.sh`

因此，VPS 执行时需要能够访问 GitHub。页面标题标注 V26.11.20，但生成命令取的是 GitHub `main` 分支脚本；如果上游更新，执行时可能使用更新后的版本，并非固定锁定到 2026-11-20 的提交。

## 输入项怎么填

### 协议和端口

- 勾选协议即表示启用该协议。
- 端口框留空：官方脚本随机分配。
- 手动端口：填 `1–65535` 的数字；建议使用未被占用的端口，并在云厂商安全组/系统防火墙/NAT 映射中放行对应 TCP 或 UDP。
- 同一组配置中不要给多个协议填写相同端口；页面会拦截重复端口。
- NaiveProxy 依赖 `alns=y`，必须先开启「域名/IP 证书 TLS」。

### 全局配置

| 输入项 | 填写规则 |
|---|---|
| `uuid` | 可留空自动生成；手动填写时使用标准 UUID。 |
| `reym` | 仅 Reality 相关协议使用；留空默认 `apple.com`，自定义时只填域名。 |
| `cfip` | 可填 1–2 个 CDN 优选 IP 域名，使用空格分隔；不确定时留空。 |
| `alns` | 默认关闭，相关 TLS 协议使用自签证书；开启后使用域名/IP 证书，并允许选择 NaiveProxy。 |
| `hyjpt` | 仅 Hysteria2 使用；支持单端口和范围，例：`123:456 789`。 |
| `cdnym` | VMess WS、VLESS XHTTP-Enc、VLESS WS-Enc 的 CF 回源 Host 域名；无 CDN 回源需求时留空。 |
| `warp` | 默认本机 IP 出站；可选 15 种 Sing-box/Xray WARP IPv4/IPv6 组合。 |
| `ippz` | 自动、仅 IPv4 或仅 IPv6 节点导出。 |
| `oap` | 默认关闭。开启会放宽系统端口访问控制，存在安全风险，不建议无明确需要时开启。 |
| `name` | 节点名称前缀；支持中文、字母、数字、点、下划线和短横线。 |

### 订阅设置

- `sub`：选择开启后，官方脚本生成 Clash/Mihomo、Sing-box 和聚合单节点订阅。
- `subid`：订阅路径密码；留空时使用 UUID。
- `subpt`：订阅服务端口；留空自动分配。
- 订阅端口不能与已填写的代理协议端口重复。

### Argo 隧道

- `argo`：选择 VMess WS、VLESS WS-Enc 或 VLESS XHTTP-Enc 作为 Argo 主协议。
- `agqc`：默认 TCP；需要 UDP 模式时选择 UDP。
- 临时隧道：`agn` 和 `agk` 都留空。
- 固定隧道：`agn` 填 Cloudflare Tunnel 的公网主机名，`agk` 填完整 Tunnel Token；两项必须同时填写。
- VLESS XHTTP-Enc 的 Argo 模式仅支持固定隧道。

## 快捷命令

- `list`：显示当前节点；会保留 IPv4/IPv6 导出选项。
- `del`：卸载 ArgoSBX。
- `upx` / `ups` / `upa`：分别升级 Xray、Sing-box、Argo 内核。
- `res`：重启脚本服务。
- `rep`：按当前填写的协议和变量重置/更新；必须至少选择一种协议。

页面支持把以前保存的完整命令粘贴到「导入以前保存的命令」区域，恢复可识别的参数。

## 安全说明

- 命令中可能包含 UUID、Cloudflare Tunnel Token、订阅密码等敏感信息。不要把命令截图公开，也不要提交到公开仓库。
- 页面不会上传表单内容，也不会自动连接 VPS；真正执行的是生成命令中引用的上游脚本。
- `oap` 是高风险选项。优先只开放实际使用的协议端口。
- 建议先在测试 VPS 验证协议和客户端配置，再迁移到正式服务器。

## 原有管理器

`manager.html` 和 `sb-manager-debian-alpine.sh` 是原 ZIP 中的自建 sing-box/Xray 管理器，与 `index.html` 的 ArgoSBX 官方脚本命令生成器使用不同后端。两者的命令、配置文件和服务管理逻辑不能混用。

## 测试

在 Linux、WSL 或安装了 Node.js 的环境中，从解压目录执行：

```sh
for test in tests/*.sh; do sh "$test"; done
node tests/test-generator.js
node tests/test-ui-smoke.js
```

生成器测试覆盖 15 种协议开关、WARP 组合、依赖关系、端口检查、Argo 固定/临时隧道、订阅端口、Shell 转义、旧命令导入和快捷命令；UI 冒烟测试覆盖动态联动、NaiveProxy、订阅和重置。旧管理器的 shell 语法和原回归测试也保留。
