#!/usr/bin/env bash

# Frigate Update Script for Proxmox LXC
# Automates updating the docker image inside the container

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

error_exit() {
    echo -e "${RED}Error: $1${NC}"
    exit 1
}

echo -e "${GREEN}Frigate LXC Update Script${NC}"
echo "--------------------------"

# Parse arguments
CT_ID=""
VERSION=""
DO_SNAPSHOT=false
SNAPSHOT_NAME=""

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
    VERSION=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases/latest | grep '"tag_name":' | cut -d '"' -f 4 | sed 's/^v//')
    [ -z "$VERSION" ] && error_exit "Could not fetch latest stable version."
elif [ "$VERSION" = "beta" ]; then
    echo "Fetching latest beta version..."
    VERSION=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases | grep -B 15 '"prerelease": true' | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4 | sed 's/^v//')
    [ -z "$VERSION" ] && error_exit "Could not fetch latest beta version."
fi

# Fetch Versions (Interactive if not provided or auto-detected)
if [ -z "$VERSION" ]; then
    echo "Fetching latest versions from GitHub..."
    # Fetch releases
    RELEASES=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases)
    AVAILABLE_VERSIONS=$(echo "$RELEASES" | grep '"tag_name":' | head -n 10 | cut -d '"' -f 4 | sed 's/^v//')
    
    # Identify latest stable (non-beta, non-rc) for default
    STABLE_DEFAULT=$(echo "$AVAILABLE_VERSIONS" | grep -vE "beta|rc" | head -n 1)
    [ -z "$STABLE_DEFAULT" ] && STABLE_DEFAULT=$(echo "$AVAILABLE_VERSIONS" | head -n 1)

    if [ -z "$AVAILABLE_VERSIONS" ]; then
        echo "Warning: Could not fetch versions. Defaulting to manual input."
        read -p "Enter version tag to update to (default: 0.16.4): " VERSION
        VERSION=${VERSION:-0.16.4}
    else
        echo "Available Versions:"
        PS3="Select a version: "
        # Use read -r for the menu so we can handle empty input (Enter)
        select opt in $AVAILABLE_VERSIONS "Custom"; do
            # handle case where user just hits enter
            if [ -z "$opt" ] && [ -z "$REPLY" ]; then
                 VERSION=$STABLE_DEFAULT
                 echo "Using default stable version: $VERSION"
                 break
            fi

            if [ "$opt" = "Custom" ]; then
                read -p "Enter custom version tag: " VERSION
                [ -n "$VERSION" ] && break
            elif [ -n "$opt" ]; then
                VERSION=$opt
                break
            else
                # If they hit enter without a choice, select doesn't always return empty. 
                # In some shells, select waits. To be safe, we check if REPLY is empty.
                if [ -z "$REPLY" ]; then
                    VERSION=$STABLE_DEFAULT
                    echo "Using default stable version: $VERSION"
                    break
                fi
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
    if [ -z "$SNAPSHOT_NAME" ]; then
        SNAPSHOT_NAME="Before-$VERSION-Update"
    fi
    # Proxmox snapshots name: Alphanumeric and dashes only
    SNAPSHOT_NAME=$(echo "$SNAPSHOT_NAME" | sed 's/[^a-zA-Z0-9-]/-/g')
    
    echo "Taking snapshot: $SNAPSHOT_NAME..."
    pct snapshot "$CT_ID" "$SNAPSHOT_NAME" --description "Automated snapshot before update to $VERSION"
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
