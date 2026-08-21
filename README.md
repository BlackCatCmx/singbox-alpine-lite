# singbox-alpine-lite

面向 64 MiB 低内存 Alpine Linux VPS 的轻量 sing-box 安装器。

本项目不下载 sing-box 官方全功能 musl Release，而是通过 Alpine `edge/community` 安装由 Alpine 官方维护和签名的软件包。该软件包去掉了 Naive outbound、CCM 和 OCM 等当前服务端不需要的构建功能，amd64 二进制约 47 MiB；官方 1.13.19 musl 二进制约 66 MiB。

当前支持：

- VLESS Reality over TCP；
- Hysteria2 over UDP；
- 同时启用 VLESS Reality 与 Hysteria2；
- 可选的 Hysteria2 UDP 端口跳跃；
- OpenRC 开机启动与有限崩溃重启；
- `sb` 轻量管理命令。

## 设计目标

- 只运行一个 sing-box 进程；
- 通过 Alpine `apk` 校验仓库签名，不自行维护第三方二进制镜像；
- 使用 Alpine 的裁剪构建，避免 Naive/Cronet 增加二进制体积；
- 不安装面板、Web 服务、数据库、WARP、Argo 或常驻监控脚本；
- 凭据和节点链接仅保存在服务器 `/etc/sing-box`；
- 明确暴露安装、配置和服务启动失败，不制造假成功。

安装器目前只接受 sing-box `1.13.x`。Alpine edge 升级到新的功能版本后，安装器会明确停止，等待本项目完成兼容验证，而不会静默安装未经测试的版本。

## 安装

将脚本下载到服务器后执行：

```sh
wget -qO /root/singbox-alpine-lite-install.sh https://raw.githubusercontent.com/BlackCatCmx/singbox-alpine-lite/main/install.sh
```

同时安装 VLESS Reality 和 Hysteria2：

```sh
sh /root/singbox-alpine-lite-install.sh \
  --protocols both \
  --vless-port 443 \
  --hy2-port 8443 \
  --sni addons.mozilla.org \
  --name alpine-lite
```

也可以直接运行脚本进入交互式安装：

```sh
sh /root/singbox-alpine-lite-install.sh
```

可用参数：

```text
--protocols VALUE       vless、hy2 或 both
--vless-port PORT       VLESS Reality TCP 端口
--hy2-port PORT         Hysteria2 UDP 监听端口
--hy2-port-range RANGE  可选的 UDP 跳跃范围，例如 20000:30000
--sni DOMAIN            Reality/TLS 服务器名称
--server HOST           写入节点链接的公网地址或域名
--name NAME             节点名称
--dry-run               只校验并显示参数，不修改系统
```

## Alpine 软件包来源

sing-box 从以下官方仓库安装：

```text
https://dl-cdn.alpinelinux.org/alpine/edge/community
```

安装器通过单次 `apk add --repository` 选择该仓库，不会把整台系统永久切换到 Alpine edge，也不会修改 `/etc/apk/repositories`。

Hysteria2 生成证书需要 `openssl`。只有系统缺少它时才会从当前 Alpine 系统仓库安装。

端口跳跃需要 `iptables`。只有用户明确配置跳跃范围且系统缺少它时，安装器才会尝试安装。

## Hysteria2 端口跳跃

示例：

```sh
sh /root/singbox-alpine-lite-install.sh \
  --protocols hy2 \
  --hy2-port 20000 \
  --hy2-port-range 20000:30000
```

范围起点同时是 sing-box 的真实监听端口和失败后的单端口回退端口。其余 UDP 端口通过本机 `iptables` 重定向到范围起点。

端口跳跃要求：

- 服务商已将完整 UDP 范围转发给 VPS；
- 容器具有 `CAP_NET_ADMIN` 权限；
- 内核允许创建 NAT/REDIRECT 规则；
- 上游防火墙或安全组放行完整范围。

本机规则无法补齐服务商没有分配的 NAT 端口。规则创建失败时，安装器会清理失败状态，并明确退回单端口 Hysteria2；生成的节点链接也会使用单端口。

## OpenRC 服务

安装器会创建 `/etc/init.d/sing-box` 并加入默认启动级别。

如果系统提供 `supervise-daemon`，服务异常退出后会有限重启：

- 重启前等待 10 秒；
- 60 秒内最多连续重启 3 次；
- 超过限制后停止，不进入无限重启循环。

## sb 管理命令

安装完成后可以使用：

```sh
sb              # 交互式菜单；非交互调用时输出节点链接
sb -N           # 输出 VLESS/Hysteria2 节点链接
sb -S           # 查看服务状态
sb -r           # 重启服务
sb -s           # 停止服务
sb -v           # 查看 sing-box 版本
sb -i           # 查看已安装协议和端口
```

配置、证书、私钥、密码、状态和节点链接位于 `/etc/sing-box`。不要将这些文件提交到 Git 仓库或发送给不受信任的人。

## 低内存说明

减小二进制只能降低代码映射和页缓存压力。实际流量仍会增加 Go 堆、QUIC 缓冲区和连接状态内存，Hysteria2 的压力通常高于纯 VLESS TCP。

64 MiB 环境必须使用真实 cgroup 数据判断内存上限；容器内 `free` 可能显示宿主机总内存。可以读取：

```sh
cat /sys/fs/cgroup/memory.max
cat /sys/fs/cgroup/memory.current
cat /sys/fs/cgroup/memory.events
```
