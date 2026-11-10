# FMO 单镜像使用手册(部署后必读)

适用镜像:`fmo-emqx-sas`(EMQX 5.8.9 + SAS + FAS + nginx 单容器)。

部署完成后你拥有:

```text
容器外(只有两个端口):
  MQTT   设备连接用,      例如 1.2.3.4:18831
  Web    管理入口,        例如 1.2.3.4:18080

容器内(不用管):
  SAS 127.0.0.1:8080   认证服务,EMQX 自动调用
  FAS 127.0.0.1:9527   审计服务
  EMQX Dashboard 127.0.0.1:18083
  nginx :8081          把 FAS 和 Dashboard 挤在同一个 Web 端口里
```

不需要域名。下面所有地址把 `1.2.3.4` 换成你的服务器 IP、`18080` 换成你的 `WEB_PORT`。

---

## 1. 访问入口:一个 Web 端口,两个后台

FAS 和 EMQX Dashboard 都不支持子路径,所以用 **Cookie 切换**,不是两个网址:

| 地址 | 作用 |
| --- | --- |
| `http://1.2.3.4:18080/__fmo` | 切换页(收藏这个) |
| `http://1.2.3.4:18080/__fmo/fas` | 切到 **FAS** 并跳回首页 |
| `http://1.2.3.4:18080/__fmo/emqx` | 切到 **EMQX Dashboard** 并跳回首页 |

规则:

- 点过切换后,这个浏览器之后所有请求都进对应后台,地址栏始终是 `/`。
- **同一个浏览器同一时间只有一个后台**。要同时开 FAS 和 Dashboard:再开一个无痕窗口,或换一个浏览器,各切各的。
- 切换后页面显示不对劲就强制刷新一次(Ctrl+F5);正常情况下不需要,切换链接自带防缓存参数。
- 从没切换过直接访问 `/`:进 `WEB_DEFAULT` 指定的后台(默认 FAS)。

---

## 2. FAS 首次配置(只需要做一次)

### 第 1 步:初始化 FAS 管理员

1. 打开 `http://1.2.3.4:18080/__fmo/fas`
2. 自动跳到初始化页,设置 FAS 管理员账号密码(这是 FAS 自己的账号,和 EMQX 无关)

### 第 2 步:在 EMQX Dashboard 创建 API Key

1. 打开 `http://1.2.3.4:18080/__fmo/emqx`
2. 登录:用户名 `admin`,密码 = `.env` 里的 `EMQX_DASHBOARD_PASSWORD`
3. 左侧 `系统设置 → API 密钥 → 创建`,得到 **API Key** 和 **Secret**(Secret 只显示一次,先复制)

### 第 3 步:回 FAS 填连接信息

1. 切回 FAS(`http://1.2.3.4:18080/__fmo/fas`),用第 1 步的账号登录
2. 进入 `配置` 页,填:

| 配置项 | 填什么 | 注意 |
| --- | --- | --- |
| EMQX 地址 | `http://127.0.0.1:18083` | **必须填这个**。它们在同一个容器里,填 `1.2.3.4:18080` 或 IP 是错的 |
| API Key / Secret | 第 2 步创建的 | |
| 主题统计 | 默认 `FMO/RAW` | 一般不用改 |
| 身份控制 | 默认开启 | 包头身份≠连接身份自动拉黑,建议保持开 |
| Webhook | `http://127.0.0.1:9527/api/ingest` | 镜像已内置默认,页面若要求填就照抄 |

3. 保存后 FAS 显示连接成功、在线列表开始出数据,配置完成。

> 不想点页面也可以命令行一次配完(容器名按实际改):
> ```bash
> docker exec -e EMQX_URL=http://127.0.0.1:18083 \
>   -e EMQX_API_KEY=<key> -e EMQX_API_SECRET=<secret> \
>   fmo /opt/fmo-fas/fmo-audit-service --configure
> ```

FAS 日常用途:排行榜、主题统计(反查干扰源)、在线列表、黑名单、身份审计、健康监控。

---

## 3. EMQX Dashboard 用来干什么

入口:`http://1.2.3.4:18080/__fmo/emqx`,账号 `admin` + `EMQX_DASHBOARD_PASSWORD`。

日常看:连接数/客户端列表(`监控 → 客户端`)、消息速率、认证是否生效。

**不要做的事:**

- ❌ 不要在 `访问控制 → 认证` 里再新建认证器 —— HTTP 认证已经内置并指向 SAS,重复建会导致认证混乱。
- ❌ 不用改 ACL/授权,沿用默认即可。

改 Dashboard 密码:登录后右上角改,或改 `.env` 的 `EMQX_DASHBOARD_PASSWORD` 后重建容器(已初始化的 EMQX 数据卷里保留旧密码时,以 Dashboard 内修改为准)。

---

## 4. FMO 设备:直接用,不需要改

设备侧和连接一台普通 FMO 服务器**完全一样**,什么都不用配置:

1. 设备从 APRS STATION 广播拿到服务器信息(`url`、`P<port>`、uid、callsign、证书指纹)
2. 直接 MQTT CONNECT 到 `url:port`(也就是你的 `IP:MQTT_PORT`,例如 `1.2.3.4:18831`)
3. username=呼号,password=证书载荷,SAS 在容器内自动完成证书链验证

**唯一要求是"五项一致"** —— 下列各项在设备看到的广播、`.env`、服务器实际暴露的地址之间必须完全相同:

```text
callsign + UID + MQTT地址 + MQTT端口 + 服务器证书指纹
```

对应 `.env`:

```env
SAS_SERVER_CALLSIGN=你的服务器呼号
SAS_SERVER_UID=你的服务器UID
SAS_MQTT_HOST=设备实际连接的公网IP或域名     # 例如 1.2.3.4,不是 127.0.0.1
SAS_MQTT_PORT=设备实际连接的端口            # 必须等于 MQTT_PORT,例如 18831
SAS_CERT_FINGERPRINT=你的服务器证书指纹      # 从 FMO 管理后台复制
```

> ⚠️ 最常见的坑:`SAS_MQTT_PORT` 填了容器内部的 1883。它必须填**设备实际连的对外端口**(即 `MQTT_PORT` 映射出来的那个),差一个数字所有登录都会 `deny`。

**验证设备登录成功:**

```bash
docker logs -f fmo 2>&1 | grep 'HTTP auth'
# 成功: HTTP auth: allowed B0ABC uid=xxxxx role=user
# 失败: HTTP auth: ... deny 原因
```

同时在 EMQX Dashboard 的客户端列表能看到设备,在 FAS 在线列表能看到呼号。

**登录被 deny 的排查顺序:**

1. 五项是否完全一致(Host 大小写不敏感,端口必须是公网端口)
2. 证书是否过期/被吊销(CRL)
3. 服务器和设备时间差是否 > 120 秒(timestamp 防重放)
4. SAS 日志里有具体原因:`server identity mismatch` / `serverFingerprint mismatch` / `role mismatch` / `chain invalid`

---

## 5. `.env` 必改项清单

| 变量 | 必改? | 说明 |
| --- | --- | --- |
| `SAS_SERVER_UID` | ✅ 必填 | FMO 管理后台获取 |
| `SAS_SERVER_CALLSIGN` | ✅ 必填 | 同上 |
| `SAS_CERT_FINGERPRINT` | ✅ 必填 | 同上,43 位 base64url |
| `SAS_MQTT_HOST` | ✅ 必填 | 设备用的公网 IP/域名 |
| `SAS_MQTT_PORT` | ✅ 必填 | = `MQTT_PORT` |
| `MQTT_PORT` / `WEB_PORT` | 按需 | 对外两个端口,别和其他服务冲突 |
| `EMQX_DASHBOARD_PASSWORD` | ✅ 必填 | 长密码 |
| `WEB_DEFAULT` | 可选 | 无 Cookie 访问 `/` 时先进 FAS 还是 EMQX |
| `SAS_CLUSTERS_JSON` | 可选 | 多台 FMO 共用一个 SAS 时才填,见下节 |

首次启动后身份会持久化在 `data/sas/config.json`;之后改 `.env` 里的身份变量并重启会自动更新配置,集群列表不受影响。

---

## 6. 多台 FMO 共用这套 SAS(可选)

这套 SAS 可以同时给多台独立 FMO 服务器做认证(官方叫 cluster)。在 `.env` 里声明式添加:

```env
SAS_CLUSTERS_JSON='[
  {"uid":20001,"callsign":"B0DEF","mqtt_host":"fmo-b.example.com","mqtt_port":40001,"certFingerprint":"..."},
  {"uid":20002,"callsign":"B0XYZ","mqtt_host":"5.6.7.8","mqtt_port":18832,"certFingerprint":"..."}
]'
```

- 每条还是那五项,`mqtt_host/mqtt_port` 必须是该台 FMO 设备实际连接的公网地址
- 那台 FMO 自己的 EMQX 需要把 HTTP 认证指向这套 SAS(内网/VPN,别暴露公网)
- 改完 `docker compose up -d` 生效(每次启动整体替换集群列表)
- 也可以交互式管理:`docker exec -it fmo /opt/fmo-sas/sas --add-cluster --config /opt/fmo-data/sas/config.json` 然后 `docker restart fmo`
- 二者**不要混用**,环境变量会在下次重启覆盖 CLI 写入的列表

---

## 7. 日常运维

```bash
# 看日志(四合一,按 [fmo]/EMQX/FAS/SAS 前缀区分)
docker logs -f fmo

# 只看认证结果
docker logs fmo 2>&1 | grep 'HTTP auth'

# 重启 / 停止
docker restart fmo
docker stop fmo

# 升级(数据不丢)
docker pull ghcr.io/<owner>/<repo>:emqx-5.8.9-sas-<SAS版本>-fas-<FAS版本>
docker compose up -d    # 或按 docker run 的方式用新 tag 重建

# 数据都在这三个卷/目录里,备份就备份它们
/opt/emqx/data     EMQX 数据、规则
/opt/fmo-data/sas  SAS 配置 + Root CA + CRL 缓存
/opt/fmo-data/fas  FAS 数据库(管理员、审计、黑名单)
```

compose 部署时对应 `./data/emqx`、`./data/sas`、`./data/fas`。

---

## 8. 常见问题

**Q: 打开 `/` 是 404 或空白?**
先访问 `http://IP:端口/__fmo` 切换一次;仍不行看 `docker logs fmo` 里 nginx 是否启动。

**Q: FAS 页面 502?**
`FAS_ENABLED` 被设成 0 了,或 FAS 进程崩了,看日志。

**Q: Dashboard 登录不上?**
账号 `admin`,密码是 `EMQX_DASHBOARD_PASSWORD`;密码改过就以改过的为准。

**Q: 设备连上 MQTT 但立刻被踢 / deny?**
见第 4 节排查顺序,90% 是五项里有一样对不上(尤其端口)。

**Q: 想把 Web 端口换成 80?**
`.env` 里 `WEB_PORT=80` 即可,容器内仍是 8081,不用改别的。

**Q: 需要 HTTPS?**
在最外层再套一层 TLS 反代(Caddy/Nginx),指向本 Web 端口;容器内 nginx 保持 HTTP 即可。

**Q: 关掉 FAS 或 nginx?**
`FAS_ENABLED=0` / `WEB_ENABLED=0`。关 nginx 后需要自己把 9527/18083 端口映射出来才能访问后台。
