# 更新记录

## v1.0.4
- 将 Shadowsocks 2022 纳入网页协议选择和终端统一协议管理。
- SS2022 支持 AES-128-GCM / AES-256-GCM，自动生成正确长度的 Base64 密钥。
- 首次接管单个现有 SS2022 入站时保留端口、method 和 password；重建配置时不重复创建同端口 SS2022。
- 所有协议的端口输入框移动到协议选择项右侧；取消独立端口区域。
- 终端菜单支持 SS2022 添加、删除、修改 method/password/port，单节点端口菜单也加入 SS2022。
- sing-box 版本解析兼容常见 upstream / v-prefixed 输出；解析失败显示二进制路径和原始版本输出，不会将未知版本当作旧版本继续。
- 新增 SS2022 配置保留、接管、版本解析回归测试。

# 更新记录 v1.0.3

- 修复核心问题：每次重建 sing-box `config.json` 时，自动保留不属于 sb-manager 管理的自定义 inbounds / outbounds 和其他顶层配置；SS2022 的端口、method、password 等原始字段不再因添加/删除 Snell 而消失。
- 对旧配置先执行 JSON 结构校验；旧配置无法解析时停止重建，避免静默覆盖或丢失自定义节点。
- 覆盖安装仍从现有 `manager.json` 读取已管理协议的凭据与端口；配置合并时保留 SS2022 等自定义协议配置。
- 新增终端菜单 `23`：全协议终端管理，支持脚本内七种协议的添加、删除和参数修改：AnyTLS、VLESS WS/Argo、VLESS Reality、NaiveProxy、AnyTLS Reality、VLESS XHTTP + ECH、Snell。
- 新增基础协议的终端增量添加：复用有效证书、自动生成凭据与端口；缺少必要证书时安全拒绝，不覆盖现有配置。
- 新增凭据/传输参数修改：AnyTLS 密码、WS Path、Reality UUID、Naive 密码、AnyTLS Reality 密码、XHTTP Mode/Path/ECH Public Name、Snell 版本/mode/PSK/UserKey。
- 所有新增、删除和修改均先生成候选配置并执行 sing-box/Xray 检查；失败时回滚内存参数或保留旧配置。
- 端口修改继续使用原菜单 `7` / `15`；菜单 `23` 提供完整节点生命周期入口。
- 新增 `tests/test-config-preservation.sh`，验证 SS2022 inbound 密钥、端口、method、用户自定义 outbound、route 和 DNS 配置在重建后保留。
