## [1.1.5] - 2026-04-19

### Fixed
- **Network Storage Resilience (#28)**: Prevented script hangs on offline CIFS/NFS shares by implementing a 5-second timeout and proactive activity checking. Inactive storage pools are now automatically filtered out during discovery.

## [1.1.4] - 2026-04-19

### Fixed
- **NVIDIA Library Mapping (#30)**: Resolved `libnvidia-ml.so.1` missing errors by implementing dynamic host library discovery and bind-mounting. The script now automatically identifies and maps essential NVIDIA libraries into the LXC container.
- **Host Driver Validation**: Added proactive checks to verify NVIDIA driver installation on the Proxmox host before allowing passthrough configuration.

## [1.1.3] - 2026-04-19

### Fixed
- **Storage Resilience (#26)**: Replaced hardcoded `local-lvm` references with dynamic storage discovery. The script now queries available pools and provides a robust interactive selection with intelligent fallbacks (LVM -> ZFS -> Local).
- **Template Storage Selection**: Added interactive selection for the template storage pool, allowing users with custom storage setups to specify where Debian images are stored.

## [1.1.2] - 2026-04-19

### Added
- **Intel Alder Lake-N Support**: Performance optimizations and tailored hardware detection for N95, N100, and N150 processors.
- **SR-IOV (Virtual GPU) Support**: Automatic detection of multiple render nodes (Virtual Functions) with an interactive selection prompt.
- **Template Storage Flexibility**: Moved template storage to a configurable `$TEMPLATE_STORAGE` variable (defaulting to `local`) to support custom Proxmox storage configurations.
- Enhanced hardware identification using `lspci -nn` for more reliable chip detection.

## [1.1.1-debug.2] - 2026-03-24

### Fixed
- Resolved malformed `docker-compose.yml` generation when using NVIDIA and Coral PCIe simultaneously.
- Made Proxmox snapshots non-fatal in both `install.sh` and `update.sh` to prevent script exit on storage-related failures.
- Prevented empty `ffmpeg:` block in `config.yml` when no hardware acceleration is selected.
- Added host-side driver validation for Coral PCIe devices with descriptive warnings and installation instructions.

## [1.1.0] - 2026-03-23

### Added
- Implemented first-class support for version 1.1.0 changes.
- Consolidated latest performance improvements and bug fixes.

## [1.0.9] - 2026-03-22

### Added
- Proactive disk space checks in `update.sh` before pulling new images.
- New `--prune` (`-p`) flag in `update.sh` to clear unused Docker data.
- Automated pruning prompt in `update.sh` when space is low (< 5GB).
- Dynamic resource checks in `install.sh` targeting the user-selected storage pool.
- Synchronize LXC container timezone with the Proxmox host and pass through host timezone to the Frigate Docker container (#22).

### Fixed
- Robust Google Coral USB detection: Added support for "Google Inc" name and `18d1:9302` USB ID.
- Replaced hardcoded `/var/lib/vz` space check with pool-aware validation.

## [1.0.8] - 2026-03-18

### Added
- Clickable link in terminal output to access the Frigate Web UI.

### Fixed
- Detect USB Coral devices that report as "Global Unichip Corp" in `lsusb`.

## [1.0.7] - 2026-03-08

### Added
- Make `shm_size` a configurable option during installation.
- Fix: Implement persistent `/dev/shm` configuration for Proxmox LXC host to prevent "No space left on device" errors.
- Bumped default `shm_size` to `512mb`.
