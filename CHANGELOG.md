# 更新记录

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
