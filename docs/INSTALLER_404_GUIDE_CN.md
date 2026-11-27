# `sb-manager-debian-alpine.sh` 返回 404：诊断说明

## 现象

安装器报告：

```text
curl: (22) The requested URL returned error: 404
[安装预检失败] 无法从 GitHub raw 下载管理脚本：
https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh?v=1.4.6
```

## 含义

`curl: (22)` 通常是因为调用方启用了 `--fail`，远端 HTTP 响应为 4xx/5xx。这里明确显示 HTTP 404，表示该 Raw 路径在指定仓库/分支下没有可用文件，或该资源对当前访问不可见。

这不是由以下因素直接造成的：

- Debian 13；
- VPS 只有 IPv6；
- sing-box 内核版本；
- 本地 `/usr/bin/sb` 管理脚本；
- `/etc/s-box/sb.json` 节点配置。

## 安全诊断

在本 Repair Kit 根目录执行：

```bash
bash tools/check-manager-404.sh
```

该工具只读取 GitHub 元数据、Raw URL 状态和仓库文件树，不执行任何下载到的脚本。

如果文件被移动/改名，工具可能列出候选路径。候选路径不等于兼容版本。必须让原维护者确认：

1. 新脚本的正式路径；
2. 对应版本号；
3. 与脚本内容匹配的完整 SHA-256；
4. 该脚本是否仍支持当前安装器生成的配置 schema。

在获得这些信息前，不要关闭 SHA-256 校验，不要把其他 fork 的脚本直接替换进来，也不要用 `curl ... | bash` 执行未知内容。

## 重要：和本 Repair Kit 的关系

本项目主修复程序只修改现有 `/usr/bin/sb`。用户日志中的安装器试图从 `mxw1589/jiedian` 下载另一个 `sb-manager-debian-alpine.sh`，目标程序不是同一个文件。因此本 Repair Kit 可以诊断 404，但不能凭空恢复上游已删除/移动的脚本，也不会擅自伪造新下载地址。

## Token 安全

用户提供的命令将配置 JSON 编码为 Base64，JSON 中含有 `argo_token`。Base64 可直接解码，不具备保密性。若该值是真实 Tunnel Token，应在对应服务后台撤销并重新生成。不要把原命令、Base64 配置、Token 或节点凭据提交到公开 GitHub 仓库。
