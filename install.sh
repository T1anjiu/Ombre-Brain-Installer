#!/usr/bin/env bash
# Ombre Brain interactive installer and lifecycle manager.
# Linux only. Runtime data is deliberately kept outside the application tree.

set -Eeuo pipefail
IFS=$'\n\t'

INSTALLER_VERSION="1.1.0"
STATE_VERSION="1"
PROJECT_NAME="ombre-brain-managed"
CONTAINER_NAME="ombre-brain"
IMAGE_NAME="p0luz/ombre-brain:latest"
REPO_URL="https://github.com/P0luz/Ombre-Brain.git"
RAW_BASE_URL="https://raw.githubusercontent.com/T1anjiu/Ombre-Brain-Installer/main"

DEFAULT_APP_DIR="/opt/ombre-brain"
DEFAULT_CONFIG_DIR="/etc/ombre-brain"
DEFAULT_DATA_DIR="/var/lib/ombre-brain"
DEFAULT_BIN_LINK="/usr/local/bin/ombrectl"

APP_DIR="${OMBRE_INSTALLER_APP_DIR:-$DEFAULT_APP_DIR}"
CONFIG_DIR="${OMBRE_INSTALLER_CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
DATA_DIR="${OMBRE_INSTALLER_DATA_DIR:-$DEFAULT_DATA_DIR}"
BIN_LINK="${OMBRE_INSTALLER_BIN_LINK:-$DEFAULT_BIN_LINK}"
ENV_FILE="$CONFIG_DIR/ombre.env"
STATE_FILE="$CONFIG_DIR/install.conf"
COMPOSE_FILE=""
SOURCE_DIR=""
MODE="image"
PORT="18001"
BIND_ADDRESS="127.0.0.1"
ACCESS_MODE="local"
TRUSTED_PROXY_CIDRS="127.0.0.0/8,::1/128"
MODEL_MANAGEMENT="dashboard"
INSTALLED="0"
STATE_LOADED=0

DRY_RUN=0
PROMPT_FD=0
PROMPT_OUT_FD=2
PROMPT_READY=0
LOCK_DIR=""
TEMP_PATHS=()
DOCKER=()
REPO_ROOT=""
SOURCE_CHOICE="clone"
LEGACY_COPY_SOURCE=""
ADOPT_CONTAINER=0
ADOPT_BACKUP_NAME="ombre-brain-installer-backup"
ADOPT_WAS_RUNNING="false"
ADOPTION_ACTIVE=0
ADOPTION_BACKUP_READY=0
GENERATED_PASSWORD=0

DASHBOARD_PASSWORD=""
COMPRESS_API_KEY=""
COMPRESS_BASE_URL=""
COMPRESS_MODEL=""
COMPRESS_FORMAT=""
COMPRESS_TIMEOUT="120"
EMBED_API_KEY=""
EMBED_BASE_URL=""
EMBED_MODEL=""
EMBED_FORMAT=""
EMBED_TIMEOUT="120"

OS_ID=""
OS_ID_LIKE=""
OS_CODENAME=""
ARCH=""
PREFLIGHT_MEMORY_MIB="未知"
PREFLIGHT_DISK_MIB="未知"
PREFLIGHT_NETWORK="未检查"
PREFLIGHT_DOCKER="未检查"
PREFLIGHT_SUDO="未检查"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_BOLD=""
  C_RESET=""
fi

info() { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
success() { printf '%s[成功]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { error "$*"; exit 1; }

cleanup() {
  local exit_code=$? path
  trap - EXIT ERR INT TERM
  set +e
  if ((ADOPTION_ACTIVE)); then
    error "操作被中断，正在恢复接管前的旧容器……"
    restore_adoption || error "旧容器自动恢复失败。请运行：sudo docker ps -a --filter name=$ADOPT_BACKUP_NAME"
  fi
  for path in "${TEMP_PATHS[@]:-}"; do
    [[ -n "$path" && -e "$path" ]] && rm -f -- "$path"
  done
  if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
    rm -rf -- "$LOCK_DIR"
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'error "操作在第 $LINENO 行失败。数据目录未被删除。"' ERR
trap 'warn "收到中断信号，正在安全收尾……"; exit 130' INT TERM

make_temp() {
  local variable=$1 path
  path="$(mktemp "${TMPDIR:-/tmp}/ombre-installer.XXXXXX")"
  chmod 600 "$path"
  TEMP_PATHS+=("$path")
  printf -v "$variable" '%s' "$path"
}

print_command() {
  local item
  printf '  $'
  for item in "$@"; do
    printf ' %q' "$item"
  done
  printf '\n'
}

run_cmd() {
  if ((DRY_RUN)); then
    print_command "$@"
    return 0
  fi
  "$@"
}

ensure_sudo() {
  if ((EUID == 0)); then
    PREFLIGHT_SUDO="root"
    return 0
  fi
  if ((DRY_RUN)); then
    PREFLIGHT_SUDO="演练模式未提权"
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || die "需要 root 权限，但系统没有 sudo。请安装 sudo 或以 root 运行。"
  sudo -v || die "未取得 sudo 权限。"
  PREFLIGHT_SUDO="sudo 已验证"
}

run_root() {
  if ((EUID == 0)); then
    run_cmd "$@"
  else
    ensure_sudo
    run_cmd sudo "$@"
  fi
}

copy_privileged_file() {
  local source=$1 destination=$2
  if [[ -r "$source" ]]; then
    cp -- "$source" "$destination"
  elif ((EUID == 0)); then
    cat -- "$source" >"$destination"
  else
    sudo cat -- "$source" >"$destination"
  fi
  chmod 600 "$destination"
}

atomic_install_file() {
  local source=$1 destination=$2 mode=${3:-0644}
  local remote_temp="${destination}.tmp.$$"
  if ((DRY_RUN)); then
    info "将原子写入 $destination（权限 $mode）"
    return 0
  fi
  if ! run_root install -m "$mode" -- "$source" "$remote_temp"; then
    run_root rm -f -- "$remote_temp" >/dev/null 2>&1 || true
    return 1
  fi
  if ! run_root mv -f -- "$remote_temp" "$destination"; then
    run_root rm -f -- "$remote_temp" >/dev/null 2>&1 || true
    return 1
  fi
}

acquire_lock() {
  local base="/tmp/ombre-brain-installer.lock"
  local old_pid=""
  if mkdir "$base" 2>/dev/null; then
    LOCK_DIR="$base"
    chmod 700 "$LOCK_DIR"
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi
  if [[ -r "$base/pid" ]]; then
    old_pid="$(<"$base/pid")"
  fi
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$old_pid" 2>/dev/null; then
    rm -rf -- "$base"
    mkdir "$base" || die "无法创建安装锁 $base"
    LOCK_DIR="$base"
    chmod 700 "$LOCK_DIR"
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi
  die "另一个安装器进程正在运行${old_pid:+（PID $old_pid）}。"
}

setup_prompt_fd() {
  ((PROMPT_READY)) && return 0
  if [[ "${OMBRE_INSTALLER_ALLOW_STDIN:-0}" == "1" ]]; then
    PROMPT_FD=0
    PROMPT_OUT_FD=2
    PROMPT_READY=1
    return 0
  fi
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    exec 3<>/dev/tty
    PROMPT_FD=3
    PROMPT_OUT_FD=3
    PROMPT_READY=1
    return 0
  fi
  die "当前操作需要交互终端。请下载脚本后运行，或确保管道命令仍连接 /dev/tty。"
}

prompt_line() {
  local variable=$1 message=$2 default_value=${3-} answer=""
  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$message" "$default_value" >&"$PROMPT_OUT_FD"
  else
    printf '%s: ' "$message" >&"$PROMPT_OUT_FD"
  fi
  IFS= read -r -u "$PROMPT_FD" answer || die "无法读取终端输入。"
  [[ -z "$answer" ]] && answer=$default_value
  printf -v "$variable" '%s' "$answer"
}

prompt_secret() {
  local variable=$1 message=$2 answer=""
  printf '%s: ' "$message" >&"$PROMPT_OUT_FD"
  IFS= read -r -s -u "$PROMPT_FD" answer || die "无法读取终端输入。"
  printf '\n' >&"$PROMPT_OUT_FD"
  printf -v "$variable" '%s' "$answer"
}

confirm() {
  local message=$1 default=${2:-no} answer=""
  while true; do
    if [[ "$default" == "yes" ]]; then
      printf '%s [Y/n，回车=是]: ' "$message" >&"$PROMPT_OUT_FD"
    else
      printf '%s [y/N，回车=否]: ' "$message" >&"$PROMPT_OUT_FD"
    fi
    IFS= read -r -u "$PROMPT_FD" answer || return 1
    answer=${answer,,}
    case "$answer" in
      "") [[ "$default" == "yes" ]]; return $? ;;
      y|yes|是|好|好的|确认|确定) return 0 ;;
      n|no|否|不|取消) return 1 ;;
      *) warn "请输入 y/是 表示继续，或 n/否 表示取消。" ;;
    esac
  done
}

menu_choice() {
  local variable=$1 message=$2 default_choice=$3
  shift 3
  local options=("$@") index answer=""
  printf '\n%s%s%s\n' "$C_BOLD" "$message" "$C_RESET" >&"$PROMPT_OUT_FD"
  for ((index = 0; index < ${#options[@]}; index++)); do
    printf '  %d) %s\n' "$((index + 1))" "${options[$index]}" >&"$PROMPT_OUT_FD"
  done
  while true; do
    printf '请选择 [%s]: ' "$default_choice" >&"$PROMPT_OUT_FD"
    IFS= read -r -u "$PROMPT_FD" answer || die "无法读取终端输入。"
    answer=${answer:-$default_choice}
    if [[ "$answer" =~ ^[0-9]{1,3}$ ]] && ((10#$answer >= 1 && 10#$answer <= ${#options[@]})); then
      printf -v "$variable" '%s' "$answer"
      return 0
    fi
    warn "请输入 1 到 ${#options[@]}。"
  done
}

validate_port() {
  local value=${1-}
  [[ "$value" =~ ^[0-9]{1,5}$ ]] && ((10#$value >= 1024 && 10#$value <= 65535))
}

validate_ipv4() {
  local value=${1-} part
  local -a octets=()
  IFS='.' read -r -a octets <<<"$value"
  ((${#octets[@]} == 4)) || return 1
  for part in "${octets[@]}"; do
    [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$part <= 255)) || return 1
  done
}

validate_http_url() {
  local value=${1-}
  [[ "$value" =~ ^https?://[^[:space:]]+$ ]]
}

validate_no_newline() {
  local value=${1-}
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

normalize_path() {
  local value=$1
  [[ "$value" == /* ]] || return 1
  validate_no_newline "$value" || return 1
  realpath -m -- "$value"
}

validate_data_path() {
  local value normalized app_resolved config_resolved
  value=${1-}
  normalized="$(normalize_path "$value")" || return 1
  app_resolved="$(realpath -m -- "$APP_DIR")"
  config_resolved="$(realpath -m -- "$CONFIG_DIR")"
  case "$normalized" in
    /|/var|/var/lib|/opt|/etc|"$APP_DIR"|"$CONFIG_DIR") return 1 ;;
  esac
  case "$normalized/" in
    "$app_resolved/"*|"$config_resolved/"*) return 1 ;;
  esac
  return 0
}

validate_managed_layout() {
  local app_resolved config_resolved data_resolved
  app_resolved="$(normalize_path "$APP_DIR")" || return 1
  config_resolved="$(normalize_path "$CONFIG_DIR")" || return 1
  data_resolved="$(normalize_path "$DATA_DIR")" || return 1
  case "$app_resolved" in /|/opt|/var|/var/lib|/etc) return 1 ;; esac
  case "$config_resolved" in /|/opt|/var|/var/lib|/etc) return 1 ;; esac
  case "$config_resolved/" in "$app_resolved/"*) return 1 ;; esac
  case "$app_resolved/" in "$config_resolved/"*) return 1 ;; esac
  case "$app_resolved/" in "$data_resolved/"*) return 1 ;; esac
  case "$config_resolved/" in "$data_resolved/"*) return 1 ;; esac
  validate_data_path "$data_resolved"
}

validate_proxy_cidrs() {
  local value=${1-} entry address prefix
  local -a entries=()
  validate_no_newline "$value" || return 1
  [[ -n "$value" && "$value" != *"0.0.0.0/0"* && "$value" != *"::/0"* ]] || return 1
  IFS=',' read -r -a entries <<<"$value"
  for entry in "${entries[@]}"; do
    [[ -n "$entry" && "$entry" == */* ]] || return 1
    address=${entry%/*}
    prefix=${entry##*/}
    [[ "$prefix" =~ ^[0-9]{1,3}$ ]] || return 1
    if [[ "$address" == *:* ]]; then
      [[ "$address" =~ ^[0-9A-Fa-f:]+$ ]] && ((10#$prefix >= 1 && 10#$prefix <= 128)) || return 1
    else
      validate_ipv4 "$address" && ((10#$prefix >= 1 && 10#$prefix <= 32)) || return 1
    fi
  done
}

directory_has_content() {
  local path=$1
  [[ -d "$path" ]] && find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

looks_like_vault() {
  local path=$1 evidence=0
  [[ -f "$path/.ombre-brain-vault" ]] && return 0
  [[ -f "$path/config.yaml" ]] && evidence=$((evidence + 1))
  [[ -f "$path/embeddings.db" ]] && evidence=$((evidence + 1))
  [[ -d "$path/permanent" ]] && evidence=$((evidence + 1))
  [[ -d "$path/dynamic" ]] && evidence=$((evidence + 1))
  ((evidence >= 2))
}

port_in_use() {
  local candidate=$1
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn 2>/dev/null | awk -v port="$candidate" '
      {
        endpoint=$4
        sub(/^.*:/, "", endpoint)
        gsub(/[^0-9]/, "", endpoint)
        if (endpoint == port) found=1
      }
      END { exit(found ? 0 : 1) }
    '
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  if [[ -r /proc/net/tcp ]]; then
    local port_hex
    port_hex="$(printf '%04X' "$candidate")"
    awk -v port=":$port_hex" '
      $2 ~ port "$" && $4 == "0A" { found=1 }
      END { exit(found ? 0 : 1) }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
    return $?
  fi
  warn "系统缺少 ss/lsof，且无法读取 /proc/net/tcp；不能可靠检查端口 $candidate。"
  return 1
}

env_quote() {
  local value=${1-}
  validate_no_newline "$value" || return 1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\$/\\\$}
  printf '"%s"' "$value"
}

env_line() {
  local key=$1 value=${2-}
  printf '%s=%s\n' "$key" "$(env_quote "$value")"
}

os_release_value() {
  local key=$1
  awk -F= -v wanted="$key" '
    $1 == wanted {
      value=substr($0, index($0, "=") + 1)
      gsub(/^"|"$/, "", value)
      gsub(/^\047|\047$/, "", value)
      print value
      exit
    }
  ' /etc/os-release
}

detect_platform() {
  [[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux 服务器。macOS、WSL 和原生 Windows 请按 README 手动使用 Docker Desktop。"
  if [[ -r /proc/sys/kernel/osrelease ]] && grep -qi microsoft /proc/sys/kernel/osrelease; then
    die "不支持在 WSL 内自动安装 Docker Engine。请使用 Docker Desktop，并按 README 手动运行 Compose。"
  fi
  [[ -r /etc/os-release ]] || die "缺少 /etc/os-release，无法安全判断发行版。"
  OS_ID="$(os_release_value ID)"
  OS_ID=${OS_ID,,}
  OS_ID_LIKE="$(os_release_value ID_LIKE)"
  OS_ID_LIKE=${OS_ID_LIKE,,}
  OS_CODENAME="$(os_release_value VERSION_CODENAME)"
  [[ -z "$OS_CODENAME" ]] && OS_CODENAME="$(os_release_value UBUNTU_CODENAME)"
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "不支持的 CPU 架构：$(uname -m)。官方镜像仅发布 linux/amd64 和 linux/arm64。" ;;
  esac
  case "$OS_ID" in
    ubuntu|debian|fedora|rhel|centos|rocky|almalinux) ;;
    *) die "不支持的发行版：$OS_ID。请先手动安装 Docker Engine 与 Compose v2，再按 README 手动部署。" ;;
  esac
}

detect_repo_root() {
  local script_path candidate
  script_path=${BASH_SOURCE[0]}
  [[ -f "$script_path" ]] || return 1
  candidate="$(cd "$(dirname "$script_path")" && pwd -P)"
  if [[ -f "$candidate/VERSION" && -f "$candidate/deploy/docker-compose.yml" && -f "$candidate/deploy/docker-compose.user.yml" ]]; then
    REPO_ROOT=$candidate
    return 0
  fi
  return 1
}

validate_loaded_state() {
  local value
  for value in "$APP_DIR" "$CONFIG_DIR" "$DATA_DIR" "$ENV_FILE" "$COMPOSE_FILE" "$BIN_LINK"; do
    [[ "$value" == /* ]] && validate_no_newline "$value" || return 1
  done
  [[ "$MODE" == "image" || "$MODE" == "source" ]] || return 1
  [[ "$INSTALLED" == "0" || "$INSTALLED" == "1" ]] || return 1
  validate_managed_layout || return 1
  validate_port "$PORT" || return 1
  validate_ipv4 "$BIND_ADDRESS" || return 1
  validate_proxy_cidrs "$TRUSTED_PROXY_CIDRS" || return 1
  case "$ACCESS_MODE" in
    local|lan|public_secure|advanced) ;;
    *) return 1 ;;
  esac
  case "$MODEL_MANAGEMENT" in
    dashboard|terminal) ;;
    *) return 1 ;;
  esac
  if [[ "$MODE" == "source" ]]; then
    [[ "$SOURCE_DIR" == /* ]] && validate_no_newline "$SOURCE_DIR" || return 1
  fi
}

read_state() {
  local key value file_state_version=""
  STATE_LOADED=0
  [[ -f "$STATE_FILE" ]] || return 1
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      STATE_VERSION)
        file_state_version=$value
        ;;
      INSTALLED|MODE|APP_DIR|CONFIG_DIR|DATA_DIR|ENV_FILE|COMPOSE_FILE|SOURCE_DIR|PORT|BIND_ADDRESS|ACCESS_MODE|TRUSTED_PROXY_CIDRS|MODEL_MANAGEMENT|BIN_LINK)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done <"$STATE_FILE"
  [[ "$file_state_version" == "$STATE_VERSION" ]] \
    || die "安装状态版本不兼容或已损坏：$STATE_FILE"
  validate_loaded_state || die "安装状态包含无效字段，拒绝继续：$STATE_FILE"
  STATE_LOADED=1
  return 0
}

write_state() {
  local temp
  make_temp temp
  {
    printf 'STATE_VERSION=%s\n' "$STATE_VERSION"
    printf 'INSTALLER_VERSION=%s\n' "$INSTALLER_VERSION"
    printf 'INSTALLED=%s\n' "$INSTALLED"
    printf 'MODE=%s\n' "$MODE"
    printf 'APP_DIR=%s\n' "$APP_DIR"
    printf 'CONFIG_DIR=%s\n' "$CONFIG_DIR"
    printf 'DATA_DIR=%s\n' "$DATA_DIR"
    printf 'ENV_FILE=%s\n' "$ENV_FILE"
    printf 'COMPOSE_FILE=%s\n' "$COMPOSE_FILE"
    printf 'SOURCE_DIR=%s\n' "$SOURCE_DIR"
    printf 'PORT=%s\n' "$PORT"
    printf 'BIND_ADDRESS=%s\n' "$BIND_ADDRESS"
    printf 'ACCESS_MODE=%s\n' "$ACCESS_MODE"
    printf 'TRUSTED_PROXY_CIDRS=%s\n' "$TRUSTED_PROXY_CIDRS"
    printf 'MODEL_MANAGEMENT=%s\n' "$MODEL_MANAGEMENT"
    printf 'BIN_LINK=%s\n' "$BIN_LINK"
  } >"$temp"
  atomic_install_file "$temp" "$STATE_FILE" 0644
}

try_download_file() {
  local url=$1 destination=$2
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --output "$destination" "$url" \
      || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=30 -O "$destination" "$url" || return 1
  else
    return 127
  fi
  [[ -s "$destination" ]]
}

download_file() {
  local url=$1 destination=$2
  if ((DRY_RUN)); then
    info "将下载 $url"
    return 0
  fi
  try_download_file "$url" "$destination" \
    || die "下载失败或结果为空：$url。请检查网络后重试：curl -fL $url -o $destination"
}

install_prerequisites() {
  case "$OS_ID" in
    ubuntu|debian)
      run_root env DEBIAN_FRONTEND=noninteractive apt-get update
      run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git gnupg
      ;;
    fedora|rhel|centos|rocky|almalinux)
      if command -v dnf >/dev/null 2>&1; then
        run_root dnf install -y ca-certificates curl git
      elif command -v yum >/dev/null 2>&1; then
        run_root yum install -y ca-certificates curl git
      else
        die "未找到 dnf 或 yum。"
      fi
      ;;
    *)
      if [[ "$OS_ID_LIKE" == *debian* ]]; then
        run_root env DEBIAN_FRONTEND=noninteractive apt-get update
        run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git gnupg
      else
        die "无法为 $OS_ID 自动安装基础依赖。"
      fi
      ;;
  esac
}

install_docker_engine() {
  local key_file repo_file repo_family package_manager
  install_prerequisites
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$OS_ID_LIKE" == *debian* ]]; then
    local docker_family="$OS_ID"
    [[ "$docker_family" != "ubuntu" && "$docker_family" != "debian" ]] && docker_family="debian"
    [[ -n "$OS_CODENAME" ]] || die "无法识别发行版代号，不能配置 Docker 官方仓库。"
    make_temp key_file
    download_file "https://download.docker.com/linux/$docker_family/gpg" "$key_file"
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$key_file" || die "Docker 仓库公钥内容无效。"
    run_root install -d -m 0755 /etc/apt/keyrings
    atomic_install_file "$key_file" /etc/apt/keyrings/docker.asc 0644
    make_temp repo_file
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "$docker_family" "$OS_CODENAME" >"$repo_file"
    atomic_install_file "$repo_file" /etc/apt/sources.list.d/docker.list 0644
    run_root env DEBIAN_FRONTEND=noninteractive apt-get update
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    case "$OS_ID" in
      fedora) repo_family="fedora" ;;
      rhel) repo_family="rhel" ;;
      centos|rocky|almalinux) repo_family="centos" ;;
      *) repo_family="centos" ;;
    esac
    make_temp repo_file
    download_file "https://download.docker.com/linux/$repo_family/docker-ce.repo" "$repo_file"
    grep -q '\[docker-ce-stable\]' "$repo_file" || die "Docker 仓库配置内容无效。"
    run_root install -d -m 0755 /etc/yum.repos.d
    atomic_install_file "$repo_file" /etc/yum.repos.d/docker-ce.repo 0644
    if command -v dnf >/dev/null 2>&1; then
      package_manager=dnf
    else
      package_manager=yum
    fi
    run_root "$package_manager" install -y \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  command -v systemctl >/dev/null 2>&1 || die "系统没有 systemctl，无法自动管理 Docker daemon。"
  run_root systemctl enable --now docker
}

ensure_docker_autostart() {
  command -v systemctl >/dev/null 2>&1 || {
    warn "系统没有 systemctl；无法自动验证 Docker 开机启动。请确认 Docker daemon 由系统负责自启。"
    return 0
  }
  if systemctl list-unit-files docker.service --no-legend 2>/dev/null | grep -q '^docker\.service'; then
    run_root systemctl enable --now docker.service \
      || die "无法启用 Docker 开机启动。请运行：sudo systemctl enable --now docker"
  elif [[ -d /run/systemd/system ]]; then
    warn "未找到 docker.service；当前 Docker 可能是 rootless/非标准安装，安装器无法保证重启后自动恢复。"
  fi
}

set_docker_command() {
  DOCKER=()
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif command -v docker >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  fi
  ((${#DOCKER[@]} > 0)) || return 1
  "${DOCKER[@]}" compose version >/dev/null 2>&1 || return 1
  PREFLIGHT_DOCKER="Engine + Compose v2 可用"
  return 0
}

ensure_docker() {
  if ((DRY_RUN)); then
    DOCKER=(docker)
    PREFLIGHT_DOCKER="演练模式假定可用"
    info "演练模式：假定 Docker Engine 与 Compose v2 可用。"
    return 0
  fi
  if set_docker_command; then
    ensure_docker_autostart
    set_docker_command || die "Docker daemon 已启动，但当前用户仍无法访问。请运行：sudo docker info"
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    run_root systemctl start docker || true
    if set_docker_command; then
      ensure_docker_autostart
      set_docker_command || die "Docker daemon 已启动，但当前用户仍无法访问。请运行：sudo docker info"
      return 0
    fi
  fi
  ((PROMPT_READY)) || setup_prompt_fd
  confirm "未检测到可用的 Docker Engine + Compose v2。现在从 Docker 官方软件仓库安装吗？" yes \
    || die "已取消 Docker 安装。请手动安装后重新运行。"
  install_docker_engine
  set_docker_command || die "Docker 安装完成，但 daemon 或 Compose v2 仍不可用。请运行：sudo systemctl status docker"
}

use_existing_docker() {
  if ((DRY_RUN)); then
    DOCKER=(docker)
    return 0
  fi
  set_docker_command && return 0
  if command -v docker >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    run_root systemctl start docker.service >/dev/null 2>&1 || true
    set_docker_command && return 0
  fi
  return 1
}

compose_run() {
  local args=(compose --project-name "$PROJECT_NAME" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
  if ((DRY_RUN)); then
    print_command "${DOCKER[@]}" "${args[@]}" "$@"
    return 0
  fi
  if ((EUID != 0)) && [[ -e "$ENV_FILE" && ! -r "$ENV_FILE" ]]; then
    run_root docker "${args[@]}" "$@"
  else
    "${DOCKER[@]}" "${args[@]}" "$@"
  fi
}

compose_run_with_file() {
  local file=$1
  shift
  local args=(compose --project-name "$PROJECT_NAME" --env-file "$ENV_FILE" -f "$file")
  if ((DRY_RUN)); then
    print_command "${DOCKER[@]}" "${args[@]}" "$@"
    return 0
  fi
  if ((EUID != 0)) && [[ -e "$ENV_FILE" && ! -r "$ENV_FILE" ]]; then
    run_root docker "${args[@]}" "$@"
  else
    "${DOCKER[@]}" "${args[@]}" "$@"
  fi
}

container_exists() {
  ((${#DOCKER[@]} > 0)) || return 1
  "${DOCKER[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

managed_container_owns_port() {
  local candidate=$1 running project service binding
  container_exists || return 1
  running="$("${DOCKER[@]}" inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  project="$("${DOCKER[@]}" inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  service="$("${DOCKER[@]}" inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  binding="$("${DOCKER[@]}" port "$CONTAINER_NAME" 8000/tcp 2>/dev/null | head -n1 || true)"
  [[ "$running" == "true" && "$project" == "$PROJECT_NAME" && "$service" == "ombre-brain" && "$binding" == *":$candidate" ]]
}

refuse_orphaned_adoption_backup() {
  ((DRY_RUN)) && return 0
  if "${DOCKER[@]}" container inspect "$ADOPT_BACKUP_NAME" >/dev/null 2>&1; then
    die "发现上次接管留下的备份容器 $ADOPT_BACKUP_NAME。请先运行：docker inspect $ADOPT_BACKUP_NAME，并人工确认恢复或移走后重试。"
  fi
}

fetch_url() {
  local url=$1
  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --max-time 5 "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 5 -O - "$url"
  else
    return 127
  fi
}

health_host() {
  if [[ "$BIND_ADDRESS" == "0.0.0.0" || "$BIND_ADDRESS" == "127.0.0.1" ]]; then
    printf '127.0.0.1\n'
  else
    printf '%s\n' "$BIND_ADDRESS"
  fi
}

redact_stream() {
  sed -E \
    -e 's/(("|\x27)(api[_-]?key|token|password)("|\x27)[[:space:]]*:[[:space:]]*("|\x27))[^"\x27]*/\1***REDACTED***/gI' \
    -e 's/((api[_-]?key|token|password)[[:space:]]*[=:][[:space:]]*)[^[:space:],"}]+/\1***REDACTED***/gI' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/-]+/\1***REDACTED***/g'
}

show_failure_details() {
  error "服务未通过健康检查。容器状态："
  compose_run ps 2>&1 || true
  error "最近 80 行脱敏日志："
  compose_run logs --tail 80 ombre-brain 2>&1 | redact_stream || true
}

health_check() {
  local timeout=${1:-90} elapsed=0 body version host
  host="$(health_host)"
  if ((DRY_RUN)); then
    info "演练模式：将轮询 http://$host:$PORT/health 和 /api/version。"
    return 0
  fi
  info "等待 Ombre Brain 就绪（最长 ${timeout} 秒）..."
  while ((elapsed < timeout)); do
    body="$(fetch_url "http://$host:$PORT/health" 2>/dev/null || true)"
    if [[ "$body" == *'"status":"ok"'* || "$body" == *'"status": "ok"'* ]]; then
      version="$(fetch_url "http://$host:$PORT/api/version" 2>/dev/null || true)"
      if printf '%s' "$version" | grep -Eq '"version"[[:space:]]*:[[:space:]]*"[^"]+"'; then
        success "健康检查通过，版本信息：$version"
        return 0
      fi
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  show_failure_details
  return 1
}

validate_compose_file() {
  local file=$1 expected_mode=$2
  [[ -s "$file" ]] || return 1
  grep -q '^services:' "$file" || return 1
  grep -q 'ombre-brain:' "$file" || return 1
  grep -q 'target: /app/buckets' "$file" || return 1
  if [[ "$expected_mode" == "image" ]]; then
    grep -q 'image: p0luz/ombre-brain:latest' "$file" || return 1
  else
    grep -q 'dockerfile: Dockerfile' "$file" || return 1
  fi
}

install_manager_script() {
  local source_script="" staged
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    source_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  fi
  if [[ -n "$source_script" && -f "$source_script" ]]; then
    bash -n "$source_script" || die "当前 install.sh 未通过 bash -n。"
    atomic_install_file "$source_script" "$APP_DIR/install.sh" 0755
  else
    make_temp staged
    download_file "$RAW_BASE_URL/install.sh" "$staged"
    bash -n "$staged" || die "下载的 install.sh 未通过 bash -n。"
    atomic_install_file "$staged" "$APP_DIR/install.sh" 0755
  fi
  if ((DRY_RUN)); then
    info "将创建命令入口 $BIN_LINK -> $APP_DIR/install.sh"
  else
    run_root ln -sfn -- "$APP_DIR/install.sh" "$BIN_LINK"
  fi
}

refresh_manager_after_update() {
  local candidate="" staged
  if ((DRY_RUN)); then
    info "演练模式：将同步更新 $APP_DIR/install.sh。"
    return 0
  fi
  if [[ "$MODE" == "source" && -n "$SOURCE_DIR" && -f "$SOURCE_DIR/install.sh" ]]; then
    candidate="$SOURCE_DIR/install.sh"
  elif [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/install.sh" ]]; then
    candidate="$REPO_ROOT/install.sh"
  fi
  if [[ -n "$candidate" ]] && bash -n "$candidate"; then
    atomic_install_file "$candidate" "$APP_DIR/install.sh" 0755
    return 0
  fi
  make_temp staged
  if try_download_file "$RAW_BASE_URL/install.sh" "$staged" && bash -n "$staged"; then
    atomic_install_file "$staged" "$APP_DIR/install.sh" 0755
  else
    warn "应用已更新，但安装器自更新失败；当前 ombrectl 仍可继续使用。"
  fi
}

write_environment() {
  local existing_file=${1-} keep_password=${2:-0} keep_models=${3:-0}
  local temp old_temp="" preserved_password="" preserved_models="" preserved_tunnel=""
  make_temp temp
  if [[ -n "$existing_file" && -f "$existing_file" ]]; then
    make_temp old_temp
    copy_privileged_file "$existing_file" "$old_temp"
    if ((keep_password)); then
      preserved_password="$(grep -m1 '^OMBRE_DASHBOARD_PASSWORD=' "$old_temp" || true)"
    fi
    if ((keep_models)); then
      preserved_models="$(grep -E '^OMBRE_(COMPRESS|EMBED)_(API_KEY|BASE_URL|MODEL|FORMAT|TIMEOUT_SECONDS)=|^OMBRE_EMBED_BACKEND=' "$old_temp" || true)"
    fi
    preserved_tunnel="$(grep -E '^TUNNEL_(EDGE|TRANSPORT_PROTOCOL)=' "$old_temp" || true)"
    awk '
      !/^(OMBRE_BIND_ADDRESS|OMBRE_HOST_PORT|OMBRE_HOST_VAULT_DIR|OMBRE_DASHBOARD_PASSWORD|OMBRE_TRUSTED_PROXY_CIDRS|OMBRE_COMPRESS_API_KEY|OMBRE_COMPRESS_BASE_URL|OMBRE_COMPRESS_MODEL|OMBRE_COMPRESS_FORMAT|OMBRE_COMPRESS_TIMEOUT_SECONDS|OMBRE_EMBED_BACKEND|OMBRE_EMBED_API_KEY|OMBRE_EMBED_BASE_URL|OMBRE_EMBED_MODEL|OMBRE_EMBED_FORMAT|OMBRE_EMBED_TIMEOUT_SECONDS|TUNNEL_EDGE|TUNNEL_TRANSPORT_PROTOCOL)=/
    ' "$old_temp" >"$temp"
  else
    printf '# Ombre Brain installer-managed environment\n' >"$temp"
  fi
  {
    printf '\n# --- ombrectl managed values; edit with `ombrectl configure` ---\n'
    env_line OMBRE_BIND_ADDRESS "$BIND_ADDRESS"
    env_line OMBRE_HOST_PORT "$PORT"
    env_line OMBRE_HOST_VAULT_DIR "$DATA_DIR"
    env_line OMBRE_TRUSTED_PROXY_CIDRS "$TRUSTED_PROXY_CIDRS"
    if ((keep_password)) && [[ -n "$preserved_password" ]]; then
      printf '%s\n' "$preserved_password"
    else
      env_line OMBRE_DASHBOARD_PASSWORD "$DASHBOARD_PASSWORD"
    fi
    if ((keep_models)) && [[ -n "$preserved_models" ]]; then
      printf '%s\n' "$preserved_models"
    elif [[ "$MODEL_MANAGEMENT" == "terminal" ]]; then
      env_line OMBRE_COMPRESS_API_KEY "$COMPRESS_API_KEY"
      env_line OMBRE_COMPRESS_BASE_URL "$COMPRESS_BASE_URL"
      env_line OMBRE_COMPRESS_MODEL "$COMPRESS_MODEL"
      env_line OMBRE_COMPRESS_FORMAT "$COMPRESS_FORMAT"
      env_line OMBRE_COMPRESS_TIMEOUT_SECONDS "$COMPRESS_TIMEOUT"
      env_line OMBRE_EMBED_BACKEND "api"
      env_line OMBRE_EMBED_API_KEY "$EMBED_API_KEY"
      env_line OMBRE_EMBED_BASE_URL "$EMBED_BASE_URL"
      env_line OMBRE_EMBED_MODEL "$EMBED_MODEL"
      env_line OMBRE_EMBED_FORMAT "$EMBED_FORMAT"
      env_line OMBRE_EMBED_TIMEOUT_SECONDS "$EMBED_TIMEOUT"
    else
      env_line OMBRE_COMPRESS_API_KEY ""
      env_line OMBRE_COMPRESS_BASE_URL ""
      env_line OMBRE_COMPRESS_MODEL ""
      env_line OMBRE_COMPRESS_FORMAT ""
      env_line OMBRE_COMPRESS_TIMEOUT_SECONDS ""
      env_line OMBRE_EMBED_BACKEND "api"
      env_line OMBRE_EMBED_API_KEY ""
      env_line OMBRE_EMBED_BASE_URL ""
      env_line OMBRE_EMBED_MODEL ""
      env_line OMBRE_EMBED_FORMAT ""
      env_line OMBRE_EMBED_TIMEOUT_SECONDS ""
    fi
    if [[ -n "$preserved_tunnel" ]]; then
      printf '%s\n' "$preserved_tunnel"
    else
      env_line TUNNEL_EDGE "region1.v2.argotunnel.com:7844,region2.v2.argotunnel.com:7844"
      env_line TUNNEL_TRANSPORT_PROTOCOL "http2"
    fi
  } >>"$temp"
  atomic_install_file "$temp" "$ENV_FILE" 0600
}

generate_password() {
  DASHBOARD_PASSWORD="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  [[ ${#DASHBOARD_PASSWORD} -eq 24 ]] || die "无法生成安全随机密码。"
  GENERATED_PASSWORD=1
}

collect_password() {
  local allow_keep=${1:-0} choice first second
  if ((allow_keep)); then
    menu_choice choice "Dashboard 密码" 1 \
      "保留现有密码（推荐）" \
      "输入一个新密码" \
      "自动生成 24 位密码"
    [[ "$choice" == "1" ]] && return 2
    [[ "$choice" == "3" ]] && { generate_password; return 0; }
  else
    menu_choice choice "Dashboard 密码" 1 \
      "自动生成 24 位密码（推荐）" \
      "输入自定义密码"
    [[ "$choice" == "1" ]] && { generate_password; return 0; }
  fi
  while true; do
    prompt_secret first "输入 Dashboard 密码（12-128 位）"
    prompt_secret second "再次输入密码"
    if [[ "$first" != "$second" ]]; then
      warn "两次密码不一致。"
      continue
    fi
    if ((${#first} < 12 || ${#first} > 128)); then
      warn "密码长度必须在 12-128 位之间。"
      continue
    fi
    validate_no_newline "$first" || { warn "密码不能包含换行或 NUL。"; continue; }
    DASHBOARD_PASSWORD=$first
    GENERATED_PASSWORD=0
    return 0
  done
}

collect_compression_provider() {
  local choice format_choice key
  menu_choice choice "选择脱水/打标 LLM" 1 \
    "Gemini（gemini-2.5-flash-lite）" \
    "DeepSeek（deepseek-chat）" \
    "硅基流动（deepseek-ai/DeepSeek-V3）" \
    "Anthropic（claude-3-5-haiku-latest）" \
    "自定义接口"
  case "$choice" in
    1)
      COMPRESS_FORMAT="openai_compat"
      COMPRESS_BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai/"
      COMPRESS_MODEL="gemini-2.5-flash-lite"
      ;;
    2)
      COMPRESS_FORMAT="openai_compat"
      COMPRESS_BASE_URL="https://api.deepseek.com/v1"
      COMPRESS_MODEL="deepseek-chat"
      ;;
    3)
      COMPRESS_FORMAT="openai_compat"
      COMPRESS_BASE_URL="https://api.siliconflow.cn/v1"
      COMPRESS_MODEL="deepseek-ai/DeepSeek-V3"
      ;;
    4)
      COMPRESS_FORMAT="anthropic"
      COMPRESS_BASE_URL="https://api.anthropic.com"
      COMPRESS_MODEL="claude-3-5-haiku-latest"
      ;;
    5)
      menu_choice format_choice "接口格式" 1 "OpenAI 兼容" "Gemini 原生" "Anthropic 原生"
      case "$format_choice" in
        1) COMPRESS_FORMAT="openai_compat" ;;
        2) COMPRESS_FORMAT="gemini" ;;
        3) COMPRESS_FORMAT="anthropic" ;;
      esac
      while true; do
        prompt_line COMPRESS_BASE_URL "Base URL" ""
        validate_http_url "$COMPRESS_BASE_URL" && break
        warn "Base URL 必须是 http:// 或 https:// 地址。"
      done
      prompt_line COMPRESS_MODEL "模型名" ""
      [[ -n "$COMPRESS_MODEL" ]] || die "模型名不能为空。"
      if [[ "$COMPRESS_BASE_URL" == http://* ]]; then
        confirm "该接口使用明文 HTTP。确认它只位于可信私网并继续吗？" no || die "已取消不安全的 HTTP 配置。"
      fi
      ;;
  esac
  prompt_secret key "输入脱水/打标 API Key"
  [[ -n "$key" ]] || die "脱水/打标 API Key 不能为空。"
  validate_no_newline "$key" || die "API Key 包含非法控制字符。"
  COMPRESS_API_KEY=$key
}

collect_embedding_provider() {
  local choice key reuse=""
  menu_choice choice "选择云端向量化服务" 1 \
    "暂不配置（可稍后在 Dashboard 设置）" \
    "Gemini（gemini-embedding-001）" \
    "硅基流动（BAAI/bge-m3）" \
    "自定义 OpenAI 兼容接口"
  case "$choice" in
    1)
      EMBED_API_KEY=""
      EMBED_BASE_URL=""
      EMBED_MODEL=""
      EMBED_FORMAT=""
      return 0
      ;;
    2)
      EMBED_FORMAT="openai_compat"
      EMBED_BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai/"
      EMBED_MODEL="gemini-embedding-001"
      if [[ "$COMPRESS_BASE_URL" == "$EMBED_BASE_URL" ]]; then
        confirm "向量化复用刚才的 Gemini Key 吗？" yes && reuse="yes"
      fi
      ;;
    3)
      EMBED_FORMAT="openai_compat"
      EMBED_BASE_URL="https://api.siliconflow.cn/v1"
      EMBED_MODEL="BAAI/bge-m3"
      if [[ "$COMPRESS_BASE_URL" == "$EMBED_BASE_URL" ]]; then
        confirm "向量化复用刚才的硅基流动 Key 吗？" yes && reuse="yes"
      fi
      ;;
    4)
      EMBED_FORMAT="openai_compat"
      while true; do
        prompt_line EMBED_BASE_URL "Embedding Base URL" ""
        validate_http_url "$EMBED_BASE_URL" && break
        warn "Base URL 必须是 http:// 或 https:// 地址。"
      done
      prompt_line EMBED_MODEL "Embedding 模型名" ""
      [[ -n "$EMBED_MODEL" ]] || die "Embedding 模型名不能为空。"
      if [[ "$EMBED_BASE_URL" == http://* ]]; then
        confirm "该接口使用明文 HTTP。确认它只位于可信私网并继续吗？" no || die "已取消不安全的 HTTP 配置。"
      fi
      ;;
  esac
  if [[ "$reuse" == "yes" ]]; then
    EMBED_API_KEY=$COMPRESS_API_KEY
  else
    prompt_secret key "输入向量化 API Key"
    [[ -n "$key" ]] || die "向量化 API Key 不能为空。"
    validate_no_newline "$key" || die "API Key 包含非法控制字符。"
    EMBED_API_KEY=$key
  fi
}

collect_model_configuration() {
  local allow_keep=${1:-0} choice
  if ((allow_keep)); then
    menu_choice choice "模型配置来源" 1 \
      "保留现有模型配置（推荐）" \
      "改由 Dashboard 管理" \
      "改由 ombrectl/环境变量管理"
    case "$choice" in
      1) return 2 ;;
      2) MODEL_MANAGEMENT="dashboard"; return 0 ;;
      3) MODEL_MANAGEMENT="terminal" ;;
    esac
  else
    menu_choice choice "模型配置来源" 1 \
      "稍后在 Dashboard 配置（推荐）" \
      "现在在终端配置"
    if [[ "$choice" == "1" ]]; then
      MODEL_MANAGEMENT="dashboard"
      return 0
    fi
    MODEL_MANAGEMENT="terminal"
  fi
  warn "终端托管值会在每次重启时覆盖 Dashboard 的同名字段；之后请使用 ombrectl configure 修改或切回 Dashboard。"
  collect_compression_provider
  collect_embedding_provider
}

collect_access_mode() {
  local default_choice=${1:-1} choice custom
  menu_choice choice "访问方式" "$default_choice" \
    "本机或 SSH 端口转发（127.0.0.1，推荐）" \
    "可信局域网（0.0.0.0，不自动改防火墙）" \
    "公网安全（127.0.0.1 + Cloudflare 账号及已托管域名）" \
    "高级自定义绑定"
  case "$choice" in
    1) ACCESS_MODE="local"; BIND_ADDRESS="127.0.0.1" ;;
    2)
      ACCESS_MODE="lan"
      BIND_ADDRESS="0.0.0.0"
      warn "局域网模式会监听所有网卡。安装器不会开放防火墙，请只允许可信网段访问。"
      ;;
    3) ACCESS_MODE="public_secure"; BIND_ADDRESS="127.0.0.1" ;;
    4)
      ACCESS_MODE="advanced"
      while true; do
        prompt_line custom "Docker 宿主机绑定 IPv4" "$BIND_ADDRESS"
        validate_ipv4 "$custom" && break
        warn "请输入合法 IPv4 地址。"
      done
      BIND_ADDRESS=$custom
      prompt_line TRUSTED_PROXY_CIDRS "可信最后一跳代理 CIDR（逗号分隔）" "$TRUSTED_PROXY_CIDRS"
      validate_proxy_cidrs "$TRUSTED_PROXY_CIDRS" \
        || die "代理 CIDR 只能包含明确的 IP/CIDR，且禁止信任 0.0.0.0/0 或 ::/0。"
      ;;
  esac
}

collect_port() {
  local current_port=${1:-18001} allow_current=${2:-0} candidate
  while true; do
    prompt_line candidate "宿主机端口" "$current_port"
    validate_port "$candidate" || { warn "端口必须是 1024-65535 的整数。"; continue; }
    if port_in_use "$candidate"; then
      if ! ((allow_current)) || [[ "$candidate" != "$current_port" ]] || ! managed_container_owns_port "$candidate"; then
        warn "端口 $candidate 已被占用："
        local _holder=""
        if command -v ss >/dev/null 2>&1; then
          _holder="$(ss -H -ltnp 2>/dev/null | awk -v p="$candidate" 'index($4, ":"p"$") || $4 ~ ":"p"$" {print}' | head -1 | sed -E 's/.*users:\(\("([^,]+),.*/\1/; s/.*\"([^\"]+)\".*/\1/')"
        fi
        if [[ -z "$_holder" ]] && command -v lsof >/dev/null 2>&1; then
          _holder="$(lsof -nP -iTCP:"$candidate" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}')"
        fi
        if [[ -n "$_holder" ]]; then
          printf '         当前占用进程：%s\n' "$_holder"
          printf '         查看真实 PID：sudo ss -ltnp "sport = :%s"\n' "$candidate"
          printf '         请确认该服务可以停止后，再使用上面查到的 PID 或 systemd 服务名停止它。\n'
        else
          printf '         （无法识别占用者，常见原因：另一容器占用、或仅本机 loopback 占用）\n'
        fi
        printf '         换一个端口，或先释放 %s 上的旧服务。\n' "$candidate"
        continue
      fi
    fi
    PORT=$candidate
    return 0
  done
}

collect_data_directory() {
  local default_value=${1:-$DEFAULT_DATA_DIR} candidate choice legacy=""
  if [[ -n "$REPO_ROOT" ]]; then
    if directory_has_content "$REPO_ROOT/buckets"; then
      legacy="$REPO_ROOT/buckets"
    elif directory_has_content "$REPO_ROOT/data"; then
      legacy="$REPO_ROOT/data"
    fi
  fi
  if [[ -n "$legacy" ]]; then
    menu_choice choice "检测到已有数据：$legacy" 1 \
      "直接采用该目录（不移动数据，推荐）" \
      "复制到标准目录并保留原目录" \
      "忽略并使用其他目录"
    case "$choice" in
      1) DATA_DIR="$(normalize_path "$legacy")"; return 0 ;;
      2) LEGACY_COPY_SOURCE="$(normalize_path "$legacy")" ;;
    esac
  fi
  while true; do
    prompt_line candidate "永久记忆目录（绝对路径）" "$default_value"
    validate_data_path "$candidate" || { warn "目录必须是安全的绝对路径，且不能是系统根目录、程序/配置目录或其子目录。"; continue; }
    candidate="$(normalize_path "$candidate")"
    if [[ -e "$candidate" && ( ! -d "$candidate" || ! -r "$candidate" || ! -x "$candidate" ) ]]; then
      if ((STATE_LOADED)) && [[ "$candidate" == "$(normalize_path "$default_value")" ]]; then
        info "根据已有安装状态继续使用受保护的 vault：$candidate"
        DATA_DIR=$candidate
        return 0
      fi
      warn "无法以当前用户安全检查该目录；请修复读取/进入权限后重试：$candidate"
      continue
    fi
    if directory_has_content "$candidate" && ! looks_like_vault "$candidate"; then
      warn "目标目录非空且不像 Ombre Brain vault：$candidate"
      continue
    fi
    if looks_like_vault "$candidate"; then
      confirm "检测到现有 Ombre Brain 数据。直接采用且不覆盖内容吗？" yes || continue
    fi
    DATA_DIR=$candidate
    return 0
  done
}

probe_existing_container() {
  local image mount running choice compose_project compose_service trusted=0
  container_exists || return 0
  image="$("${DOCKER[@]}" inspect --format '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  mount="$("${DOCKER[@]}" inspect --format '{{range .Mounts}}{{if eq .Destination "/app/buckets"}}{{println .Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | head -n1)"
  running="$("${DOCKER[@]}" inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  compose_project="$("${DOCKER[@]}" inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  compose_service="$("${DOCKER[@]}" inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  case "$image" in
    p0luz/ombre-brain|p0luz/ombre-brain:*|p0luz/ombre-brain@*|docker.io/p0luz/ombre-brain|docker.io/p0luz/ombre-brain:*|docker.io/p0luz/ombre-brain@*) trusted=1 ;;
  esac
  if [[ -n "$compose_service" && "$compose_service" != "ombre-brain" ]]; then
    trusted=0
  fi
  if ((trusted == 0)) || [[ -z "$mount" || "$mount" != /* ]]; then
    die "发现同名容器 $CONTAINER_NAME，但无法确认它是带持久挂载的 Ombre Brain。为避免覆盖，安装已停止。"
  fi
  if [[ "$compose_project" == "$PROJECT_NAME" ]]; then
    die "同名容器已带有固定 Compose 项目标签 $PROJECT_NAME，但安装状态缺失。为避免 Compose 接管时删除回滚容器，请先备份 $mount，并人工恢复 /etc/ombre-brain/install.conf。"
  fi
  if "${DOCKER[@]}" container inspect "$ADOPT_BACKUP_NAME" >/dev/null 2>&1; then
    die "发现上次接管留下的备份容器 $ADOPT_BACKUP_NAME。请先运行：docker inspect $ADOPT_BACKUP_NAME，并人工确认恢复或移走后重试。"
  fi
  printf '\n检测到未由 ombrectl 管理的现有 Ombre Brain：\n'
  printf '  镜像：%s\n  数据：%s\n' "$image" "$mount"
  menu_choice choice "如何处理现有容器" 1 \
    "接管部署并继续使用现有数据" \
    "停止安装，不改动容器"
  [[ "$choice" == "1" ]] || die "已停止，现有容器未改动。"
  ADOPT_CONTAINER=1
  ADOPT_WAS_RUNNING=$running
  DATA_DIR="$(normalize_path "$mount")"
  info "接管时会先把旧容器改名保存；新部署健康后才移除旧容器。"
}

prepare_adoption() {
  ((ADOPT_CONTAINER)) || return 0
  if ((DRY_RUN)); then
    info "将把 $CONTAINER_NAME 临时改名为 $ADOPT_BACKUP_NAME。"
    return 0
  fi
  ADOPTION_ACTIVE=1
  if [[ "$ADOPT_WAS_RUNNING" == "true" ]]; then
    if ! "${DOCKER[@]}" stop "$CONTAINER_NAME" >/dev/null; then
      die "无法停止待接管容器；请运行：sudo docker logs $CONTAINER_NAME"
    fi
  fi
  if ! "${DOCKER[@]}" rename "$CONTAINER_NAME" "$ADOPT_BACKUP_NAME"; then
    if [[ "$ADOPT_WAS_RUNNING" == "true" ]]; then
      if ! "${DOCKER[@]}" start "$CONTAINER_NAME" >/dev/null 2>&1; then
        error "原容器重新启动失败。请运行：sudo docker start $CONTAINER_NAME"
        die "无法创建接管备份，且原容器未能自动重新启动。"
      fi
    fi
    ADOPTION_ACTIVE=0
    die "无法创建接管备份容器；原容器未被删除。"
  fi
  ADOPTION_BACKUP_READY=1
}

finish_adoption() {
  ((ADOPT_CONTAINER)) || return 0
  if ((DRY_RUN)); then
    info "新部署健康后将移除旧容器备份；数据目录不删除。"
    return 0
  fi
  ADOPTION_ACTIVE=0
  ADOPTION_BACKUP_READY=0
  if ! "${DOCKER[@]}" rm -f "$ADOPT_BACKUP_NAME" >/dev/null 2>&1; then
    warn "新服务已健康，但旧备份容器未能清理：$ADOPT_BACKUP_NAME"
    warn "请检查后运行：sudo docker inspect $ADOPT_BACKUP_NAME && sudo docker rm $ADOPT_BACKUP_NAME"
  fi
}

restore_adoption() {
  ((ADOPT_CONTAINER && ADOPTION_ACTIVE)) || return 0
  warn "恢复接管前的旧容器。"
  compose_run down --remove-orphans >/dev/null 2>&1 || true
  if ((DRY_RUN)); then
    ADOPTION_ACTIVE=0
    ADOPTION_BACKUP_READY=0
    return 0
  fi
  if ((ADOPTION_BACKUP_READY)) || "${DOCKER[@]}" container inspect "$ADOPT_BACKUP_NAME" >/dev/null 2>&1; then
    if "${DOCKER[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
      error "新容器仍占用名称 $CONTAINER_NAME，拒绝覆盖旧备份。"
      return 1
    fi
    if ! "${DOCKER[@]}" rename "$ADOPT_BACKUP_NAME" "$CONTAINER_NAME"; then
      error "无法把备份容器恢复为 $CONTAINER_NAME。"
      if [[ "$ADOPT_WAS_RUNNING" == "true" ]] \
          && ! "${DOCKER[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        if "${DOCKER[@]}" start "$ADOPT_BACKUP_NAME" >/dev/null 2>&1; then
          warn "旧服务已用备份名称临时恢复：$ADOPT_BACKUP_NAME。请稍后人工修复容器名称。"
        fi
      fi
      return 1
    fi
  elif ! "${DOCKER[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    error "原容器和备份容器都无法找到，不能自动恢复。"
    return 1
  fi
  if [[ "$ADOPT_WAS_RUNNING" == "true" ]]; then
    if ! "${DOCKER[@]}" start "$CONTAINER_NAME" >/dev/null; then
      error "旧容器名称已恢复，但启动失败。请运行：sudo docker start $CONTAINER_NAME"
      return 1
    fi
  fi
  ADOPTION_ACTIVE=0
  ADOPTION_BACKUP_READY=0
  return 0
}

prepare_directories() {
  run_root install -d -m 0755 -- "$APP_DIR" "$CONFIG_DIR"
  run_root install -d -m 0750 -- "$DATA_DIR"
  if [[ -n "$LEGACY_COPY_SOURCE" ]]; then
    if directory_has_content "$DATA_DIR"; then
      die "复制目标 $DATA_DIR 已非空，拒绝合并两个 vault。"
    fi
    info "复制旧数据到 $DATA_DIR；原目录将保留。"
    if ((DRY_RUN)); then
      print_command cp -a "$LEGACY_COPY_SOURCE/." "$DATA_DIR/"
    else
      run_root cp -a -- "$LEGACY_COPY_SOURCE/." "$DATA_DIR/"
    fi
  fi
  if ((DRY_RUN)); then
    info "将创建 vault 标记 $DATA_DIR/.ombre-brain-vault"
    info "将创建程序标记 $APP_DIR/.ombre-installer-managed"
  else
    local marker
    make_temp marker
    printf 'managed-by=ombrectl\n' >"$marker"
    atomic_install_file "$marker" "$DATA_DIR/.ombre-brain-vault" 0644
    atomic_install_file "$marker" "$APP_DIR/.ombre-installer-managed" 0644
  fi
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    info "检测到 SELinux Enforcing，标记数据目录供容器读写。"
    run_root chcon -Rt container_file_t -- "$DATA_DIR" || warn "SELinux 标记失败；若容器提示 Permission denied，请检查该目录策略。"
  fi
}

prepare_reconfigured_data_dir() {
  local marker
  run_root install -d -m 0750 -- "$DATA_DIR"
  if [[ ! -f "$DATA_DIR/.ombre-brain-vault" ]]; then
    make_temp marker
    printf 'managed-by=ombrectl\n' >"$marker"
    atomic_install_file "$marker" "$DATA_DIR/.ombre-brain-vault" 0644
  fi
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    run_root chcon -Rt container_file_t -- "$DATA_DIR" \
      || warn "SELinux 标记失败；若容器提示 Permission denied，请检查该目录策略。"
  fi
}

prepare_image_mode() {
  local staged
  make_temp staged
  if [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/deploy/docker-compose.user.yml" ]]; then
    cp -- "$REPO_ROOT/deploy/docker-compose.user.yml" "$staged"
  else
    download_file "$RAW_BASE_URL/deploy/docker-compose.user.yml" "$staged"
  fi
  if ! ((DRY_RUN)); then
    validate_compose_file "$staged" image || die "用户版 Compose 校验失败。"
  fi
  COMPOSE_FILE="$APP_DIR/compose.yaml"
  atomic_install_file "$staged" "$COMPOSE_FILE" 0644
  SOURCE_DIR=""
}

prepare_source_mode() {
  if [[ "$SOURCE_CHOICE" == "current" ]]; then
    [[ -n "$REPO_ROOT" ]] || die "没有可用的当前源码仓库。"
    SOURCE_DIR=$REPO_ROOT
  else
    SOURCE_DIR="$APP_DIR/source"
    if [[ -e "$SOURCE_DIR" ]] && directory_has_content "$SOURCE_DIR"; then
      die "源码目标目录非空：$SOURCE_DIR"
    fi
    if ((DRY_RUN)); then
      print_command git clone --branch main --single-branch "$REPO_URL" "$SOURCE_DIR"
    else
      run_root install -d -m 0755 -- "$SOURCE_DIR"
      run_root rmdir -- "$SOURCE_DIR"
      run_root git clone --branch main --single-branch "$REPO_URL" "$SOURCE_DIR"
    fi
  fi
  COMPOSE_FILE="$SOURCE_DIR/deploy/docker-compose.yml"
  if ! ((DRY_RUN)); then
    validate_compose_file "$COMPOSE_FILE" source || die "源码版 Compose 校验失败：$COMPOSE_FILE"
  fi
}

validate_install_targets() {
  local app_resolved repo_resolved link_target=""
  app_resolved="$(realpath -m -- "$APP_DIR")"
  repo_resolved="${REPO_ROOT:+$(realpath -m -- "$REPO_ROOT")}"

  if [[ "$MODE" == "source" && "$SOURCE_CHOICE" == "current" && ! -d "$REPO_ROOT/.git" ]]; then
    die "当前目录不是可更新的 Git checkout：$REPO_ROOT。请选择自动克隆源码。"
  fi

  if [[ -d "$APP_DIR" && ( ! -r "$APP_DIR" || ! -x "$APP_DIR" ) ]]; then
    die "无法安全检查程序目标目录：$APP_DIR。请修复权限或直接以 root 重新运行。"
  fi
  if [[ -d "$CONFIG_DIR" && ( ! -r "$CONFIG_DIR" || ! -x "$CONFIG_DIR" ) ]]; then
    die "无法安全检查配置目标目录：$CONFIG_DIR。请修复权限或直接以 root 重新运行。"
  fi

  if directory_has_content "$APP_DIR"; then
    if [[ "$MODE" == "source" && "$SOURCE_CHOICE" == "current" && -n "$repo_resolved" && "$app_resolved" == "$repo_resolved" ]]; then
      die "程序目录不能与当前源码仓库相同：$APP_DIR。请保持默认 /opt/ombre-brain，卸载器绝不会递归删除你的源码 checkout。"
    elif [[ -f "$APP_DIR/.ombre-installer-managed" ]]; then
      confirm "检测到上次未完成的安装。继续使用 $APP_DIR 重试吗？vault 不会被覆盖或删除。" yes \
        || die "已停止；程序目录和 vault 均未改动。"
    else
      die "程序目标目录非空且没有 ombrectl 管理标记：$APP_DIR。请移走该目录或设置其他目标，安装器不会静默合并。"
    fi
  fi

  if directory_has_content "$CONFIG_DIR" && [[ ! -f "$STATE_FILE" ]]; then
    if [[ -f "$ENV_FILE" ]]; then
      confirm "检测到没有安装状态的现有环境文件 $ENV_FILE。明确采用并保留其中未托管配置吗？" no \
        || die "已停止；配置目录未改动。"
    else
      die "配置目标目录非空但没有可识别的安装状态或环境文件：$CONFIG_DIR"
    fi
  fi

  if [[ -e "$BIN_LINK" || -L "$BIN_LINK" ]]; then
    if [[ -L "$BIN_LINK" ]]; then
      link_target="$(readlink "$BIN_LINK" || true)"
    fi
    [[ "$link_target" == "$APP_DIR/install.sh" ]] \
      || die "全局命令目标已存在且不属于 Ombre Brain：$BIN_LINK。请人工确认后移走，安装器不会覆盖。"
  fi
}

ensure_required_tools() {
  if [[ "$MODE" == "source" ]] && ! command -v git >/dev/null 2>&1; then
    info "源码安装和安全更新需要 Git，正在通过系统软件仓库安装基础工具。"
    install_prerequisites
  fi
  if [[ "$MODE" == "source" ]]; then
    command -v git >/dev/null 2>&1 || die "Git 安装后仍不可用。请先运行 git --version 再重试。"
  fi
}

validate_disk_space() {
  local target=$1 parent available
  parent=$target
  while [[ ! -e "$parent" && "$parent" != "/" ]]; do
    parent=$(dirname "$parent")
  done
  available="$(df -Pm "$parent" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ "$available" =~ ^[0-9]+$ ]]; then
    PREFLIGHT_DISK_MIB=$available
    if ((available < 1024)); then
      die "可用磁盘不足 1 GiB（约 ${available} MiB）。请释放空间后重试。"
    elif ((available < 2048)); then
      warn "可用磁盘约 ${available} MiB，低于建议的 2 GiB。"
    fi
  fi
}

validate_memory() {
  local memory_kib=""
  if [[ -r /proc/meminfo ]]; then
    memory_kib="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
  fi
  if [[ "$memory_kib" =~ ^[0-9]+$ ]]; then
    PREFLIGHT_MEMORY_MIB=$((memory_kib / 1024))
    if ((PREFLIGHT_MEMORY_MIB < 1024)); then
      warn "系统内存约 ${PREFLIGHT_MEMORY_MIB} MiB，低于建议的 1 GiB；构建源码时尤其可能失败。"
    fi
  else
    warn "无法读取系统内存信息；继续前请确认至少有 1 GiB 可用内存。"
  fi
}

validate_network_access() {
  local url host registry_url="https://registry-1.docker.io/v2/"
  local -a urls=(
    "$RAW_BASE_URL/install.sh"
    "https://github.com/"
  )
  local -a hosts=(raw.githubusercontent.com github.com registry-1.docker.io)
  if [[ "$PREFLIGHT_DOCKER" != "Engine + Compose v2 可用"* ]]; then
    urls+=("https://download.docker.com/")
    hosts+=(download.docker.com)
  fi
  if ((DRY_RUN)); then
    PREFLIGHT_NETWORK="演练模式未请求网络"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    for url in "${urls[@]}"; do
      curl --fail --silent --show-error --location --output /dev/null --max-time 10 "$url" \
        || die "网络预检失败：$url。修复 DNS/代理后可复制运行：curl -I $url"
    done
    curl --silent --show-error --output /dev/null --max-time 10 "$registry_url" \
      || die "Docker Hub 网络预检失败。修复 DNS/代理后运行：curl -I $registry_url"
    PREFLIGHT_NETWORK="安装器仓库、上游 GitHub、Docker 仓库可达"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    for url in "${urls[@]}"; do
      wget --quiet --spider --timeout=10 "$url" \
        || die "网络预检失败：$url。修复 DNS/代理后可复制运行：wget --spider $url"
    done
    if command -v getent >/dev/null 2>&1; then
      getent ahosts registry-1.docker.io >/dev/null 2>&1 \
        || die "DNS 无法解析 registry-1.docker.io；请先修复 DNS。"
    fi
    PREFLIGHT_NETWORK="安装器仓库、上游 GitHub、Docker 仓库可达"
    return 0
  fi
  if command -v getent >/dev/null 2>&1; then
    for host in "${hosts[@]}"; do
      getent ahosts "$host" >/dev/null 2>&1 || die "DNS 无法解析 $host；请先修复 DNS。"
    done
    PREFLIGHT_NETWORK="DNS 正常（缺少 curl/wget，未做 HTTPS 探测）"
    warn "$PREFLIGHT_NETWORK"
    return 0
  fi
  PREFLIGHT_NETWORK="无法验证（缺少 curl、wget 和 getent）"
  warn "$PREFLIGHT_NETWORK"
}

inspect_docker_status() {
  if ! command -v docker >/dev/null 2>&1; then
    PREFLIGHT_DOCKER="未安装；执行时将再次确认"
  elif command -v sudo >/dev/null 2>&1 \
      && sudo -n docker info >/dev/null 2>&1 \
      && sudo -n docker compose version >/dev/null 2>&1; then
    PREFLIGHT_DOCKER="Engine + Compose v2 可用（通过 sudo）"
  elif ! docker info >/dev/null 2>&1; then
    PREFLIGHT_DOCKER="已安装但 daemon/权限不可用；执行时将尝试修复"
  elif ! docker compose version >/dev/null 2>&1; then
    PREFLIGHT_DOCKER="Engine 可用但缺少 Compose v2"
  else
    PREFLIGHT_DOCKER="Engine + Compose v2 可用"
  fi
}

show_install_summary() {
  local dummy=""
  local -a blockers=()
  local headline mode_label access_label model_label
  if [[ "$MODE" == "image" ]]; then
    mode_label="官方预构建镜像（无需编译，推荐）"
  else
    mode_label="从源码构建（适合开发者）"
  fi
  case "$ACCESS_MODE" in
    local) access_label="仅本机/SSH 转发；外网不能直接访问" ;;
    lan) access_label="可信局域网；监听所有网卡，安装器不改防火墙" ;;
    public_secure) access_label="公网安全引导；当前仍只监听本机，不直接暴露公网" ;;
    advanced) access_label="高级自定义绑定：$BIND_ADDRESS" ;;
  esac
  if [[ "$MODEL_MANAGEMENT" == "dashboard" ]]; then
    model_label="稍后在 Dashboard 配置压缩与向量模型（推荐）"
  else
    model_label="由 ombrectl 环境变量托管"
  fi
  if [[ "$PREFLIGHT_SUDO" == *'未'* || "$PREFLIGHT_SUDO" == '演练模式未提权' ]]; then
    blockers+=("权限：$PREFLIGHT_SUDO")
  fi
  case "$PREFLIGHT_DOCKER" in
    *'未安装'*|*'缺少'*|*'不可用'*) blockers+=("Docker：$PREFLIGHT_DOCKER") ;;
  esac
  case "$PREFLIGHT_NETWORK" in
    *'无法'*|*'缺少'*) blockers+=("网络：$PREFLIGHT_NETWORK") ;;
  esac
  if (( ${#PREFLIGHT_MEMORY_MIB} > 0 )) && [[ "$PREFLIGHT_MEMORY_MIB" != '未知' ]] && (( PREFLIGHT_MEMORY_MIB < 1024 )); then
    blockers+=("内存：${PREFLIGHT_MEMORY_MIB} MiB < 1024")
  fi
  if (( ${#PREFLIGHT_DISK_MIB} > 0 )) && [[ "$PREFLIGHT_DISK_MIB" != '未知' ]] && (( PREFLIGHT_DISK_MIB < 2048 )); then
    blockers+=("磁盘：${PREFLIGHT_DISK_MIB} MiB < 2048")
  fi
  if (( ${#blockers[@]} == 0 )); then
    headline="${C_GREEN}✅ 你的服务器满足安装条件${C_RESET}"
  elif (( ${#blockers[@]} <= 2 )); then
    headline="${C_YELLOW}⚠️  存在 ${#blockers[@]} 项需要确认的条件${C_RESET}"
  else
    headline="${C_RED}❌ 存在 ${#blockers[@]} 项阻塞条件，建议先修复再继续${C_RESET}"
  fi
  printf '\n%s\n' "$headline"
  if (( ${#blockers[@]} > 0 )); then
    local item
    for item in "${blockers[@]}"; do
      printf '   - %s\n' "$item"
    done
  fi
  if (( DRY_RUN )); then
    info '干跑模式：自动展开完整摘要，跳过确认步骤。'
  else
    prompt_line dummy '按 Enter 查看完整摘要，输入 q 取消' ''
    if [[ "$dummy" == 'q' || "$dummy" == 'Q' ]]; then
      die '已按用户要求取消安装。'
    fi
  fi
  printf '\n%s完整安装摘要%s\n' "$C_BOLD" "$C_RESET"
  printf '  部署模式：%s\n' "$mode_label"
  printf '  程序目录：%s\n' "$APP_DIR"
  printf '  配置目录：%s\n' "$CONFIG_DIR"
  printf '  记忆目录：%s\n' "$DATA_DIR"
  printf '  监听地址：%s:%s\n' "$BIND_ADDRESS" "$PORT"
  printf '  访问方式：%s\n' "$access_label"
  printf '  模型配置：%s\n' "$model_label"
  printf '  发行版：%s%s\n' "$OS_ID" "${OS_CODENAME:+ ($OS_CODENAME)}"
  printf '  CPU 架构：%s\n' "$ARCH"
  printf '  内存：%s MiB\n' "$PREFLIGHT_MEMORY_MIB"
  printf '  目标磁盘可用：%s MiB\n' "$PREFLIGHT_DISK_MIB"
  printf '  网络：%s\n' "$PREFLIGHT_NETWORK"
  printf '  权限：%s\n' "$PREFLIGHT_SUDO"
  printf '  Docker：%s\n' "$PREFLIGHT_DOCKER"
  if [[ "$MODE" == "source" ]]; then
    printf '  源码来源：%s\n' "$SOURCE_CHOICE"
  fi
  printf '  防火墙/HTTPS：不自动修改\n'
  printf '  记忆删除：安装器永不删除 vault\n\n'
}

post_install_instructions() {
  local context=${1:-install} host_ip="" ssh_user
  ssh_user="${SUDO_USER:-${USER:-root}}"
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    host_ip="$(awk '{print $3}' <<<"$SSH_CONNECTION")"
  fi
  if [[ -z "$host_ip" ]] && command -v hostname >/dev/null 2>&1; then
    host_ip="$({ hostname -I 2>/dev/null || true; } | awk '{print $1}')"
  fi
  [[ -n "$host_ip" ]] || host_ip="你的服务器IP"
  if [[ "$context" == "configure" ]]; then
    printf '\n%s%s配置已应用，Ombre Brain 健康检查通过%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  else
    printf '\n%s%sOmbre Brain 已就绪%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf '\n%s小白首次使用五步走%s\n' "$C_BOLD" "$C_RESET"
    printf '  1) 按下方说明打开 Dashboard 并登录\n'
    if ((GENERATED_PASSWORD)); then
      printf '  2) 使用下方自动生成的密码；登录后立即改成自己记得住的强密码\n'
    else
      printf '  2) 使用你刚才亲自输入的密码登录；安装器不会再次显示它\n'
    fi
    printf '  3) Dashboard → ③ 引擎：分别填写“压缩模型”和“向量模型”的 Key，并分别点测试\n'
    printf '  4) Dashboard → ⑥ MCP 配置：复制生成的 /mcp 连接地址或配置\n'
    printf '  5) 把连接添加到 Claude Desktop、Claude Code 或 claude.ai，再发送“你好”验证\n\n'
  fi
  case "$ACCESS_MODE" in
    lan) printf '  Dashboard：http://%s:%s\n' "$host_ip" "$PORT" ;;
    *)
      printf '  Dashboard：http://127.0.0.1:%s\n' "$PORT"
      printf '\n  这是安全的本机地址，不能直接在远程服务器之外打开。\n'
      printf '  请在“自己的电脑”上新开终端执行下面这条命令，不是在服务器里执行：\n'
      printf '  ssh -N -L %s:127.0.0.1:%s %s@%s\n' "$PORT" "$PORT" "$ssh_user" "$host_ip"
      printf '  如果上面的 IP 不是你平时登录服务器使用的地址，请替换成云厂商给你的 SSH IP。\n'
      printf '  这个 SSH 窗口必须保持开启；然后在自己电脑浏览器打开 http://127.0.0.1:%s\n' "$PORT"
      ;;
  esac
  if ((GENERATED_PASSWORD)); then
    printf '  本次生成的 Dashboard 密码：%s\n' "$DASHBOARD_PASSWORD"
    printf '  请立即保存；之后可用 ombrectl configure 更换。\n'
  fi
  if [[ "$MODEL_MANAGEMENT" == "dashboard" ]]; then
    printf '  模型配置：登录 Dashboard → ③ 引擎，分别配置并测试压缩模型与向量模型。\n'
  else
    printf '  模型由 /etc/ombre-brain/ombre.env 托管；请在 Dashboard 分别测试压缩和向量接口。\n'
  fi
  if [[ "$ACCESS_MODE" == "public_secure" ]]; then
    printf '  公网安全：准备 Cloudflare 账号及已托管域名，再经 SSH 登录 Dashboard 配置内置 Tunnel，最后在 /onboarding 选择“公网安全”。\n'
  fi
  printf '\n常用命令：\n'
  printf '  ombrectl status      查看状态\n'
  printf '  ombrectl doctor      完整诊断\n'
  printf '  ombrectl logs        跟踪脱敏日志（按 Ctrl+C 退出，不会停止服务）\n'
  printf '  ombrectl configure   修改端口、密码或模型配置\n'
  printf '  ombrectl update      安全更新并在失败时回滚镜像\n'
  printf '\nMCP 地址路径：/mcp（完整地址可在 Dashboard → ⑥ MCP 配置复制）\n'
  printf '记忆永久目录：%s\n' "$DATA_DIR"
}

fail_install_runtime() {
  local message=$1
  if ((ADOPT_CONTAINER)); then
    if ! restore_adoption; then
      warn "旧容器自动恢复失败；备份容器可能仍为 $ADOPT_BACKUP_NAME。请运行：docker ps -a --filter name=$ADOPT_BACKUP_NAME"
    fi
  else
    compose_run down --remove-orphans >/dev/null 2>&1 || true
  fi
  INSTALLED="0"
  write_state || warn "无法把安装状态标记为未完成：$STATE_FILE"
  die "$message。vault 未删除：$DATA_DIR。修复后重新运行：ombrectl install"
}

install_command() {
  local choice keep_password=0 keep_models=0 existing_env="" selected_data
  setup_prompt_fd
  printf '\n%sOmbre Brain 小白一键安装向导%s\n' "$C_BOLD" "$C_RESET"
  printf '  • 一路按 Enter 会采用安全推荐值（默认不暴露公网）\n'
  printf '  • 通常需要 3-10 分钟；源码构建会更久\n'
  printf '  • 安装期间请保持 SSH 连接，不要关闭当前终端\n'
  printf '  • 需要 sudo 时请输入“服务器登录密码”；输入过程不显示字符是正常的\n\n'
  acquire_lock
  detect_platform
  detect_repo_root || true
  if read_state && [[ "$INSTALLED" == "1" ]]; then
    die "已存在 ombrectl 管理的安装。请使用 ombrectl status、update 或 configure。"
  fi
  [[ -f "$ENV_FILE" ]] && existing_env=$ENV_FILE

  menu_choice choice "安装模式" 1 \
    "官方预构建镜像（推荐，最快）" \
    "从源码构建"
  if [[ "$choice" == "2" ]]; then
    MODE="source"
    if [[ -n "$REPO_ROOT" ]]; then
      menu_choice choice "源码位置" 1 \
        "使用当前仓库：$REPO_ROOT" \
        "在 $APP_DIR/source 克隆干净的 main"
      [[ "$choice" == "1" ]] && SOURCE_CHOICE="current" || SOURCE_CHOICE="clone"
    fi
  else
    MODE="image"
  fi

  collect_data_directory "$DATA_DIR"
  collect_port "$PORT" 0
  collect_access_mode 1
  if collect_password 0; then :; fi
  if collect_model_configuration 0; then :; fi
  validate_managed_layout || die "程序、配置和 vault 目录必须是彼此隔离的安全绝对路径。"
  validate_install_targets
  validate_disk_space "$DATA_DIR"
  validate_memory
  info "接下来验证 sudo 权限；若出现 Password，请输入服务器登录密码（屏幕不显示字符是正常现象）。"
  ensure_sudo
  inspect_docker_status
  validate_network_access
  show_install_summary
  confirm "确认执行以上安装吗？" yes || die "已取消，未改动系统。"

  ensure_docker
  ensure_required_tools
  refuse_orphaned_adoption_backup
  if container_exists; then
    selected_data=$DATA_DIR
    probe_existing_container
    if [[ "$DATA_DIR" != "$selected_data" ]]; then
      validate_disk_space "$DATA_DIR"
      show_install_summary
      confirm "接管将改用上面现有容器的数据目录。再次确认继续吗？" no \
        || die "已取消接管，现有容器未改动。"
    fi
  fi
  prepare_directories
  if [[ "$MODE" == "image" ]]; then
    prepare_image_mode
  else
    prepare_source_mode
  fi
  write_environment "$existing_env" "$keep_password" "$keep_models"
  INSTALLED="0"
  write_state
  install_manager_script
  prepare_adoption

  if ! ((DRY_RUN)); then
    compose_run config --quiet || fail_install_runtime "Compose 配置校验失败"
  fi
  if [[ "$MODE" == "image" ]]; then
    compose_run pull ombre-brain || fail_install_runtime "官方镜像拉取失败"
    compose_run up -d --force-recreate ombre-brain || fail_install_runtime "新容器启动失败"
  else
    compose_run build --pull ombre-brain || fail_install_runtime "源码镜像构建失败"
    compose_run up -d --force-recreate --no-build ombre-brain || fail_install_runtime "源码容器启动失败"
  fi
  if ! health_check 120; then
    fail_install_runtime "安装后健康检查失败"
  fi
  INSTALLED="1"
  write_state
  finish_adoption
  post_install_instructions
}

require_installation() {
  read_state || die "未找到安装状态：$STATE_FILE。请先运行 install.sh install。"
  [[ "$INSTALLED" == "1" ]] || die "Ombre Brain 当前标记为未安装，请重新运行 install.sh install。"
  [[ -f "$ENV_FILE" ]] || die "缺少环境文件：$ENV_FILE"
  [[ -f "$COMPOSE_FILE" ]] || die "缺少 Compose 文件：$COMPOSE_FILE"
}

capture_current_image() {
  container_exists || return 1
  "${DOCKER[@]}" inspect --format '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null
}

capture_current_image_ref() {
  container_exists || return 1
  "${DOCKER[@]}" inspect --format '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null
}

source_is_managed_clone() {
  [[ "$(realpath -m -- "$SOURCE_DIR")" == "$(realpath -m -- "$APP_DIR/source")" ]]
}

source_git_run() {
  if source_is_managed_clone; then
    run_root git -C "$SOURCE_DIR" "$@"
  else
    run_cmd git -C "$SOURCE_DIR" "$@"
  fi
}

source_git_capture() {
  if ((DRY_RUN)); then
    return 0
  fi
  if source_is_managed_clone; then
    if ((EUID == 0)); then
      git -C "$SOURCE_DIR" "$@"
    else
      ensure_sudo
      sudo git -C "$SOURCE_DIR" "$@"
    fi
  else
    git -C "$SOURCE_DIR" "$@"
  fi
}

source_git_test() {
  if ((DRY_RUN)); then
    return 0
  fi
  if source_is_managed_clone; then
    if ((EUID == 0)); then
      git -C "$SOURCE_DIR" "$@" >/dev/null 2>&1
    else
      ensure_sudo
      sudo git -C "$SOURCE_DIR" "$@" >/dev/null 2>&1
    fi
  else
    git -C "$SOURCE_DIR" "$@" >/dev/null 2>&1
  fi
}

rollback_runtime() {
  local old_image=$1 image_ref=$2 old_compose=${3-} compose_snapshot_kind=${4:-replace}
  warn "新版本未通过健康检查，开始恢复旧运行镜像。"
  if [[ "$compose_snapshot_kind" == "replace" && -n "$old_compose" && -f "$old_compose" ]]; then
    atomic_install_file "$old_compose" "$COMPOSE_FILE" 0644
  fi
  if [[ -z "$old_image" || -z "$image_ref" ]]; then
    error "没有可用的旧镜像引用，无法自动回滚。vault 仍完整保留。"
    return 1
  fi
  run_cmd "${DOCKER[@]}" image tag "$old_image" "$image_ref"
  if [[ "$compose_snapshot_kind" == "runtime" && -n "$old_compose" && -f "$old_compose" ]]; then
    compose_run_with_file "$old_compose" up -d --force-recreate --no-build ombre-brain
  elif [[ "$MODE" == "source" ]]; then
    compose_run up -d --force-recreate --no-build ombre-brain
  else
    compose_run up -d --force-recreate ombre-brain
  fi
  health_check 90
}

update_command() {
  local old_image="" image_ref="" old_compose="" staged="" rollback_kind="replace"
  require_installation
  acquire_lock
  ensure_docker
  old_image="$(capture_current_image || true)"
  image_ref="$(capture_current_image_ref || true)"
  if [[ -z "$image_ref" || "$image_ref" == *@* || "$image_ref" == sha256:* ]]; then
    image_ref="$(compose_run config --images 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$old_image" && -n "$image_ref" ]]; then
    old_image="$("${DOCKER[@]}" image inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)"
  fi
  [[ -n "$old_image" && -n "$image_ref" ]] \
    || die "无法确定当前运行镜像，不能保证回滚。请先运行：ombrectl start，然后重试更新。"

  if [[ "$MODE" == "image" ]]; then
    make_temp old_compose
    copy_privileged_file "$COMPOSE_FILE" "$old_compose"
    make_temp staged
    if [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/deploy/docker-compose.user.yml" ]]; then
      cp -- "$REPO_ROOT/deploy/docker-compose.user.yml" "$staged"
    else
      download_file "$RAW_BASE_URL/deploy/docker-compose.user.yml" "$staged"
    fi
    if ! ((DRY_RUN)); then
      validate_compose_file "$staged" image || die "更新版 Compose 校验失败。"
    fi
    atomic_install_file "$staged" "$COMPOSE_FILE" 0644
    if ! compose_run config --quiet; then
      atomic_install_file "$old_compose" "$COMPOSE_FILE" 0644
      die "新版 Compose 校验失败，已恢复旧文件。可复制运行：ombrectl doctor"
    fi
    if ! compose_run pull ombre-brain; then
      atomic_install_file "$old_compose" "$COMPOSE_FILE" 0644
      die "新镜像拉取失败，旧容器仍在运行且 Compose 已恢复。可复制重试：ombrectl update"
    fi
    if ! compose_run up -d --force-recreate ombre-brain; then
      rollback_runtime "$old_image" "$image_ref" "$old_compose" replace \
        || die "新容器启动失败且自动回滚失败。请运行：ombrectl logs"
      die "新容器启动失败，已恢复旧运行镜像。"
    fi
  else
    [[ -d "$SOURCE_DIR/.git" ]] || die "源码目录不是 Git 仓库：$SOURCE_DIR"
    [[ -z "$(source_git_capture status --porcelain)" ]] || die "源码工作树有未提交改动。为避免覆盖，更新已停止；请先提交或自行处理。"
    make_temp old_compose
    compose_run config >"$old_compose" \
      || die "无法保存更新前的 Compose 运行快照，更新未开始。请运行：ombrectl doctor"
    rollback_kind="runtime"
    source_git_run fetch origin main \
      || die "Git fetch 失败；旧容器仍在运行。可复制重试：git -C $SOURCE_DIR fetch origin main"
    source_git_test merge-base --is-ancestor HEAD origin/main \
      || die "本地源码与 origin/main 已分叉，拒绝自动合并。"
    source_git_run merge --ff-only origin/main \
      || die "源码无法快进更新；未执行 reset 或 stash，请人工检查：git -C $SOURCE_DIR status"
    compose_run config --quiet \
      || die "更新后的 Compose 无效；源码历史未回滚，旧容器仍在运行。请检查：git -C $SOURCE_DIR show --stat"
    compose_run build --pull ombre-brain \
      || die "新源码镜像构建失败；源码历史未回滚，旧容器仍在运行。修复后重试：ombrectl update"
    if ! compose_run up -d --force-recreate --no-build ombre-brain; then
      rollback_runtime "$old_image" "$image_ref" "$old_compose" runtime \
        || die "源码容器启动失败且旧运行镜像也未恢复。请运行：ombrectl logs"
      die "源码容器启动失败，已恢复旧运行镜像；Git 历史未回滚。"
    fi
  fi

  if ! health_check 120; then
    rollback_runtime "$old_image" "$image_ref" "$old_compose" "$rollback_kind" \
      || die "自动回滚也未恢复健康。请查看 ombrectl logs；vault 位于 $DATA_DIR。"
    die "新版本不健康，已恢复旧运行镜像。源码仓库不会被 reset。"
  fi
  refresh_manager_after_update
  write_state
  success "更新完成。vault 未移动：$DATA_DIR"
}

restore_configuration_snapshot() {
  local old_env=$1 old_state=$2 recreate=${3:-0}
  atomic_install_file "$old_env" "$ENV_FILE" 0600
  atomic_install_file "$old_state" "$STATE_FILE" 0644
  read_state
  if ((recreate)); then
    compose_run config --quiet || return 1
    compose_run up -d --force-recreate ombre-brain || return 1
    health_check 90 || return 1
  fi
}

configure_command() {
  local old_env old_state old_data
  local keep_password=0 keep_models=0 default_access=1 choice new_data
  require_installation
  setup_prompt_fd
  acquire_lock
  detect_platform
  ensure_docker
  make_temp old_env
  make_temp old_state
  copy_privileged_file "$ENV_FILE" "$old_env"
  cp -- "$STATE_FILE" "$old_state"
  old_data=$DATA_DIR

  collect_port "$PORT" 1
  case "$ACCESS_MODE" in
    local) default_access=1 ;;
    lan) default_access=2 ;;
    public_secure) default_access=3 ;;
    advanced) default_access=4 ;;
  esac
  collect_access_mode "$default_access"
  prompt_line new_data "永久记忆目录（留空表示保持）" "$DATA_DIR"
  validate_data_path "$new_data" || die "新的记忆目录不是安全绝对路径。"
  new_data="$(normalize_path "$new_data")"
  if [[ "$new_data" != "$DATA_DIR" ]]; then
    if [[ -e "$new_data" && ( ! -d "$new_data" || ! -r "$new_data" || ! -x "$new_data" ) ]]; then
      die "无法以当前用户安全检查新 vault 目录：$new_data"
    fi
    if directory_has_content "$new_data" && ! looks_like_vault "$new_data"; then
      die "新目录非空且不像 Ombre Brain vault，拒绝切换。"
    fi
    warn "切换数据目录不会复制旧记忆。原目录 $DATA_DIR 将完整保留。"
    confirm "确认改用 $new_data 吗？" no || die "已取消数据目录切换。"
    DATA_DIR=$new_data
  fi

  if collect_password 1; then
    keep_password=0
  else
    case $? in
      2) keep_password=1 ;;
      *) die "密码配置失败。" ;;
    esac
  fi
  if collect_model_configuration 1; then
    keep_models=0
  else
    case $? in
      2) keep_models=1 ;;
      *) die "模型配置失败。" ;;
    esac
  fi

  validate_managed_layout || die "程序、配置和 vault 目录必须保持隔离。"
  validate_disk_space "$DATA_DIR"
  validate_memory
  PREFLIGHT_NETWORK="现有安装，未重新请求外网"
  ensure_sudo
  show_install_summary
  confirm "应用配置并重建容器吗？" yes || die "已取消，现有配置未改动。"
  prepare_reconfigured_data_dir
  if ! write_environment "$ENV_FILE" "$keep_password" "$keep_models"; then
    restore_configuration_snapshot "$old_env" "$old_state" 0 || true
    die "写入新环境文件失败，已恢复旧配置。"
  fi
  if ! write_state; then
    restore_configuration_snapshot "$old_env" "$old_state" 0 || true
    die "写入新安装状态失败，已恢复旧配置。"
  fi
  if ! compose_run config --quiet; then
    restore_configuration_snapshot "$old_env" "$old_state" 0 \
      || die "Compose 校验失败，且旧配置文件恢复失败。vault 仍位于 $old_data。"
    die "新配置未通过 Compose 校验，已恢复旧配置；现有容器未重建。"
  fi
  if ! compose_run up -d --force-recreate ombre-brain; then
    restore_configuration_snapshot "$old_env" "$old_state" 1 \
      || die "新容器启动失败，旧配置恢复后也未能启动。请运行：ombrectl logs"
    die "新容器启动失败，已恢复旧配置和旧运行容器。"
  fi
  if ! health_check 90; then
    warn "新配置不健康，恢复旧环境和状态。"
    restore_configuration_snapshot "$old_env" "$old_state" 1 \
      || die "旧配置恢复后服务仍不健康；请查看 ombrectl logs。"
    die "新配置未生效，已恢复旧配置。"
  fi
  if [[ "$old_data" != "$DATA_DIR" ]]; then
    success "已切换 vault；旧目录仍保留：$old_data"
  fi
  post_install_instructions configure
}

status_command() {
  local health="不可达" version="未知" host body=""
  require_installation
  ensure_docker
  printf '%sOmbre Brain 状态%s\n' "$C_BOLD" "$C_RESET"
  printf '  模式：%s\n  Compose：%s\n  Vault：%s\n  地址：%s:%s\n' \
    "$MODE" "$COMPOSE_FILE" "$DATA_DIR" "$BIND_ADDRESS" "$PORT"
  compose_run ps
  host="$(health_host)"
  body="$(fetch_url "http://$host:$PORT/health" 2>/dev/null || true)"
  if [[ "$body" == *'"status":"ok"'* || "$body" == *'"status": "ok"'* ]]; then
    version="$(fetch_url "http://$host:$PORT/api/version" 2>/dev/null || true)"
    if printf '%s' "$version" | grep -Eq '"version"[[:space:]]*:[[:space:]]*"[^"]+"'; then
      health="正常"
    else
      health="部分异常（版本接口不可用）"
    fi
  fi
  printf '  健康：%s\n  版本：%s\n' "$health" "$version"
}

doctor_command() {
  local failures=0 mount_source="" mode="" perms="" available=""
  local -a repair_hints=()
  require_installation
  detect_platform
  ensure_docker
  info "检查 Compose 配置"
  if ! compose_run config --quiet; then
    error "Compose 配置无效。"
    repair_hints+=("ombrectl configure")
    failures=$((failures + 1))
  fi
  info "检查容器与持久挂载"
  if container_exists; then
    mount_source="$("${DOCKER[@]}" inspect --format '{{range .Mounts}}{{if eq .Destination "/app/buckets"}}{{println .Source}}{{end}}{{end}}' "$CONTAINER_NAME" | head -n1)"
    if [[ "$(realpath -m -- "$mount_source")" != "$(realpath -m -- "$DATA_DIR")" ]]; then
      error "容器挂载 $mount_source 与状态中的 $DATA_DIR 不一致。"
      repair_hints+=("ombrectl status")
      failures=$((failures + 1))
    else
      success "持久挂载一致：$DATA_DIR"
    fi
  else
    error "容器不存在。"
    repair_hints+=("ombrectl start")
    failures=$((failures + 1))
  fi
  if [[ -f "$ENV_FILE" ]]; then
    if command -v stat >/dev/null 2>&1; then
      perms="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || true)"
      [[ "$perms" == "600" ]] || { error "环境文件权限应为 600，当前为 ${perms:-未知}。"; repair_hints+=("sudo chmod 600 $ENV_FILE"); failures=$((failures + 1)); }
    fi
  else
    error "环境文件缺失。"
    repair_hints+=("ombrectl configure")
    failures=$((failures + 1))
  fi
  if [[ ! -d "$DATA_DIR" ]]; then
    error "vault 目录不存在：$DATA_DIR"
    repair_hints+=("检查磁盘挂载或从备份恢复：$DATA_DIR")
    failures=$((failures + 1))
  else
    mode="$(df -PT "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $2}')"
    case "$mode" in
      tmpfs|ramfs|overlay) error "vault 位于 $mode 文件系统，可能不是持久磁盘。"; failures=$((failures + 1)) ;;
      *) success "vault 文件系统：${mode:-未知}" ;;
    esac
    available="$(df -Pm "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
    [[ "$available" =~ ^[0-9]+$ ]] && info "vault 可用空间：${available} MiB"
  fi
  if ! health_check 20; then
    repair_hints+=("ombrectl logs")
    failures=$((failures + 1))
  fi
  if "${DOCKER[@]}" container inspect "$ADOPT_BACKUP_NAME" >/dev/null 2>&1; then
    error "发现未清理的接管备份容器：$ADOPT_BACKUP_NAME"
    repair_hints+=("sudo docker inspect $ADOPT_BACKUP_NAME")
    failures=$((failures + 1))
  fi
  if ((failures)); then
    printf '\n可复制的检查/修复命令：\n' >&2
    printf '  %s\n' "${repair_hints[@]}" >&2
    die "诊断发现 $failures 项问题。"
  fi
  success "诊断全部通过。"
}

logs_command() {
  require_installation
  ensure_docker
  info "正在持续显示脱敏日志；按 Ctrl+C 退出日志查看，不会停止 Ombre Brain。"
  compose_run logs --tail 200 --follow ombre-brain 2>&1 | redact_stream
}

start_command() {
  require_installation
  acquire_lock
  ensure_docker
  if ! compose_run up -d ombre-brain; then
    show_failure_details
    die "启动失败。可复制运行：ombrectl doctor"
  fi
  health_check 90 || die "启动后健康检查失败。"
}

stop_command() {
  require_installation
  acquire_lock
  ensure_docker
  compose_run stop ombre-brain \
    || die "停止失败。请运行：ombrectl status；然后运行：ombrectl logs"
  success "服务已停止；vault 未改动。"
}

restart_command() {
  require_installation
  acquire_lock
  ensure_docker
  if ! compose_run restart ombre-brain; then
    show_failure_details
    die "重启失败。可复制运行：ombrectl doctor"
  fi
  health_check 90 || die "重启后健康检查失败。"
}

safe_remove_app_dir() {
  local resolved marker data_resolved
  resolved="$(realpath -m -- "$APP_DIR")"
  data_resolved="$(realpath -m -- "$DATA_DIR")"
  marker="$resolved/.ombre-installer-managed"
  case "$resolved" in
    /|/opt|/var|/var/lib|/etc|"$data_resolved")
      die "拒绝删除不安全的程序目录：$resolved"
      ;;
  esac
  case "$data_resolved/" in
    "$resolved/"*) die "vault 位于程序目录内部，拒绝卸载以避免删除记忆：$data_resolved" ;;
  esac
  [[ -f "$marker" ]] || die "程序目录缺少 ombrectl 管理标记，拒绝递归删除：$resolved"
  if [[ -d "$resolved/.git" ]] || { [[ "$MODE" == "source" && -n "$SOURCE_DIR" ]] && [[ "$(realpath -m -- "$SOURCE_DIR")" == "$resolved" ]]; }; then
    run_root rm -f -- "$marker"
    warn "程序目录是 Git 源码 checkout，已保留整个仓库：$resolved"
    return 0
  fi
  run_root rm -rf -- "$resolved"
}

uninstall_command() {
  local typed choice link_target="" docker_available=0 offline_cleanup=0
  require_installation
  setup_prompt_fd
  acquire_lock
  ensure_sudo
  if use_existing_docker; then
    docker_available=1
  else
    warn "Docker 当前不可用；卸载器不会为了卸载而重新安装 Docker。"
    menu_choice choice "无法验证或移除现有容器" 1 \
      "停止卸载，先修复 Docker（推荐）" \
      "仅清理本机安装器文件；容器可能仍会运行"
    if [[ "$choice" == "1" ]]; then
      die "请先运行：sudo systemctl start docker && ombrectl uninstall"
    fi
    prompt_line typed "高风险离线清理：请输入 OFFLINE-UNINSTALL" ""
    [[ "$typed" == "OFFLINE-UNINSTALL" ]] || die "确认文字不匹配，已取消。"
    offline_cleanup=1
  fi
  if ((offline_cleanup)); then
    printf '\n将只清理 ombrectl 和受管理的本机文件；无法验证或停止 Docker 容器。\n'
  else
    printf '\n将停止并移除 Ombre Brain 容器和受管理的程序文件。\n'
  fi
  printf 'vault 永久保留：%s\n' "$DATA_DIR"
  printf '不会执行 docker compose down -v，也不会删除任何记忆。\n'
  prompt_line typed "请输入 UNINSTALL 确认" ""
  [[ "$typed" == "UNINSTALL" ]] || die "确认文字不匹配，已取消。"
  menu_choice choice "密钥配置如何处理" 1 \
    "保留 /etc/ombre-brain，便于重装（推荐）" \
    "删除 /etc 中的环境密钥；保留无密钥恢复状态"

  if ((docker_available)); then
    compose_run down --remove-orphans \
      || die "容器移除失败，已停止卸载以保留恢复文件。请运行：ombrectl doctor"
  fi
  if [[ -L "$BIN_LINK" ]]; then
    link_target="$(readlink "$BIN_LINK" || true)"
    if [[ "$link_target" == "$APP_DIR/install.sh" ]]; then
      run_root rm -f -- "$BIN_LINK"
    else
      warn "$BIN_LINK 指向未知目标，未删除。"
    fi
  fi
  INSTALLED="0"
  write_state
  if [[ "$choice" == "2" ]]; then
    run_root rm -f -- "$ENV_FILE"
  fi
  safe_remove_app_dir
  if ((offline_cleanup)); then
    warn "安装器文件已清理，但由于 Docker 不可用，容器状态未经验证。"
    warn "Docker 修复后请运行：sudo docker inspect $CONTAINER_NAME && sudo docker rm -f $CONTAINER_NAME"
    success "vault 仍完整保留：$DATA_DIR"
  else
    success "运行环境已卸载。vault 仍完整保留：$DATA_DIR"
  fi
  if [[ "$choice" == "1" ]]; then
    info "配置仍保留：$CONFIG_DIR"
  else
    info "环境密钥已移除；无密钥恢复状态保留在：$STATE_FILE"
  fi
}

interactive_operations_menu() {
  local choice
  setup_prompt_fd
  menu_choice choice "Ombre Brain 运维菜单" 1 \
    "查看状态" \
    "更新" \
    "重新配置" \
    "完整诊断" \
    "查看日志" \
    "重启" \
    "停止" \
    "启动" \
    "安全卸载"
  case "$choice" in
    1) status_command ;;
    2) update_command ;;
    3) configure_command ;;
    4) doctor_command ;;
    5) logs_command ;;
    6) restart_command ;;
    7) stop_command ;;
    8) start_command ;;
    9) uninstall_command ;;
  esac
}

show_help() {
  cat <<'HELP'
Ombre Brain 一键安装器 / 生命周期管理器

用法：
  bash install.sh [--dry-run] [命令]
  ombrectl [--dry-run] [命令]

命令：
  install      交互式首次安装（默认预构建镜像）
  update       更新镜像或源码，健康失败时回滚运行镜像
  configure    修改端口、访问方式、密码、vault 或模型配置
  status       显示容器、版本和健康状态
  doctor       检查 Compose、权限、持久挂载、磁盘和健康
  logs         跟踪脱敏容器日志
  start        启动服务并检查健康
  stop         停止服务，不删除容器或数据
  restart      重启服务并检查健康
  uninstall    移除运行环境；永不删除 vault
  help         显示本帮助

选项：
  --dry-run    展示将执行的系统命令，不写系统目录、不启动容器
  -h, --help   显示本帮助

默认目录：
  /opt/ombre-brain       程序和 Compose
  /etc/ombre-brain       密钥和安装状态
  /var/lib/ombre-brain   永久记忆 vault
HELP
}

main() {
  local command="" arg
  local -a positional=()
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      -h|--help) show_help; return 0 ;;
      *) positional+=("$arg") ;;
    esac
  done
  ((${#positional[@]} <= 1)) || die "一次只能执行一个命令。"
  command=${positional[0]:-}
  detect_repo_root || true
  if [[ -z "$command" ]]; then
    if read_state && [[ "$INSTALLED" == "1" ]]; then
      interactive_operations_menu
    else
      install_command
    fi
    return 0
  fi
  case "$command" in
    install) install_command ;;
    update) update_command ;;
    configure|config) configure_command ;;
    status) status_command ;;
    doctor) doctor_command ;;
    logs) logs_command ;;
    start) start_command ;;
    stop) stop_command ;;
    restart) restart_command ;;
    uninstall) uninstall_command ;;
    help) show_help ;;
    *) die "未知命令：$command。运行 install.sh help 查看用法。" ;;
  esac
}

if [[ "${OMBRE_INSTALLER_LIBRARY:-0}" != "1" ]]; then
  main "$@"
fi
