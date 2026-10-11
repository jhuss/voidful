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
| `--bootloader LOADER` | Bootloader to install (`grub` only; `none` supported via config) | `BOOTLOADER` (default: `grub`) |
| `--dry-run` | Validate config and exit without installing | N/A (requires root for hardware checks) |
| `--verbose` | Enable verbose logging | `LOG_LEVEL` (default: `info`) |
| `--help` | Show help message | N/A |
| `--version` | Show version | N/A |

> **Note:** `--target-disk` accepts paths with or without `/dev/` prefix (e.g., `/dev/sda` or `sda`). The hardware detection module normalizes the device name internally. See `docs/hardware.md` for details.

## Environment Variables

The following environment variables can also override config values (highest priority):

| Variable | Description |
|---|---|
| `LUKS_PASSPHRASE` | LUKS passphrase (at least one of this or `LUKS_KEYFILE` required if any partition has `--luks "yes"`) |
| `LUKS_KEYFILE` | Path to LUKS keyfile on live ISO (at least one of this or `LUKS_PASSPHRASE` required if any partition has `--luks "yes"`; both can be set for passphrase + keyfile fallback) |
| `ROOT_PASS` | Root password |
| `USER_PASS` | Regular user password |
| `END_ACTION_SCRIPT` | Path to post-install script (for `END_ACTION=script`) |
| `END_ACTION_FUNC` | Function name to call (for `END_ACTION=func`) |

## Configuration File Discovery

The installer searches for config files in this order:

1. `--config FILE` (explicit path via CLI)
2. `$CONFIG_FILE` environment variable
3. `configs/example-uefi.conf` (default)
4. `configs/*.conf` — first file found in alphabetical order (fallback if default file doesn't exist)

If no config file is found, the installer exits with an error.

> **Note:** In dry-run mode, the installer still requires root privileges (for hardware detection and config file discovery). No disk operations are performed.

## Override Priority

Configuration values are resolved in this order (highest priority first):

1. **Environment variables** — `LUKS_PASSPHRASE`, `ROOT_PASS`, etc.
2. **CLI arguments** — `--config`, `--target-disk`, etc.
3. **Config file** — values defined in `configs/*.conf`
4. **Defaults** — hardcoded defaults in the installer

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

### Verbose installation:
```bash
sudo ./install.sh --verbose --config configs/example-minimal.conf --target-disk /dev/sda --end-action reboot
```

## Dry-Run Mode

When `--dry-run` is specified, the installer validates the configuration and exits without performing any installation steps:

1. Loads the config file
2. Runs `validate_config()`
3. Displays the resolved configuration
4. Exits with code `0` on success, `1` on failure

**Requirements:**
- Root privileges required (for hardware detection and config file discovery)
- No disk operations are performed

**Exit codes:** `0` (success), `1` (validation failure), `2` (disk error — target disk not found), `3` (permission error — not root). See `docs/exit_codes.md` for the full reference.

## Pre-flight: Root Check

The installer requires root privileges. Exit code `3` indicates "not root" (see `docs/exit_codes.md`).

## Installation Pipeline

The installer execution pipeline is defined in `AGENTS.md` (Installation Pipeline Workflow section). Each step is documented in its respective module (`docs/partitioning.md`, `docs/clone_mode.md`, `docs/user_config.md`, `docs/signal_handling.md`).
