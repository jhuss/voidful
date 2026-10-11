# Known Limitations

This document lists features that the voidful installer does **not** currently support. These limitations are intentional and may be addressed in future versions.

## Unsupported Features

### Disk Layout

| Feature | Status | Notes |
|---------|--------|-------|
| **LVM** | ❌ Not supported | No Logical Volume Manager support. Use LUKS + LVM after installation if needed. |
| **RAID** | ❌ Not supported | No software RAID (mdadm) or hardware RAID configuration. |
| **MBR** | ❌ Not supported | GPT is the only supported partition table format. See `docs/partitioning.md` for details. |
| **Non-contiguous partitions** | ❌ Not supported | All partitions must be sequential on the target disk. |

### Installation Source

| Feature | Status | Notes |
|---------|--------|-------|
| **Network installation** | ❌ Not supported | The installer is offline-only. Uses the live ISO rootfs as the base system. |
| **Custom package repository** | ❌ Not supported | The installer uses only the Live ISO's repodata. No network access or custom repository sync is allowed. See `AGENTS.md` for Zero Internet Dependency constraint. |
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
| **No bootloader** | ✅ Supported | Set `BOOTLOADER="none"` to skip bootloader installation. Exit code 6 (bootloader error) is not applicable in this case. |

### System Configuration

| Feature | Status | Notes |
|---------|--------|-------|
| **Wireless networks** | ⚠️ Partial | Static and DHCP wired networks are supported. Wireless requires manual configuration via `wpa_supplicant`. |
| **Multiple users** | ❌ Not supported | Only one regular user can be created (`CREATE_USER="yes"`). |
| **Custom runit services** | ✅ Supported | Via `ENABLED_SERVICES` comma-separated string (parsed into an array during service enabling). |
| **Locale generation** | ✅ Supported | Single locale via `LOCALE` variable. |

## Hardware Limitations

| Limitation | Details |
|------------|---------|
| **Architecture** | x86_64 (tested). Other architectures (aarch64, riscv64) may work but are untested. |
| **Disk size** | Minimum 8GB recommended. No maximum limit (GPT supports > 2TB). |
| **CPU** | No minimum CPU requirements. Requires 64-bit x86_64. |
| **RAM** | Minimum 1GB (2GB recommended for desktop installs). Swap may be needed for less. |

## Workarounds

For unsupported features, consider post-installation configuration using standard Void Linux tools.


