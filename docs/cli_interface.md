# CLI Interface

The installer accepts command-line arguments to override configuration values and specify installation targets. This document defines the complete CLI specification.

## Usage

```bash
./install.sh [OPTIONS]
```

## Options

| Option | Description | Overrides |
|--------|-------------|-----------|
| `--config FILE` | Path to configuration file | `CONFIG_FILE` (default: `configs/example-uefi.conf`) |
| `--target-disk DISK` | Target disk device (e.g., `/dev/sda`) | `TARGET_DISK` |
| `--target-dir DIR` | Mount point for root partition | `TARGET_DIR` (default: `/mnt`) |
| `--end-action ACTION` | Post-install action | `END_ACTION` (default: `shutdown`) |
| `--bootloader LOADER` | Bootloader to install (`grub` or `none`) | `BOOTLOADER` (default: `grub`) |
| `--dry-run` | Validate config and exit without installing | N/A (no root required; runs before pre-flight) |
| `--test-mode` | Generate full operational plan without performing operations | N/A |
| `--reinstall` | Reinstall over existing installation (unmounts partitions and LUKS mappers first) | N/A |
| `--verbose` | Enable debug-level logging | `LOG_LEVEL` (set to `debug`; default: `info`) |
| `--help` | Show help message | N/A |
| `--version` | Show version | N/A |

> **Note:** `--target-disk` accepts paths with or without `/dev/` prefix (e.g., `/dev/sda` or `sda`). The hardware detection module normalizes the device name internally. See `docs/hardware.md` for details.

## Environment Variables

The following environment variables are read by the installer when the config file does not set them. Because the config file is `source`d **after** the environment is inspected, a value set in the config file **overrides** the environment variable for these:

| Variable | Description |
|---|---|
| `LUKS_PASSPHRASE` | LUKS passphrase (at least one of this or `LUKS_KEYFILE` required if any partition has `--luks "yes"`) |
| `LUKS_KEYFILE` | Path to LUKS keyfile on live ISO (at least one of this or `LUKS_PASSPHRASE` required if any partition has `--luks "yes"`; both can be set for passphrase + keyfile fallback) |
| `ROOT_PASS` | Root password |
| `USER_PASS` | Regular user password |
| `END_ACTION_SCRIPT` | Path to post-install script (for `END_ACTION=script`) |
| `END_ACTION_FUNC` | Function name to call (for `END_ACTION=func`) |

## Configuration File Discovery

The config file is resolved in this order:

1. `--config FILE` (explicit path via CLI)
2. `configs/example-uefi.conf` (default, when `--config` is not given)

If the resolved file does not exist, the installer exits with an error. There is no `$CONFIG_FILE` environment variable and no directory-scan fallback.

> **Note:** In dry-run mode the installer does **not** require root and performs no hardware detection — it only sources the config file and runs `validate_config()`.

## Override Priority

Configuration values are resolved in this order (highest priority first):

1. **CLI arguments** — `--config`, `--target-disk`, etc.
2. **Config file** — values defined in `configs/*.conf`
3. **Defaults** — hardcoded defaults in the installer

> **Note:** Environment variables (`LUKS_PASSPHRASE`, `ROOT_PASS`, `USER_PASS`, `END_ACTION_SCRIPT`, `END_ACTION_FUNC`, `LUKS_KEYFILE`) are read only when the config file does not set them — the sourced config file wins, and CLI arguments win over both (they are applied after the config file is sourced).

## Example Usage

### Basic installation with UEFI config:
```bash
sudo ./install.sh --config configs/example-uefi.conf --target-disk /dev/sda
```

### Encrypted install with passphrase:
```bash
export LUKS_PASSPHRASE="my-secret"
sudo ./install.sh --config configs/example-encrypted.conf --target-disk /dev/nvme0n1
```

### Dry-run mode (validate only):
```bash
sudo ./install.sh --config configs/example-uefi.conf --dry-run
```

### Reinstall mode (over existing installation):
```bash
sudo ./install.sh --config configs/example-uefi.conf --target-disk /dev/sda --reinstall
```

The `--reinstall` option:
1. Detects and unmounts any existing partitions on the target disk
2. Closes any existing LUKS mapper devices for the target disk
3. Proceeds with the normal installation pipeline (wipefs, sfdisk, format, clone, chroot)

### Verbose installation:
```bash
sudo ./install.sh --verbose --config configs/example-minimal.conf --target-disk /dev/sda --end-action reboot
```

## Dry-Run Mode

When `--dry-run` is specified, the installer validates the configuration and exits before the pre-flight stage, without performing any installation steps:

1. Loads the config file
2. Runs `validate_config()`
3. Prints "Configuration is valid"
4. Exits with code `0` on success, `1` on failure

**Requirements:**
- No root privileges required (dry-run runs before `stage_preflight`, so no hardware detection is performed)
- No disk operations are performed

**Exit codes:** `0` (success), `1` (validation failure / missing config). See `docs/exit_codes.md` for the full reference.

## Reinstall Mode

When `--reinstall` is specified, the installer performs pre-installation cleanup on the target disk before partitioning. This is useful for re-installing over an existing Void Linux installation without destroying the entire disk first.

### What it does:

1. **Unmounts existing partitions** — Scans for any partitions on the target disk that are currently mounted and unmounts them
2. **Closes LUKS mappers** — Detects and closes any open LUKS mapper devices (`/dev/mapper/luks-*`) that point to the target disk
3. **Continues normal pipeline** — After cleanup, proceeds with `wipefs`, `sfdisk`, formatting, cloning, and chroot configuration

### Safety:

- The unmount operation uses `umount -f` (force) to handle busy filesystems
- If a partition cannot be unmounted, a warning is logged but the installer continues
- LUKS mapper closure is best-effort — if `cryptsetup close` fails, a warning is logged
- The `wipefs -a` and `sfdisk` steps will still overwrite all data regardless

### Exit codes:
Same as normal installation (pre-flight `2`/`3`, any module failure `1`, signal `8`, end-action `9`). See `docs/exit_codes.md` for the full reference.

## Pre-flight: Root Check

The installer requires root privileges. Exit code `3` indicates "not root" (see `docs/exit_codes.md`).

## Installation Pipeline

The installer execution pipeline is defined in `AGENTS.md` (Installation Pipeline Workflow section). Each step is documented in its respective module (`docs/partitioning.md`, `docs/clone_mode.md`, `docs/user_config.md`, `docs/signal_handling.md`).
