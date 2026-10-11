# Hardware Detection Module

The hardware detection module (`lib/hardware.sh`) provides helpers for detecting boot mode, available disks, and disk properties.

## Functions

| Function | Description |
|----------|-------------|
| `detect_boot_mode()` | Sets `BOOT_MODE` to `uefi` or `bios` |
| `get_disks()` | Lists available block devices (excludes loop, ram, cdrom) |
| `get_disk_size <device>` | Returns disk size in GB |
| `get_disk_type <device>` | Returns `sata`, `nvme`, `mmc`, or `virtual` |
| `needs_p_prefix <device>` | Returns `yes` if disk uses `p` prefix (`nvme`/`mmc`) |
| `validate_disk <device>` | Validates that the device is a valid block device and not the host disk. Returns exit code 2 if invalid. |

## Variables Set

| Variable | Value | Source |
|----------|-------|--------|
| `BOOT_MODE` | `uefi` or `bios` | `/sys/firmware/efi` exists? |
| `AVAILABLE_DISKS` | Space-separated list | `lsblk --noheadings --output NAME,TYPE` |

## Boot Mode Detection

Checks for `/sys/firmware/efi` directory to determine boot mode.

## Disk Discovery

Lists available block devices, excluding loop, ram, and cdrom devices.

### Host Disk Exclusion

The `get_disks()` function returns ALL available block devices — it does **not** exclude the host machine's disks. This is intentional: the installer must present the disk list to the user for selection.

**Safety pattern:** After calling `get_disks()`, the installer MUST validate the user's choice against the actual disk list and ensure `TARGET_DISK` is NOT the disk containing the running system's root filesystem.

## Disk Properties

### Disk Type

Reads `/sys/block/<device>/device/type` to determine disk type (sata, nvme, mmc, virtual).

### Partition Prefix

Returns `yes` for nvme and mmc disks (requiring `p` prefix for partitions), `no` for sd/vd disks.

### Disk Type to Prefix Mapping

The return value of `get_disk_type()` maps to device name prefixes as follows:

| `get_disk_type()` Return | Device Prefix | Example |
|--------------------------|---------------|---------|
| `sata` | `sd` (no `p` prefix) | `/dev/sda1`, `/dev/sda2` |
| `nvme` | `nvme` (uses `p` prefix) | `/dev/nvme0n1p1`, `/dev/nvme0n1p2` |
| `mmc` | `mmc` (uses `p` prefix) | `/dev/mmcblk0p1`, `/dev/mmcblk0p2` |
| `virtual` | `vd` (no `p` prefix) | `/dev/vda1`, `/dev/vda2` |

The `needs_p_prefix()` function returns `yes` for `nvme` and `mmc`, `no` for `sata` and `virtual`.

## Device Name Normalization

The installer accepts device paths with `/dev/` prefix (e.g., `/dev/sda`) from configuration files and CLI arguments. The `normalize_device()` function in `lib/hardware.sh` strips the `/dev/` prefix to produce bare device names for internal use.

```bash
normalize_device() {
    local device="${1#/dev/}"
    echo "${device}"
}
```

All functions in `lib/hardware.sh` that accept a device name call `normalize_device()` internally. This means:

- Configuration files and CLI can use `/dev/sda`, `/dev/nvme0n1`, etc.
- Internal functions always work with bare names (`sda`, `nvme0n1`)
- The `get_disk_size()` and `get_disk_type()` functions prepend `/dev/` when accessing `/sys/block/<device>` or `/sys/block/<device>/device/type`

## Architecture Detection

The installer detects the system architecture using `xbps-uhelper arch` and stores the result in `XBPS_ARCH`. This variable is used to:

- Select the correct repositories (e.g., `x86_64-musl` vs `x86_64-glibc`)
- Choose appropriate locale packages
- Select correct bootloader packages (e.g., `grub-x86_64-efi` vs `grub-i386-efi`)

```bash
XBPS_ARCH=$(xbps-uhelper arch)
```

### Architecture-Sensitive Configuration

| Variable | musl | glibc |
|----------|------|-------|
| Repositories | `x86_64-musl` | `x86_64-glibc` |
| Locale package | `glibc-locales-musl` | `glibc-locales` |
| Bootloader EFI | `grub-x86_64-efi` | `grub-x86_64-efi` |

> **Note:** The architecture is detected once during pre-flight checks and cached in `XBPS_ARCH` for the remainder of the installation.

## Usage

> **Important:** All functions in `lib/hardware.sh` expect **bare device names** (e.g., `sda`, `nvme0n1`, `mmcblk0`) — **NOT** `/dev/` prefixed names. The `get_disk_size()` and `get_disk_type()` functions prepend `/dev/` internally.
