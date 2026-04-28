#!/bin/bash
# FRP Tunnel Server - Installation Script
# This script sets up the frp server with Docker Compose
#
# Usage:
#   Interactive mode: ./install.sh
#   Non-interactive mode: ./install.sh --domain tunnel.example.com [options]

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

# ============================================
# Command-line argument parsing
# ============================================

show_help() {
    cat << EOF
FRP Tunnel Server Installation Script

Usage: $0 [OPTIONS]

Options:
    --domain DOMAIN           Tunnel domain (e.g., tunnel.example.com)
    --token TOKEN             FRP auth token (auto-generated if not provided)
    --ssl-email EMAIL         Email for Let's Encrypt notifications
    --enable-dashboard        Enable frp dashboard
    --no-dashboard            Disable frp dashboard (default)
    --dashboard-port PORT     Dashboard port (default: 7500)
    --dashboard-user USER     Dashboard username (default: admin)
    --dashboard-password PASS Dashboard password (auto-generated if not provided)
    --http-port PORT          HTTP port (default: 80)
    --https-port PORT         HTTPS port (default: 443)
    --frps-port PORT          FRPS port (default: 7000)
    --vhost-port PORT         Vhost HTTP port (default: 8080)
    --skip-ssl               Skip SSL certificate acquisition
    --auto-start              Auto-start services after installation
    -y, --yes                 Auto-confirm all prompts (non-interactive mode)
    -h, --help                Show this help

Examples:
    # Interactive mode
    $0

    # Non-interactive mode with minimal config
    $0 --domain tunnel.example.com -y

    # Full configuration
    $0 --domain tunnel.example.com --token mytoken --ssl-email admin@example.com -y

EOF
}

# Default values
TUNNEL_DOMAIN=""
FRP_AUTH_TOKEN=""
SSL_EMAIL=""
DASHBOARD_ENABLED="false"
DASHBOARD_PORT="7500"
DASHBOARD_USER="admin"
DASHBOARD_PASSWORD=""
NGINX_HTTP_PORT="80"
NGINX_HTTPS_PORT="443"
FRPS_PORT="7000"
FRPS_VHOST_HTTP_PORT="8080"
SKIP_SSL=false
AUTO_START=false
NON_INTERACTIVE=false

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            TUNNEL_DOMAIN="$2"
            shift 2
            ;;
        --token)
            FRP_AUTH_TOKEN="$2"
            shift 2
            ;;
        --ssl-email)
            SSL_EMAIL="$2"
            shift 2
            ;;
        --enable-dashboard)
            DASHBOARD_ENABLED="true"
            shift
            ;;
        --no-dashboard)
            DASHBOARD_ENABLED="false"
            shift
            ;;
        --dashboard-port)
            DASHBOARD_PORT="$2"
            shift 2
            ;;
        --dashboard-user)
            DASHBOARD_USER="$2"
            shift 2
            ;;
        --dashboard-password)
            DASHBOARD_PASSWORD="$2"
            shift 2
            ;;
        --http-port)
            NGINX_HTTP_PORT="$2"
            shift 2
            ;;
        --https-port)
            NGINX_HTTPS_PORT="$2"
            shift 2
            ;;
        --frps-port)
            FRPS_PORT="$2"
            shift 2
            ;;
        --vhost-port)
            FRPS_VHOST_HTTP_PORT="$2"
            shift 2
            ;;
        --skip-ssl)
            SKIP_SSL=true
            shift
            ;;
        --auto-start)
            AUTO_START=true
            shift
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
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Check if running in non-interactive mode
if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ -z "$TUNNEL_DOMAIN" ]]; then
        echo "Error: --domain is required in non-interactive mode"
        show_help
        exit 1
    fi
fi

# Configuration
PROJECT_NAME="frp-tunnel"
DATA_DIR="./data"
CERT_DIR="./certs"
LOG_DIR="./logs"
ENV_FILE=".env"

# Welcome message
show_banner() {
    cat << "EOF"
╔══════════════════════════════════════════════════════════╗
║     FRP Tunnel Server - Docker Compose Installation      ║
╚══════════════════════════════════════════════════════════╝
EOF
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_warning "This script should be run as root for full functionality"
        if [[ "$NON_INTERACTIVE" == "false" ]]; then
            if ! confirm "Continue without root? Some features may not work"; then
                die "Please run with sudo"
            fi
        fi
    fi

    # Check Docker
    if ! command_exists docker; then
        die "Docker is not installed. Please install Docker first: https://docs.docker.com/get-docker/"
    fi

    # Check Docker Compose
    if ! docker compose version &>/dev/null && ! docker-compose version &>/dev/null; then
        die "Docker Compose is not installed. Please install Docker Compose first."
    fi

    # Skip port check in non-interactive mode
    if [[ "$NON_INTERACTIVE" == "false" ]]; then
        local ports=(80 443 7000 7500)
        for port in "${ports[@]}"; do
            if check_port "$port"; then
                log_warning "Port $port is already in use"
                if ! confirm "Continue anyway?"; then
                    die "Installation cancelled"
                fi
            fi
        done
    fi

    log_success "Prerequisites check passed"
}

# Collect configuration
collect_config() {
    log_step "Collecting configuration..."

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        # Non-interactive mode - use values from command-line
        log_info "Using non-interactive mode with provided configuration"

        # Generate token if not provided
        if [[ -z "$FRP_AUTH_TOKEN" ]]; then
            FRP_AUTH_TOKEN=$(generate_token)
            log_info "Generated auth token: $FRP_AUTH_TOKEN"
        fi

        # Generate dashboard password if not provided
        if [[ "$DASHBOARD_ENABLED" == "true" ]] && [[ -z "$DASHBOARD_PASSWORD" ]]; then
            DASHBOARD_PASSWORD=$(generate_token)
            log_info "Generated dashboard password: $DASHBOARD_PASSWORD"
        fi

        # Validate domain
        if ! validate_domain "$TUNNEL_DOMAIN"; then
            die "Invalid domain name: $TUNNEL_DOMAIN"
        fi

        log_success "Configuration collected (non-interactive)"
        return
    fi

    # Interactive mode
    echo
    log_info "Please provide the following configuration:"
    echo

    # Domain configuration
    while true; do
        TUNNEL_DOMAIN=$(prompt_input "Tunnel domain (e.g., tunnel.yourdomain.com)" "")
        if validate_domain "$TUNNEL_DOMAIN"; then
            break
        fi
        log_error "Invalid domain name. Please try again."
    done

    # Authentication token
    echo
    log_info "Authentication token (leave empty to auto-generate)"
    FRP_AUTH_TOKEN=$(prompt_input "FRP auth token" "$(generate_token)")

    # SSL email
    echo
    SSL_EMAIL=$(prompt_input "Email for Let's Encrypt notifications" "")

    # Dashboard configuration
    echo
    if confirm "Enable frp dashboard?"; then
        DASHBOARD_ENABLED="true"
        DASHBOARD_PORT=$(prompt_input "Dashboard port" "7500")
        DASHBOARD_USER=$(prompt_input "Dashboard username" "admin")
        DASHBOARD_PASSWORD=$(prompt_password "Dashboard password")
    else
        DASHBOARD_ENABLED="false"
    fi

    # Port configuration (advanced)
    echo
    if confirm "Configure custom ports?"; then
        NGINX_HTTP_PORT=$(prompt_input "HTTP port" "80")
        NGINX_HTTPS_PORT=$(prompt_input "HTTPS port" "443")
        FRPS_PORT=$(prompt_input "FRPS port" "7000")
        FRPS_VHOST_HTTP_PORT=$(prompt_input "FRPS vhost HTTP port" "8080")
    fi

    log_success "Configuration collected"
}

# Create directory structure
create_directories() {
    log_step "Creating directory structure..."

    mkdir -p "$DATA_DIR"
    mkdir -p "$CERT_DIR/www"
    mkdir -p "$CERT_DIR/letsencrypt"
    mkdir -p "$LOG_DIR"
    mkdir -p "$LOG_DIR/nginx"

    log_success "Directories created"
}

# Generate .env file
generate_env() {
    log_step "Generating .env file..."

    cat > "$ENV_FILE" <<EOF
# FRP Tunnel Server Configuration
# Generated: $(date)

# Project
COMPOSE_PROJECT_NAME=$PROJECT_NAME

# FRP Configuration
FRP_VERSION=0.68.1
FRPS_PORT=$FRPS_PORT
FRPS_VHOST_HTTP_PORT=$FRPS_VHOST_HTTP_PORT
FRP_AUTH_TOKEN=$FRP_AUTH_TOKEN
TUNNEL_DOMAIN=$TUNNEL_DOMAIN

# Nginx Configuration
NGINX_HTTP_PORT=$NGINX_HTTP_PORT
NGINX_HTTPS_PORT=$NGINX_HTTPS_PORT

# SSL Configuration
SSL_EMAIL=$SSL_EMAIL

# Dashboard Configuration
DASHBOARD_ENABLED=$DASHBOARD_ENABLED
EOF

    if [[ "$DASHBOARD_ENABLED" == "true" ]]; then
        cat >> "$ENV_FILE" <<EOF
DASHBOARD_PORT=$DASHBOARD_PORT
DASHBOARD_USER=$DASHBOARD_USER
DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD
EOF
    fi

    cat >> "$ENV_FILE" <<EOF

# Data Directories
DATA_DIR=$DATA_DIR
CERT_DIR=$CERT_DIR
LOG_DIR=$LOG_DIR
EOF

    log_success ".env file generated"
}

# Generate frps configuration
generate_frps_config() {
    log_step "Generating frps configuration..."

    local template="$SCRIPT_DIR/configs/frps.toml.template"
    local output="$SCRIPT_DIR/configs/frps.toml"

    # Simple template replacement
    sed -e "s|{{FRPS_PORT}}|$FRPS_PORT|g" \
        -e "s|{{FRPS_VHOST_HTTP_PORT}}|$FRPS_VHOST_HTTP_PORT|g" \
        -e "s|{{FRP_AUTH_TOKEN}}|$FRP_AUTH_TOKEN|g" \
        "$template" > "$output"

    # Handle dashboard configuration
    if [[ "$DASHBOARD_ENABLED" == "true" ]]; then
        sed -i '/{{#DASHBOARD_ENABLED}}/,/{{\/DASHBOARD_ENABLED}}/s/^#//' "$output"
        sed -i '/{{#DASHBOARD_ENABLED}}/d; /{{\/DASHBOARD_ENABLED}}/d' "$output"
        sed -i "s|{{DASHBOARD_PORT}}|$DASHBOARD_PORT|g" "$output"
        sed -i "s|{{DASHBOARD_USER}}|$DASHBOARD_USER|g" "$output"
        sed -i "s|{{DASHBOARD_PASSWORD}}|$DASHBOARD_PASSWORD|g" "$output"
    else
        sed -i '/{{#DASHBOARD_ENABLED}}/,/{{\/DASHBOARD_ENABLED}}/d' "$output"
    fi

    log_success "frps configuration generated"
}

# Generate nginx configuration
generate_nginx_config() {
    log_step "Generating nginx configuration..."

    local template="$SCRIPT_DIR/configs/nginx.conf.template"
    local output="$SCRIPT_DIR/configs/nginx.conf"

    # Simple template replacement
    sed -e "s|{{NGINX_HTTP_PORT}}|$NGINX_HTTP_PORT|g" \
        -e "s|{{NGINX_HTTPS_PORT}}|$NGINX_HTTPS_PORT|g" \
        -e "s|{{FRPS_VHOST_HTTP_PORT}}|$FRPS_VHOST_HTTP_PORT|g" \
        -e "s|{{TUNNEL_DOMAIN}}|$TUNNEL_DOMAIN|g" \
        "$template" > "$output"

    # Handle dashboard configuration
    if [[ "$DASHBOARD_ENABLED" == "true" ]]; then
        sed -i '/{{#DASHBOARD_ENABLED}}/,/{{\/DASHBOARD_ENABLED}}/s/^#//' "$output"
        sed -i '/{{#DASHBOARD_ENABLED}}/d; /{{\/DASHBOARD_ENABLED}}/d' "$output"
        sed -i "s|{{DASHBOARD_PORT}}|$DASHBOARD_PORT|g" "$output"
    else
        sed -i '/{{#DASHBOARD_ENABLED}}/,/{{\/DASHBOARD_ENABLED}}/d' "$output"
    fi

    log_success "nginx configuration generated"
}

# Get initial SSL certificate

# Generate temporary self-signed certificate
generate_temp_certificate() {
    log_step "Generating temporary SSL certificate..."

    local domain="$TUNNEL_DOMAIN"
    local cert_dir="$CERT_DIR/letsencrypt/live/$domain"

    # Create directory
    mkdir -p "$cert_dir"

    # Generate self-signed certificate valid for 1 day
    openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
        -keyout "$cert_dir/privkey.pem" \
        -out "$cert_dir/fullchain.pem" \
        -subj "/CN=$domain" >/dev/null 2>&1

    log_success "Temporary certificate generated (will be replaced)"
}

# Get SSL certificate using Let's Encrypt
get_ssl_certificate() {
    log_step "Setting up SSL certificate..."

    local domain="$TUNNEL_DOMAIN"
    local email="$SSL_EMAIL"

    if [[ -z "$email" ]]; then
        log_warning "No email provided, skipping SSL certificate"
        log_info "You can obtain it later with: certbot certonly --webroot -w ./certs/www -d $domain"
        return
    fi

    log_info "Attempting to get SSL certificate for $domain"

    # Check if certificate already exists and is valid
    if [[ -f "$CERT_DIR/letsencrypt/live/$domain/fullchain.pem" ]]; then
        # Check if certificate is self-signed (temporary)
        if openssl x509 -in "$CERT_DIR/letsencrypt/live/$domain/fullchain.pem" -noout -subject 2>/dev/null | grep -q "CN=$domain"; then
            log_info "Temporary certificate found, obtaining real certificate..."
        else
            log_info "Valid certificate already exists"
            return
        fi
    fi

    # Get certificate using certbot container
    if docker compose run --rm certbot certonly --webroot \
        --webroot-path=/var/www/certbot \
        -d "$domain" \
        --email "$email" \
        --agree-tos \
        --no-eff-email 2>&1 | grep -v "setlocale"; then

        log_success "SSL certificate obtained"
        return 0
    else
        log_warning "Failed to obtain SSL certificate"
        log_info "You can obtain it later using certbot manually"
        return 1
    fi
}

# Restart nginx to reload SSL certificate
restart_nginx() {
    log_info "Restarting nginx to load SSL certificate..."

    docker compose restart nginx >/dev/null 2>&1

    sleep 3

    log_success "nginx restarted"
}
start_services() {
    log_step "Starting services..."

    # Load .env file
    # shellcheck source=/dev/null
    source "$ENV_FILE"

    # Start Docker Compose
    if docker compose version &>/dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi

    log_success "Services started"
}

# Show status and next steps
show_status() {
    echo
    log_success "Installation completed!"
    echo
    log_info "Configuration Summary:"
    echo "  Tunnel Domain: $TUNNEL_DOMAIN"
    echo "  HTTP Port: $NGINX_HTTP_PORT"
    echo "  HTTPS Port: $NGINX_HTTPS_PORT"
    echo "  FRPS Port: $FRPS_PORT"
    echo "  Auth Token: $FRP_AUTH_TOKEN"
    if [[ "$DASHBOARD_ENABLED" == "true" ]]; then
        echo "  Dashboard: http://<server-ip>:$DASHBOARD_PORT"
    fi
    echo

    log_info "Client Configuration:"
    echo "  Server Address: <server-ip>"
    echo "  Server Port: $FRPS_PORT"
    echo "  Auth Token: $FRP_AUTH_TOKEN"
    echo
}

# Main installation flow
main() {
    show_banner
    echo

    check_prerequisites
    collect_config
    create_directories
    generate_env
    generate_frps_config
    generate_nginx_config

    # SSL certificate & Services
    local ssl_obtained=false
    local needs_nginx_restart=false

    if [[ "$SKIP_SSL" == "true" ]]; then
        log_warning "Skipping SSL certificate acquisition"
        log_info "You can obtain it later with: certbot certonly --webroot -w ./certs/www -d $TUNNEL_DOMAIN"
    elif [[ -n "$SSL_EMAIL" ]]; then
        # Generate temporary certificate for nginx to start
        generate_temp_certificate
    fi

    # Start services
    if [[ "$AUTO_START" == "true" ]]; then
        echo
        start_services
        sleep 3
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
        log_info "Services not started. Start them with: docker compose up -d"
        show_status
        return
    else
        echo
        if confirm "Start services now?"; then
            start_services
            sleep 3
        else
            log_info "Services not started. Start them later with: docker compose up -d"
            show_status
            return
        fi
    fi

    # Get real SSL certificate after services are running
    if [[ "$SKIP_SSL" != "true" ]] && [[ -n "$SSL_EMAIL" ]]; then
        echo
        if get_ssl_certificate; then
            ssl_obtained=true
            needs_nginx_restart=true
        fi
    fi

    # Restart nginx with real certificate
    if [[ "$needs_nginx_restart" == "true" ]]; then
        echo
        restart_nginx
    fi

    show_status

}

# Run main function
main "$@"
