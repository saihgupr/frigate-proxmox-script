#!/usr/bin/env bash

# Frigate Update Script for Proxmox LXC
# Automates updating the docker image inside the container

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Set terminal title
echo -ne "\033]0;Frigate Proxmox Script\007"

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[DONE]${NC} $1"
}

log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

error_exit() {
    echo -e "${RED}Error: $1${NC}"
    exit 1
}

echo -e "${GREEN}Frigate Proxmox Update Script${NC}"
echo "--------------------------"

# Parse arguments
CT_ID=""
VERSION=""
DO_SNAPSHOT=false
SNAPSHOT_NAME=""
DO_PRUNE=false
AUTO_PRUNE_LIMIT=5 # GB

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--id|--container|-c)
            CT_ID="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -s|--snapshot)
            DO_SNAPSHOT=true
            if [[ -n "$2" && "$2" != -* ]]; then
                SNAPSHOT_NAME="$2"
                shift 2
            else
                shift
            fi
            ;;
        -p|--prune)
            DO_PRUNE=true
            shift
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$CT_ID" ]; then
                CT_ID="$1"
            elif [ -z "$VERSION" ] && [[ ! "$1" =~ ^- ]]; then
                VERSION="$1"
            fi
            shift
            ;;
    esac
done

# Fallback to interactive prompt if not provided
if [ -z "$CT_ID" ]; then
    read -p "Enter Container ID: " CT_ID
fi

# Verify container exists and is running
if ! pct status "$CT_ID" | grep -q "running"; then
    echo "Error: Container $CT_ID is not running or does not exist."
    if [ -f "./install.sh" ]; then
        echo ""
        echo -e "${YELLOW}Did you mean to run ./install.sh instead?${NC}"
        echo "This script is for updating an EXISTING installation."
    fi
    exit 1
fi

# Handle latest/beta keywords
if [ "$VERSION" = "latest" ]; then
    echo "Fetching latest stable version..."
    VERSION=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases/latest | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d '"' -f 4 | sed 's/^v//')
    [ -z "$VERSION" ] && error_exit "Could not fetch latest stable version."
elif [ "$VERSION" = "beta" ]; then
    echo "Fetching latest beta version..."
    VERSION=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases | grep -B 15 '"prerelease": true' | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d '"' -f 4 | sed 's/^v//')
    [ -z "$VERSION" ] && error_exit "Could not fetch latest beta version."
fi

# Fetch Versions (Interactive if not provided or auto-detected)
if [ -z "$VERSION" ]; then
    echo "Fetching latest versions from GitHub..."
    # Fetch releases
    RELEASES=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases)
    AVAILABLE_VERSIONS=$(echo "$RELEASES" | grep -o '"tag_name": *"[^"]*"' | head -n 10 | cut -d '"' -f 4 | sed 's/^v//')
    
    if [ -z "$AVAILABLE_VERSIONS" ]; then
        echo "Warning: Could not fetch versions. Defaulting to manual input."
        read -p "Enter version tag to update to (default: 0.16.4): " VERSION
        VERSION=${VERSION:-0.16.4}
    else
        echo "Available Versions:"
        # Convert to array for manual indexing
        mapfile -t VERSION_ARRAY <<< "$AVAILABLE_VERSIONS"
        for i in "${!VERSION_ARRAY[@]}"; do
            echo " $((i+1))) ${VERSION_ARRAY[$i]}"
        done
        CUSTOM_INDEX=$(( ${#VERSION_ARRAY[@]} + 1 ))
        echo " $CUSTOM_INDEX) Custom"

        while true; do
            read -p "Select a version [1-$CUSTOM_INDEX] (default: 1): " choice
            choice=${choice:-1}

            if [[ "$choice" -eq "$CUSTOM_INDEX" ]]; then
                read -p "Enter custom version tag: " VERSION
                [ -n "$VERSION" ] && break
            elif [[ "$choice" -ge 1 && "$choice" -le "${#VERSION_ARRAY[@]}" ]]; then
                VERSION="${VERSION_ARRAY[$((choice-1))]}"
                break
            else
                echo "Invalid selection."
            fi
        done
    fi
fi

# Snapshot handling prompt (only if not already set by flags)
if [ "$DO_SNAPSHOT" = false ]; then
    echo -n "Take a snapshot before updating? (Y/n): "
    read -r snap_choice
    snap_choice=${snap_choice:-Y}
    if [[ "$snap_choice" =~ ^[Yy]$ ]]; then
        DO_SNAPSHOT=true
    fi
fi


if [ "$DO_SNAPSHOT" = true ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    if [ -z "$SNAPSHOT_NAME" ]; then
        SNAPSHOT_NAME="snapshot_${TIMESTAMP}"
    else
        # If user provided a custom name, append timestamp to make it unique
        SNAPSHOT_NAME="${SNAPSHOT_NAME}_${TIMESTAMP}"
    fi
    # Proxmox snapshots name: Alphanumeric, underscores, and dashes only
    SNAPSHOT_NAME=$(echo "$SNAPSHOT_NAME" | sed 's/[^a-zA-Z0-9_-]/_/g')
    
    echo "Taking snapshot: $SNAPSHOT_NAME..."
    if pct snapshot "$CT_ID" "$SNAPSHOT_NAME" --description "Automated snapshot before update to $VERSION"; then
        log_success "Snapshot $SNAPSHOT_NAME created"
    else
        echo -e "${YELLOW}Warning: Failed to create snapshot '$SNAPSHOT_NAME'. Continuing update anyway...${NC}"
    fi
fi

# Function to check disk space
check_container_space() {
    log_step "Checking available disk space in container $CT_ID..."
    local avail_kb
    avail_kb=$(pct exec "$CT_ID" -- df / --output=avail | tail -1 | xargs)
    local avail_gb=$((avail_kb / 1024 / 1024))
    
    if [ "$avail_gb" -lt "$AUTO_PRUNE_LIMIT" ]; then
        echo -e "${YELLOW}Warning: Only ${avail_gb}GB available on container root disk.${NC}"
        echo -n "Would you like to prune unused Docker images and layers to free up space? (Y/n): "
        read -r prune_choice
        prune_choice=${prune_choice:-Y}
        if [[ "$prune_choice" =~ ^[Yy]$ ]]; then
            echo "Pruning Docker system..."
            pct exec "$CT_ID" -- docker system prune -a -f
            # Re-check space
            avail_kb=$(pct exec "$CT_ID" -- df / --output=avail | tail -1 | xargs)
            avail_gb=$((avail_kb / 1024 / 1024))
            echo "Space after pruning: ${avail_gb}GB"
        fi
    else
        echo "Available disk space: ${avail_gb}GB (Requirement: >${AUTO_PRUNE_LIMIT}GB)"
    fi
}

if [ "$DO_PRUNE" = true ]; then
    echo "Pruning Docker system in container $CT_ID..."
    pct exec "$CT_ID" -- docker system prune -a -f
    [ "$VERSION" = "" ] && exit 0 # Exit if only pruning was requested
fi

check_container_space

echo "Updating container $CT_ID to version $VERSION..."

# update docker-compose.yml inside the container using sed
# We look for the image: line and replace the tag
pct exec "$CT_ID" -- bash -c "sed -i 's|image: ghcr.io/blakeblackshear/frigate:.*|image: ghcr.io/blakeblackshear/frigate:$VERSION|' /opt/frigate/docker-compose.yml"
# Remove obsolete version line to suppress warnings
pct exec "$CT_ID" -- bash -c "sed -i '/^version:/d' /opt/frigate/docker-compose.yml"

echo "Pulling new image..."
pct exec "$CT_ID" -- docker compose -f /opt/frigate/docker-compose.yml pull

echo "Recreating container..."
pct exec "$CT_ID" -- docker compose -f /opt/frigate/docker-compose.yml up -d


echo -e "${GREEN}Update complete!${NC}"
# Get container IP
CT_IP=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
echo -e "Check \033]8;;http://${CT_IP}:5000/api/version\007http://${CT_IP}:5000/api/version\033]8;;\007"
