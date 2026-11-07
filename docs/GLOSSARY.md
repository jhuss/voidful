# Voidful Domain Glossary

Comprehensive domain terminology for the Voidful Void Linux installer project.

---

## 1. Installation Pipeline

### Pipeline
The sequential 7-stage workflow that performs a complete Void Linux installation. Each stage delegates to a dedicated module.

| Stage | Name | Module | Description |
|-------|------|--------|-------------|
| 1 | Pre-flight Check | `install.sh` + `lib/hardware.sh` | Detect boot mode, verify root, validate target disk |
| 2 | Configuration Loading | `install.sh` | Source config, execute `define_partition()`, run `validate_config()` |
| 3 | Partition & Format | `lib/partitioning.sh` | GPT (UEFI) / MBR-DOS (BIOS) table via `sfdisk`, format filesystems, setup LUKS, mount |
| 4 | System Clone | `lib/clone.sh` | Copy live rootfs via `tar --one-file-system` |
| 5a | Post-Clone Cleanup | `lib/cleanup.sh` | Remove live files, live user, unnecessary packages |
| 5b | Chroot Configuration | `lib/chroot_tasks.sh` | 20-step system configuration inside chroot |
| 6 | Teardown | `install.sh` | Unmount filesystems, close LUKS mappers, sync |
| 7 | End-Action | `install.sh` | Execute configured post-install action |

### Dry-Run Mode
A validation-only execution path (`--dry-run` flag) that loads and validates configuration without performing any disk operations.

### Test Mode
A safe preview execution path (`--test-mode` flag) that generates a complete operational plan without performing any operations. Prints: sfdisk layout, mount plan, tar command, chroot commands. Exits 0 on success, 1 on failure. NEVER touches the target disk.

### Pre-flight Check
The first pipeline stage that verifies: root privileges, boot mode (UEFI/BIOS), target disk availability, and disk is not the host machine.

---

## 2. Configuration Model

### Configuration File
A shell-sourceable file (`.conf`) that defines global settings, partition layouts, and optional system configuration. Located in `configs/`.

### Global Settings
Top-level configuration variables in a config file: `TARGET_DISK`, `TARGET_DIR`, `END_ACTION`, `BOOTLOADER`, `SWAP_TYPE`, `SWAP_SIZE`, `ENABLED_SERVICES`, `ISSUE_MESSAGE`, plus system settings (`HOSTNAME`, `LOCALE`, `KEYMAP`, `TIMEZONE`, `ROOT_PASS`, `CREATE_USER`, `USER_LOGIN`, `USER_PASS`, `USER_GROUPS`, `TEXTCONSOLE`) and optional network settings (`NETWORK_DEVICE`, `NETWORK_MODE`, `NETWORK_IP`, `NETWORK_GATEWAY`, `DNS_SERVERS`).

### Partition Definition
A call to `define_partition()` with named parameters (`--mount`, `--size`, `--fs`, `--luks`, `--subvol`) that declares a single partition in the installation layout.

### Partition Arrays
Parallel bash arrays that store partition data after `define_partition()` calls:
- `PART_MOUNTS` — Mount points (`/boot/efi`, `/`, `/home`)
- `PART_SIZES` — Partition sizes (`+100M`, `4G`, `""` for remaining)
- `PART_FS` — Filesystem types (`ext4`, `vfat`, `btrfs`)
- `PART_LUKS` — LUKS flag (`yes` / `no`)
- `PART_DEVICES` — Resolved device paths after partitioning (`/dev/sda1`, `/dev/sda2`)

### validate_config()
The validation function in `lib/config.sh` that orchestrates cross-validation of all configuration: disk validity, partition requirements, LUKS credentials, UEFI EFI partition, size constraints, `TIMEZONE` (zoneinfo file must exist), and user settings.

### Detected Variables
Variables auto-detected or derived by the installer, not set in config files:
- `BOOT_MODE` — `uefi` or `bios`, derived from `/sys/firmware/efi/systab`
- `LIVE_USERNAME` — Live ISO username (env var, default: `anon`)
- LUKS name — Derived from mount point by `_luks_name_from_mount()` (`/` → `root`, `/home` → `home`); computed per-consumer, no global variable
- `ARCH` — Architecture from `xbps-uhelper arch` (set in pre-flight, logged for information only)

### Override Priority
The resolution order for configuration values (highest first): (1) CLI arguments (applied after the config file is sourced) → (2) Config file → (3) Environment variables → (4) Hardcoded defaults. A fixed set of environment variables (`LUKS_PASSPHRASE`, `LUKS_KEYFILE`, `ROOT_PASS`, `USER_PASS`, `END_ACTION_SCRIPT`, `END_ACTION_FUNC`) are read only when the config file does not set them — the sourced config file wins over the environment, and CLI arguments win over both.

---

## 3. Hardware Detection

### Boot Mode
The firmware interface used by the system: `uefi` (checks that `/sys/firmware/efi/systab` exists — a file, not just the directory) or `bios`.

### Disk Type
The physical interface of a block device: `sata`, `nvme`, `mmc`, or `virtual`. Voidful does not query the device type — `get_partition_prefix()` derives the partition naming prefix from the device name alone.

### Partition Prefix
The naming convention for partition numbers on a disk:
- `sd` devices (SATA/SAS): `sda1`, `sda2` — no `p` prefix
- `nvme` devices: `nvme0n1p1`, `nvme0n1p2` — uses `p` prefix
- `mmc` devices: `mmcblk0p1`, `mmcblk0p2` — uses `p` prefix
- `vd` devices (virtual): `vda1`, `vda2` — no `p` prefix

### Device Normalization
The process of stripping the `/dev/` prefix from device paths for internal use (e.g., `/dev/sda` → `sda`).

### Architecture (`ARCH`)
The Void Linux architecture string (e.g., `x86_64-musl`, `x86_64-glibc`). Detected via `xbps-uhelper arch` during pre-flight and logged for information only — the offline system clone installs no packages from a repository, so it does not drive repository, locale, or bootloader package selection.

### Host Disk
The disk on which the installer itself is running. The installer does **not** check for it (`validate_disk()` only rejects the CD-ROM drive `sr0`); the user must verify the target device before running.

---

## 4. Partitioning & Filesystem

### Partition Table Format (GPT / MBR)
The partition table is derived from `BOOT_MODE`: **GPT** for UEFI (required by the UEFI spec; supports > 2TB disks and up to 128 partitions) and **MBR/DOS** for BIOS (limited to 2TB and 4 primary partitions; the first partition is marked `bootable` so `grub-probe` can locate it). See `docs/partitioning.md`.

### EFI System Partition (ESP)
A vfat partition (≥ 100MB) mounted at `/boot/efi`, required for UEFI systems. Has GPT type code `EF00`.

### Root Partition
The partition mounted at `/` — the system's root filesystem. At least one partition must mount at `/`.

### Remaining Space
A partition size specified as empty (`""`), meaning "use all remaining disk space". Only the LAST partition may have remaining space.

### Swap Type
How swap is configured on the target system: `partition` (dedicated swap partition), `file` (swap file on root filesystem), or `none` (no swap).

### Filesystem
The format of a partition: `ext4`, `vfat`, `btrfs`, `xfs`, or `f2fs`. Each has a corresponding `mkfs.*` command.

### Mount Order
The sequence in which partitions are mounted: root (`/`) first, then EFI (UEFI only), then other partitions in dependency order. Unmounted in reverse order.

### fstab
The `/etc/fstab` file generated during chroot configuration, using UUIDs (not device paths) for all entries.

### Btrfs Subvolume
A lightweight snapshot-capable subdivision within a Btrfs filesystem. Voidful uses `@` (root), `@home`, and `@var` naming convention.

### Btrfs Subvolume Workflow
Per-partition 4-step sequence in `_mount_btrfs_partition()`: (1) Mount the raw btrfs device (or LUKS mapper) to a temporary location → (2) Create the subvolume(s) if `PART_SUBVOLS` is set → (3) Unmount and remove the temporary location → (4) Mount the subvolume (`-o subvol=<name>`) at the partition's mount point. The root partition is mounted first (its `@` subvolume is the clone target); dependent subvolumes are mounted afterwards in dependency order.

---

## 5. LUKS Encryption

### LUKS (Linux Unified Key Setup)
Disk encryption using the LUKS2 format via `cryptsetup`. Supports passphrase, keyfile, or both methods.

### LUKS Passphrase
A plaintext string set via `LUKS_PASSPHRASE` environment variable. Stored in LUKS header slot 0. Used for interactive boot decryption.

### LUKS Keyfile
A file on the live ISO set via `LUKS_KEYFILE` environment variable. Added to the LUKS header: slot 0 when keyfile-only, slot 1 when combined with a passphrase (slot 0 = passphrase). Copied to the target's `/etc/cryptsetup-keys/` during installation (retains its original basename).

### LUKS Mapper Device
The decrypted block device created by `cryptsetup open`: `/dev/mapper/luks-<name>`. Used for formatting and mounting.

### LUKS Name
The identifier derived from a partition's mount point: `/` → `root`, `/home` → `home`, `/var/log` → `var-log`. Used in mapper device paths (`/dev/mapper/luks-<name>`) and crypttab entries. (Keyfiles are NOT named after the LUKS name — they retain their original basename from the live ISO.)

### crypttab
The `/etc/crypttab` file on the target system that maps LUKS names to device UUIDs and keyfile paths for initramfs decryption.

### cryptsetup Flow
The sequence of LUKS operations: (1) `luksFormat` → (2) `luksAddKey` (optional) → (3) `open` → (4) format mapper device → (5) mount mapper device.

### Initramfs (dracut)
The initial ram filesystem rebuilt by `dracut` to include LUKS decryption modules. Uses `hostonly=yes` for LUKS systems, `--no-hostonly` for non-LUKS.

---

## 6. System Clone

### System Clone
The core installation method: copying the entire live system rootfs (~837MB squashfs) to the target disk via `tar --one-file-system`, then cleaning up unnecessary packages.

### tar Clone Command
The specific `tar` pipeline used for cloning:
```bash
tar --create --one-file-system --xattrs -f - \
    --exclude=./var/log --exclude=./etc/machine-id "${source_root}" |
tar --extract --xattrs --xattrs-include='*' --preserve-permissions -f - -C "${TARGET_DIR}"
```

### Live Rootfs
The live ISO's operating system root filesystem, stored as a squashfs image (~837MB). This is the source for the clone operation.

### Clone Target (`TARGET_DIR`)
The mount point for the root partition where the cloned system is written. Default: `/mnt`.

### Post-Clone Cleanup
The removal of live system artifacts after cloning: live files, live user account, and unnecessary packages (`dialog`, `xtools-minimal`, `xmirror`, etc.).

### Keep List
Packages that must NOT be removed during cleanup: `dracut`, `cryptsetup`, `runit`, `bash`, and bootloader packages (if `BOOTLOADER="grub"`). Enforced via post-removal verification: after `xbps-remove`, the target's installed packages are re-queried and a warning is emitted if a keep package was removed. `espeakup`/`brltty` are removed only when NOT enabled in the cloned target.

---

## 7. Chroot Configuration

### Chroot
A root filesystem isolation technique. The installer enters the cloned target system via `chroot "${TARGET_DIR}"` to configure it.

### Chroot Preparation
The ordered steps performed **before** entering chroot:
1. Mount bind filesystems: `proc` (rbind, rw), `dev` (rbind, rw), `devpts`, `sys` (rbind, ro)
2. Mount `efivarfs` (UEFI only)
3. Copy XBPS signing keys (`/etc/xbps.d`)
4. Copy `/etc/resolv.conf` (removed during Teardown)

### Chroot Configuration Sequence
The 20 ordered steps executed **inside** chroot:
1. Fix root ownership
2. Copy `/etc/skel` files
3. Set hostname
4. Configure locale
5. Configure keymap
6. Configure timezone
7. Set issue file
8. Set root password
9. Create regular user
10. Set user password
11. Configure sudo
12. Configure network
13. Enable runit services
14. Copy LUKS keyfile
15. Configure crypttab
16. Rebuild initramfs (dracut)
17. Install GRUB + configure terminal (TEXTCONSOLE)
18. Create swap file (if `SWAP_TYPE="file"`)
19. Set btrfs default subvolume (btrfs root defined with `--subvol`)
20. Generate fstab

### Bind Mount
Mounting a host directory inside the chroot with `--rbind` to share the host's filesystem tree.

### XBPS Signing Keys
XBPS configuration copied from `/etc/xbps.d` to `${TARGET_DIR}/etc/xbps.d` before any package operation to allow package operations without signature errors.

---

## 8. Cleanup & Teardown

### Teardown
The pipeline stage (step 6) that reverses all mount operations: unmounts `${TARGET_DIR}` recursively, closes LUKS mapper devices, and syncs filesystem buffers.

### Unmount Order
Reverse of mount order: dependent subvolumes first, then root, then EFI. Performed via `umount -R "${TARGET_DIR}"`.

### Live User
The default user account on the Void Linux live ISO (`anon`). Removed during post-clone cleanup via `userdel -r`.

---

## 9. End-Actions

### End-Action
The configurable post-install behavior after teardown completes. Set via `END_ACTION` variable.

### End-Action Modes
| Mode | Description | Context |
|------|-------------|---------|
| `shutdown` | Run `poweroff` | Default |
| `reboot` | Run `reboot` | — |
| `script` | Execute a user script file (`END_ACTION_SCRIPT`) | Subprocess |
| `func` | Call a user-defined bash function (`END_ACTION_FUNC`) | Same shell |
| `none` | Do nothing — leave the system running (no action) | — |

### END_ACTION_SCRIPT / END_ACTION_FUNC
Environment variables specifying the script path or function name for `script`/`func` end-action modes.

---

## 10. Error Handling & Signals

### Exit Code
A numeric code indicating the outcome of the installer. Standardized codes: `0`, `1`, `2`, `3`, `8`, `9` (see `docs/exit_codes.md`).

### Signal Handler
A `trap`-based cleanup routine that runs on `INT`, `TERM`, `HUP`, or `PIPE` signals. Performs unmounting and exits with code 8.

### Two-Trap Pattern
The signal handling strategy using:
- `EXIT` trap: Always runs, preserves existing exit code, performs cleanup
- Signal traps (`INT`/`TERM`/`HUP`/`PIPE`): Run cleanup then exit with code 8

### PIPE Signal
A signal added to the trap to handle broken pipe scenarios (e.g., `tar | tar` during clone). Prevents pipeline interruptions from bypassing cleanup.

---

## 11. Logging & Progress

### Log Level
The minimum severity for terminal output: `error` (0), `warn` (1), `info` (2, default), `debug` (3). Log file always receives all levels.

### Log Functions
| Function | Prefix | Output |
|----------|--------|--------|
| `log_info` | `[INFO]` | stdout (cyan on TTY) |
| `log_warn` | `[WARN]` | stderr (yellow on TTY) |
| `log_error` | `[ERROR]` | stderr (red on TTY) |
| `log_success` | `[OK]` | stdout (green on TTY) |

### Step Progress
Major installation stages announced via `log_info "Stage N: …"` (e.g. `Stage 3: Partition & Format`), one per pipeline stage (stages 1–8).

### Sub-step Progress
Periodic status messages during long-running operations (e.g., "Still cloning..."). Indented with 2 spaces, shown every 30 seconds via a background process.

---

## 12. Void Linux Specifics

### runit
The init system used by Void Linux. Services are enabled via `ln -s /etc/sv/<service> /var/service/<service>` and disabled via `rm /var/service/<service>`. Service names follow `^[a-z_][a-z0-9_-]*$` naming convention.

### xbps
The Void Linux package manager. Used for:
- `xbps-install`: Install packages
- `xbps-remove -Ry`: Remove packages with orphan cleanup
- `xbps-query`: Query installed packages
- `xbps-reconfigure`: Reconfigure installed packages
- `xbps-uhelper arch`: Query architecture

### musl vs glibc
Void Linux supports two C library variants. Detected via `xbps-uhelper arch` (stored in `ARCH`, logged during pre-flight). In voidful the value is informational only — the system clone is offline and installs no packages, so no package selection is performed. In general Void the variant affects:
- Repository selection (`x86_64-musl` vs `x86_64-glibc`)
- Locale package (`glibc-locales-musl` vs `glibc-locales`)
- Other package naming conventions

---

## 13. Security Concepts

### Host Safety
The principle that destructive operations (partitioning, formatting, wiping) must never target the host machine running the installer.

### Credential Isolation
LUKS credentials (`LUKS_PASSPHRASE`, `LUKS_KEYFILE`) must never be committed to version control. They are exported as environment variables.

### Keyfile Permissions
Keyfiles on the target system are stored at `/etc/cryptsetup-keys/<basename>` (the keyfile's original basename from the live ISO) with permissions `0400` and owner `root:root`.
