#!/bin/bash
# Add subdomain configuration to portal nginx
# Usage: ./add-subdomain.sh <ssh_key> <portal_host> <subdomain> <server_name> [password]

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[Portal]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }

if [[ $# -lt 4 ]]; then
    log_error "Usage: $0 <ssh_key> <portal_host> <subdomain> <server_name> [password]"
    exit 1
fi

# Expand SSH key path before making readonly
SSH_KEY_PATH="${1/#\~/$HOME}"
readonly SSH_KEY="$SSH_KEY_PATH"
readonly PORTAL_HOST="$2"
readonly SUBDOMAIN="$3"
readonly SERVER_NAME="$4"
readonly PASSWORD="${5:-}"

log_info "Adding subdomain configuration to portal..."
log_info "  Subdomain: $SUBDOMAIN.$SERVER_NAME"
log_info "  Portal: $PORTAL_HOST"

# Generate password if not provided
HTTP_PASSWORD="$PASSWORD"
if [[ -z "$HTTP_PASSWORD" ]]; then
    HTTP_PASSWORD=$(openssl rand -base64 16 | tr -d "/+=" | head -16)
    log_info "  Generated password: $HTTP_PASSWORD"
fi

# Create directories on portal
log_info "Creating directories..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "root@${PORTAL_HOST}" \
    "mkdir -p /root/frp-tunnel/server/configs/subdomains /root/frp-tunnel/server/configs/htpasswd"

# Generate .htpasswd file
log_info "Configuring Basic Auth..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "root@${PORTAL_HOST}" \
    "echo \"${SUBDOMAIN}:\$(openssl passwd -1 '${HTTP_PASSWORD}')\" > /root/frp-tunnel/server/configs/htpasswd/${SUBDOMAIN}.htpasswd"

# Generate nginx subdomain configuration
log_info "Generating nginx configuration..."
readonly SUBDOMAIN_CONF="/tmp/${SUBDOMAIN}.conf.$$"
cat > "$SUBDOMAIN_CONF" << EOF
# Subdomain configuration for ${SUBDOMAIN}.${SERVER_NAME}

server {
    listen 80;
    server_name ${SUBDOMAIN}.${SERVER_NAME};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${SUBDOMAIN}.${SERVER_NAME};

    # SSL certificate
    ssl_certificate /etc/letsencrypt/live/${SUBDOMAIN}.${SERVER_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SUBDOMAIN}.${SERVER_NAME}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    auth_basic "${SUBDOMAIN^} Dev Host";
    auth_basic_user_file /etc/nginx/.htpasswd/${SUBDOMAIN}.htpasswd;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;

    access_log /var/log/nginx/${SUBDOMAIN}_access.log main;
    error_log /var/log/nginx/${SUBDOMAIN}_error.log warn;

    location / {
        proxy_pass http://frps:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

# Upload configuration
log_info "Uploading configuration..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "$SUBDOMAIN_CONF" \
    "root@${PORTAL_HOST}:/root/frp-tunnel/server/configs/subdomains/${SUBDOMAIN}.conf"

rm -f "$SUBDOMAIN_CONF"

# Reload nginx
log_info "Reloading nginx..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "root@${PORTAL_HOST}" \
    "cd /root/frp-tunnel/server && docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload"

log_success "Subdomain configuration complete!"
log_info "URL: https://${SUBDOMAIN}.${SERVER_NAME}"
log_info "Username: ${SUBDOMAIN}"
log_info "Password: ${HTTP_PASSWORD}"
