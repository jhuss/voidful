# Exit Codes

Standardized exit codes produced by the installer:

| Code | Meaning |
|------|---------|
| `0` | Success — installation completed |
| `1` | General error — config validation failure, missing config file, or failure of any pipeline stage (partitioning, LUKS, clone, cleanup, chroot configuration, bootloader, mounting) |
| `2` | Disk error — target disk not found, not a block device, or the CD-ROM drive (`sr0`) |
| `3` | Permission error — not running as root |
| `8` | User interruption — installer was cancelled (SIGINT/SIGTERM/SIGHUP) or a pipeline stage was interrupted by a broken pipe |
| `9` | Unknown `END_ACTION` value (see `docs/end_actions.md`) |

> **Why module failures all exit `1`:** every function in `lib/*.sh` signals failure
> with `return 1`, the stages in `install.sh` invoke them plainly under
> `set -euo pipefail`, and the `EXIT` trap (`trap_cleanup`) preserves that code
> while running cleanup. The code above is therefore the code of the failing
> module, uniformly `1`. A non-zero exit of a `script` or `func` end-action
> propagates the child's own exit code (not `9`).

## Responsibility Mapping

| Code | Module | Function / location |
|------|--------|----------|
| `1` | `lib/config.sh` | `validate_config()` (also `run_dry_run()`) |
| `1` | `lib/*.sh` (all) | Any stage failure: `wipe_and_partition()`, `format_luks_partitions()`, `open_luks_partitions()`, `mount_filesystems()`, `clone_system()`, `cleanup_packages()`, `configure_chroot()` (incl. `_install_grub()`), `stage_teardown()` |
| `2` | `lib/hardware.sh` | `validate_disk()` (checked in `stage_preflight()`) |
| `3` | `install.sh` | root check in `stage_preflight()` |
| `8` | `install.sh` | signal trap: `trap 'trap_cleanup; exit 8' INT TERM HUP PIPE` |
| `9` | `install.sh` | `stage_end_action()` — unknown `END_ACTION` value |

The EXIT trap (`trap trap_cleanup EXIT`) preserves the exit code set by the
failing command, so the cleanup routine (unmount + LUKS close + sync, see
`docs/signal_handling.md`) never masks the real error code.
