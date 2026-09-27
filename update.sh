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
FRIGATE_DIR=""
COMPOSE_FILE=""
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
        --dir)
            FRIGATE_DIR="$2"
            [ -n "$FRIGATE_DIR" ] || error_exit "--dir requires an install path, for example /home/frigate."
            shift 2
            ;;
        --dir=*)
            FRIGATE_DIR="${1#*=}"
            [ -n "$FRIGATE_DIR" ] || error_exit "--dir requires an install path, for example /home/frigate."
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

# Helper: find latest built dev tag on GHCR
# Uses curl for all network calls (reliable on Proxmox), python3 only for JSON parsing
resolve_dev_version() {
    echo "Fetching latest built dev version from GHCR..."

    # Step 1: Get 10 most recent commit SHAs from the dev branch
    local SHAS
    SHAS=$(curl -s -H "User-Agent: Mozilla/5.0" \
        "https://api.github.com/repos/blakeblackshear/frigate/commits?sha=dev&per_page=10" \
        | python3 -c "import sys,json; [print(c['sha'][:7]) for c in json.load(sys.stdin)]" 2>/dev/null)

    if [ -z "$SHAS" ]; then
        error_exit "Could not fetch dev branch commits from GitHub."
    fi

    # Step 2: Get a public GHCR read token
    local TOKEN
    TOKEN=$(curl -s \
        "https://ghcr.io/token?service=ghcr.io&scope=repository:blakeblackshear/frigate:pull" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)

    if [ -z "$TOKEN" ]; then
        error_exit "Could not fetch GHCR authentication token."
    fi

    # Step 3: Loop through SHAs, find the newest one that's fully built on GHCR
    local SHA HTTP_CODE
    for SHA in $SHAS; do
        HTTP_CODE=$(curl -s -o /dev/null -I -w "%{http_code}" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
            "https://ghcr.io/v2/blakeblackshear/frigate/manifests/$SHA")
        if [ "$HTTP_CODE" = "200" ]; then
            VERSION="$SHA"
            echo "Resolved dev version: $VERSION"
            return 0
        fi
    done

    error_exit "No built dev tag found among the 10 most recent commits."
}

# Handle latest/beta/dev keywords
if [ "$VERSION" = "latest" ]; then
    echo "Fetching latest stable version..."
    VERSION=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases/latest | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d '"' -f 4 | sed 's/^v//')
    [ -z "$VERSION" ] && error_exit "Could not fetch latest stable version."
elif [ "$VERSION" = "beta" ]; then
    echo "Fetching latest beta version..."
    VERSION=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases | grep -B 15 '"prerelease": true' | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d '"' -f 4 | sed 's/^v//')
    [ -z "$VERSION" ] && error_exit "Could not fetch latest beta version."
elif [ "$VERSION" = "dev" ]; then
    resolve_dev_version
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
        DEV_INDEX=$(( ${#VERSION_ARRAY[@]} + 1 ))
        CUSTOM_INDEX=$(( ${#VERSION_ARRAY[@]} + 2 ))
        echo " $DEV_INDEX) dev (latest built dev branch commit)"
        echo " $CUSTOM_INDEX) Custom"

        while true; do
            read -p "Select a version [1-$CUSTOM_INDEX] (default: 1): " choice
            choice=${choice:-1}

            if [[ "$choice" -eq "$CUSTOM_INDEX" ]]; then
                read -p "Enter custom version tag: " VERSION
                [ -n "$VERSION" ] && break
            elif [[ "$choice" -eq "$DEV_INDEX" ]]; then
                resolve_dev_version
                break
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

log_step "Locating Frigate compose file in container $CT_ID..."
if [ -n "$FRIGATE_DIR" ] && [[ ! "$FRIGATE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    error_exit "Invalid --dir path '$FRIGATE_DIR'. Use an absolute path such as /home/frigate."
fi

search_dirs=""
if [ -n "$FRIGATE_DIR" ]; then
    search_dirs="$FRIGATE_DIR"
else
    wd=$(pct exec "$CT_ID" -- docker inspect frigate --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
    if [ -n "$wd" ] && [ "$wd" != "<no value>" ]; then
        search_dirs="$wd"
    fi
    search_dirs="$search_dirs /opt/frigate /home/frigate /root/frigate /srv/frigate /mnt/frigate"
fi

FRIGATE_IMAGE_RE="^[[:space:]]*image:[[:space:]]*[\"']?(ghcr\.io/)?blakeblackshear/frigate:"

is_frigate_compose() {
    pct exec "$CT_ID" -- grep -E -q "$FRIGATE_IMAGE_RE" "$1" 2>/dev/null
}

skipped_files=""
for dir in $search_dirs; do
    dir="${dir%/}"
    for name in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
        if ! pct exec "$CT_ID" -- test -f "$dir/$name"; then
            continue
        fi
        if ! is_frigate_compose "$dir/$name"; then
            log_info "Skipping $dir/$name (no blakeblackshear/frigate image found)"
            skipped_files="$skipped_files $dir/$name"
            continue
        fi
        COMPOSE_FILE="$dir/$name"
        break
    done
    if [ -n "$COMPOSE_FILE" ]; then
        break
    fi
done

if [ -z "$COMPOSE_FILE" ] && [ -z "$FRIGATE_DIR" ]; then
    COMPOSE_FILE=$(pct exec "$CT_ID" -- bash -c 'find /home /opt /root /srv /mnt -maxdepth 4 \( -name compose.yml -o -name compose.yaml -o -name docker-compose.yml -o -name docker-compose.yaml \) -print 2>/dev/null | while IFS= read -r f; do grep -E -q "$1" "$f" && printf "%s\n" "$f" && break; done' bash "$FRIGATE_IMAGE_RE" || true)
fi

if [ -z "$COMPOSE_FILE" ]; then
    if [ -n "$FRIGATE_DIR" ]; then
        if [ -n "$skipped_files" ]; then
            error_exit "Found compose file(s) in $FRIGATE_DIR inside container $CT_ID, but none use the blakeblackshear/frigate image:$skipped_files"
        fi
        error_exit "Could not find compose.yml, compose.yaml, docker-compose.yml, or docker-compose.yaml in $FRIGATE_DIR inside container $CT_ID."
    fi
    error_exit "Could not find a Frigate compose file inside container $CT_ID. Searched /opt/frigate, /home/frigate, and other common paths. Re-run with --dir /path/to/install if Frigate lives somewhere else."
fi
log_info "Found Frigate compose file: $COMPOSE_FILE"

if [ "$COMPOSE_FILE" = "/opt/frigate/docker-compose.yml" ] && pct exec "$CT_ID" -- bash -c '[ ! -f /opt/frigate/compose.yml ]'; then
    log_info "Legacy docker-compose.yml detected. Migrating to compose.yml..."
    pct exec "$CT_ID" -- mv /opt/frigate/docker-compose.yml /opt/frigate/compose.yml
    COMPOSE_FILE="/opt/frigate/compose.yml"
fi

echo "Updating container $CT_ID to version $VERSION..."
echo "Compose file: $COMPOSE_FILE"

sed_version=$(printf '%s' "$VERSION" | sed -e 's/[\\&|]/\\&/g')
pct exec "$CT_ID" -- sed -E -i "s|(image:[[:space:]]*[\"']?)(ghcr.io/)?blakeblackshear/frigate:[^\"'[:space:]]*|\1ghcr.io/blakeblackshear/frigate:${sed_version}|" "$COMPOSE_FILE"

if ! pct exec "$CT_ID" -- grep -F -q "blakeblackshear/frigate:${VERSION}" "$COMPOSE_FILE"; then
    error_exit "Could not update the Frigate image tag in $COMPOSE_FILE. The image line was not in a recognized format."
fi

# Only drop the obsolete top-level version: key once the image update is confirmed
pct exec "$CT_ID" -- sed -i '/^version:/d' "$COMPOSE_FILE"

compose_dir=$(dirname "$COMPOSE_FILE")
compose_base=$(basename "$COMPOSE_FILE")

echo "Pulling new image..."
pct exec "$CT_ID" -- bash -c 'cd "$1" && docker compose -f "$2" pull' bash "$compose_dir" "$compose_base"

echo "Recreating container..."
pct exec "$CT_ID" -- bash -c 'cd "$1" && docker compose -f "$2" up -d' bash "$compose_dir" "$compose_base"


echo -e "${GREEN}Update complete!${NC}"
# Get container IP
CT_IP=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
echo -e "Check \033]8;;http://${CT_IP}:5000/api/version\007http://${CT_IP}:5000/api/version\033]8;;\007"
