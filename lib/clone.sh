#!/usr/bin/env bash
set -euo pipefail

# clone.sh — System clone operations for the voidful installer.
#
# Provides functions for:
#   - Cloning the live system rootfs to the target disk via tar
#   - Progress display during long operations
#
# Module dependencies: logging.sh
# Cleanup is handled by lib/cleanup.sh.

# ---------------------------------------------------------------------------
# Source dependencies
# ---------------------------------------------------------------------------
# shellcheck source=lib/logging.sh
source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

# Progress tracking
PROGRESS_PID=""

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# _progress_indicator()
#
# Displays periodic "still cloning..." messages during long operations.
# Runs in the background and is killed when cloning completes.
# ---------------------------------------------------------------------------
_progress_indicator() {
    local interval="${1:-30}"
    while true; do
        sleep "${interval}"
        log_info "still cloning..."
    done
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# clone_system()
#
# Clone the live system rootfs to the target disk via tar.
# Uses --one-file-system --xattrs --xattrs-include='*' for full system clone.
#
# Args: $1 = source rootfs (default: /)
#       $2 = target mount point (default: ${TARGET_DIR:-/mnt})
# ---------------------------------------------------------------------------
#
# _populate_boot_partition()
#
# Copy the kernel/initramfs from the source live system onto the target's
# /boot partition AFTER the clone.
#
# WHY THIS IS REQUIRED:
#   `copy_rootfs` uses `tar --one-file-system`, which stops at
#   filesystem/device-number boundaries. On an overlay-based live system the
#   /boot images (vmlinuz, initramfs) come from the read-only LOWER layer (a
#   separate block device), so tar treats them as a different file system and
#   drops them — leaving the target /boot empty. grub-mkconfig (run later in
#   chroot) needs vmlinuz present to reference it; dracut regenerates the
#   initramfs in place. This explicit copy is the only offline way to get a
#   bootable kernel onto the target (xbps-reconfigure cannot rebuild it).
#
# NOTE: this MUST run while ${target_dir}/boot is mounted, so the copy lands
# on the dedicated boot partition rather than the root filesystem.
#
# Args: $1 = source rootfs (default /),   $2 = target mount point (default ${TARGET_DIR})
# Returns: 0 on success, 1 if no boot partition or no kernel/initramfs found.
_populate_boot_partition() {
    local source_root="${1:-/}"
    local target_dir="${2:-${TARGET_DIR:-/mnt}}"
    local src_boot="${source_root}/boot"

    # The copy only lands on the boot partition if it is mounted. If /boot is
    # not present as a mount point, this MUST be a real error: silently
    # returning success here masked broken installs (empty boot partition).
    if [[ ! -d "${target_dir}/boot" ]]; then
        log_error "_populate_boot_partition: ${target_dir}/boot is not mounted — cannot populate the boot partition offline"
        return 1
    fi

    shopt -s nullglob
    local img count=0
    for img in "${src_boot}"/vmlinuz-* "${src_boot}"/initramfs-*.img; do
        cp -a "${img}" "${target_dir}/boot/" && count=$((count + 1))
    done
    shopt -u nullglob

    if [[ ${count} -eq 0 ]]; then
        log_warn "_populate_boot_partition: no kernel/initramfs at ${src_boot}, skipping"
        return 1
    fi
    log_success "Boot partition populated (${count} file(s))"
    return 0
}

clone_system() {
    local source_root="${1:-/}"
    local target_dir="${2:-${TARGET_DIR:-/mnt}}"

    log_info "Starting system clone: ${source_root} -> ${target_dir}"

    # Ensure target directory exists
    if [[ ! -d "${target_dir}" ]]; then
        log_error "clone_system: Target directory ${target_dir} does not exist"
        return 1
    fi

    # Start progress indicator
    _progress_indicator 30 &
    PROGRESS_PID=$!

    # Clone the system using tar pipeline, matching void-installer's
    # copy_rootfs() pattern:
    #   tar --create --one-file-system --xattrs -f - / |
    #       tar --extract --xattrs --xattrs-include='*' --preserve-permissions -f - -C $TARGETDIR
    #
    # Differences from the official approach:
    #   - Exclude ./var/log and ./etc/machine-id (live env noise)
    #   - We do NOT exclude ./var/db/xbps (official copies it fully,
    #     then cleans up unnecessary packages via xbps-remove in chroot)
    #   - --one-file-system automatically excludes proc, sys, dev
    #
    # --xattrs on the create side captures file capabilities
    # (security.capability) so they survive the clone. The installer runs
    # as root, which has CAP_SYS_ADMIN to restore them on extract.
    #
    # NOTE: --exclude MUST come before file arguments in GNU tar,
    # otherwise they are ignored.
    #
    # Exit status semantics (GNU tar):
    #   0 = all went well
    #   1 = file changed while being archived (TAREXIT_DIFFERS)
    #   2 = serious error
    # In the first minutes after boot, volatile mount points (/sys, /dev, ...)
    # are still changing (eudev, module loading), so the create side often
    # reports the harmless "file changed as we read it" warning (exit 1)
    # even though the archive is complete. The clone succeeds iff the
    # extract side finished without error and the create side did not
    # report a serious error (exit 2).
    local create_status=0
    local extract_status=0
    local create_err
    local extract_err
    create_err=$(mktemp)
    extract_err=$(mktemp)
    set +o pipefail
    if tar --create --one-file-system --xattrs -f - \
           --exclude=./var/log \
           --exclude=./etc/machine-id \
           "${source_root}" 2>"${create_err}" | \
        tar --extract --xattrs --xattrs-include='*' --preserve-permissions -f - \
            -C "${target_dir}" 2>"${extract_err}"; then
        read -r create_status extract_status <<< "${PIPESTATUS[@]}"
    else
        read -r create_status extract_status <<< "${PIPESTATUS[@]}"
    fi
    set -o pipefail
    if [[ ${extract_status} -eq 0 && ${create_status} -le 1 ]]; then
        if [[ ${create_status} -eq 1 ]]; then
            log_warn "tar create: 'file changed as we read it' (harmless: volatile mount points still settling after boot)"
        fi
        rm -f "${create_err}" "${extract_err}"
        log_success "System clone completed successfully"

        # The tar clone above cannot carry /boot on overlay live systems;
        # copy the kernel/initramfs onto the mounted boot partition now.
        if ! _populate_boot_partition "${source_root}" "${target_dir}"; then
            log_error "clone_system: boot partition missing kernel/initramfs"
            return 1
        fi
    else
        log_error "clone_system: System clone failed (create: ${create_status}, extract: ${extract_status})"
        if [[ -s "${create_err}" ]]; then
            log_error "tar create: $(cat "${create_err}")"
        fi
        if [[ -s "${extract_err}" ]]; then
            log_error "tar extract: $(cat "${extract_err}")"
        fi
        rm -f "${create_err}" "${extract_err}"
        kill "${PROGRESS_PID}" 2>/dev/null || true
        wait "${PROGRESS_PID}" 2>/dev/null || true
        return 1
    fi

    # Stop progress indicator
    kill "${PROGRESS_PID}" 2>/dev/null || true
    wait "${PROGRESS_PID}" 2>/dev/null || true
}
