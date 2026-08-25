#!/usr/bin/env bash
# 停止并移除 fleet-mem compose 项目的三件套容器。
#
# 用法：
#   ./stop-all.sh              # 停容器，保留 volume（数据保留）
#   ./stop-all.sh --purge      # 停容器 + 删 volume + 删网络 + 删 admin key/config（彻底清理）

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

PURGE=0
if [[ "${1:-}" == "--purge" ]]; then
  PURGE=1
fi

# .env 不存在时也允许运行（用默认卷名兜底）
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi
MEMORY_CORE_VOLUME="${MEMORY_CORE_VOLUME:-tdai-memory-core-data}"
PANEL_VOLUME="${PANEL_VOLUME:-tdai-panel-data}"

COMPOSE_PROJECT=fleet-mem
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"

# 优先用 compose down（干净移除整个项目）；找不到 compose.yaml 时兜底逐个 rm。
if [[ -f "$COMPOSE_FILE" ]]; then
  info "docker compose down（项目 ${COMPOSE_PROJECT}）"
  env_arg=()
  [[ -f "$ENV_FILE" ]] && env_arg=(--env-file "$ENV_FILE")
  $DOCKER compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" \
    --project-directory "$SCRIPT_DIR" ${env_arg[@]+"${env_arg[@]}"} down || true
fi
# 兜底：清掉任何遗留的同名容器（例如旧的 standalone docker run 版本）。
for c in tdai-cliproxy tdai-proxy tdai-memory-hub tdai-memory-core; do
  if $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
    info "移除遗留容器 $c"
    $DOCKER rm -f "$c" >/dev/null
  fi
done

if (( PURGE == 1 )); then
  warn "--purge 已启用：删除 volume + 网络 + admin key 文件"
  for v in "$MEMORY_CORE_VOLUME" "$PANEL_VOLUME"; do
    if $DOCKER volume inspect "$v" >/dev/null 2>&1; then
      $DOCKER volume rm "$v" >/dev/null && ok "已删除 volume $v" || warn "删除 volume $v 失败"
    fi
  done
  if $DOCKER network inspect tdai-memory-stack >/dev/null 2>&1; then
    $DOCKER network rm tdai-memory-stack >/dev/null && ok "已删除网络 tdai-memory-stack" || true
  fi
  # admin key 与 volume 强绑定，purge volume 必须同步清 key，否则下次启动会读到
  # 旧 key 但 volume 是新的，auth 校验会失败。
  ADMIN_KEY_FILE="${MEMORY_CORE_ADMIN_KEY_FILE:-$SCRIPT_DIR/.admin-key}"
  if [[ -f "$ADMIN_KEY_FILE" ]]; then
    rm -f "$ADMIN_KEY_FILE" && ok "已删除 admin key 文件 $ADMIN_KEY_FILE"
  fi
  # 顺带清 proxy / memory-core 生成的 config
  PROXY_CFG_DIR="${PROXY_CONFIG_DIR:-$SCRIPT_DIR/.proxy-config}"
  if [[ -d "$PROXY_CFG_DIR" ]]; then
    rm -rf "$PROXY_CFG_DIR" && ok "已删除 proxy config 目录 $PROXY_CFG_DIR"
  fi
  CORE_CFG_DIR="${MEMORY_CORE_CONFIG_DIR:-$SCRIPT_DIR/.memory-core-config}"
  if [[ -d "$CORE_CFG_DIR" ]]; then
    rm -rf "$CORE_CFG_DIR" && ok "已删除 memory-core config 目录 $CORE_CFG_DIR"
  fi
fi

ok "完成。"
