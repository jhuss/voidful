# Hardware Detection Module

The hardware detection module (`lib/hardware.sh`) provides helpers for detecting boot mode, available disks, and disk properties.

## Functions

| Function | Description |
|----------|-------------|
| `detect_boot_mode()` | Sets `BOOT_MODE` to `uefi` or `bios` |
| `get_disks()` | Prints disk-type block device names (one per line, bare names without `/dev/`); loop, ram and cdrom devices are excluded by the `lsblk` type filter |
| `validate_disk <device>` | Validates that the device exists, is a block device, and is not the CD-ROM drive (`sr0`). Returns `1` if invalid (the pre-flight stage maps this to exit code `2`). |
| `detect_arch()` | Returns system architecture via `xbps-uhelper arch` (e.g., `x86_64-musl`) |
| `get_partition_prefix <device>` | Returns `p` for `nvme`/`mmc` disks, empty for `sd`/`vd` disks |

## Variables Set

| Variable | Value | Source |
|----------|-------|--------|
| `BOOT_MODE` | `uefi` or `bios` | `/sys/firmware/efi/systab` exists? |
| `ARCH` | `xbps-uhelper arch` output (e.g., `x86_64-musl`) | set in `stage_preflight`, logged (the disk list itself is a local `disk_names` variable, one name per line) |

## Boot Mode Detection

Checks for `/sys/firmware/efi/systab` (a file, not just a directory) to determine
boot mode via `detect_boot_mode()`, which prints `uefi` or `bios` and sets the global
`BOOT_MODE`. Using `systab` instead of the `/sys/firmware/efi` directory matches
Void-installer's detection and avoids false positives.

### Hardware Detection Prevails Over Config

`detect_boot_mode()` runs in **stage_preflight** (after config loading) and its result
is authoritative. This guarantees the installer never uses a boot mode the firmware
cannot use — for example, it will not install UEFI GRUB on BIOS hardware just because
a config template requested UEFI.

Concretely:

- `stage_preflight` reconciles `BOOT_MODE` so the hardware-detected value always wins
  over anything implied by the config or environment. An invalid value is forced to
  `bios`, and a valid value is logged as authoritative.
- In **stage_partition**, `_reconcile_partitions_for_boot_mode()` (see
  [`lib/partitioning.sh`](partitioning.md)) discards partitions the detected firmware
cannot use. The only UEFI-only partition today is an EFI System Partition (`/boot/efi`).
When the machine boots from BIOS, that partition is dropped before the layout is built,
so it neither wastes space nor gets mis-formatted. When UEFI is detected, it is kept.
- `CHROOT_BOOT_MODE` (used to select the GRUB install target) derives from the
  reconciled `BOOT_MODE`, so a BIOS system installs MBR GRUB even if the config named
  a UEFI layout.

## Disk Discovery

Lists available block devices, excluding loop, ram, and cdrom devices.

### Disk Validation Safety

The `get_disks()` function returns all disk-type block devices — it does **not** exclude the host machine's disks. Disk validation is done by `validate_disk()`, which checks that the target:

1. exists (`/dev/<device>` is present),
2. is a block device (`[ -b ]`), and
3. is **not** the CD-ROM drive (`sr0` — the live ISO's source, which would be a nonsensical install target).

> **Note:** there is **no** check that `TARGET_DISK` is not the disk containing the running system's root filesystem. The user must verify the device (e.g., with `lsblk`) before running the installer.

## Partition Prefix

`get_partition_prefix()` returns `p` for `nvme` and `mmc` disks (requiring `p` prefix for partitions), and an empty string for `sd`/`vd` disks.

| Disk prefix | `get_partition_prefix()` Return | Example |
|-------------|-------------------------------|---------|
| `sd` | (empty) | `/dev/sda1`, `/dev/sda2` |
| `nvme` | `p` | `/dev/nvme0n1p1`, `/dev/nvme0n1p2` |
| `mmc` | `p` | `/dev/mmcblk0p1`, `/dev/mmcblk0p2` |
| `vd` | (empty) | `/dev/vda1`, `/dev/vda2` |

## Architecture Detection

The installer detects the system architecture using `xbps-uhelper arch` and stores the result in `ARCH` (set in `stage_preflight`). The value is **logged for information only** — it is not used to select repositories, locale packages, or bootloader packages, because the system-clone approach is fully offline and installs no packages from a repository.

## Usage

> **Important:** All functions in `lib/hardware.sh` expect **bare device names** (e.g., `sda`, `nvme0n1`, `mmcblk0`) — **NOT** `/dev/` prefixed names. `validate_disk()` prepends `/dev/` internally when checking the device.
