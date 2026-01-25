#!/usr/bin/env bash

# Frigate NVR Docker Installation Script for Proxmox VE
# Optimized for Beelink S12 with Intel iGPU Hardware Acceleration
# Author: Created for Proxmox VE 7.0+
# License: MIT

set -euo pipefail

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

VERSION="1.0.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/frigate-install-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=false
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Container Configuration
CT_ID=""
CT_HOSTNAME="frigate"
CT_PRIVILEGED=1  # Must be privileged for iGPU passthrough
CT_CORES=4
CT_RAM=2048
CT_DISK=10
CT_STORAGE="local-lvm"
CT_BRIDGE="vmbr0"
CT_NETWORK_TYPE="dhcp"
CT_IP=""
CT_GATEWAY=""
CT_DNS="8.8.8.8"
DEBIAN_TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"

# Frigate Configuration
FRIGATE_VERSION="stable"  # Docker tag: stable, beta, or specific version
ENABLE_IGPU="yes"
FRIGATE_PORT="5000"
ENABLE_SSH="no"
SSH_USER="frigate"
SSH_PASSWORD=""
ENABLE_SAMBA="no"
IS_REOLINK="no"
ROOT_PASSWORD=""

# Hardware Detection Result Strings
DETECTED_CPU=""
DETECTED_GPU="none"
DETECTED_CORAL="none"
GPU_PRESET="preset-vaapi" # Default to VAAPI (Intel/AMD)

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
    
    local pve_version
    pve_version=$(pveversion | grep "pve-manager" | cut -d'/' -f2 | cut -d'-' -f1)
    log_success "Running on Proxmox VE $pve_version"
}

check_root() {
    log_step "Checking privileges..."
    
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root!"
    fi
    
    log_success "Running as root"
}

check_resources() {
    log_step "Checking available resources..."
    
    local available_space
    available_space=$(df /var/lib/vz 2>/dev/null | tail -1 | awk '{print $4}')
    available_space=$((available_space / 1024 / 1024))
    
    if [ "$available_space" -lt 30 ]; then
        log_warn "Only ${available_space}GB available. Recommended: 30GB+"
    else
        log_success "Available disk space: ${available_space}GB"
    fi
}

check_hardware() {
    log_step "Detecting hardware..."
    
    # CPU Detection
    if command -v lscpu &>/dev/null; then
        DETECTED_CPU=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
    else
        DETECTED_CPU=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)
    fi
    log "CPU: $DETECTED_CPU"

    # GPU Detection
    if [ -e "/dev/dri/renderD128" ]; then
        if lspci 2>/dev/null | grep -qi "intel"; then
            DETECTED_GPU="Intel iGPU"
            GPU_PRESET="preset-vaapi"
        elif lspci 2>/dev/null | grep -qi "amd"; then
            DETECTED_GPU="AMD GPU"
            GPU_PRESET="preset-vaapi"
        else
            DETECTED_GPU="Generic VAAPI (Intel/AMD)"
            GPU_PRESET="preset-vaapi"
        fi
    elif command -v nvidia-smi &>/dev/null; then
        DETECTED_GPU="NVIDIA GPU"
        GPU_PRESET="preset-nvidia"
    fi
    
    if [ "$DETECTED_GPU" != "none" ]; then
        log_success "Detected GPU: $DETECTED_GPU"
    else
        log_warn "No integrated or dedicated GPU detected for hardware acceleration."
        GPU_PRESET="none"
    fi

    # Coral Detection
    if lsusb 2>/dev/null | grep -qi "Google Inc. Digital Enlightenment"; then
        DETECTED_CORAL="USB"
        log_success "Detected Google Coral (USB)"
    elif lspci 2>/dev/null | grep -qi "Global Unichip Corp"; then
        DETECTED_CORAL="PCIe"
        log_success "Detected Google Coral (PCIe)"
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
        read -p "Enter Container ID [100-999] (default: auto): " input_id
        if [ -z "$input_id" ]; then
            CT_ID=$(pvesh get /cluster/nextid)
            log "Auto-selected Container ID: $CT_ID"
            break
        elif [[ "$input_id" =~ ^[0-9]+$ ]] && [ "$input_id" -ge 100 ] && [ "$input_id" -le 999 ]; then
            if pct status "$input_id" &>/dev/null; then
                log_error "Container ID $input_id already exists!"
            else
                CT_ID="$input_id"
                break
            fi
        else
            log_error "Invalid Container ID. Must be between 100-999."
        fi
    done
    
    read -p "Enter hostname (default: frigate): " input_hostname
    CT_HOSTNAME="${input_hostname:-frigate}"
    
    read -p "Enter CPU cores (default: 4): " input_cores
    CT_CORES="${input_cores:-4}"
    
    read -p "Enter RAM in MB (default: 2048): " input_ram
    CT_RAM="${input_ram:-2048}"
    
    read -p "Enter disk size in GB (default: 10): " input_disk
    CT_DISK="${input_disk:-10}"
    
    echo ""
    echo "Network Configuration:"
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
    
    echo ""
    if [ "$DETECTED_GPU" != "none" ]; then
        read -p "Enable hardware acceleration using $DETECTED_GPU? (Y/n): " enable_hwaccel
        if [[ "$enable_hwaccel" =~ ^[Nn]$ ]]; then
            ENABLE_IGPU="no"
        else
            ENABLE_IGPU="yes"
        fi
    else
        log_warn "Hardware acceleration will be disabled (no compatible GPU detected)."
        ENABLE_IGPU="no"
    fi
    
    echo ""
    read -p "Enter Frigate web port (default: 5000): " input_port
    FRIGATE_PORT="${input_port:-5000}"
    
    echo ""
    echo "Frigate Docker Image:"
    echo "  1) stable (recommended)"
    echo "  2) beta"
    echo "  3) Custom tag"
    read -p "Select version (1-3): " version_choice
    
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
        3) read -p "Enter custom tag (e.g., 0.14.1): " custom_tag
           FRIGATE_VERSION="$custom_tag" ;;
        *) FRIGATE_VERSION="stable" ;;
    esac
    
    echo ""
    read -p "Do you have Reolink cameras? (y/N): " is_reolink
    if [[ "$is_reolink" =~ ^[Yy]$ ]]; then
        IS_REOLINK="yes"
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
        read -p "Enter SSH username (default: frigate): " input_user
        SSH_USER="${input_user:-frigate}"
        
        # Reuse root password for SSH user
        SSH_PASSWORD="$ROOT_PASSWORD"
        log "SSH password will match the root password."
    else
        ENABLE_SSH="no"
    fi
    
    echo ""
    read -p "Enable Samba file sharing? (Y/n): " enable_samba
    enable_samba=${enable_samba:-Y}
    if [[ "$enable_samba" =~ ^[Yy]$ ]]; then
        ENABLE_SAMBA="yes"
        
        # If SSH is disabled, we need to ask for a Samba password specifically
        if [ "$ENABLE_SSH" != "yes" ]; then
            echo ""
            log_warn "Samba enabled but SSH disabled. You need to set a Samba password."
            while true; do
                read -sp "Enter Samba password: " SSH_PASSWORD
                echo ""
                
                if [ -z "$SSH_PASSWORD" ]; then
                    log_error "Password cannot be empty!"
                    continue
                fi
                
                read -sp "Confirm Samba password: " SAMBA_PASSWORD_CONFIRM
                echo ""
                
                if [ "$SSH_PASSWORD" = "$SAMBA_PASSWORD_CONFIRM" ]; then
                    break
                else
                    log_error "Passwords do not match! Please try again."
                    echo ""
                fi
            done
        fi
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
    echo "  Type:            Privileged LXC"
    echo "  CPU Cores:       $CT_CORES"
    echo "  RAM:             ${CT_RAM}MB"
    echo "  Disk:            ${CT_DISK}GB"
    echo "  Storage:         $CT_STORAGE"
    echo "  Network Bridge:  $CT_BRIDGE"
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
    echo "  Reolink Support: $IS_REOLINK"
    echo "  Web Port:        $FRIGATE_PORT"
    if [ "$ENABLE_SSH" = "yes" ]; then
        echo "  SSH User:        $SSH_USER"
    fi
    if [ "$ENABLE_SAMBA" = "yes" ]; then
        echo "  Samba:           Enabled (3 shares)"
    fi
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
    
    if pveam list local 2>/dev/null | grep -q "$DEBIAN_TEMPLATE"; then
        log_success "Debian template already available"
        return
    fi
    
    log "Downloading Debian 12 template..."
    
    if [ "$DRY_RUN" = false ]; then
        pveam download local "$DEBIAN_TEMPLATE" 2>&1 | tee -a "$LOG_FILE" || error_exit "Failed to download template"
        log_success "Debian template downloaded"
    else
        log_dry_run "pveam download local $DEBIAN_TEMPLATE"
    fi
}

create_lxc_container() {
    log_step "Creating LXC container $CT_ID..."
    
    local net_config
    if [ "$CT_NETWORK_TYPE" = "static" ]; then
        net_config="name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP,gw=$CT_GATEWAY"
    else
        net_config="name=eth0,bridge=$CT_BRIDGE,ip=dhcp"
    fi
    
    local pct_cmd="pct create $CT_ID local:vztmpl/$DEBIAN_TEMPLATE \
        --hostname $CT_HOSTNAME \
        --cores $CT_CORES \
        --memory $CT_RAM \
        --swap 512 \
        --rootfs $CT_STORAGE:$CT_DISK \
        --net0 $net_config \
        --unprivileged 0 \
        --features nesting=1 \
        --onboot 1 \
        --start 0"
    
    if [ "$DRY_RUN" = false ]; then
        eval "$pct_cmd" 2>&1 | tee -a "$LOG_FILE" || error_exit "Failed to create container"
        log_success "Container $CT_ID created"
    else
        log_dry_run "$pct_cmd"
    fi
}

configure_igpu_passthrough() {
    if [ "$ENABLE_IGPU" != "yes" ]; then
        log "Skipping iGPU passthrough (disabled)"
        return
    fi
    
    log_step "Configuring Intel iGPU passthrough..."
    
    local lxc_conf="/etc/pve/lxc/${CT_ID}.conf"
    
    if [ "$DRY_RUN" = false ]; then
        cat >> "$lxc_conf" << EOF

# Intel iGPU Passthrough
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
EOF
        log_success "iGPU passthrough configured in $lxc_conf"
    else
        log_dry_run "Add iGPU passthrough configuration to $lxc_conf"
    fi
}

start_container() {
    log_step "Starting container $CT_ID..."
    
    if [ "$DRY_RUN" = false ]; then
        pct start "$CT_ID" 2>&1 | tee -a "$LOG_FILE" || error_exit "Failed to start container"
        
        log "Waiting for container to initialize..."
        sleep 5
        
        local max_wait=30
        local count=0
        while [ $count -lt $max_wait ]; do
            if pct exec "$CT_ID" -- ip addr show eth0 | grep -q "inet"; then
                break
            fi
            sleep 1
            ((count++))
        done
        
        log_success "Container $CT_ID is running"
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
    execute_in_container "DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl"
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
    log_step "Creating docker-compose.yml..."
    
    local device_config=""
    if [ "$ENABLE_IGPU" = "yes" ]; then
        if [ "$DETECTED_GPU" = "NVIDIA GPU" ]; then
            device_config="    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu, video]"
        else
            device_config="    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128"
        fi
    fi

    # Add Coral PCIe if detected
    if [ "$DETECTED_CORAL" = "PCIe" ]; then
        if [ -n "$device_config" ]; then
            device_config="$device_config
      - /dev/apex_0:/dev/apex_0"
        else
            device_config="    devices:
      - /dev/apex_0:/dev/apex_0"
        fi
    fi
    
    if [ "$DRY_RUN" = false ]; then
        pct exec "$CT_ID" -- bash -c "cat > /opt/frigate/docker-compose.yml" << EOF
version: "3.9"

services:
  frigate:
    container_name: frigate
    restart: unless-stopped
    stop_grace_period: 30s
    image: ghcr.io/blakeblackshear/frigate:$FRIGATE_VERSION
    volumes:
      - ./config:/config
      - ./storage:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    ports:
      - "$FRIGATE_PORT:$FRIGATE_PORT"
      - "8554:8554"  # RTSP feeds
      - "8555:8555/tcp"  # WebRTC
      - "8555:8555/udp"  # WebRTC
$device_config
    environment:
      - FRIGATE_RTSP_PASSWORD=password
    shm_size: "256mb"
EOF
        log_success "docker-compose.yml created"
    else
        log_dry_run "Create docker-compose.yml"
    fi
}

create_frigate_config() {
    log_step "Creating initial Frigate configuration..."
    
    local hwaccel_config=""
    if [ "$ENABLE_IGPU" = "yes" ] && [ "$GPU_PRESET" != "none" ]; then
        hwaccel_config="  hwaccel_args: $GPU_PRESET"
    fi

    local go2rtc_config=""
    if [ "$IS_REOLINK" = "yes" ]; then
        go2rtc_config="go2rtc:
  streams:
    reolink_camera: # Example Reolink stream
      - ffmpeg:http://camera-ip/flv?user=admin&password=yourpassword&channel=0&stream=0"
    fi

    local camera_template=""
    if [ "$IS_REOLINK" = "yes" ]; then
        camera_template="  reolink_camera:
    enabled: false
    ffmpeg:
      inputs:
        - path: rtsp://admin:password@camera-ip:554/h264Preview_01_main
          roles:
            - detect
            - record"
    else
        camera_template="  dummy_camera:
    enabled: false
    ffmpeg:
      inputs:
        - path: rtsp://user:password@camera-ip:554/stream
          roles:
            - detect"
    fi

    local detector_config="detectors:
  ov:
    type: openvino
    device: CPU"
    
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
    elif [[ "$DETECTED_GPU" == *"Intel"* ]]; then
        detector_config="detectors:
  ov:
    type: openvino
    device: GPU"
    fi

    if [ "$DRY_RUN" = false ]; then
        pct exec "$CT_ID" -- bash -c "cat > /opt/frigate/config/config.yml" << EOF
mqtt:
  enabled: false

$go2rtc_config

ffmpeg:
$hwaccel_config

$detector_config

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
        log "Using existing root user"
    fi
    
    # Enable and start SSH
    execute_in_container "systemctl enable ssh"
    execute_in_container "systemctl start ssh"
    
    log_success "SSH configured for user: $SSH_USER"
}

setup_samba() {
    if [ "$ENABLE_SAMBA" != "yes" ]; then
        log "Skipping Samba setup (disabled)"
        return
    fi
    
    log_step "Setting up Samba file sharing..."
    
    execute_in_container "DEBIAN_FRONTEND=noninteractive apt-get install -y samba"
    
    # Backup original config
    execute_in_container "cp /etc/samba/smb.conf /etc/samba/smb.conf.bak"
    
    # Create Samba configuration
    if [ "$DRY_RUN" = false ]; then
        pct exec "$CT_ID" -- bash -c "cat > /etc/samba/smb.conf" << 'EOF'
[global]
netbios name = FRIGATE
server string = Frigate NVR File Share
workgroup = WORKGROUP
security = user
map to guest = Bad User
guest account = nobody

[Frigate]
path = /opt/frigate
comment = Frigate installation directory
browsable = yes
read only = no
writable = yes
guest ok = yes
public = yes
create mask = 0777
directory mask = 0777
force user = root
force create mode = 0777
force directory mode = 0777

[Config]
path = /opt/frigate/config
comment = Frigate configuration
browsable = yes
read only = no
writable = yes
guest ok = yes
public = yes
create mask = 0777
directory mask = 0777
force user = root
force create mode = 0777
force directory mode = 0777

[Media]
path = /opt/frigate/storage
comment = Frigate recordings and media
browsable = yes
read only = no
writable = yes
guest ok = yes
public = yes
create mask = 0777
directory mask = 0777
force user = root
force create mode = 0777
force directory mode = 0777
EOF
    else
        log_dry_run "Create /etc/samba/smb.conf"
    fi
    
    # Set root Samba password
    local samba_pass=""
    
    if [ -n "$SSH_PASSWORD" ]; then
        samba_pass="$SSH_PASSWORD"
    elif [ -n "$ROOT_PASSWORD" ]; then
        samba_pass="$ROOT_PASSWORD"
    fi
    
    if [ -z "$samba_pass" ]; then
        log_error "No password available for Samba setup!"
        return 1
    fi

    if [ "$DRY_RUN" = false ]; then
        echo -e "$samba_pass\n$samba_pass" | pct exec "$CT_ID" -- smbpasswd -a -s root
    else
        log_dry_run "Set Samba password for root"
    fi
    
    # Restart Samba
    execute_in_container "systemctl restart smbd"
    execute_in_container "systemctl enable smbd"
    
    log_success "Samba configured with shares: Frigate, Config, Media"
}

setup_root_password() {
    log_step "Setting up root password..."
    
    if [ -n "$ROOT_PASSWORD" ]; then
        execute_in_container "echo 'root:$ROOT_PASSWORD' | chpasswd"
        log_success "Root password set"
    else
        log_warn "No root password set (this should not happen)"
    fi
}

# ============================================================================
# USAGE & MAIN
# ============================================================================

show_usage() {
    cat << EOF
Frigate NVR Docker Installation Script for Proxmox VE v${VERSION}

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --dry-run     Run in simulation mode (no actual changes)
    --verbose     Enable verbose output
    --help        Show this help message

DESCRIPTION:
    Automated Docker-based installation script for Frigate NVR on Proxmox VE.
    Creates an LXC container and installs Frigate using Docker Compose
    with Intel iGPU hardware acceleration support.

REQUIREMENTS:
    - Proxmox VE 7.0 or later
    - Root privileges
    - Internet connection

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

main() {
    clear
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  FRIGATE NVR DOCKER INSTALLATION FOR PROXMOX VE"
    echo "  Version: $VERSION"
    echo "  Using Docker Compose (Fast & Reliable)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    log "Starting Frigate Docker installation at $(date)"
    log "Log file: $LOG_FILE"
    echo ""
    
    # Pre-flight checks
    check_proxmox
    check_root
    check_resources
    check_hardware
    
    # Configuration
    configure_container
    show_configuration_summary
    
    # Installation
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "PHASE 1: Creating LXC Container"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    download_debian_template
    create_lxc_container
    configure_igpu_passthrough
    start_container
    
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "PHASE 2: Installing Docker"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    install_docker
    
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "PHASE 3: Preparing Frigate"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    create_frigate_directories
    create_docker_compose
    create_frigate_config
    
    # Set root password (always)
    setup_root_password
    
    # Optional features
    if [ "$ENABLE_SSH" = "yes" ] || [ "$ENABLE_SAMBA" = "yes" ]; then
        echo ""
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "PHASE 4: Setting Up Optional Features"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        setup_ssh
        setup_samba
    fi
    
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "PHASE 5: Starting Frigate NVR"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    start_frigate
    
    # Completion
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✓ INSTALLATION COMPLETE!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [ "$DRY_RUN" = false ]; then
        local container_ip
        container_ip=$(pct exec "$CT_ID" -- ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d/ -f1)
        
        log_success "Frigate NVR has been successfully installed!"
        echo ""
        echo "Container Details:"
        echo "  Container ID:  $CT_ID"
        echo "  Hostname:      $CT_HOSTNAME"
        echo "  IP Address:    $container_ip"
        echo ""
        echo "Frigate Access:"
        echo "  Web Interface: http://${container_ip}:${FRIGATE_PORT}"
        echo ""
        echo "Configuration:"
        echo "  Directory:     /opt/frigate"
        echo "  Config File:   /opt/frigate/config/config.yml"
        echo "  Storage:       /opt/frigate/storage"
        echo ""
        echo "Docker Commands (run inside container):"
        echo "  View logs:     cd /opt/frigate && docker compose logs -f"
        echo "  Restart:       cd /opt/frigate && docker compose restart"
        echo "  Stop:          cd /opt/frigate && docker compose down"
        echo "  Update image:  cd /opt/frigate && docker compose pull && docker compose up -d"
        echo ""
        echo "Next Steps:"
        echo "  1. Access Frigate at http://${container_ip}:${FRIGATE_PORT}"
        echo "  2. Note the initial password from logs:"
        echo "     pct exec $CT_ID -- docker logs frigate"
        echo "  3. Add your cameras to /opt/frigate/config/config.yml"
        echo "  4. Restart: pct exec $CT_ID -- 'cd /opt/frigate && docker compose restart'"
        echo ""
        log "Installation log saved to: $LOG_FILE"
    else
        log_success "Dry-run complete! No changes were made."
        echo ""
        echo "To perform the actual installation, run:"
        echo "  $0"
    fi
    
    echo ""
    log "Installation completed at $(date)"
}

# Entry point
parse_arguments "$@"

# Check for interactive terminal
if [ ! -t 0 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ERROR: This script requires an interactive terminal"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Please download and run the script manually:"
    echo ""
    echo "  wget https://raw.githubusercontent.com/saihgupr/frigate-script/main/install.sh"
    echo "  bash install.sh"
    echo ""
    echo "Or run with curl (interactive mode):"
    echo ""
    echo "  bash <(curl -s https://raw.githubusercontent.com/saihgupr/frigate-script/main/install.sh)"
    echo ""
    exit 1
fi

main

exit 0
