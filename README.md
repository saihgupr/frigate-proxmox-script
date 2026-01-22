# Frigate Proxmox Script

An automated, Docker-based installation script for deploying [Frigate NVR](https://frigate.video/) on Proxmox VE using an LXC container. This script provisions the full stack end-to-end—no manual setup required.

### What it does:
1. Creates a privileged **LXC container**
2. Installs **Docker** and **Docker Compose**
3. Deploys **Frigate NVR** with Intel iGPU hardware acceleration

Optimized for the **Beelink S12** (Intel N95/N100), but compatible with any Intel-based Proxmox host.

## Features

✅ **Docker-Based** - Fast, reliable installation using official Frigate Docker images  
✅ **Fully Automated** - One-command installation in ~10 minutes  
✅ **Safe by Design** - Dry-run mode, pre-flight checks, and rollback capabilities  
✅ **Version Selection** - Choose stable, beta, or custom version tags  
✅ **Intel iGPU Support** - Hardware acceleration via VAAPI  
✅ **Easy Updates** - Simple Docker image updates  
✅ **Home Assistant Ready** - Port 5000 default for easy integration  
✅ **Optional SSH & Samba** - Configurable remote access and file sharing  

## Requirements

- **Proxmox VE** 7.0 or later
- **Root access** on Proxmox host
- **Internet connection** for downloading packages
- **Intel iGPU** (recommended for hardware acceleration)

## Quick Start

### Option 1: One-Command Install (Recommended)

```bash
bash <(curl -s https://raw.githubusercontent.com/saihgupr/frigate-script/main/install.sh)
```

### Option 2: Download and Run

```bash
wget https://raw.githubusercontent.com/saihgupr/frigate-script/main/install.sh
bash install.sh
```

**Installation takes ~10 minutes**

## Usage

```bash
./install.sh [OPTIONS]

OPTIONS:
    --dry-run       Run in simulation mode (no actual changes)
    --verbose       Enable verbose output
    --help          Show help message
```

## Configuration Options

The script will prompt you for:

- **Container ID** - Choose between 100-999 (or auto-select)
- **Hostname** - Default: `frigate`
- **CPU Cores** - Default: 4
- **RAM** - Default: 2048 MB (2GB recommended for Docker)
- **Disk Size** - Default: 10 GB (for recordings)
- **Network** - DHCP or static IP
- **Intel iGPU** - Enable hardware acceleration (recommended)
- **Web Port** - Default: 5000 (Home Assistant compatible)
- **Docker Image** - stable, beta, or custom version tag

## Post-Installation

### Adding Your Cameras

#### Method 1: Edit Config File via SSH

```bash
# Access Proxmox host, then edit the config
pct exec <CT_ID> -- nano /opt/frigate/config/config.yml
```

#### Method 2: Copy Config from Your Local Machine

```bash
# From your Mac/PC, copy your config.yml to Proxmox
scp config.yml root@<PROXMOX_IP>:/tmp/

# On Proxmox host, copy to container
pct push <CT_ID> /tmp/config.yml /opt/frigate/config/config.yml

# Restart Frigate to apply changes
pct exec <CT_ID> -- docker compose -f /opt/frigate/docker-compose.yml restart
```

#### Method 3: Use Frigate Web UI (Recommended)

Starting in Frigate 0.14+, you can edit the configuration directly in the web interface:

1. Go to `http://<CONTAINER_IP>:5000/config`
2. Click the **Edit** button
3. Make your changes
4. Click **Save** (Frigate will automatically restart)

### Samba Network File Sharing

If you enabled Samba during installation, you can access and edit Frigate files directly from your computer using network file shares.

**Available Shares:**

1. **`\\<CONTAINER_IP>\Frigate`** - Full Frigate installation directory (`/opt/frigate`)
2. **`\\<CONTAINER_IP>\Config`** - Configuration files only (`/opt/frigate/config`)
3. **`\\<CONTAINER_IP>\Media`** - Recordings and snapshots (`/opt/frigate/storage`)

**How to Connect:**

**Windows:**
1. Open File Explorer
2. Type in the address bar: `\\<CONTAINER_IP>\Config`
3. Press Enter
4. Navigate to `config.yml` and edit with your favorite text editor

**macOS:**
1. Open Finder
2. Press `Cmd + K` (or Go → Connect to Server)
3. Enter: `smb://<CONTAINER_IP>/Config`
4. Click Connect
5. Edit `config.yml` in any text editor

**Linux:**
```bash
# Mount the share
sudo mount -t cifs //<CONTAINER_IP>/Config /mnt/frigate -o guest

# Edit config
nano /mnt/frigate/config.yml
```

**Share Details:**
- **Authentication**: Guest access enabled (no password required by default)
- **Password**: If you configured Samba during installation, you can also authenticate with:
  - Username: `root`
  - Password: The password you set during installation (same as SSH password if SSH was enabled, or the separate Samba password you provided)
- **Permissions**: Full read/write access
- **User**: All files created as `root` user automatically

### File Locations

```
/opt/frigate/
├── docker-compose.yml      # Docker Compose configuration
├── config/
│   └── config.yml         # Frigate configuration
└── storage/               # Recordings and snapshots
```

## Hardware Acceleration

For **Beelink S12** (Intel N95/N100), hardware acceleration is automatically configured:

- **Device**: `/dev/dri/renderD128` (passed through to container)
- **Driver**: VAAPI (Video Acceleration API)
- **ffmpeg preset**: `preset-vaapi`

### Verify Hardware Acceleration

```bash
# Check if device is accessible in container
pct exec <CT_ID> -- ls -l /dev/dri/renderD128

# View Frigate logs for hardware acceleration status
pct exec <CT_ID> -- docker logs frigate 2>&1 | grep -i vaapi
```

### Example Config with Hardware Acceleration

```yaml
ffmpeg:
  hwaccel_args: preset-vaapi

detectors:
  ov:
    type: openvino
    device: GPU  # Uses Intel iGPU for object detection
```

<details>
<summary><h2>Troubleshooting</h2></summary>

### Container won't start
```bash
# Check LXC status
pct status <CT_ID>

# View container logs
pct exec <CT_ID> -- journalctl -xe
```

### Frigate not accessible
```bash
# Check if Docker container is running
pct exec <CT_ID> -- docker ps

# Check Frigate logs
pct exec <CT_ID> -- docker logs frigate

# Verify port in docker-compose.yml
pct exec <CT_ID> -- cat /opt/frigate/docker-compose.yml | grep -A2 ports
```

### Hardware acceleration not working
```bash
# Check if iGPU device exists
pct exec <CT_ID> -- ls -l /dev/dri/

# Test VAAPI
pct exec <CT_ID> -- docker exec frigate vainfo
```

### Configuration errors
```bash
# Validate YAML syntax
pct exec <CT_ID> -- docker exec frigate python3 -c "import yaml; yaml.safe_load(open('/config/config.yml'))"

# Check Frigate logs for config errors
pct exec <CT_ID> -- docker logs frigate 2>&1 | grep -i error
```

</details>

## Updating Frigate

```bash
# Pull the latest image
pct exec <CT_ID> -- docker compose -f /opt/frigate/docker-compose.yml pull

# Restart with new image
pct exec <CT_ID> -- docker compose -f /opt/frigate/docker-compose.yml up -d

# Verify new version
pct exec <CT_ID> -- docker exec frigate cat /VERSION
```

## Uninstallation

```bash
# Stop and destroy the container
pct stop <CT_ID>
pct destroy <CT_ID>
```

## Based On

- **Tutorial**: [Installing Frigate NVR on Proxmox](https://www.mostlychris.com/installing-frigate-nvr-on-proxmox-in-an-lxc-container/)
- **Official Docs**: [Frigate Installation](https://docs.frigate.video/frigate/installation)
- **Docker**: [Official Frigate Docker Image](https://github.com/blakeblackshear/frigate)

## License

MIT License - Feel free to use and modify as needed.

## Contributing

Issues and pull requests are welcome! Star the repo if you find it useful. ⭐
