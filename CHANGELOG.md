## [Unreleased]

### Added
- Added support for installing and updating to Frigate's latest built development branch images directly from GHCR.
- Added documentation and troubleshooting workarounds for Intel QSV "Can't allocate a surface" hardware acceleration errors on newer Intel CPUs.

### Changed
- Converted VLAN, MTU, and Proxmox firewall configuration from interactive onboarding prompts to command-line flag options (`--vlan`, `--mtu`, and `--firewall`), streamlining the default setup flow.
- Set the Proxmox container firewall to default off, using the `--firewall` flag to enable it.

### Fixed
- Switched to curl for installer network calls to improve reliability.
- Expose go2rtc API (1984) and Frigate Auth (8971) ports by default in the generated `compose.yml` and Proxmox firewall rules.
- Standardized documentation and command references to use `compose.yml` instead of the legacy `docker-compose.yml`.
- Improved automatic GPU render node selection by resolving to the first detected render node on the host when only a single node is present.

## [1.3.0] - 2026-05-09

### Added
- **Unprivileged LXC Support (#37)**: Added interactive support for creating unprivileged LXC containers. This improves security while providing a user-selectable prompt to fall back to privileged mode if required by specific hardware or kernel configurations.
- **Samba File Sharing**: Integrated out-of-the-box support for Samba, providing easy network access to Frigate's `/config` and `/storage` directories with per-user authentication.
- **Professional Proxmox Dashboard**: Re-implemented a high-fidelity Markdown summary for the Proxmox container notes, providing one-click access to the Web UI, go2rtc API, and hardware status directly from the Proxmox GUI.
- **Modern Hardware Passthrough (PVE 8.2+)**: Implemented the modern `dev[n]` device mapping logic for Proxmox 8.2 and newer. This provides more robust hardware passthrough for NVIDIA GPUs, Intel iGPUs, and Coral TPUs while maintaining legacy fallback support for older PVE versions.
- **Refined Configuration Notes**: Restored descriptive comments, AppArmor `unconfined` profiles, and custom Proxmox container description notes to ensure maximum visibility and compatibility.
- **Improved Passthrough Security**: Unprivileged containers now include necessary idmap configurations and device permission adjustments to ensure hardware access remains functional without compromising security.
- **GitHub Cache Bypassing**: Added documentation and script logic to bypass GitHub's `raw` content cache using timestamped queries, ensuring users always pull the latest installation script.

### Fixed
- **NVIDIA Passthrough Logic**: Resolved a syntax error in the NVIDIA configuration function that could prevent script execution when using complex passthrough scenarios.
- **Silent Script Failures**: Fixed an issue where the script would terminate unexpectedly after container startup due to bash arithmetic expressions (`((counter++))`) returning non-zero exit codes under `set -e`.
- **Contribution Recognition**: Integrated community-driven improvements for security and hardware compatibility (Special thanks to @HarmEllis).

## [1.2.3] - 2026-05-08

### Fixed
- **SHM Size Input Bug (#35)**: Fixed a critical bug where entering a raw number for SHM size (e.g., `1024`) would be interpreted by Docker as bytes instead of megabytes, leading to "No space left on device" errors and container crashes. The script now automatically appends `mb` to numeric inputs and validates the format.
- **RAM Validation**: Added a safety check to ensure the LXC container RAM is sufficient for the requested SHM size, offering to automatically increase RAM if needed.

## [1.2.2] - 2026-05-01

### Fixed
- **NVIDIA Passthrough Resilience**: Further improved major number detection for NVIDIA devices on the host.
- **Debian 12 Template Fallback**: Improved reliability of template downloading and storage detection.

## [1.2.1] - 2026-04-29

### Fixed
- **Storage Pool Detection (#26, #34)**: Resolved "stops without a notice" issues by moving disk space checks after storage selection and making them more robust.
- **NVIDIA Library Resilience (#30)**: Significantly improved NVIDIA library mapping by scanning all potential host paths and ensuring the library cache is updated inside the container.
- **Hardware Detection Fix**: Fixed a bug where the script would exit early if no Google Coral was detected or if certain hardware info was missing.
- **Dynamic Defaults**: Improved storage pool fallback heuristics to better detect ZFS and other non-LVM storage setups.
- **Improved Robustness**: Enhanced `is_storage_active` and `check_resources` to handle empty or inactive storage pools gracefully without crashing under `set -e`.

## [1.2.0] - 2026-04-20

### Added
- **Custom Network Bridge (#31)**: Added support for specifying the network bridge (e.g., `vmbr1`) during installation via a hidden `--bridge <name>` command-line flag. This allows advanced users to configure their specific network bridge without changing the interactive setup for standard users.
- **VLAN Awareness (#29)**: Added support for specifying a VLAN tag during installation via a hidden `--vlan <tag>` command-line flag.

## [1.1.9] - 2026-04-19

### Added
- **VLAN Awareness (#29)**: Added support for specifying a VLAN tag during installation via a hidden `--vlan <tag>` command-line flag. This allows advanced users to isolate the container at the network level without cluttering the interactive setup for standard users.

## [1.1.8] - 2026-04-19

### Added
- **Auto-reboot LXC (#29)**: Added a smart prompt at the end of the installation to automatically reboot the container if hardware passthrough (GPU/Coral) was configured, ensuring devices initialize correctly.

## [1.1.7] - 2026-04-19

### Changed
- **Docker Compose v2 Standardization (#25)**: Modernized the installation by renaming `docker-compose.yml` to `compose.yml` and updating all commands and log messages to use the `docker compose` syntax.

## [1.1.6] - 2026-04-19

### Fixed
- **Coral USB 3.0 Detection (#19)**: Enhanced hardware discovery with expanded Vendor/Product ID matching. Added proactive USB bus speed validation to warn users if their Coral is running at throttled (USB 2.0) speeds.

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
