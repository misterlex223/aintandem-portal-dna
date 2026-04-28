#!/bin/bash
# Get FRP Auth Token from remote server
# Usage: ./get-token.sh [user@]server [ssh_key_path]

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }

# Default SSH key
DEFAULT_SSH_KEY="$HOME/workspace/Aliyun-GZ.pem"

# Parse arguments
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-$DEFAULT_SSH_KEY}"
REMOTE_HOST=""

show_help() {
    cat << EOF
Get FRP Auth Token from remote server

Usage: $0 [OPTIONS] <host>

Options:
    -u, --user USER        SSH user (default: root)
    -i, --key KEY          SSH private key path
    -h, --help             Show this help

Examples:
    $0 kunlun.unclemon.studio
    $0 -i ~/.ssh/id_rsa user@server.com

EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user)
            SSH_USER="$2"
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
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            REMOTE_HOST="$1"
            shift
            ;;
    esac
done

if [[ -z "$REMOTE_HOST" ]]; then
    echo "Error: Please specify remote host"
    echo
    show_help
    exit 1
fi

# Build SSH command
SSH_CMD="ssh -o StrictHostKeyChecking=no"
if [[ -f "$SSH_KEY" ]]; then
    SSH_CMD="$SSH_CMD -i $SSH_KEY"
fi
SSH_CMD="$SSH_CMD ${SSH_USER}@${REMOTE_HOST}"

# Fetch token from remote server
log_info "Fetching FRP configuration from $REMOTE_HOST..."

ENV_FILE="/root/frp-tunnel/server/.env"

if $SSH_CMD "test -f $ENV_FILE"; then
    TOKEN=$($SSH_CMD "grep '^FRP_AUTH_TOKEN=' $ENV_FILE | cut -d'=' -f2")
    DASHBOARD_ENABLED=$($SSH_CMD "grep '^DASHBOARD_ENABLED=' $ENV_FILE | cut -d'=' -f2")
    DASHBOARD_PORT=$($SSH_CMD "grep '^DASHBOARD_PORT=' $ENV_FILE | cut -d'=' -f2")
    DASHBOARD_USER=$($SSH_CMD "grep '^DASHBOARD_USER=' $ENV_FILE | cut -d'=' -f2")
    DASHBOARD_PASSWORD=$($SSH_CMD "grep '^DASHBOARD_PASSWORD=' $ENV_FILE | cut -d'=' -f2")
    TUNNEL_DOMAIN=$($SSH_CMD "grep '^TUNNEL_DOMAIN=' $ENV_FILE | cut -d'=' -f2")

    log_success "Configuration retrieved:"
    echo
    echo "  Tunnel Domain: $TUNNEL_DOMAIN"
    echo "  FRPS Port: 7000"
    echo "  Auth Token: $TOKEN"
    echo
    echo "  Dashboard: $DASHBOARD_ENABLED"
    if [[ "$DASHBOARD_ENABLED" == "true" ]]; then
        echo "  Dashboard Port: $DASHBOARD_PORT"
        echo "  Dashboard User: $DASHBOARD_USER"
        echo "  Dashboard Password: $DASHBOARD_PASSWORD"
        echo
        echo "  Access via SSH tunnel:"
        echo "    ssh -L $DASHBOARD_PORT:localhost:$DASHBOARD_PORT -i $SSH_KEY ${SSH_USER}@${REMOTE_HOST}"
        echo "    Then open: http://localhost:$DASHBOARD_PORT"
    fi
    echo
else
    echo "Error: Configuration file not found on remote server"
    exit 1
fi
