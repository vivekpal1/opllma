#!/usr/bin/env bash

# ██████╗ ██████╗ ██╗     ██╗     ███╗   ███╗ █████╗ 
# ██╔══██╗██╔══██╗██║     ██║     ████╗ ████║██╔══██╗
# ██║  ██║██████╔╝██║     ██║     ██╔████╔██║███████║
# ██║  ██║██╔═══╝ ██║     ██║     ██║╚██╔╝██║██╔══██║
# ██████╔╝██║     ███████╗███████╗██║ ╚═╝ ██║██║  ██║
# ╚═════╝ ╚═╝     ╚══════╝╚══════╝╚═╝     ╚═╝╚═╝  ╚═╝
# Open WebUI Deployment Script v2.1

set -eo pipefail

# Configuration
ENV_FILE=".webui.env"
NETWORK_NAME="ollama-network"
OLLAMA_CONTAINER="ollama"
WEBUI_CONTAINER="open-webui"
GPU_SUPPORT=true
AUTO_OPEN_BROWSER=true
LOG_FILE="webui_deploy.log"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize logging
exec > >(tee -a "$LOG_FILE") 2>&1

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

check_dependencies() {
    local deps=("docker" "curl")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "Required dependency $dep not found"
        fi
    done
}

validate_env() {
    [ -f "$ENV_FILE" ] || {
        cat > "$ENV_FILE" <<-EOL
# Web Search Configuration
SEARCH_PROVIDER=serper
SEARCH_API_KEY=your_api_key_here
SEARCH_URL=https://google.serper.dev/search

# WebUI Configuration
WEBUI_SECRET_KEY=$(openssl rand -hex 32)
ENABLE_SIGNUP=true
DEFAULT_MODEL=deepseek-r1

# Network Configuration
OLLAMA_HOST=ollama
OLLAMA_PORT=11434
WEBUI_PORT=3000
EOL
        info "Created default environment file: $ENV_FILE"
    }
    source "$ENV_FILE"
}

gpu_support() {
    if [ "$GPU_SUPPORT" = true ] && nvidia-smi &> /dev/null; then
        local gpu_args="--gpus all"
        info "NVIDIA GPU detected - enabling GPU support"
        echo "$gpu_args"
    fi
}

network_setup() {
    if ! docker network inspect "$NETWORK_NAME" &> /dev/null; then
        docker network create "$NETWORK_NAME" || error "Failed to create network"
        success "Created Docker network: $NETWORK_NAME"
    fi
}

container_management() {
    local container=$1
    local image=$2
    local args=$3

    if docker ps -a --format '{{.Names}}' | grep -q "^${container}\$"; then
        info "Restarting existing container: $container"
        docker start "$container" || error "Failed to start $container"
    else
        info "Creating new container: $container"
        docker run -d --network "$NETWORK_NAME" \
            --name "$container" \
            $args \
            "$image" || error "Failed to create $container"
    fi
}

health_check() {
    info "Performing health checks..."
    
    # Check Ollama API
    local ollama_status
    ollama_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${OLLAMA_PORT}")
    [ "$ollama_status" -eq 200 ] || error "Ollama service not responding"

    # Check WebUI
    local webui_status
    webui_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${WEBUI_PORT}")
    [ "$webui_status" -eq 200 ] || error "WebUI not responding"

    success "All services operational"
}

cleanup() {
    info "Resetting environment..."
    docker stop "$OLLAMA_CONTAINER" "$WEBUI_CONTAINER" 2> /dev/null || true
    docker rm "$OLLAMA_CONTAINER" "$WEBUI_CONTAINER" 2> /dev/null || true
    docker volume rm ollama open-webui 2> /dev/null || true
    success "Reset complete"
}

main() {
    check_dependencies
    validate_env

    # Cleanup if requested
    [ "$1" = "--reset" ] && { cleanup; exit 0; }

    network_setup

    # Ollama Container
    container_management "$OLLAMA_CONTAINER" "ollama/ollama" \
        "-v ollama:/root/.ollama \
         -p ${OLLAMA_PORT}:11434 \
         $(gpu_support)"

    # WebUI Container
    container_management "$WEBUI_CONTAINER" "ghcr.io/open-webui/open-webui:main" \
        "-p ${WEBUI_PORT}:8080 \
         -v open-webui:/app/backend/data \
         --env-file ${ENV_FILE}"

    sleep 10  # Wait for services to initialize
    health_check

    if [ "$AUTO_OPEN_BROWSER" = true ]; then
        info "Launching WebUI in default browser..."
        xdg-open "http://localhost:${WEBUI_PORT}" || true
    fi

    success "Deployment complete! Access WebUI at: http://localhost:${WEBUI_PORT}"
}

# Handle command line arguments
case "$1" in
    "--reset") main "$1" ;;
    "--help")  echo "Usage: $0 [--reset|--help]" ;;
    *)         main ;;
esac
