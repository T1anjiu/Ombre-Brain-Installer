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

安装器不会自动修改防火墙、DNS、反向代理或 HTTPS，也不会执行 `docker compose down -v`。卸载后 `/var/lib/ombre-brain` 始终保留。

## 更新来源

- 镜像模式从 Docker Hub 拉取 `p0luz/ombre-brain:latest`；
- 源码模式从 <https://github.com/P0luz/Ombre-Brain> 的 `main` 分支快进更新；
- 安装器脚本和用户 Compose 模板从本仓库更新。

源码工作树存在未提交修改或发生分叉时，更新会停止，不会自动 `stash` 或 `reset`。

## 文件布局

```text
/opt/ombre-brain       程序和 Compose
/etc/ombre-brain       安装状态与密钥
/var/lib/ombre-brain   永久记忆和配置
/usr/local/bin/ombrectl 全局命令
```

更多接管、升级回滚、故障诊断和数据恢复说明见 [`docs/OPERATIONS.md`](docs/OPERATIONS.md)。

## 许可证

安装器代码以 MIT License 发布，详见 [`LICENSE`](LICENSE)。Ombre Brain 应用本身由作者上游仓库维护，安装器不会重新授权上游源码。
