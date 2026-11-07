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
# Clone the entire live system (pipefail suspended around the pipeline;
# both statuses are checked via PIPESTATUS)
tar --create --one-file-system --xattrs -f - \
    --exclude=./var/log \
    --exclude=./etc/machine-id \
    / 2>create_err | \
tar --extract --xattrs --xattrs-include='*' --preserve-permissions -f - \
    -C "${TARGET_DIR}" 2>extract_err
```

**Key flags:**
- `--one-file-system`: Do not cross filesystem boundaries (excludes /proc, /sys, /dev, the live ISO's squashfs, etc.)
- `--xattrs`: Preserve extended attributes
- `--xattrs-include='*'`: Preserve all extended attributes
- `--exclude=./var/log` / `--exclude=./etc/machine-id`: Keep per-boot volatile state out of the clone
- `--preserve-permissions`: Preserve file permissions during extraction
- There is **no** `--no-overwrite-dir` — destination directories are overwritten so the target rootfs matches the source

**Progress Display:**

For clone operations that take 5-15 minutes, `_progress_indicator 30` (in `lib/clone.sh`) prints a periodic status line every 30 seconds in the background:

```bash
# Start background progress indicator (30s interval)
_progress_indicator 30 &
PROGRESS_PID=$!

# ... perform the clone (tar pipeline above) ...

# Clean up background progress indicator
kill "${PROGRESS_PID}" 2>/dev/null || true
wait "${PROGRESS_PID}" 2>/dev/null || true
```

See `docs/progress.md` for the complete sub-step progress pattern.

**Performance Notes:**
- The clone operation typically takes 5-15 minutes depending on disk speed and system size
- Use faster storage (SSD/NVMe) for better performance
- The `tar` command preserves all file attributes, permissions, and ownership

## Phase 3: Post-Clone Cleanup

### 3.1: Remove Live Environment Files

`remove_live_files()` (in `lib/cleanup.sh`) removes every item below from the target, each guarded by an existence check (and, where the target may contain more than one file, with `|| true`) and logged with `log_info`. Note the initramfs mount point is removed with `rm -rf` (guarded by a `-d` check), not `rmdir`:

```bash
# Remove live installer binary (not owned by any package on live ISO)
rm -f "${target_dir}/usr/bin/void-installer"

# Remove live sudoers override (grants NOPASSWD to live user)
rm -f "${target_dir}/etc/sudoers.d/99-void-live"

# Remove live ISO mount point (created during installation)
rm -rf "${target_dir}/run/initramfs"

# Reset SDDM config to defaults
rm -f "${target_dir}/etc/sddm.conf"

# Remove live polkit rules
rm -f "${target_dir}/etc/polkit-1/rules.d/void-live.rules"

# Remove live user auto-login from getty (if configured;
# uses ${LIVE_USERNAME}, default 'anon')
sed -i "s,GETTY_ARGS=\"--noclear -a ${live_user}\",GETTY_ARGS=\"--noclear\",g" "${target_dir}/etc/sv/agetty-tty1/conf"

# Remove SSH host keys and user .ssh directories
rm -f "${target_dir}/etc/ssh/ssh_host_"*
rm -rf "${target_dir}/root/.ssh" "${target_dir}/home/"*"/.ssh"
```

**Files removed:**
- `/usr/bin/void-installer` — The installer binary itself (not owned by any package on live ISO)
- `/etc/sudoers.d/99-void-live` — Live user sudoers override (owned by `sudo` package, safe to remove)
- `/run/initramfs` — Live ISO mount point
- `/etc/sddm.conf` — SDDM configuration (reset to defaults)
- `/etc/polkit-1/rules.d/void-live.rules` — Live polkit rules
- Getty auto-login for the live user (only when the config actually contains `-a <live_user>`)
- `/etc/ssh/ssh_host_*` — SSH host keys
- `/root/.ssh` and `/home/*/.ssh` — SSH keys from live user home directories

> **Note:** The following files are **NOT** removed by cleanup:
> - `/etc/motd` — Does not exist on live ISO
> - `/etc/issue` — not removed in cleanup; replaced with custom content during chroot configuration (see `docs/user_config.md`, step 7)
> - `/mnt/target` — Not created by voidful (created by void-installer only)

### 3.2: Remove Live User Account

Remove the live user account (default: `anon`) from the target system:

```bash
# Check if live user exists in the cloned system, then remove
if grep -q "^${live_user}:" "${target_dir}/etc/passwd" 2>/dev/null; then
    chroot "${target_dir}" userdel -r "${live_user}" 2>/dev/null || true
    log_info "Removed live user '${live_user}'"
else
    log_info "Live user '${live_user}' not found, skipping"
fi
```

**Note:** `LIVE_USERNAME` defaults to `anon` on the official Void Linux live ISO (set in `/etc/default/live.conf` as `USERNAME=anon`). The function greps `/etc/passwd` first, then runs `userdel -r` with `|| true` and logs the result with `log_info` (not `log_warn`) — the installer continues either way.

### 3.3: Remove Unnecessary Packages

Remove live system packages that are not needed on the target. The cleanup must NOT remove essential system packages.

#### Cleanup Exclusions

The following packages MUST NOT be removed during cleanup:
- `dracut` — Required for initramfs rebuild
- `grub`, `grub-x86_64-efi`, `grub-i386-efi` — Required for bootloader installation (unless `BOOTLOADER="none"`)
- `cryptsetup` — Required for LUKS support
- `runit` — Required for service management
- `bash` — Required for shell operations

Enforcement is via post-removal verification: after `xbps-remove`, `cleanup_packages()` re-queries the target's installed packages and emits `log_warn "Essential package removed: <pkg> — may need reinstall"` if a keep package is missing.



#### Packages to Remove

```bash
# Packages to always remove (live environment only)
local -a remove_packages=(dialog xtools-minimal xmirror void-live-audio)

# Conditionally remove espeakup: remove when NOT enabled in the cloned target
# (not used in the live environment); keep when enabled.
if [[ ! -e "${TARGET_DIR}/var/service/espeakup" ]]; then
    remove_packages+=(espeakup)
fi

# Conditionally remove brltty (same rule as espeakup)
if [[ ! -e "${TARGET_DIR}/var/service/brltty" ]]; then
    remove_packages+=(brltty)
fi

# In the current ISO, both packages are installed but not enabled in the
# clone, so the conditionals trigger and the packages are removed.

# Remove bootloader packages only if bootloader is disabled
if [[ "${BOOTLOADER}" == "none" ]]; then
    remove_packages+=(grub-x86_64-efi grub-i386-efi grub)
fi

# Packages to keep (essential system packages)
local -a keep_packages=(dracut cryptsetup runit bash)

# Conditionally add bootloader packages to keep list
if [[ "${BOOTLOADER}" == "grub" ]]; then
    keep_packages+=(grub grub-x86_64-efi grub-i386-efi)
fi

# Build list of packages to remove (only installed ones)
local -a to_remove=()
local installed_pkgs
installed_pkgs=$(chroot "${TARGET_DIR}" xbps-query -l 2>/dev/null | awk "{print \$2}" || true)
for pkg in "${remove_packages[@]}"; do
    if echo "${installed_pkgs}" | grep -q "^${pkg}-"; then
        to_remove+=("${pkg}")
        log_info "Will remove package: ${pkg}"
    else
        log_info "Package not installed: ${pkg}"
    fi
done

# Remove all unnecessary packages in a single call
# This avoids dependency ordering issues (e.g., xmirror depends on dialog)
if [[ ${#to_remove[@]} -gt 0 ]]; then
    chroot "${TARGET_DIR}" xbps-remove -y -R "${to_remove[@]}" 2>/dev/null || true
    log_info "Removed packages: ${to_remove[*]}"
fi

# Verify essential packages are still present (re-query AFTER removal;
# xbps-remove -R can remove orphaned dependencies)
local post_pkgs
post_pkgs=$(chroot "${TARGET_DIR}" xbps-query -l 2>/dev/null | awk "{print \$2}" || true)
for pkg in "${keep_packages[@]}"; do
    if ! echo "${post_pkgs}" | grep -q "^${pkg}-"; then
        log_warn "Essential package removed: ${pkg} — may need reinstall"
    fi
done
```

### xbps-remove Flags

| Flag | Meaning | Notes |
|------|---------|-------|
| `-R` | Recursive — remove specified packages AND their orphaned dependencies | Use carefully; may remove packages the user actually wants |
| `-y` | Assume yes — non-interactive mode | Required for unattended installation |



**Packages to remove:**
- `dialog` — UI tool for the live installer
- `xtools-minimal` — Live environment tools
- `xmirror` — Package mirror utility
- `void-live-audio` — Live-environment audio/speech script (its `alsa-utils` dep becomes orphaned and is removed via `-R`)
- `espeakup` — Screen reader (only if not running in live)
- `brltty` — Braille display driver (only if not running in live)
- `grub-x86_64-efi`, `grub-i386-efi`, `grub` — Bootloader packages (only if bootloader is disabled)



## Phase 4: Teardown

After all chroot configuration is complete (see `docs/user_config.md` and `docs/luks.md`), the installer performs teardown. The teardown steps are defined in `AGENTS.md` (Pipeline Step 6) and include:

- **Flush the installer log to the target**: `cp "${LOG_FILE}" "${TARGET_DIR}/var/log/voidful.log"`. The stage 4 clone only snapshotted the log at clone start, so without this step the log on the installed system ends at "Starting system clone" and the stage 5-6 lines (cleanup, chroot configuration, e.g. the btrfs default subvolume step) are lost when the live system reboots. Guarded by `findmnt` so the interruption path (target never mounted) does not write to a plain host directory.
- Swap off the swapfile (`swapoff "${TARGET_DIR}/swapfile"`, the name is hardcoded — there is no `SWAP_FILE` variable) when `SWAP_TYPE="file"` and the swapfile exists — this must happen **before** unmounting, otherwise the swapfile remains active on the mounted filesystem and its backing block device (a LUKS mapper) cannot be closed
- Unmount nested mount points **deepest-first**: read `/proc/mounts`, keep only the mount points under `${TARGET_DIR}` (i.e. `${TARGET_DIR}/...`), sort them reverse-lexicographically (a nested path is always lexicographically greater than its parent prefix, so children come before parents), then `umount` each; finally unmount `${TARGET_DIR}` itself. (Copy-overwritten files such as `resolv.conf` are **not** removed here — that is done by `_unmount_bind_filesystems()` at the end of the chroot stage.)
- Close LUKS mapper devices (if any)
- Sync filesystem buffers

See `AGENTS.md` for the complete teardown procedure.

## Security Considerations

1. **Live System Passwords**: The cloned system may contain passwords from the live environment. Ensure all passwords are reset during chroot configuration (see `docs/user_config.md`).

2. **User Accounts**: The live user account is removed during cleanup. Any additional live user accounts should be removed manually.

3. **SSH Keys**: `remove_live_files()` already removes `/etc/ssh/ssh_host_*` (host keys) and `/root/.ssh` / `/home/*/.ssh` during post-clone cleanup, so custom keys added during the live session do not carry over to the target.

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
