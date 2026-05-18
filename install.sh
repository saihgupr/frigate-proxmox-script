#!/usr/bin/env bash

# Frigate NVR Docker Installation Script for Proxmox VE
# Optimized for Beelink S12 with Intel iGPU Hardware Acceleration
# Author: Created for Proxmox VE 7.0+
# License: MIT

set -euo pipefail

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

VERSION="1.3.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/frigate-install-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=false
VERBOSE=false
REBOOT_REQUIRED=false
PVE_VERSION=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Set terminal title
echo -ne "\033]0;Frigate Proxmox Script\007"

# Container Configuration
CT_ID=""
CT_HOSTNAME="frigate"
CT_PRIVILEGED=0  # Security default: use unprivileged LXC
CT_CORES=4
CT_RAM=2048
CT_DISK=10
CT_STORAGE=""
CT_VLAN=""
CT_MTU=""
CT_BRIDGE="vmbr0"
CT_NETWORK_TYPE="dhcp"
CT_IP=""
CT_GATEWAY=""
CT_DNS="8.8.8.8"
# Default (will be updated dynamically during install)
DEBIAN_TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"
TEMPLATE_STORAGE=""

# Frigate Configuration
FRIGATE_VERSION="stable"  # Docker tag: stable, beta, or specific version
ENABLE_IGPU="yes"
FRIGATE_PORT="5000"
GO2RTC_PORT="1984"
AUTH_PORT="8971"
SHM_SIZE="256mb"
ENABLE_SSH="no"
SSH_USER="root"
SSH_PASSWORD=""
ENABLE_FIREWALL="yes"
ENABLE_SAMBA="no"
SAMBA_PASSWORD=""
ROOT_PASSWORD=""
DO_SNAPSHOT=false
SNAPSHOT_NAME=""


# Hardware Detection Result Strings
DETECTED_CPU=""
DETECTED_GPU="none"
GPU_TYPES_FOUND=() # Array to store all found GPU types (intel, amd, nvidia)
SELECTED_GPU_TYPE="none"
DETECTED_RENDER_NODES=() # Array to store found render nodes
SELECTED_RENDER_NODE="/dev/dri/renderD128"
DETECTED_CORAL="none"
GPU_PRESET="preset-vaapi" # Default to VAAPI (Intel/AMD)
ENABLE_YOLO_MODEL=false
YOLO_MODEL_SIZE="s"
YOLO_IMG_SIZE="640"
YOLO_MODEL_PATH=""

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $*" | tee -a "$LOG_FILE"
}

log_dry_run() {
    echo -e "${MAGENTA}[DRY-RUN]${NC} Would execute: $*" | tee -a "$LOG_FILE"
}

execute() {
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "$*"
    else
        if [ "$VERBOSE" = true ]; then
            log "Executing: $*"
        fi
        eval "$*" 2>&1 | tee -a "$LOG_FILE"
    fi
}

# Detect storage pools by content type (e.g., images, vztmpl)
# Check if storage is active with a timeout to prevent hanging on offline CIFS/NFS
is_storage_active() {
    local storage=$1
    if [ -z "$storage" ]; then
        return 1
    fi

    # Use a subshell to isolate any pipe failures if pipefail is on
    local active=1
    if command -v timeout &>/dev/null; then
        if timeout 5 pvesm status -storage "$storage" 2>/dev/null | grep -q "active"; then
            active=0
        fi
    else
        if pvesm status -storage "$storage" 2>/dev/null | grep -q "active"; then
            active=0
        fi
    fi
    return $active
}

# Detect storage pools by content type (e.g., images, vztmpl)
get_storage_pools() {
    local content_type=$1
    local pools=()
    
    # Get initial list
    local raw_pools
    raw_pools=$(pvesm status -content "$content_type" 2>/dev/null | awk 'NR>1 {print $1}')
    
    for p in $raw_pools; do
        if is_storage_active "$p"; then
            echo "$p"
        fi
    done
}

# Helper for interactive storage selection
select_storage_pool() {
    local content_type=$1
    local default_hint=$2
    local prompt_msg=$3
    local pools=($(get_storage_pools "$content_type"))

    if [ ${#pools[@]} -eq 0 ]; then
        log_warn "No storage pools found for content type '$content_type'."
        read -p "Enter custom storage pool name: " selected_val
        echo "$selected_val"
        return
    fi

    # Identify default index
    local default_index=""
    for i in "${!pools[@]}"; do
        if [[ "${pools[$i]}" == "$default_hint" ]]; then
            default_index=$((i+1))
            break
        fi
    done
    
    # Fallback default heuristics
    if [ -z "$default_index" ]; then
        # 1. Look for common VM/Image storage names
        for i in "${!pools[@]}"; do
            if [[ "${pools[$i]}" =~ local-lvm|local-zfs|zfspool|data|storage|pve-storage ]]; then
                default_index=$((i+1))
                break
            fi
        done
        
        # 2. If still no match, look for 'local'
        if [ -z "$default_index" ]; then
            for i in "${!pools[@]}"; do
                if [[ "${pools[$i]}" == "local" ]]; then
                    default_index=$((i+1))
                    break
                fi
            done
        fi
        
        # 3. Final fallback: first available pool
        [ -z "$default_index" ] && default_index=1
    fi

    echo "Available storage pools supporting '$content_type':" >&2
    for i in "${!pools[@]}"; do
        echo "  $((i+1))) ${pools[$i]}" >&2
    done
    echo "  $(( ${#pools[@]} + 1 ))) Custom" >&2

    local choice
    local def_name="${pools[$((default_index-1))]}"
    read -p "$prompt_msg [default: $default_index ($def_name)]: " choice
    choice=${choice:-$default_index}

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le "${#pools[@]}" ]; then
        echo "${pools[$((choice-1))]}"
    elif [ "$choice" -eq "$(( ${#pools[@]} + 1 ))" ]; then
        read -p "Enter custom storage pool name: " custom_val
        echo "$custom_val"
    else
        echo "$def_name"
    fi
}

execute_in_container() {
    local cmd="$*"
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "pct exec $CT_ID -- bash -c '$cmd'"
    else
        pct exec "$CT_ID" -- bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE"
    fi
}

error_exit() {
    log_error "$1"
    log_error "Installation failed! Check log file: $LOG_FILE"
    
    if [ -n "$CT_ID" ] && pct status "$CT_ID" &>/dev/null; then
        echo ""
        read -p "Container $CT_ID was created. Delete it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Destroying container $CT_ID..."
            pct stop "$CT_ID" 2>/dev/null || true
            pct destroy "$CT_ID" 2>/dev/null || true
            log_success "Container $CT_ID destroyed."
        fi
    fi
    
    exit 1
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

check_proxmox() {
    log_step "Checking Proxmox environment..."
    
    if ! command -v pveversion &> /dev/null; then
        error_exit "This script must be run on a Proxmox VE host!"
    fi
    
    # Extract version for compatibility checks (e.g., 8.2)
    PVE_VERSION=$(pveversion | grep "pve-manager" | cut -d'/' -f2 | cut -d'-' -f1 | cut -d'.' -f1,2)
    log_success "Running on Proxmox VE $PVE_VERSION"
}

check_root() {
    log_step "Checking privileges..."
    
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root!"
    fi
    
    log_success "Running as root"
}

check_resources() {
    if [ -z "$CT_STORAGE" ]; then
        return
    fi
    
    log_step "Checking available resources on storage pool: $CT_STORAGE..."
    
    if ! is_storage_active "$CT_STORAGE"; then
        log_warn "Storage pool '$CT_STORAGE' is currently inactive or unreachable. Skipping space check."
        return
    fi

    # Use a more robust way to get storage info that doesn't crash with set -e
    local storage_info
    storage_info=$(pvesm status -storage "$CT_STORAGE" 2>/dev/null | awk 'NR>1 {print $0}' || true)
    
    if [ -z "$storage_info" ]; then
        log_warn "Could not retrieve status for storage pool '$CT_STORAGE'. Skipping specific space check."
        return
    fi
    
    # Example pvesm status output:
    # Name             Type     Status           Total            Used            Available        %
    # local-lvm        lvmthin  active           93782016         12345678        81436338         13.16%

    local total used avail pct
    # Use awk to safely extract fields
    total=$(echo "$storage_info" | awk '{print $4}' || echo "0")
    used=$(echo "$storage_info" | awk '{print $5}' || echo "0")
    avail=$(echo "$storage_info" | awk '{print $6}' || echo "0")
    pct=$(echo "$storage_info" | awk '{print $7}' | tr -d '%' || echo "0")
    
    if [[ ! "$avail" =~ ^[0-9]+$ ]]; then
        log_warn "Could not parse available space for '$CT_STORAGE'. Skipping check."
        return
    fi

    local avail_gb=$((avail / 1024 / 1024))
    local pct_int=${pct%%.*}

    if [ "$avail_gb" -lt 10 ]; then
        log_warn "Low space on pool '$CT_STORAGE': Only ${avail_gb}GB available. Recommended: 10GB+ for rootfs."
    elif [ "$pct_int" -gt 90 ]; then
        log_warn "Storage pool '$CT_STORAGE' is ${pct}% full. This may cause issues during operation."
    else
        log_success "Storage pool '$CT_STORAGE' has ${avail_gb}GB available (${pct}% used)."
    fi
}

check_hardware() {
    log_step "Detecting hardware..."
    
    # CPU Detection
    if command -v lscpu &>/dev/null; then
        DETECTED_CPU=$(lscpu | grep "Model name" | cut -d: -f2 | xargs || echo "Unknown")
    else
        DETECTED_CPU=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs || echo "Unknown")
    fi
    log "CPU: $DETECTED_CPU"

    # GPU Detection
    GPU_TYPES_FOUND=()
    DETECTED_RENDER_NODES=()
    
    # 1. PCI Hardware Detection (Physical presence)
    local pci_output
    pci_output=$(lspci -nn 2>/dev/null || true)
    
    if echo "$pci_output" | grep -qi "intel"; then
        GPU_TYPES_FOUND+=("intel")
    fi
    if echo "$pci_output" | grep -qi "amd"; then
        GPU_TYPES_FOUND+=("amd")
    fi
    if echo "$pci_output" | grep -qi "nvidia"; then
        GPU_TYPES_FOUND+=("nvidia")
    fi

    # 2. Device Node Detection (Driver status)
    if [ -d "/dev/dri" ]; then
        DETECTED_RENDER_NODES=($(ls /dev/dri/renderD* 2>/dev/null || true))
    fi

    # 3. Logic for selection and warnings
    if [ ${#GPU_TYPES_FOUND[@]} -eq 0 ] && [ ${#DETECTED_RENDER_NODES[@]} -gt 0 ]; then
        # Render nodes exist but didn't match intel/amd/nvidia - likely generic VAAPI
        GPU_TYPES_FOUND+=("vaapi")
    fi

    # Check for NVIDIA tools if hardware found
    if [[ " ${GPU_TYPES_FOUND[*]} " == *" nvidia "* ]]; then
        if ! command -v nvidia-smi &>/dev/null; then
            log_warn "NVIDIA GPU hardware detected, but 'nvidia-smi' not found on host!"
            log_warn "Ensure the NVIDIA driver is installed on Proxmox host for passthrough to work."
        fi
    fi
    
    # Set initial DETECTED_GPU based on priority
    if [ ${#GPU_TYPES_FOUND[@]} -eq 1 ]; then
        SELECTED_GPU_TYPE="${GPU_TYPES_FOUND[0]}"
        case "$SELECTED_GPU_TYPE" in
            intel) DETECTED_GPU="Intel iGPU"; GPU_PRESET="preset-vaapi" ;;
            amd) DETECTED_GPU="AMD GPU"; GPU_PRESET="preset-vaapi" ;;
            nvidia) DETECTED_GPU="NVIDIA GPU"; GPU_PRESET="preset-nvidia" ;;
            vaapi) DETECTED_GPU="Generic VAAPI"; GPU_PRESET="preset-vaapi" ;;
        esac
    elif [ ${#GPU_TYPES_FOUND[@]} -gt 1 ]; then
        DETECTED_GPU="Multiple (${GPU_TYPES_FOUND[*]})"
        # We'll let the user select later
    fi
    
    # Verify driver existence on host for Intel/AMD/VAAPI
    if [[ "$SELECTED_GPU_TYPE" == "intel" || "$SELECTED_GPU_TYPE" == "amd" || "$SELECTED_GPU_TYPE" == "vaapi" ]]; then
        if [ ${#DETECTED_RENDER_NODES[@]} -eq 0 ]; then
            log_warn "GPU detected via lspci but no render nodes found in /dev/dri/!"
            log_warn "This usually means the host drivers are not loaded."
            log_warn "Try: apt-get install -y intel-media-va-driver-non-free (for Intel)"
            DETECTED_GPU="none"
            SELECTED_GPU_TYPE="none"
        fi
    fi
    
    if [ "$DETECTED_GPU" != "none" ]; then
        log_success "Detected GPU: $DETECTED_GPU"
        if [ ${#DETECTED_RENDER_NODES[@]} -gt 1 ]; then
            log "Found ${#DETECTED_RENDER_NODES[@]} render nodes: ${DETECTED_RENDER_NODES[*]}"
        fi
    else
        log_warn "No integrated or dedicated GPU detected for hardware acceleration."
        GPU_PRESET="none"
    fi

    # Coral Detection
    local coral_usb_info
    coral_usb_info=$(lsusb 2>/dev/null | grep -Ei "18d1:9302|1a6e:089a|Google Inc|Global Unichip Corp" | head -n 1 || echo "")

    if [ -n "$coral_usb_info" ]; then
        DETECTED_CORAL="USB"
        log_success "Detected Google Coral (USB)"
        
        # Speed Detection (Issue #19)
        local dev_num=$(echo "$coral_usb_info" | awk '{print $4}' | sed 's/://')
        local speed
        speed=$(lsusb -t 2>/dev/null | grep "Dev $dev_num" | grep -o "[0-9]\+M" | head -n 1 || echo "Unknown")
        
        if [ "$speed" = "480M" ]; then
            log_warn "Coral USB is running at 480Mbps (USB 2.0). Performance may be throttled!"
            log_warn "Recommendation: Use a USB 3.0 (blue) port and verify 'USB3' is enabled in Proxmox passthrough."
        elif [ -n "$speed" ]; then
            log "Coral USB speed: $speed"
        fi
    elif lspci 2>/dev/null | grep -qi "089a\|089b\|Global Unichip Corp"; then
        DETECTED_CORAL="PCIe"
        log_success "Detected Google Coral (PCIe)"
        # Check for host driver (Gasket/EdgeTPU)
        if [ ! -e "/dev/apex_0" ]; then
            log_warn "Coral PCIe hardware seen but /dev/apex_0 not found on Proxmox host!"
            log_warn "You likely need to install host drivers (gasket-dkms, libedgetpu1-std)"
            log_warn "Visit: https://coral.ai/docs/pcie/install/"
        fi
    fi
}

# ============================================================================
# INTERACTIVE CONFIGURATION
# ============================================================================

configure_container() {
    log_step "Configuring LXC container settings..."
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  FRIGATE DOCKER INSTALLATION - Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Container ID
    while true; do
        read -p "Enter Container ID [100-9999] (default: auto): " input_id
        if [ -z "$input_id" ]; then
            CT_ID=$(pvesh get /cluster/nextid)
            log "Auto-selected Container ID: $CT_ID"
            break
        elif [[ "$input_id" =~ ^[0-9]+$ ]] && [ "$input_id" -ge 100 ] && [ "$input_id" -le 9999 ]; then
            if pct status "$input_id" &>/dev/null; then
                log_error "Container ID $input_id already exists!"
            else
                CT_ID="$input_id"
                break
            fi
        else
            log_error "Invalid Container ID. Must be between 100-9999."
        fi
    done
    
    CT_HOSTNAME="frigate"
    
    read -p "Enter CPU cores (default: 4): " input_cores
    CT_CORES="${input_cores:-4}"
    
    read -p "Enter RAM in MB (default: 2048): " input_ram
    CT_RAM="${input_ram:-2048}"
    
    # Storage Configuration
    echo ""
    log_step "Storage Configuration"
    
    # LXC Root Filesystem Storage
    CT_STORAGE=$(select_storage_pool "images" "local-lvm" "Select primary storage partition")
    log "Selected primary storage: $CT_STORAGE"

    # Template Storage (where Debian .tar.zst downloads go)
    echo ""
    TEMPLATE_STORAGE=$(select_storage_pool "vztmpl" "local" "Select storage for LXC templates")
    log "Selected template storage: $TEMPLATE_STORAGE"

    echo ""
    read -p "Enter disk size in GB (default: 10): " input_disk
    CT_DISK="${input_disk:-10}"
    
    # Optional Separate Recordings Disk
    echo ""
    read -p "Add a separate disk for recordings? (y/N): " add_recordings_disk
    if [[ "$add_recordings_disk" =~ ^[Yy]$ ]]; then
        ADD_EXTRA_DISK=true
        echo ""
        EXTRA_DISK_STORAGE=$(select_storage_pool "images" "local-lvm" "Select recordings storage partition")
        log "Selected recordings storage: $EXTRA_DISK_STORAGE"
        
        read -p "Enter recordings disk size in GB (default: 50): " input_extra_disk
        EXTRA_DISK_SIZE="${input_extra_disk:-50}"
    else
        ADD_EXTRA_DISK=false
    fi

    echo ""
    echo "Network Configuration:"

    # Detect available Linux bridges
    local available_bridges
    mapfile -t available_bridges < <(ip link show type bridge 2>/dev/null | awk -F': ' '/^[0-9]+:/{print $2}' | sed 's/@.*//' | grep '^vmbr')
    if [ ${#available_bridges[@]} -eq 0 ]; then
        read -p "Enter network bridge (e.g., vmbr0): " input_bridge
        CT_BRIDGE="${input_bridge:-vmbr0}"
    elif [ ${#available_bridges[@]} -eq 1 ]; then
        CT_BRIDGE="${available_bridges[0]}"
        echo "  Network Bridge:  $CT_BRIDGE (auto-detected)"
    else
        echo "  Available bridges:"
        for i in "${!available_bridges[@]}"; do
            echo "    $((i+1))) ${available_bridges[$i]}"
        done
        while true; do
            read -p "Select network bridge [1-${#available_bridges[@]}] (default: 1): " bridge_choice
            bridge_choice=${bridge_choice:-1}
            if [[ "$bridge_choice" =~ ^[0-9]+$ ]] && [ "$bridge_choice" -ge 1 ] && [ "$bridge_choice" -le "${#available_bridges[@]}" ]; then
                CT_BRIDGE="${available_bridges[$((bridge_choice-1))]}"
                break
            else
                log_error "Invalid selection."
            fi
        done
    fi

    echo "  1) DHCP (automatic)"
    echo "  2) Static IP"
    read -p "Select network type (1/2): " net_choice
    
    if [ "$net_choice" = "2" ]; then
        CT_NETWORK_TYPE="static"
        read -p "Enter IP address with CIDR (e.g., 192.168.1.100/24): " CT_IP
        read -p "Enter gateway (e.g., 192.168.1.1): " CT_GATEWAY
        read -p "Enter DNS server (default: 8.8.8.8): " input_dns
        CT_DNS="${input_dns:-8.8.8.8}"
    else
        CT_NETWORK_TYPE="dhcp"
    fi

    read -p "Enter VLAN tag (optional, press Enter to skip): " input_vlan
    if [ -n "$input_vlan" ]; then
        if [[ "$input_vlan" =~ ^[0-9]+$ ]] && [ "$input_vlan" -ge 1 ] && [ "$input_vlan" -le 4094 ]; then
            CT_VLAN="$input_vlan"
        else
            log_warn "Invalid VLAN tag '$input_vlan' (must be 1-4094). Skipping."
        fi
    fi

    read -p "Enter MTU (optional, press Enter for default): " input_mtu
    if [ -n "$input_mtu" ]; then
        if [[ "$input_mtu" =~ ^[0-9]+$ ]] && [ "$input_mtu" -ge 576 ] && [ "$input_mtu" -le 9000 ]; then
            CT_MTU="$input_mtu"
        else
            log_warn "Invalid MTU '$input_mtu' (must be 576-9000). Skipping."
        fi
    fi
    
    echo ""
    if [ ${#GPU_TYPES_FOUND[@]} -gt 1 ]; then
        log_step "Multiple GPUs detected. Select which one to use for Frigate:"
        options=()
        for type in "${GPU_TYPES_FOUND[@]}"; do
            case "$type" in
                intel) options+=("Intel iGPU (VAAPI)") ;;
                amd) options+=("AMD GPU (VAAPI)") ;;
                nvidia) options+=("NVIDIA GPU (NVDEC/NVENC)") ;;
                vaapi) options+=("Generic VAAPI") ;;
            esac
        done
        options+=("None (CPU only)")
        
        select opt in "${options[@]}"; do
            case "$opt" in
                "Intel iGPU (VAAPI)") SELECTED_GPU_TYPE="intel"; DETECTED_GPU="Intel iGPU"; GPU_PRESET="preset-vaapi"; ENABLE_IGPU="yes"; break ;;
                "AMD GPU (VAAPI)") SELECTED_GPU_TYPE="amd"; DETECTED_GPU="AMD GPU"; GPU_PRESET="preset-vaapi"; ENABLE_IGPU="yes"; break ;;
                "NVIDIA GPU (NVDEC/NVENC)") SELECTED_GPU_TYPE="nvidia"; DETECTED_GPU="NVIDIA GPU"; GPU_PRESET="preset-nvidia"; ENABLE_IGPU="yes"; break ;;
                "Generic VAAPI") SELECTED_GPU_TYPE="vaapi"; DETECTED_GPU="Generic VAAPI"; GPU_PRESET="preset-vaapi"; ENABLE_IGPU="yes"; break ;;
                "None (CPU only)") SELECTED_GPU_TYPE="none"; DETECTED_GPU="none"; ENABLE_IGPU="no"; GPU_PRESET="none"; break ;;
                *) log_error "Invalid selection" ;;
            esac
        done
    elif [ "$DETECTED_GPU" != "none" ]; then
        read -p "Enable hardware acceleration using $DETECTED_GPU? (Y/n): " enable_hwaccel
        if [[ "$enable_hwaccel" =~ ^[Nn]$ ]]; then
            ENABLE_IGPU="no"
            SELECTED_GPU_TYPE="none"
            GPU_PRESET="none"
        else
            ENABLE_IGPU="yes"
        fi
    else
        echo ""
        log_warn "Integrated GPU (iGPU) not detected for hardware-accelerated video decoding."
        if [ "$DETECTED_CORAL" != "none" ]; then
            log "Note: Google Coral ($DETECTED_CORAL) WAS detected and will be used for high-speed object detection."
            log "However, video streams will be decoded using the CPU, which may increase load."
        else
            log "If you have an Intel CPU with iGPU, ensure 'HEVC' or 'iGPU' is enabled in BIOS and drivers are installed on the host."
        fi
        ENABLE_IGPU="no"
    fi

    # Handle multiple render nodes (SR-IOV)
    if [ "$ENABLE_IGPU" = "yes" ] && [ ${#DETECTED_RENDER_NODES[@]} -gt 1 ]; then
        echo ""
        log_step "Multiple render nodes found (Possible SR-IOV). Select which one to use:"
        options=()
        for node in "${DETECTED_RENDER_NODES[@]}"; do
            options+=("$node")
        done
        
        select opt in "${options[@]}"; do
            if [ -n "$opt" ]; then
                SELECTED_RENDER_NODE="$opt"
                log "Selected render node: $SELECTED_RENDER_NODE"
                break
            else
                log_error "Invalid selection"
            fi
        done
    fi
    
    echo ""
    read -p "Enter Frigate web port (default: 5000): " input_port
    FRIGATE_PORT="${input_port:-5000}"
    
    read -p "Enter go2rtc port (default: 1984): " input_go2rtc
    GO2RTC_PORT="${input_go2rtc:-1984}"
    
    read -p "Enter Frigate Auth port (default: 8971): " input_auth
    AUTH_PORT="${input_auth:-8971}"
    
    while true; do
        read -p "Enter Frigate SHM size (default: 512mb): " input_shm
        input_shm="${input_shm:-512mb}"
        
        # Append 'mb' if only numbers provided
        if [[ "$input_shm" =~ ^[0-9]+$ ]]; then
            input_shm="${input_shm}mb"
        fi
        
        # Validate format (number followed by b, k, m, g)
        if [[ ! "$input_shm" =~ ^[0-9]+([bkmg]|[bkmg]b)$ ]]; then
            log_error "Invalid SHM size format! Use e.g. 512mb, 1gb, 256m"
            continue
        fi

        # Extract numeric value in MB for comparison with RAM
        local shm_val_mb=0
        local num=$(echo "$input_shm" | grep -oE '^[0-9]+')
        local unit=$(echo "$input_shm" | grep -oE '[a-zA-Z]+' | tr '[:upper:]' '[:lower:]')
        
        case "$unit" in
            g|gb) shm_val_mb=$((num * 1024)) ;;
            m|mb) shm_val_mb=$num ;;
            k|kb) shm_val_mb=$((num / 1024)) ;;
            b) shm_val_mb=1 ;; # negligible
        esac

        if [ "$shm_val_mb" -ge "$CT_RAM" ]; then
            log_warn "SHM size ($input_shm) is larger than or equal to total RAM (${CT_RAM}MB)!"
            log_warn "This will cause the container to crash. Please increase RAM or decrease SHM."
            read -p "Increase RAM to $((shm_val_mb + 512))MB? (Y/n): " confirm_ram
            if [[ ! "$confirm_ram" =~ ^[Nn]$ ]]; then
                CT_RAM=$((shm_val_mb + 512))
                log "Updated RAM to ${CT_RAM}MB"
            else
                continue
            fi
        fi
        
        SHM_SIZE="$input_shm"
        break
    done

    echo ""
    echo "Frigate Docker Image:"
    echo "  1) stable (recommended)"
    echo "  2) beta"
    echo "  3) dev (latest built dev branch commit)"
    echo "  4) Custom tag"
    read -p "Select version (1-4): " version_choice

    # Helper: resolve latest built dev tag from GHCR
    # Uses curl for all network calls (reliable on Proxmox), python3 only for JSON parsing
    resolve_dev_version_install() {
        echo -n "Fetching latest built dev version from GHCR... "

        # Step 1: Get 10 most recent commit SHAs from the dev branch
        local SHAS
        SHAS=$(curl -s -H "User-Agent: Mozilla/5.0" \
            "https://api.github.com/repos/blakeblackshear/frigate/commits?sha=dev&per_page=10" \
            | python3 -c "import sys,json; [print(c['sha'][:7]) for c in json.load(sys.stdin)]" 2>/dev/null)

        if [ -z "$SHAS" ]; then
            echo "Failed!"
            echo "Could not fetch dev branch commits from GitHub."
            return 1
        fi

        # Step 2: Get a public GHCR read token
        local TOKEN
        TOKEN=$(curl -s \
            "https://ghcr.io/token?service=ghcr.io&scope=repository:blakeblackshear/frigate:pull" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)

        if [ -z "$TOKEN" ]; then
            echo "Failed!"
            echo "Could not fetch GHCR authentication token."
            return 1
        fi

        # Step 3: Loop through SHAs, find the newest one that's fully built on GHCR
        local SHA HTTP_CODE
        for SHA in $SHAS; do
            HTTP_CODE=$(curl -s -o /dev/null -I -w "%{http_code}" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
                "https://ghcr.io/v2/blakeblackshear/frigate/manifests/$SHA")
            if [ "$HTTP_CODE" = "200" ]; then
                FRIGATE_VERSION="$SHA"
                echo "$FRIGATE_VERSION"
                return 0
            fi
        done

        echo "Failed!"
        echo "No built dev tag found among the 10 most recent commits."
        return 1
    }
    
    case $version_choice in
        2) 
           echo -n "Fetching latest beta version... "
           # Use || true to prevent script exit if grep finds nothing (set -e is active)
           LATEST_BETA=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases | grep -B 15 '"prerelease": true' | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4 | sed 's/^v//' || true)
           # Fallback if detection failed
           if [ -z "$LATEST_BETA" ]; then
               LATEST_BETA="0.17.0-beta2"
           fi
           FRIGATE_VERSION="$LATEST_BETA"
           echo "$FRIGATE_VERSION"
           ;;
        3) resolve_dev_version_install ;;
        4) read -p "Enter custom tag (e.g., 0.14.1): " custom_tag
           FRIGATE_VERSION="$custom_tag" ;;
        *) FRIGATE_VERSION="stable" ;;
    esac
    
    echo ""

    # YOLOv9 model (only for OpenVINO-capable GPUs)
    if [ "$SELECTED_GPU_TYPE" = "intel" ] || [ "$SELECTED_GPU_TYPE" = "amd" ] || [ "$SELECTED_GPU_TYPE" = "vaapi" ]; then
        echo ""
        echo -n "Use custom YOLOv9 model (OpenVINO)? More accurate than default SSD. (y/N): "
        read -r yolo_choice
        if [[ "$yolo_choice" =~ ^[Yy]$ ]]; then
            ENABLE_YOLO_MODEL=true
            echo ""
            echo "Model size (larger = more accurate, slower on iGPU):"
            echo " 1) t - Tiny    (fastest)"
            echo " 2) s - Small   [recommended]"
            echo " 3) m - Medium"
            echo " 4) c - Large"
            echo " 5) e - Extra Large (slowest)"
            while true; do
                read -p "Select [1-5] (default: 2): " size_choice
                size_choice=${size_choice:-2}
                case "$size_choice" in
                    1) YOLO_MODEL_SIZE="t"; break ;;
                    2) YOLO_MODEL_SIZE="s"; break ;;
                    3) YOLO_MODEL_SIZE="m"; break ;;
                    4) YOLO_MODEL_SIZE="c"; break ;;
                    5) YOLO_MODEL_SIZE="e"; break ;;
                    *) log_error "Invalid selection" ;;
                esac
            done
            echo ""
            echo "Image size:"
            echo " 1) 320 (faster)"
            echo " 2) 640 (more accurate) [recommended]"
            while true; do
                read -p "Select [1-2] (default: 2): " img_choice
                img_choice=${img_choice:-2}
                case "$img_choice" in
                    1) YOLO_IMG_SIZE="320"; break ;;
                    2) YOLO_IMG_SIZE="640"; break ;;
                    *) log_error "Invalid selection" ;;
                esac
            done
            YOLO_MODEL_PATH="/config/model_cache/yolo/yolov9-${YOLO_MODEL_SIZE}-${YOLO_IMG_SIZE}.onnx"
            log_success "YOLOv9-${YOLO_MODEL_SIZE} at ${YOLO_IMG_SIZE}px selected (export runs after installation)"
        fi
    fi

    echo ""
    echo ""
    log_step "Security Configuration"
    
    # Root Password (Always required)
    while true; do
        echo "Set the root password for the container (required for console access):"
        read -sp "Root Password: " ROOT_PASSWORD
        echo ""
        
        if [ -z "$ROOT_PASSWORD" ]; then
            log_error "Password cannot be empty!"
            continue
        fi
        
        read -sp "Confirm Root Password: " root_pass_confirm
        echo ""
        
        if [ "$ROOT_PASSWORD" = "$root_pass_confirm" ]; then
            break
        else
            log_error "Passwords do not match! Please try again."
            echo ""
        fi
    done
    
    echo ""
    read -p "Enable SSH access? (Y/n): " enable_ssh
    enable_ssh=${enable_ssh:-Y}
    
    if [[ "$enable_ssh" =~ ^[Yy]$ ]]; then
        ENABLE_SSH="yes"
        SSH_USER="root"
        
        # Reuse root password for SSH user
        SSH_PASSWORD="$ROOT_PASSWORD"
        log "SSH password will match the root password."
    else
        ENABLE_SSH="no"
    fi

    # Container Security Level (Privileged vs Unprivileged)
    echo ""
    log_step "Container Security"
    
    local recommend_privileged=false
    local reason=""
    
    # Simple version comparison for PVE < 8.2
    local pve_major=$(echo "$PVE_VERSION" | cut -d. -f1)
    local pve_minor=$(echo "$PVE_VERSION" | cut -d. -f2)
    local pve_below_82=false
    if [ "$pve_major" -lt 8 ] || { [ "$pve_major" -eq 8 ] && [ "$pve_minor" -lt 2 ]; }; then
        pve_below_82=true
    fi

    if [ "$SELECTED_GPU_TYPE" = "nvidia" ]; then
        recommend_privileged=true
        reason="NVIDIA GPU detected (Privileged mode is significantly easier for NVIDIA drivers)"
    elif [ "$DETECTED_CORAL" = "PCIe" ]; then
        recommend_privileged=true
        reason="Coral PCIe detected (Privileged mode recommended for Gasket/Apex drivers)"
    elif [ "$pve_below_82" = true ]; then
        recommend_privileged=true
        reason="Proxmox version $PVE_VERSION is < 8.2 (Native dev[n] passthrough requires 8.2+)"
    fi

    echo "Select container security level:"
    if [ "$recommend_privileged" = true ]; then
        echo "  1) Privileged (Recommended - $reason)"
        echo "  2) Unprivileged (Higher security, but hardware passthrough might fail on this setup)"
        read -p "Selection [default: 1]: " security_choice
        security_choice=${security_choice:-1}
    else
        echo "  1) Privileged (Legacy mode, lower security)"
        echo "  2) Unprivileged (Recommended - Modern, higher security) [default]"
        read -p "Selection [default: 2]: " security_choice
        security_choice=${security_choice:-2}
    fi

    if [ "$security_choice" = "1" ]; then
        CT_PRIVILEGED=1
        log "Selected: Privileged Container (Security: Lower, Compatibility: High)"
    else
        CT_PRIVILEGED=0
        log "Selected: Unprivileged Container (Security: High, Compatibility: Modern)"
    fi
    
    echo ""
    read -p "Enable Samba file sharing (config & storage only, password required)? (y/N): " enable_samba
    enable_samba=${enable_samba:-N}
    if [[ "$enable_samba" =~ ^[Yy]$ ]]; then
        ENABLE_SAMBA="yes"
        while true; do
            read -sp "Enter Samba password for user 'frigate': " SAMBA_PASSWORD
            echo ""
            if [ -z "$SAMBA_PASSWORD" ]; then
                log_error "Password cannot be empty!"
                continue
            fi
            read -sp "Confirm Samba password: " samba_confirm
            echo ""
            if [ "$SAMBA_PASSWORD" = "$samba_confirm" ]; then
                break
            else
                log_error "Passwords do not match! Please try again."
            fi
        done
    fi

    echo ""
    read -p "Enable Proxmox firewall on container (opens port $FRIGATE_PORT)? (Y/n): " enable_fw
    enable_fw=${enable_fw:-Y}
    if [[ "$enable_fw" =~ ^[Yy]$ ]]; then
        ENABLE_FIREWALL="yes"
    else
        ENABLE_FIREWALL="no"
    fi

    echo ""
    read -p "Take a snapshot after container creation? (Y/n): " snap_choice
    snap_choice=${snap_choice:-Y}
    if [[ "$snap_choice" =~ ^[Yy]$ ]]; then
        DO_SNAPSHOT=true
    fi
}


show_configuration_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  CONFIGURATION SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Container Settings:"
    echo "  ID:              $CT_ID"
    echo "  Hostname:        $CT_HOSTNAME"
    local security_label="Unprivileged"
    [ "$CT_PRIVILEGED" = "1" ] && security_label="Privileged"
    echo "  Type:            $security_label LXC"
    echo "  CPU Cores:       $CT_CORES"
    echo "  RAM:             ${CT_RAM}MB"
    echo "  Disk:            ${CT_DISK}GB"
    echo "  Storage:         $CT_STORAGE"
    if [ "$ADD_EXTRA_DISK" = true ]; then
        echo "  Recordings:      ${EXTRA_DISK_SIZE}GB on $EXTRA_DISK_STORAGE"
    fi
    echo "  Network Bridge:  $CT_BRIDGE"
    if [ -n "$CT_VLAN" ]; then
        echo "  VLAN Tag:        $CT_VLAN"
    fi
    if [ -n "$CT_MTU" ]; then
        echo "  MTU:             $CT_MTU"
    fi
    echo "  Network Type:    $CT_NETWORK_TYPE"
    if [ "$CT_NETWORK_TYPE" = "static" ]; then
        echo "  IP Address:      $CT_IP"
        echo "  Gateway:         $CT_GATEWAY"
        echo "  DNS:             $CT_DNS"
    fi
    echo ""
    echo "Frigate Settings:"
    echo "  Docker Image:    ghcr.io/blakeblackshear/frigate:$FRIGATE_VERSION"
    echo "  HW Accel:        $ENABLE_IGPU ($DETECTED_GPU)"
    if [ "$ENABLE_IGPU" = "yes" ] && [ "$SELECTED_GPU_TYPE" != "nvidia" ]; then
        echo "  Render Node:     $SELECTED_RENDER_NODE"
    fi
    echo "  Web Port:        $FRIGATE_PORT"
    echo "  go2rtc Port:     $GO2RTC_PORT"
    echo "  Auth Port:       $AUTH_PORT"
    echo "  SHM Size:        $SHM_SIZE"
    if [ "$ENABLE_YOLO_MODEL" = true ]; then
        echo "  YOLO Model:      YOLOv9-${YOLO_MODEL_SIZE} @ ${YOLO_IMG_SIZE}px (OpenVINO)"
    fi
    if [ "$ENABLE_SSH" = "yes" ]; then
        echo "  SSH User:        $SSH_USER"
    fi
    if [ "$ENABLE_SAMBA" = "yes" ]; then
        echo "  Samba:           Enabled (user: frigate, shares: Config + Storage)"
    fi
    echo "  Firewall:        $ENABLE_FIREWALL"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY-RUN MODE: No actual changes will be made"
        echo ""
    fi
    
    read -p "Proceed with installation? (Y/n): " confirm
    confirm=${confirm:-Y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "Installation cancelled by user"
        exit 0
    fi
}

# ============================================================================
# LXC CONTAINER CREATION
# ============================================================================

download_debian_template() {
    log_step "Checking for Debian template..."
    
    check_resources
    
    log "Updating Proxmox appliance database..."
    if [ "$DRY_RUN" = false ]; then
        pveam update || log_warn "Failed to update pveam database. Attempting to proceed..."
    fi

    log "Searching for latest Debian 12 template..."
    # Dynamically find the latest Debian 12 standard template
    local latest_template
    latest_template=$(pveam available -section system 2>/dev/null | grep "debian-12-standard" | sort -V | tail -n 1 | awk '{print $2}')
    
    if [ -n "$latest_template" ]; then
        DEBIAN_TEMPLATE="$latest_template"
        log "Selected template: $DEBIAN_TEMPLATE"
    else
        log_warn "Could not discover Debian 12 template dynamically. Using fallback: $DEBIAN_TEMPLATE"
    fi
    
    if pveam list $TEMPLATE_STORAGE 2>/dev/null | grep -q "$DEBIAN_TEMPLATE"; then
        log_success "Debian template already available"
        return
    fi
    
    log "Downloading $DEBIAN_TEMPLATE..."
    
    if [ "$DRY_RUN" = false ]; then
        pveam download $TEMPLATE_STORAGE "$DEBIAN_TEMPLATE" 2>&1 | tee -a "$LOG_FILE" || error_exit "Failed to download template"
        log_success "Debian template downloaded"
    else
        log_dry_run "Download $DEBIAN_TEMPLATE to $TEMPLATE_STORAGE"
    fi
}

create_lxc_container() {
    log_step "Creating LXC container $CT_ID ($CT_HOSTNAME)..."
    
    local net_config="name=eth0,bridge=$CT_BRIDGE"
    if [ "$CT_NETWORK_TYPE" = "static" ]; then
        net_config="$net_config,ip=$CT_IP,gw=$CT_GATEWAY"
    else
        net_config="$net_config,ip=dhcp"
    fi
    
    if [ -n "$CT_VLAN" ]; then
        net_config="$net_config,tag=$CT_VLAN"
    fi
    if [ -n "$CT_MTU" ]; then
        net_config="$net_config,mtu=$CT_MTU"
    fi
    if [ "$ENABLE_FIREWALL" = "yes" ]; then
        net_config="$net_config,firewall=1"
    fi

    local password_part=""
    if [ -n "$ROOT_PASSWORD" ]; then
        password_part="--password $ROOT_PASSWORD"
    fi
    
    if [ "$DRY_RUN" = false ]; then
        pct create "$CT_ID" "$TEMPLATE_STORAGE:vztmpl/$DEBIAN_TEMPLATE" \
            --hostname "$CT_HOSTNAME" \
            --cores "$CT_CORES" \
            --memory "$CT_RAM" \
            --swap 512 \
            --rootfs "$CT_STORAGE:$CT_DISK" \
            --net0 "$net_config" \
            --onboot 1 \
            --ostype debian \
            --unprivileged $((1 - CT_PRIVILEGED)) \
            --features nesting=1,keyctl=1 \
            $password_part 2>&1 | tee -a "$LOG_FILE" || error_exit "Failed to create container"
        
        log_success "Container created"
    else
        log_dry_run "Create container $CT_ID with template $DEBIAN_TEMPLATE"
    fi
}

configure_lxc_passthrough() {
    log_step "Configuring hardware passthrough..."
    
    local lxc_conf="/etc/pve/lxc/${CT_ID}.conf"
    
    if [ "$DRY_RUN" = false ]; then
        # Common Passthrough for iGPU / Render Nodes
        if [ "$ENABLE_IGPU" = "yes" ]; then
            if [ "$SELECTED_GPU_TYPE" = "intel" ] || [ "$SELECTED_GPU_TYPE" = "amd" ] || [ "$SELECTED_GPU_TYPE" = "vaapi" ]; then
                configure_igpu_passthrough
            elif [ "$SELECTED_GPU_TYPE" = "nvidia" ]; then
                configure_nvidia_passthrough
            fi
        fi
        
        # Coral Passthrough
        if [ "$DETECTED_CORAL" = "PCIe" ]; then
            configure_coral_pcie_passthrough
        fi
        
        log_success "Passthrough configured"
    fi
}

configure_igpu_passthrough() {
    if [[ "$SELECTED_GPU_TYPE" != "intel" && "$SELECTED_GPU_TYPE" != "amd" && "$SELECTED_GPU_TYPE" != "vaapi" ]]; then
        return
    fi
    
    log_step "Configuring iGPU passthrough..."
    
    local lxc_conf="/etc/pve/lxc/${CT_ID}.conf"
    
    # Get device major/minor and GID
    local dev_major=$(stat -c '%t' "$SELECTED_RENDER_NODE")
    dev_major=$((0x$dev_major))
    local dev_minor=$(stat -c '%T' "$SELECTED_RENDER_NODE")
    dev_minor=$((0x$dev_minor))
    
    local render_gid
    render_gid=$(getent group render 2>/dev/null | cut -d: -f3)
    if [ -z "$render_gid" ]; then
        render_gid=$(stat -c '%g' "$SELECTED_RENDER_NODE")
    fi

    # Check PVE version
    local pve_major=$(echo "$PVE_VERSION" | cut -d. -f1)
    local pve_minor=$(echo "$PVE_VERSION" | cut -d. -f2)
    local pve_82_plus=true
    if [ "$pve_major" -lt 8 ] || { [ "$pve_major" -eq 8 ] && [ "$pve_minor" -lt 2 ]; }; then
        pve_82_plus=false
    fi

    if [ "$DRY_RUN" = false ]; then
        if [ "$pve_82_plus" = true ]; then
            # Modern Proxmox 8.2+ way (Works for both Privileged/Unprivileged)
            local dev_slot=0
            while grep -q "^dev${dev_slot}:" "$lxc_conf" 2>/dev/null; do
                dev_slot=$((dev_slot + 1))
            done
            echo "" >> "$lxc_conf"
            echo "# Frigate: iGPU Passthrough + AppArmor" >> "$lxc_conf"
            echo "dev${dev_slot}: $SELECTED_RENDER_NODE,gid=$render_gid" >> "$lxc_conf"
            echo "lxc.apparmor.profile: unconfined" >> "$lxc_conf"
            log_success "iGPU passthrough and AppArmor configured in $lxc_conf"
        else
            # Legacy way (< 8.2)
            echo "" >> "$lxc_conf"
            echo "# Frigate: iGPU Passthrough + AppArmor" >> "$lxc_conf"
            cat >> "$lxc_conf" << EOF
lxc.cgroup2.devices.allow: c $dev_major:$dev_minor rwm
lxc.mount.entry: $SELECTED_RENDER_NODE dev/dri/$(basename "$SELECTED_RENDER_NODE") none bind,optional,create=file
lxc.apparmor.profile: unconfined
EOF
            if [ "$CT_PRIVILEGED" = "0" ]; then
                log_warn "Unprivileged iGPU passthrough on Proxmox < 8.2 may require manual GID mapping."
            fi
            log_success "iGPU passthrough configured using legacy cgroup2 method"
        fi
        REBOOT_REQUIRED=true
    else
        log_dry_run "Add iGPU passthrough configuration to $lxc_conf"
    fi
}

configure_coral_pcie_passthrough() {
    if [ "$DETECTED_CORAL" != "PCIe" ]; then
        return
    fi
    
    log_step "Configuring Google Coral PCIe passthrough..."
    
    local lxc_conf="/etc/pve/lxc/${CT_ID}.conf"
    local apex_dev="/dev/apex_0"
    
    # Check PVE version
    local pve_major=$(echo "$PVE_VERSION" | cut -d. -f1)
    local pve_minor=$(echo "$PVE_VERSION" | cut -d. -f2)
    local pve_82_plus=true
    if [ "$pve_major" -lt 8 ] || { [ "$pve_major" -eq 8 ] && [ "$pve_minor" -lt 2 ]; }; then
        pve_82_plus=false
    fi

    if [ "$DRY_RUN" = false ]; then
        if [ "$pve_82_plus" = true ]; then
            # Modern Proxmox 8.2+ way
            local apex_gid
            apex_gid=$(stat -c '%g' "$apex_dev" 2>/dev/null || echo "0")
            
            local dev_slot=0
            while grep -q "^dev${dev_slot}:" "$lxc_conf" 2>/dev/null; do
                dev_slot=$((dev_slot + 1))
            done
            echo "" >> "$lxc_conf"
            echo "# Frigate: Google Coral PCIe Passthrough" >> "$lxc_conf"
            echo "dev${dev_slot}: $apex_dev,gid=$apex_gid" >> "$lxc_conf"
            log_success "Coral PCIe passthrough configured using modern dev${dev_slot} method"
        else
            # Legacy way
            cat >> "$lxc_conf" << EOF

# Frigate: Google Coral PCIe Passthrough
lxc.cgroup2.devices.allow: c 120:* rwm
lxc.mount.entry: $apex_dev dev/apex_0 none bind,optional,create=file
EOF
            log_success "Coral PCIe passthrough configured using legacy method"
        fi
        REBOOT_REQUIRED=true
    else
        log_dry_run "Add Coral PCIe passthrough configuration to $lxc_conf"
    fi
}

configure_nvidia_passthrough() {
    if [ "$SELECTED_GPU_TYPE" != "nvidia" ]; then
        return
    fi
    
    log_step "Configuring NVIDIA GPU passthrough..."
    
    local lxc_conf="/etc/pve/lxc/${CT_ID}.conf"
    
    # Check PVE version
    local pve_major=$(echo "$PVE_VERSION" | cut -d. -f1)
    local pve_minor=$(echo "$PVE_VERSION" | cut -d. -f2)
    local pve_82_plus=true
    if [ "$pve_major" -lt 8 ] || { [ "$pve_major" -eq 8 ] && [ "$pve_minor" -lt 2 ]; }; then
        pve_82_plus=false
    fi

    if [ "$DRY_RUN" = false ]; then
        if [ "$pve_82_plus" = true ]; then
            # Modern Proxmox 8.2+ way
            local nvidia_devs=(
                "/dev/nvidia0"
                "/dev/nvidiactl"
                "/dev/nvidia-modeset"
                "/dev/nvidia-uvm"
                "/dev/nvidia-uvm-tools"
            )
            
            echo "" >> "$lxc_conf"
            echo "# Frigate: NVIDIA GPU Passthrough + AppArmor" >> "$lxc_conf"
            echo "lxc.apparmor.profile: unconfined" >> "$lxc_conf"
            
            for dev in "${nvidia_devs[@]}"; do
                if [ -c "$dev" ]; then
                    local dev_gid
                    dev_gid=$(stat -c '%g' "$dev" 2>/dev/null || echo "0")
                    
                    local dev_slot=0
                    while grep -q "^dev${dev_slot}:" "$lxc_conf" 2>/dev/null; do
                        dev_slot=$((dev_slot + 1))
                    done
                    echo "dev${dev_slot}: $dev,gid=$dev_gid" >> "$lxc_conf"
                    log "  Mapped $dev to dev${dev_slot} (gid=$dev_gid)"
                fi
            done
            log_success "NVIDIA GPU device nodes configured using modern dev method"
        else
            # Legacy way
            # Device Nodes
            if ! grep -q "nvidia" "$lxc_conf"; then
                # Get major numbers for devices (Resilience for Issue #30)
                local nvidia_major=$(ls -l /dev/nvidiactl 2>/dev/null | awk '{print $5}' | cut -d, -f1 || echo "195")
                local uvm_major=$(ls -l /dev/nvidia-uvm 2>/dev/null | awk '{print $5}' | cut -d, -f1 || echo "511")
                
                cat >> "$lxc_conf" << EOF

# Frigate: NVIDIA GPU Passthrough + AppArmor
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: c $nvidia_major:* rwm
lxc.cgroup2.devices.allow: c $uvm_major:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
EOF
                log_success "NVIDIA GPU device nodes configured in $lxc_conf (Major: $nvidia_major, $uvm_major)"
            fi
        fi

        # Library Mapping (Resilience for Issue #30)
        log "Mapping NVIDIA libraries to container..."
        local lib_list=(
            "libnvidia-ml.so.1"
            "libcuda.so.1"
            "libnvidia-fatbinaryloader.so.1"
            "libnvidia-ptxjitcompiler.so.1"
            "libnvidia-allocator.so.1"
            "libnvidia-cfg.so.1"
            "libnvidia-encode.so.1"
            "libnvidia-decode.so.1"
            "libnvcuvid.so.1"
            "libnvidia-rtcore.so.1"
        )
        
        for lib_name in "${lib_list[@]}"; do
            # Find all potential paths on host (Resilience for Issue #30)
            local host_paths=()
            # 1. Check ldconfig
            local ld_paths
            ld_paths=$(ldconfig -p | grep "$lib_name" | awk '{print $NF}' || true)
            for lp in $ld_paths; do
                host_paths+=("$lp")
            done
            # 2. Check standard paths
            for p in "/usr/lib/x86_64-linux-gnu" "/usr/lib" "/lib/x86_64-linux-gnu"; do
                if [ -f "$p/$lib_name" ]; then
                    host_paths+=("$p/$lib_name")
                fi
            done
            
            # Remove duplicates and process each found path
            if [ ${#host_paths[@]} -gt 0 ]; then
                local unique_paths
                unique_paths=$(echo "${host_paths[@]}" | tr ' ' '\n' | sort -u || true)
                
                for host_path in $unique_paths; do
                    if [ -f "$host_path" ]; then
                        # Resolve symlink to get the real file
                        local real_path
                        real_path=$(readlink -f "$host_path")
                        
                        # Bind mount the path
                        local target_path="${host_path#/}"
                        if ! grep -q "$host_path" "$lxc_conf"; then
                            echo "lxc.mount.entry: $host_path $target_path none bind,optional,create=file" >> "$lxc_conf"
                            log "  Mapped $host_path"
                        fi
                        
                        # Also bind mount the real file if it's different (Resilience for Issue #30)
                        if [ "$real_path" != "$host_path" ] && [ -f "$real_path" ]; then
                            local real_target_path="${real_path#/}"
                            if ! grep -q "$real_path" "$lxc_conf"; then
                                echo "lxc.mount.entry: $real_path $real_target_path none bind,optional,create=file" >> "$lxc_conf"
                                log "  Mapped $real_path (real file)"
                            fi
                        fi
                    fi
                done
            else
                log_warn "Library $lib_name not found on host. Hardware acceleration may fail."
            fi
        done
    else
        log_dry_run "Add NVIDIA passthrough configuration to $lxc_conf"
    fi
}

start_lxc_container() {
    log_step "Starting container..."
    
    if [ "$DRY_RUN" = false ]; then
        pct start "$CT_ID" || error_exit "Failed to start container"
        
        # Wait for network
        log "Waiting for container to initialize network..."
        local counter=0
        while [ $counter -lt 30 ]; do
            if pct exec "$CT_ID" -- ip addr show eth0 | grep -q "inet "; then
                break
            fi
            sleep 1
            counter=$((counter + 1))
        done
        
        log_success "Container $CT_ID is running"
        
        if [ "$SELECTED_GPU_TYPE" = "nvidia" ]; then
            log "Updating library cache inside container..."
            pct exec "$CT_ID" -- ldconfig || log_warn "Failed to run ldconfig inside container."
        fi
    else
        log_dry_run "pct start $CT_ID"
    fi
}

# ============================================================================
# DOCKER INSTALLATION
# ============================================================================

install_docker() {
    log_step "Installing Docker..."
    
    execute_in_container "apt-get update"
    execute_in_container "DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg"
    execute_in_container "install -m 0755 -d /etc/apt/keyrings"
    execute_in_container "curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc"
    execute_in_container "chmod a+r /etc/apt/keyrings/docker.asc"
    
    execute_in_container 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
    
    execute_in_container "apt-get update"
    execute_in_container "DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    
    execute_in_container "systemctl enable docker"
    execute_in_container "systemctl start docker"
    
    log_success "Docker installed"
}

install_nvidia_toolkit() {
    if [ "$SELECTED_GPU_TYPE" != "nvidia" ]; then
        return
    fi
    
    log_step "Installing NVIDIA Container Toolkit..."
    
    execute_in_container 'curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg'
    execute_in_container 'curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list'
    
    execute_in_container "apt-get update"
    execute_in_container "DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit"
    
    execute_in_container "nvidia-ctk runtime configure --runtime=docker"
    execute_in_container "systemctl restart docker"
    
    log_success "NVIDIA Container Toolkit installed"
}

# ============================================================================
# FRIGATE INSTALLATION
# ============================================================================

create_frigate_directories() {
    log_step "Creating Frigate directories..."
    
    execute_in_container "mkdir -p /opt/frigate/config"
    execute_in_container "mkdir -p /opt/frigate/storage"
    
    log_success "Directories created"
}

create_docker_compose() {
    log_step "Creating compose.yml..."
    
    local devices_list=""
    local deploy_config=""

    # 1. Handle GPU Acceleration (NVIDIA vs Others)
    if [ "$ENABLE_IGPU" = "yes" ]; then
        if [ "$SELECTED_GPU_TYPE" = "nvidia" ]; then
            deploy_config="    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu, video]"
        else
            devices_list="      - $SELECTED_RENDER_NODE:$SELECTED_RENDER_NODE"
        fi
    fi

    # 2. Add Coral PCIe if detected
    if [ "$DETECTED_CORAL" = "PCIe" ]; then
        if [ -n "$devices_list" ]; then
            devices_list="$devices_list
      - /dev/apex_0:/dev/apex_0"
        else
            devices_list="      - /dev/apex_0:/dev/apex_0"
        fi
    fi

    # 3. Combine into device_config
    local device_config=""
    if [ -n "$devices_list" ]; then
        device_config="    devices:
$devices_list"
    fi
    
    if [ -n "$deploy_config" ]; then
        if [ -n "$device_config" ]; then
            device_config="$device_config
$deploy_config"
        else
            device_config="$deploy_config"
        fi
    fi
    
    if [ "$DRY_RUN" = false ]; then
        local FRIGATE_RTSP_PASSWORD
        FRIGATE_RTSP_PASSWORD=$(openssl rand -hex 16)

        local group_add_config=""
        if [ "$ENABLE_IGPU" = "yes" ] && [ "$SELECTED_GPU_TYPE" != "nvidia" ]; then
            local render_gid
            render_gid=$(getent group render 2>/dev/null | cut -d: -f3)
            if [ -z "$render_gid" ]; then
                render_gid=$(stat -c '%g' "$SELECTED_RENDER_NODE")
            fi
            group_add_config="    group_add:
      - \"$render_gid\""
        fi

        pct exec "$CT_ID" -- bash -c "cat > /opt/frigate/compose.yml" << EOF
version: "3.9"

services:
  frigate:
    container_name: frigate
    restart: unless-stopped
    stop_grace_period: 30s
    image: ghcr.io/blakeblackshear/frigate:$FRIGATE_VERSION
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
      - ./config:/config
      - ./storage:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    ports:
      - "$FRIGATE_PORT:$FRIGATE_PORT"
$device_config
    environment:
      - FRIGATE_RTSP_PASSWORD=$FRIGATE_RTSP_PASSWORD
      - CONFIG_FILE=/config/config.yml
    cap_add:
      - CAP_PERFMON
    shm_size: "$SHM_SIZE"
$group_add_config
EOF
        log_success "compose.yml created"
    else
        log_dry_run "Create compose.yml"
    fi
}

export_yolo_model() {
    if [ "$ENABLE_YOLO_MODEL" = false ]; then
        return
    fi

    log_step "Exporting YOLOv9-${YOLO_MODEL_SIZE} ONNX model (this may take several minutes)..."

    local model_dir="/opt/frigate/config/model_cache/yolo"
    local model_file="yolov9-${YOLO_MODEL_SIZE}-${YOLO_IMG_SIZE}.onnx"

    if [ "$DRY_RUN" = false ]; then
        pct exec "$CT_ID" -- mkdir -p "$model_dir"

        pct exec "$CT_ID" -- bash -s << EXPORTSCRIPT
cd "$model_dir"
docker build --build-arg MODEL_SIZE=${YOLO_MODEL_SIZE} --build-arg IMG_SIZE=${YOLO_IMG_SIZE} --output . - << 'DOCKERFILE'
FROM python:3.11 AS build
RUN apt-get update && apt-get install --no-install-recommends -y cmake libgl1
COPY --from=ghcr.io/astral-sh/uv:0.10.4 /uv /bin/
WORKDIR /yolov9
ADD https://github.com/WongKinYiu/yolov9.git .
# torch<2.6: weights_only default changed to True in 2.6, breaking YOLOv9's torch.load calls in models/experimental.py
RUN uv pip install --system "torch<2.6" -r requirements.txt
RUN uv pip install --system onnx==1.18.0 onnxruntime onnx-simplifier onnxscript
ARG MODEL_SIZE
ARG IMG_SIZE
ADD https://github.com/WongKinYiu/yolov9/releases/download/v0.1/yolov9-\${MODEL_SIZE}-converted.pt yolov9-\${MODEL_SIZE}.pt
RUN python3 export.py --weights ./yolov9-\${MODEL_SIZE}.pt --imgsz \${IMG_SIZE} --simplify --include onnx
FROM scratch
ARG MODEL_SIZE
ARG IMG_SIZE
COPY --from=build /yolov9/yolov9-\${MODEL_SIZE}.onnx /yolov9-\${MODEL_SIZE}-\${IMG_SIZE}.onnx
DOCKERFILE
EXPORTSCRIPT

        if pct exec "$CT_ID" -- test -f "$model_dir/$model_file"; then
            log_success "Model exported: $model_file"
        else
            log_warn "YOLO model export failed. Falling back to default SSD model."
            log_warn "You can export manually later and update config.yml."
            ENABLE_YOLO_MODEL=false
        fi
    else
        log_dry_run "Export YOLOv9-${YOLO_MODEL_SIZE} (${YOLO_IMG_SIZE}px) ONNX model inside container"
    fi
}

create_frigate_config() {
    log_step "Creating initial Frigate configuration..."
    
    local hwaccel_config=""
    if [ "$ENABLE_IGPU" = "yes" ] && [ "$GPU_PRESET" != "none" ]; then
        hwaccel_config="ffmpeg:
  hwaccel_args: $GPU_PRESET"
    fi

    local go2rtc_config=""
    
    local camera_template="  dummy_camera:
    enabled: false
    ffmpeg:
      inputs:
        - path: rtsp://user:password@camera-ip:554/stream
          roles:
            - detect"

    local detector_config="detectors:
  ov:
    type: openvino
    device: CPU
    model:
      path: /openvino-model/ssdlite_mobilenet_v2.xml"
    
    if [ "$DETECTED_CORAL" = "USB" ]; then
        detector_config="detectors:
  coral:
    type: edgetpu
    device: usb"
    elif [ "$DETECTED_CORAL" = "PCIe" ]; then
        detector_config="detectors:
  coral:
    type: edgetpu
    device: pci"
    elif [ "$SELECTED_GPU_TYPE" = "intel" ] || [ "$SELECTED_GPU_TYPE" = "amd" ] || [ "$SELECTED_GPU_TYPE" = "vaapi" ]; then
        detector_config="detectors:
  ov:
    type: openvino
    device: GPU"
        if [ "$ENABLE_YOLO_MODEL" = false ]; then
            detector_config="$detector_config
    model:
      path: /openvino-model/ssdlite_mobilenet_v2.xml"
        fi
    fi

    local yolo_model_config=""
    if [ "$ENABLE_YOLO_MODEL" = true ]; then
        yolo_model_config="model:
  model_type: yolo-generic
  width: $YOLO_IMG_SIZE
  height: $YOLO_IMG_SIZE
  input_tensor: nchw
  input_dtype: float
  path: $YOLO_MODEL_PATH
  labelmap_path: /labelmap/coco-80.txt"
    elif [ "$SELECTED_GPU_TYPE" = "intel" ] || [ "$SELECTED_GPU_TYPE" = "amd" ] || [ "$SELECTED_GPU_TYPE" = "vaapi" ]; then
        # Frigate 0.17+ defaults to 320x320 tensor input; SSD MobileNet requires explicit 300x300
        yolo_model_config="model:
  width: 300
  height: 300
  path: /openvino-model/ssdlite_mobilenet_v2.xml"
    fi

    if [ "$DRY_RUN" = false ]; then
        pct exec "$CT_ID" -- bash -c "cat > /opt/frigate/config/config.yml" << EOF
mqtt:
  enabled: false

$go2rtc_config

$hwaccel_config

$detector_config

$yolo_model_config

cameras:
$camera_template
EOF
        log_success "Initial config.yml created"
    else
        log_dry_run "Create config.yml"
    fi
}

start_frigate() {
    log_step "Starting Frigate container..."
    
    execute_in_container "cd /opt/frigate && docker compose up -d"
    
    if [ "$DRY_RUN" = false ]; then
        log "Waiting for Frigate to start..."
        sleep 10
    fi
    
    log_success "Frigate started"
}

# ============================================================================
# OPTIONAL FEATURES
# ============================================================================

setup_ssh() {
    if [ "$ENABLE_SSH" != "yes" ]; then
        log "Skipping SSH setup (disabled)"
        return
    fi
    
    log_step "Setting up SSH access..."
    
    execute_in_container "DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server"
    
    # Create user (unless it's root)
    if [ "$SSH_USER" != "root" ]; then
        execute_in_container "useradd -m -s /bin/bash $SSH_USER"
        execute_in_container "echo '$SSH_USER:$SSH_PASSWORD' | chpasswd"
        execute_in_container "usermod -aG sudo $SSH_USER"
        
        # Configure passwordless sudo
        execute_in_container "mkdir -p /etc/sudoers.d"
        execute_in_container "echo '$SSH_USER ALL=(ALL) NOPASSWD:ALL' | tee /etc/sudoers.d/$SSH_USER"
        execute_in_container "chmod 0440 /etc/sudoers.d/$SSH_USER"
    else
        # Just set root password
        execute_in_container "echo 'root:$SSH_PASSWORD' | chpasswd"
        # Enable root login in sshd_config
        execute_in_container "sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
        execute_in_container "sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"  
        log "Using existing root user"
    fi
    
    # Enable and start SSH
    execute_in_container "systemctl enable ssh"
    execute_in_container "systemctl restart ssh"
    
    log_success "SSH configured for user: $SSH_USER"
}

setup_extra_disk() {
    if [ "$ADD_EXTRA_DISK" != true ]; then
        return
    fi
    
    log_step "Adding extra disk for recordings ($EXTRA_DISK_SIZE GB)..."
    
    if [ "$DRY_RUN" = false ]; then
        # Find next mount point ID
        local mp_id=0
        while grep -q "mp$mp_id" "/etc/pve/lxc/${CT_ID}.conf"; do
            mp_id=$((mp_id + 1))
        done
        
        log "Using mount point mp$mp_id on $EXTRA_DISK_STORAGE"
        if pct set "$CT_ID" "--mp${mp_id}" "${EXTRA_DISK_STORAGE}:${EXTRA_DISK_SIZE},mp=/opt/frigate/storage" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Extra disk added and mounted to /opt/frigate/storage"
        else
            log_warn "Failed to add extra disk. Using rootfs instead."
        fi
    else
        log_dry_run "Add $EXTRA_DISK_SIZE GB disk to $CT_ID on $EXTRA_DISK_STORAGE"
    fi
}

create_snapshot() {
    if [ "$DO_SNAPSHOT" != true ]; then
        return
    fi
    
    SNAPSHOT_NAME="Post-Install-$(date +%Y%m%d-%H%M)"
    log_step "Creating post-installation snapshot: $SNAPSHOT_NAME..."
    
    if [ "$DRY_RUN" = false ]; then
        pct snapshot "$CT_ID" "$SNAPSHOT_NAME" --description "Automatically created after Frigate installation" 2>&1 | tee -a "$LOG_FILE" || log_warn "Failed to create snapshot."
        log_success "Snapshot created"
    else
        log_dry_run "Create snapshot $SNAPSHOT_NAME for container $CT_ID"
    fi
}

# ============================================================================
setup_samba() {
    if [ "$ENABLE_SAMBA" != "yes" ]; then
        log "Skipping Samba setup (disabled)"
        return
    fi

    log_step "Setting up Samba file sharing..."

    execute_in_container "DEBIAN_FRONTEND=noninteractive apt-get install -y samba"

    # Create a dedicated non-root samba user
    execute_in_container "id frigate &>/dev/null || useradd -M -s /usr/sbin/nologin frigate"
    execute_in_container "chown -R frigate:frigate /opt/frigate/config /opt/frigate/storage"
    execute_in_container "chmod -R 750 /opt/frigate/config /opt/frigate/storage"

    if [ "$DRY_RUN" = false ]; then
        pct exec "$CT_ID" -- bash -c "printf '%s\n%s\n' '$SAMBA_PASSWORD' '$SAMBA_PASSWORD' | smbpasswd -a -s frigate"

        pct exec "$CT_ID" -- bash -c "cat > /etc/samba/smb.conf" << 'EOF'
[global]
netbios name = FRIGATE
server string = Frigate NVR
workgroup = WORKGROUP
security = user
map to guest = Never
server min protocol = SMB2

[Config]
path = /opt/frigate/config
comment = Frigate configuration files
browsable = yes
read only = no
valid users = frigate
force user = frigate
create mask = 0640
directory mask = 0750

[Storage]
path = /opt/frigate/storage
comment = Frigate recordings and snapshots
browsable = yes
read only = no
valid users = frigate
force user = frigate
create mask = 0640
directory mask = 0750
EOF
    fi

    execute_in_container "systemctl restart smbd && systemctl enable smbd"
    log_success "Samba configured (user: frigate, shares: Config + Storage)"
}

setup_firewall() {
    if [ "$ENABLE_FIREWALL" != "yes" ]; then
        log "Skipping firewall setup (disabled)"
        return
    fi

    log_step "Configuring Proxmox firewall for container $CT_ID..."

    local fw_dir="/etc/pve/firewall"
    local fw_file="$fw_dir/${CT_ID}.fw"

    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$fw_dir"
        cat > "$fw_file" << EOF
[OPTIONS]
enable: 1

[RULES]
IN ACCEPT -p tcp --dport $FRIGATE_PORT -log nolog # Frigate web UI
EOF
        log_success "Firewall enabled: port $FRIGATE_PORT (TCP) open"
    else
        log_dry_run "Create $fw_file and enable firewall on container"
    fi
}

create_container_summary_dashboard() {
    log_step "Creating Proxmox summary dashboard..."
    
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Set container description to professional dashboard"
        return
    fi

    local ip_address
    ip_address=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}' || echo "<IP_ADDRESS>")
    
    local coral_line=""
    if [ -n "$DETECTED_CORAL" ] && [ "$DETECTED_CORAL" != "none" ]; then
        coral_line="- Coral Detector: ${DETECTED_CORAL}\n"
    fi

    # Construct Markdown Description
    local description=$(echo -e "# Frigate Proxmox Script

**Quick Access**
| Service | URL |
| :--- | :--- |
| Web UI | http://${ip_address}:${FRIGATE_PORT:-5000} |
| go2rtc API | http://${ip_address}:${GO2RTC_PORT:-1984} |
| Frigate Auth | https://${ip_address}:${AUTH_PORT:-8971} |

**Hardware Profile**
- GPU Acceleration: ${SELECTED_GPU_TYPE:-None}
${coral_line}- SHM Size: ${SHM_SIZE:-512mb}
- Resources: ${CT_RAM}MB RAM / ${CT_CORES} CPU Cores

**File Locations**
- Configuration: /opt/frigate/config/config.yml
- Media Storage: /opt/frigate/storage

---
GitHub: [saihgupr/frigate-proxmox-script](https://github.com/saihgupr/frigate-proxmox-script)

Support: [Buy me a coffee](https://ko-fi.com/saihgupr)")

    if pct set "$CT_ID" --description "$description" 2>/dev/null; then
        log_success "Proxmox summary dashboard created for container $CT_ID"
    else
        log_warn "Failed to create Proxmox summary dashboard"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    echo -e "${BLUE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  FRIGATE NVR DOCKER INSTALLER FOR PROXMOX"
    echo "  Version: $VERSION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"

    check_root
    check_proxmox
    check_hardware
    
    configure_container
    show_configuration_summary
    
    download_debian_template
    create_lxc_container
    configure_lxc_passthrough
    setup_extra_disk
    
    start_lxc_container
    
    install_docker
    install_nvidia_toolkit
    
    create_frigate_directories
    create_docker_compose
    export_yolo_model
    create_frigate_config
    
    start_frigate
    
    setup_ssh
    setup_samba
    setup_firewall
    create_container_summary_dashboard
    
    create_snapshot

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  INSTALLATION COMPLETE!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local ip_addr
    ip_addr=$(pct exec "$CT_ID" -- ip addr show eth0 | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -n 1)
    
    echo "  Frigate Web UI:  http://${ip_addr:-$CT_IP}:$FRIGATE_PORT"
    echo "  go2rtc API:      http://${ip_addr:-$CT_IP}:$GO2RTC_PORT"
    echo "  Container ID:    $CT_ID"
    echo ""
    
    if [ "$REBOOT_REQUIRED" = true ]; then
        echo -e "${YELLOW}[IMPORTANT]${NC} A reboot of the Proxmox HOST is recommended to"
        echo "ensure all GPU passthrough settings and drivers are fully active."
    fi
    
    echo ""
    echo "Log file: $LOG_FILE"
    echo ""
}

# Run main function with all arguments
main "$@"
