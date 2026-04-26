#!/bin/bash
# FRP Tunnel Client - Management Script

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
FRPC_SERVICE_PREFIX="frpc"
FRPC_CONFIG_DIR="/etc/frp"

# Show help
show_help() {
    cat << EOF
FRP Tunnel Client - Management Script

Usage: $0 <command> [options]

Commands:
    list              List all configured clients
    status <name>     Show status of a specific client
    start <name>      Start a client service
    stop <name>       Stop a client service
    restart <name>    Restart a client service
    logs <name>       Show logs for a client
    enable <name>     Enable auto-start on boot
    disable <name>    Disable auto-start on boot
    add               Add a new client (interactive)
    remove <name>     Remove a client configuration
    config <name>     Show client configuration
    version           Show frpc version

Examples:
    $0 list                           # List all clients
    $0 status myapp                   # Show status of 'myapp'
    $0 logs myapp                     # Show logs for 'myapp'
    $0 add                            # Add new client interactively

EOF
}

# List all clients
cmd_list() {
    log_step "Configured clients:"
    echo

    local services
    services=$(systemctl list-units --all --type=service | grep -oP "${FRPC_SERVICE_PREFIX}@[^\s]+" || true)

    if [[ -z "$services" ]]; then
        log_warning "No clients found"
        return
    fi

    printf "%-20s %-10s %-10s\n" "Client" "Status" "Enabled"
    printf "%-20s %-10s %-10s\n" "------" "------" "-------"

    for service in $services; do
        local name
        name=$(echo "$service" | sed "s/${FRPC_SERVICE_PREFIX}@//")

        local status
        if systemctl is-active --quiet "$service"; then
            status="running"
        else
            status="stopped"
        fi

        local enabled
        if systemctl is-enabled --quiet "$service"; then
            enabled="yes"
        else
            enabled="no"
        fi

        printf "%-20s %-10s %-10s\n" "$name" "$status" "$enabled"
    done
}

# Show client status
cmd_status() {
    local name=$1

    if [[ -z "$name" ]]; then
        log_error "Please specify a client name"
        exit 1
    fi

    local service="${FRPC_SERVICE_PREFIX}@${name}"

    if ! systemctl list-units --all --type=service | grep -q "$service"; then
        log_error "Client '$name' not found"
        exit 1
    fi

    log_step "Status for client '$name':"
    echo

    systemctl status "$service" --no-pager
}

# Start client
cmd_start() {
    local name=$1

    if [[ -z "$name" ]]; then
        log_error "Please specify a client name"
        exit 1
    fi

    local service="${FRPC_SERVICE_PREFIX}@${name}"
    local config_file="$FRPC_CONFIG_DIR/${name}.toml"

    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration not found: $config_file"
        exit 1
    fi

    log_step "Starting client '$name'..."
    systemctl start "$service"

    if systemctl is-active --quiet "$service"; then
        log_success "Client '$name' started"
    else
        log_error "Failed to start client '$name'"
        exit 1
    fi
}

# Stop client
cmd_stop() {
    local name=$1

    if [[ -z "$name" ]]; then
        log_error "Please specify a client name"
        exit 1
    fi

    local service="${FRPC_SERVICE_PREFIX}@${name}"

    log_step "Stopping client '$name'..."
    systemctl stop "$service"

    if systemctl is-active --quiet "$service"; then
        log_error "Failed to stop client '$name'"
        exit 1
    else
        log_success "Client '$name' stopped"
    fi
}

# Restart client
cmd_restart() {
    local name=$1

    if [[ -z "$name" ]]; then
        log_error "Please specify a client name"
        exit 1
    fi

    local service="${FRPC_SERVICE_PREFIX}@${name}"

    log_step "Restarting client '$name'..."
    systemctl restart "$service"

    sleep 1

    if systemctl is-active --quiet "$service"; then
        log_success "Client '$name' restarted"
    else
        log_error "Failed to restart client '$name'"
        exit 1
    fi
}

# Show logs
cmd_logs() {
    local name=$1

    if [[ -z "$name" ]]; then
        log_error "Please specify a client name"
        exit 1
    fi

    local service="${FRPC_SERVICE_PREFIX}@${name}"

    log_step "Showing logs for client '$name' (Ctrl+C to exit)..."
    echo
    journalctl -u "$service" -f
}

# Enable auto-start
cmd_enable() {
    local name=$1

    if [[ -z "$name" ]]; then
        log_error "Please specify a client name"
        exit 1
    fi

    local service="${FRPC_SERVICE_PREFIX}@${name}"

    log_step "Enabling auto-start for client '$name'..."
    systemctl enable "$service"
    log_success "Client '$name' will start automatically on boot"
}

# Disable auto-start
cmd_disable() {
    local name=$1

    if [[ -z "$name" ]]; then
        log_error "Please specify a client name"
        exit 1
    fi

    local service="${FRPC_SERVICE_PREFIX}@${name}"

    log_step "Disabling auto-start for client '$name'..."
    systemctl disable "$service"
    log_success "Client '$name' will not start automatically on boot"
}

# Add new client (interactive)
cmd_add() {
    log_step "Add new client configuration"
    echo

    # Prompt for configuration
    local server_addr
    server_addr=$(prompt_input "FRP Server Address" "")

    local server_port
    server_port=$(prompt_input "FRP Server Port" "7000")

    local auth_token
    auth_token=$(prompt_input "Auth Token" "")

    local client_name
    while true; do
        client_name=$(prompt_input "Client Name" "")
        if [[ -n "$client_name" ]] && [[ ! "$client_name" =~ [[:space:]] ]]; then
            break
        fi
        log_error "Invalid client name"
    done

    local subdomain
    while true; do
        subdomain=$(prompt_input "Subdomain" "$client_name")
        if validate_subdomain "$subdomain"; then
            break
        fi
        log_error "Invalid subdomain"
    done

    local local_port
    while true; do
        local_port=$(prompt_input "Local Port" "3000")
        if [[ "$local_port" =~ ^[0-9]+$ ]] && [[ "$local_port" -ge 1 ]] && [[ "$local_port" -le 65535 ]]; then
            break
        fi
        log_error "Invalid port number"
    done

    local local_ip
    local_ip=$(prompt_input "Local IP" "127.0.0.1")

    # Run install script with collected parameters
    local install_script="$SCRIPT_DIR/install.sh"

    if [[ -x "$install_script" ]]; then
        exec "$install_script" \
            --server "$server_addr" \
            --port "$server_port" \
            --token "$auth_token" \
            --name "$client_name" \
            --subdomain "$subdomain" \
            --local-port "$local_port" \
            --local-ip "$local_ip"
    else
        log_error "Install script not found or not executable: $install_script"
        exit 1
    fi
}

# Remove client
cmd_remove() {
    local name=$1

    if [[ -z "$name" ]]; then
        log_error "Please specify a client name"
        exit 1
    fi

    local service="${FRPC_SERVICE_PREFIX}@${name}"
    local config_file="$FRPC_CONFIG_DIR/${name}.toml"

    log_warning "This will remove client '$name'"
    if ! confirm "Continue?"; then
        exit 0
    fi

    # Stop and disable service
    if systemctl list-unit-files | grep -q "$service"; then
        systemctl stop "$service" 2>/dev/null || true
        systemctl disable "$service" 2>/dev/null || true
    fi

    # Remove systemd service file
    local service_file="/etc/systemd/system/${service}.service"
    if [[ -f "$service_file" ]]; then
        rm -f "$service_file"
        systemctl daemon-reload
    fi

    # Remove configuration
    if [[ -f "$config_file" ]]; then
        rm -f "$config_file"
    fi

    log_success "Client '$name' removed"
}

# Show configuration
cmd_config() {
    local name=$1

    if [[ -z "$name" ]]; then
        log_error "Please specify a client name"
        exit 1
    fi

    local config_file="$FRPC_CONFIG_DIR/${name}.toml"

    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration not found: $config_file"
        exit 1
    fi

    log_step "Configuration for client '$name':"
    echo

    # Hide sensitive info
    grep -v "auth.token" "$config_file" | grep -v "^#"
    echo
    log_info "Auth token: (hidden)"
}

# Show version
cmd_version() {
    if [[ -x "/usr/local/bin/frpc" ]]; then
        /usr/local/bin/frpc --version
    else
        log_error "frpc not found in /usr/local/bin"
    fi
}

# Main
main() {
    require_root

    local command=${1:-help}

    case "$command" in
        list)       cmd_list ;;
        status)     cmd_status "${2:-}" ;;
        start)      cmd_start "${2:-}" ;;
        stop)       cmd_stop "${2:-}" ;;
        restart)    cmd_restart "${2:-}" ;;
        logs)       cmd_logs "${2:-}" ;;
        enable)     cmd_enable "${2:-}" ;;
        disable)    cmd_disable "${2:-}" ;;
        add)        cmd_add ;;
        remove)     cmd_remove "${2:-}" ;;
        config)     cmd_config "${2:-}" ;;
        version)    cmd_version ;;
        help|--help|-h) show_help ;;
        *)
            log_error "Unknown command: $command"
            echo
            show_help
            exit 1
            ;;
    esac
}

main "$@"
