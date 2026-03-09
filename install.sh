#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
DEFAULT_CONTAINER_NAME="warp"
DEFAULT_IMAGE="caomingjun/warp:latest"
DEFAULT_PORT="1080"
DEFAULT_USER="admin"
DEFAULT_PASS="admin"
DEFAULT_WARP_SLEEP="10"
DEFAULT_MIRROR_PREFIX=""

# 根据操作系统和用户权限，返回合适的默认数据目录
get_default_data_dir() {
  local container_name="$1"
  local os="$2"
  
  case "$os" in
    linux)
      # Linux: root 用户用 /var/lib/warp-proxy/，普通用户用 ~/.local/share/warp-proxy/
      if [ "$(id -u)" -eq 0 ]; then
        echo "/var/lib/warp-proxy/${container_name}"
      else
        echo "$HOME/.local/share/warp-proxy/${container_name}"
      fi
      ;;
    darwin)
      # macOS: ~/Library/Application Support/warp-proxy/
      mkdir -p "$HOME/Library/Application Support/warp-proxy" 2>/dev/null || true
      echo "$HOME/Library/Application Support/warp-proxy/${container_name}"
      ;;
    windows)
      # Windows: %APPDATA%\warp-proxy\
      if [ -n "${APPDATA:-}" ]; then
        echo "${APPDATA}\\warp-proxy\\${container_name}"
      else
        echo "$HOME/warp-proxy/${container_name}"
      fi
      ;;
    *)
      # 未知系统，回退到脚本目录
      echo "$SCRIPT_DIR/data"
      ;;
  esac
}

say() { printf '%s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*"; }
err() { printf '[error] %s\n' "$*" >&2; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

prompt_default() {
  local prompt="$1"
  local def="$2"
  local val
  read -r -p "$prompt [$def]: " val || true
  if [ -z "${val:-}" ]; then printf '%s' "$def"; else printf '%s' "$val"; fi
}

prompt_yes_no() {
  local prompt="$1"
  local def="$2"
  local val
  read -r -p "$prompt [$def]: " val || true
  val="${val:-$def}"
  case "$val" in
    y|Y|yes|YES) echo y ;;
    *) echo n ;;
  esac
}

need_sudo() {
  if [ "$(id -u)" -ne 0 ]; then echo sudo; else echo; fi
}

SUDO="$(need_sudo)"

OS="unknown"
case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux) OS="linux" ;;
  Darwin) OS="macos" ;;
  *) OS="unknown" ;;
esac

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    say "[info] 已加载本地配置：$CONFIG_FILE"
  fi
}

save_config() {
  local save_password="$1"
  cat > "$CONFIG_FILE" <<EOF
CONTAINER_NAME='${CONTAINER_NAME//\'/\'"\'"\'}'
EXTERNAL_PORT='${EXTERNAL_PORT//\'/\'"\'"\'}'
SOCKS_USER='${SOCKS_USER//\'/\'"\'"\'}'
DATA_DIR='${DATA_DIR//\'/\'"\'"\'}'
WARP_SLEEP='${WARP_SLEEP//\'/\'"\'"\'}'
MIRROR_PREFIX='${MIRROR_PREFIX//\'/\'"\'"\'}'
IMAGE='${IMAGE//\'/\'"\'"\'}'
SAVE_PASSWORD='$save_password'
EOF
  if [ "$save_password" = "y" ]; then
    printf "SOCKS_PASS='%s'\n" "${SOCKS_PASS//\'/\'"\'"\'}" >> "$CONFIG_FILE"
  fi
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  say "[info] 配置已保存：$CONFIG_FILE"
}

install_docker_linux() {
  say '[info] Docker 未检测到，尝试自动安装（Linux）...'
  if command_exists apt-get; then
    $SUDO apt-get update
    $SUDO apt-get install -y docker.io curl
  elif command_exists dnf; then
    $SUDO dnf install -y docker curl
  elif command_exists yum; then
    $SUDO yum install -y docker curl
  elif command_exists zypper; then
    $SUDO zypper install -y docker curl
  elif command_exists pacman; then
    $SUDO pacman -Sy --noconfirm docker curl
  else
    err '无法识别包管理器，请先手动安装 Docker。'
    exit 1
  fi
  if command_exists systemctl; then $SUDO systemctl enable --now docker || true; fi
}

install_docker_macos() {
  say '[info] Docker 未检测到，尝试自动安装（macOS）...'
  if command_exists brew; then
    brew install --cask docker
    warn 'Docker Desktop 已尝试安装。请手动启动 Docker Desktop 后重新运行本脚本。'
    exit 0
  fi
  err '未检测到 Homebrew。请先安装 Docker Desktop。'
  exit 1
}

ensure_docker() {
  if command_exists docker; then return 0; fi
  case "$OS" in
    linux) install_docker_linux ;;
    macos) install_docker_macos ;;
    *) err '当前 install.sh 仅支持 Linux/macOS。Windows 请使用 install.ps1。'; exit 1 ;;
  esac
  command_exists docker || { err 'Docker 安装后仍不可用。'; exit 1; }
}

ensure_docker_running() {
  if ! $SUDO docker info >/dev/null 2>&1; then
    err 'Docker 已安装，但当前 daemon 不可用。请先启动 Docker 再执行。'
    exit 1
  fi
}

pull_image() {
  local image="$1"
  local mirror_prefix="$2"
  local candidates=()
  local candidate
  if [ -n "$mirror_prefix" ]; then candidates+=("${mirror_prefix%/}/$image"); fi
  candidates+=("docker.1ms.run/$image" "docker-cf.registry.cyou/$image" "$image")
  for candidate in "${candidates[@]}"; do
    say "[info] 尝试拉取镜像：$candidate"
    if $SUDO docker pull "$candidate" >/dev/null 2>&1; then
      say "[info] 镜像拉取成功：$candidate"
      echo "$candidate"
      return 0
    fi
    warn "拉取失败：$candidate"
  done
  err '所有候选镜像源都拉取失败。'
  exit 1
}

wait_healthy() {
  local name="$1"
  say '[info] 等待容器健康检查通过...'
  for _ in $(seq 1 36); do
    local status
    status="$($SUDO docker inspect "$name" --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}')"
    say "  - $status"
    if [ "$status" = 'running|healthy' ] || [ "$status" = 'running|nohealth' ]; then return 0; fi
    sleep 5
  done
  err '容器未在预期时间内进入健康状态。'
  $SUDO docker logs --tail 100 "$name" || true
  exit 1
}

proxy_test() {
  local user="$1" pass="$2" port="$3"
  say '[info] 通过代理做出网测试...'
  curl -sS --max-time 30 --proxy "socks5h://$user:$pass@127.0.0.1:$port" https://www.cloudflare.com/cdn-cgi/trace | sed -n '1,20p'
}

main() {
  say '=== WARP 一键安装器（Linux/macOS） ==='
  load_config
  ensure_docker
  ensure_docker_running

  CONTAINER_NAME="$(prompt_default '容器名' "${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}")"
  
  # 检测是否已有同名容器，复用其数据目录
  OLD_DATA_DIR=""
  if $SUDO docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    OLD_DATA_DIR="$($SUDO docker inspect "$CONTAINER_NAME" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/cloudflare-warp"}}{{.Source}}{{end}}{{end}}')"
    if [ -n "$OLD_DATA_DIR" ]; then
      say "[info] 检测到已存在容器，发现原有数据目录：$OLD_DATA_DIR"
    fi
  fi
  
  # 计算默认数据目录（如果 config.env 没有指定）
  if [ -z "${DATA_DIR:-}" ]; then
    DATA_DIR="$(get_default_data_dir "$CONTAINER_NAME" "$OS")"
  fi
  
  # 如果有原有数据目录，优先提示复用
  if [ -n "$OLD_DATA_DIR" ]; then
    DATA_DIR="$(prompt_default '数据目录（复用原有）' "$OLD_DATA_DIR")"
  else
    DATA_DIR="$(prompt_default '数据目录' "$DATA_DIR")"
  fi
  
  # macOS 额外提示
  if [ "$OS" = "macos" ]; then
    say "[info] macOS 建议数据目录放在用户 Library 下，避免权限问题。"
    say "  当前设置：$DATA_DIR"
    read -r -p "是否修改数据目录？[y/N] " change_dir
    if [[ "$change_dir" =~ ^[Yy]$ ]]; then
      read -r -p "请输入新的数据目录路径：" DATA_DIR
    fi
  fi
  
  EXTERNAL_PORT="$(prompt_default '对外端口' "${EXTERNAL_PORT:-$DEFAULT_PORT}")"
  SOCKS_USER="$(prompt_default 'SOCKS5 用户名' "${SOCKS_USER:-$DEFAULT_USER}")"
  SOCKS_PASS="$(prompt_default 'SOCKS5 密码' "${SOCKS_PASS:-$DEFAULT_PASS}")"
  WARP_SLEEP="$(prompt_default 'WARP_SLEEP' "${WARP_SLEEP:-$DEFAULT_WARP_SLEEP}")"
  MIRROR_PREFIX="$(prompt_default '镜像加速前缀（可留空，例如 docker.1ms.run）' "${MIRROR_PREFIX:-$DEFAULT_MIRROR_PREFIX}")"
  SAVE_PASSWORD="$(prompt_yes_no '是否把密码保存到本地配置文件' "${SAVE_PASSWORD:-n}")"

  mkdir -p "$DATA_DIR"
  IMAGE="$(pull_image "$DEFAULT_IMAGE" "$MIRROR_PREFIX")"

  if $SUDO docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    warn "发现已存在容器：$CONTAINER_NAME，准备重建。"
    $SUDO docker rm -f "$CONTAINER_NAME" >/dev/null
  fi

  say "[info] 启动容器：$CONTAINER_NAME"
  $SUDO docker run -d \
    --name "$CONTAINER_NAME" \
    --privileged \
    --cap-add NET_ADMIN \
    --cap-add AUDIT_WRITE \
    --cap-add MKNOD \
    --device-cgroup-rule='c 10:200 rwm' \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --security-opt label=disable \
    --restart always \
    -p "$EXTERNAL_PORT:1080" \
    -e WARP_SLEEP="$WARP_SLEEP" \
    -e "GOST_ARGS=-L socks5://$SOCKS_USER:$SOCKS_PASS@:1080" \
    -v "$DATA_DIR:/var/lib/cloudflare-warp" \
    "$IMAGE" >/dev/null

  wait_healthy "$CONTAINER_NAME"
  proxy_test "$SOCKS_USER" "$SOCKS_PASS" "$EXTERNAL_PORT"
  save_config "$SAVE_PASSWORD"

  say ''
  say '[done] 安装完成'
  say "**协议**：socks5"
  say "**地址**：$(hostname -I 2>/dev/null | awk '{print $1}'):$EXTERNAL_PORT"
  say "**用户名**：$SOCKS_USER"
  say "**密码**：$SOCKS_PASS"
  say "**容器名**：$CONTAINER_NAME"
  say "**数据目录**：$DATA_DIR"
  say "**配置文件**：$CONFIG_FILE"
}

main "$@"
