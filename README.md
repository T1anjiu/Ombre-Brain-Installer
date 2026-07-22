# Ombre Brain Installer

面向 Linux 新手的 Ombre Brain 交互式一键安装器。安装完成后使用统一命令 `ombrectl` 管理服务。

## 一键安装

支持 Ubuntu / Debian、Fedora / RHEL / CentOS / Rocky / AlmaLinux，架构为 `amd64` 或 `arm64`。

直接复制下面这一整行执行即可：

```bash
curl -fsSL https://raw.githubusercontent.com/T1anjiu/Ombre-Brain-Installer/main/install.sh | bash
```

安装器随后会交互式检查 Docker、Compose v2、磁盘、内存、端口和网络，并在执行前展示完整摘要。

如果希望先保存脚本再查看或执行，也可以使用：

```bash
curl -fsSL https://raw.githubusercontent.com/T1anjiu/Ombre-Brain-Installer/main/install.sh \
  -o /tmp/ombre-install.sh && bash /tmp/ombre-install.sh
```

### 如果提示 `curl: command not found`

先按发行版安装 `curl` 和 HTTPS 证书包。只需要更新软件索引，不需要先执行整机 `upgrade`：

```bash
# Ubuntu / Debian
sudo apt-get update
sudo apt-get install -y curl ca-certificates
```

```bash
# Fedora / RHEL / CentOS / Rocky / AlmaLinux
sudo dnf install -y curl ca-certificates
```

如果系统没有 `dnf` 但提供 `yum`，使用：

```bash
sudo yum install -y curl ca-certificates
```

安装完成后，重新执行上面的一键安装命令。

默认配置：

- 使用官方预构建镜像；
- 监听 `127.0.0.1:18001`，不会直接暴露公网；
- 模型配置在 Dashboard 中完成；
- 记忆数据永久保存在 `/var/lib/ombre-brain`。

远程访问推荐在自己的电脑上执行 SSH 转发：

```bash
ssh -N -L 18001:127.0.0.1:18001 user@SERVER_PUBLIC_IP
```

安装完成后的提示会尝试自动填入 VPS 公网 IPv4；如果云厂商阻止公网 IP 查询，再把
`SERVER_PUBLIC_IP` 替换成控制台显示的地址。SSH 用户名默认取当前登录用户，也可以提前设置
`OMBRE_SSH_USER` 覆盖。保持 SSH 窗口开启，然后打开 <http://127.0.0.1:18001>。

## MCP 连接方式

默认安装只监听 `127.0.0.1`，因此下面这个地址**不能**直接从公网使用：

```text
http://SERVER_PUBLIC_IP:18001/mcp
```

按 MCP 客户端所在位置选择连接方式：

1. **Claude Desktop / Claude Code 在自己的电脑上运行**：先在自己的电脑执行上面的 SSH 转发，
   然后把 MCP 地址填写为 `http://127.0.0.1:18001/mcp`。
2. **可信局域网客户端**：运行 `ombrectl configure`，选择“可信局域网（0.0.0.0）”，只允许
   可信网段访问防火墙端口，再使用 `http://服务器局域网IP:18001/mcp`。不要把它直接暴露到互联网。
3. **claude.ai 或其他云端 MCP 客户端**：云端服务不能访问你的 `127.0.0.1`，也不建议用公网 IP
   加明文 HTTP。安装时选择“公网自动 HTTPS（Caddy）”，让安装器申请证书；在 `/onboarding`
   选择“公网安全”，最后使用 Dashboard“⑥ MCP 配置”生成的 `https://域名/mcp` 地址。已有
   Cloudflare 账号的用户也可以继续选择 Tunnel。

### 小白公网安全教程（Caddy 自动 HTTPS，推荐）

Caddy 本身免费，不需要注册 Cloudflare、绑定银行卡或购买证书。你只需要一台带公网 IPv4 的 VPS
和一个自己能修改 DNS 的域名。Ombre Brain 仍只监听 `127.0.0.1`，公网只开放标准 HTTPS 入口。

安装前先完成两件事：

1. 在域名服务商添加 **A 记录**，例如把 `brain.example.com` 指向这台 VPS 的公网 IPv4；等待解析生效。
   如果 DNS 恰好托管在 Cloudflare，请先设为灰云 **DNS only**，不要让代理地址替代 VPS 的真实 A 记录。
2. 在云厂商安全组和服务器防火墙中放行入站 **TCP 80 和 443**。应用端口 `18001` 不需要对公网开放。

运行安装器后选择“公网自动 HTTPS（VPS + 自有域名，Caddy，推荐）”，输入域名。安装器会检查 A
记录和本机端口占用，启动独立的 Caddy 容器，并自动申请和续期 HTTPS 证书。成功后：

1. 打开 `https://你的域名` 登录 Dashboard；
2. 打开 `https://你的域名/onboarding`，选择“公网安全模式”，公网地址填写同一个
   `https://你的域名`，保存并按页面提示重启；
3. 到 Dashboard → **⑥ MCP 配置**，复制 `https://你的域名/mcp` 并添加到客户端。

若证书暂时申请失败，Ombre Brain 不会被卸载或停止，仍可通过 SSH 转发访问。先运行
`ombrectl doctor`，再检查 A 记录、TCP 80/443 和 `sudo docker logs --tail 100 ombre-brain-caddy`；
修正后执行 `ombrectl restart` 会自动重试。若 80/443 已由自己的 Nginx/Caddy 占用，请使用
“高级自定义绑定”，安装器不会覆盖现有反向代理。

### 备选公网教程（Cloudflare Tunnel）

如果你已经有可用的 Cloudflare 账号及托管域名，也可以选择 Tunnel。安装器仍只监听
`127.0.0.1`，不会把 Ombre Brain 应用端口直接暴露到公网。

1. **准备 Cloudflare**：在自己的电脑浏览器打开 <https://one.dash.cloudflare.com>，登录或注册
   Cloudflare，并确认要使用的域名已经添加并托管在 Cloudflare。
2. **通过 SSH 打开 Dashboard**：在自己的电脑终端执行安装完成时显示的 SSH 命令（不要在服务器
   终端执行），保持这个 SSH 窗口一直开着；然后在自己的电脑浏览器打开
   `http://127.0.0.1:18001`（如果安装时改了端口，按实际端口替换）。
3. **创建并启动 Tunnel**：在 Cloudflare Zero Trust 中进入 **Networks → Tunnels → Create a
   tunnel**，选择 **Cloudflared**，填写名称并继续；在 **Install connector** 页面选择
   **Docker**，复制 `--token` 后面的长 Token（通常以 `eyJ` 开头）。回到 Dashboard → 设置 →
   **Cloudflare Tunnel**，粘贴 Token，点击“保存 Token”再点击“启动”，等待状态变成绿色“已连接”。
4. **添加 Public Hostname**：回到 Cloudflare 刚创建的 Tunnel，进入 **Public Hostnames → Add a
   public hostname**。Domain 填你的域名（例如 `ombre.example.com`）；Service Type 选 **HTTP**；
   URL 填 `localhost:8000`，保存后等待约 30 秒。
5. **选择公网安全模式**：在 Dashboard 打开 `/onboarding`，选择“公网安全模式”，填写完整 HTTPS
   地址（例如 `https://ombre.example.com`）。不能填写公网 IP，也不能使用 `http://`；保存后按
   页面提示重启服务。
6. **连接 MCP**：打开 Dashboard → **⑥ MCP 配置**，复制生成的
   `https://你的域名/mcp`，添加到 claude.ai、Claude Code 或其他支持 OAuth 的 MCP 客户端。

遇到连接失败时，先确认 Cloudflare Tunnel 状态为绿色“已连接”、Public Hostname 域名能打开
Dashboard，再确认 `/onboarding` 中的 HTTPS 地址与域名完全一致。不要把 Cloudflare Token 发给别人。

首次连接前，先在 Dashboard“③ 引擎”分别配置并测试压缩模型和向量模型，再到“⑥ MCP 配置”复制
客户端配置。若 `/mcp` 返回 `401`，通常表示网络已经连通但客户端还没有完成 OAuth/Token 鉴权；
若公网 `/health` 超时，则先检查绑定地址、防火墙和云厂商安全组。

## 常用命令

```bash
ombrectl status       # 查看状态
ombrectl doctor       # 诊断 Docker、Compose、挂载和健康状态
ombrectl configure    # 修改端口、访问方式、密码和模型配置
ombrectl update       # 更新镜像或源码；健康检查失败时恢复旧容器
ombrectl start        # 启动
ombrectl stop         # 停止
ombrectl restart      # 重启
ombrectl logs         # 查看脱敏日志，按 Ctrl+C 退出
ombrectl uninstall    # 卸载容器和程序，永久保留记忆数据
```

Caddy 模式会创建一个由 `ombrectl` 独占管理的反向代理容器，并自动申请、续期 HTTPS 证书；
安装器不会修改 DNS、云安全组、防火墙或用户已有的 Nginx/Caddy。其他接入模式不会自动配置
反向代理或 HTTPS。安装器不会执行 `docker compose down -v`，卸载后 `/var/lib/ombre-brain`
始终保留。

## 更新来源

- 镜像模式从 Docker Hub 拉取 `p0luz/ombre-brain:latest`；
- 源码模式从 <https://github.com/P0luz/Ombre-Brain> 的 `main` 分支快进更新；
- 安装器脚本和用户 Compose 模板从本仓库更新。

源码工作树存在未提交修改或发生分叉时，更新会停止，不会自动 `stash` 或 `reset`。

## 文件布局

```text
/opt/ombre-brain       程序和 Compose
/etc/ombre-brain       安装状态、密钥与受管理 Caddyfile
/var/lib/ombre-brain   永久记忆和配置
/usr/local/bin/ombrectl 全局命令
```

更多接管、升级回滚、故障诊断和数据恢复说明见 [`docs/OPERATIONS.md`](docs/OPERATIONS.md)。

## 许可证

安装器代码以 MIT License 发布，详见 [`LICENSE`](LICENSE)。Ombre Brain 应用本身由作者上游仓库维护，安装器不会重新授权上游源码。
