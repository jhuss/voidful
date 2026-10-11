# Clone Mode Implementation

This document details the system clone approach used by Voidful for offline-first installation. The clone method copies the entire live system rootfs to the target disk, then removes unnecessary packages.

For filesystem mounting, see `docs/partitioning.md`. For chroot configuration, user accounts, and bootloader, see `docs/user_config.md`. For LUKS, see `docs/luks.md`.

## Overview

Voidful uses a **system clone approach** similar to the `void-installer --source=local` option. This method:

1. Copies the entire live system rootfs (~837MB squashfs) to the target disk via `tar`
2. Removes unnecessary live system packages
3. Cleans up live environment files
4. Chroot configuration (hostname, locale, users, bootloader) — see `docs/user_config.md`

**Advantages:**
- Completely offline — no network or local package repository required
- Fast installation (file copy only)
- Fully functional system from the first boot
- All live system tools and packages are available (can be cleaned up later by the user)

**Disadvantages:**
- Larger initial system size (includes live system packages)
- Requires post-clone cleanup to remove unnecessary packages
- The cloned system includes installation tools that may not be needed on the target

## Clone Flow

The clone workflow consists of four sequential phases:

1. **Filesystem Mounting**: Create and mount target filesystems (see `docs/partitioning.md`)
2. **System Clone**: Copy the live rootfs via `tar` (handled by `lib/clone.sh`)
3. **Post-Clone Cleanup**: Remove live packages and files (handled by `lib/cleanup.sh`)
4. **Chroot Configuration**: Configure hostname, locale, users, bootloader (see `docs/user_config.md` and `docs/luks.md`). Initramfs rebuild is covered in `docs/user_config.md`.

### Module Responsibilities

| Module | Responsibility |
|--------|---------------|
| `lib/clone.sh` | System clone (`clone_system()`), progress display |
| `lib/cleanup.sh` | Live file removal (`remove_live_files()`), package removal (`cleanup_packages()`) |

---

## Phase 2: Clone the Live System

**⚠️ CRITICAL: Filesystem Mounting Prerequisite**

Before cloning, the target filesystem **must be correctly mounted**:

- **ext4**: Mount the root partition at `${TARGET_DIR}`
- **Btrfs with subvolumes**: Mount the root subvolume `@` at `${TARGET_DIR}` using `-o subvol=@` (see `docs/partitioning.md` for dynamic device resolution)
- **LUKS**: Mount `/dev/mapper/luks-<name>` at `${TARGET_DIR}`
- **UEFI**: Also mount EFI partition at `${TARGET_DIR}/boot/efi`

For Btrfs systems, the root subvolume `@` **must be mounted first** before cloning. Use the dynamic device resolution pattern from `docs/partitioning.md` to find the correct partition index.

**Why this matters:** The `tar --one-file-system` clone copies from the live rootfs (`/`) to the target mount point. If the root subvolume is not mounted correctly, the clone will fail or produce an unbootable system.

Use `tar` to copy the live system rootfs to the target disk:

```bash
# Clone the entire live system
tar --create \
    --one-file-system \
    --xattrs \
    --xattrs-include='*' \
    --directory=/ \
    -f - | \
tar --extract \
    --xattrs \
    --xattrs-include='*' \
    --directory="${TARGET_DIR}" \
    --no-overwrite-dir \
    --preserve-permissions
```

**Key flags:**
- `--one-file-system`: Do not cross filesystem boundaries (excludes /proc, /sys, /dev, etc.)
- `--xattrs`: Preserve extended attributes
- `--xattrs-include='*'`: Preserve all extended attributes
- `--no-overwrite-dir`: Preserve metadata of existing directories (safety for /boot/efi, etc.)
- `--preserve-permissions`: Preserve file permissions during extraction

**Progress Display:**

For clone operations that take 5-15 minutes, show periodic status updates:

```bash
# Decision D1: Use periodic status messages (sleep 30), not file counting
# File counting adds complexity for marginal accuracy gain

# Start background progress updater
(
    while true; do
        log_info "  [clone progress] Still cloning..."
        sleep 30
    done
) &
local clone_bg=$!

# Perform clone
tar --create \
    --one-file-system \
    --xattrs \
    --xattrs-include='*' \
    --directory=/ \
    -f - | \
tar --extract \
    --xattrs \
    --xattrs-include='*' \
    --directory="${TARGET_DIR}" \
    --no-overwrite-dir \
    --preserve-permissions

# Clean up background counter
kill ${clone_bg} 2>/dev/null || true
wait ${clone_bg} 2>/dev/null || true

log_info "System clone complete"
```

See `docs/progress.md` for the complete sub-step progress pattern.

**Performance Notes:**
- The clone operation typically takes 5-15 minutes depending on disk speed and system size
- Use faster storage (SSD/NVMe) for better performance
- The `tar` command preserves all file attributes, permissions, and ownership

## Phase 3: Post-Clone Cleanup

### 3.1: Remove Live Environment Files

Remove files and directories from the live environment that are not needed on the target:

```bash
# Remove live installer binary (not owned by any package on live ISO)
rm -f "${TARGET_DIR}/usr/bin/void-installer" 2>/dev/null || true

# Remove live sudoers override (grants NOPASSWD to live user)
rm -f "${TARGET_DIR}/etc/sudoers.d/99-void-live" 2>/dev/null || true

# Remove live ISO mount points (created during installation)
rmdir "${TARGET_DIR}/run/initramfs" 2>/dev/null || true
```

**Files removed:**
- `/usr/bin/void-installer` — The installer binary itself (not owned by any package on live ISO)
- `/etc/sudoers.d/99-void-live` — Live user sudoers override (owned by `sudo` package, safe to remove)
- `/run/initramfs` — Live ISO mount point

> **Note:** The following files are **NOT** removed because they do not exist on the live ISO or are part of essential packages:
> - `/etc/motd` — Does not exist on live ISO
> - `/etc/issue` — Owned by `base-files`, preserved on target
> - `/mnt/target` — Not created by voidful (created by void-installer only)

#### Additional Live System Cleanup

The official void-installer removes additional files that voidful may also want to clean:

```bash
# Reset SDDM config to defaults
rm -f "${TARGET_DIR}/etc/sddm.conf" 2>/dev/null || true

# Remove live polkit rules
rm -f "${TARGET_DIR}/etc/polkit-1/rules.d/void-live.rules" 2>/dev/null || true

# Remove live user auto-login from getty (if configured)
# Note: This pattern is ISO-version-dependent. On the current Void Linux
# live ISO, the getty config does not include auto-login.
# Use ${LIVE_USERNAME} (not ${USERNAME}) to reference the live ISO user.
sed -i "s,GETTY_ARGS=\"--noclear -a ${LIVE_USERNAME}\",GETTY_ARGS=\"--noclear\",g" "${TARGET_DIR}/etc/sv/agetty-tty1/conf" 2>/dev/null || true

# Remove SSH host keys
rm -f "${TARGET_DIR}/etc/ssh/ssh_host_*" 2>/dev/null || true
```

### 3.2: Remove Live User Account

Remove the live user account (default: `anon`) from the target system:

```bash
if ! chroot "${TARGET_DIR}" userdel -r "${LIVE_USERNAME}" 2>/dev/null; then
    log_warn "Live user '${LIVE_USERNAME}' not found (may have been removed already)"
fi
```

**Note:** `LIVE_USERNAME` defaults to `anon` on the official Void Linux live ISO (set in `/etc/default/live.conf` as `USERNAME=anon`). The `-r` flag removes the user's home directory and mail spool. Graceful error handling ensures the installer continues even if the user doesn't exist.

### 3.3: Remove Unnecessary Packages

Remove live system packages that are not needed on the target. The cleanup must NOT remove essential system packages.

#### Cleanup Exclusions

The following packages MUST NOT be removed during cleanup:
- `dracut` — Required for initramfs rebuild
- `grub`, `grub-x86_64-efi`, `grub-i386-efi` — Required for bootloader installation (unless `BOOTLOADER="none"`)
- `cryptsetup` — Required for LUKS support
- `runit` — Required for service management
- `bash` — Required for shell operations

```bash
declare -a KEEP_LIST=("dracut" "cryptsetup" "runit" "bash")

# Conditionally add bootloader packages to keep list
if [ "${BOOTLOADER}" = "grub" ]; then
    KEEP_LIST+=("grub" "grub-x86_64-efi" "grub-i386-efi")
fi

declare -a CLEAN_TO_REMOVE=()
for pkg in ${TO_REMOVE}; do
    local skip=false
    for keep in "${KEEP_LIST[@]}"; do
        [[ "${pkg}" == "${keep}" ]] && skip=true && break
    done
    ${skip} || CLEAN_TO_REMOVE+=("${pkg}")
done
TO_REMOVE="${CLEAN_TO_REMOVE[*]}"
```



#### Packages to Remove

```bash
# Packages to always remove
# Note: xmirror depends on dialog. Removing dialog with -R will
# also remove xmirror as an orphan. Removing xmirror first will
# leave dialog as an orphan (also removed with -R).
TO_REMOVE="dialog xtools-minimal xmirror"

# Conditionally remove based on live environment
# Note: The following conditional checks are ISO-version-dependent.
# On some Void Linux live ISO versions, these packages are installed
# but their services are not running. Consider using xbps-query to
# check for package installation instead:
#
# if xbps-query -s espeakup &>/dev/null; then
#     TO_REMOVE+=" espeakup"
# fi
#
# For the current ISO version, both packages are installed but
# /var/service/espeakup and /var/service/brltty do not exist,
# so these conditionals will not trigger. The packages will be
# removed unconditionally if listed in TO_REMOVE.
if [ -e "/var/service/espeakup" ]; then
    TO_REMOVE+=" espeakup"
fi

if [ -e "/var/service/brltty" ]; then
    TO_REMOVE+=" brltty"
fi

# Remove bootloader packages only if bootloader is disabled
if [ "${BOOTLOADER}" = "none" ]; then
    TO_REMOVE+=" grub-x86_64-efi grub-i386-efi grub"
fi

# Apply cleanup exclusions filter (see above)

# Remove packages using xbps-remove in the target
if [ -n "${TO_REMOVE}" ]; then
    log_info "Removing unnecessary packages: ${TO_REMOVE}"
    xbps-remove -r "${TARGET_DIR}" -Ry ${TO_REMOVE}
fi
```

### xbps-remove Flags

| Flag | Meaning | Notes |
|------|---------|-------|
| `-r DIR` | Root directory — operate on the target system's rootfs | Required for clone mode |
| `-R` | Recursive — remove specified packages AND their orphaned dependencies | Use carefully; may remove packages the user actually wants |
| `-y` | Assume yes — non-interactive mode | Required for unattended installation |



**Packages to remove:**
- `dialog` — UI tool for the live installer
- `xtools-minimal` — Live environment tools
- `xmirror` — Package mirror utility
- `espeakup` — Screen reader (only if not running in live)
- `brltty` — Braille display driver (only if not running in live)
- `grub-x86_64-efi`, `grub-i386-efi`, `grub` — Bootloader packages (only if bootloader is disabled)



## Phase 4: Teardown

After all chroot configuration is complete (see `docs/user_config.md` and `docs/luks.md`), the installer performs teardown. The teardown steps are defined in `AGENTS.md` (Pipeline Step 6) and include:

- Remove copied files (resolv.conf, etc.)
- Unmount `${TARGET_DIR}` recursively (`umount -R`)
- Close LUKS mapper devices (if any)
- Sync filesystem buffers

See `AGENTS.md` for the complete teardown procedure.

## Security Considerations

1. **Live System Passwords**: The cloned system may contain passwords from the live environment. Ensure all passwords are reset during chroot configuration (see `docs/user_config.md`).

2. **User Accounts**: The live user account is removed during cleanup. Any additional live user accounts should be removed manually.

3. **SSH Keys**: The live ISO does not ship with SSH keys, but if custom keys were added during live session, remove them:
   ```bash
   rm -rf "${TARGET_DIR}/root/.ssh" 2>/dev/null || true
   rm -rf "${TARGET_DIR}/home/*/.ssh" 2>/dev/null || true
   ```

4. **Network Configuration**: Clear any network configuration from the live environment (e.g., static IP addresses, Wi-Fi passwords). The chroot configuration will overwrite these with user-defined settings.

5. **Temporary Files**: Clean up temporary files and caches in the cloned system.

## Troubleshooting

### Clone Fails with "Filesystem Full"

- Verify the target disk has sufficient space (at least 10GB recommended)
- Check available space with `df -h "${TARGET_DIR}"`
- Consider removing more packages before cloning

### Boot Fails After Clone

- Verify initramfs was rebuilt with `dracut --force` (see `docs/luks.md`)
- Check that bootloader was installed correctly (see `docs/user_config.md`)
- Verify `/etc/fstab` uses UUIDs, not device paths (see `docs/partitioning.md`)
- Ensure LUKS partitions are configured correctly (if applicable, see `docs/luks.md`)

### Missing Drivers After Clone

- Add necessary drivers to the dracut command: `dracut --add-drivers "driver1 driver2" --force`
- Check `dmesg` for driver errors during boot
- Verify storage controller is supported by the kernel
