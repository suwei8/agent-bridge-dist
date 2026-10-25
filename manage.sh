#!/bin/bash

set -u
set -o pipefail

# AgentBridge 管理脚本
# 功能: 部署、启动、停止、重启、查看日志

DISPLAY_NAME="AgentBridge"
case "$(uname -m)" in
    x86_64|amd64) APP_NAME="agent-bridge-linux-amd64" ;;
    *)            APP_NAME="agent-bridge" ;;
esac
LEGACY_APP_NAME="antigravity-bridge"
LEGACY_DIR_NAME="antigravity-Bridge"
REPO="suwei8/agent-bridge-dist"
LOG_FILE_NAME="app.log"
PID_FILE_NAME="app.pid"
RELEASE_TAG_FILE_NAME=".agentbridge-release-tag"
LEGACY_RELEASE_TAG_FILE_NAME=".antigravity-release-tag"
MCP_SERVER_NAME="agent-bridge"
MANAGE_SCRIPT_NAME="manage.sh"
MANAGE_SCRIPT_API_URL="https://api.github.com/repos/${REPO}/contents/${MANAGE_SCRIPT_NAME}"
DEFAULT_TELEGRAM_CHAT_IDS="1118793113,8415850251"
EMBEDDED_GITHUB_TOKEN=""
MIN_ROOT_FREE_MB="${MIN_ROOT_FREE_MB:-512}"
MIN_TMP_FREE_MB="${MIN_TMP_FREE_MB:-512}"
STALE_MEI_MAX_AGE_MINUTES="${STALE_MEI_MAX_AGE_MINUTES:-1440}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR"
APP_PATH="$INSTALL_DIR/$APP_NAME"
LEGACY_APP_PATH="$INSTALL_DIR/$LEGACY_APP_NAME"
LEGACY_DIR_PATH="$INSTALL_DIR/$LEGACY_DIR_NAME"
LOG_FILE="$INSTALL_DIR/$LOG_FILE_NAME"
PID_FILE="$INSTALL_DIR/$PID_FILE_NAME"
ENV_FILE="$INSTALL_DIR/.env"
RELEASE_TAG_FILE="$INSTALL_DIR/$RELEASE_TAG_FILE_NAME"
LEGACY_RELEASE_TAG_FILE="$INSTALL_DIR/$LEGACY_RELEASE_TAG_FILE_NAME"
GITHUB_TOKEN_ENV_FILE="$INSTALL_DIR/.agentbridge-github.env"
MANAGE_SCRIPT_PATH="$INSTALL_DIR/$MANAGE_SCRIPT_NAME"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

LATEST_RELEASE_JSON=""
EXCLUDED_PIDS=""

info() {
    echo -e "${GREEN}[INFO] $1${NC}" >&2
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}" >&2
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

append_result_note() {
    local note="$1"
    local result_notes_file="${RESULT_NOTES_FILE:-${RESULT_NOTES:-}}"

    if [ -z "$result_notes_file" ]; then
        return 0
    fi

    if [ -d "$result_notes_file" ]; then
        return 0
    fi

    if [ -e "$result_notes_file" ] || [ -d "$(dirname "$result_notes_file")" ]; then
        printf '%s\n' "$note" >> "$result_notes_file" 2>/dev/null || true
    fi
}

load_env_file() {
    local file="$1"
    if [ -f "$file" ]; then
        set -a
        # shellcheck disable=SC1090
        source "$file"
        set +a
        return 0
    fi
    return 1
}

resolve_github_token() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        return 0
    fi

    local candidate=""
    for candidate in \
        "$GITHUB_TOKEN_ENV_FILE" \
        "$HOME/.agentbridge-github.env" \
        "$HOME/.config/agentbridge/github.env" \
        "$ENV_FILE" \
        "$HOME/dev_root/agent-bridge/.env"; do
        if load_env_file "$candidate" && [ -n "${GITHUB_TOKEN:-}" ]; then
            info "已从 $(basename "$candidate") 加载 GITHUB_TOKEN"
            return 0
        fi
    done

    warn "未找到 GITHUB_TOKEN，将以匿名方式访问公开 Release（存在限流）"
    return 0
}

github_api_curl() {
    local accept_header="$1"
    shift
    local common_args=(
        -H "Accept: ${accept_header}"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        local curl_status=0
        if curl -fsSL --retry 3 --connect-timeout 10 \
            "${common_args[@]}" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            "$@"; then
            return 0
        else
            curl_status=$?
        fi

        # curl exit code 22 means an HTTP error response. For this public
        # distribution repository, retry anonymously in case the token is
        # stale, revoked, or lacks access. Do not retry transport failures.
        if [ "$curl_status" -ne 22 ]; then
            return "$curl_status"
        fi
        warn "带 GITHUB_TOKEN 的 GitHub 请求收到 HTTP 错误，正在重试匿名访问公开资源..."
    fi

    curl -fsSL --retry 3 --connect-timeout 10 \
        "${common_args[@]}" \
        "$@"
}

mb_to_kb() {
    local mb="$1"
    echo $((mb * 1024))
}

is_dir_in_use() {
    local dir="$1"
    local fd_path=""
    local target=""

    for fd_path in /proc/[0-9]*/fd/*; do
        if [ ! -e "$fd_path" ]; then
            continue
        fi
        target="$(readlink "$fd_path" 2>/dev/null || true)"
        case "$target" in
            "$dir"|"$dir"/*)
                return 0
                ;;
        esac
    done

    return 1
}

cleanup_stale_mei_dirs() {
    local found_any=0
    local mei_dir=""

    if [ ! -d /tmp ]; then
        return 0
    fi

    while IFS= read -r mei_dir; do
        if [ -z "$mei_dir" ]; then
            continue
        fi
        found_any=1
        if is_dir_in_use "$mei_dir"; then
            warn "跳过仍被进程占用的 PyInstaller 临时目录: $mei_dir"
            continue
        fi
        warn "清理老旧 PyInstaller 临时目录: $mei_dir"
        rm -rf "$mei_dir" 2>/dev/null || warn "清理失败: $mei_dir"
    done <<EOF
$(find /tmp -maxdepth 1 -mindepth 1 -type d -name '_MEI*' -mmin +"$STALE_MEI_MAX_AGE_MINUTES" 2>/dev/null | sort)
EOF

    if [ "$found_any" -eq 0 ]; then
        info "未发现超过 ${STALE_MEI_MAX_AGE_MINUTES} 分钟的 /tmp/_MEI* 残留"
    fi
}

check_disk_space() {
    local root_free_kb=""
    local tmp_free_kb=""
    local min_root_kb=""
    local min_tmp_kb=""

    info "磁盘空间检查:"
    df -h / /tmp 2>/dev/null || true

    cleanup_stale_mei_dirs

    info "清理后磁盘检查:"
    df -h / /tmp 2>/dev/null || true

    root_free_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 { print $4 }')"
    tmp_free_kb="$(df -Pk /tmp 2>/dev/null | awk 'NR==2 { print $4 }')"
    min_root_kb="$(mb_to_kb "$MIN_ROOT_FREE_MB")"
    min_tmp_kb="$(mb_to_kb "$MIN_TMP_FREE_MB")"

    if [ -z "$root_free_kb" ] || [ -z "$tmp_free_kb" ]; then
        error "无法读取 / 或 /tmp 的剩余空间"
        return 1
    fi

    if [ "$root_free_kb" -lt "$min_root_kb" ] || [ "$tmp_free_kb" -lt "$min_tmp_kb" ]; then
        append_result_note "disk full"
        error "磁盘空间不足: / 至少需要 ${MIN_ROOT_FREE_MB}MB，/tmp 至少需要 ${MIN_TMP_FREE_MB}MB 可用空间"
        error "请先清理磁盘后重试"
        return 1
    fi

    return 0
}

check_dependencies() {
    info "检查系统依赖..."
    local cmds=("curl" "python3")
    local pkgs=("python3-dev")
    local install_needed=0
    local install_list=""
    local cmd=""
    local pkg=""

    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "命令 $cmd 未安装"
            install_needed=1
            install_list="$install_list $cmd"
        fi
    done

    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            echo "包 $pkg 未安装"
            install_needed=1
            install_list="$install_list $pkg"
        fi
    done

    if [ "$install_needed" -eq 1 ]; then
        info "正在安装缺失的依赖 (需要 sudo 权限)..."
        info "安装列表:${install_list}"
        sudo apt-get update
        sudo apt-get install -y $install_list
    else
        info "所有依赖已安装。"
    fi
}

fetch_latest_release_json() {
    if [ -n "$LATEST_RELEASE_JSON" ]; then
        return 0
    fi

    resolve_github_token || return 1

    LATEST_RELEASE_JSON="$(github_api_curl "application/vnd.github+json" "https://api.github.com/repos/${REPO}/releases/latest")" || {
        error "获取 Latest Release 失败，请检查仓库权限、GITHUB_TOKEN 或网络"
        return 1
    }
}

parse_release_field() {
    local field_name="$1"
    python3 -c '
import json
import sys

field = sys.argv[1]
data = json.load(sys.stdin)
value = data.get(field, "")
if isinstance(value, str):
    print(value)
' "$field_name"
}

find_asset_id() {
    local asset_name="$1"
    python3 -c '
import json
import sys

asset_name = sys.argv[1]
data = json.load(sys.stdin)
for asset in data.get("assets", []):
    if asset.get("name") == asset_name:
        print(asset.get("id", ""))
        break
' "$asset_name"
}

download_release_asset() {
    local asset_name="$1"
    local dest_file="$2"
    local asset_id=""

    fetch_latest_release_json || return 1

    asset_id="$(printf '%s\n' "$LATEST_RELEASE_JSON" | find_asset_id "$asset_name")"
    if [ -z "$asset_id" ]; then
        return 1
    fi

    github_api_curl "application/octet-stream" \
        -o "$dest_file" \
        "https://api.github.com/repos/${REPO}/releases/assets/${asset_id}"
}

verify_download_checksum() {
    local asset_name="$1"
    local target_file="$2"
    local checksum_tmp="${target_file}.sha256"
    local expected=""
    local actual=""

    rm -f "$checksum_tmp"
    if ! download_release_asset "${asset_name}.sha256" "$checksum_tmp"; then
        warn "未找到 ${asset_name}.sha256，跳过校验"
        return 0
    fi

    expected="$(awk 'NF { print $1; exit }' "$checksum_tmp")"
    actual="$(sha256sum "$target_file" | awk '{print $1}')"
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        rm -f "$checksum_tmp"
        error "SHA256 校验失败: $asset_name"
        return 1
    fi

    rm -f "$checksum_tmp"
    return 0
}

get_latest_release_tag() {
    fetch_latest_release_json || return 1
    printf '%s\n' "$LATEST_RELEASE_JSON" | parse_release_field "tag_name"
}

get_local_release_tag() {
    if [ -f "$RELEASE_TAG_FILE" ]; then
        cat "$RELEASE_TAG_FILE"
    fi
}

download_latest_binary() {
    local tmp_file="$1"
    local latest_tag=""

    latest_tag="$(get_latest_release_tag)"
    if [ -n "$latest_tag" ]; then
        info "Latest Release tag: $latest_tag"
    else
        error "未能解析 Latest Release tag"
        return 1
    fi

    info "正在从 GitHub Releases 下载二进制..."
    if ! download_release_asset "$APP_NAME" "$tmp_file"; then
        error "Latest Release 中未找到 $APP_NAME"
        return 1
    fi
    info "已下载发布资产: $APP_NAME (tag: $latest_tag)"

    verify_download_checksum "$APP_NAME" "$tmp_file" || return 1
    printf '%s\n' "$latest_tag" > "$RELEASE_TAG_FILE"
    return 0
}

refresh_manage_script() {
    local tmp_file="${MANAGE_SCRIPT_PATH}.tmp"

    info "开始原子更新 ${MANAGE_SCRIPT_PATH} ..."
    resolve_github_token || return 1
    rm -f "$tmp_file"

    if ! github_api_curl "application/vnd.github.raw+json" \
        -o "$tmp_file" \
        "$MANAGE_SCRIPT_API_URL"; then
        error "下载 ${MANAGE_SCRIPT_NAME} 失败"
        rm -f "$tmp_file"
        return 1
    fi

    if [ ! -s "$tmp_file" ]; then
        append_result_note "manage.sh download failed"
        error "下载得到的 ${MANAGE_SCRIPT_NAME} 为空，已放弃覆盖旧文件"
        rm -f "$tmp_file"
        return 1
    fi

    if ! bash -n "$tmp_file"; then
        append_result_note "manage.sh syntax check failed"
        error "${MANAGE_SCRIPT_NAME} 语法校验失败，已保留旧文件"
        rm -f "$tmp_file"
        return 1
    fi

    chmod +x "$tmp_file" || {
        error "无法设置 ${tmp_file} 为可执行"
        rm -f "$tmp_file"
        return 1
    }

    mv -f "$tmp_file" "$MANAGE_SCRIPT_PATH" || {
        error "替换 ${MANAGE_SCRIPT_PATH} 失败"
        rm -f "$tmp_file"
        return 1
    }

    info "${MANAGE_SCRIPT_PATH} 更新完成"
    return 0
}

find_matching_pids() {
    local mode="$1"
    local excluded_pids=""
    excluded_pids="$(get_excluded_pids)"
    ps -eo pid=,args= | awk -v mode="$mode" \
        -v excluded="$excluded_pids" \
        -v app_path="$APP_PATH" \
        -v app_name="$APP_NAME" \
        -v legacy_app_path="$LEGACY_APP_PATH" \
        -v legacy_app_name="$LEGACY_APP_NAME" \
        -v legacy_dir="$LEGACY_DIR_PATH" '
        {
            pid=$1
            $1=""
            gsub(/^ +/, "", $0)

            if (index(excluded, " " pid " ") > 0) {
                next
            }
            if (index($0, "manage.sh") > 0 || index($0, "ps -eo pid=,args=") > 0) {
                next
            }

            current_match = (index($0, app_path) > 0) || ($0 ~ ("(^|[[:space:]/.])" app_name "([[:space:]]|$)"))
            legacy_match = (index($0, legacy_app_path) > 0) || (index($0, legacy_dir) > 0) || ($0 ~ ("(^|[[:space:]/.])" legacy_app_name "([[:space:]]|$)"))

            if ((mode == "current" && current_match) || (mode == "legacy" && legacy_match)) {
                print pid
            }
        }'
}

get_excluded_pids() {
    if [ -n "$EXCLUDED_PIDS" ]; then
        printf '%s\n' "$EXCLUDED_PIDS"
        return 0
    fi

    local current_pid="$$"
    local ppid=""
    local chain=" "

    while [ -n "$current_pid" ] && [ "$current_pid" -gt 1 ] 2>/dev/null; do
        chain="${chain}${current_pid} "
        ppid="$(ps -o ppid= -p "$current_pid" 2>/dev/null | tr -d ' ')"
        if [ -z "$ppid" ] || [ "$ppid" = "$current_pid" ]; then
            break
        fi
        current_pid="$ppid"
    done

    EXCLUDED_PIDS="$chain"
    printf '%s\n' "$EXCLUDED_PIDS"
}

kill_pid_group() {
    local pids="$1"
    local label="$2"
    local signal="$3"

    if [ -z "$pids" ]; then
        return 0
    fi

    info "发送 ${signal} 到 ${label} 进程: $(echo "$pids" | tr '\n' ' ')"
    echo "$pids" | xargs -r kill "$signal" 2>/dev/null || true
}

resolve_app_path() {
    if [ -f "$APP_PATH" ]; then
        echo "$APP_PATH"
        return 0
    fi
    return 1
}

setup_env() {
    # GUI 模式已移除，无需配置 X11 DISPLAY
    info "跳过 X11 环境配置（CLI 模式无需 DISPLAY）"
}

ensure_env_file() {
    upsert_env_value() {
        local key="$1"
        local value="$2"
        local escaped_value=""
        escaped_value="$(printf '%s' "$value" | sed 's/[&|]/\\&/g')"

        if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
            sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$ENV_FILE"
        else
            printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
        fi
    }

    prompt_required_value() {
        local prompt_text="$1"
        local default_value="$2"
        local answer=""
        while true; do
            if [ -n "$default_value" ]; then
                read -r -p "$prompt_text [$default_value]: " answer
                answer="${answer:-$default_value}"
            else
                read -r -p "$prompt_text: " answer
            fi
            if [ -n "$answer" ]; then
                printf '%s\n' "$answer"
                return 0
            fi
            warn "该项不能为空。"
        done
    }

    configure_env_interactive() {
        local existing_notice="$1"
        local telegram_token="${TELEGRAM_BOT_TOKEN:-}"

        info "$existing_notice"
        telegram_token="$(prompt_required_value "请输入 TELEGRAM_BOT_TOKEN" "$telegram_token")"

        touch "$ENV_FILE"
        upsert_env_value "TELEGRAM_BOT_TOKEN" "$telegram_token"
        upsert_env_value "TELEGRAM_CHAT_ID" "${TELEGRAM_CHAT_ID:-$DEFAULT_TELEGRAM_CHAT_IDS}"
        upsert_env_value "DEFAULT_MODE" "${DEFAULT_MODE:-CLI}"
        upsert_env_value "DEFAULT_CLI_PROFILE" "${DEFAULT_CLI_PROFILE:-devin_cli}"
        upsert_env_value "CODEX_COMMAND" "${CODEX_COMMAND:-$(command -v codex 2>/dev/null || echo codex)}"
        upsert_env_value "CLAUDE_COMMAND" "${CLAUDE_COMMAND:-$(command -v claude 2>/dev/null || echo claude)}"
        upsert_env_value "KILO_COMMAND" "${KILO_COMMAND:-$(command -v kilo 2>/dev/null || echo kilo)}"
        upsert_env_value "OPENCODE_COMMAND" "${OPENCODE_COMMAND:-$(command -v opencode 2>/dev/null || echo opencode)}"
        upsert_env_value "DEVIN_COMMAND" "${DEVIN_COMMAND:-$(command -v devin 2>/dev/null || echo devin)}"
        upsert_env_value "CLINE_COMMAND" "${CLINE_COMMAND:-$(command -v cline 2>/dev/null || echo cline)}"
        upsert_env_value "CLI_CWD" "${CLI_CWD:-/home/sw/dev_root/}"
        upsert_env_value "CLI_EXEC_MODE" "${CLI_EXEC_MODE:-YOLO}"
        upsert_env_value "CLI_HEARTBEAT_SECONDS" "${CLI_HEARTBEAT_SECONDS:-15}"
        info ".env 配置文件已写入: $ENV_FILE"
        load_env_file "$ENV_FILE"
        return 0
    }

    if [ -f "$ENV_FILE" ]; then
        load_env_file "$ENV_FILE"
        if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
            upsert_env_value "TELEGRAM_CHAT_ID" "${TELEGRAM_CHAT_ID:-$DEFAULT_TELEGRAM_CHAT_IDS}"
            upsert_env_value "DEFAULT_MODE" "${DEFAULT_MODE:-CLI}"
            upsert_env_value "DEFAULT_CLI_PROFILE" "${DEFAULT_CLI_PROFILE:-devin_cli}"
            upsert_env_value "CODEX_COMMAND" "${CODEX_COMMAND:-$(command -v codex 2>/dev/null || echo codex)}"
            upsert_env_value "CLAUDE_COMMAND" "${CLAUDE_COMMAND:-$(command -v claude 2>/dev/null || echo claude)}"
            upsert_env_value "KILO_COMMAND" "${KILO_COMMAND:-$(command -v kilo 2>/dev/null || echo kilo)}"
            upsert_env_value "OPENCODE_COMMAND" "${OPENCODE_COMMAND:-$(command -v opencode 2>/dev/null || echo opencode)}"
            upsert_env_value "DEVIN_COMMAND" "${DEVIN_COMMAND:-$(command -v devin 2>/dev/null || echo devin)}"
            upsert_env_value "CLINE_COMMAND" "${CLINE_COMMAND:-$(command -v cline 2>/dev/null || echo cline)}"
            upsert_env_value "CLI_CWD" "${CLI_CWD:-/home/sw/dev_root/}"
            upsert_env_value "CLI_EXEC_MODE" "${CLI_EXEC_MODE:-YOLO}"
            upsert_env_value "CLI_HEARTBEAT_SECONDS" "${CLI_HEARTBEAT_SECONDS:-15}"
            info "检测到现有 .env 配置文件"
            load_env_file "$ENV_FILE"
            return 0
        fi
        if [ -t 0 ]; then
            configure_env_interactive "检测到现有 .env，但缺少 TELEGRAM_BOT_TOKEN，开始补齐配置"
            return 0
        fi
        warn "检测到现有 .env，但缺少 TELEGRAM_BOT_TOKEN"
        return 1
    fi

    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
        cat > "$ENV_FILE" <<EOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-$DEFAULT_TELEGRAM_CHAT_IDS}
DEFAULT_MODE=${DEFAULT_MODE:-CLI}
DEFAULT_CLI_PROFILE=${DEFAULT_CLI_PROFILE:-devin_cli}
CODEX_COMMAND=${CODEX_COMMAND:-$(command -v codex 2>/dev/null || echo codex)}
CLAUDE_COMMAND=${CLAUDE_COMMAND:-$(command -v claude 2>/dev/null || echo claude)}
KILO_COMMAND=${KILO_COMMAND:-$(command -v kilo 2>/dev/null || echo kilo)}
OPENCODE_COMMAND=${OPENCODE_COMMAND:-$(command -v opencode 2>/dev/null || echo opencode)}
DEVIN_COMMAND=${DEVIN_COMMAND:-$(command -v devin 2>/dev/null || echo devin)}
CLINE_COMMAND=${CLINE_COMMAND:-$(command -v cline 2>/dev/null || echo cline)}
CLI_CWD=${CLI_CWD:-/home/sw/dev_root/}
CLI_EXEC_MODE=${CLI_EXEC_MODE:-YOLO}
CLI_HEARTBEAT_SECONDS=${CLI_HEARTBEAT_SECONDS:-15}
EOF
        info ".env 配置文件已根据当前环境变量创建"
        load_env_file "$ENV_FILE"
        return 0
    fi

    if [ -t 0 ]; then
        configure_env_interactive "未检测到 .env，开始首次部署交互配置"
        return 0
    fi

    warn "未检测到 $ENV_FILE，且当前不是交互环境。请先创建 .env，或在交互终端执行 deploy。"
    return 1
}

cleanup_legacy_artifacts() {
    info "清理旧版 antigravity 部署残留..."
    rm -rf "$LEGACY_DIR_PATH"
    rm -f "$LEGACY_APP_PATH"
    rm -f "$LEGACY_RELEASE_TAG_FILE"
}

deploy() {
    info "开始部署..."
    cd "$INSTALL_DIR" || return 1
    check_disk_space || return 1
    check_dependencies

    local tmp_file="${APP_PATH}.tmp"

    if download_latest_binary "$tmp_file"; then
        chmod +x "$tmp_file"
        info "正在停止旧版本进程..."
        stop
        cleanup_legacy_artifacts
        mv -f "$tmp_file" "$APP_PATH"
        info "二进制部署成功: $APP_PATH"

        if ensure_env_file; then
            setup_env
        fi

        info "部署完成！可以使用 '$APP_PATH' 或 'bash $0 start' 启动。"
    else
        error "下载失败，请检查 GITHUB_TOKEN、网络或 Release 资产"
        rm -f "$tmp_file"
        return 1
    fi
}

update() {
    info "开始更新到最新版本..."
    check_disk_space || return 1
    refresh_manage_script || return 1
    deploy && start
}

start() {
    cd "$INSTALL_DIR" || return 1
    check_disk_space || return 1

    if [ -f "$PID_FILE" ]; then
        if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            error "程序已在运行中 (PID: $(cat "$PID_FILE"))"
            return 1
        fi
        rm -f "$PID_FILE"
    fi

    local current_pids=""
    local legacy_pids=""
    current_pids="$(find_matching_pids current)"
    legacy_pids="$(find_matching_pids legacy)"

    if [ -n "$current_pids" ] || [ -n "$legacy_pids" ]; then
        info "检测到残留进程，先执行停止..."
        stop
    fi

    if [ ! -f "$APP_PATH" ]; then
        error "未找到可执行文件 $APP_PATH，请先执行 deploy"
        return 1
    fi

    if [ ! -f "$ENV_FILE" ]; then
        error "未找到 $ENV_FILE，请先创建配置后再启动"
        return 1
    fi

    load_env_file "$ENV_FILE"
    setup_env

    # Clear stale PyInstaller runtime variables inherited from parent shells.
    unset _PYI_APPLICATION_HOME_DIR
    unset _PYI_ARCHIVE_FILE
    unset _PYI_PARENT_PROCESS_LEVEL
    unset _PYI_LINUX_PROCESS_NAME
    unset _PYI_SPLASH_IPC
    unset LD_LIBRARY_PATH
    unset CLAUDE_BASE_URL CLAUDE_AUTH_TOKEN CLAUDE_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY

    local local_tag=""
    local_tag="$(get_local_release_tag)"
    if [ -n "$local_tag" ]; then
        info "准备启动版本 tag: $local_tag"
    fi

    info "正在启动 $APP_PATH ..."
    setsid "$APP_PATH" > "$LOG_FILE" 2>&1 < /dev/null &
    echo $! > "$PID_FILE"
    info "启动成功! PID: $(cat "$PID_FILE")"
    info "日志输出到 $LOG_FILE"

    sleep 2
    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "运行状态: 正常"
    else
        error "启动失败，请检查日志:"
        cat "$LOG_FILE"
        return 1
    fi
}

stop() {
    cd "$INSTALL_DIR" || return 1

    info "正在停止所有相关进程..."
    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE")"
        info "正在停止主程序 (PID: $pid)..."
        kill "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi

    local current_pids=""
    local legacy_pids=""
    current_pids="$(find_matching_pids current)"
    legacy_pids="$(find_matching_pids legacy)"

    kill_pid_group "$current_pids" "agent-bridge" "-TERM"
    kill_pid_group "$legacy_pids" "antigravity-bridge" "-TERM"
    sleep 1

    current_pids="$(find_matching_pids current)"
    legacy_pids="$(find_matching_pids legacy)"
    kill_pid_group "$current_pids" "agent-bridge" "-KILL"
    kill_pid_group "$legacy_pids" "antigravity-bridge" "-KILL"
    sleep 1

    current_pids="$(find_matching_pids current)"
    legacy_pids="$(find_matching_pids legacy)"
    if [ -n "$current_pids" ] || [ -n "$legacy_pids" ]; then
        error "警告：仍有进程未能正常退出，请手动检查"
        return 1
    fi

    info "程序已停止。"
}

restart() {
    stop
    sleep 1
    start
}

logs() {
    if [ ! -f "$LOG_FILE" ]; then
        error "日志文件不存在: $LOG_FILE"
        return 1
    fi
    info "正在查看日志 (Ctrl+C 退出)..."
    tail -f "$LOG_FILE"
}

switch_mode() {
    cd "$INSTALL_DIR" || return 1

    if [ ! -f "$ENV_FILE" ]; then
        error "未找到 $ENV_FILE，请先执行部署或手动创建。"
        return 1
    fi

    echo "=========================================="
    echo "请选择默认 CLI 档位:"
    echo "1) OpenCode · free"
    echo "2) Codex CLI · GPT-5.4"
    echo "3) Claude CLI · Opus"
    echo "4) Claude CLI · Sonnet"
    echo "5) Devin CLI · swe-2"
    echo "6) Cline CLI · glm-5.3-flash"
    echo "7) Kilo CLI · free"
    echo "=========================================="
    read -r -p "请输入选项 [1-7, 默认 5]: " profile_choice

    local default_profile="devin_cli"
    case "${profile_choice:-5}" in
        1) default_profile="opencode_free" ;;
        2) default_profile="codex_gpt_5_4" ;;
        3) default_profile="claude_opus" ;;
        4) default_profile="claude_sonnet" ;;
        6) default_profile="cline_cli" ;;
        7) default_profile="kilo_cpa" ;;
        *) default_profile="devin_cli" ;;
    esac

    local codex_cmd="${CODEX_COMMAND:-codex}"
    local claude_cmd="${CLAUDE_COMMAND:-claude}"
    local full_path=""

    full_path="$(which "$codex_cmd" 2>/dev/null || true)"
    if [ -n "$full_path" ]; then
        codex_cmd="$full_path"
        info "已解析 Codex 命令绝对路径: $codex_cmd"
    else
        warn "未解析到 Codex 命令 $codex_cmd，如运行失败请改为绝对路径"
    fi

    full_path="$(which "$claude_cmd" 2>/dev/null || true)"
    if [ -n "$full_path" ]; then
        claude_cmd="$full_path"
        info "已解析 Claude 命令绝对路径: $claude_cmd"
    else
        warn "未解析到 Claude 命令 $claude_cmd，如运行失败请改为绝对路径"
    fi

    sed -i '/^DEFAULT_CLI_PROFILE=/d' "$ENV_FILE" 2>/dev/null || true
    sed -i '/^CODEX_COMMAND=/d' "$ENV_FILE" 2>/dev/null || true
    sed -i '/^CLAUDE_COMMAND=/d' "$ENV_FILE" 2>/dev/null || true
    sed -i '/^CLI_COMMAND=/d' "$ENV_FILE" 2>/dev/null || true
    echo "DEFAULT_CLI_PROFILE=$default_profile" >> "$ENV_FILE"
    echo "CODEX_COMMAND=$codex_cmd" >> "$ENV_FILE"
    echo "CLAUDE_COMMAND=$claude_cmd" >> "$ENV_FILE"

    sed -i '/^DEFAULT_MODE=/d' "$ENV_FILE" 2>/dev/null || true
    echo "DEFAULT_MODE=CLI" >> "$ENV_FILE"

    info "已将默认工作模式切换为: CLI，默认档位: $default_profile"
    info "提示: 需要重启服务才能应用新的默认模式"
}

case "${1:-}" in
    deploy)
        deploy
        ;;
    update)
        update
        ;;
    refresh_script)
        check_disk_space && refresh_manage_script
        ;;
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    logs)
        logs
        ;;
    switch_mode)
        switch_mode
        ;;
    *)
        echo "=========================================="
        echo "   AgentBridge 管理脚本"
        echo "=========================================="
        echo "1. 部署 (Deploy)"
        echo "2. 启动 (Start)"
        echo "3. 停止 (Stop)"
        echo "4. 重启 (Restart)"
        echo "5. 查看日志 (Logs)"
        echo "6. 更新 (Update)"
        echo "7. 切换模式 (Switch Mode)"
        echo "8. 更新管理脚本 (Refresh Script)"
        echo "0. 退出 (Exit)"
        echo "=========================================="
        read -r -p "请输入选项 [0-8]: " choice

        case "$choice" in
            1) deploy ;;
            2) start ;;
            3) stop ;;
            4) restart ;;
            5) logs ;;
            6) update ;;
            7) switch_mode ;;
            8) check_disk_space && refresh_manage_script ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
        ;;
esac
