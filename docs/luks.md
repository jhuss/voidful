# LUKS Implementation Details

This document covers the LUKS (Linux Unified Key Setup) implementation for the Void Linux installer.

## Overview

LUKS provides disk encryption for target partitions. The installer supports both passphrase and keyfile authentication methods.

## cryptsetup Flow

### 1. Open LUKS Partition

Format the partition with LUKS and open the mapper device. The flow depends on which credentials are configured:

#### Passphrase Only

```bash
cryptsetup luksFormat --batch-mode --type luks2 /dev/sda2
cryptsetup --batch-mode open --type luks2 --key-file <(echo "${LUKS_PASSPHRASE}") /dev/sda2 luks-root
```

#### Keyfile Only

```bash
cryptsetup luksFormat --batch-mode --type luks2 /dev/sda2
cryptsetup --batch-mode open --type luks2 --key-file "${LUKS_KEYFILE}" /dev/sda2 luks-root
```

#### Both Passphrase and Keyfile

```bash
# Format with passphrase in slot 0
cryptsetup luksFormat --batch-mode --type luks2 /dev/sda2

# Add keyfile in a separate slot
cryptsetup luksAddKey --batch-mode /dev/sda2 "${LUKS_KEYFILE}"

# Open the mapper device
cryptsetup --batch-mode open --type luks2 --key-file <(echo "${LUKS_PASSPHRASE}") /dev/sda2 luks-root
```

This creates `/dev/mapper/luks-root` which is then used for formatting and mounting.

### 2. Format Filesystem

```bash
mkfs.ext4 /dev/mapper/luks-root
```

### 3. Mount LUKS Partition

```bash
mount /dev/mapper/luks-root /mnt
```

## Passphrase and Keyfile

Both `LUKS_PASSPHRASE` and `LUKS_KEYFILE` can be used independently or **together on the same LUKS partition**. Having both provides flexibility: passphrase for interactive boot (typing at the console) and keyfile for automated/unattended boot.

### LUKS2 Multiple Key Slots

LUKS2 supports multiple key slots. The installer uses:
- **Slot 0** for the passphrase (via `cryptsetup luksFormat`)
- **Slot 1+** for the keyfile (via `cryptsetup luksAddKey`)

When both are configured, the initramfs cryptsetup hook can unlock the partition with either method. The keyfile is tried first; if not found, the user is prompted for the passphrase.

### Passphrase

- Set via `LUKS_PASSPHRASE` environment variable before running the installer
- Written to LUKS header slot 0 during `cryptsetup luksFormat`
- Prompted at boot time via initramfs cryptsetup hook
- **Unattended mode:** Pass the passphrase via process substitution to avoid interactive prompt

### Keyfile

- Set via `LUKS_KEYFILE` environment variable before running the installer (source path on live ISO)
- Added to LUKS header in a separate slot during `cryptsetup luksAddKey`
- Copied to target's `/etc/cryptsetup-keys/` during installation
- Permissions set to `0400` and owned by `root:root` on target
- Referenced by initramfs cryptsetup hook at boot time
- **Unattended mode:** Pass the file path directly to `--key-file`
- **Important:** The keyfile must exist and be readable on the live ISO at the specified path.

#### Keyfile Copy Operation

Before entering chroot, the keyfile must be copied to the target system:

```bash
# Create the keyfile directory
mkdir -p "${TARGET_DIR}/etc/cryptsetup-keys/"

# Copy the keyfile from the live ISO
cp "${LUKS_KEYFILE}" "${TARGET_DIR}/etc/cryptsetup-keys/${LUKS_NAME}.key"

# Set restrictive permissions
chmod 0400 "${TARGET_DIR}/etc/cryptsetup-keys/${LUKS_NAME}.key"
chown root:root "${TARGET_DIR}/etc/cryptsetup-keys/${LUKS_NAME}.key"
```

The keyfile is referenced by the crypttab entry and used by dracut at boot time.

### Configuration Scenarios

| Scenario | `LUKS_PASSPHRASE` | `LUKS_KEYFILE` | Behavior |
|----------|-------------------|----------------|----------|
| Passphrase only | Set | Unset | Unlock via passphrase prompt at boot |
| Keyfile only | Unset | Set | Unlock via keyfile at boot |
| Both | Set | Set | Try keyfile first, fall back to passphrase prompt |

## Mount Order

1. Open LUKS with `cryptsetup open` (creates `/dev/mapper/luks-<name>`)
2. Format mapper device with `mkfs.*`
3. Create mount point with `mkdir -p /mnt/<mount>`
4. Mount `/dev/mapper/luks-<name>` to mount point

## LUKS + Btrfs Subvolumes

When combining LUKS encryption with Btrfs subvolumes, the mount order is critical. The raw LUKS mapper device must be mounted temporarily to create subvolumes, then unmounted and remounted with `subvol=@`.

### Step-by-Step

#### Step 1: Open LUKS and Create Temporary Mount

Find the LUKS partition index and derive the LUKS name from the mount point:

```bash
# Find the index of the LUKS partition in the PART_* arrays
local luks_idx=0
for i in "${!PART_MOUNTS[@]}"; do
    if [[ "${PART_LUKS[$i]}" == "yes" && "${PART_MOUNTS[$i]}" == "/" ]]; then
        luks_idx=$i
        break
    fi
done

# Derive LUKS_NAME: / → root, other mount points have leading / removed and / replaced with -
local luks_mount="${PART_MOUNTS[$luks_idx]}"
local LUKS_NAME="${luks_mount#/}"
[[ -z "${LUKS_NAME}" ]] && LUKS_NAME="root"
LUKS_NAME="${LUKS_NAME//-/}"

local LUKS_MAPPER="/dev/mapper/luks-${LUKS_NAME}"

# Passphrase mode (or both — passphrase is tried as fallback if keyfile not found)
cryptsetup open --type luks2 --key-file <(echo "${LUKS_PASSPHRASE}") "${PART_DEVICES[$luks_idx]}" "${LUKS_NAME}"

local btrfs_tmp="${TARGET_DIR}/.btrfs_tmp"
mkdir -p "${btrfs_tmp}"
mount "${LUKS_MAPPER}" "${btrfs_tmp}"
```

#### Step 2: Create Subvolumes

```bash
btrfs subvolume create "${btrfs_tmp}/@"
btrfs subvolume create "${btrfs_tmp}/@home"
btrfs subvolume create "${btrfs_tmp}/@var"
umount "${btrfs_tmp}"
rmdir "${btrfs_tmp}"
```

#### Step 3: Mount Root Subvolume

```bash
mount -o subvol="@" "${LUKS_MAPPER}" "${TARGET_DIR}"
```

#### Step 4: Mount Dependent Subvolumes (After Clone)

```bash
for subvol in "@home" "@var"; do
    mkdir -p "${TARGET_DIR}/${subvol#@}"
    mount -o subvol="${subvol}" "${LUKS_MAPPER}" "${TARGET_DIR}/${subvol#@}"
done
```

#### Step 5: Unmount in Reverse Order

```bash
umount "${TARGET_DIR}/@var"
umount "${TARGET_DIR}/@home"
umount "${TARGET_DIR}"
```

## crypttab Configuration

LUKS partitions require a `/etc/crypttab` entry for initramfs decryption. The UUID must be sourced from the **raw block device** (not `/dev/mapper/`).

### Passphrase Only

```bash
echo "luks-root UUID=$(blkid -s UUID -o value /dev/sda2) none luks" > "${TARGET_DIR}/etc/crypttab"
```

### Keyfile Only

```bash
echo "luks-root UUID=$(blkid -s UUID -o value /dev/sda2) /etc/cryptsetup-keys/${LUKS_NAME}.key luks" > "${TARGET_DIR}/etc/crypttab"
```

### Both Passphrase and Keyfile

```bash
echo "luks-root UUID=$(blkid -s UUID -o value /dev/sda2) /etc/cryptsetup-keys/${LUKS_NAME}.key luks" > "${TARGET_DIR}/etc/crypttab"
```

When both are configured, the crypttab entry specifies the keyfile path. cryptsetup tries the keyfile first; if not found, it falls back to prompting for the passphrase (which is stored in LUKS slot 0). The `luks` option enables passphrase fallback automatically.

## fstab Configuration

LUKS partitions use `/dev/mapper/luks-<name>` in fstab, not the underlying block device:

```
/dev/mapper/luks-root  /        ext4  defaults  0 1
```

## Chroot Preparation

Before entering chroot: ensure `/dev/mapper/luks-<name>` is mounted at the target mount point and mount required filesystems (`proc`, `sys`, `dev`, `devpts`, `efivarfs` for UEFI).

## Initramfs / dracut

LUKS decryption at boot requires proper initramfs configuration via dracut. The approach differs between LUKS and non-LUKS systems:

### LUKS Systems

1. Write `hostonly=yes` to `${TARGET_DIR}/etc/dracut.conf.d/hostonly.conf` to ensure cryptsetup modules are included in the initramfs.
2. Run `dracut --force --add-drivers "ahci"` to rebuild the initramfs with LUKS support.

### Non-LUKS Systems

Run `dracut --no-hostonly --add-drivers "ahci" --force` to rebuild the initramfs from the cloned system without host-specific modules.

> **Important:** Do not mix `--no-hostonly` CLI flag with `hostonly=yes` in the config file. Use one approach or the other, not both.

## LUKS Name Derivation

The `luks-<name>` mapper name is derived from the partition's mount point:

| Mount Point | LUKS Name | Mapper Device |
|-------------|-----------|---------------|
| `/` | `root` | `/dev/mapper/luks-root` |
| `/home` | `home` | `/dev/mapper/luks-home` |
| `/var` | `var` | `/dev/mapper/luks-var` |

Derivation rule (step-by-step):
1. If mount point is `/`, the LUKS name is `root`
2. Otherwise, remove the leading `/` from the mount point
3. Replace any remaining `/` characters with `-`

Examples:
- `/` → `root`
- `/home` → `home`
- `/var/log` → `var-log`

The `LUKS_NAME` variable holds this derived name (e.g., `root`, `home`) and is used in:
- crypttab entries: `/etc/cryptsetup-keys/${LUKS_NAME}.key`
- Mapper device path: `/dev/mapper/luks-${LUKS_NAME}`
- Keyfile name on target: `${LUKS_NAME}.key`

Derivation rule: `/` → `root`, other mount points have leading `/` removed and remaining `/` replaced with `-`. For the full detected variables table, see `docs/configuration.md`.

## Multiple LUKS Partitions

All examples show a single LUKS partition. The configuration supports multiple encrypted partitions.

### Configuration Example

```bash
define_partition \
  --mount "/boot/efi" \
  --size "+100M" \
  --fs "vfat" \
  --luks "no"

define_partition \
  --mount "/" \
  --size "30G" \
  --fs "ext4" \
  --luks "yes"

define_partition \
  --mount "/home" \
  --size "50G" \
  --fs "ext4" \
  --luks "yes"
```

### LUKS Credential Handling

By default, all LUKS partitions share the **same passphrase** (`LUKS_PASSPHRASE`). During `cryptsetup open`, the same passphrase is used for every encrypted partition.

If `LUKS_KEYFILE` is set, the same keyfile is added to all LUKS partitions via `cryptsetup luksAddKey`, and the same keyfile path is used in each partition's crypttab entry.

## Security Considerations

- `LUKS_PASSPHRASE` and `LUKS_KEYFILE` must never be committed to version control — export them before running the installer
- Keyfiles stored on target at `/etc/cryptsetup-keys/` with restrictive permissions (`0400`, `root:root`)
- Passphrase is stored only in the LUKS header, not on the filesystem
- When both passphrase and keyfile are configured, the keyfile provides automated boot while the passphrase provides interactive fallback
- dracut hostonly mode reduces the attack surface by excluding unnecessary drivers from the initramfs
