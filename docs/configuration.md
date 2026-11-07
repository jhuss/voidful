# Configuration Pattern

Configuration files are shell-sourceable and use a function-based approach for partition definitions. This document covers the complete configuration syntax, validation rules, and examples.

## Global Settings

```bash
TARGET_DISK="/dev/sda"           # Target disk for installation
TARGET_DIR="/mnt"                # Mount point for root partition
END_ACTION="shutdown"            # shutdown, reboot, script, func, none
BOOTLOADER="grub"                # "grub" or "none"
SWAP_TYPE="partition"            # "partition", "file", or "none"
SWAP_SIZE="4G"                   # Swap size (partition or file)
ENABLED_SERVICES=""              # Comma-separated list of runit services
HOSTNAME="voidful"               # System hostname
LOCALE="en_US.UTF-8"            # System locale
KEYMAP="us"                      # Keyboard layout
TIMEZONE=""                     # Timezone (e.g., America/Argentina/Buenos_Aires; empty = keep system default)
ROOT_PASS=""                     # Root password (or via ROOT_PASS env var)
CREATE_USER="yes"                # Create regular user
USER_LOGIN="user"               # Login username
USERNAME="Void User"            # Full display name
USER_GROUPS="wheel"             # Supplementary groups
USER_PASS=""                    # User password (or via USER_PASS env var)
TEXTCONSOLE="0"                 # GRUB text console (0=graphical, 1=text)
```
ISSUE_MESSAGE='                   # Custom ASCII art and information for /etc/issue

      __p888888q__           Void Linux
    _q888P"  "Y888p_         Kernel: $(uname -r)
   d888"  _pp_  "888b        Arch:   $(uname -m)
  (888|  d8888b  |888)       Uptime: $(uptime -p)
   Y888_ "Y88P" _888P
    "q888p_  _q888p"
       ""Y8888P""
'
```

### `TARGET_DIR` Initialization

`TARGET_DIR` is set in the global settings (default: `/mnt`). It is created with `mkdir -p` by the installer before mounting any partitions. It can be configured in the config file or overridden via command-line argument.

### Network Configuration (Optional)

For DHCP or static IP setups, the following variables may be set:

```bash
NETWORK_DEVICE="eth0"            # Network interface name
NETWORK_MODE="dhcp"              # "dhcp" or "static"
# For static mode:
NETWORK_IP="192.168.1.100"
NETWORK_GATEWAY="192.168.1.1"
DNS_SERVERS="8.8.8.8,1.1.1.1"    # Comma-separated (static mode; empty → DNS via DHCP)
```

`DNS_SERVERS` is only used in `static` mode. When set, the values (comma-separated, e.g. `8.8.8.8,1.1.1.1`) are written to `/etc/dhcpcd.conf` as `static domain_name_servers=…`. When unset/empty in static mode, the line is omitted and DNS is obtained via DHCP. In `dhcp` mode DNS always comes from the DHCP server (no `DNS_SERVERS` needed).

## Partition Definitions

The `define_partition()` function is defined in `lib/config.sh`. Configuration files source this function before calling it. It is not a standalone function — it relies on `log_error()` from `lib/logging.sh`.

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
| `--size` | No | `""` (remaining) | Size in MB/GB/TB (e.g., `+100M`, `4G`, `2T`, empty for remaining) |
| `--fs` | Yes | — | Filesystem type (`ext4`, `vfat`, `btrfs`, `xfs`) |
| `--luks` | No | `"no"` | `yes` or `no` |
| `--subvol` | No | `""` (none) | Btrfs subvolume name (e.g., `@`, `@home`) — only meaningful with `--fs "btrfs"` |

### Sourcing Order

The installer must source `lib/config.sh` (which defines `define_partition()`) **before** sourcing the configuration file:

```bash
source "lib/config.sh"
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
USER_GROUPS="wheel"
TEXTCONSOLE="0"
```

### Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `HOSTNAME` | No | `voidful` | System hostname |
| `LOCALE` | No | `en_US.UTF-8` | System locale |
| `KEYMAP` | No | `us` | Console keymap |
| `TIMEZONE` | No | `""` (system default) | Timezone name under /usr/share/zoneinfo |
| `ROOT_PASS` | No | skipped (not set) | Root password (env var or config; no interactive prompt) |
| `CREATE_USER` | No | `no` | `yes` or `no` — whether to create a regular user |
| `USER_LOGIN` | Conditional | — | Login username (required if `CREATE_USER="yes"`) |
| `USERNAME` | No | `${USER_LOGIN}` | Display name / GECOS comment (defaults to `USER_LOGIN` if unset) |
| `USER_PASS` | Conditional | skipped (not set) | Regular user password (env var or config; no interactive prompt) |
| `USER_SHELL` | No | `/bin/bash` | User login shell |
| `USER_GROUPS` | No | `wheel` | Comma-separated groups for the user |
| `TEXTCONSOLE` | No | `0` | Enable text-mode GRUB boot menu (`0` or `1`) |

### Installation Mode

Voidful uses a **system clone approach** (offline-first): the entire live system rootfs is copied to the target disk, then unnecessary packages are removed. See `docs/clone_mode.md` for implementation details.

### `TEXTCONSOLE` Behavior

When `TEXTCONSOLE` is set to a truthy value (`1`, `yes`, `true`, or `on`, case-insensitive), the installer sets `GRUB_TERMINAL_OUTPUT=console` in `/etc/default/grub` inside the chroot, forcing GRUB to use the text-mode console. When it is `0`, `no`, or unset, `GRUB_TERMINAL_OUTPUT` is left at its default (text + console combined, no forced console). An unrecognized value also falls back to the default (no forced console). Applied in `docs/user_config.md` during chroot configuration.

### Sudo Access

When `CREATE_USER="yes"`, the user is created with `-G "${USER_GROUPS}"` (default `wheel`). Sudo configuration is unconditional and does not depend on the user's groups:

- `/etc/sudoers.d/wheel` is always written with `%wheel ALL=(ALL) SETENV: ALL` (and `chmod 0440` applied), so any user in the `wheel` group can run sudo.
- No per-user sudoers file is created and no `visudo -c` check is run.

See `docs/user_config.md` for complete sudo configuration details.

## Validation Rules

1. `TARGET_DISK` must be set and point to a valid block device — checked in the pre-flight stage (`stage_preflight`, exit code `2`), not during config validation
2. `END_ACTION` must be one of: `shutdown`, `reboot`, `script`, `func`, `none`. **Not validated during config load** — an unknown value is only caught in the end-action stage (exit code `9`)
3. `SWAP_TYPE` must be one of: `partition`, `file`, or `none`
4. `SWAP_SIZE` is used when `SWAP_TYPE` is `"partition"` or `"file"`; it is ignored when `SWAP_TYPE` is `"none"`
5. At least one of `LUKS_PASSPHRASE` or `LUKS_KEYFILE` must be exported when any partition has `--luks "yes"` (both can be set for passphrase + keyfile fallback)
6. At least one partition must be mounted at `/`
7. UEFI systems require a vfat partition mounted at `/boot/efi`
8. Partition sizes must be valid (positive integers with optional `+` prefix and M/G/T suffix, or empty for remaining)
9. Only the LAST partition may have an empty size (remaining space). All other partitions must have explicit sizes.
10. `CREATE_USER="yes"` requires `USER_LOGIN` — enforced in the chroot stage (user creation is silently skipped with a log message when `USER_LOGIN` is unset); `USER_PASS` is optional (skipped when unset, no interactive prompt)
11. `USER_LOGIN` must match `^[a-z][a-z0-9_-]{0,31}$` (validated in the chroot stage)
12. `USER_PASS` is used as-is when set (no length validation); when unset, no password is set for the user
13. `USER_GROUPS` is **not** validated — groups that do not exist are tolerated (`useradd -G` failures are logged but non-fatal); on the target system the standard groups exist
14. `TEXTCONSOLE`: truthy values (`1`/`yes`/`true`/`on`) enable the text-mode console; `0`/`no`/unset leave the default. No hard validation — unrecognized values fall back to the default (no forced console)
15. `BOOTLOADER`: not validated during config load (only the `--bootloader` CLI argument is validated, exit code `1`); accepted values are `grub` or `none`
16. LUKS partitions require BOTH `/boot` (kernel/initramfs) AND `/boot/efi` (UEFI only) — GRUB must read kernel/initramfs from unencrypted partitions
17. When LUKS is used, at least one partition must have `--mount "/boot"` with `--luks "no"` (unencrypted boot partition)
18. When TIMEZONE is set, /usr/share/zoneinfo/${TIMEZONE} must exist as a regular file (validated in stage 2, before any disk operation)

### Disk Size Validation

When `SWAP_TYPE="partition"`, the partitioning stage checks (via `_adjust_partition_sizes_for_swap`) that the requested partition sizes fit within the target disk; on "Disk too small" the stage fails with exit code `1`. No disk-size check is performed during config validation (`validate_config`).

### ENABLED_SERVICES Parsing

The `ENABLED_SERVICES` variable is a comma-separated string of runit service names. During service enabling, the string is split on commas into a bash array. It is parsed in `lib/chroot_tasks.sh` during the chroot configuration phase (AGENTS.md Pipeline Step 5b), not during config validation. Service names are not validated at config load.

**Execution (inside chroot):**
- Services are enabled by symlinking: `ln -s /etc/sv/<service> /var/service/<service>` (dangling symlinks removed first; `/var/service` created if missing)
- A service with no matching directory in `/etc/sv/` causes the `ln` to fail, which is logged but non-fatal

## Parsing & Validation Flow

The installer processes configuration files through a defined sequence:

1. **Source Config**: `source "${CONFIG_FILE}"` — loads global variables and executes all `define_partition` calls, populating partition arrays.
2. **Validate Globals** (`validate_config` in `lib/config.sh`): Check `SWAP_TYPE` is valid, `SWAP_SIZE` format, LUKS credentials are properly set (if any partition has `--luks "yes"`), and `TIMEZONE` (when set) points to an existing zoneinfo file. `TARGET_DISK` and `END_ACTION` are intentionally NOT checked here (pre-flight stage and end-action stage respectively).
3. **Assemble Partition Table**: Iterate over `PART_MOUNTS`, `PART_SIZES`, `PART_FS`, `PART_LUKS` in parallel to build the sfdisk layout.
4. **Cross-Validate**:
   - At least one partition must mount at `/`
   - UEFI systems require a vfat partition at `/boot/efi`
   - LUKS partitions require BOTH `/boot` (unencrypted, for kernel/initramfs) AND `/boot/efi` (UEFI only, for GRUB EFI binary)
   - LUKS partitions must have at least one credential source (`LUKS_PASSPHRASE` and/or `LUKS_KEYFILE`); both can be set for passphrase + keyfile fallback
   - Partition sizes must be positive integers with M/G/T suffix, or empty for remaining space
5. **Pass to Partitioning Module**: The validated partition table is passed to `partitioning.sh` for sfdisk generation and formatting.

### validate_config() Function

The `validate_config()` function in `lib/config.sh` orchestrates the parsing and validation flow described above. It calls individual validation checks for each configuration category.

### Example Config Files

The `configs/` directory contains reference configurations demonstrating common installation scenarios:

- `example-uefi.conf` — UEFI + ext4, no LUKS
- `example-btrfs.conf` — Btrfs with subvolumes
- `example-minimal.conf` — Minimal single partition
- `example-encrypted.conf` — UEFI + LUKS + ext4 (with `/boot/efi` + `/boot`)
- `example-encrypted-btrfs.conf` — UEFI + dual LUKS + Btrfs subvolumes (with `/boot/efi` + `/boot`)
- `example-bios-ext4.conf` — BIOS + ext4, no LUKS

Each example is fully functional and can be used as a starting point for custom configurations.
