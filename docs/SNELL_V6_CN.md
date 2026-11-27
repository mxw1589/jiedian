# Snell v6 使用与导入说明

## 协议支持

本项目使用 sing-box 内置 Snell v6 inbound/outbound，不安装独立 Snell 服务端。根据 sing-box 官方配置文档，Snell inbound/outbound 从 sing-box 1.14.0 开始支持；version 6 需要 PSK（12–255 字节）并使用 `mode`。

官方文档：
- https://sing-box.sagernet.org/configuration/inbound/snell/
- https://sing-box.sagernet.org/configuration/outbound/snell/

## 项目生成的服务端参数

| 参数 | 默认 / 来源 | 说明 |
|---|---|---|
| version | `6` | Snell v6 |
| listen_port | 网页输入或自动分配 | TCP 监听端口 |
| psk | 自动生成 32 字节随机值 | 需要与客户端一致 |
| mode | `default` | 推荐，使用默认流量整形模式 |
| mode 可选 | `unshaped` | 不使用默认整形，但仍保留 AEAD 加密 |

项目不开放 `unsafe-raw`，因为该模式会移除加密层。

## 服务端生成文件

- `/etc/sing-box/snell-v6-client-primary.json`
- `/etc/sing-box/snell-v6-client-ipv6.json`（配置了独立 IPv6 地址时）

两个文件包含 PSK，权限为 `0600`。仅通过 SSH/SFTP 安全下载。

## 导入步骤

1. 打开网页选择 Snell v6；注意页面默认预选 Argo WS，如果只安装 Snell，请取消 Argo WS，否则还会要求 Cloudflare Tunnel Token。安装完成后运行 `sb-manager`，在节点输出中确认 Snell v6 地址、端口、mode 和客户端 JSON 路径。
2. 使用 SFTP 或 SCP 下载对应 JSON 文件。
3. 在 sing-box 1.14.0+ 客户端中导入本地配置文件。
4. 启用配置。默认 mixed 入站监听 `127.0.0.1:2080`，应用可使用该本地 HTTP/SOCKS 代理。
5. 如果要合并进现有 sing-box 客户端配置，只复制 Snell outbound，并根据需要调整 `route.final`；不要覆盖原有 DNS、inbounds 或 route 设置。

## 手动配置时需要的字段

- Server：VPS 公网 IP 或直连域名
- Server Port：管理器显示的 TCP 端口
- Version：6
- PSK：管理器生成的 PSK
- Mode：与服务端一致，默认为 `default`

对应的 sing-box outbound 示例（将占位值替换为实际信息）：

```json
{
  "type": "snell",
  "tag": "snell-v6",
  "server": "2001:db8::1234",
  "server_port": 23456,
  "version": 6,
  "psk": "替换为管理器生成的PSK",
  "mode": "default"
}
```

如果已有 sing-box 客户端配置，请把这个对象合并到现有 `outbounds` 数组，并将 `route.final` 或对应路由规则指向 `snell-v6`；不要用这个片段覆盖完整配置。

本项目不生成非标准或未经验证的 `snell://` 分享链接。

## 网络与防火墙

- 放行 Snell 监听 TCP 端口。标准 Snell v6 的 UDP 通过 TCP 承载，不需要另开同端口 UDP 入站；客户端应启用 UDP 网络支持。
- 如果使用 NAT，确保公网映射目标端口与本机监听端口一致。
- IPv6-only VPS 只能被具备 IPv6 连通性的客户端直接访问；IPv4-only 客户端需要 IPv4 网关 / NAT 转发。
- 不需要 TLS 证书、SNI、Reality、Cloudflare DNS Token 或独立 Snell 二进制。

## PSK 轮换

在 `sb-manager` 菜单 20 中选择 Snell v6，进入专属参数设置。PSK 留空保持原值，输入 `-` 生成新 PSK。轮换后旧客户端配置会失效，需要重新下载并导入新的 JSON。
