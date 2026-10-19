# Higress AI 网关：内容审查部署方案

使用 Higress（网关 + 控制台）和 Python 内置静态页面服务。Compose 不启动 Redis；后续如需 Token 限流，可接入现有 Redis。

```
Java / Python 项目 ─┐                         ┌─► CLI Proxy API ─► 上游模型
CLI 客户端 ─────────┼─► Higress :8080 ────────┤
                    │   ① key-auth  识别调用方 └─► 其他大模型 API（可选）
                    │   ② ai-data-masking  敏感词拦截 + PII 脱敏
                    │   ③ ai-statistics    token 统计、审计日志
                    │   ④（可选）ai-token-ratelimit 按调用方限流（Redis）
```

## 目录

```
docker-compose.yml                    仅启动 Higress
.env                                  端口、密码（本地配置，不要提交）
start.sh                              在宿主机启动 Python 检查页面
web/index.html                        检查页面
plugins/
  01-key-auth.global.yaml             全局：三个调用方的网关 key
  02-ai-data-masking.global.yaml      全局：敏感词拦截、PII 脱敏
  03-ai-statistics.global.yaml        全局：token 统计、记录调用方
  04-ai-token-ratelimit.global.yaml   可选：按调用方限流（需要 Redis）
  05-key-auth.route-allow.yaml        路由级：限制路由只给指定调用方用（可选）
scripts/test.sh                       冒烟测试
```

插件文件里的内容就是控制台里要粘贴的 YAML，每个文件开头都写了粘贴位置和注意事项。

---

## 一、启动

```bash
# 生产环境把 HIGRESS_TAG 固定成具体版本号
docker compose up -d
bash start.sh  # 启动检查页面
docker compose ps
```

- 网关：`http://<服务器IP>:8080`
- 检查页面：运行 `bash start.sh` 后访问 `http://localhost:8090`（默认只绑定本机；端口和绑定地址由 `.env` 中的 `WEB_PORT`、`WEB_BIND` 控制）
- 控制台：默认只绑定 `127.0.0.1:8001`。在服务器本机访问，或者在自己电脑上执行
  `ssh -L 8001:127.0.0.1:8001 user@服务器` 后打开 `http://localhost:8001`
- 第一次登录时设置管理员账号和密码

页面通过浏览器直接请求 Higress；网关地址默认使用当前主机的 8080 端口，可在页面中修改。页面与网关端口不同，若浏览器提示跨域错误，需要在 Higress 路由配置允许该页面来源的 CORS 请求。

> 官方说明 All-in-One 模式主要面向本地部署和测试。先用它把方案跑通；
> 正式上线时可换成 Helm（K8s）或官方 standalone 脚本，插件 YAML 可以原样复用。

## 二、在控制台添加服务来源

「服务来源」→「创建服务来源」：

| 名称 | 类型 | 域名 / 地址 | 端口 | 用途 |
|---|---|---|---|---|
| `redis`（按需） | DNS 域名 | 填写 Higress 容器可访问的现有 Redis 地址 | Redis 端口 | 启用限流时添加；插件引用名为 `redis.dns` |
| `cli-proxy` | DNS 域名 | `host.docker.internal` | CLI Proxy 的端口（按实际填写） | CLI Proxy API 跑在宿主机上 |
| `llm-upstream`（可选） | DNS 域名 | 模型厂商域名，如 `api.example.com` | 443 | Java/Python 直连的模型 API |

- CLI Proxy API 如果也跑在 Docker 里，就把它加入 `ai-gw` 网络，地址填它的容器名
- 上游是 HTTPS 的，记得在路由的「后端协议」里选择 HTTPS

## 三、创建路由

「路由配置」→「创建路由」，按路径或域名区分。示例：

| 路由名 | 匹配 | 目标服务 | 给谁用 |
|---|---|---|---|
| `cli-proxy-route` | 路径前缀 `/` （或独立域名，如 `ai.example.com`） | `cli-proxy` | CLI 客户端、也可以给 Java/Python 用 |
| `llm-route`（可选） | 路径前缀 `/llm/`，并在路由里重写去掉前缀 | `llm-upstream` | Java/Python 直连模型时 |

如果 Java/Python 本来就是通过 CLI Proxy API 调模型，那只需要 `cli-proxy-route` 一条路由。

## 四、开启插件

「插件配置」里找到对应插件，打开开关，把 `plugins/` 下对应文件的内容粘进去：

1. **key-auth**：粘贴 `01-key-auth.global.yaml`，先把三个 `credential` 换成随机串
   ```bash
   openssl rand -hex 24
   ```
2. **ai-statistics**：需要统计时粘贴 `03-ai-statistics.global.yaml`；以后启用 Token 限流时也必须先开启它
3. **ai-data-masking**：粘贴 `02-ai-data-masking.global.yaml`，把 `deny_words` 换成你的词
4. **可选：Token 限流**：以后需要时，在控制台把现有 Redis 添加为服务来源（地址必须能从 Higress 容器访问），再启用 `ai-token-ratelimit` 并粘贴 `04-ai-token-ratelimit.global.yaml`；统计依赖 `ai-statistics`。

插件策略在 Higress 控制台配置，Redis 本身使用外部已有实例，不由本项目启动。执行顺序由插件自身的优先级决定，不需要手动排序。

需要按项目区分策略（例如 Java 用 `deny_code: 400`、CLI 用 200）时：在「路由配置」里选中路由 →「策略」，给该路由单独配置一份 ai-data-masking，路由级配置会覆盖全局配置。

想让某条路由只给指定调用方用，在路由的 key-auth 策略里粘贴 `05-key-auth.route-allow.yaml`。

## 五、改造三个调用方

所有请求都要额外带上请求头 `x-gateway-key: <对应的 credential>`。原来的 `Authorization` 保持不变，网关会原样转给上游。

**Python（OpenAI SDK）**
```python
from openai import OpenAI

client = OpenAI(
    base_url="http://<网关地址>:8080/v1",
    api_key="<原来的上游 key>",
    default_headers={"x-gateway-key": "gw-py-xxxx"},
)
```

**Java（Spring AI / OpenAI 兼容客户端）**
把 base-url 改成网关地址，并添加默认请求头。以 Spring `RestClient` 为例：
```java
RestClient client = RestClient.builder()
    .baseUrl("http://<网关地址>:8080")
    .defaultHeader("x-gateway-key", "gw-java-xxxx")
    .defaultHeader("Authorization", "Bearer <原来的上游 key>")
    .build();
```
使用 Spring AI 时，可以通过自定义 `RestClient.Builder` 加上同样的默认请求头。

**CLI 客户端（访问 CLI Proxy API 的工具）**
把客户端配置的 base URL 从 CLI Proxy 地址改成网关地址，并加上 `x-gateway-key` 请求头。
例如 Claude Code 可以通过环境变量添加自定义请求头：
```bash
export ANTHROPIC_BASE_URL=http://<网关地址>:8080
export ANTHROPIC_CUSTOM_HEADERS="x-gateway-key: gw-cli-xxxx"
```

### 无法加自定义请求头怎么办

有些客户端只能设置 API Key。这时可以让网关直接读 `Authorization` 头：

1. key-auth 的 `keys` 改为 `- authorization`
2. 对应 consumer 的 `credential` 写成完整的请求头值，例如 `"Bearer sk-你的CLI-Proxy-key"`

这样网关 key 和 CLI Proxy 的 key 就是同一个，客户端什么都不用改。
注意不要同时配置多个 key 来源，否则请求里同时带了两个时，key-auth 会报 “Multiple API keys found” 并返回 401。

## 六、测试

```bash
GATEWAY=http://127.0.0.1:8080 \
GW_KEY=gw-java-xxxx \
UPSTREAM_KEY=sk-上游key \
MODEL=上游可用的模型名 \
BLOCK_WORD=自定义敏感词示例1 \
bash scripts/test.sh
```

脚本会依次检查：缺少或错误的网关 key 返回 401、正常请求返回 200、非流式和流式请求中的敏感词都被拦截，以及手机号是否被脱敏（这一项需要人工确认）。

## 七、上线建议

1. **先灰度**：ai-data-masking 没有“只记录不拦截”模式。建议先只在一条测试路由上开启它，用真实流量跑几天，看误杀情况再推到全局
2. **内置词库偏严**：技术、医学、历史类内容容易被误杀。如果误杀多，可以先关闭 `system_deny`，只用自己维护的 `deny_words`
3. **流式局限**：敏感词恰好被切在两个 chunk 之间时，可能有一部分已经返回给用户。对此要求严格的话，后续可以用 Go 写自研 Wasm 插件（带跨 chunk 窗口和更强的归一化），放在 ai-data-masking 前面
4. **日志**：开启 03 插件里的问答记录后，日志中会包含用户原文，需要控制访问权限和保留期限
5. **控制台安全**：不要把 8001 端口直接暴露到公网
6. **固定版本**：生产环境把 `HIGRESS_TAG` 固定为具体版本号，升级前先在测试环境验证

## 参考

- 部署：https://higress.ai/en/docs/latest/ops/deploy-by-docker/
- key-auth：https://higress.ai/en/docs/latest/user/plugins/authentication/key-auth/
- ai-data-masking：https://higress.ai/en/docs/latest/user/plugins/ai/api-consumer/ai-data-masking/
- ai-statistics：https://higress.ai/en/docs/latest/user/plugins/ai/api-o11y/ai-statistics/
- ai-token-ratelimit：https://higress.ai/en/docs/latest/user/plugins/ai/api-consumer/ai-token-ratelimit/
