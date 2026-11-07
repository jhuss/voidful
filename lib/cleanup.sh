#!/usr/bin/env bash
set -euo pipefail

# cleanup.sh — Post-clone cleanup for the voidful installer.
#
# Provides functions for:
#   - Removing live environment files from the cloned system
#   - Deleting the live user account
#   - Removing unnecessary live system packages
#
# Module dependencies: logging.sh
# Caller responsibility: TARGET_DIR must be set before calling any function.

# ---------------------------------------------------------------------------
# Source dependencies
# ---------------------------------------------------------------------------
# shellcheck source=lib/logging.sh
source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# remove_live_files()
#
# Remove live environment files and directories from the cloned system.
# Removes: void-installer binary, live sudoers override, initramfs mount point,
#          SDDM config, live polkit rules, SSH host keys, getty auto-login.
#
# Args: $1 = target directory (default: ${TARGET_DIR:-/mnt})
# ---------------------------------------------------------------------------
remove_live_files() {
    local target_dir="${1:-${TARGET_DIR:-/mnt}}"

    log_info "Removing live environment files from ${target_dir}"

    # Remove void-installer binary
    if [[ -f "${target_dir}/usr/bin/void-installer" ]]; then
        rm -f "${target_dir}/usr/bin/void-installer"
        log_info "Removed void-installer binary"
    fi

    # Remove live sudoers override
    if [[ -f "${target_dir}/etc/sudoers.d/99-void-live" ]]; then
        rm -f "${target_dir}/etc/sudoers.d/99-void-live"
        log_info "Removed live sudoers override"
    fi

    # Remove initramfs mount point
    if [[ -d "${target_dir}/run/initramfs" ]]; then
        rm -rf "${target_dir}/run/initramfs" 2>/dev/null || true
        log_info "Removed initramfs mount point"
    fi

    # Remove SDDM config to defaults
    if [[ -f "${target_dir}/etc/sddm.conf" ]]; then
        rm -f "${target_dir}/etc/sddm.conf"
        log_info "Removed SDDM config"
    fi

    # Remove live polkit rules
    if [[ -f "${target_dir}/etc/polkit-1/rules.d/void-live.rules" ]]; then
        rm -f "${target_dir}/etc/polkit-1/rules.d/void-live.rules"
        log_info "Removed live polkit rules"
    fi

    # Remove getty auto-login for live user (if configured)
    local live_user="${LIVE_USERNAME:-anon}"
    local getty_conf="${target_dir}/etc/sv/agetty-tty1/conf"
    if [[ -f "${getty_conf}" ]] && grep -q "\-a ${live_user}" "${getty_conf}" 2>/dev/null; then
        sed -i "s,GETTY_ARGS=\"--noclear -a ${live_user}\",GETTY_ARGS=\"--noclear\",g" "${getty_conf}"
        log_info "Removed getty auto-login for '${live_user}'"
    fi

    # Remove SSH host keys
    if [[ -d "${target_dir}/etc/ssh" ]]; then
        rm -f "${target_dir}/etc/ssh/ssh_host_"* 2>/dev/null || true
        log_info "Removed SSH host keys"
    fi

    # Remove SSH keys from live user home directories
    rm -rf "${target_dir}/root/.ssh" 2>/dev/null || true
    rm -rf "${target_dir}/home/"*"/.ssh" 2>/dev/null || true
    log_info "Removed SSH keys from user home directories"
}

# remove_live_user()
#
# Delete the live user account from the cloned system.
# Default live user is 'anon'.
#
# Args: $1 = target directory (default: ${TARGET_DIR:-/mnt})
#       $2 = live username (default: anon)
# ---------------------------------------------------------------------------
remove_live_user() {
    local target_dir="${1:-${TARGET_DIR:-/mnt}}"
    local live_user="${2:-${LIVE_USERNAME:-anon}}"

    log_info "Removing live user '${live_user}' from ${target_dir}"

    # Check if live user exists in the cloned system
    if grep -q "^${live_user}:" "${target_dir}/etc/passwd" 2>/dev/null; then
        chroot "${target_dir}" userdel -r "${live_user}" 2>/dev/null || true
        log_info "Removed live user '${live_user}'"
    else
        log_info "Live user '${live_user}' not found, skipping"
    fi
}

# cleanup_packages()
#
# Remove unnecessary live system packages while preserving essential packages.
# Removes: dialog, xtools-minimal, xmirror, void-live-audio, and conditionally espeakup/brltty/grub.
# Keeps: dracut, cryptsetup, runit, bash, grub, xbps, base system.
#
# Args: $1 = target directory (default: ${TARGET_DIR:-/mnt})
#       $2 = bootloader name (default: ${BOOTLOADER:-grub})
# ---------------------------------------------------------------------------
cleanup_packages() {
    local target_dir="${1:-${TARGET_DIR:-/mnt}}"
    local bootloader="${2:-${BOOTLOADER:-grub}}"

    log_info "Cleaning up unnecessary packages from ${target_dir}"

    # Packages to always remove (live environment only)
    local -a remove_packages=(dialog xtools-minimal xmirror void-live-audio)

    # Conditionally remove espeakup: remove when NOT enabled in the cloned target
    # (not used in the live environment); keep when enabled.
    if [[ ! -e "${target_dir}/var/service/espeakup" ]]; then
        remove_packages+=(espeakup)
    fi

    # Conditionally remove brltty (same rule as espeakup)
    if [[ ! -e "${target_dir}/var/service/brltty" ]]; then
        remove_packages+=(brltty)
    fi

    # Remove bootloader packages only if bootloader is disabled
    if [[ "${bootloader}" == "none" ]]; then
        remove_packages+=(grub-x86_64-efi grub-i386-efi grub)
    fi

    # Packages to keep (essential system packages)
    local -a keep_packages=(dracut cryptsetup runit bash)

    # Conditionally add bootloader packages to keep list
    if [[ "${bootloader}" == "grub" ]]; then
        keep_packages+=(grub grub-x86_64-efi grub-i386-efi)
    fi

    # Build list of packages to remove (only installed ones)
    local -a to_remove=()
    local pkg
    local installed_pkgs
    # Get installed packages from the target system using chroot
    installed_pkgs=$(chroot "${target_dir}" xbps-query -l 2>/dev/null | awk "{print \$2}" || true)
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
        chroot "${target_dir}" xbps-remove -y -R "${to_remove[@]}" 2>/dev/null || true
        log_info "Removed packages: ${to_remove[*]}"
    else
        log_info "No unnecessary packages to remove"
    fi

    # Verify essential packages are still present (re-query AFTER removal;
    # xbps-remove -R can remove orphaned dependencies)
    local post_pkgs
    post_pkgs=$(chroot "${target_dir}" xbps-query -l 2>/dev/null | awk "{print \$2}" || true)
    for pkg in "${keep_packages[@]}"; do
        if ! echo "${post_pkgs}" | grep -q "^${pkg}-"; then
            log_warn "Essential package removed: ${pkg} — may need reinstall"
        fi
    done
}

# ---------------------------------------------------------------------------
# Usage note
# ---------------------------------------------------------------------------
#
# From install.sh, source this module and call the three functions directly:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/cleanup.sh"
#   remove_live_files "${TARGET_DIR}"
#   remove_live_user "${TARGET_DIR}"
#   cleanup_packages "${TARGET_DIR}" "${BOOTLOADER}"
#
