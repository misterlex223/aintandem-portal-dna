#!/bin/bash
# FRP Tunnel Server - Installation Script
# This script sets up the frp server with Docker Compose

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
        if ! confirm "Continue without root? Some features may not work"; then
            die "Please run with sudo"
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

    # Check if ports are available
    local ports=(80 443 7000 7500)
    for port in "${ports[@]}"; do
        if check_port "$port"; then
            log_warning "Port $port is already in use"
            if ! confirm "Continue anyway?"; then
                die "Installation cancelled"
            fi
        fi
    done

    log_success "Prerequisites check passed"
}

# Collect configuration
collect_config() {
    log_step "Collecting configuration..."

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
    else
        NGINX_HTTP_PORT="80"
        NGINX_HTTPS_PORT="443"
        FRPS_PORT="7000"
        FRPS_VHOST_HTTP_PORT="8080"
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
FRP_VERSION=0.60.0
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
        -e "s|{{TUNNEL_DOMAIN}}|$TUNNEL_DOMAIN|g" \
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
get_ssl_certificate() {
    log_step "Setting up SSL certificate..."

    local domain="$TUNNEL_DOMAIN"
    local email="$SSL_EMAIL"
    local staging="--staging"

    log_info "Attempting to get SSL certificate for *.$domain"
    log_info "First attempt will use Let's Encrypt staging server"

    # Create temporary nginx for standalone certbot
    docker run --rm -d \
        --name frp-temp-nginx \
        -p 80:80 \
        -v "$CERT_DIR/www:/var/www/certbot" \
        nginx:alpine

    sleep 2

    # Get certificate
    if docker run --rm \
        -v "$CERT_DIR/letsencrypt:/etc/letsencrypt" \
        -v "$CERT_DIR/www:/var/www/certbot" \
        certbot/certbot:latest \
        certonly --webroot \
        -w "/var/www/certbot" \
        -d "*.$domain" \
        --email "$email" \
        --agree-tos \
        --no-eff-email \
        $staging; then

        log_success "Staging certificate obtained"

        # Now get production certificate
        docker stop frp-temp-nginx >/dev/null 2>&1

        log_info "Getting production certificate..."
        docker run --rm -d \
            --name frp-temp-nginx \
            -p 80:80 \
            -v "$CERT_DIR/www:/var/www/certbot" \
            nginx:alpine

        sleep 2

        if docker run --rm \
            -v "$CERT_DIR/letsencrypt:/etc/letsencrypt" \
            -v "$CERT_DIR/www:/var/www/certbot" \
            certbot/certbot:latest \
            certonly --webroot \
            -w "/var/www/certbot" \
            -d "*.$domain" \
            --email "$email" \
            --agree-tos \
            --no-eff-email \
            --force-renewal; then
            log_success "Production certificate obtained"
        else
            log_warning "Production certificate failed, using staging certificate"
        fi
    else
        log_warning "Failed to obtain SSL certificate"
        log_info "You can obtain it later using certbot manually"
    fi

    docker stop frp-temp-nginx >/dev/null 2>&1
}

# Start services
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
    log_info "Service Status:"
    echo

    if docker compose version &>/dev/null; then
        docker compose ps
    else
        docker-compose ps
    fi

    echo
    log_info "Configuration Summary:"
    echo "  Tunnel Domain: $TUNNEL_DOMAIN"
    echo "  HTTP Port: $NGINX_HTTP_PORT"
    echo "  HTTPS Port: $NGINX_HTTPS_PORT"
    echo "  FRPS Port: $FRPS_PORT"
    if [[ "$DASHBOARD_ENABLED" == "true" ]]; then
        echo "  Dashboard: http://<server-ip>:$DASHBOARD_PORT"
    fi
    echo

    log_info "DNS Configuration:"
    echo "  Add the following A record to your DNS:"
    echo "    *.tunnel  A  <server-ip>"
    echo

    log_info "Client Configuration:"
    echo "  Server Address: <server-ip>"
    echo "  Server Port: $FRPS_PORT"
    echo "  Auth Token: $FRP_AUTH_TOKEN"
    echo

    log_info "To view logs:"
    echo "  docker compose logs -f"
    echo

    log_info "To manage services:"
    echo "  docker compose stop    # Stop services"
    echo "  docker compose start   # Start services"
    echo "  docker compose restart # Restart services"
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

    echo
    if confirm "Get SSL certificate now?"; then
        get_ssl_certificate
    else
        log_warning "Skipping SSL certificate. Remember to obtain it before starting services."
        log_info "You can get it later with: certbot certonly --webroot -w ./certs/www -d *.$TUNNEL_DOMAIN"
    fi

    echo
    if confirm "Start services now?"; then
        start_services
        sleep 2
        show_status
    else
        log_info "Services not started. Start them later with: docker compose up -d"
    fi
}

# Run main function
main "$@"
