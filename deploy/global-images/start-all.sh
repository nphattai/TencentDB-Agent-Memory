#!/usr/bin/env bash
# 一键拉起 memory-core → memory-hub → proxy 三件套，作为一个 docker compose
# 项目 fleet-mem（Docker Desktop 里分组显示，且都带 restart 策略）。
#
# 顺序由 compose.yaml 的 depends_on(service_healthy) 保证：core healthy 后起 hub，
# 两者 healthy 后起 proxy。
#
# 用法：
#   ./start-all.sh            # 本地已有镜像就直接用
#   PULL=1 ./start-all.sh     # 先 docker compose pull 三个镜像，升级到最新 latest
#
# 前置：cp .env.example .env 并把两组 LLM 参数填好（REPLACE_ME → 真值）。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"
# shellcheck source=./lib-config.sh
source "$SCRIPT_DIR/lib-config.sh"

load_env

# 一次性校验全部必填参数，避免拉起 core 之后才发现 proxy 参数缺
require_vars \
  MEMORY_CORE_IMAGE MEMORY_HUB_IMAGE PROXY_IMAGE \
  MEMORY_CORE_PORT PANEL_PORT KNOWLEDGE_PORT PROXY_PORT \
  MEMORY_CORE_VOLUME PANEL_VOLUME \
  MEMORY_LLM_BASE_URL MEMORY_LLM_API_KEY MEMORY_LLM_MODEL \
  KNOWLEDGE_PUBLIC_BASE_URL \
  PROXY_UPSTREAM_URL PROXY_UPSTREAM_API_KEY PROXY_UPSTREAM_MODEL

COMPOSE_PROJECT=fleet-mem
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"
compose() {
  $DOCKER compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" \
    --project-directory "$SCRIPT_DIR" --env-file "$ENV_FILE" "$@"
}

# compose.yaml 把网络和 volume 声明为 external，必须先存在（幂等创建）。
NETWORK=tdai-memory-stack
if ! $DOCKER network inspect "$NETWORK" >/dev/null 2>&1; then
  info "创建 docker 网络 $NETWORK"
  $DOCKER network create "$NETWORK" >/dev/null
fi
for v in "$MEMORY_CORE_VOLUME" "$PANEL_VOLUME"; do
  if ! $DOCKER volume inspect "$v" >/dev/null 2>&1; then
    info "创建 docker volume $v"
    $DOCKER volume create "$v" >/dev/null
  fi
done

# 生成两个挂载进容器的 config 文件（core gateway + proxy）。
# 默认打开 proxy 完整流水线（auth + sessionInit + tdai 注入）；PROXY_FULL_STACK=0 可关。
info "生成 gateway config → $(gen_core_config)"
export PROXY_FULL_STACK="${PROXY_FULL_STACK:-1}"
info "生成 proxy config → $(gen_proxy_config)"

# PULL=1 时先拉最新镜像
if [[ "${PULL:-0}" == "1" ]]; then
  info "docker compose pull（升级到最新 latest）"
  compose pull
fi

info "═══ docker compose up -d（项目 ${COMPOSE_PROJECT}）═══════════════"
compose up -d

# depends_on 保证 core/hub healthy 后才起 proxy；这里再显式等 core healthy，
# 以便下面对 core 做 init-admin（需 host 端 8420 可达）。
wait_healthy tdai-memory-core 90
wait_healthy tdai-memory-hub 120
wait_healthy tdai-proxy 90

# 首次启动初始化 admin user（已初始化则复用 .admin-key）
init_admin_user

ok "═══ 全部服务已就绪（compose 项目 ${COMPOSE_PROJECT}）═══════════"
print_endpoints

# 打印 Claude Code / proxy 使用命令
ADMIN_KEY_FILE="${MEMORY_CORE_ADMIN_KEY_FILE:-$SCRIPT_DIR/.admin-key}"
if [[ -s "$ADMIN_KEY_FILE" ]]; then
  ADMIN_KEY=$(cat "$ADMIN_KEY_FILE")
  UPSTREAM_MODEL="${PROXY_UPSTREAM_MODEL:-<your-model>}"
  echo ""
  echo "  ┌─ 通过 proxy 用 Claude Code ─────────────────────────────────────┐"
  echo "  │  export ANTHROPIC_BASE_URL=http://127.0.0.1:${PROXY_PORT}/claude-code/default"
  echo "  │  export ANTHROPIC_AUTH_TOKEN='${ADMIN_KEY}'"
  echo "  │  claude --model ${UPSTREAM_MODEL}"
  echo "  │"
  echo "  │  admin user_key 保存在: $ADMIN_KEY_FILE"
  echo "  └────────────────────────────────────────────────────────────────┘"
fi
echo ""
echo "  查看日志：  docker compose -p ${COMPOSE_PROJECT} logs -f [tdai-memory-core|tdai-memory-hub|tdai-proxy]"
echo "  停止服务：  ./stop-all.sh"
echo ""
