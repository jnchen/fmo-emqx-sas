# FMO EMQX + SAS + FAS 单镜像

> 📖 **部署完成后怎么用?** 看 [使用手册](docs/usage-manual.md):如何访问 FAS / Dashboard、首次配置、FMO 设备是否需要修改、常见问题。

这个仓库把四件东西打进**一个容器**，对外只开放 **MQTT** 和 **一个 Web 端口**：

- `emqx/emqx:5.8.9` — MQTT Broker
- [FMO Server Authorizer Service (SAS)](https://github.com/BG5ESN/fmo-server-authrozier-service) — HTTP 证书链认证
- [FMO Audit Service (FAS)](https://github.com/bi9bbl/fmo-audit-service) — 审计、在线列表、黑名单、身份控制
- `nginx` — 在同一个 Web 端口上用 Cookie 切换 FAS 和 EMQX Dashboard

```text
设备 ──MQTT :1883──▶ EMQX ──POST /auth──▶ SAS 127.0.0.1:8080
                       │
                       └── Rule Engine ──▶ FAS 127.0.0.1:9527

浏览器 ──Web :8081──▶ nginx ──Cookie: fmoapp=fas  ──▶ FAS 127.0.0.1:9527
                              └─Cookie: fmoapp=emqx ──▶ EMQX Dashboard 127.0.0.1:18083
```

- SAS 只监听容器内 `127.0.0.1:8080`，不对外发布。
- EMQX 的 HTTP 认证器由镜像内置（`EMQX_AUTHENTICATION__1`），**不需要再去 Dashboard 新建认证器**。
- FAS 默认随容器启动；`FAS_ENABLED=0` 可只跑 SAS + EMQX。
- nginx 默认随容器启动；`WEB_ENABLED=0` 可关闭，自己发布 9527/18083。
- SAS 和 FAS 都是 .NET 单文件自包含程序，开启 invariant globalization，不依赖基础镜像里的 ICU。

## 为什么用 Cookie 切换（不需要域名）

EMQX Dashboard 和 FAS 都**不支持部署在 URL 子路径**（如 `/emqx/`、`/fas/`），强行用路径代理会破坏它们的绝对路径 API 和静态资源。

所以 nginx 用**同一个端口 + 一个切换 Cookie**：

| 访问地址 | 作用 |
| --- | --- |
| `http://<服务器IP>:<WEB_PORT>/__fmo` | 切换页，选择 FAS 或 EMQX |
| `http://<服务器IP>:<WEB_PORT>/__fmo/fas` | 切到 FAS（写 `fmoapp=fas` 后跳回 `/`） |
| `http://<服务器IP>:<WEB_PORT>/__fmo/emqx` | 切到 EMQX Dashboard（写 `fmoapp=emqx` 后跳回 `/`） |

切换后，浏览器后续的所有请求（页面、API、静态资源、WebSocket）都会带上 `fmoapp` Cookie，nginx 按它转发到对应应用。两个应用始终以为自己在根路径 `/`，不需要改任何代码。

- 不需要域名、不需要 DNS、不需要改 hosts。
- 第一次访问 `/` 且没有 Cookie 时，进入 `WEB_DEFAULT` 指定的应用（默认 `fas`）。
- 同一个浏览器同一时间只能选中一个应用；要在两个应用间来回切，打开 `/__fmo` 即可（切换后如果页面看起来是旧的，硬刷新一次）。
- 需要同时登录 FAS 和 Dashboard 时，用两个浏览器、两个无痕窗口或两个浏览器配置文件，各自保留自己的 Cookie。
- 两个应用的 Cookie 名称不同，不会互相覆盖。

## 快速开始

### 方式一：一条 `docker run`（不需要 compose）

```bash
docker volume create fmo-emqx
docker volume create fmo-sas
docker volume create fmo-fas

docker run -d --name fmo \
  --restart unless-stopped \
  -p 18831:1883 \
  -p 18080:8081 \
  -e SAS_SERVER_UID=10032 \
  -e SAS_SERVER_CALLSIGN=B0ABC \
  -e SAS_MQTT_HOST=fmo.example.com \
  -e SAS_MQTT_PORT=18831 \
  -e SAS_CERT_FINGERPRINT=replace-with-fmo-certificate-fingerprint \
  -e EMQX_DASHBOARD_PASSWORD=replace-with-a-long-password \
  -e WEB_DEFAULT=fas \
  -v fmo-emqx:/opt/emqx/data \
  -v fmo-sas:/opt/fmo-data/sas \
  -v fmo-fas:/opt/fmo-data/fas \
  ghcr.io/<owner>/<repo>:latest
```

访问：

```text
切换页:         http://<服务器IP>:18080/__fmo
FAS:            http://<服务器IP>:18080/__fmo/fas
EMQX Dashboard: http://<服务器IP>:18080/__fmo/emqx
MQTT:           <服务器IP>:18831
```

### 方式二：compose

```bash
cp .env.example .env
# 编辑 .env，填入 UID、呼号、证书指纹和端口
mkdir -p data/emqx data/sas data/fas
sudo chown -R 1000:1000 data
docker compose -f compose.yml up -d
docker compose -f compose.yml logs -f fmo
```

> `SAS_MQTT_PORT` 必须填**设备从公网访问的端口**（通常等于 `MQTT_PORT`），不是容器内的 1883。
> 每套 FMO 服务器使用独立目录/独立卷，不要共享 `data/sas`。

## 端口与数据

对外只需要两个端口：

| 对外端口 | 容器端口 | 用途 |
| --- | --- | --- |
| `MQTT_PORT`（如 18831） | `1883` | FMO 设备 MQTT |
| `WEB_PORT`（如 18080） | `8081` | nginx：FAS + EMQX Dashboard |

容器内部端口：

| 内部端口 | 用途 |
| --- | --- |
| `8080` | SAS HTTP 认证，仅 EMQX 调用，不发布 |
| `8081` | nginx，宿主机 `WEB_PORT` 映射到它 |
| `9527` | FAS，仅 nginx 调用，不发布 |
| `18083` | EMQX Dashboard，仅 nginx 调用，不发布 |

| 容器路径 | 内容 |
| --- | --- |
| `/opt/emqx/data` | EMQX 数据、配置、规则引擎 |
| `/opt/fmo-data/sas` | `config.json`、`roots/`（Root CA）、`roles/`、`crl/` 缓存 |
| `/opt/fmo-data/fas` | FAS SQLite 数据库（管理员、审计、黑名单、EMQX 连接）、`admin-password.txt`、`emqx-api-key` |

> 三个数据目录都要持久化。删除 `fmo-sas` 卷会导致 SAS 重新初始化；删除 `fmo-fas` 卷会丢失审计与黑名单数据。

## Web 路由变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `WEB_ENABLED` | `1` | `0` 关闭 nginx |
| `WEB_LISTEN_PORT` | `8081` | nginx 在容器内监听的端口；一般不需要改 |
| `WEB_DEFAULT` | `fas` | 第一次访问 `/` 且没有 Cookie 时进入 FAS 还是 EMQX |

- 切换入口固定是 `/__fmo`、`/__fmo/fas`、`/__fmo/emqx`。
- 同一个浏览器共享 `fmoapp` Cookie；要同时用两个应用，请用不同浏览器/无痕窗口。

## 环境变量

### SAS 主身份（首次启动必填）

| 变量 | 说明 |
| --- | --- |
| `SAS_SERVER_UID` | 服务器 UID |
| `SAS_SERVER_CALLSIGN` | 服务器呼号 |
| `SAS_MQTT_HOST` | 设备实际连接的公网域名/IP |
| `SAS_MQTT_PORT` | 设备实际连接的公网端口 |
| `SAS_CERT_FINGERPRINT` | 服务器证书 SHA-256 指纹（base64url） |

首次启动后配置写入 `/opt/fmo-data/sas/config.json`，之后容器重启会沿用该文件；再次提供上述变量会自动更新对应字段。

### 可选 SAS 参数

`SAS_HTTP_ADDR`（默认 `127.0.0.1`）、`SAS_HTTP_PORT`（默认 `8080`）、`SAS_HTTP_TTL`、
`SAS_CRL_REFRESH`、`SAS_ALLOW_ISSUER_SN`、`SAS_ISSUER_SN`、`SAS_LOG_LEVEL`、
`SAS_ROOTS_DIR`（默认 `/opt/fmo-data/sas/roots`，Root CA / roles / CRL 都在这个卷里）。

### EMQX / FAS

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `EMQX_DASHBOARD_USERNAME` | `admin` | Dashboard 账号 |
| `EMQX_DASHBOARD_PASSWORD` | 必填 | Dashboard 密码 |
| `EMQX_AUTHENTICATION__1` | 镜像内置 | 想覆盖认证器时再设置 |
| `FAS_ENABLED` | `1` | `0` 关闭 FAS |
| `FAS_AUTOCONFIG` | `1` | `0` 关闭自动配置（API Key 引导 + 自动 `--configure` + 自动建管理员） |
| `FAS_ADMIN_USERNAME` | `admin` | 自动创建的 FAS 管理员用户名 |
| `FAS_ADMIN_PASSWORD` | 自动生成 | 不填则生成随机密码，打印在日志并写入 `data/fas/admin-password.txt` |
| `EMQX_MONITOR_PORT` | `9527` | FAS 监听端口 |
| `EMQX_MONITOR_DB` | `/opt/fmo-data/fas/fmo-audit-service.db` | FAS 数据库路径 |
| `EMQX_MONITOR_WEBHOOK_URL` | `http://127.0.0.1:9527/api/ingest` | EMQX 规则回传 FAS 的地址 |

## 多 FMO 共用一个 SAS（集群）

这里的“集群”指：**多台独立 FMO/EMQX 服务器共用一个 SAS 实例做认证**，不是 EMQX 自身组集群。

SAS 的 `config.json` 里用 `Mqtt.Clusters` 记录其它 FMO 服务器身份。每条包含：

```json
{
  "uid": 10033,
  "callsign": "B0DEF",
  "mqtt_host": "fmo-b.example.com",
  "mqtt_port": 43911,
  "certFingerprint": "..."
}
```

设备登录时，SAS 要求这五项与某一条主配置或集群条目**完全匹配**：
`targetCallsign + targetUID + targetUrl + targetPort + serverFingerprint`。

### 方式 A：环境变量（声明式，推荐）

```bash
-e SAS_CLUSTERS_JSON='[
  {"uid":10033,"callsign":"B0DEF","mqtt_host":"fmo-b.example.com","mqtt_port":43911,"certFingerprint":"..."},
  {"uid":10034,"callsign":"B0XYZ","mqtt_host":"fmo-c.example.com","mqtt_port":43912,"certFingerprint":"..."}
]'
```

- 每次容器启动都会**整体替换** `Mqtt.Clusters`。
- 留空则完全不覆盖，适合用 CLI 管理。
- `mqtt_host/mqtt_port` 必须是设备可访问的公网地址，不能填容器名。

可选的管理员列表：

```bash
-e SAS_ADMINS_JSON='[{"uid":10032,"certFingerprint":"...","role":"super"}]'
```

> `SAS_ADMINS_JSON` 会整体替换 `Server.Admins`。列表非空时，服务器自身不会自动获得 `super`，除非也列进去。

### 方式 B：交互式 CLI

```bash
docker exec -it fmo /opt/fmo-sas/sas --add-cluster \
  --config /opt/fmo-data/sas/config.json

docker exec -it fmo /opt/fmo-sas/sas --list-clusters \
  --config /opt/fmo-data/sas/config.json

# CLI 改完配置后重启容器，让常驻 SAS 重新加载
docker restart fmo
```

管理员同理：`--add-admin` / `--remove-admin` / `--list-admins`。

> 不要同时使用 `SAS_CLUSTERS_JSON` 和 CLI：环境变量会在下次启动时覆盖 CLI 写入的列表。

### 其它 FMO 的 EMQX 怎么指向这个 SAS

在其它 FMO 服务器的 EMQX 中配置 HTTP 认证：

```text
method  = post
url     = http://<本机地址>:8080/auth
headers = {"Content-Type" = "application/json"}
body    = {"username":"${username}","password":"${password}"}
```

SAS 的 8080 不要暴露到公网；不同主机时请走内网/VPN/反向代理。

## FAS 首次配置：默认全自动，不用动手

容器第一次启动时（`FAS_AUTOCONFIG=1`，默认开）会自动完成原来需要手动做的全部三步：

1. 生成一对专用 EMQX API Key/Secret，通过 EMQX 的 `api_key.bootstrap_file` 在启动时注册（保存在 `data/fas/emqx-api-key`，随 FAS 数据卷持久化）。
2. 等 EMQX 就绪后自动执行 FAS 的 `--configure`：写入连接配置并创建 `FMO/RAW` 主题统计 bridge。只在新库第一次启动时做一次，已有 FAS 数据库不会被改动。
3. FAS 起来后自动创建管理员：
   - 用户名 = `FAS_ADMIN_USERNAME`（默认 `admin`）
   - 密码 = `FAS_ADMIN_PASSWORD`；不填则**自动生成**，打印在启动日志里并保存到 `data/fas/admin-password.txt`

启动后直接打开 `http://<服务器IP>:<WEB_PORT>/__fmo/fas` 用上面的账号登录即可。看初始密码：

```bash
docker logs fmo 2>&1 | grep 'FAS admin created'
# 或
docker exec fmo cat /opt/fmo-data/fas/admin-password.txt
```

想自己指定密码就在 `.env` 里设 `FAS_ADMIN_PASSWORD`（至少 8 位）。想完全手动（自己上 Dashboard 建 API Key、自己跑初始化向导）就设 `FAS_AUTOCONFIG=0`，手动流程见 [使用手册](docs/usage-manual.md)。

## 自动升级（SAS + FAS 任一更新都会重建）

GitHub Actions 每 6 小时同时检查两个上游：

- SAS：[BG5ESN/fmo-server-authrozier-service releases](https://github.com/BG5ESN/fmo-server-authrozier-service/releases)
- FAS：`https://bg5esn.com/share/fmo/fas.json`

只要其中**任意一个版本变化**，不可变标签就会变化，定时任务不会跳过，重新构建并推送 amd64/arm64 镜像：

```text
ghcr.io/<owner>/<repo>:latest
ghcr.io/<owner>/<repo>:emqx-5.8.9-sas-<SAS版本>-fas-<FAS版本>
```

例如：

```text
emqx-5.8.9-sas-1.0.6-fas-2.0.22
```

- SAS 更新 → 标签里的 `sas-*` 变化 → 重建。
- FAS 更新 → 标签里的 `fas-*` 变化 → 重建。
- 两者都没变 → 标签已存在 → 跳过。
- `latest` 始终跟随最新构建。

工作流支持手动指定 `sas_version` 和 `force`。每次推送 `main` 分支也会构建。

> 这里说的是**镜像自动构建**。服务器端要自动应用新镜像，可以加一条 cron：
> `docker compose pull && docker compose up -d`，或使用 Watchtower；本仓库不自带容器内自更新。

把仓库推到 GitHub 后，在 `Settings -> Actions -> General` 确认允许 Actions 写入 packages。
GHCR 包第一次发布后，按需设为 public，或在部署机 `docker login ghcr.io`。

### 同步到 Docker Hub

在仓库 `Settings -> Secrets and variables -> Actions` 添加：

| 类型 | 名称 | 示例或内容 |
| --- | --- | --- |
| Variable | `DOCKERHUB_REPOSITORY` | `your-name/fmo-emqx-sas` |
| Secret | `DOCKERHUB_USERNAME` | Docker Hub 用户名 |
| Secret | `DOCKERHUB_TOKEN` | Read/Write Access Token |

设置后，同一次构建会同步发布：

```text
your-name/fmo-emqx-sas:latest
your-name/fmo-emqx-sas:emqx-5.8.9-sas-1.0.6-fas-2.0.22
```

## 升级

```bash
docker pull ghcr.io/<owner>/<repo>:emqx-5.8.9-sas-1.0.6-fas-2.0.22
# 修改 compose/.env 或 docker run 的镜像标签后重建
docker compose -f compose.yml up -d
```

建议先用带版本号的标签灰度，确认 SAS 日志出现 `HTTP auth: allowed ...`、FAS 页面正常后再切 `latest`。
升级不会删除 `fmo-sas` / `fmo-fas` / EMQX 数据卷。

## 本地构建

```bash
docker buildx build --platform linux/amd64 \
  --build-arg SAS_VERSION=v1.0.6 \
  --build-arg SAS_URL_AMD64=https://github.com/BG5ESN/fmo-server-authrozier-service/releases/download/v1.0.6/linux-x64.tar.gz \
  --build-arg FAS_VERSION=2.0.22 \
  --build-arg FAS_URL_AMD64=https://bg5esn.com/share/fmo/fas/v2.0.22/fmo-audit-service-linux-x64.tar.gz \
  -t fmo/emqx-sas-fas:local .
```

Dockerfile 已内置 FAS v2.0.22 和静态 `jq` 1.7.1 的 SHA-256；手工覆盖 `FAS_URL_*` / `JQ_URL_*` 时请同时传入对应的 `*_SHA256_*`。

最终镜像会通过 apt 安装 `nginx-light`，构建时需要能访问 Debian 软件源。国内网络可覆盖基础镜像：

```bash
docker build \
  --build-arg EMQX_IMAGE=docker.m.daocloud.io/emqx/emqx:5.8.9 \
  --build-arg SAS_BUILDER_IMAGE=docker.m.daocloud.io/library/debian:bookworm-slim \
  -t fmo/emqx-sas-fas:local .
```

## 迁移注意事项

- 不要使用 `--network host` 部署多套实例；用 bridge 网络和不同宿主机端口。
- 迁移前备份原 EMQX 数据，尤其是 `data/configs/cluster.hocon`。
- 保留原有 `acl.conf` 和 authorization 配置；本镜像只替换认证链路。
- SAS/FAS 版本由镜像标签固定，升级通过重新构建/拉取完成，不依赖容器内 OTA。
- FAS 容器内检测到 Docker 后会提示使用镜像升级，不要在容器里执行 `--update` 替换自身。
- 统一 Web 端口同时暴露 FAS 管理面和 EMQX Dashboard，请用防火墙限制来源；需要 HTTPS 时在最外层再加 TLS 终止。
