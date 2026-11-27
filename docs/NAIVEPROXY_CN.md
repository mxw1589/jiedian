# NaiveProxy 配置与排障指南（Jiedian Manager 1.4.9）

## 1. 服务端条件

- sing-box 服务端版本至少为 1.13.0；建议使用项目安装器已验证的正式版本。
- 必须启用 Naive 入站，并使用 TCP / HTTP/2。
- 必须有公开 CA 签发、未过期且覆盖 `TLS_DOMAIN` 的完整证书与对应私钥。
- TLS 域名的 DNS A / AAAA 记录必须指向真正能到达该 VPS 的源站地址。
- Naive 监听 TCP 端口必须在 VPS 防火墙、云安全组和上游 NAT 规则中放行。
- 标准 NaiveProxy 不能依赖普通 Cloudflare 橙云代理转发任意自定义 TCP 端口；使用 DNS only 或明确支持该 TCP 服务的专用转发产品。

## 2. 分享链接

1.4.7 输出标准域名形式：

```text
naive+https://USERNAME:PASSWORD@proxy.example.com:PORT/#NODE_NAME
```

`proxy.example.com` 同时承担连接目标、TLS SNI 和证书主机名校验。不要把 IP 地址放在 URI 主机位置，再附加 `?sni=...`；常见 Naive URI 约定没有标准化这个查询参数。

## 3. sing-box 客户端文件

刷新节点信息后，管理器会生成：

- `/etc/sing-box/naive-client.json`：TCP / HTTP/2。
- `/etc/sing-box/naive-client-uot.json`：TCP / HTTP/2 + UDP-over-TCP v2。

两份文件均包含认证凭据，权限设为 `0600`。只通过安全方式传输，不要放入公开仓库或公开订阅。

导入后，客户端本地提供 `127.0.0.1:2080` mixed 入站（HTTP + SOCKS）。如客户端本机端口冲突，先修改 JSON 中的 `listen_port`。

UDP-over-TCP 是 sing-box 的扩展机制，不是所有 Naive 客户端都支持。原生 NaiveProxy 主要代理 TCP。只有客户端也支持 sing-box UoT v2 时，才使用 `naive-client-uot.json`。

## 4. 客户端核心要求

sing-box Naive 出站并非每个构建都可用：

- Linux：选择包含 `libcronet.so` 的兼容构建；官方 purego 构建需要该库与 sing-box 二进制位于同目录或系统库路径。
- Windows：确保 `libcronet.dll` 与 `sing-box.exe` 同目录或位于 PATH。
- Android / Apple：使用支持 Naive 出站的 sing-box 客户端版本。

服务端 Naive 入站正常，不代表客户端所用的 sing-box 构建一定含 Naive 出站。

## 5. IPv6-only VPS 注意事项

如果 VPS 只有 IPv6：

- TLS 域名必须有正确 AAAA 记录，指向 VPS 的公网 IPv6。
- IPv6 网络客户端可以直接连接。
- 没有公网 IPv4 入站时，IPv4-only 客户端不能直接连接。NAT64 出站只解决 VPS 主动访问 IPv4 网站，不会给 VPS 增加 IPv4 入站。
- 若要服务 IPv4-only 客户端，需要另配可用的 IPv4 入站网关 / 端口映射，并确认服务商允许隧道转发。

## 6. 内置诊断

在管理菜单中选择 `14. 诊断 NaiveProxy`。诊断会检查：

1. 证书是否覆盖 TLS 域名、是否过期；
2. 证书公钥与私钥是否匹配；
3. TCP 监听端口是否存在；
4. 本机 TLS 证书验证是否成功；
5. TLS ALPN 是否协商为 HTTP/2（h2）；
6. DNS A / AAAA 是否与已配置的源站地址一致。

本机诊断通过不等于公网一定可达。仍应从外部网络测试域名解析、TCP 端口、客户端导入、认证和实际网页访问。

## 7. 常见故障判断

| 表现 | 优先检查 |
|---|---|
| 证书主机名错误 | 分享链接主机是否为证书域名；DNS 是否直达源站 |
| TLS 握手失败 | 证书链、有效期、私钥匹配、SNI |
| 没有 `h2` ALPN | 服务端 Naive TLS / sing-box 配置和版本 |
| 本机正常、外网超时 | 防火墙、安全组、NAT 端口映射、DNS 代理状态 |
| IPv6 客户端可用、IPv4-only 客户端不可用 | VPS 是否没有公网 IPv4 入站 |
| TCP 正常、UDP 应用不通 | 是否导入 UoT v2 配置；客户端是否支持 UoT |
| 客户端提示 Naive 核心不可用 | 客户端 sing-box 构建是否包含 libcronet 运行时 |

