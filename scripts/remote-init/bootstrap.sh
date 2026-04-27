#!/bin/bash
# FRP Tunnel Remote Host Bootstrap Script
# 初始化遠端主機環境，然後執行 server 安裝腳本

# 調試模式：取消註釋以下行來啟用
# set -x
set -euo pipefail

# ============================================
# 配置
# ============================================

# 服務配置 (可透過環境變量傳入)
FRP_DOMAIN="${FRP_DOMAIN:-}"
FRP_TOKEN="${FRP_TOKEN:-}"
FRP_SSL_EMAIL="${FRP_SSL_EMAIL:-}"
FRP_AUTO_START="${FRP_AUTO_START:-false}"
# 如果提供了 SSL 郵箱，默認不跳過 SSL
if [[ -n "$FRP_SSL_EMAIL" ]]; then
    FRP_SKIP_SSL="${FRP_SKIP_SSL:-false}"
else
    FRP_SKIP_SSL="${FRP_SKIP_SSL:-true}"
fi

# 獲取腳本目錄 (支援直接執行和 stdin 傳輸)
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    SERVER_INSTALL_DIR="$PROJECT_ROOT/server"
else
    # 通過 stdin 執行，假設已上傳到 /root/frp-tunnel
    PROJECT_ROOT="/root/frp-tunnel"
    SCRIPT_DIR="$PROJECT_ROOT/remote-init"
    SERVER_INSTALL_DIR="$PROJECT_ROOT/server"
fi
STATE_FILE="/var/lib/frp-tunnel/bootstrap.state"
WORK_DIR="/root/frp-tunnel"

# 顏色
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# ============================================
# 日誌函數
# ============================================

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }
log_step() { echo -e "${CYAN}==>${NC} $*"; }
log_progress() { echo -e "${CYAN}  →${NC} $*"; }

# 確認函數
confirm() {
    local prompt=$1
    local response

    # 非互動式環境，默認確認
    if [[ ! -t 0 ]]; then
        return 0
    fi

    read -rp "${prompt} [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]]
}

# ============================================
# 檢查點系統
# ============================================

# 檢查點階段定義
declare -A STAGE_DESCRIPTION=(
    ["system_check"]="檢查系統環境"
    ["docker_check"]="檢查 Docker 安裝"
    ["docker_install"]="安裝 Docker"
    ["docker_mirror"]="配置 Docker 鏡像源"
    ["docker_compose"]="檢查 Docker Compose"
    ["firewall_check"]="檢查防火牆配置"
    ["create_workdir"]="創建工作目錄"
    ["upload_scripts"]="上傳安裝腳本"
    ["run_install"]="執行服務安裝"
)

# 檢查點順序
STAGE_ORDER=(
    "system_check"
    "docker_check"
    "docker_install"
    "docker_mirror"
    "docker_compose"
    "firewall_check"
    "create_workdir"
    "upload_scripts"
    "run_install"
)

# 初始化狀態文件
init_state() {
    local state_dir
    state_dir=$(dirname "$STATE_FILE")
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir"
    fi
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "# FRP Tunnel Bootstrap State" > "$STATE_FILE"
        echo "LAST_STAGE=" >> "$STATE_FILE"
        echo "START_TIME=$(date +%s)" >> "$STATE_FILE"
    fi
}

# 獲取當前階段
get_current_stage() {
    source "$STATE_FILE"
    echo "$LAST_STAGE"
}

# 更新狀態
set_stage() {
    local stage=$1
    sed -i "s/^LAST_STAGE=.*/LAST_STAGE=$stage/" "$STATE_FILE"
}

# 檢查階段是否完成
is_stage_completed() {
    local stage=$1
    local current
    current=$(get_current_stage)

    # 獲取當前階段在順序中的位置
    local current_pos=-1
    local stage_pos=-1
    local i=0
    for s in "${STAGE_ORDER[@]}"; do
        if [[ "$s" == "$current" ]]; then
            current_pos=$i
        fi
        if [[ "$s" == "$stage" ]]; then
            stage_pos=$i
        fi
        ((i++))
    done

    # 如果當前階段的位置大於等於檢查階段的位置，表示已完成
    [[ $stage_pos -lt $current_pos ]]
}

# 標記階段完成
mark_stage_complete() {
    local stage=$1
    set_stage "$stage"
    log_success "${STAGE_DESCRIPTION[$stage]} - 完成"
}

# ============================================
# 階段 1: 系統檢查
# ============================================

stage_system_check() {
    log_step "${STAGE_DESCRIPTION[system_check]}"

    # 檢查是否為 root
    if [[ $EUID -ne 0 ]]; then
        log_error "此腳本必須以 root 權限運行"
        log_info "請使用: sudo $0"
        exit 1
    fi
    log_progress "✓ Root 權限檢查通過"

    # 檢查 OS
    if [[ ! -f /etc/os-release ]]; then
        log_error "無法檢測操作系統"
        exit 1
    fi

    source /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"

    log_progress "✓ 操作系統: $OS_ID $OS_VERSION"

    # 檢查架構
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            log_error "不支援的架構: $ARCH"
            exit 1
            ;;
    esac
    log_progress "✓ 系統架構: $ARCH"

    # 檢查連接
    if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log_warning "網路連接可能有問題"
    else
        log_progress "✓ 網路連接正常"
    fi

    mark_stage_complete "system_check"
}

# ============================================
# 階段 2: 檢查 Docker
# ============================================

stage_docker_check() {
    log_step "${STAGE_DESCRIPTION[docker_check]}"

    if command -v docker &>/dev/null; then
        DOCKER_VERSION=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        log_progress "✓ Docker 已安裝: $DOCKER_VERSION"
    else
        log_progress "Docker 未安裝，將在下一階段安裝"
    fi

    mark_stage_complete "docker_check"
}

# ============================================
# 階段 3: 安裝 Docker
# ============================================

stage_docker_install() {
    log_step "${STAGE_DESCRIPTION[docker_install]}"

    if command -v docker &>/dev/null; then
        log_info "Docker 已安裝，跳過"
        mark_stage_complete "docker_install"
        return 0
    fi

    log_info "開始安裝 Docker..."

    # 根據 OS 選擇安裝方式
    case "$OS_ID" in
        ubuntu|debian)
            log_progress "使用 apt 安裝 Docker..."

            # 安裝依賴
            apt-get update -qq
            apt-get install -y \
                ca-certificates \
                curl \
                gnupg \
                lsb-release >/dev/null 2>&1

            # 使用 Docker 官方便捷腳本
            log_progress "下載 Docker 安裝腳本..."
            if curl -fsSL https://get.docker.com -o get-docker.sh; then
                log_progress "執行 Docker 安裝..."
                sh get-docker.sh 2>&1 | grep -v "setlocale"
            else
                log_error "無法下載 Docker 安裝腳本"
                exit 1
            fi

            ;;
        centos|rhel|rocky|almalinux)
            log_progress "使用 yum 安裝 Docker..."

            # 安裝依賴
            yum install -y yum-utils >/dev/null

            # 添加 Docker repository
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null

            # 安裝 Docker
            yum install -y docker-ce docker-ce-cli containerd.io >/dev/null

            ;;
        alpine)
            log_progress "使用 apk 安裝 Docker..."
            apk add --no-cache docker docker-cli-compose >/dev/null
            ;;
        *)
            log_error "不支援的 OS: $OS_ID"
            log_info "請手動安裝 Docker: https://docs.docker.com/get-docker/"
            exit 1
            ;;
    esac

    # 啟動 Docker
    systemctl enable docker
    systemctl start docker

    # 驗證安裝
    if docker --version &>/dev/null; then
        DOCKER_VERSION=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        log_success "Docker 安裝成功: $DOCKER_VERSION"
        mark_stage_complete "docker_install"
    else
        log_error "Docker 安裝失敗"
        exit 1
    fi
}

# ============================================
# 階段 4: 配置 Docker 鏡像源
# ============================================

stage_docker_mirror() {
    log_step "${STAGE_DESCRIPTION[docker_mirror]}"

    local daemon_json="/etc/docker/daemon.json"

    # 備份現有配置
    if [[ -f "$daemon_json" ]]; then
        cp "$daemon_json" "${daemon_json}.backup.$(date +%Y%m%d%H%M%S)"
        log_progress "已備份現有配置"
    fi

    # 創建配置目錄
    mkdir -p /etc/docker

    # 配置國內鏡像源
    cat > "$daemon_json" << 'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerproxy.com",
    "https://docker.mirrors.ustc.edu.cn",
    "https://docker.nju.edu.cn"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

    log_progress "✓ 鏡像源配置已更新"

    # 重啟 Docker
    systemctl restart docker

    # 等待 Docker 啟動
    sleep 2

    if systemctl is-active --quiet docker; then
        log_progress "✓ Docker 已重啟"
        log_info "鏡像源配置完成"
        docker info | grep -A 5 "Registry Mirrors" || true
    else
        log_error "Docker 重啟失敗"
        exit 1
    fi

    mark_stage_complete "docker_mirror"
}

# ============================================
# 階段 5: 檢查 Docker Compose
# ============================================

stage_docker_compose() {
    log_step "${STAGE_DESCRIPTION[docker_compose]}"

    if docker compose version &>/dev/null; then
        COMPOSE_VERSION=$(docker compose version --short)
        log_progress "✓ Docker Compose 已安裝: $COMPOSE_VERSION"
    elif docker-compose version &>/dev/null; then
        COMPOSE_VERSION=$(docker-compose version --short)
        log_progress "✓ Docker Compose (獨立版) 已安裝: $COMPOSE_VERSION"
    else
        log_error "Docker Compose 未安裝"
        log_info "請安裝 Docker Compose: https://docs.docker.com/compose/install/"
        exit 1
    fi

    mark_stage_complete "docker_compose"
}

# ============================================
# 階段 6: 防火牆檢查
# ============================================

stage_firewall_check() {
    log_step "${STAGE_DESCRIPTION[firewall_check]}"

    local ports=(80 443 7000 7500)
    local need_open=()

    # 檢查 firewalld
    if systemctl is-active --quiet firewalld; then
        log_info "檢測到 firewalld"
        for port in "${ports[@]}"; do
            if ! firewall-cmd --list-ports | grep -q "${port}/tcp"; then
                need_open+=("$port/tcp")
            fi
        done

        if [[ ${#need_open[@]} -gt 0 ]]; then
            log_warning "以下端口需要在 firewalld 中開放:"
            printf "  - %s\n" "${need_open[@]}"
            echo
            log_info "執行以下命令開放端口:"
            for port in "${need_open[@]}"; do
                echo "  firewall-cmd --permanent --add-port=$port"
            done
            echo "  firewall-cmd --reload"
            echo
            log_warning "請手動執行上述命令後重新運行腳本"
            exit 1
        else
            log_progress "✓ firewalld 端口已配置"
        fi
    fi

    # 檢查 ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        log_info "檢測到 ufw"
        for port in "${ports[@]}"; do
            if ! ufw status | grep -q "$port"; then
                need_open+=("$port")
            fi
        done

        if [[ ${#need_open[@]} -gt 0 ]]; then
            log_warning "以下端口需要在 ufw 中開放:"
            printf "  - %s\n" "${need_open[@]}"
            echo
            log_info "執行以下命令開放端口:"
            for port in "${need_open[@]}"; do
                echo "  ufw allow $port"
            done
            echo
            log_warning "請手動執行上述命令後重新運行腳本"
            exit 1
        else
            log_progress "✓ ufw 端口已配置"
        fi
    fi

    # 檢查 iptables (無狀態)
    if ! systemctl is-active --quiet firewalld && ! command -v ufw &>/dev/null; then
        log_info "未檢測到防火牆服務"
        log_warning "請確保以下端口已開放: ${ports[*]}"
        log_warning "阿里雲用戶請在安全組中配置"
    fi

    mark_stage_complete "firewall_check"
}

# ============================================
# 階段 7: 創建工作目錄
# ============================================

stage_create_workdir() {
    log_step "${STAGE_DESCRIPTION[create_workdir]}"

    mkdir -p "$WORK_DIR"
    log_progress "✓ 工作目錄: $WORK_DIR"

    mark_stage_complete "create_workdir"
}

# ============================================
# 階段 8: 上傳腳本
# ============================================

stage_upload_scripts() {
    log_step "${STAGE_DESCRIPTION[upload_scripts]}"

    # 檢查腳本是否已存在（可能已被 deploy-remote.sh 上傳）
    if [[ -d "$WORK_DIR/server" ]]; then
        log_progress "✓ 腳本已存在"
        mark_stage_complete "upload_scripts"
        return 0
    fi

    # 嘗試找到 server 目錄
    local server_dir=""

    # 檢查當前目錄
    if [[ -d "./server" ]]; then
        server_dir="./server"
    # 檢查父目錄
    elif [[ -d "../server" ]]; then
        server_dir="../server"
    # 檢查工作目錄
    elif [[ -d "$WORK_DIR/server" ]]; then
        server_dir="$WORK_DIR/server"
    fi

    if [[ -z "$server_dir" ]]; then
        log_error "找不到 server 安裝腳本"
        log_info "當前目錄: $(pwd)"
        log_info "工作目錄: $WORK_DIR"
        log_info "請確保腳本已上傳"
        exit 1
    fi

    # 複製腳本到工作目錄
    log_info "複製腳本到遠端..."
    cp -r "$server_dir" "$WORK_DIR/"
    log_progress "✓ 腳本已複製"

    mark_stage_complete "upload_scripts"
}

# ============================================
# 階段 9: 執行安裝
# ============================================

stage_run_install() {
    log_step "${STAGE_DESCRIPTION[run_install]}"

    cd "$WORK_DIR/server"

    if [[ ! -x "./install.sh" ]]; then
        chmod +x ./install.sh
    fi

    log_info "執行服務安裝腳本..."
    echo

    # 構建 install.sh 參數
    local install_args=""

    # 如果有域名配置，使用非互動模式
    if [[ -n "$FRP_DOMAIN" ]]; then
        install_args="--domain $FRP_DOMAIN -y"

        if [[ -n "$FRP_TOKEN" ]]; then
            install_args="$install_args --token $FRP_TOKEN"
        fi

        if [[ -n "$FRP_SSL_EMAIL" ]]; then
            install_args="$install_args --ssl-email $FRP_SSL_EMAIL"
        fi

        # 只有在明確設置 FRP_SKIP_SSL 為 true 時才跳過 SSL
        if [[ "$FRP_SKIP_SSL" == "true" ]]; then
            install_args="$install_args --skip-ssl"
        fi

        if [[ "$FRP_AUTO_START" == "true" ]]; then
            install_args="$install_args --auto-start"
        fi
    fi

    # 執行安裝腳本
    # shellcheck disable=SC2086
    if ./install.sh $install_args; then
        echo
        log_success "服務安裝完成"
        mark_stage_complete "run_install"
    else
        log_error "服務安裝失敗"
        log_info "您可以重新運行此腳本繼續"
        exit 1
    fi
}

# ============================================
# 主程序
# ============================================

show_banner() {
    cat << "EOF"
╔══════════════════════════════════════════════════════════╗
║     FRP Tunnel - 遠端主機初始化腳本                      ║
╚══════════════════════════════════════════════════════════╝
EOF
}

show_resume_info() {
    local current_stage
    current_stage=$(get_current_stage)

    if [[ -n "$current_stage" ]]; then
        echo
        log_info "檢測到之前的安裝進度"
        log_info "上次完成的階段: ${STAGE_DESCRIPTION[$current_stage]:-未知}"
        echo
        log_info "將從以下階段繼續:"
    fi
}

show_progress() {
    local current=$1
    local total=${#STAGE_ORDER[@]}

    echo
    log_info "進度: [$current/$total] $current%"
}

main() {
    show_banner
    echo
    log_info "初始化狀態系統..."

    # 初始化狀態
    init_state
    log_success "狀態系統已初始化"

    # 檢查是否恢復
    local current_stage
    current_stage=$(get_current_stage)

    if [[ -n "$current_stage" ]]; then
        show_resume_info
        # 找到當前階段的下一個
        local found_current=false
        for stage in "${STAGE_ORDER[@]}"; do
            if [[ "$found_current" == "true" ]]; then
                echo "  → ${STAGE_DESCRIPTION[$stage]}"
            fi
            if [[ "$stage" == "$current_stage" ]]; then
                found_current=true
            fi
        done
        echo
        if ! confirm "是否繼續？"; then
            log_info "已取消"
            exit 0
        fi
        echo
    fi

    log_info "開始執行部署階段..."

    # 調試輸出
    >&2 echo "DEBUG: About to enter for loop" >&2

    echo

    # 執行各階段
    local stage_num=0

    for stage in "${STAGE_ORDER[@]}"; do
        ((stage_num++)) || true

        # 跳過已完成的階段
        if is_stage_completed "$stage"; then
            log_info "[${stage_num}/${#STAGE_ORDER[@]}] 跳過: ${STAGE_DESCRIPTION[$stage]}"
            continue
        fi

        # 執行階段
        log_info "[${stage_num}/${#STAGE_ORDER[@]}] 執行: ${STAGE_DESCRIPTION[$stage]}"
        echo

        if "stage_$stage"; then
            echo
        else
            echo
            log_error "階段失敗: ${STAGE_DESCRIPTION[$stage]}"
            echo
            log_info "狀態已保存，重新運行腳本將從此階段繼續"
            exit 1
        fi
    done

    # 完成
    echo
    log_success "═══════════════════════════════════════"
    log_success "遠端主機初始化完成！"
    log_success "═══════════════════════════════════════"
    echo

    # 清理狀態文件
    rm -f "$STATE_FILE"

    # 顯示摘要
    log_info "工作目錄: $WORK_DIR"
    log_info "配置文件: $WORK_DIR/server/.env"
    echo
    log_info "管理命令:"
    echo "  cd $WORK_DIR/server"
    echo "  ./manage.sh status    # 查看狀態"
    echo "  ./manage.sh logs      # 查看日誌"
}

# 運行主程序
main "$@"
