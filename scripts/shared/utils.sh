#!/bin/bash
# FRP Tunnel Deployment - Shared Utility Functions
# This library provides common functions for server and client scripts

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_step() {
    echo -e "${BLUE}==>${NC} $*"
}

# Error handling
die() {
    log_error "$@"
    exit 1
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Check if running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $0"
    fi
}

# Detect system architecture
detect_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l)
            echo "armv7"
            ;;
        *)
            die "Unsupported architecture: $arch"
            ;;
    esac
}

# Detect OS type
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

# Get latest frp version from GitHub
get_latest_frp_version() {
    local api_url="https://api.github.com/repos/fatedier/frp/releases/latest"
    if command_exists curl; then
        curl -s "$api_url" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/v//'
    elif command_exists wget; then
        wget -qO- "$api_url" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/v//'
    else
        die "Neither curl nor wget is available"
    fi
}

# Download frp binary
download_frp() {
    local version=$1
    local binary=$2
    local arch=$3
    local output_dir=$4

    local filename="frp_${version}_linux_${arch}"
    local url="https://github.com/fatedier/frp/releases/download/v${version}/${filename}.tar.gz"
    local tar_file="${output_dir}/${filename}.tar.gz"

    log_step "Downloading frp ${version} for linux_${arch}..."

    if command_exists curl; then
        curl -L -o "$tar_file" "$url"
    elif command_exists wget; then
        wget -O "$tar_file" "$url"
    else
        die "Neither curl nor wget is available"
    fi

    log_step "Extracting ${binary}..."
    tar -xzf "$tar_file" -C "$output_dir" --strip-components=1 "${filename}/${binary}"
    chmod +x "${output_dir}/${binary}"

    # Cleanup
    rm -f "$tar_file"

    log_success "${binary} ${version} installed to ${output_dir}"
}

# Generate random token
generate_token() {
    local length=${1:-32}
    openssl rand -base64 "$length" | tr -d '/+=' | head -c "$length"
}

# Prompt user for input with default value
prompt_input() {
    local prompt=$1
    local default_value=$2
    local result

    if [[ -n "$default_value" ]]; then
        prompt="$prompt [$default_value]"
    fi

    read -rp "$prompt: " result
    echo "${result:-$default_value}"
}

# Prompt for password (hidden input)
prompt_password() {
    local prompt=$1
    local password
    local password_confirm

    while true; do
        read -rsp "$prompt: " password
        echo
        read -rsp "Confirm password: " password_confirm
        echo

        if [[ "$password" == "$password_confirm" ]]; then
            if [[ -n "$password" ]]; then
                echo "$password"
                return 0
            else
                log_error "Password cannot be empty"
            fi
        else
            log_error "Passwords do not match"
        fi
    done
}

# Confirm action
confirm() {
    local prompt=$1
    local response

    read -rp "${prompt} [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]]
}

# Check if port is in use
check_port() {
    local port=$1
    if ss -tuln | grep -q ":${port} "; then
        return 0
    fi
    return 1
}

# Validate domain name
validate_domain() {
    local domain=$1
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

# Validate subdomain
validate_subdomain() {
    local subdomain=$1
    if [[ ! "$subdomain" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        return 1
    fi
    return 0
}

# Template replacement
replace_template_vars() {
    local template_file=$1
    local output_file=$2
    shift 2
    local vars=("$@")

    cp "$template_file" "$output_file"

    for var in "${vars[@]}"; do
        local key="${var%%=*}"
        local value="${var#*=}"
        value="${value//\//\\/}"
        sed -i "s|{{${key}}}|${value}|g" "$output_file"
    done
}

# Create systemd service file
create_systemd_service() {
    local service_name=$1
    local service_file="/etc/systemd/system/${service_name}.service"
    local exec_start=$2
    local description=$3
    local user=${4:-root}
    local working_dir=${5:-}

    cat > "$service_file" <<EOF
[Unit]
Description=${description}
After=network.target

[Service]
Type=simple
User=${user}
ExecStart=${exec_start}
Restart=on-failure
RestartSec=5s
$(if [[ -n "$working_dir" ]]; then echo "WorkingDirectory=${working_dir}"; fi)

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_success "Systemd service created: ${service_name}"
}

# Export functions for use in other scripts
export -f log_info log_success log_warning log_error log_step
export -f die command_exists require_root detect_arch detect_os
export -f get_latest_frp_version download_frp generate_token
export -f prompt_input prompt_password confirm
export -f check_port validate_domain validate_subdomain
export -f replace_template_vars create_systemd_service
