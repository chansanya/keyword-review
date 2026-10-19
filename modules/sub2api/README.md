# Sub2API 部署模块

该目录提供独立的 Docker Compose 部署。Sub2API 使用 PostgreSQL 和 Redis；本配置启动 PostgreSQL，Redis 连接现有 WSL 实例，不另起 Redis 容器。所有连接参数都从本目录 `.env` 读取。Sub2API 需要 PostgreSQL，不能把现有 MySQL 当作 PostgreSQL 使用；当前 Compose 会启动一个 PostgreSQL 容器。Sub2API 容器还加入根目录 Higress 的 `ai-gw` 网络，供 Higress 以 `sub2api:8080` 访问，因此要先启动根目录的 Higress Compose。

## 启动

先在项目根目录启动 Higress，创建共享网络：

```bash
docker compose up -d
```

再在本目录启动 Sub2API：

```bash
cp .env.example .env
chmod 600 .env
# 编辑 .env：设置 DATABASE_PASSWORD、现有 WSL Redis 连接信息、JWT_SECRET、TOTP_ENCRYPTION_KEY
# 密钥分别生成：openssl rand -hex 32
docker compose -f compose.yaml up -d
docker compose -f compose.yaml ps
docker compose -f compose.yaml logs --tail=100 sub2api
```

管理界面默认绑定 `127.0.0.1:8081`，不会与 Higress 的 `8080` 冲突；Higress 通过共享 Docker 网络访问 `sub2api:8080`。Redis 默认用 `host.docker.internal:6379`，需确保 WSL 中的 Redis 允许 Docker 主机访问，并在 `.env` 填入现有 Redis 密码。若确实要从局域网直接访问 Sub2API，把 `BIND_HOST` 改为 `0.0.0.0`，并自行配置 HTTPS、访问控制与主机防火墙。首次启动若未配置管理员邮箱和密码，登录凭据会自动生成并写入应用日志；日志可能包含密码，应限制访问并及时保存/清理。

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
