# singbox-alpine-lite

面向 64 MiB Alpine Linux VPS 的 sing-box 一键安装器。它使用 Alpine `edge/community` 的官方签名裁剪版本，支持 VLESS Reality、Hysteria2、双协议和可选的 Hysteria2 UDP 端口跳跃，并提供 OpenRC 服务与 `sb` 管理命令。

## 安装

仅安装 VLESS Reality，64 MiB 环境优先使用此方案：

```sh
wget -qO /root/singbox-alpine-lite-install.sh https://raw.githubusercontent.com/BlackCatCmx/singbox-alpine-lite/main/install.sh && sh /root/singbox-alpine-lite-install.sh --protocols vless --vless-port 443 --sni addons.mozilla.org --name alpine-lite
```

仅安装 Hysteria2：

```sh
wget -qO /root/singbox-alpine-lite-install.sh https://raw.githubusercontent.com/BlackCatCmx/singbox-alpine-lite/main/install.sh && sh /root/singbox-alpine-lite-install.sh --protocols hy2 --hy2-port 8443 --sni addons.mozilla.org --name alpine-lite
```

同时安装 VLESS Reality 和 Hysteria2：

```sh
wget -qO /root/singbox-alpine-lite-install.sh https://raw.githubusercontent.com/BlackCatCmx/singbox-alpine-lite/main/install.sh && sh /root/singbox-alpine-lite-install.sh --protocols both --vless-port 443 --hy2-port 8443 --sni addons.mozilla.org --name alpine-lite
```

启用 Hysteria2 端口跳跃时，`--hy2-port` 必须等于范围起点，并且服务商必须转发完整 UDP 范围：

```sh
wget -qO /root/singbox-alpine-lite-install.sh https://raw.githubusercontent.com/BlackCatCmx/singbox-alpine-lite/main/install.sh && sh /root/singbox-alpine-lite-install.sh --protocols both --vless-port 443 --hy2-port 20000 --hy2-port-range 20000:30000 --sni addons.mozilla.org --name alpine-lite
```

## 可用参数

```text
--protocols VALUE       vless、hy2 或 both，默认 both
--vless-port PORT       VLESS Reality TCP 端口，默认 443
--hy2-port PORT         Hysteria2 UDP 端口，默认 8443
--hy2-port-range RANGE  可选的 UDP 跳跃范围，例如 20000:30000
--sni DOMAIN            Reality/TLS 服务器名称，默认 addons.mozilla.org
--server HOST           写入节点链接的公网地址或域名
--name NAME             节点名称
--dry-run               只校验并显示参数，不修改系统
--help                  显示帮助
```

## 管理命令

安装完成后可以使用：

```sh
sb       # 打开管理菜单
sb -N    # 输出节点链接
sb -S    # 查看服务状态
sb -r    # 重启服务
sb -s    # 停止服务
sb -v    # 查看版本
sb -i    # 查看协议和端口
```
