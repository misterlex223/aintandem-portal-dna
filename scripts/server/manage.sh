#!/bin/bash
# FRP Tunnel Server - Management Script

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

# Change to script directory
cd "$SCRIPT_DIR"

# Load .env if exists
if [[ -f .env ]]; then
    # shellcheck source=/dev/null
    source .env
fi

# Get docker compose command
get_compose_cmd() {
    if docker compose version &>/dev/null; then
        echo "docker compose"
    else
        echo "docker-compose"
    fi
}

COMPOSE_CMD=$(get_compose_cmd)

# Show help
show_help() {
    cat << EOF
FRP Tunnel Server - Management Script

Usage: $0 <command> [options]

Commands:
    status       Show service status
    start        Start all services
    stop         Stop all services
    restart      Restart all services
    logs         Show logs from all services
    logs <svc>   Show logs from specific service (frps, nginx, certbot)
    ps           List running containers
    exec <svc>   Execute command in container
    config       Show current configuration
    update       Update frp to latest version
    backup       Backup configuration and certificates
    restore      Restore from backup
    clean        Remove all containers and volumes (DANGER!)

EOF
}

# Show service status
cmd_status() {
    log_step "Checking service status..."
    echo
    $COMPOSE_CMD ps
    echo

    # Check if services are healthy
    if docker ps | grep -q "frps"; then
        log_success "frps is running"
    else
        log_error "frps is not running"
    fi

    if docker ps | grep -q "frp-nginx"; then
        log_success "nginx is running"
    else
        log_error "nginx is not running"
    fi

    if docker ps | grep -q "frp-certbot"; then
        log_success "certbot is running"
    else
        log_warning "certbot is not running"
    fi
}

# Start services
cmd_start() {
    log_step "Starting services..."
    $COMPOSE_CMD start
    log_success "Services started"
}

# Stop services
cmd_stop() {
    log_step "Stopping services..."
    $COMPOSE_CMD stop
    log_success "Services stopped"
}

# Restart services
cmd_restart() {
    log_step "Restarting services..."
    $COMPOSE_CMD restart
    log_success "Services restarted"
}

# Show logs
cmd_logs() {
    local service=${1:-}
    if [[ -n "$service" ]]; then
        log_step "Showing logs for $service..."
        $COMPOSE_CMD logs -f "$service"
    else
        log_step "Showing logs for all services..."
        $COMPOSE_CMD logs -f
    fi
}

# List containers
cmd_ps() {
    $COMPOSE_CMD ps
}

# Execute command in container
cmd_exec() {
    local service=$1
    shift
    if [[ -z "$service" ]]; then
        log_error "Please specify a service (frps, nginx, or certbot)"
        exit 1
    fi
    docker exec -it "$service" "$@"
}

# Show configuration
cmd_config() {
    log_step "Current Configuration:"
    echo

    if [[ -f .env ]]; then
        echo "Environment Variables (.env):"
        grep -v "PASSWORD\|TOKEN" .env | grep -v "^#" | grep -v "^$"
        echo
    fi

    if [[ -f configs/frps.toml ]]; then
        echo "FRPS Configuration:"
        grep -v "PASSWORD\|TOKEN" configs/frps.toml | head -20
        echo
    fi
}

# Update frp version
cmd_update() {
    log_step "Checking for frp updates..."

    local current_version="${FRP_VERSION:-}"
    local latest_version
    latest_version=$(get_latest_frp_version)

    if [[ -z "$current_version" ]]; then
        current_version=$($COMPOSE_CMD exec -T frps frps --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
    fi

    log_info "Current version: $current_version"
    log_info "Latest version: $latest_version"

    if [[ "$current_version" == "$latest_version" ]]; then
        log_success "Already up to date"
        return
    fi

    if confirm "Update to version $latest_version?"; then
        # Update .env file
        sed -i "s/^FRP_VERSION=.*/FRP_VERSION=$latest_version/" .env

        # Pull new image and restart
        $COMPOSE_CMD pull frps
        $COMPOSE_CMD up -d frps

        log_success "Updated to version $latest_version"
    fi
}

# Backup configuration and certificates
cmd_backup() {
    local backup_dir="./backups/$(date +%Y%m%d_%H%M%S)"
    log_step "Creating backup to $backup_dir..."

    mkdir -p "$backup_dir"

    # Copy configuration
    cp -r configs "$backup_dir/"
    cp .env "$backup_dir/" 2>/dev/null || true

    # Copy certificates
    if [[ -d "$CERT_DIR/letsencrypt" ]]; then
        cp -r "$CERT_DIR/letsencrypt" "$backup_dir/"
    fi

    log_success "Backup created at $backup_dir"
}

# Restore from backup
cmd_restore() {
    local backup_dir=$1

    if [[ -z "$backup_dir" ]]; then
        log_error "Please specify backup directory"
        echo "Available backups:"
        ls -lt ./backups/ 2>/dev/null | head -10
        exit 1
    fi

    if [[ ! -d "$backup_dir" ]]; then
        die "Backup directory not found: $backup_dir"
    fi

    log_step "Restoring from $backup_dir..."

    # Stop services
    $COMPOSE_CMD stop

    # Restore configuration
    rm -rf configs
    cp -r "$backup_dir/configs" ./

    # Restore .env
    cp "$backup_dir/.env" ./ 2>/dev/null || true

    # Restore certificates
    if [[ -d "$backup_dir/letsencrypt" ]]; then
        rm -rf "$CERT_DIR/letsencrypt"
        cp -r "$backup_dir/letsencrypt" "$CERT_DIR/"
    fi

    # Start services
    $COMPOSE_CMD start

    log_success "Restore completed"
}

# Clean everything (dangerous!)
cmd_clean() {
    log_warning "This will remove all containers, volumes, and data!"
    if ! confirm "Are you sure you want to continue?"; then
        exit 0
    fi

    if ! confirm "Really? This cannot be undone!"; then
        exit 0
    fi

    log_step "Stopping and removing all containers..."
    $COMPOSE_CMD down -v

    log_step "Removing data directories..."
    rm -rf ./data
    rm -rf ./certs
    rm -rf ./logs

    log_success "Cleanup completed"
}

# Main
main() {
    local command=${1:-help}

    case "$command" in
        status)   cmd_status ;;
        start)    cmd_start ;;
        stop)     cmd_stop ;;
        restart)  cmd_restart ;;
        logs)     cmd_logs "${2:-}" ;;
        ps)       cmd_ps ;;
        exec)     shift; cmd_exec "$@" ;;
        config)   cmd_config ;;
        update)   cmd_update ;;
        backup)   cmd_backup ;;
        restore)  cmd_restore "${2:-}" ;;
        clean)    cmd_clean ;;
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
