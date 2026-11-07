# Partitioning Strategies

This document covers partitioning strategies, layouts, and best practices for the Void Linux installer.

## ⚠️ Safety & Data Loss Warning

Partitioning and formatting operations **irreversibly destroy all data** on the target disk. Before executing any partitioning commands:

### Pre-flight Safety Checklist

1. **Verify target disk**: Confirm `TARGET_DISK` matches the intended disk (e.g., `/dev/sda`, `/dev/nvme0n1`). Never use `${HOST_DISK}` or auto-detect without explicit user confirmation.
2. **Check for mounted partitions**: Ensure no partitions on the target disk are currently mounted.
3. **Confirm disk is not the host disk**: Verify the target disk is not the disk running the installer.
4. **Warn the user**: Display a clear warning before proceeding.
5. **Wipe existing signatures**: Remove any existing filesystem signatures **before** calling `sfdisk`. The order is: `wipefs -a` → `sfdisk` → `partx -u`.

## Disk Naming Conventions

| Disk Type | Example | Partition Prefix |
|---|---|---|
| SATA/SAS | `/dev/sda` | None (`sda1`, `sda2`) |
| NVMe | `/dev/nvme0n1` | `p` (`nvme0n1p1`, `nvme0n1p2`) |
| MMC/eMMC | `/dev/mmcblk0` | `p` (`mmcblk0p1`, `mmcblk0p2`) |
| Virtual | `/dev/vda` | None (`vda1`, `vda2`) |

The installer detects the disk type and applies the correct partition prefix automatically using `needs_p_prefix()` from `lib/hardware.sh`.

## Partition Layouts

### UEFI + ext4 (Recommended)

```
sda1       /boot/efi    vfat   100M    (EFI System Partition)
sda2       /            ext4   remaining
```

### UEFI + LUKS + ext4

```
sda1       /boot/efi    vfat   100M    (EFI System Partition, unencrypted)
sda2       /            ext4   remaining (LUKS encrypted)
```

### UEFI + Btrfs + Subvolumes

```
sda1       /boot/efi    vfat   100M    (EFI System Partition)
sda2       (btrfs)      btrfs  remaining
  Subvolumes:
    @      /
    @home  /home
    @var   /var
```

### Minimal (Single Partition)

```
sda1       /            ext4   remaining
```

### BIOS + ext4

```
sda1       /            ext4   remaining
```

### NVMe Example

```
nvme0n1p1  /boot/efi    vfat   100M    (EFI System Partition)
nvme0n1p2  /            ext4   remaining
```

## Swap Configuration

Swap configuration is controlled by `SWAP_TYPE` and `SWAP_SIZE` variables (see `docs/configuration.md`). This section covers the partitioning/formatting mechanics.

### Swap Partition

Creates a separate swap partition after all other partitions. The swap partition is activated with `swapon` after formatting.

#### Automatic root-size adjustment

When swap is a partition and the root partition uses the default "remaining space"
size (empty `--size`), the root size is computed in
`_adjust_partition_sizes_for_swap()` so the layout fits the disk:

```text
root_sectors = disk_sectors - start_offset(2048) - pre-root partitions - swap_sectors - gpt_reserve
```

- `pre-root partitions` is the sum of the sizes (in sectors) of every partition
  that comes **before** root — e.g. the EFI System Partition. Without subtracting
  these, the root size overflows the disk and `sfdisk` fails.
- `gpt_reserve` is `33` sectors for GPT (backup partition table), `0` otherwise.

If the resulting root size is `<= 0`, the installer aborts with a "disk too small"
error.

### Swap File

Creates a swap file on the root filesystem before entering chroot. The swap file is activated with `swapon` after creation.

```bash
# For btrfs: set the no-COW attribute (chattr +C) on an EMPTY file, BEFORE
# allocating. chattr +C on a fallocated file silently no-ops (returns 0 but
# does NOT set the COW attribute), leaving the file COW and swapon failing
# with EINVAL. So: create empty, set no-COW, THEN allocate — fallocate
# respects the no-COW attribute and allocates no-COW blocks.
if [[ "$(findmnt -n -o FSTYPE "${TARGET_DIR}")" == "btrfs" ]]; then
    : > "${TARGET_DIR}/swapfile"
    chattr +C "${TARGET_DIR}/swapfile"
fi

# Create file / allocate blocks (fallocate allocates; for btrfs the file was
# pre-created empty above, so fallocate allocates no-COW blocks).
fallocate -l "${SWAP_SIZE}" "${TARGET_DIR}/swapfile"

# Set correct permissions
chmod 0600 "${TARGET_DIR}/swapfile"

# Format as swap
mkswap "${TARGET_DIR}/swapfile"

# Activate swap
swapon "${TARGET_DIR}/swapfile"
```

> **Why `chattr +C` before `fallocate` on btrfs:** The no-COW attribute must be
> set on an empty file *before* allocation. On a fallocated file, `chattr +C`
> returns 0 but does not set the attribute (the file stays COW), and `swapon`
> then fails with `EINVAL`. `fallocate` respects an existing no-COW attribute, so
> setting it first allocates no-COW blocks. This is a per-file attribute — the
> rest of the root filesystem keeps CoW enabled.

### Swap Activation

Both swap partition and swap file are activated using `swapon`:

```bash
# For swap partition
swapon "${PART_DEVICES[$swap_idx]}"

# For swap file (on root filesystem)
swapon "${TARGET_DIR}/swapfile"
```

See `AGENTS.md` for available swap tools (`swapon`, `swaplabel`, `mkswap`).

## Best Practices

1. **EFI System Partition**: Required for UEFI systems, must be vfat and at least 100M
2. **Root Partition**: At least one partition must be mounted at `/`
3. **LUKS**: Consider encrypting the root partition for security
4. **Swap**: Use swap partition for hibernation support, swap file for simplicity
5. **Btrfs Subvolumes**: Use `@`, `@home`, `@var` naming convention for compatibility; mount subvolumes in dependency order (`@` first, then `@home`, `@var`) and unmount in reverse order to avoid `device or resource busy` errors
6. **Partition Order**: Place EFI partition first, then LUKS partitions, then others
7. **Size Planning**: Leave remaining space for root partition (empty `--size ""`)

## `define_partition()` Function

> **Note:** The `define_partition()` function is fully documented in `docs/configuration.md`. This section covers partitioning-specific details only.

### Arrays Populated

Each call to `define_partition()` appends values to these arrays:

| Array | Content | Example |
|---|---|---|
| `PART_MOUNTS` | Mount points | `/boot/efi`, `/`, `/home` |
| `PART_SIZES` | Partition sizes | `+100M`, `30G`, `` (remaining) |
| `PART_FS` | Filesystem types | `vfat`, `ext4`, `btrfs` |
| `PART_LUKS` | LUKS flag | `no`, `yes` |

The `PART_DEVICES` array is populated later by `lib/partitioning.sh` after the partition table is applied by `sfdisk` (e.g., `/dev/sda1`, `/dev/sda2`).

## Boot-Mode Partition Reconciliation

`_reconcile_partitions_for_boot_mode()` (called from `stage_partition`, before
`build_sfdisk_input`) discards partitions the detected firmware cannot use. This is
how "hardware detection prevails over config": an EFI System Partition (`/boot/efi`,
vfat) only makes sense on UEFI firmware. When the machine boots from BIOS, that
partition is removed from the layout before it is carved or formatted.

- Requires `BOOT_MODE` to have been reconciled with hardware first (see
  [`lib/hardware.md`](hardware.md#boot-mode-detection)).
- Only affects partitions incompatible with the detected mode. Today this means:
  - **BIOS**: drop `/boot/efi`.
  - **UEFI**: keep all partitions as-is.
- Mutates the global `PART_MOUNTS`, `PART_SIZES`, `PART_FS`, `PART_LUKS`, and
  `PART_SUBVOLS` arrays in place, so the subsequent layout/format steps operate on the
  reconciled set. If nothing was dropped, it logs that the layout was already
  consistent.

See [`lib/partitioning.sh`](#) for the implementation.

## sfdisk Layout Generation

The installer uses `sfdisk` to create partition tables. The layout is generated based on configuration and boot mode (UEFI vs BIOS).

### Partition Rescan

After applying the partition table, rescan partitions to ensure the kernel recognizes the new layout:

```bash
# Use partx -u for reliable partition rescan
partx -u "${TARGET_DISK}" 2>/dev/null || true
```

> **NOTE:** `partprobe` is NOT available on the Void Linux live ISO. Only `partx` (from util-linux) is available. Use `partx -u` exclusively. If `partx -u` fails (e.g., kernel does not recognize the new partition table), the next reboot will pick up the new layout automatically.

## Filesystem Formatting

After partitioning, format each partition with the appropriate filesystem:

### ext4 Formatting

The voidful installer uses `mkfs.ext4` (symlink to `mke2fs` on Void Linux) for ext4 filesystems:

```bash
mkfs.ext4 -F ${DEVICE}
```

### Other Filesystems

| Filesystem | Command | Notes |
|------------|---------|-------|
| btrfs | `mkfs.btrfs -f ${DEVICE}` | Force overwrite |
| vfat | `mkfs.vfat -F32 ${DEVICE}` | FAT32 |
| xfs | `mkfs.xfs -f -i sparse=0 ${DEVICE}` | Disable inode allocation |

## Filesystem Mounting

After partitioning and formatting, `mount_filesystems()` mounts the target filesystems in the correct order:

### Mount Order

1. **Root partition** — Mounted FIRST at `${TARGET_DIR}` (btrfs with its subvolume, or plain).
2. **Remaining partitions** — Mounted **shallowest-first** (a parent is always mounted before anything nested inside it). Each partition's mount point directory is created **right before its mount** (`mkdir -p "${target_dir}${mount_point}"`), so a nested mount point (e.g. `/boot/efi`) lands on the already-mounted parent partition (`/boot`), not in the rootfs.

**Why shallowest-first with per-mount mkdir:** at boot the kernel only mounts `/`; runit's `mount -a` then mounts the fstab entries, which reference mount points **by path**. A nested mount point (e.g. `/boot/efi`) lives on its parent partition (`/boot`), so the parent must be mounted before the child. `_generate_fstab()` emits entries shallowest-first (parent before child), so `mount -a` at boot mounts `/boot` (ext4) before `/boot/efi` (vfat on ext4) and finds the nested mount point.

### Btrfs Subvolume Workflow

Each btrfs partition is mounted by `_mount_btrfs_partition()` (called from `mount_filesystems()`):

1. Mount the raw btrfs device (or LUKS mapper) to a temporary location.
2. Create the subvolume (e.g. `@`, `@home`) if `PART_SUBVOLS` is set for that partition.
3. Unmount and remove the temporary location.
4. Mount the subvolume (`-o subvol=<name>`) at the partition's mount point.

The root btrfs partition is mounted first (step 1 of the mount order above); its subvolume `@` is the mount point used for the clone operation. Dependent subvolumes (`@home`, etc.) are mounted in step 2, after the root is mounted.

### Unmount Order

`_teardown()` unmounts nested mount points **deepest-first**. It reads `/proc/mounts` and keeps only the mount points under `${TARGET_DIR}` (i.e. `${TARGET_DIR}/...`), then sorts them reverse-lexicographically (a nested path is always lexicographically greater than its parent prefix, so children come before parents), then unmounts each, then the root mount itself, then closes the LUKS mappers. Unmounting a parent while a sub-mount is still attached fails with `target is busy`.

## fstab Generation

The `_generate_fstab()` function generates `/etc/fstab` using UUIDs derived from the `PART_DEVICES` and `PART_MOUNTS` arrays.

**Entry types:**

| Type | Example entry | Notes |
|------|---------------|-------|
| Partition | `UUID=<uuid> / ext4 defaults 0 2` | One entry per partition |
| Swap partition | `UUID=<uuid> none swap sw 0 0` | Swap partition (when `SWAP_TYPE="partition"`) |
| Swap file | `/swapfile none swap sw 0 0` | Swap file (when `SWAP_TYPE="file"`) |

**Mount options by filesystem (when `SWAP_TYPE="file"`):**

| Filesystem | Mount options | Reason |
|------------|---------------|--------|
| ext4 | `defaults,noatime` | `noatime` reduces write I/O for swap file |
| btrfs | `defaults` | Swap file carries `chattr +C` (no-COW); root keeps CoW |
| xfs | `defaults` | No special options needed |

## Partition Type Codes

The installer uses different partition type codes depending on the label type:

**GPT (UEFI):**

| GUID | Purpose | Used For |
|------|---------|----------|
| `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` | EFI System Partition | `/boot/efi` |
| `0FC63DAF-8483-4772-8E79-3D69D8477DE4` | Linux filesystem | Root, home, and other partitions |
| `0657FD6D-A4AB-43C4-84E5-0933C84B4F42` | Linux swap | Swap partitions |

**MBR/DOS (BIOS):**

| Code | Purpose | Used For |
|------|---------|----------|
| `0xef` | EFI System Partition | `/boot/efi` (if defined) |
| `0x82` | Linux swap | Swap partitions |
| `0x83` | Linux filesystem | Root, home, and other partitions |

## Disk Error Handling

Disk I/O errors can occur during partitioning, formatting, or cloning. The installer does **not** implement automatic retry logic, but should report errors clearly to the user.

### Common Disk Errors

| Error | Cause | Action |
|-------|-------|--------|
| `Input/output error` | Bad sectors, failing disk | Try a different disk; check hardware connections |
| `No space left on device` | Disk too small for partitions | Verify disk size before partitioning |
| `Device or resource busy` | Partition already mounted | Unmount before formatting |
| `Permission denied` | Not running as root | Run installer as root |


## Partition Table Format: GPT vs MBR

The installer uses **GPT** (GUID Partition Table) for UEFI systems and **MBR/DOS** for BIOS systems. The label type is derived from `BOOT_MODE`:

- `BOOT_MODE=uefi` → `PARTITION_LABEL_TYPE=gpt`
- `BOOT_MODE=bios` → `PARTITION_LABEL_TYPE=dos`

**Why GPT for UEFI:**
- UEFI spec requires GPT (MBR is not supported by UEFI firmware)
- GPT supports disks > 2TB (MBR is limited to 2TB)
- GPT supports up to 128 partitions (MBR is limited to 4 primary)
- GPT stores backup partition table at end of disk

**Why MBR for BIOS:**
- BIOS firmware uses MBR boot sector
- MBR is the standard partition table for legacy BIOS systems
- `grub-install` installs MBR GRUB on the first partition's boot sector

### BIOS Bootable Flag

`build_sfdisk_input` marks the **first partition** as `bootable` when the label type
is DOS/MBR (BIOS). In the sfdisk named-fields format this is the valueless `bootable`
field appended to the first partition line (e.g. `start=2048, size=1048576, type=83,
bootable`).

- **Why:** without the boot flag, `grub-probe` (called by `grub-install`) cannot
  resolve the boot partition and fails with `cannot find a GRUB drive for /dev/vda1`.
- **UEFI:** the boot flag is not emitted — UEFI firmware ignores it and uses the GPT
  EFI System Partition type GUID (`C12A7328-...`) instead.
- Only the **first** partition is marked bootable (a DOS disk has at most one active
  partition); `bootable` is never emitted on other partitions or in GPT mode.
