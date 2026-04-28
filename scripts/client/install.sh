#!/bin/bash
# FRP Tunnel Client - Installation Script
# This script installs and configures the frpc client

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(dirname "$SCRIPT_DIR")/shared"

# Source shared utilities
# shellcheck source=../shared/utils.sh
if [[ -f "$SHARED_DIR/utils.sh" ]]; then
    source "$SHARED_DIR/utils.sh"
else
    echo "Error: Cannot find utils.sh at $SHARED_DIR/utils.sh"
    exit 1
fi

# Configuration
FRPC_VERSION="${FRPC_VERSION:-0.60.0}"
FRPC_INSTALL_DIR="/usr/local/bin"
FRPC_CONFIG_DIR="/etc/frp"
FRPC_SERVICE_PREFIX="frpc"

# Colors for output (imported from utils.sh)
show_banner() {
    cat << "EOF"
╔══════════════════════════════════════════════════════════╗
║         FRP Tunnel Client - Installation Script          ║
╚══════════════════════════════════════════════════════════╝
EOF
}

# Parse command line arguments
parse_args() {
    SERVER_ADDR=""
    SERVER_PORT="7000"
    AUTH_TOKEN=""
    CLIENT_NAME=""
    SUBDOMAIN=""
    LOCAL_PORT=""
    LOCAL_IP="127.0.0.1"
    PROXY_NAME="web"
    NON_INTERACTIVE=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --server)
                SERVER_ADDR="$2"
                shift 2
                ;;
            --port)
                SERVER_PORT="$2"
                shift 2
                ;;
            --token)
                AUTH_TOKEN="$2"
                shift 2
                ;;
            --name)
                CLIENT_NAME="$2"
                shift 2
                ;;
            --subdomain)
                SUBDOMAIN="$2"
                shift 2
                ;;
            --local-port)
                LOCAL_PORT="$2"
                shift 2
                ;;
            --local-ip)
                LOCAL_IP="$2"
                shift 2
                ;;
            --proxy-name)
                PROXY_NAME="$2"
                shift 2
                ;;
            -y|--yes)
                NON_INTERACTIVE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Show help
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --server <addr>       FRP server address (required)
    --port <port>         FRP server port (default: 7000)
    --token <token>       Authentication token (required)
    --name <name>         Client/instance name (required)
    --subdomain <sub>     Subdomain for this tunnel (required)
    --local-port <port>   Local port to forward (required)
    --local-ip <ip>       Local IP to forward to (default: 127.0.0.1)
    --proxy-name <name>   Proxy name (default: web)
    -y, --yes             Auto-confirm all prompts (non-interactive mode)
    -h, --help            Show this help

Example:
    sudo $0 \\
        --server <your-server-ip> \\
        --token your-secret-token \\
        --name myapp \\
        --subdomain myapp \\
        --local-port 3000

EOF
}

# Validate arguments
validate_args() {
    if [[ -z "$SERVER_ADDR" ]]; then
        die "Server address is required. Use --server <addr>"
    fi

    if [[ -z "$AUTH_TOKEN" ]]; then
        die "Auth token is required. Use --token <token>"
    fi

    if [[ -z "$CLIENT_NAME" ]]; then
        die "Client name is required. Use --name <name>"
    fi

    if [[ -z "$SUBDOMAIN" ]]; then
        die "Subdomain is required. Use --subdomain <subdomain>"
    fi

    if ! validate_subdomain "$SUBDOMAIN"; then
        die "Invalid subdomain: $SUBDOMAIN"
    fi

    if [[ -z "$LOCAL_PORT" ]]; then
        die "Local port is required. Use --local-port <port>"
    fi

    if ! [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || [[ "$LOCAL_PORT" -lt 1 ]] || [[ "$LOCAL_PORT" -gt 65535 ]]; then
        die "Invalid local port: $LOCAL_PORT"
    fi
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."

    # Check if running as root
    require_root

    # Check if port is available for local service
    if check_port "$LOCAL_PORT"; then
        log_warning "Port $LOCAL_PORT is already in use. Make sure your service is running."
    fi

    log_success "Prerequisites check passed"
}

# Install frpc binary
install_frpc() {
    log_step "Installing frpc binary..."

    local arch
    arch=$(detect_arch)

    # Check if already installed
    if [[ -x "$FRPC_INSTALL_DIR/frpc" ]]; then
        local current_version
        current_version=$("$FRPC_INSTALL_DIR/frpc" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        log_info "frpc $current_version is already installed"

        if [[ "$current_version" == "$FRPC_VERSION" ]]; then
            log_info "Version matches, skipping download"
            return 0
        fi

        if [[ "$NON_INTERACTIVE" == "false" ]]; then
            if confirm "Update to version $FRPC_VERSION?"; then
                :
            else
                log_info "Using existing version"
                return 0
            fi
        fi
    fi

    # Download and install
    download_frp "$FRPC_VERSION" "frpc" "$arch" "/tmp"
    mv "/tmp/frpc" "$FRPC_INSTALL_DIR/frpc"

    log_success "frpc $FRPC_VERSION installed"
}

# Create configuration
create_config() {
    log_step "Creating configuration..."

    mkdir -p "$FRPC_CONFIG_DIR"

    local config_file="$FRPC_CONFIG_DIR/${CLIENT_NAME}.toml"
    local template="$SCRIPT_DIR/configs/frpc.toml.template"

    # Generate config from template
    sed -e "s|{{SERVER_ADDR}}|$SERVER_ADDR|g" \
        -e "s|{{SERVER_PORT}}|$SERVER_PORT|g" \
        -e "s|{{AUTH_TOKEN}}|$AUTH_TOKEN|g" \
        -e "s|{{CLIENT_NAME}}|$CLIENT_NAME|g" \
        -e "s|{{PROXY_NAME}}|$PROXY_NAME|g" \
        -e "s|{{LOCAL_IP}}|$LOCAL_IP|g" \
        -e "s|{{LOCAL_PORT}}|$LOCAL_PORT|g" \
        -e "s|{{SUBDOMAIN}}|$SUBDOMAIN|g" \
        "$template" > "$config_file"

    log_success "Configuration created: $config_file"
}

# Create systemd service
create_service() {
    log_step "Creating systemd service..."

    local service_name="${FRPC_SERVICE_PREFIX}@${CLIENT_NAME}"
    local config_file="$FRPC_CONFIG_DIR/${CLIENT_NAME}.toml"
    local exec_start="$FRPC_INSTALL_DIR/frpc -c $config_file"

    create_systemd_service "$service_name" "$exec_start" "FRP Client - $CLIENT_NAME"

    systemctl enable "$service_name"

    log_success "Systemd service created: $service_name"
}

# Start service
start_service() {
    log_step "Starting frpc service..."

    local service_name="${FRPC_SERVICE_PREFIX}@${CLIENT_NAME}"

    systemctl start "$service_name"

    # Wait a bit for service to start
    sleep 2

    if systemctl is-active --quiet "$service_name"; then
        log_success "Service started successfully"
    else
        log_error "Service failed to start"
        systemctl status "$service_name" --no-pager
        exit 1
    fi
}

# Show status and next steps
show_status() {
    local service_name="${FRPC_SERVICE_PREFIX}@${CLIENT_NAME}"

    echo
    log_success "Installation completed!"
    echo

    log_info "Service Status:"
    systemctl status "$service_name" --no-pager | head -10
    echo

    log_info "Configuration Summary:"
    echo "  Server Address: $SERVER_ADDR:$SERVER_PORT"
    echo "  Client Name: $CLIENT_NAME"
    echo "  Subdomain: $SUBDOMAIN"
    echo "  Local: $LOCAL_IP:$LOCAL_PORT"
    echo

    log_info "Access URL:"
    echo "  https://$SUBDOMAIN.$(echo $SERVER_ADDR | sed 's/^[0-9.]*$//;t; s/^/tunnel./')"
    echo

    log_info "Service Management:"
    echo "  systemctl status $service_name  # Check status"
    echo "  systemctl start $service_name   # Start service"
    echo "  systemctl stop $service_name    # Stop service"
    echo "  systemctl restart $service_name # Restart service"
    echo "  journalctl -u $service_name -f  # View logs"
    echo
}

# Main installation flow
main() {
    show_banner
    echo

    parse_args "$@"
    validate_args
    check_prerequisites

    # Show configuration summary
    log_info "Configuration Summary:"
    echo "  Server: $SERVER_ADDR:$SERVER_PORT"
    echo "  Client Name: $CLIENT_NAME"
    echo "  Subdomain: $SUBDOMAIN"
    echo "  Local Forward: $LOCAL_IP:$LOCAL_PORT"
    echo

    if [[ "$NON_INTERACTIVE" == "false" ]]; then
        if ! confirm "Proceed with installation?"; then
            log_info "Installation cancelled"
            exit 0
        fi
    fi

    install_frpc
    create_config
    create_service
    start_service
    show_status
}

# Run main function
main "$@"
