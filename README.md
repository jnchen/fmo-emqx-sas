# FMO EMQX + SAS 镜像

这个仓库把 `emqx/emqx:5.8.9` 和 FMO SAS 认证器打进一个容器。
SAS 在容器内监听 `127.0.0.1:8080`，宿主机只需要映射 MQTT 和 Dashboard 两个端口。
镜像为 SAS 启用了 .NET invariant globalization，避免精简版 EMQX 基础镜像缺少 ICU 时无法启动；FMO 使用的呼号、JSON 字段和证书数据不依赖区域化规则。

## 自动升级

GitHub Actions 每 6 小时查询 [ESN SAS Releases](https://github.com/BG5ESN/fmo-server-authrozier-service/releases)。
发现新版本后会校验 Release 资产的 SHA-256，再自动构建并推送到当前仓库的 GHCR：

```text
ghcr.io/<owner>/<repo>:latest
ghcr.io/<owner>/<repo>:emqx-5.8.9-sas-1.0.6
```

版本标签不会被覆盖，方便回滚。工作流也支持手动指定 `sas_version`。

把仓库推到 GitHub 后，在仓库的 `Settings -> Actions -> General` 确认允许 Actions 写入 packages。
GHCR 包第一次发布后，按需将包设为 public，或在部署机执行 `docker login ghcr.io`。

## 部署

```bash
cp .env.example .env
# 编辑 .env，填入这一套服务器的 UID、呼号、证书指纹和端口
mkdir -p data/emqx data/sas
sudo chown -R 1000:1000 data
docker compose -f compose.yml up -d
docker compose -f compose.yml logs -f fmo
```

每套 FMO 服务器使用独立目录、独立 `data/emqx` 和 `data/sas`，不要共享 SAS 配置。
`SAS_MQTT_PORT` 填设备从公网访问的端口，而不是容器内部的 1883。

只开放 MQTT 和 Dashboard 端口，不要发布 SAS 的 8080 端口。

## 本地构建

工作流使用 GitHub Release 资产。手工构建时可覆盖 SAS 版本和下载地址：

```bash
docker buildx build --platform linux/amd64 \
  --build-arg SAS_VERSION=v1.0.6 \
  --build-arg SAS_URL_AMD64=https://github.com/BG5ESN/fmo-server-authrozier-service/releases/download/v1.0.6/linux-x64.tar.gz \
  -t fmo/emqx-sas:local .
```

镜像升级时优先使用带版本号的标签灰度验证，确认 SAS 日志出现 `HTTP auth: allowed ...` 后再切换 `latest`。

如果构建环境无法访问 Docker Hub，可将工作流中的 `EMQX_IMAGE` 改为可用镜像，例如
`hub.1panel.dev/emqx/emqx:5.8.9`。本地构建还可以同时覆盖下载器基础镜像：

```bash
docker build \
  --build-arg EMQX_IMAGE=docker.m.daocloud.io/emqx/emqx:5.8.9 \
  --build-arg SAS_BUILDER_IMAGE=docker.m.daocloud.io/library/debian:bookworm-slim \
  -t fmo/emqx-sas:local .
```

## 迁移注意事项

- 不要使用 `--network host` 部署多套 EMQX；使用 bridge 网络和不同宿主机端口。
- 迁移前备份原 EMQX 数据和配置，尤其是 `data/configs/cluster.hocon`。
- 保留原有 `acl.conf` 和 authorization 配置；本仓库只替换认证链路。
- SAS 版本由镜像标签固定，升级通过重新构建完成，不依赖容器内 OTA。
