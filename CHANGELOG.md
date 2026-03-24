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
