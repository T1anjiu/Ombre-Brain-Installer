# Ombre Brain 可靠性与恢复手册

## 安全部署向导

首次登录后打开 `/onboarding`，只选择部署意图：

- 本机：自己的设备或可信内网使用，OAuth 可关闭。
- 公网安全：HTTPS 域名远程使用，OAuth 强制开启。
- 高级：已有反向代理或外部鉴权时自行选择，系统仍持续报告风险。

向导写入现有 `config.yaml`，不会创建第二套配置。OAuth 与传输模式在进程启动时绑定，保存后必须重启。系统体检的“实际生效配置”同时显示已保存值、当前进程值、环境变量来源和持久卷状态；只有环境变量确实改变保存值时才告警。

公网安全模式中的“公网连接地址”是 OAuth 与 MCP 共同使用的外部来源地址。可以粘贴域名、`https://域名` 或完整的 `https://域名/mcp`，系统会保存为规范化的 HTTPS origin，并自动生成 `/mcp` 地址。修改地址后需重启服务，并让 MCP 客户端重新连接/授权；绑定旧地址的授权码或 refresh token 会返回 `invalid_grant`，不会继续签发随后必然 401 的 token。

Docker/Zeabur 的持久卷统一挂载 `/app/buckets`，配置路径为 `/app/buckets/config.yaml`。Zeabur 从 GitHub 部署时只需添加模型 Key、挂载该卷、绑定 HTTPS 域名，再从向导选择“公网安全模式”。不要在平台中长期保留 `OMBRE_MCP_REQUIRE_AUTH` 或 `OMBRE_TRANSPORT`，除非明确希望平台覆盖 Dashboard。

这份文档说明 Ombre Brain 在断网、模型限流、外部编辑和备份恢复时真正保证什么。

## `ombrectl` 一键安装与生命周期

Linux 服务器首选根目录 `install.sh`。它支持 Ubuntu / Debian、Fedora / RHEL /
CentOS / Rocky / AlmaLinux 的 amd64 与 arm64，只使用 Docker Compose v2。远程安装优先
复制下面这一整行：

```bash
curl -fsSL https://raw.githubusercontent.com/T1anjiu/Ombre-Brain-Installer/main/install.sh -o /tmp/ombre-install.sh && bash /tmp/ombre-install.sh
```

只有系统没有 curl 时才改用下面这一行，不要连续执行两种入口：

```bash
wget -qO /tmp/ombre-install.sh https://raw.githubusercontent.com/T1anjiu/Ombre-Brain-Installer/main/install.sh && bash /tmp/ombre-install.sh
```

如果 `curl` 和 `wget` 都不存在，Ubuntu / Debian 先执行
`sudo apt update && sudo apt install -y curl`；Fedora / RHEL / CentOS / Rocky / AlmaLinux
先执行 `sudo dnf install -y curl`，然后重新运行上面的 curl 方式。

安装器默认拉取 `p0luz/ombre-brain:latest`，也可在 Git checkout 中明确选择当前源码，
或让安装器克隆 `main`。Docker 缺失时会再次询问，然后配置 Docker 官方 apt/dnf
仓库并安装 Engine、Buildx 和 Compose 插件；不会调用在线便捷脚本、修改防火墙或把用户
加入 `docker` 组。执行前会汇总发行版、架构、内存、磁盘、网络、端口、sudo、Docker、
绑定地址、vault 和模型配置来源。用 `bash install.sh --dry-run install` 可只打印系统命令。

安装器、用户版 Compose 模板和 `ombrectl` 自更新固定从
`https://raw.githubusercontent.com/T1anjiu/Ombre-Brain-Installer/main` 下载；该地址是安装与运维层的
独立发布源。源码模式的应用代码仍克隆上游
`https://github.com/P0luz/Ombre-Brain.git`，不要把两者的更新来源混在一起。

标准目录和命令：

| 路径 | 内容 |
|---|---|
| `/opt/ombre-brain` | 生命周期脚本和 Compose；自动克隆源码时也放在这里 |
| `/etc/ombre-brain/ombre.env` | 密码与终端托管的 provider 密钥，权限固定为 `0600` |
| `/etc/ombre-brain/install.conf` | 不含密钥的安装状态；按白名单解析，不执行其中内容 |
| `/var/lib/ombre-brain` | `config.yaml`、Markdown、索引及其他永久 vault 数据 |
| `/usr/local/bin/ombrectl` | 全局管理入口 |

```bash
ombrectl status
ombrectl doctor
ombrectl logs                 # 持续跟踪日志，按 Ctrl+C 退出
ombrectl start|stop|restart
ombrectl configure
ombrectl update
ombrectl uninstall
```

所有 Compose 调用都固定使用隔离项目名 `ombre-brain-managed`，并显式传入
`--env-file /etc/ombre-brain/ombre.env`。旧入口 `deploy/deploy.sh` 只是兼容包装器；
新部署和运维应直接使用 `install.sh` / `ombrectl`。

### 访问方式

- 本机 / SSH 模式只绑定 `127.0.0.1`，这是默认选项，**不会直接暴露到公网**。不要尝试用
  `http://服务器公网IP:18001` 访问。在自己的电脑（不是服务器）另开终端执行
  `ssh -L 18001:127.0.0.1:18001 ubuntu@203.0.113.10`：把 `ubuntu` 换成服务器登录用户名，
  把 `203.0.113.10` 换成服务器 IP。保持该 SSH 窗口开启，然后用自己电脑的浏览器打开
  `http://127.0.0.1:18001`。若安装时改了端口，请把命令和浏览器地址中的 `18001` 一并替换。
- 可信局域网模式绑定 `0.0.0.0`。安装器不会开放端口；应由管理员只允许可信网段访问。
- 公网安全模式仍绑定回环地址。先通过 SSH 登录 Dashboard，配置内置 Cloudflare
  Tunnel，再到 `/onboarding` 选择“公网安全”。claude.ai 等云端客户端无法访问本机
  `127.0.0.1`，必须先完成这一步并使用生成的 HTTPS `/mcp` 地址。
- 高级模式只接受明确的 IPv4 绑定和最后一跳代理 CIDR，不安装 Caddy/nginx、不申请证书，
  并拒绝把 `0.0.0.0/0` 或 `::/0` 设为可信代理。

#### 公网安全模式：Cloudflare Tunnel 手把手流程

安装器选择“公网安全”后，服务仍然只监听 `127.0.0.1`。下面的 Tunnel 是唯一把指定域名
安全转发到本机服务的步骤，请按顺序完成：

1. 在自己的电脑浏览器打开 <https://one.dash.cloudflare.com>，登录 Cloudflare；确认准备使用
   的域名已经添加并托管在 Cloudflare。
2. 在自己的电脑（不是服务器）打开终端，执行安装完成摘要中显示的 `ssh -N -L ...` 命令。
   保持这个窗口开启，然后打开 `http://127.0.0.1:18001` 进入服务器 Dashboard。端口被修改时，
   将地址中的 `18001` 换成实际端口。
3. 在 Cloudflare Zero Trust 进入 **Networks → Tunnels → Create a tunnel**，选择
   **Cloudflared**，填写 Tunnel 名称并继续；在 **Install connector** 页面选择 **Docker**，
   复制 `--token` 后面的长 Token（通常以 `eyJ` 开头）。
4. 回到 Ombre Brain Dashboard → **设置 → Cloudflare Tunnel**，粘贴 Token，点击“保存 Token”，
   再点击“启动”。等待状态变成绿色“已连接”；Token 只粘贴到自己的 Dashboard，不要发到聊天或工单。
5. 回到 Cloudflare 刚创建的 Tunnel，打开 **Public Hostnames → Add a public hostname**：
   Domain 填你的域名（例如 `ombre.example.com`）；Service Type 选 **HTTP**；URL 填
   `localhost:8000`。保存后等待约 30 秒，并用浏览器打开该域名确认 Dashboard 可达。
6. 在 Dashboard 地址栏打开 `/onboarding`，选择“公网安全模式”，填写完整 HTTPS 地址，例如
   `https://ombre.example.com`。不能填写公网 IP，也不能填写 `http://`；保存并按页面提示重启。
7. 打开 Dashboard → **⑥ MCP 配置**，复制生成的 `https://你的域名/mcp`，再添加到 claude.ai、
   Claude Code 或其他支持 OAuth 的 MCP 客户端。

排错顺序：先看 Tunnel 是否绿色“已连接”，再确认 Public Hostname 的域名和 `localhost:8000`，
最后确认 `/onboarding` 中保存的是同一个 HTTPS 域名。云端 MCP 客户端不能使用
`http://127.0.0.1:18001/mcp` 或服务器公网 IP 的明文 HTTP 地址。

不要把 `http://服务器公网IP:18001/mcp` 当作默认公网 MCP 地址。默认回环绑定会让该地址无法
从互联网连接；即使把端口开放到公网，MCP 远程 OAuth 也应使用 HTTPS 域名而不是裸 IP 明文 HTTP。
本机或 SSH 转发客户端使用 `http://127.0.0.1:18001/mcp`，可信局域网客户端使用绑定后的局域网 IP，
claude.ai 等云端客户端则必须使用 Cloudflare Tunnel 或其他明确配置的 HTTPS 反向代理地址。

### 配置来源与优先级

推荐让 Dashboard 管理模型配置。此时安装器写入空的 provider 环境值，应用会忽略空值，
不会覆盖 vault 中的 `config.yaml`。终端托管模式把 Gemini、DeepSeek、SiliconFlow、
Anthropic 或自定义接口写入 `ombre.env`；非空环境变量优先级最高，会覆盖 Dashboard 同名值，
之后必须使用 `ombrectl configure` 修改或切回 Dashboard。安装器不部署 Ollama 或 bge-m3。

首次进入 Dashboard 后不能直接“聊天验证”；Dashboard 是配置和管理页面。正确顺序是：

1. 在“③ 引擎”中分别配置**压缩模型**与**向量化模型**，逐项保存并测试成功；
2. 打开“⑥ MCP 配置”，选择客户端并复制生成的配置或 `/mcp` 地址；
3. 在 Claude Desktop、Claude Code 或 claude.ai 中添加连接；
4. 回到 Claude 发送消息，确认 Ombre Brain 的 MCP 工具能够加载和调用。

本机或 SSH 转发适合运行在自己电脑上的 Claude Desktop / Claude Code；claude.ai 连接需要
上文的公网安全模式和 HTTPS 地址。

排查连接层时先不要直接测试 `/mcp`，因为未完成鉴权时返回 `401` 是正常现象。先在服务器执行：

```bash
ombrectl status
curl -i http://127.0.0.1:18001/health
```

再从外部电脑测试：

```bash
curl -i http://服务器公网IP:18001/health
```

外部请求超时通常是回环绑定、防火墙或云安全组问题；`401`/`405` 则说明网络已经连通，接下来
应检查 MCP 客户端是否支持项目要求的 OAuth/Token 流程，以及是否使用了 Dashboard“⑥ MCP 配置”
生成的完整地址。

### 开机自启策略

安装器不注册单独的 `ombre-brain.service`。systemd 负责启用和启动 Docker daemon，
Ombre Brain 容器由 Compose 中的 `restart: unless-stopped` 策略恢复。因此服务器重启后，
Docker 启动时会恢复此前正常运行的容器；执行 `ombrectl stop` 明确停止过容器后，应运行
`ombrectl start` 才会再次启动。可用以下命令核对：

```bash
systemctl is-enabled docker
systemctl is-active docker
ombrectl status
```

### 更新、失败回滚与源码边界

镜像模式更新前同时保存旧镜像 ID 和旧 Compose。新版 Compose 校验、镜像拉取、容器启动或
`/health` 检查失败时，会重新标记旧镜像、恢复旧 Compose 并重建旧容器；vault 不移动。
可用 `ombrectl doctor` 和 `ombrectl logs` 核实恢复结果。

源码模式更新前要求工作树完全干净，并确认当前 `HEAD` 是 `origin/main` 的祖先；否则立即停止，
不会 stash、merge 或 reset。更新前的解析后 Compose 运行快照临时以 `0600` 保存。新构建不健康
时只用旧快照和旧镜像恢复运行容器，Git checkout 保持已经快进后的历史，便于管理员检查：

```bash
git -C /opt/ombre-brain/source status
git -C /opt/ombre-brain/source log --oneline --decorate -10
ombrectl doctor
ombrectl logs
```

### 接管旧部署与旧数据

重复运行不会覆盖已由 `ombrectl` 管理的安装。状态缺失但存在同名容器时，安装器只接受官方
镜像，或带明确 `com.docker.compose.service=ombre-brain` 标签并挂载 `/app/buckets` 的容器；
未知同名容器直接拒绝。接管会显示镜像和真实挂载，再把旧容器停机改名保留；新容器健康后
才移除备份。隔离项目名避免手动部署常见的 `ombre-brain` 标签误命中回滚容器。若固定项目
标签已经是 `ombre-brain-managed`，或发现上次接管留下的备份容器，安装器会
停止并要求人工恢复，避免 Compose 按标签误删回滚点。

仓库内检测到旧 `buckets/` 或 `data/` 时，可以原地采用，或复制到标准目录并保留原目录。
非空目标必须已经像 Ombre Brain vault；复制目标必须为空。安装器不会静默合并两个 vault，
也拒绝使用系统根目录、程序/配置目录及其子目录作为 vault。

### 卸载与恢复

`ombrectl uninstall` 需要输入 `UNINSTALL`。它只执行不带 `-v` 的 Compose `down`，删除受
管理标记保护的程序目录和自身命令；永远不提供删除 vault 的选项。可选择：

1. 保留 `/etc/ombre-brain` 的全部配置，便于原样重装；
2. 删除 `ombre.env` 中的环境密钥，但保留不含密钥的 `install.conf` 恢复状态。

两种选择都会保留 vault，并打印其绝对路径。恢复时重新运行安装器；它会从恢复状态取得原
vault 路径。若状态也由管理员手工移走，在安装问答中输入该目录并确认“采用现有 vault”即可。
不要把恢复操作改成 `docker compose down -v`，也不要删除 vault 内的 `_app`、Markdown 或
`config.yaml`。

无论选择哪种卸载方式，`/var/lib/ombre-brain`（或安装时选择的自定义 vault）都不会被安装器
删除；这里的 Markdown、`config.yaml` 和索引会留在原处。删除 `/etc/ombre-brain/ombre.env`
只会移除 Dashboard 密码及终端托管的模型密钥，不等于删除记忆。重新安装时选择原 vault
路径即可恢复数据；在确认恢复成功之前不要手工清理该目录。

## 数据边界

- `buckets/**/*.md` 是记忆真源。写入成功以 Markdown 原子落盘为准。
- `embeddings.db`、BM25 缓存和脱水缓存都是可重建的派生数据。
- `.embedding_outbox.json` 只保存待索引 ID、内容哈希和重试状态，不复制记忆正文。
- `config.yaml`、`.env`、API Key、OAuth/Tunnel token 不进入本地记忆导出包。

## 写入与恢复保证

1. embedding 不可用、限流或超时时，Markdown 仍先保存，后台 outbox 持久重试。
2. 连续 provider 故障会打开全局熔断，避免每条待办都重复撞击同一个故障端点；冷却后自动恢复，也可在 Dashboard 手动补齐。
3. Obsidian、Git 或手工修改 Markdown 后，BucketManager 会按配置的轮询间隔发现文件集合/mtime/size 变化，刷新内存与 BM25，并只对正文变化重新排队向量。
4. 本地导出对正在使用的 SQLite 调用 backup API，得到事务一致快照；不会直接复制可能处于 WAL 写入中的数据库文件。
5. 新导出包含 `backup_manifest.json`，逐文件记录字节数与 SHA-256。恢复预检要求清单与 ZIP 内容完全一致。

清单只能发现残缺或意外篡改，不能证明备份由谁创建。需要来源认证时，应在可信存储或带签名的发布/备份系统中保管 ZIP。

## 日常检查

Dashboard 的“系统诊断”与命令行使用同一套只读检查：

```bash
python tools/check_buckets.py
python tools/check_buckets.py --json
```

检查项包括：

- Markdown 是否都能以 UTF-8 + frontmatter 解析；
- 是否存在重复 bucket ID 或指向 vault 外的软链接；
- `embeddings.db` 的 `PRAGMA quick_check`；
- 已没有对应 Markdown 的孤儿向量；
- 活跃 Markdown 缺向量时，是否已经进入 outbox。

历史兼容工具：

- `python tools/diagnose_permanent_reads.py` 只读检查旧版 permanent 召回问题，不再导入完整 server runtime。
- `python tools/migrate_feel_domain.py` 默认只读预演；确认旧 feel 元数据后必须显式加 `--apply`。
- `python tools/fix_unpinned_permanent.py` 默认只读。`--force-demote` 只用于人工确认的旧数据；当前显式 permanent 是合法类型，不能批量自动降级。

## 备份与恢复演练

1. 在 Dashboard 导出完整记忆包，确认请求成功且文件非空。
2. 准备一个全新的临时 vault/测试实例，不要直接覆盖唯一的生产目录。
3. 在迁移页面上传 ZIP。新包应显示“备份清单与 SHA-256 校验通过”；旧包会显示“未验证”。
4. 检查 bucket 数、冲突决策和 embedding 模型/维度，再执行导入。
5. 导入完成后运行 `python tools/check_buckets.py`，并用 `breath(query=...)` 抽查可检索性。
6. 确认 outbox 待处理数最终回到 0。模型离线时允许保持 pending，但 Markdown 必须完整可读。

导入冲突的语义：

- `skip`：保留当前记忆，不导入冲突项。
- `keep_both`：导入项获得新 ID；可复用的向量同步映射到新 ID。
- `overwrite`：当前项不会被物理抹去，而是归档并获得唯一的 `*-superseded-*` 历史 ID；导入项接管原 ID。

## 故障处置

| 现象 | 数据状态 | 处理 |
|---|---|---|
| embedding 超时/限流 | Markdown 已保存，向量 pending | 检查网络/额度；等待熔断冷却或手动补齐 |
| 语义检索不可用 | 关键词/BM25 仍可读，返回明确降级提示 | 修复 provider 后等待 outbox 清空 |
| Obsidian 修改后结果旧 | 等待外部变更轮询周期 | 检查 `storage.external_change_poll_seconds`，再看系统诊断的外部变更计数 |
| ZIP 上传被拒绝 | 本地 vault 未写入 | 按错误修复损坏、路径穿越、重复项或清单不一致，重新导出 |
| SQLite quick_check 失败 | Markdown 真源通常仍在 | 先备份 Markdown，移走损坏的派生库，再重建向量；不要删除 Markdown |
| outbox 长时间不下降 | 记忆正文仍安全 | 查看熔断状态、最近错误、Key/模型/维度和 provider 连通性 |
| 编辑记忆、热更新或重启提示 `Cross-origin request rejected` | 写请求被来源防护拒绝，原数据未改动；这不是 CORS 缺失 | 优先手动升级到 2.7.1+；nginx 必须保留公网 authority，传入 `X-Forwarded-Proto: https`，并让应用精确信任最后一跳代理 CIDR。不要添加 CORS 头或改写浏览器 `Origin` |
| Polaris 报 `Failed to fetch`，`/health` 为 200，但 `OPTIONS /mcp` 为 401 且无 CORS 头 | 2.8.1 及更早版本中 CORS 位于 MCP 鉴权内层，静态 Token 模式错误拦截了不携带 Token 的浏览器预检 | 升级到 2.8.2+ 并重建/重启服务；确认预检返回 200，且响应包含 `Access-Control-Allow-Origin`、允许 `POST` 和客户端使用的 Token 请求头 |

### nginx 反代与 v2.7.0 脱困

`Cross-origin request rejected` 是应用的 CSRF 来源校验，不是浏览器 CORS
预检失败。nginx 增加 `Access-Control-Allow-Origin` 不会改变请求的
`Origin`、Host 或协议，因此不能修复这个 403，还可能制造重复 CORS 响应头。

同机 nginx 反代到默认 Docker 端口时可使用：

```nginx
location / {
    proxy_pass http://127.0.0.1:18001;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_buffering off;
    proxy_read_timeout 3600s;
}
```

`$http_host` 会保留非默认公网端口；不要用上游地址覆盖 Host，也不要只发送
RFC 7239 `Forwarded` 而省略上述 `X-Forwarded-*`。如果 nginx 前面还有 CDN，
先正确配置 nginx `real_ip`，再使用清洗后的 `$remote_addr`。

v2.7.1+ 只采信来自 `OMBRE_TRUSTED_PROXY_CIDRS` 的转发头。这里应填写
**直接连接 OB 的最后一跳 nginx/代理地址或网段**，不是浏览器公网 IP、域名或
`0.0.0.0/0`。Docker 中该 peer 常是精确的 `172.x` 网桥网段；修改
`deploy/.env` 后要用 `docker compose ... up -d --force-recreate`，仅重启旧容器
不会注入新增环境变量。

v2.7.0 的热更新和重启按钮本身也是 POST，因此可能一起被旧 CSRF bug 卡住。
先按上面配置并 reload nginx；若仍无法使用 Dashboard，请不要给更新接口关闭
CSRF，直接从宿主机升级：

```bash
# 预构建镜像部署
docker compose -f deploy/docker-compose.user.yml pull
docker compose -f deploy/docker-compose.user.yml up -d --force-recreate

# 源码构建部署则先 git pull，再重建
git pull --ff-only origin main
docker compose -f deploy/docker-compose.yml up -d --build --force-recreate
```

## 访问控制

- Dashboard 会话默认 30 天过期，可通过 `OMBRE_DASHBOARD_SESSION_DAYS` 调整为 1-365 天。认证文件与 token 文件使用原子写入，并在支持的系统上限制为仅文件所有者可读写。
- 登录和 OAuth 授权共用失败限流。`X-Forwarded-For` / `X-Forwarded-Proto` / `X-Forwarded-Host` 只在请求确实来自可信反代时采用；内置 Tunnel 使用回环地址，外置 nginx/Caddy/容器反代应通过 `OMBRE_TRUSTED_PROXY_CIDRS` 添加直接连接 OB 的最后一跳代理 CIDR，不能使用 `0.0.0.0/0`。三个官方 Compose 模板都会把该变量从 `.env` 传入容器。
- 内置 JSON OAuth 状态按单进程部署设计。官方 Docker/Render 启动方式使用单 worker；自行部署时不要启动多个 Web worker 或多个共享同一数据卷的副本，否则授权状态不具备跨进程事务保证。
- `limits.max_management_request_bytes` 限制普通 Dashboard/OAuth 写请求；导入文本和迁移 ZIP 仍使用各自更大的流式上限。
- `/api/update-info` 包含数据目录和容器信息，因此需要 Dashboard 登录；公开健康检查仅使用 `/health` 和 `/api/version`。

## Docker 热更新与代码播种

容器内的记忆真源和运行代码是两类资产。记忆始终以 `buckets/**/*.md` 为准；运行代码由 `entrypoint.sh` 从镜像播种到可写卷上的 `OMBRE_CODE_DIR`，Dashboard 热更新只修改后者。

启动器用两项信息判断镜像是否需要重新播种：

1. 根目录 `VERSION`；
2. 镜像 `src/` 与 `frontend/` 的稳定 SHA-256 代码指纹。

`.seeded_image_fingerprint` 保存“上次播种所用镜像”的指纹，而不是当前运行目录指纹。这个区别是刻意的：Dashboard 热更新会让运行目录不同于镜像，但只要镜像基线没变，重启必须继续保留热更新；本地以相同 `VERSION` 重建了不同代码的镜像时，镜像指纹会变化并触发重新播种。

重新播种先复制到暂存目录并检查 `src/server.py` 与 `frontend/`，完成后才切换活动树。原先健康的运行树会进入 `_prev`；新树连续启动失败达到阈值后自动回滚，回滚结果不会在同一次启动中再次被同一坏镜像覆盖。

常用日志状态：

| 状态 | 含义 |
|---|---|
| `code-state=image-match` | 活动代码与镜像完全一致 |
| `code-state=runtime-override` | 活动代码来自热更新或回滚，镜像未变化，因此保留 |
| `code-state=reseed reason=image-fingerprint-changed` | 版本号相同，但镜像代码内容变化，已重新播种 |
| `code-state=legacy-residue` | 数据目录里发现非活动的历史 `_app`，只提示、不自动删除 |

排障必须先看日志中的“活动代码目录”。默认部署的 `<数据目录>/_app` 可能正在使用，不能仅凭其中的 `VERSION` 新旧决定删除。只有明确出现 `code-state=legacy-residue` 时，该路径才是非活动遗留；建议先备份再手工清理。

紧急情况下可为单次启动设置 `OMBRE_FORCE_CODE_RESEED=1`，强制丢弃卷内运行覆盖并从镜像重新播种。确认启动成功后必须移除该变量，否则每次启动都会重新播种。

`entrypoint.sh` 本身来自镜像，不在 Dashboard 热更新覆盖范围内。升级到带有新播种逻辑的版本时必须先拉取/重建镜像一次，不能只点击 Dashboard 更新。

Dashboard 热更新会限制下载包、成员数、单文件大小、总解压量和压缩率。建立 `_prev` 回滚点失败时不会继续覆盖；逐文件写入采用原子替换。若 `requirements.txt` 有变化且未显式开启 `OMBRE_UPDATE_ALLOW_PIP=1`，热更新会回滚并要求重建镜像，避免“代码更新成功但重启后缺包”。

若希望代码与记忆目录彻底分离，生产环境优先使用命名卷或 bind mount，不要依赖无法稳定重新挂载的临时目录。例如：

```yaml
services:
  ombre-brain:
    environment:
      OMBRE_CODE_DIR: /app/ombre-code/_app
    volumes:
      - ombre-code:/app/ombre-code
      - ./buckets:/app/buckets

volumes:
  ombre-code:
```

命名卷默认可跨 `docker compose down` / `up` 复用；执行 `down -v` 会主动删除它。Dashboard 对独立代码卷的检测来自 `/proc/self/mountinfo`，不会再把它误报成容器 overlay 临时层。

## 配置

```yaml
storage:
  external_change_poll_seconds: 1.0

embedding:
  background_indexing: true
  retry_base_seconds: 5
  retry_max_seconds: 300
  circuit_failure_threshold: 3
  circuit_base_seconds: 30
  circuit_max_seconds: 600
```

轮询设为 `0` 表示每次活跃桶列表读取都检查文件状态。生产环境一般保留 `1.0`，避免高频目录扫描。
