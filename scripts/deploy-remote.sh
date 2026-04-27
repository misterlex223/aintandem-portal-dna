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
    -a, --aliyun           使用阿里雲密鑰 ~/workspace/Aliyun-GZ.pem
    -d, --domain DOMAIN    FRP 隧道域名 (必需)
    -t, --token TOKEN      FRP 認證 Token (留空自動生成)
    --ssl-email EMAIL      SSL 憑證郵箱
    --proxy-vless VLESS    Xray VLESS 連接 (GitHub 加速)
    --auto-start           自動啟動服務
    -h, --help             顯示此幫助

參數:
    host                   遠端主機 IP 或域名

範例:
    $0 -d kunlun.unclemon.studio kunlun.unclemon.studio
    $0 -a -d tunnel.example.com your-server.com
    $0 -d tunnel.example.com -t mytoken --auto-start your-server.com

EOF
}

# 解析參數
SSH_USER="$DEFAULT_SSH_USER"
SSH_PORT="$DEFAULT_SSH_PORT"
SSH_KEY=""
REMOTE_HOST=""
FRP_DOMAIN=""
FRP_TOKEN=""
FRP_SSL_EMAIL=""
FRP_PROXY_VLESS=""
FRP_AUTO_START="false"

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
        -a|--aliyun)
            SSH_KEY="$HOME/workspace/Aliyun-GZ.pem"
            shift
            ;;
        -d|--domain)
            FRP_DOMAIN="$2"
            shift 2
            ;;
        -t|--token)
            FRP_TOKEN="$2"
            shift 2
            ;;
        --ssl-email)
            FRP_SSL_EMAIL="$2"
            shift 2
            ;;
        --proxy-vless)
            FRP_PROXY_VLESS="$2"
            shift 2
            ;;
        --auto-start)
            FRP_AUTO_START="true"
            shift
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

if [[ -z "$FRP_DOMAIN" ]]; then
    log_error "請指定 FRP 隧道域名 (-d/--domain)"
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
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi
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
log_info "FRP 配置:"
echo "  域名: $FRP_DOMAIN"
if [[ -n "$FRP_TOKEN" ]]; then
    echo "  Token: $FRP_TOKEN"
else
    echo "  Token: (自動生成)"
fi
if [[ -n "$FRP_SSL_EMAIL" ]]; then
    echo "  SSL 郵箱: $FRP_SSL_EMAIL"
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

# 上傳文件到遠端
log_info "上傳腳本到遠端..."
echo
$SSH_CMD "mkdir -p /root/frp-tunnel"

# 獲取 server 目錄的絕對路徑
if [[ -d "$SCRIPT_DIR/server" ]]; then
    SERVER_DIR="$SCRIPT_DIR/server"
elif [[ -d "$SCRIPT_DIR/../server" ]]; then
    SERVER_DIR="$(cd "$SCRIPT_DIR/../server" && pwd)"
else
    log_error "找不到 server 目錄"
    exit 1
fi

log_info "Server 目錄: $SERVER_DIR"

if [[ -n "$SSH_KEY" ]]; then
    scp -i "$SSH_KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=no -r "$SERVER_DIR" "${SSH_USER}@${REMOTE_HOST}:/root/frp-tunnel/" 2>&1 | grep -v "setlocale" || true
    if [[ -d "$SCRIPT_DIR/shared" ]]; then
        scp -i "$SSH_KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/shared" "${SSH_USER}@${REMOTE_HOST}:/root/frp-tunnel/" 2>&1 | grep -v "setlocale" || true
    fi
else
    scp -P "$SSH_PORT" -o StrictHostKeyChecking=no -r "$SERVER_DIR" "${SSH_USER}@${REMOTE_HOST}:/root/frp-tunnel/" 2>&1 | grep -v "setlocale" || true
    if [[ -d "$SCRIPT_DIR/shared" ]]; then
        scp -P "$SSH_PORT" -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/shared" "${SSH_USER}@${REMOTE_HOST}:/root/frp-tunnel/" 2>&1 | grep -v "setlocale" || true
    fi
fi
log_success "腳本已上傳"

# 下載 xray (如果在本地使用代理，可以成功訪問 GitHub)
if [[ -n "$FRP_PROXY_VLESS" ]]; then
    log_info "準備 xray 二進製..."

    # 創建臨時目錄
    TEMP_DIR=$(mktemp -d)
    XRAY_ZIP="$TEMP_DIR/xray.zip"

    # 下載 xray (使用本地的代理環境)
    log_info "從 GitHub 下載 xray..."
    if curl -L -o "$XRAY_ZIP" "https://github.com/XTLS/Xray-core/releases/download/v1.8.24/Xray-linux-64.zip" 2>/dev/null; then
        # 解壓 (使用 Python zipfile，因為系統可能沒有 unzip)
        python3 -c "import zipfile; zipfile.ZipFile('$XRAY_ZIP').extractall('$TEMP_DIR')"
        chmod +x "$TEMP_DIR/xray"
        log_success "xray 已下載"

        # 解析 VLESS URL: vless://encoded_part?params
        # 編碼部分格式: :uuid@server:port (注意開頭的冒號)
        vless_encoded=$(echo "$FRP_PROXY_VLESS" | sed 's/vless:\/\///;s/\?.*//')
        vless_decoded=$(echo "$vless_encoded" | base64 -d 2>/dev/null || echo "$vless_encoded")

        # 使用正則表達式更可靠地解析
        [[ "$vless_decoded" =~ :([0-9a-f-]+)@([0-9.]+):([0-9]+) ]]
        vless_uuid="${BASH_REMATCH[1]}"
        vless_server="${BASH_REMATCH[2]}"
        vless_port="${BASH_REMATCH[3]}"
        vless_peer=$(echo "$FRP_PROXY_VLESS" | sed -n 's/.*peer=\([^&]*\).*/\1/p')

        # 生成 xray 配置文件
        log_info "生成 xray 配置文件..."
        XRAY_CONFIG="$TEMP_DIR/xray-vless.json"

        # 使用 jq 生成配置
        jq -n \
            --argjson loglevel '"warning"' \
            --argjson port "${FRP_PROXY_HTTP_PORT:-10808}" \
            --arg uuid "$vless_uuid" \
            --arg server "$vless_server" \
            --argjson port_num "$vless_port" \
            --arg peer "$vless_peer" \
            '{
                log: { loglevel: $loglevel },
                inbounds: [
                    {
                        port: $port,
                        protocol: "http",
                        settings: { allowTransparent: false }
                    }
                ],
                outbounds: [
                    {
                        protocol: "vless",
                        settings: {
                            vnext: [
                                {
                                    address: $server,
                                    port: $port_num,
                                    users: [{ id: $uuid, encryption: "none" }]
                                }
                            ]
                        },
                        streamSettings: {
                            network: "tcp",
                            security: "tls",
                            tlsSettings: {
                                serverName: $peer,
                                allowInsecure: false
                            }
                        }
                    }
                ]
            }' > "$XRAY_CONFIG"

        # 上傳 xray 和配置到遠端
        log_info "上傳 xray 到遠端..."
        if [[ -n "$SSH_KEY" ]]; then
            scp -i "$SSH_KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=no "$TEMP_DIR/xray" "${SSH_USER}@${REMOTE_HOST}:/tmp/xray"
            scp -i "$SSH_KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=no "$XRAY_CONFIG" "${SSH_USER}@${REMOTE_HOST}:/tmp/xray-vless.json"
        else
            scp -P "$SSH_PORT" -o StrictHostKeyChecking=no "$TEMP_DIR/xray" "${SSH_USER}@${REMOTE_HOST}:/tmp/xray"
            scp -P "$SSH_PORT" -o StrictHostKeyChecking=no "$XRAY_CONFIG" "${SSH_USER}@${REMOTE_HOST}:/tmp/xray-vless.json"
        fi
        log_success "xray 已上傳"
    else
        log_error "下載 xray 失敗"
        log_info "將在遠端嘗試直接下載"
    fi

    # 清理臨時文件
    rm -rf "$TEMP_DIR"
fi

# 執行初始化腳本
log_info "執行初始化腳本..."
echo

# 構建環境變量
env_vars=""
if [[ -n "$FRP_DOMAIN" ]]; then
    env_vars="export FRP_DOMAIN=$FRP_DOMAIN"
fi
if [[ -n "$FRP_TOKEN" ]]; then
    env_vars="$env_vars; export FRP_TOKEN=$FRP_TOKEN"
fi
if [[ -n "$FRP_SSL_EMAIL" ]]; then
    env_vars="$env_vars; export FRP_SSL_EMAIL=$FRP_SSL_EMAIL"
fi
if [[ -n "$FRP_PROXY_VLESS" ]]; then
    env_vars="$env_vars; export FRP_PROXY_VLESS='$FRP_PROXY_VLESS'"
fi
if [[ "$FRP_AUTO_START" == "true" ]]; then
    env_vars="$env_vars; export FRP_AUTO_START=true"
fi

# 將腳本內容傳到遠端執行，帶環境變量
$SSH_CMD "$env_vars; bash -s" < "$BOOTSTRAP_SCRIPT"

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
