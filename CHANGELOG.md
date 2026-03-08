# Changelog

## [1.0.7] - 2026-03-08

### Added
- Make `shm_size` a configurable option during installation.
- Fix: Implement persistent `/dev/shm` configuration for Proxmox LXC host to prevent "No space left on device" errors.
- Bumped default `shm_size` to `512mb`.
