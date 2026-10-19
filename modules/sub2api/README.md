# Sub2API 部署模块

该目录提供独立的 Docker Compose 部署，包含 Sub2API、PostgreSQL 和 Redis。数据库与 Redis 只在 Compose 内部网络可访问，持久数据保存在 Docker named volumes。Sub2API 容器另外加入根目录 Higress 的 `ai-gw` 网络，供 Higress 以 `sub2api:8080` 访问；因此要先启动根目录的 Higress Compose。

## 启动

先在项目根目录启动 Higress，创建共享网络：

```bash
docker compose up -d
```

再在本目录启动 Sub2API：

```bash
cp .env.example .env
chmod 600 .env
# 编辑 .env，至少替换 PostgreSQL 密码、JWT_SECRET、TOTP_ENCRYPTION_KEY
# 三个密钥分别生成：openssl rand -hex 32
docker compose -f compose.yaml up -d
docker compose -f compose.yaml ps
docker compose -f compose.yaml logs --tail=100 sub2api
```

默认管理界面绑定在 `127.0.0.1:8081`，不会与 Higress 的 `8080` 冲突；Higress 容器通过共享网络用 `sub2api:8080` 访问，不需要把服务暴露到外网。若确实要从局域网直接访问，把 `BIND_HOST` 改为 `0.0.0.0`，并自行配置 HTTPS、访问控制与主机防火墙。首次启动若未配置管理员邮箱和密码，登录凭据会自动生成并写入应用日志；日志可能包含密码，应限制访问并及时保存/清理。

停止但保留数据：

```bash
docker compose -f compose.yaml down
```

彻底删除数据（不可恢复）：

```bash
docker compose -f compose.yaml down -v
```

## 请求拦截能力边界

Sub2API 风控中心已有输入侧关键词拦截，可在管理界面配置；本 Compose 只部署服务，不会自动写入规则。它是关键词匹配，不等于语义级 AI 内容审核，短词可能误命中正常文本。官方关于增加 AI 内容审核模块的需求仍是开放讨论，因此不要把现有关键词规则当成完整的内容安全审核。
