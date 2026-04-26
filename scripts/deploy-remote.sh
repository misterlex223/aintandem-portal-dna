#!/bin/bash
# FRP Tunnel - 遠端部署腳本
# 從本地機器部署到遠端主機

set -euo pipefail

# 顏色
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }

# 默認配置
DEFAULT_SSH_USER="root"
DEFAULT_SSH_PORT="22"
DEFAULT_SSH_KEY="$HOME/.ssh/id_rsa"

show_help() {
    cat << EOF
FRP Tunnel - 遠端部署腳本

用法: $0 [OPTIONS] <host>

選項:
    -u, --user USER        SSH 用戶名 (默認: root)
    -p, --port PORT        SSH 端口 (默認: 22)
    -i, --key KEY          SSH 私鑰路徑
    -h, --help             顯示此幫助

參數:
    host                   遠端主機 IP 或域名

範例:
    $0 8.163.40.165
    $0 -u admin -i ~/.ssh/mykey your-server.com
    $0 --port 2222 192.168.1.100

EOF
}

# 解析參數
SSH_USER="$DEFAULT_SSH_USER"
SSH_PORT="$DEFAULT_SSH_PORT"
SSH_KEY=""
REMOTE_HOST=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user)
            SSH_USER="$2"
            shift 2
            ;;
        -p|--port)
            SSH_PORT="$2"
            shift 2
            ;;
        -i|--key)
            SSH_KEY="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "未知選項: $1"
            show_help
            exit 1
            ;;
        *)
            REMOTE_HOST="$1"
            shift
            ;;
    esac
done

# 檢查參數
if [[ -z "$REMOTE_HOST" ]]; then
    log_error "請指定遠端主機"
    echo
    show_help
    exit 1
fi

# 構建 SSH 命令
SSH_CMD="ssh -p $SSH_PORT -o StrictHostKeyChecking=no"
if [[ -n "$SSH_KEY" ]]; then
    SSH_CMD="$SSH_CMD -i $SSH_KEY"
fi
SSH_CMD="$SSH_CMD ${SSH_USER}@${REMOTE_HOST}"

# 獲取腳本目錄
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="$SCRIPT_DIR/remote-init/bootstrap.sh"

# 檢查腳本是否存在
if [[ ! -f "$BOOTSTRAP_SCRIPT" ]]; then
    log_error "找不到初始化腳本: $BOOTSTRAP_SCRIPT"
    exit 1
fi

# 顯示部署信息
echo
log_info "╔══════════════════════════════════════════════════════════╗"
log_info "║     FRP Tunnel - 遠端部署                                ║"
log_info "╚══════════════════════════════════════════════════════════╝"
echo
log_info "部署目標:"
echo "  主機: $REMOTE_HOST"
echo "  用戶: $SSH_USER"
echo "  端口: $SSH_PORT"
if [[ -n "$SSH_KEY" ]]; then
    echo "  私鑰: $SSH_KEY"
fi
echo

# 測試連接
log_info "測試連接..."
if $SSH_CMD "echo '連接成功'" 2>/dev/null; then
    log_success "連接成功"
else
    log_error "無法連接到遠端主機"
    log_info "請檢查:"
    echo "  - 主機地址正確"
    echo "  - SSH 服務運行中"
    echo "  - 防火牆允許連接"
    echo "  - SSH 密鑰正確"
    exit 1
fi

# 上傳並執行腳本
log_info "上傳並執行初始化腳本..."
echo

# 使用 heredoc 上傳並執行腳本
$SSH_CMD "bash -s" < "$BOOTSTRAP_SCRIPT"

# 檢查執行結果
if [[ $? -eq 0 ]]; then
    echo
    log_success "部署完成！"
    echo
    log_info "後續管理:"
    echo "  $SSH_CMD"
    echo "  cd /root/frp-tunnel/server"
    echo "  ./manage.sh status"
else
    echo
    log_error "部署失敗"
    log_info "您可以重新運行此腳本，它將從上次失敗的地方繼續"
    exit 1
fi
