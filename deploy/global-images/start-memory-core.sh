#!/usr/bin/env bash
# 单独拉起 memory-core（内核 gateway，端口 8420），首次启动自动 init-admin +
# 把生成的 user_key 持久化到 .admin-key 供 proxy / claude-code 使用。
#
# 用法：
#   ./start-memory-core.sh
#
# 数据持久化到 named volume（默认 tdai-memory-core-data，可在 .env 改 MEMORY_CORE_VOLUME）。
# 重复执行会先移除旧容器再启新的，volume 数据保留 —— admin user_key 也随之保留。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"
# shellcheck source=./lib-config.sh
source "$SCRIPT_DIR/lib-config.sh"

load_env
require_vars MEMORY_CORE_IMAGE MEMORY_CORE_PORT MEMORY_CORE_VOLUME

# ── Gateway 内部管理凭据 ─────────────────────────────────────────
# 用 ${VAR-default}（不是 :-default）：允许 .env 里显式设为空字符串来关闭 Bearer gate。
#
# 当前 memory-core 的 Bearer gate 与 proxy auth 存在**已知不兼容**：proxy 调
# /v3/meta/auth/verify 时不带 Bearer（源码遗漏，见 MemoryProxy/src/auth.ts），
# 所以 proxy 启用 auth 时必须把 MEMORY_CORE_GATEWAY_API_KEY 留空。默认已置空。
MEMORY_CORE_GATEWAY_API_KEY="${MEMORY_CORE_GATEWAY_API_KEY-}"
MEMORY_CORE_ADMIN_USERNAME="${MEMORY_CORE_ADMIN_USERNAME:-admin}"

# admin user_key 持久化位置（宿主机侧；volume 数据被清后需一并删掉此文件）
ADMIN_KEY_FILE="${MEMORY_CORE_ADMIN_KEY_FILE:-$SCRIPT_DIR/.admin-key}"

if [[ -n "$MEMORY_CORE_GATEWAY_API_KEY" ]]; then
  warn "MEMORY_CORE_GATEWAY_API_KEY 非空 —— proxy 的 sessionInit/auth 目前会因缺 Bearer 而失败。"
  warn "本地体验请把 .env 里的 MEMORY_CORE_GATEWAY_API_KEY 留空。"
fi

CONTAINER=tdai-memory-core
NETWORK=tdai-memory-stack

# 创建共享网络（幂等）
if ! $DOCKER network inspect "$NETWORK" >/dev/null 2>&1; then
  info "创建 docker 网络 $NETWORK"
  $DOCKER network create "$NETWORK" >/dev/null
fi

pull_image "$MEMORY_CORE_IMAGE"
rm_container_if_exists "$CONTAINER"

# ── 生成 gateway config.yaml，挂到容器 /data/config/tdai-gateway.yaml ──
# 默认镜像里没 config，memory-core 走编译时的默认（skill / knowledge 模块关闭）。
# 模板已抽到 lib-config.sh:gen_core_config（与 compose 路径共用）。
info "生成 gateway config"
CORE_CONFIG_FILE=$(gen_core_config)
info "  → $CORE_CONFIG_FILE"

info "启动 memory-core (image=$MEMORY_CORE_IMAGE, port=$MEMORY_CORE_PORT)"
$DOCKER run -d --name "$CONTAINER" --restart unless-stopped \
  --network "$NETWORK" \
  --network-alias memory-core \
  -p "127.0.0.1:${MEMORY_CORE_PORT}:8420" \
  -v "${MEMORY_CORE_VOLUME}:/data/tdai-memory" \
  -v "$CORE_CONFIG_FILE:/data/config/tdai-gateway.yaml:ro" \
  -e TDAI_GATEWAY_PORT=8420 \
  -e TDAI_GATEWAY_HOST=0.0.0.0 \
  -e TDAI_GATEWAY_API_KEY="$MEMORY_CORE_GATEWAY_API_KEY" \
  -e TDAI_DATA_DIR=/data/tdai-memory \
  "$MEMORY_CORE_IMAGE" >/dev/null

wait_healthy "$CONTAINER" 90
ok "memory-core 已启动 → http://localhost:${MEMORY_CORE_PORT}/"

# ── Admin user 生命周期 ─────────────────────────────────────────
# 首次启动 init-admin + 落盘 .admin-key；重启（409）复用已存在的 key。
# 逻辑抽到 lib-config.sh:init_admin_user（与 compose 路径共用）。
init_admin_user
