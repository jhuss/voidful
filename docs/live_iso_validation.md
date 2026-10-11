# Live ISO Validation

This document describes the recommended validation workflow for ensuring correctness against the official Void Linux live ISO environment. Use these commands to verify tool availability and filesystem layout described in `AGENTS.md` (Available Tooling) and `docs/hardware.md` (Disk Discovery).

## Why This Matters

The installer operates by cloning the live system rootfs to the target disk. All tools, package flags, and filesystem behaviors must match what is actually available in the live ISO. Validating against the live ISO prevents assumptions about tool availability, flag support, and system layout.

## Validation Environment

- **SSH**: Connect to the Void Linux live ISO instance
- **User**: `anon` (NOPASSWD sudo via `/etc/sudoers.d/99-void-live`)
- **Root filesystem**: overlayfs (lowerdir=/run/rootfsbase, upperdir=/run/overlayfs)
- **ISO mount**: `/run/initramfs/live` (iso9660 from /dev/sr0)

## Example Validation Commands

Verify tool availability and flags before implementing features:

```bash
# Check tool existence
which <tool>

# Check command flags
<tool> --help | grep -i "<flag>"

# Verify filesystem layout
findmnt -no SOURCE /
df -h | grep -E "overlay|tmpfs|iso9660"

# Verify package manager
xbps-query -l | wc -l
xbps-query -Rs <package>

# Verify encryption tools
cryptsetup --help | grep -E "batch-mode|key-file|key-slot"

# Verify bootloader
grub-install --help | grep -i "efi"

# Verify chroot
xchroot --help

# Verify archive tools
tar --help | grep -E "one-file-system|xattrs"

# Verify disk tools
sfdisk --help | grep -i "wipefs"
blkid -s UUID -o value /dev/sda 2>/dev/null
```

## Revalidation

Revalidate when:
- A new feature depends on a tool or flag not yet verified
- The official Void Linux ISO version changes
- An implementation fails in an unexpected way during testing
