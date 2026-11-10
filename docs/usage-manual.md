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

## 2. FAS:默认全自动,启动即用,无需配置

镜像默认开启 `FAS_AUTOCONFIG=1`,容器**第一次启动**时自动完成过去需要手动做的全部三步:

| 过去手动做 | 现在自动做 |
| --- | --- |
| 上 Dashboard 创建 API Key/Secret | 生成专用 Key,经 EMQX `api_key.bootstrap_file` 启动时注册(存于 `data/fas/emqx-api-key`,随 FAS 卷持久化) |
| FAS 配置页填 EMQX 地址 + Key | 自动执行官方 `--configure`:写连接 + 建 `FMO/RAW` 统计 bridge |
| 打开 FAS 初始化管理员 | 自动创建:用户名 `FAS_ADMIN_USERNAME`(默认 `admin`),密码 `FAS_ADMIN_PASSWORD`,不填则随机生成 |

**你要做的只有一件事:拿到初始密码登录。**

```bash
docker logs fmo 2>&1 | grep 'FAS admin created'
# 输出形如: [fmo] FAS admin created: username=admin password=Xx3...(also saved to ...)
# 或者直接读文件:
docker exec fmo cat /opt/fmo-data/fas/admin-password.txt
```

然后打开 `http://1.2.3.4:18080/__fmo/fas` 登录即可。首次启动从拉起到 FAS 完全就绪约需 1 分钟(要等 EMQX 起来完成自动配置),之后每次重启不再重复配置。

想自定义密码:在 `.env` 里设 `FAS_ADMIN_PASSWORD=你的密码`(至少 8 位),首次启动即用它建号。

**验证自动配置成功:**

- 启动日志出现 `FAS autoconfigured:` 且 `[3/3]` 通过
- FAS 登录后 `配置` 页显示已连接、`在线列表`/`主题统计` 有数据
- 若日志出现 `WARNING: FAS autoconfigure failed`,多为 EMQX 未就绪,`docker restart fmo` 再试一次即可(已有数据不会重复初始化)

**想完全手动?** 设 `FAS_AUTOCONFIG=0`,恢复原始三步:① FAS 初始化页建管理员 → ② Dashboard(`系统设置 → API 密钥`)创建 Key/Secret → ③ FAS 配置页填 EMQX 地址 **`http://127.0.0.1:18083`**(同容器内部地址,别填 IP)+ Key/Secret,webhook 填 `http://127.0.0.1:9527/api/ingest`。

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
/opt/fmo-data/fas  FAS 数据库(管理员、审计、黑名单、EMQX 连接) + 初始密码文件 + API Key
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
