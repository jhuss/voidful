# Known Limitations

This document lists features that the voidful installer does **not** currently support. These limitations are intentional and may be addressed in future versions.

## Unsupported Features

### Disk Layout

| Feature | Status | Notes |
|---------|--------|-------|
| **LVM** | ❌ Not supported | No Logical Volume Manager support. Use LUKS + LVM after installation if needed. |
| **RAID** | ❌ Not supported | No software RAID (mdadm) or hardware RAID configuration. |
| **Non-contiguous partitions** | ❌ Not supported | All partitions must be sequential on the target disk. |

### Installation Source

| Feature | Status | Notes |
|---------|--------|-------|
| **Network installation** | ❌ Not supported | The installer is offline-only. Uses the live ISO rootfs as the base system. |
| **Custom package repository** | ❌ Not supported | No packages are ever downloaded or installed — the installer only *removes* packages from the cloned live rootfs. No network access or custom repository sync is allowed. See `AGENTS.md` for Zero Internet Dependency constraint. |
| **Partial clone** | ❌ Not supported | The entire live system rootfs is cloned. Cannot selectively clone packages. |

### Encryption

| Feature | Status | Notes |
|---------|--------|-------|
| **LUKS passphrase** | ✅ Supported | All LUKS partitions share one passphrase. Per-partition passphrases are not supported. |
| **LUKS keyfile** | ✅ Supported | Keyfile mode is supported via `LUKS_KEYFILE`. |
| **Passphrase + keyfile** | ✅ Supported | Both can be set simultaneously for automated boot (keyfile) with interactive fallback (passphrase). |
| **LUKS + Btrfs** | ✅ Supported | See `docs/luks.md` for LUKS + Btrfs subvolume mount order. |
| **Multiple LUKS partitions** | ✅ Supported | Multiple encrypted partitions are supported with the same passphrase. |

### Bootloader

| Feature | Status | Notes |
|---------|--------|-------|
| **GRUB** | ✅ Supported | Both UEFI and BIOS modes. `grub-install --bootloader-id=void_grub --recheck`. |
| **systemd-boot** | ❌ Not supported | Only GRUB is supported as a bootloader. |
| **No bootloader** | ✅ Supported | Set `BOOTLOADER="none"` to skip bootloader installation (the grub packages are also removed during cleanup). |

### System Configuration

| Feature | Status | Notes |
|---------|--------|-------|
| **Wireless networks** | ⚠️ Partial | Static and DHCP wired networks are supported. Wireless requires manual configuration via `wpa_supplicant`. |
| **Multiple users** | ❌ Not supported | Only one regular user can be created (`CREATE_USER="yes"`). |
| **Custom runit services** | ✅ Supported | Via `ENABLED_SERVICES` comma-separated string (parsed into an array during service enabling). |
| **Locale generation** | ✅ Supported | Single locale via `LOCALE` variable. |
| **Install-time package list** | ❌ Not supported | No `INSTALL_PACKAGES` support (removed — it required network `xbps-install -Sy`). The offline clone installs only the live ISO's rootfs; add packages post-installation. |

## Hardware Limitations

| Limitation | Details |
|------------|---------|
| **Architecture** | x86_64 (tested). Other architectures (aarch64, riscv64) may work but are untested. |
| **Disk size** | Minimum 8GB recommended. No maximum limit (GPT supports > 2TB). |
| **CPU** | No minimum CPU requirements. Requires 64-bit x86_64. |
| **RAM** | Minimum 1GB (2GB recommended for desktop installs). Swap may be needed for less. |

## Workarounds

For unsupported features, consider post-installation configuration using standard Void Linux tools.

### GRUB device probing inside the live session (testing note)

When the installer runs **inside the minimal Void live ISO** (e.g. via `qemu_boot_test.sh` or a bare live boot),
`grub-install` / `grub-probe` may emit errors such as:

```
grub-probe: error: failed to get canonical path of `devtmpfs'.
```

This is **not** a bootloader failure and does not occur on real hardware. The minimal live initramfs does not fully
initialize the kernel block device (`/dev/vda`) before the post-clone GRUB step runs, so `grub-probe` cannot resolve the
drive geometry in `devtmpfs`. On real hardware — which has a complete `udev`/`systemd` stack — `/dev/vda` is fully
initialized by the time GRUB installs (installed to its MBR; see `_install_grub()`), so this warning never appears.

If you observe these messages during automated testing, they are an environment artifact of the minimal live session,
not a regression in bootloader installation.

### `btrfs subvolume list -s` is unreliable (btrfs-progs v6.11, testing note)

On the installed system's btrfs-progs (v6.11), `btrfs subvolume list -s /` returns **empty even when a default
subvolume is set** — it is not a valid verification of `btrfs subvolume set-default`. Verified on a QEMU install:
after `set-default 5` (top level) and `set-default 256` (subvolume `@`), a bare `mount /dev/mapper/<dev>` (no
`subvol=` option) correctly landed on the newly-defaulted subvolume in both cases, while `list -s` stayed empty.

To verify the default subvolume, use a behavioral check instead:

```bash
# Bare mount (no subvol= option) — shows the DEFAULT subvolume's contents
mkdir -p /tmp/btrfs_default_check
mount /dev/mapper/luks-root /tmp/btrfs_default_check
ls /tmp/btrfs_default_check   # rootfs contents (bin, etc, ...) = default is @; empty = top level
umount /tmp/btrfs_default_check
```

The installer itself does not depend on `list -s` — it checks `set-default`'s exit code (see
`docs/user_config.md`, step 18).


