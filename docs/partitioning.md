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

### Swap File

Creates a swap file on the root filesystem before entering chroot. The swap file is activated with `swapon` after creation.

```bash
# Create swap file (uses dd for reliability)
dd if=/dev/zero of="${TARGET_DIR}/swapfile" bs=1M count=$((SWAP_SIZE / 1024 * 1024)) status=progress

# Set correct permissions
chmod 0600 "${TARGET_DIR}/swapfile"

# Format as swap
mkswap "${TARGET_DIR}/swapfile"

# Activate swap
swapon "${TARGET_DIR}/swapfile"
```

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

### ext2/3/4 Formatting

The voidful installer uses `mkfs.ext4` (symlink to `mke2fs` on Void Linux) for ext family filesystems:

```bash
mkfs.ext2 -F ${DEVICE}       # ext2
mkfs.ext3 -F ${DEVICE}       # ext3
mkfs.ext4 -F ${DEVICE}       # ext4
```

### Other Filesystems

| Filesystem | Command | Notes |
|------------|---------|-------|
| btrfs | `mkfs.btrfs -f ${DEVICE}` | Force overwrite |
| vfat | `mkfs.vfat -F32 ${DEVICE}` | FAT32 |
| xfs | `mkfs.xfs -f -i sparse=0 ${DEVICE}` | Disable inode allocation |
| f2fs | `mkfs.f2fs -f ${DEVICE}` | Flash-Friendly FS |

## Filesystem Mounting

After partitioning and formatting, mount the target filesystems in the correct order:

### Mount Order

1. **Root partition** — Mount first at `${TARGET_DIR}`
2. **EFI partition** — Mount at `${TARGET_DIR}/boot/efi` (UEFI only)
3. **Other partitions** — Mount in dependency order (`/home`, `/var`, etc.)


### Btrfs Subvolume Workflow

Btrfs subvolume management requires a specific sequence: create subvolumes on the raw filesystem, then mount the root subvolume `@` at `${TARGET_DIR}`, and finally mount dependent subvolumes.

#### Step 1: Create Subvolumes (on raw filesystem)

After `mkfs.btrfs` but **before** mounting with `subvol=@`: identify the root partition index and use the `PART_DEVICES` array for dynamic device resolution.

```bash
# Find the index of the root partition in the PART_* arrays
local root_idx=0
for i in "${!PART_MOUNTS[@]}"; do
    if [[ "${PART_MOUNTS[$i]}" == "/" && "${PART_FS[$i]}" == "btrfs" ]]; then
        root_idx=$i
        break
    fi
done

local root_device="${PART_DEVICES[$root_idx]}"

local btrfs_tmp="${TARGET_DIR}/.btrfs_tmp"
mkdir -p "${btrfs_tmp}"
mount "$(blkid -s UUID -o value "${root_device}")" "${btrfs_tmp}"
btrfs subvolume create "${btrfs_tmp}/@"
btrfs subvolume create "${btrfs_tmp}/@home"
btrfs subvolume create "${btrfs_tmp}/@var"
umount "${btrfs_tmp}"
rmdir "${btrfs_tmp}"
```

#### Step 2: Mount Root Subvolume

Mount the `@` subvolume at `${TARGET_DIR}` — this is the mount point used for the clone operation:

```bash
mount -o subvol=@ "$(blkid -s UUID -o value "${root_device}")" "${TARGET_DIR}"
```

#### Step 3: Mount Dependent Subvolumes (After Clone)

After the clone operation completes, mount the additional subvolumes:

```bash
for i in "${!PART_MOUNTS[@]}"; do
    if [[ "${PART_MOUNTS[$i]}" != "/" && "${PART_FS[$i]}" == "btrfs" ]]; then
        local subvol="${PART_MOUNTS[$i]}"
        mkdir -p "${TARGET_DIR}${subvol}"
        mount -o subvol="${subvol#/}" "$(blkid -s UUID -o value "${PART_DEVICES[$i]}")" "${TARGET_DIR}${subvol}"
    fi
done
```

#### Step 4: Unmount in Reverse Order

Unmount in reverse order: `/var`, `/home`, then `/`.

## fstab Generation

The `generate_fstab()` function generates `/etc/fstab` using UUIDs derived from the `PART_DEVICES` and `PART_MOUNTS` arrays.

## Partition Type Codes

| Type Code | Purpose | Used For |
|-----------|---------|----------|
| `EF00` | EFI System Partition | `/boot/efi` on UEFI systems |
| `8300` | Linux filesystem | ⚠️ Not used (GPT-only; kept for reference only) |
| `8309` | Linux filesystem (GPT) | Root, home, and other partitions on GPT |
| `8200` | Linux swap | Swap partitions |
| `8E00` | Linux LVM | ⚠️ Not used (LVM unsupported; kept for reference only) |

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

The installer uses **GPT** (GUID Partition Table) for all supported systems, both UEFI and BIOS.

- **UEFI requirement:** UEFI systems **require** GPT (MBR is not supported by UEFI spec)
- **Larger disks:** GPT supports disks > 2TB (MBR is limited to 2TB)
- **More partitions:** GPT supports up to 128 partitions (MBR is limited to 4 primary)
- **Redundancy:** GPT stores backup partition table at end of disk

MBR (Master Boot Record) is **not supported**.
