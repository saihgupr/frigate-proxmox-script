#!/usr/bin/env bash

# Frigate Update Script for Proxmox LXC
# Automates updating the docker image inside the container

set -e

# Colors
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}Frigate LXC Update Script${NC}"
echo "--------------------------"

# Get Container ID
read -p "Enter Container ID: " CT_ID

# Verify container exists and is running
if ! pct status "$CT_ID" | grep -q "running"; then
    echo "Error: Container $CT_ID is not running or does not exist."
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

echo "Pulling new image..."
pct exec "$CT_ID" -- docker compose -f /opt/frigate/docker-compose.yml pull

echo "Recreating container..."
pct exec "$CT_ID" -- docker compose -f /opt/frigate/docker-compose.yml up -d

echo -e "${GREEN}Update complete!${NC}"
echo "Check http://<YOUR_FRIGATE_IP>:5000/api/version"
