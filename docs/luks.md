# LUKS Implementation Details

This document covers the LUKS (Linux Unified Key Setup) implementation for the Void Linux installer.

## Overview

LUKS provides disk encryption for target partitions. The installer supports both passphrase and keyfile authentication methods.

## cryptsetup Flow

### 1. Open LUKS Partition

Format the partition with LUKS and open the mapper device. The flow depends on which credentials are configured:

The key is always passed as **raw bytes** (via `printf '%s'` for the passphrase — no
trailing newline — or the keyfile path directly). cryptsetup keyfiles are read as raw
bytes, so the exact bytes written to a slot must match what crypttab reads at boot.

#### Passphrase Only (slot 0 = passphrase)

```bash
cryptsetup luksFormat --batch-mode --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --hash sha256 \
    --iter-time 5000 --use-random \
    --key-file <(printf '%s' "${LUKS_PASSPHRASE}") /dev/sda2
cryptsetup --batch-mode open --type luks2 \
    --key-file <(printf '%s' "${LUKS_PASSPHRASE}") /dev/sda2 luks-root
```

#### Keyfile Only (slot 0 = raw keyfile)

```bash
# The keyfile is used raw as slot 0 (no read into memory, no newline handling)
cryptsetup luksFormat --batch-mode --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --hash sha256 \
    --iter-time 5000 --use-random \
    --key-file "${LUKS_KEYFILE}" /dev/sda2
# Open with the same raw keyfile
cryptsetup --batch-mode open --type luks2 \
    --key-file "${LUKS_KEYFILE}" /dev/sda2 luks-root
```

#### Both Passphrase and Keyfile (slot 0 = passphrase, slot 1 = keyfile)

```bash
# slot 0 = passphrase
cryptsetup luksFormat --batch-mode --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --hash sha256 \
    --iter-time 5000 --use-random \
    --key-file <(printf '%s' "${LUKS_PASSPHRASE}") /dev/sda2

# slot 1 = keyfile (the passphrase authenticates the add; the keyfile is the new key)
printf '%s' "${LUKS_PASSPHRASE}" | cryptsetup luksAddKey --batch-mode \
    --key-file - /dev/sda2 "${LUKS_KEYFILE}"

# Open the mapper device (passphrase = slot 0)
printf '%s' "${LUKS_PASSPHRASE}" | cryptsetup --batch-mode open --type luks2 \
    --key-file - /dev/sda2 luks-root
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

LUKS2 supports multiple key slots. Slot 0 is **always the credential that unlocks the
partition during the install and (when a passphrase is present) the interactive boot
fallback**. The keyfile slot is chosen by credential mode:

- **Passphrase only** — slot 0 = passphrase (written via `printf '%s'` to a temp file,
  no trailing newline).
- **Keyfile only** — slot 0 = the **raw keyfile** (`--key-file "${LUKS_KEYFILE}"`, used
  directly, never read into memory). crypttab therefore points at the keyfile and boot
  reads slot 0 = the keyfile.
- **Both (combined)** — slot 0 = passphrase (via `luksFormat`), slot 1 = keyfile (via
  `luksAddKey`, authenticated by the passphrase). crypttab points at the keyfile; the
  initramfs tries the keyfile (slot 1) first and falls back to the passphrase prompt
  (slot 0) if it is missing.

In every mode the bytes written to slot 0 match exactly what crypttab reads at boot
(passphrase → the passphrase bytes; keyfile → the raw keyfile bytes), so the initramfs
can decrypt the partition non-interactively.

### Passphrase

- Set via `LUKS_PASSPHRASE` environment variable before running the installer
- Written to LUKS header slot 0 during `cryptsetup luksFormat`
- Prompted at boot time via initramfs cryptsetup hook
- **Unattended mode:** Pass the passphrase via process substitution to avoid interactive prompt

### Keyfile

- Set via `LUKS_KEYFILE` environment variable before running the installer (source path on live ISO)
- Added to LUKS header in a separate slot during `cryptsetup luksAddKey`
- Copied to target's `/etc/cryptsetup-keys/` during installation
- Permissions set to `0400` via `chmod 0400` (no `chown` is run; the file is `root:root` because the installer runs as root and `cp` as root preserves root ownership)
- Referenced by initramfs cryptsetup hook at boot time
- **Unattended mode:** Pass the file path directly to `--key-file`
- **Important:** The keyfile must exist and be readable on the live ISO at the specified path.

#### Keyfile Copy Operation

Before entering chroot, the keyfile must be copied to the target system. The keyfile retains its original basename from the live ISO:

```bash
# Create the keyfile directory
mkdir -p "${TARGET_DIR}/etc/cryptsetup-keys/"

# Copy the keyfile from the live ISO (retains original basename)
cp "${LUKS_KEYFILE}" "${TARGET_DIR}/etc/cryptsetup-keys/$(basename "${LUKS_KEYFILE}")"

# Set restrictive permissions (no chown — root ownership comes from running as root)
chmod 0400 "${TARGET_DIR}/etc/cryptsetup-keys/$(basename "${LUKS_KEYFILE}")"
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

When combining LUKS encryption with Btrfs subvolumes, the mount order is critical. Each btrfs partition is mounted by `_mount_btrfs_partition()` (see `docs/partitioning.md`): the raw LUKS mapper device is mounted temporarily to create the subvolume, then unmounted and remounted with `subvol=<name>`.

### Step-by-Step

1. **Open LUKS** with `cryptsetup open` (creates `/dev/mapper/luks-<name>`; LUKS names are derived from the mount point via `_luks_name_from_mount`: `/` → `luks-root`, `/home` → `luks-home`).
2. **Mount the root btrfs partition FIRST**: mount the mapper to a temporary location, create its subvolume (`@`), unmount the temporary location, then mount with `subvol=@` at `${TARGET_DIR}`.
3. **Mount the remaining partitions shallowest-first** (a parent is always mounted before anything nested inside it). Each partition's mount point directory is created **right before its mount**, so a nested mount point (e.g. `/boot/efi`) lands on the already-mounted parent partition (e.g. `/boot`), not in the rootfs. Btrfs partitions use the temporary-mount → create subvolume → mount subvolume sequence (e.g. `/home` with `subvol=@home`); non-btrfs partitions are mounted directly.
4. **Unmount deepest-first** (nested mount points before their parents, then the root), then close the LUKS mappers. See `docs/partitioning.md` (Unmount Order).

## crypttab Configuration

LUKS partitions require a `/etc/crypttab` entry for initramfs decryption. The UUID must be sourced from the **raw block device** (not `/dev/mapper/`).

### Passphrase Only

```bash
echo "luks-root UUID=$(blkid -s UUID -o value /dev/sda2) none luks" > "${TARGET_DIR}/etc/crypttab"
```

### Keyfile Only

```bash
# Keyfile basename is used (e.g., luks.key)
echo "luks-root UUID=$(blkid -s UUID -o value /dev/sda2) /etc/cryptsetup-keys/luks.key luks" > "${TARGET_DIR}/etc/crypttab"
```

### Both Passphrase and Keyfile

```bash
# Same entry — cryptsetup tries keyfile first, falls back to passphrase
echo "luks-root UUID=$(blkid -s UUID -o value /dev/sda2) /etc/cryptsetup-keys/luks.key luks" > "${TARGET_DIR}/etc/crypttab"
```

When both are configured, the crypttab entry specifies the keyfile path. cryptsetup tries the keyfile first; if not found, it falls back to prompting for the passphrase (which is stored in LUKS slot 0). The `luks` option enables passphrase fallback automatically.

## fstab Configuration

The installer generates `/etc/fstab` using **UUIDs** for all partitions. For LUKS partitions, the UUID is read from the mapper device (which exposes the filesystem UUID of the decrypted content):

```
UUID=<luks-root-uuid>     /       btrfs  defaults,subvol=@   0 2
UUID=<boot-partition-uuid> /boot  ext4   defaults                      0 2
UUID=<luks-home-uuid>     /home   btrfs  defaults,subvol=@home        0 2
UUID=<efi-partition-uuid>  /boot/efi vfat defaults                    0 2
```

- **LUKS mapper names** are derived from the mount point via `_luks_name_from_mount` (`/` → `luks-root`, `/home` → `luks-home`), matching the names used in `crypttab`.
- **Btrfs subvolumes**: when a partition is defined with `--subvol`, the fstab entry includes `subvol=<name>` in its mount options. Without it, the default (top-level) subvolume would be mounted, which does not contain `@`/`@home`.

The `crypttab` entry handles the mapping from UUID to `/dev/mapper/luks-<name>`, so the fstab only needs the UUID.

## Chroot Preparation

Before entering chroot: ensure `/dev/mapper/luks-<name>` is mounted at the target mount point and mount required filesystems (`proc`, `sys`, `dev`, `devpts`, `efivarfs` for UEFI).

## Initramfs / dracut

LUKS decryption at boot requires proper initramfs configuration via dracut. The approach differs between LUKS and non-LUKS systems:

### LUKS Systems

The installer uses **Approach 1: unencrypted /boot**. GRUB reads the kernel and initramfs from the unencrypted boot partition. The initramfs handles LUKS decryption via the `cryptdevice` kernel parameter.

1. Write `hostonly=yes` to `${TARGET_DIR}/etc/dracut.conf.d/hostonly.conf` to ensure cryptsetup modules are included in the initramfs.
2. Build the LUKS kernel command line (`_build_luks_cmdline`: one `cryptdevice=UUID=<uuid>:luks-<name>` per LUKS partition, plus `root=/dev/mapper/luks-root` for a LUKS root, plus `rootflags=subvol=<subvol>` for a btrfs root with a subvolume).
3. Run `dracut --force --add crypt --add-drivers ahci --kernel-cmdline "<the cmdline>"` to rebuild the initramfs with LUKS support.

The `crypt` module (module `90crypt`) handles LUKS decryption and processes `/etc/crypttab`. In Void Linux's dracut, LUKS support is built into the `crypt` module — there is no separate `luks` module. The `--add-drivers ahci` ensures the AHCI disk driver is included for disk detection.

**Why `--kernel-cmdline` is required:** dracut's `parse-crypt` hook generates the LUKS
udev rules from the kernel command line (`rd.luks.uuid`, PARTUUID, SERIAL, or
`rd.auto`). Without `--kernel-cmdline`, the built initramfs has no `cryptdevice`/`root`/
`rootflags` parameters, so the LUKS root is never decrypted at boot. The same command
line is written to `GRUB_CMDLINE_LINUX` so GRUB passes it to the kernel.

### Non-LUKS Systems

Run `dracut --no-hostonly --force` to rebuild the initramfs from the cloned system without host-specific modules.

> **Important:** Do not mix `--no-hostonly` CLI flag with `hostonly=yes` in the config file. Use one approach or the other, not both.

## Boot Process (Approach 1: Unencrypted /boot)

The boot flow for LUKS-encrypted root with unencrypted /boot:

```
BIOS/UEFI
  ↓
GRUB (reads from unencrypted /boot or /boot/efi)
  ↓
vmlinuz + initramfs (read from unencrypted /boot)
  ↓
initramfs executes dracut → reads cryptdevice from kernel cmdline
  ↓
cryptsetup opens each LUKS partition → /dev/mapper/luks-root, /dev/mapper/luks-home, ...
  ↓
kernel mounts /dev/mapper/luks-root / (subvol from rootflags, when the root is a btrfs subvolume)
  ↓
runit's mount service runs `mount -a` → mounts remaining fstab entries (e.g. /home with subvol=@home)
```

### Kernel Command Line

The `cryptdevice` parameter tells the initramfs which partition to decrypt. One `cryptdevice=` parameter is generated **for every LUKS partition** — dracut's `parse-crypt` hook creates one udev rule per `rd.luks.uuid` value, so a LUKS partition without a `cryptdevice` parameter is never decrypted at boot and its fstab entry cannot mount:

```
cryptdevice=UUID=<luks-root-uuid>:luks-root cryptdevice=UUID=<luks-home-uuid>:luks-home
```

- `UUID=<luks-uuid>`: UUID of the raw LUKS partition (not the mapper)
- `luks-root` / `luks-home`: Name of the mapper device (`/dev/mapper/luks-root`, `/dev/mapper/luks-home`)

The installer automatically generates these parameters in `/etc/default/grub`:

```bash
GRUB_CMDLINE_LINUX="cryptdevice=UUID=xxxx-xxxx:luks-root cryptdevice=UUID=yyyy-yyyy:luks-home root=/dev/mapper/luks-root"
```

`root=/dev/mapper/luks-root` is only added when the root partition itself is LUKS.

When the root is a btrfs subvolume (defined with `--subvol`), `rootflags=subvol=<subvol>` is appended to the same line:

```bash
GRUB_CMDLINE_LINUX="cryptdevice=UUID=xxxx-xxxx:luks-root cryptdevice=UUID=yyyy-yyyy:luks-home root=/dev/mapper/luks-root rootflags=subvol=@"
```

Without `rootflags`, the kernel mounts the **top-level (default) subvolume**, which is empty — the rootfs lives in the named subvolume (`@`), so the system would boot into an empty root.

### GRUB Configuration

GRUB does **NOT** use cryptodisk. It reads the kernel and initramfs from the unencrypted boot partition.

The installer **preserves** all existing settings in `/etc/default/grub` and only updates what's needed:

- `GRUB_TERMINAL_OUTPUT` → set to `console` if not already present
- `GRUB_CMDLINE_LINUX` → **created** with one `cryptdevice=UUID=xxxx:luks-<name>` parameter per LUKS partition, plus `root=/dev/mapper/luks-root` when the root partition is LUKS, plus `rootflags=subvol=<subvol>` when the root is a btrfs subvolume. The `cryptdevice=` lines tell the initramfs which partitions to decrypt; `root=/dev/mapper/luks-root` tells the kernel which decrypted device is root (required for BIOS boot, and appended by grub-mkconfig for EFI too); `rootflags=subvol=@` tells the kernel which btrfs subvolume is root. (Void Linux default config has `GRUB_CMDLINE_LINUX_DEFAULT` but not `GRUB_CMDLINE_LINUX`, so we create `GRUB_CMDLINE_LINUX` with these parameters)

```bash
# /etc/default/grub (preserved settings + LUKS additions)
GRUB_TIMEOUT=5
GRUB_DEFAULT=0
GRUB_GFXMODE=auto
GRUB_DISABLE_OS_PROBER=false
GRUB_TERMINAL_OUTPUT=console
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4"
GRUB_CMDLINE_LINUX="cryptdevice=UUID=xxxx-xxxx:luks-root cryptdevice=UUID=yyyy-yyyy:luks-home root=/dev/mapper/luks-root"
```

The generated `grub.cfg` will look like:

```bash
menuentry 'Void GNU/Linux' {
    linux /boot/vmlinuz-6.12.11_1 root=/dev/mapper/luks-root ro cryptdevice=UUID=xxxx-xxxx:luks-root cryptdevice=UUID=yyyy-yyyy:luks-home loglevel=4
    initrd /boot/initramfs-6.12.11_1.img
}
```

### Why Unencrypted /boot?

| Approach | Pros | Cons |
|----------|------|------|
| **Unencrypted /boot** (current) | Simple, GRUB doesn't need cryptodisk modules, reliable | /boot is readable (no sensitive data) |
| GRUB cryptodisk | Everything encrypted | GRUB needs cryptodisk modules, more complex boot chain |

The unencrypted /boot approach is recommended because:
- GRUB only needs to read kernel/initramfs (no sensitive data)
- The actual encrypted root is protected by LUKS
- Simpler boot chain (no GRUB cryptodisk dependency)
- More reliable across different hardware

## Boot Partition Requirement

When LUKS is enabled, the installer **requires unencrypted partitions** so GRUB can read the kernel and initramfs. The exact requirements depend on the boot mode:

### UEFI + LUKS

Both partitions are **mandatory**:

| Partition | Purpose | Type |
|-----------|---------|------|
| `/boot/efi` | GRUB EFI binary (`grubx64.efi`) | vfat (ESP) |
| `/boot` | Kernel + initramfs (`vmlinuz`, `initramfs`) | ext4 (or any non-LUKS fs) |

### BIOS + LUKS

Only `/boot` is required:

| Partition | Purpose | Type |
|-----------|---------|------|
| `/boot` | Kernel + initramfs (`vmlinuz`, `initramfs`) | ext4 (or any non-LUKS fs) |

### Why Unencrypted /boot?

GRUB cannot read from an encrypted partition (without cryptodisk, which is not used). The boot flow:

1. **`/boot/efi`** (UEFI only) — UEFI firmware loads GRUB EFI binary from here
2. **`/boot`** — GRUB reads kernel and initramfs from here (unencrypted)
3. The initramfs handles LUKS decryption via the `cryptdevice` parameter

### Validation

The installer validates this in `validate_config()`. If LUKS is used without the required partitions, installation fails:

```
# Missing /boot (UEFI or BIOS)
ERROR: LUKS partitions detected but no unencrypted /boot partition found — LUKS root requires GRUB to read kernel/initramfs from an unencrypted partition. Add a partition with --mount "/boot" and --luks "no"

# Missing /boot/efi (UEFI only)
ERROR: LUKS + UEFI detected but no EFI System Partition found — add a vfat partition with --mount "/boot/efi" and --luks "no"
```

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

The derived name is computed per-consumer by `_luks_name_from_mount()` (a local `luks_name` variable in each function — there is no global `LUKS_NAME`) and is used in:
- Mapper device path: `/dev/mapper/luks-${luks_name}`
- crypttab entry name: `luks-${luks_name}`

The keyfile on target retains its **original basename** from the live ISO (e.g., `luks.key` → `/etc/cryptsetup-keys/luks.key`). It is NOT named after the LUKS partition.

Derivation rule: `/` → `root`, other mount points have leading `/` removed and remaining `/` replaced with `-`.

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
