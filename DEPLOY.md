# 自建 DSH Docker 容器 — 部署到甲骨文云 VPS

没有官方镜像。上游只发 npm 包（`@deepseek-ai/dsh`）和源码，
浏览器端产物打包在 `@deepseek-ai/dsh-web-frontend` 里，
所以「自己做」= `node:24-bookworm-slim` + 这个 npm 包。本目录就是完整的镜像与部署包。

> 重要：这套文件是在没有 Docker 的 Windows 机器上写的，**没有本地构建验证过**。
> 请在 VPS 上按下面的顺序跑一遍；第一步 `docker compose config` 会先暴露语法问题。

---

## 0. 这套东西是什么

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | 镜像定义：node:24-bookworm-slim + `@deepseek-ai/dsh`，无原生模块需重编 |
| `docker-entrypoint.sh` | 解析容器自身 IP 作为绑定地址，拼 `dsh --profile web` 命令行 |
| `healthcheck.sh` | 打容器自身地址的 `/`（前端静态回退位会返回 200） |
| `docker-compose.yml` | 编排：数据卷、端口只绑 127.0.0.1、内存上限 |
| `.env.example` | 可调参数模板，`cp` 成 `.env` 再改 |
| `nginx-dsh.conf` | 反代 + TLS 终止示例（带 WebSocket/Upgrade） |

镜像里 `dsh --profile web --no-open --host <容器IP> --port 3080` 跑在
`WORKDIR /workspace`，所以挂载进去的目录就是默认 workspace 根目录。

---

## 1. VPS 准备（Oracle Cloud，Ubuntu 22.04/24.04 均可）

```bash
# 装 Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER      # 重新登录后免 sudo

# 甲骨文的 Ubuntu 镜像默认带 iptables 规则，会拦截 docker 的 NAT 转发
sudo netfilter-persistent flush   # 或者: sudo iptables -F && sudo netfilter-persistent save
```

甲骨文免费档 ARM（A1.Flex，最高 4 OCPU/24 GB）完全够用；
镜像基于 `node:24-bookworm-slim`，arm64 也能直接构建。

---

## 2. 构建 & 启动

```bash
mkdir -p ~/dsh && cd ~/dsh
git clone https://github.com/ly921002/dsh-docker.git .
cp .env.example .env

docker compose config          # 先做一次语法/变量展开检查
docker compose up -d           # 直接拉 CI 构建好的镜像（推荐）
# 或者本地构建：docker compose build --pull && docker compose up -d
docker compose logs -f dsh     # 启动 URL 只打印一次，含进程凭据
```

> 镜像已在 GHCR 上：`ghcr.io/ly921002/dsh-docker:latest`，amd64 / arm64 双架构都有，
> 用法见 [GHCR.md](GHCR.md)。compose 文件默认就走这条路径，不需要 build。

首次启动会自动在 `./data/.dsh/profiles/web/` 生成 profile。
**把 `docker compose logs` 里那行 `dsh web: http://...` 当密码看待** ——
URL 里带启动令牌。不想让它出现在日志里，设 `DSH_EXTRA_ARGS="--print-url false"`。

---

## 3. 开放端口（两处都要改）

**Oracle 控制台** → 实例 → Virtual Cloud Network → 安全列表 → 入站规则：
`0.0.0.0/0`（或你的 IP）→ TCP `3080`（或你反代用的 443/80）。

**实例内部**：Ubuntu 镜像默认 `iptables -P INPUT DROP`，所以要显式放行：

```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

---

## 4. 两种暴露方式

### A. 只绑 loopback + Nginx 反代（推荐）

`docker-compose.yml` 默认就把 3080 绑在 `127.0.0.1` 上，外部摸不到。
把 `nginx-dsh.conf` 改成你的域名，配好证书（Certbot 或甲骨文免费证书），然后：

```bash
sudo cp nginx-dsh.conf /etc/nginx/sites-available/dsh
sudo ln -s /etc/nginx/sites-available/dsh /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

在 `.env` 里告诉 DSH 浏览器真正访问的根地址，否则 Host 围栏会把每个 API 请求打成 403：

```ini
DSH_PUBLIC_URL=https://dsh.example.com/
DSH_TRUSTED_HOST=dsh.example.com
```

`DSH_PUBLIC_URL` 只影响「打印/打开/运行时上下文里的 URL」，**不授予任何信任**；
真正让围栏放行的是 `--trusted-host`。两个都要设。
反代必须保留浏览器看到的 `Host`（围栏比对的就是它）、剥掉挂载前缀、
转发 `Upgrade`/`Connection`、把 cookie 的 `Path` 改写成挂载前缀。
参考配置里这些都处理了。

### B. 直接对外（不推荐）

```bash
sed -i 's/"127.0.0.1:${DSH_PORT/'"'"'${DSH_PORT/' docker-compose.yml   # 或者直接手改成 "3080:3080"
```

仍然必须设 `DSH_PUBLIC_URL` + `DSH_TRUSTED_HOST`，或者用 DSH 自带的原生 TLS
（`DSH_TLS_CERT`/`DSH_TLS_KEY`，路径相对 `DSH_WORKSPACE` 即 `/workspace`）。
**纯 HTTP 的 0.0.0.0 绑定会把会话令牌和凭据裸奔在公网上** —— 官方文档原话：
「请把端口限制在可信代理或网络内」。

---

## 5. 升级

**关键前提**：能移动的是 npm 包，不是镜像。仓库里钉的版本号只是本地构建的兜底值，
真正的升级由 CI 每天比对 npm 后重建镜像完成，所以你不需要手工改版本号。

### 方案 1：手动拉取（默认推荐）

```bash
cd ~/dsh
./scripts/upgrade.sh          # 备份建议 + pull + recreate + 前后版本对比
```

等价于：

```bash
cp -a data data.bak-$(date +%F)
docker compose pull && docker compose up -d
```

`./scripts/upgrade.sh --check` 只报当前版本、不动任何东西。

### 方案 2：自动跟随（watchtower）

```bash
docker compose --profile auto-update up -d
```

compose 文件里已内置 `auto-update` 服务，只对带
`com.centurylinklabs.watchtower.enable=true` 标签的容器生效（即 `dsh`），
不会碰宿主机上其它容器。默认每 3600 秒检查一次，可在 `.env` 里改：

```ini
AUTO_UPDATE_INTERVAL=3600
```

**代价**：重建容器会终止正在跑的 agent 会话。长会话场景建议用方案 1，挑空闲时手动升。

### 方案 3：本地构建

```bash
cd ~/dsh
git pull
docker compose build --pull          # 用 Dockerfile 里的默认版本
docker compose up -d
```

指定版本：

```bash
DSH_VERSION=0.2.1-rc.5 docker compose build
docker compose up -d
```

### 确认当前跑的是哪个版本

```bash
./scripts/upgrade.sh --check
```

或分别查：

```bash
docker exec dsh-web cat /usr/local/share/dsh/version.txt
docker inspect --format '{{ index .Config.Labels "io.dsh.dsh-version" }}' dsh-web
```

镜像里的 `/usr/local/share/dsh/version.txt` 记录的是 `npm install` 之后
**实际解析到的**版本，不是你在 build arg 里写的那个 ref——所以用 dist-tag 构建时也能查到确切版本。

### 回滚

CI 给每次构建打三类标签：分支名（`main`）、短 commit sha（`sha-aa6d952`）、
`v<version>`（只有打 `v*` tag 才有）。回滚就是改用旧标签：

```bash
# 1. 看有哪些标签可用（不需要 docker login，公开包匿名可读）
node scripts/image-label.mjs --tags ghcr.io/ly921002/dsh-docker

# 2. 在 .env 里指向旧标签
sed -i 's#^DSH_IMAGE=.*#DSH_IMAGE=ghcr.io/ly921002/dsh-docker:sha-aa6d952#' .env

# 3. 重建
docker compose pull && docker compose up -d
```

用 sha 标签最精确（分支名和 `latest` 都会移动）。
数据在 `./data` 卷里，回滚镜像不影响会话与凭据。

---

## 6. 已知边界（都验证过，不是猜的）

- **DSH 拒绝通配绑定**：`--host 0.0.0.0` / `::` 直接启动失败，报错
  `binding every interface would expose remote code execution to the network`。
  所以入口脚本必须自己解析出一个具体地址 —— 容器里就是 `hostname -i` 的第一个 IPv4。
- **运行态树是纯 JS**：`node_modules/@deepseek-ai` 下没有任何 `*.node`，
  所以镜像不需要按平台重编原生模块。
- **Linux 上 PowerShell 工具行默认关闭**：官方 `standard` preset 里
  `tool-pwsh: disabled: !!js process.platform !== 'win32'`，bash 是默认 shell。
  只有自定义 preset 重新启用 `tool-pwsh` 时才需要 `pwsh`，那时用
  `--build-arg INSTALL_PWSH=1`。
- **Office→PDF 在 Linux 走 WASM 引擎**：`libreoffice-kit` 没有发布 linux 原生引擎包，
  会回落到 `libreoffice-kit-wasm`；镜像里装了 DejaVu/Liberation 字体
  （Linux 上无字体自动发现，不装字体会影响 PDF 观感）。
- **会话全文搜索默认关闭**：`session-query-sqlite` 行是 `openAt: never` + `:memory:`，
  属于可选功能，容器里没开，无需额外处理。
- **没有遥测**：`desktop-product-telemetry` / `product-analytics` 行只在
  `profileContext.name === 'desktop'` 时启用，web profile 下是关闭的。
- **版本**：Dockerfile 默认 `0.2.1-rc.5`，与 npm `latest` 一致
  （`next` 同为 rc.5，`alpha` 通道是 `0.2.2-alpha.2`）。这个默认值只是本地构建兜底；
  CI 每天会重新解析 npm 上的 `latest` 并在有变化时重建镜像，所以不需要手工跟版本。
  `/usr/local/share/dsh/version.txt` 里记录的是实际装上的版本。
- **DSH 没有 ACME 客户端，也不会自动续期证书**。长期跑请用反代（方案 A）。
