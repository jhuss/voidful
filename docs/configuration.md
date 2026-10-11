# Configuration Pattern

Configuration files are shell-sourceable and use a function-based approach for partition definitions. This document covers the complete configuration syntax, validation rules, and examples.

## Global Settings

```bash
TARGET_DISK="/dev/sda"           # Target disk for installation (accepts /dev/ prefix, normalized by hardware.sh)
TARGET_DIR="/mnt"                # Mount point for root partition (created with mkdir -p)
END_ACTION="shutdown"            # shutdown, reboot, script, func
BOOTLOADER="grub"                # "grub" or "none"
SWAP_TYPE="partition"            # See "SWAP_TYPE and SWAP_SIZE" section for full details
SWAP_SIZE="4G"
ENABLED_SERVICES=""              # Comma-separated list of runit services to enable
```

### Detected Variables

These variables are **detected or derived by the installer**, not set in the config file:

| Variable | Source | Configurable | Description |
|---|---|---|---|
| `BOOT_MODE` | `/sys/firmware/efi` exists? | No | `uefi` or `bios` |
| `LIVE_USERNAME` | `/etc/default/live.conf` (key: `USERNAME`) | No | Live ISO username (default: `anon`) — auto-detected, cannot be overridden |
| `LUKS_NAME` | Derived from mount point (`/` → `root`, `/home` → `home`) | No | LUKS mapper name for crypttab and keyfile paths — auto-derived, cannot be overridden |

> **Note:** Detected variables are auto-detected or derived by the installer and cannot be set in configuration files. They are used internally during the installation process.

### `TARGET_DIR` Initialization

`TARGET_DIR` is set in the global settings (default: `/mnt`). It is created with `mkdir -p` by the installer before mounting any partitions. It can be configured in the config file or overridden via command-line argument.

### Network Configuration (Optional)

For wireless or static IP setups, the following variables may be set:

```bash
NETWORK_DEVICE="wlan0"           # Network interface name
NETWORK_MODE="dhcp"              # "dhcp", "static", or "wireless"
# For static mode:
NETWORK_IP="192.168.1.100"
NETWORK_GW="192.168.1.1"
NETWORK_CIDR="24"
DNS_SERVERS="8.8.8.8,1.1.1.1"
```

## Partition Definitions

The `define_partition()` function is defined in `lib/partitioning.sh`. Configuration files source this function before calling it. It is not a standalone function — it relies on `log_error()` from `lib/logging.sh`.

Each partition is defined using `define_partition` with named parameters:

```bash
define_partition \
  --mount "/boot/efi" \
  --size "+100M" \
  --fs "vfat" \
  --luks "no"
```

### Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `--mount` | Yes | — | Mount point (e.g., `/`, `/home`, `/boot/efi`) |
| `--size` | No | `""` (remaining) | Size in MB/G (e.g., `+100M`, `4G`, empty for remaining) |
| `--fs` | Yes | — | Filesystem type (`ext4`, `vfat`, `btrfs`) |
| `--luks` | No | `"no"` | `yes` or `no` |

### Sourcing Order

The installer must source `lib/partitioning.sh` (which defines `define_partition()`) **before** sourcing the configuration file:

```bash
source "lib/partitioning.sh"
source "${CONFIG_FILE}"
```

This ensures `define_partition()` is available when the config file is parsed.

### SWAP_TYPE and SWAP_SIZE

These variables control swap configuration for the target system.

```bash
SWAP_TYPE="partition"
SWAP_SIZE="4G"
```

Or:

```bash
SWAP_TYPE="file"
SWAP_SIZE="4G"
```

Or no swap:

```bash
SWAP_TYPE="none"
```

When `SWAP_TYPE="none"`, no swap partition or file is created. This is suitable for minimal installs, containers, or systems with sufficient RAM.

### SWAP_SIZE Validation

`SWAP_SIZE` does NOT accept the `+` prefix (unlike partition sizes). Swap is an absolute size, not a "remaining space" value. The format must match `^[0-9]+[MG]$`.


**Key rules:**
- No `+` prefix allowed (unlike partition sizes)
- No `T` (terabyte) suffix — use `G` for large swap sizes
- Minimum recommended: `4G` (or `2G` for systems with ≥ 8GB RAM)
- Exit code `1` for validation failure

## Package Installation (Optional)

To install additional packages after clone but before bootloader installation, use `INSTALL_PACKAGES`:

```bash
INSTALL_PACKAGES="vim htop net-tools"
```

#### Package Name Validation

> **Validation:** Package names are validated against `^[a-zA-Z0-9][a-zA-Z0-9._+-]*$`. Invalid names are **logged as warnings and skipped** — the installer continues without them. No network calls are made. The `-y` flag is unnecessary in non-tty mode. The `-S` flag updates the package index first.

### User Configuration

Beyond partitions, the installer configures the target system's hostname, locale, keymap, root password, and optional regular user:

```bash
HOSTNAME="mydesktop"
LOCALE="en_US.UTF-8"
KEYMAP="us"
ROOT_PASS="rootpass123"
CREATE_USER="yes"
USER_LOGIN="juan"
USERNAME="Juan Perez"
USER_PASS="juandpass"
USER_SHELL="/bin/bash"
USER_GROUPS="wheel,audio,video"
TEXTCONSOLE="0"
```

### Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `HOSTNAME` | No | `voidlinux` | System hostname |
| `LOCALE` | No | `en_US.UTF-8` | System locale (must be generated in Void) |
| `KEYMAP` | No | `us` | Console keymap |
| `ROOT_PASS` | No | Interactive prompt | Root password (env var or prompted) |
| `CREATE_USER` | No | `no` | `yes` or `no` — whether to create a regular user |
| `USER_LOGIN` | Conditional | — | Login username (required if `CREATE_USER="yes"`) |
| `USERNAME` | No | `${USER_LOGIN}` | Display name / GECOS comment (defaults to `USER_LOGIN` if unset) |
| `USER_PASS` | Conditional | Interactive prompt | Regular user password (env var or prompted) |
| `USER_SHELL` | No | `/bin/bash` | User login shell |
| `USER_GROUPS` | No | `wheel,audio,video` | Comma-separated groups for the user |
| `TEXTCONSOLE` | No | `0` | Enable text-mode GRUB boot menu (`0` or `1`) |

### Installation Mode

Voidful uses a **system clone approach** (offline-first): the entire live system rootfs is copied to the target disk, then unnecessary packages are removed. See `docs/clone_mode.md` for implementation details.

### `TEXTCONSOLE` Behavior

When `TEXTCONSOLE="1"`, the installer uncomments `GRUB_TERMINAL_INPUT` and `GRUB_TERMINAL_OUTPUT` in `/etc/default/grub` inside chroot, forcing GRUB to use the console terminal instead of graphical output. Default is `0` (graphical GRUB). Valid values: `0` or `1`. Applied in `docs/user_config.md` during chroot configuration.

### Sudo Access

When `CREATE_USER="yes"`, the user is automatically added to the `wheel` group (if not explicitly overridden). Sudo configuration follows void-installer logic:

- If user is in `wheel`: `%wheel ALL=(ALL:ALL) ALL` is written to `/etc/sudoers.d/wheel`
- If user is NOT in `wheel`: A per-user sudoers file is created at `/etc/sudoers.d/${USER_LOGIN}`

See `docs/user_config.md` for complete sudo configuration details.

## Validation Rules

1. `TARGET_DISK` must be set and point to a valid block device
2. `END_ACTION` must be one of: `shutdown`, `reboot`, `script`, `func`
3. `SWAP_TYPE` must be one of: `partition`, `file`, or `none`
4. `SWAP_SIZE` is used when `SWAP_TYPE` is `"partition"` or `"file"`; it is ignored when `SWAP_TYPE` is `"none"`
5. At least one of `LUKS_PASSPHRASE` or `LUKS_KEYFILE` must be exported when any partition has `--luks "yes"` (both can be set for passphrase + keyfile fallback)
6. At least one partition must be mounted at `/`
7. UEFI systems require a vfat partition mounted at `/boot/efi`
8. Partition sizes must be valid (positive integers with optional `+` prefix and M/G suffix, or empty for remaining)
9. Only the LAST partition may have an empty size (remaining space). All other partitions must have explicit sizes.
10. `CREATE_USER="yes"` requires `USER_LOGIN` and (`USER_PASS` or interactive prompt availability)
11. `USER_LOGIN` must match `^[a-z_][a-z0-9_-]*$` (consistent with void-installer)
12. `USER_PASS` must be at least 8 characters when set via env var
13. `USER_GROUPS` members are validated inside chroot (not on host) — groups may not exist on the live ISO but will exist on the target system
14. `TEXTCONSOLE` must be `0` or `1` when set
15. `BOOTLOADER` must be `grub` or `none` when set

### Disk Size Validation

Before applying the partition table, the installer must validate that all partition sizes fit within the target disk:
- Exit code `1` for validation failure (consistent with other validation errors)

### ENABLED_SERVICES Parsing

The `ENABLED_SERVICES` variable is a comma-separated string of runit service names. During service enabling, the string is split on commas into a bash array. It is parsed in `lib/chroot_tasks.sh` during the chroot configuration phase (AGENTS.md Pipeline Step 5b), not during config validation.

**Validation (during config load):**
- If non-empty, each service name must match `^[a-z_][a-z0-9_-]*$` (consistent with runit service naming)
- Service names must not contain spaces or special characters
- Empty values are valid (no services to enable)

**Execution (inside chroot):**
- The actual service enabling happens via `sv enable` calls

## Parsing & Validation Flow

The installer processes configuration files through a defined sequence:

1. **Source Config**: `source "${CONFIG_FILE}"` — loads global variables and executes all `define_partition` calls, populating partition arrays.
2. **Validate Globals**: Check `TARGET_DISK` exists, `END_ACTION` is valid, `SWAP_TYPE` is valid, and LUKS credentials are properly set (if any partition has `--luks "yes"`).
3. **Assemble Partition Table**: Iterate over `PART_MOUNTS`, `PART_SIZES`, `PART_FS`, `PART_LUKS` in parallel to build the sfdisk layout.
4. **Cross-Validate**:
   - At least one partition must mount at `/`
   - UEFI systems require a vfat partition at `/boot/efi`
   - LUKS partitions must have at least one credential source (`LUKS_PASSPHRASE` and/or `LUKS_KEYFILE`); both can be set for passphrase + keyfile fallback
   - Partition sizes must be positive integers with M/G suffix, or empty for remaining space
5. **Pass to Partitioning Module**: The validated partition table is passed to `partitioning.sh` for sfdisk generation and formatting.

### validate_config() Function

The `validate_config()` function in `install.sh` orchestrates the parsing and validation flow described above. It calls individual validation checks for each configuration category.

### Example Config Files

The `configs/` directory contains reference configurations demonstrating common installation scenarios:

- `example-uefi.conf` — UEFI + ext4, no LUKS
- `example-btrfs.conf` — Btrfs with subvolumes
- `example-minimal.conf` — Minimal single partition
- `example-encrypted.conf` — UEFI + LUKS + ext4

Each example is fully functional and can be used as a starting point for custom configurations.
