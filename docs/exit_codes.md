# Exit Codes

Standardized exit codes for the installer:

| Code | Meaning |
|------|---------|
| `0` | Success — installation completed |
| `1` | General error — validation failure, missing config |
| `2` | Disk error — target disk not found, not a block device |
| `3` | Permission error — not running as root |
| `4` | Clone error — tar operation failed |
| `5` | Chroot error — configuration inside chroot failed |
| `6` | Bootloader error — GRUB installation failed (only applies when `BOOTLOADER != "none"`) |
| `7` | LUKS error — cryptsetup operation failed |
| `8` | User interruption — installer was cancelled (SIGINT/SIGTERM) |
| `9` | End-action error — post-install action failed (see `docs/end_actions.md`) |
| `10` | Mount/umount error — failed to mount or unmount filesystems |

## Responsibility Mapping

Each exit code maps to a specific module and function responsible for the error:

| Code | Module | Function |
|------|--------|----------|
| `1` | `install.sh` | `validate_config()` |
| `2` | `lib/hardware.sh`, `lib/partitioning.sh` | `get_disks()`, `validate_disk()` |
| `3` | `install.sh` | `check_root()` |
| `4` | `lib/clone.sh` | `clone_system()` |
| `5` | `lib/chroot_tasks.sh` | Any chroot operation |
| `6` | `lib/chroot_tasks.sh` | `configure_bootloader()` |
| `7` | `lib/partitioning.sh`, `lib/luks.sh` | `format_luks()`, `open_luks()` |
| `8` | `install.sh` | `handle_signal()` |
| `9` | `install.sh` | `end_actions()` |
| `10` | `lib/partitioning.sh`, `lib/clone.sh` | `mount_filesystems()`, `unmount_filesystems()` |

Signal handlers use exit code `8` for user interruptions. The EXIT trap in `docs/signal_handling.md` preserves the exit code set by the failing module, allowing the cleanup routine to report the correct error code.
