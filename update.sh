#!/usr/bin/env bash

# Frigate Update Script for Proxmox LXC
# Automates updating the docker image inside the container

set -e

# Colors
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}Frigate LXC Update Script${NC}"
echo "--------------------------"

# Parse arguments
CT_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--id|--container)
            CT_ID="$2"
            shift 2
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                CT_ID="$1"
                shift
            else
                shift
            fi
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

# Fetch Versions
echo "Fetching latest versions from GitHub..."
# Fetch releases, grab tag_name, limit to top 10, strip "v" prefix, and format into a list
AVAILABLE_VERSIONS=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases | grep '"tag_name":' | head -n 10 | cut -d '"' -f 4 | sed 's/^v//')

if [ -z "$AVAILABLE_VERSIONS" ]; then
    echo "Warning: Could not fetch versions. Defaulting to manual input."
    read -p "Enter version tag to update to (default: 0.17.0-rc1): " VERSION
    VERSION=${VERSION:-0.17.0-rc1}
else
    echo "Available Versions:"
    PS3="Select a version (or choose 'Custom'): "
    select opt in $AVAILABLE_VERSIONS "Custom"; do
        if [ "$opt" = "Custom" ]; then
            read -p "Enter custom version tag: " VERSION
            [ -n "$VERSION" ] && break
        elif [ -n "$opt" ]; then
            VERSION=$opt
            break
        else
            echo "Invalid selection."
        fi
    done
fi

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
echo "Check http://${CT_IP}:5000/api/version"
