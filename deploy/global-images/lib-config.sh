#!/usr/bin/env bash
# 共享的「配置生成 + admin 初始化」逻辑，供 start-memory-core.sh / start-proxy.sh
# （standalone docker run 路径）和 start-all.sh（docker compose 路径）复用，避免
# 两处各维护一份 config 模板。不单独执行，通过 `source lib-config.sh` 引入。
#
# 依赖：先 source _lib.sh（提供 info/ok/warn/die/$DOCKER 等），并已 load_env。

# 1→true / 其它→false（供 YAML 开关用）
_fleet_bool() { [[ "$1" == "1" ]] && echo "true" || echo "false"; }

# 生成 sk-mem-<32 chars> 随机 user_key（格式同 metadata/utils/user-key.ts）
_fleet_gen_key() {
  local raw
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)
  else
    raw=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)
  fi
  echo "sk-mem-${raw}"
}

# 校验 user_key（auth/verify 200 即通过）；读全局 MEMORY_CORE_PORT / MEMORY_CORE_GATEWAY_API_KEY
_fleet_verify_key() {
  local key="$1" code
  code=$(/usr/bin/curl -sS -o /dev/null -w "%{http_code}" --max-time 5 \
    -X POST -H "Content-Type: application/json" \
    -H "x-tdai-service-id: default" \
    ${MEMORY_CORE_GATEWAY_API_KEY:+-H "Authorization: Bearer ${MEMORY_CORE_GATEWAY_API_KEY}"} \
    "http://localhost:${MEMORY_CORE_PORT}/v3/meta/auth/verify" \
    -d "$(printf '{"user_key":"%s"}' "$key")" 2>/dev/null || echo "000")
  [[ "$code" == "200" ]]
}

# ── 生成 memory-core gateway config → .memory-core-config/tdai-gateway.yaml ──
# 默认镜像里没 config，从 .env 里的 MEMORY_LLM_* 生成一份 standalone+skill 的最小配置。
# 回显生成路径到 stdout 供调用方拿到文件位置（standalone 脚本会挂载它）。
gen_core_config() {
  local dir="${MEMORY_CORE_CONFIG_DIR:-$SCRIPT_DIR/.memory-core-config}"
  mkdir -p "$dir"
  local file="$dir/tdai-gateway.yaml"
  cat > "$file" <<YAML
# 由 start-*.sh 自动生成 —— 每次启动覆盖，请不要手动改。
deployMode: standalone
stateBackend: local

server:
  port: 8420
  host: 0.0.0.0

data:
  baseDir: /data/tdai-memory

llm:
  baseUrl: "${MEMORY_LLM_BASE_URL:-}"
  apiKey: "${MEMORY_LLM_API_KEY:-}"
  model: "${MEMORY_LLM_MODEL:-}"
  maxTokens: 32000
  timeoutMs: 300000

memory:
  # promptMode: chat（默认，通用聊天/教学场景）| code（代码工程场景，
  # LLM 会重点抽"改了什么/发现什么问题/工具用法"，普通聊天可能抽出 0 条）
  # 通过 .env 里 MEMORY_PROMPT_MODE 覆盖。
  promptMode: ${MEMORY_PROMPT_MODE:-chat}
  capture: { enabled: true }
  extraction:
    enabled: true
    enableDedup: true
    maxMemoriesPerSession: 20
  persona:
    triggerEveryN: 50
    maxScenes: 15
  pipeline:
    everyNConversations: 5
    enableWarmup: true
    l1IdleTimeoutSeconds: 600
    l2DelayAfterL1Seconds: 90
    l2MinIntervalSeconds: 900
    l2MaxIntervalSeconds: 3600
  recall:
    enabled: true
    maxResults: 5
    scoreThreshold: 0.3
    strategy: hybrid
    timeoutMs: 5000
  storeBackend: sqlite
  embedding:
    # lab pilot: local Ollama (OpenAI-compatible) - no cloud key, corpus stays on-machine
    enabled: true
    provider: openai
    baseUrl: http://host.docker.internal:11434/v1
    apiKey: ollama-local
    model: nomic-embed-text
    dimensions: 768  # required >0 or core silently writes ZERO VECTOR (story-04 finding)

# ── Skill 模块 ──
skill:
  enabled: true
  routing:
    mode: bm25
    searchTopK: 20
  extraction:
    enabled: false  # lab-home pilot: auto-Skills extraction OFF (story 02); manual skill entries only
    maxIterations: 16
    queue:
      backend: local
      keyPrefix: tdai
      resultTtlSeconds: 86400
      lockTtlMs: 600000
      maxRetries: 2
      retryBackoffsMs: [5000, 15000]
  resources:
    maxResourceSizeBytes: 5000000
YAML
  echo "$file"
}

# ── 生成 proxy config → .proxy-config/config.yaml ──
# proxy 只从 YAML 读上游 URL / API key（不认环境变量）。三大能力开关同 start-proxy.sh。
# 回显生成路径到 stdout。
gen_proxy_config() {
  if [[ "${PROXY_FULL_STACK:-0}" == "1" ]]; then
    PROXY_ENABLE_AUTH=1
    PROXY_ENABLE_TDAI=1
    PROXY_ENABLE_SESSION_INIT=1
  fi
  PROXY_ENABLE_AUTH="${PROXY_ENABLE_AUTH:-0}"
  PROXY_ENABLE_TDAI="${PROXY_ENABLE_TDAI:-0}"
  PROXY_ENABLE_SESSION_INIT="${PROXY_ENABLE_SESSION_INIT:-0}"
  if [[ "$PROXY_ENABLE_SESSION_INIT" == "1" && "$PROXY_ENABLE_AUTH" != "1" ]]; then
    warn "PROXY_ENABLE_SESSION_INIT=1 需要 auth；自动打开 PROXY_ENABLE_AUTH"
    PROXY_ENABLE_AUTH=1
  fi
  local gw_key="${MEMORY_CORE_GATEWAY_API_KEY:-local}"

  local dir="${PROXY_CONFIG_DIR:-$SCRIPT_DIR/.proxy-config}"
  mkdir -p "$dir"
  local file="$dir/config.yaml"
  cat > "$file" <<YAML
# 由 start-*.sh 自动生成 —— 每次启动覆盖，请不要手动改。
server:
  host: 0.0.0.0
  port: 8096
  forwardTimeoutMs: 600000

upstream:
  url: "${PROXY_UPSTREAM_URL}"
  apiKey: "${PROXY_UPSTREAM_API_KEY}"

log:
  file: ""
  level: info
  backend: console

# tdai 内核对接（用于 injection / skill / auth 拉取）
tdai:
  enabled: $(_fleet_bool $PROXY_ENABLE_TDAI)
  endpoint: "http://memory-core:8420"
  apiKey: "${gw_key}"
  serviceId: default
  memory:
    enabled: true
    inject: true
    writeL0: true
    recallL1: true
    injectL2L3: true

skill:
  endpoint: "http://memory-core:8420"
  serviceToken: "${gw_key}"

auth:
  enabled: $(_fleet_bool $PROXY_ENABLE_AUTH)
  url: "http://memory-core:8420"
  timeoutMs: 5000

sessionInit:
  enabled: $(_fleet_bool $PROXY_ENABLE_SESSION_INIT)
  maxRetries: 3
  injectAgentContext: true
  injectTaskContext: true
  headerAutoSelect:
    enabled: true
    teamHeader: "x-team-id"
    agentHeader: "x-agent-id"
    taskHeader: "x-task-id"
    onMismatch: "form"

costGuard:
  enabled: false

# 打开 skill + knowledge + tdai-memory 三个注入器；
# knowledge 依赖 memory-hub 起来，否则 hook 内部会降级为空块。
injection:
  enabled: true
  injectors:
    - skill
    - knowledge
    - tdai-memory

redis:
  enabled: false
YAML
  echo "$file"
}

# ── 首次启动 memory-core 后初始化 admin user，把 user_key 持久化到 .admin-key ──
# 已初始化（409）时复用已存在的 .admin-key。需要 core 已经 healthy 并监听 MEMORY_CORE_PORT。
init_admin_user() {
  local gw_key="${MEMORY_CORE_GATEWAY_API_KEY-}"
  local admin_user="${MEMORY_CORE_ADMIN_USERNAME:-admin}"
  local key_file="${MEMORY_CORE_ADMIN_KEY_FILE:-$SCRIPT_DIR/.admin-key}"

  info "初始化 admin user（username=${admin_user}, key 持久化 → ${key_file}）..."
  local admin_key
  if [[ -s "$key_file" ]]; then
    admin_key=$(cat "$key_file")
    info "  复用已保存的 admin key（.admin-key 已存在）"
  else
    admin_key=$(_fleet_gen_key)
  fi

  local init_body init_resp
  init_body=$(printf '{"username":"%s","user_key":"%s"}' "$admin_user" "$admin_key")
  init_resp=$(/usr/bin/curl -sS -o /tmp/init-admin.$$ -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    ${gw_key:+-H "Authorization: Bearer ${gw_key}"} \
    -H "x-tdai-service-id: default" \
    "http://localhost:${MEMORY_CORE_PORT}/v3/internal/meta/user/init-admin" \
    -d "$init_body" 2>/dev/null || echo "000")

  case "$init_resp" in
    200)
      ok "admin user 已创建"
      umask 077
      echo -n "$admin_key" > "$key_file"
      ok "  admin user_key 已保存到 $key_file"
      ;;
    409)
      if [[ -s "$key_file" ]]; then
        ok "admin user 已存在（跳过 init-admin，用 $key_file 里的 key）"
      else
        warn "admin user 已存在，但 $key_file 缺失，无法恢复 user_key。"
        warn "选项 A: 清理 volume 重建 —— ./stop-all.sh --purge && ./start-all.sh"
        warn "选项 B: 手动创建新 admin user_key（需要旧 key 或 gateway apiKey）"
      fi
      ;;
    *)
      warn "init-admin 返回 HTTP=${init_resp}，可能需要手动排查："
      cat /tmp/init-admin.$$ 2>/dev/null; echo
      ;;
  esac
  rm -f /tmp/init-admin.$$

  if [[ -s "$key_file" ]]; then
    admin_key=$(cat "$key_file")
    if _fleet_verify_key "$admin_key"; then
      local masked="${admin_key:0:11}****${admin_key: -4}"
      ok "admin user_key 校验通过（auth/verify 200）—— $masked"
      ok "  key file: $key_file"
    else
      warn "admin user_key 校验失败（auth/verify 非 200）。检查 $key_file 与 volume 是否匹配。"
    fi
  fi
}
