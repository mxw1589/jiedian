# 更新记录

## 1.2.0

- 节点输出改为紧凑单行格式，分为 IPv4、IPv6、域名 / Argo 三组；不再为每个节点重复打印协议说明、地址、端口和空行。
- 新增 `nodes-ipv4.txt`、`nodes-ipv6.txt`、`nodes-domain.txt` 三个独立节点文件，并保留完整 `nodes.txt`。
- IPv6 URI 继续自动使用方括号格式；WS / Argo 按实际客户端连接地址归组，XHTTP + ECH 按 TLS 域名归组。
- Snell 和 AnyTLS Reality 新增 IPv4 / IPv6 独立 sing-box 客户端 JSON，保留原有默认客户端配置文件名以兼容旧流程。
- 更新管理器网页版本检查，旧版远程脚本不会被误认为支持紧凑双栈导出。
- 增加双栈文件导出、紧凑排版和按地址族 JSON 回归测试。

## 1.1.1

- 管理器安装器增加 v1.0.7 远程脚本版本标记校验；旧版远程脚本会停止安装，避免页面与服务器端节点逻辑不一致。
- 卸载操作增加大写 YES 二次确认，减少误删 `/etc/sing-box` 与 `/etc/xray` 的风险。
- 修正自动内核协议的说明，明确 V26.11.20 上游在仅选择自动协议时默认走 Xray。
- 增加统一回归测试入口，统一执行 Shell 与 Node.js 测试。

## 1.1.0

- 主入口升级为 ArgoSBX V26.11.20 完整命令生成器。
- 补齐 Xray、Sing-box 和自动内核组共 15 种协议开关及端口输入。
- 补齐 15 种 WARP 出站组合、Reality、CDN 优选域名、TLS 证书、HY2 端口跳跃、IP 导出、防火墙开关、节点前缀、订阅和 Argo 临时/固定隧道参数。
- 增加协议依赖联动：NaiveProxy 依赖 `alns=y`；Reality/CDN/HY2 字段按协议启用；Argo 主协议自动勾选；XHTTP-Enc Argo 强制固定隧道。
- 增加端口、域名、UUID、Token、订阅参数和范围端口校验；拦截重复端口。
- 改用 Shell 单引号安全转义；支持导入旧命令、curl/wget、快捷命令、复制和 TXT 下载。
- 保留原自建 sing-box/Xray 管理器为 `manager.html`。
- 修复旧管理器 SS2022 端口占用判断，并补齐 SS2022/Snell IPv4 + IPv6 节点输出。
- 增加生成器、HTML 脚本和节点导出回归测试。


## 1.2.1
- 新增 `nodes-dualstack.txt`：将 IPv4 与 IPv6 节点合并到同一个纯 URI 列表，IPv4 在前、IPv6 在后，方便一次性导入客户端。
- 保留原有按地址族分组文件和域名/Argo 文件。
- 明确双栈在标准分享链接中以两个独立节点表示，避免生成不兼容的伪双地址 URI。


## 1.2.2 / manager v1.0.9

- `manager.html` 新增节点输出地址族选择：IPv4、IPv6、IPv4 + IPv6 双栈合并；默认双栈。
- 安装命令最后调用本仓库安装的 `/usr/local/sbin/sb-manager nodes {4|6|46}`，不再依赖上游 ArgoSBX 的 `ippz` 参数实现双栈。
- 服务端 `sb-manager nodes` 增加地址族参数；不带参数时保持原有行为。
- 主 `index.html` 增加跳转说明，明确官方 ArgoSBX 的 `ippz` 不支持 `46`，双栈选择应使用本仓库的 `manager.html`。
- 远程脚本版本标记提升至 v1.0.9；旧远程脚本会被网页版本检查拒绝。
