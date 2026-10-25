# 自建 DSH Docker 容器 — 部署到甲骨文云 VPS

没有官方镜像。上游只发 npm 包（`@deepseek-ai/dsh`）和源码，
浏览器端产物打包在 `@deepseek-ai/dsh-web-frontend` 里，
所以「自己做」= `node:24-slim` + 这个 npm 包。本目录就是完整的镜像与部署包。

> 重要：这套文件是在没有 Docker 的 Windows 机器上写的，**没有本地构建验证过**。
> 请在 VPS 上按下面的顺序跑一遍；第一步 `docker compose config` 会先暴露语法问题。

---

## 0. 这套东西是什么

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | 镜像定义：node:24-slim + `@deepseek-ai/dsh`，无原生模块需重编 |
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
镜像基于 `node:24-slim-bookworm`，arm64 也能直接构建。

---

## 2. 构建 & 启动

```bash
mkdir -p ~/dsh && cd ~/dsh
# 把本目录的 6 个文件上传到这里
cp .env.example .env

docker compose config          # 先做一次语法/变量展开检查
docker compose up -d --build
docker compose logs -f dsh     # 启动 URL 只打印一次，含进程凭据
```

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

```bash
cd ~/dsh
# 改 Dockerfile 的 DSH_VERSION / compose 的 build args，然后：
docker compose build --pull
docker compose up -d
```

session 数据在 `./data` 卷里，重建镜像不丢。
升级前建议 `cp -a data data.bak-$(date +%F)`。

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
- **版本**：当前 `0.2.1-rc.3` 是开发者预览，npm `latest` 还停在 `rc.2`
  （`next` tag 才是 rc.3）。Dockerfile 里显式钉了 rc.3，想跟桌面版一致就保持这个值；
  想稳一点改成 `0.2.1-rc.2`。
- **DSH 没有 ACME 客户端，也不会自动续期证书**。长期跑请用反代（方案 A）。
