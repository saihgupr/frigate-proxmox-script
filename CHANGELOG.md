# Changelog

## [1.0.8] - 2026-03-18

### Fixed
- Detect USB Coral devices that report as "Global Unichip Corp" in `lsusb`.

## [1.0.7] - 2026-03-08

### Added
- Make `shm_size` a configurable option during installation.
- Fix: Implement persistent `/dev/shm` configuration for Proxmox LXC host to prevent "No space left on device" errors.
- Bumped default `shm_size` to `512mb`.
