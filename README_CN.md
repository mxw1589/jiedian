# Sing-box-yg v26.4.11 修复包

## 这个 ZIP 是什么

这是针对 VPS 上**现有 `/usr/bin/sb` 文件**的安全补丁包，不是完整的官方源码重打包。它根据官方仓库 `yonggekkk/sing-box-yg` 的 v26.4.11 源码结构制作，采用严格锚点匹配；如果本机脚本不是对应版本/代码结构，会停止，不会强行覆盖。

官方来源：
- 仓库：https://github.com/yonggekkk/sing-box-yg
- 脚本：https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh
- 版本说明：https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/version

## 修复内容

1. **依赖自愈**：不再只依赖首次运行的 `sbyg_update` 标记；每次启动检查 `jq`、`curl`、`wget`、`openssl`、`socat`、`busybox`、`iptables`、`tar`、`expect`、`xxd`、`python3`、`qrencode`、`git`、`ip`、`ss`、`ping`、`crontab` 等命令。缺少时通过系统包管理器补装。
2. **TTY 兼容**：仅在标准输入和输出均为终端时执行 `stty`，避免非交互 SSH/管道调用时报 `Inappropriate ioctl for device`。
3. **Argo 判断保护**：先确认 `jq` 和 `/etc/s-box/sb.json` 可用，再读取 `.inbounds[1].tls.enabled`。读取失败时明确报错并退出，不再把空值误当成 TLS 已开启。
4. **安全备份**：修改前备份到 `/var/backups/sing-box-yg/`。
5. **语法验证与回滚**：修改后执行 `bash -n /usr/bin/sb`；失败则恢复备份。

## 安装方法（Ubuntu 22.04 / Debian）

把 ZIP 解压到 VPS，例如 `/root/sb-yg-repair/`，然后执行：

```bash
cd /root/sb-yg-repair
chmod +x repair.sh
bash repair.sh
```

修复后运行：

```bash
jq --version
bash -n /usr/bin/sb
sb
```

## 重要说明

- 不会重新安装 sing-box 内核。
- 不会删除或重建 `/etc/s-box/sb.json`、UUID、端口、证书、订阅或节点。
- 不会关闭防火墙，也不会开放任何端口。
- **不会强行让 TLS 模式的 VMess 使用 Argo。** 上游脚本设计为 VMess TLS 开启时不提供该 Argo 路径；补丁只确保 TLS 状态读取准确。如果 `jq` 修复后显示 TLS 为 `true`，原脚本提示 Argo 不可用属于其既定逻辑，不是依赖故障。
- 如果 VPS 的 `/usr/bin/sb` 与官方 v26.4.11 代码锚点不同，补丁会停止。此时需要用户提供实际 `/usr/bin/sb` 文件，才能按其本机改版精确修复。

## 回滚

查看备份：

```bash
ls -lt /var/backups/sing-box-yg/
```

选择对应备份文件恢复（请将文件名替换为实际名称）：

```bash
cp -a /var/backups/sing-box-yg/sb.v26.4.11.before-repair.TIMESTAMP.bak /usr/bin/sb
bash -n /usr/bin/sb
```
