#!/usr/bin/env bash
# 网关冒烟测试
#
# 用法：
#   GATEWAY=http://127.0.0.1:8080 \
#   GW_KEY=gw-java-xxxx \
#   UPSTREAM_KEY=sk-xxxx \
#   MODEL=your-model-name \
#   BLOCK_WORD=自定义敏感词示例1 \
#   bash scripts/test.sh
#
# 说明：
#   GW_KEY        网关 key（key-auth 里某个 consumer 的 credential）
#   UPSTREAM_KEY  上游需要的 Authorization（CLI Proxy 的 key 或模型厂商的 key），没有可留空
#   MODEL         上游可用的模型名
#   BLOCK_WORD    ai-data-masking 里配置的一个自定义敏感词

set -u

GATEWAY="${GATEWAY:-http://127.0.0.1:8080}"
GW_KEY="${GW_KEY:?请设置 GW_KEY}"
UPSTREAM_KEY="${UPSTREAM_KEY:-}"
MODEL="${MODEL:?请设置 MODEL}"
BLOCK_WORD="${BLOCK_WORD:-自定义敏感词示例1}"
PATH_CHAT="${PATH_CHAT:-/v1/chat/completions}"

pass=0
fail=0

auth_args=()
if [ -n "$UPSTREAM_KEY" ]; then
  auth_args=(-H "Authorization: Bearer ${UPSTREAM_KEY}")
fi

chat_body() {
  # $1 = 用户消息，$2 = 是否流式
  python3 - "$MODEL" "$1" "$2" <<'PY'
import json, sys
model, msg, stream = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
print(json.dumps({"model": model, "stream": stream,
                  "messages": [{"role": "user", "content": msg}]}, ensure_ascii=False))
PY
}

# $1 名称  $2 期望(状态码或 grep 模式)  其余参数传给 curl
check_status() {
  local name="$1" want="$2"; shift 2
  local code
  code=$(curl -s -o /tmp/gw_test_body.$$ -w '%{http_code}' "$@")
  if [ "$code" = "$want" ]; then
    echo "  [通过] $name（HTTP $code）"; pass=$((pass+1))
  else
    echo "  [失败] $name：期望 HTTP $want，实际 $code"
    head -c 400 /tmp/gw_test_body.$$ 2>/dev/null; echo
    fail=$((fail+1))
  fi
}

check_body() {
  local name="$1" pattern="$2"; shift 2
  local body
  body=$(curl -s "$@")
  if printf '%s' "$body" | grep -q -- "$pattern"; then
    echo "  [通过] $name"; pass=$((pass+1))
  else
    echo "  [失败] $name：响应中未找到「$pattern」"
    printf '%s' "$body" | head -c 400; echo
    fail=$((fail+1))
  fi
}

echo "== 1. 认证 =="
check_status "不带网关 key 返回 401" 401 \
  -X POST "${GATEWAY}${PATH_CHAT}" -H 'Content-Type: application/json' \
  -d "$(chat_body '你好' false)"

check_status "错误的网关 key 返回 401" 401 \
  -X POST "${GATEWAY}${PATH_CHAT}" -H 'Content-Type: application/json' \
  -H 'x-gateway-key: wrong-key' -d "$(chat_body '你好' false)"

echo "== 2. 正常请求 =="
check_status "正常提问返回 200" 200 \
  -X POST "${GATEWAY}${PATH_CHAT}" -H 'Content-Type: application/json' \
  -H "x-gateway-key: ${GW_KEY}" ${auth_args[@]+"${auth_args[@]}"} \
  -d "$(chat_body '用一句话介绍你自己' false)"

echo "== 3. 敏感词拦截 =="
check_body "包含自定义敏感词时被拦截" "屏蔽" \
  -X POST "${GATEWAY}${PATH_CHAT}" -H 'Content-Type: application/json' \
  -H "x-gateway-key: ${GW_KEY}" ${auth_args[@]+"${auth_args[@]}"} \
  -d "$(chat_body "请解释一下：${BLOCK_WORD}" false)"

check_body "流式请求中的敏感词同样被拦截" "屏蔽" \
  -N -X POST "${GATEWAY}${PATH_CHAT}" -H 'Content-Type: application/json' \
  -H "x-gateway-key: ${GW_KEY}" ${auth_args[@]+"${auth_args[@]}"} \
  -d "$(chat_body "请解释一下：${BLOCK_WORD}" true)"

echo "== 4. PII 脱敏（人工确认）=="
echo "  发送：我的手机号是 13800138000，请原样复述"
curl -s -X POST "${GATEWAY}${PATH_CHAT}" -H 'Content-Type: application/json' \
  -H "x-gateway-key: ${GW_KEY}" ${auth_args[@]+"${auth_args[@]}"} \
  -d "$(chat_body '我的手机号是 13800138000，请原样复述这个号码' false)" | head -c 600
echo
echo "  ↑ 模型复述的应是 ****，而不是真实号码"

rm -f /tmp/gw_test_body.$$
echo
echo "结果：通过 ${pass}，失败 ${fail}"
[ "$fail" -eq 0 ]
