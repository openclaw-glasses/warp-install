#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

prompt_yes_no() {
  local prompt="$1" def="$2" val
  read -r -p "$prompt [$def]: " val || true
  val="${val:-$def}"
  case "$val" in y|Y|yes|YES) echo y ;; *) echo n ;; esac
}
need_sudo() { if [ "$(id -u)" -ne 0 ]; then echo sudo; fi; }
SUDO="$(need_sudo)"

CONTAINER_NAME="warp"
DATA_DIR="$SCRIPT_DIR/data"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

REMOVE_DATA="$(prompt_yes_no '是否删除数据目录（会丢失 WARP 注册状态）' 'n')"

if $SUDO docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  $SUDO docker rm -f "$CONTAINER_NAME" >/dev/null
  echo "[done] 已删除容器：$CONTAINER_NAME"
else
  echo "[info] 未发现容器：$CONTAINER_NAME"
fi

if [ "$REMOVE_DATA" = "y" ] && [ -d "$DATA_DIR" ]; then
  rm -rf "$DATA_DIR"
  echo "[done] 已删除数据目录：$DATA_DIR"
fi
