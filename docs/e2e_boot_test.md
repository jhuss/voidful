# End-to-End Boot Test

This document describes how to run end-to-end validation of the voidful installer, including QEMU automation and physical hardware testing.

## Overview

The end-to-end (E2E) boot test validates that the installed Void Linux system:

1. Boots correctly after installation
2. Has the correct hostname, locale, and keymap
3. Has a regular user account with sudo access
4. Has GRUB bootloader installed and functional
5. Has correct filesystem layout (Btrfs subvolumes, EFI partition, etc.)
6. Has correct `/etc/fstab` with UUID-based entries
7. Has the live user account removed
8. Has unnecessary packages removed and essential packages preserved
9. Has SSH host keys handled correctly

## Checklist Reference

All verification items are documented in ticket [#09](../.scratch/voidful-installer/issues/09-end-to-end-verification-boot-test.md).

## Test Scripts

### 1. Installed System Verification

**Script:** `tests/verify_installed_system.sh`

Run this script **inside the installed system** to check all configuration items.

```bash
# Run as root inside the installed system
ssh root@<installed-ip>
sudo bash /tests/verify_installed_system.sh
```

**What it checks:**

| Section | Checks |
|---------|--------|
| Hostname | `/etc/hostname` exists and is non-empty |
| Locale & Keymap | `/etc/locale.conf` and `/etc/vconsole.conf` exist with expected keys |
| User Account | Regular user(s) exist, wheel group has members, sudoers.d/wheel exists |
| Live User Removal | `anon` user removed, `/etc/sudoers.d/live` removed, `void-installer` binary removed |
| Package Cleanup | `dialog`, `xtools-minimal`, `xmirror` removed; `dracut`, `cryptsetup`, `runit`, `bash`, `grub` preserved |
| SSH Host Keys | No SSH host private keys present (or warned if found) |
| Filesystem Layout | `/etc/fstab` uses UUIDs, EFI partition mounted as vfat, Btrfs subvolumes checked |
| Bootloader | `/boot/grub` exists, `grub.cfg` present, UEFI boot entry present (if UEFI) |
| System Services | Runit services in `/var/service` listed |

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | All checks passed |
| `1` | One or more checks failed |
| `2` | Script requires root |

### 2. QEMU Boot Test

**Script:** `tests/qemu_boot_test.sh`

Automated end-to-end test using QEMU. Provisions a virtual disk, runs the installer inside the VM, then verifies the boot.

```bash
# Full automated test
sudo ./tests/qemu_boot_test.sh \
    --iso /path/to/void-live-x86_64-live.xz \
    --installer /path/to/voidful \
    --config /path/to/configs/example-btrfs.conf

# Keep the virtual disk for manual inspection
sudo ./tests/qemu_boot_test.sh \
    --iso /path/to/void-live-x86_64-live.xz \
    --installer /path/to/voidful \
    --config /path/to/configs/example-btrfs.conf \
    --keep-disk

# Verbose mode (captures QEMU output)
sudo ./tests/qemu_boot_test.sh \
    --iso /path/to/void-live-x86_64-live.xz \
    --installer /path/to/voidful \
    --config /path/to/configs/example-btrfs.conf \
    --verbose
```

**What it does:**

1. **Phase 1 — Installation:**
   - Creates a QEMU virtual disk (qcow2)
   - Creates a boot ISO containing the installer and configuration
   - Boots the Void Linux live ISO with the virtual disk and boot ISO
   - Runs the installer automatically (timeout: 30 minutes)

2. **Phase 2 — Boot Verification:**
   - Restarts the VM from the virtual disk (no live ISO)
   - Captures serial output for 5 minutes
   - Analyzes boot log for GRUB, kernel, runit, and login indicators
   - Reports findings

**Prerequisites:**

- `qemu-system-x86_64` (QEMU with KVM support)
- `/dev/kvm` (KVM device — falls back to TCG if unavailable)
- Root privileges (for KVM access)
- Void Linux live ISO
- Generator tool (`genisoimage` or `xorriso`)

**Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `--iso FILE` | Path to Void Linux live ISO | *(required)* |
| `--installer DIR` | Path to voidful installer source | *(required)* |
| `--config FILE` | Path to installer configuration | `example-btrfs.conf` |
| `--disk-size SIZE` | Virtual disk size | `10G` |
| `--memory MB` | VM memory in MB | `2048` |
| `--vcpus COUNT` | VM vCPUs | `2` |
| `--network TYPE` | Network mode: `user` or `bridge` | `user` |
| `--keep-disk` | Keep virtual disk after test | `false` |
| `--verbose` | Capture QEMU output | `false` |

## Manual Testing Workflow

When automation is not available, follow this manual workflow:

### Step 1: Prepare the Live ISO Environment

1. Boot the Void Linux live ISO on target hardware or QEMU
2. SSH into the live system (user: `anon`, password: per ISO defaults)
3. Copy the voidful installer to the live system:

```bash
# From the host
scp -r /path/to/voidful anon@<live-iso-ip>:/home/anon/

# Or use the live ISO's shared storage
```

### Step 2: Run the Installer

```bash
# On the live system
cd voidful
sudo bash install.sh \
    --target-disk /dev/sda \
    --config configs/example-btrfs.conf \
    --end-action reboot
```

### Step 3: Verify Boot

After the installer completes and the system reboots:

1. **At the GRUB menu:** Confirm GRUB menu appears (if configured with timeout)
2. **At the login prompt:** Verify the system reaches a login prompt
3. **SSH into the installed system:**

```bash
ssh user@<installed-ip>
sudo -i
```

### Step 4: Run Verification Script

```bash
# Copy the verification script to the installed system
scp tests/verify_installed_system.sh root@<installed-ip>:/root/

# Run it
ssh root@<installed-ip> bash /root/verify_installed_system.sh
```

### Step 5: Manual Spot Checks

```bash
# Check hostname
cat /etc/hostname

# Check locale
cat /etc/locale.conf
cat /etc/vconsole.conf

# Check users
grep -E "user|wheel" /etc/passwd
getent group wheel

# Check fstab
cat /etc/fstab

# Check mounted filesystems
mount | grep -E "efi|btrfs|subvol"

# Check packages
xbps-query -s "^dracut$|^cryptsetup$|^runit$|^bash$|^grub$"

# Check GRUB
ls -la /boot/grub/
ls -la /boot/efi/EFI/VoidLinux/  # UEFI only

# Check services
ls -la /var/service/
```

## Physical Hardware Testing

### Laptop/Desktop (x86_64)

1. Create a bootable USB with the voidful installer (or use the live ISO + installer)
2. Boot from USB on the target machine
3. Run the installer with `--target-disk` pointing to the internal drive
4. After reboot, verify the system boots from the internal drive

**Safety:** Always verify `--target-disk` before running. Double-check the device name:

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

### Raspberry Pi (aarch64)

1. Flash the Void Linux aarch64 live image to an SD card
2. Copy the voidful installer to the SD card
3. Boot the Pi from the SD card
4. Run the installer with `--target-disk /dev/mmcblk0`
5. After reboot, remove the SD card and boot from the internal storage

**Note:** GRUB on aarch64 requires UEFI firmware. Ensure the Pi is running a UEFI firmware build (e.g., `edk2`).

## Troubleshooting

### GRUB Menu Does Not Appear

- Check `GRUB_TIMEOUT` in `/etc/default/grub`
- Verify GRUB was installed correctly: `grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=VoidLinux`
- For UEFI: verify the EFI boot entry exists: `ls /boot/efi/EFI/VoidLinux/`

### System Does Not Boot (Black Screen)

- Check QEMU logs for kernel panic messages
- Verify the initramfs was built: `ls /boot/initramfs-*`
- For LUKS: verify dracut included LUKS support: `lsinitrd /boot/initramfs-* | grep luks`
- Check serial console output for errors

### Btrfs Subvolumes Not Mounted

- Verify `@`, `@home`, `@var` subvolumes exist: `btrfs subvolume list /`
- Check `/etc/fstab` has correct `subvol=@` mount options
- Verify the root subvolume is mounted: `findmnt -n -o SUBVOL /`

### Network Not Working After Boot

- Check if `dhcpcd` service is enabled: `ls /var/service/ | grep dhcpcd`
- Verify `dhcpcd.conf` has correct interface: `cat /etc/dhcpcd.conf`
- Check network device name: `ip link show`

### SSH Host Keys Missing

- Regenerate on first boot: `ssh-keygen -A`
- Or add to init script to run once at boot

## CI Integration

For CI/CD integration, run the QEMU boot test in a container or VM with KVM passthrough:

```yaml
# Example GitHub Actions snippet
- name: QEMU Boot Test
  run: |
    sudo ./tests/qemu_boot_test.sh \
      --iso ${{ secrets.LIVE_ISO_PATH }} \
      --installer ./ \
      --config configs/example-btrfs.conf \
      --keep-disk
  timeout-minutes: 35
```

## Related

- [Ticket #09](../.scratch/voidful-installer/issues/09-end-to-end-verification-boot-test.md) — Original specification
- [Live ISO Validation](./live_iso_validation.md) — Pre-implementation validation
- [Exit Codes](./exit_codes.md) — Standardized exit codes
- [End Actions](./end_actions.md) — Post-install behavior (`--end-action`)
