#!/usr/bin/env bash
set -euo pipefail

# verify_installed_system.sh — Verify an installed Void Linux system has correct
# configuration after a voidful installer run.
#
# Run this script INSIDE the installed system (via SSH, serial console, or
# directly after boot) to validate all checklist items from ticket #09.
#
# Exit codes:
#   0 — All checks passed
#   1 — One or more checks failed
#   2 — Script requires root

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/../lib/logging.sh"
# Use /dev/null as log file — verification runs inside the installed system,
# not during a live installation context
LOG_FILE="/dev/null"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TOTAL=0
PASSED=0
FAILED=0
WARNINGS=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _check <description> <command>
#
# Run a command and record pass/fail.
# ---------------------------------------------------------------------------
_check() {
    local desc="${1}"
    shift
    ((TOTAL++)) || true

    if "$@" &>/dev/null; then
        log_success "${desc}"
        ((PASSED++)) || true
    else
        log_error "${desc}"
        ((FAILED++)) || true
    fi
}

# _check_contains <description> <expected_substring> <command...>
#
# Run a command, check that output contains a substring.
# ---------------------------------------------------------------------------
_check_contains() {
    local desc="${1}"
    local expected="${2}"
    shift 2
    ((TOTAL++)) || true

    local actual
    actual=$("$@" 2>/dev/null) || actual=""

    if [[ "${actual}" == *"${expected}"* ]]; then
        log_success "${desc}"
        ((PASSED++)) || true
    else
        log_error "${desc}"
        log_info "         Expected substring: '${expected}'"
        log_info "         Actual:             '${actual}'"
        ((FAILED++)) || true
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    # Require root
    if [[ $(id -u) -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 2
    fi

    echo "============================================="
    echo " Voidful Installed System Verification"
    echo "============================================="
    echo ""

    # -----------------------------------------------------------------------
    # Section 1: Hostname
    # -----------------------------------------------------------------------
    echo "--- Hostname ---"

    if [[ -f /etc/hostname ]]; then
        local hostname_val
        hostname_val=$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')
        if [[ -n "${hostname_val}" ]]; then
            echo "  [PASS] /etc/hostname exists (value: ${hostname_val})"
            ((PASSED++)) || true
        else
            echo "  [FAIL] /etc/hostname is empty"
            ((FAILED++)) || true
        fi
        ((TOTAL++)) || true
    else
        echo "  [FAIL] /etc/hostname does not exist"
        ((FAILED++)) || true
        ((TOTAL++)) || true
    fi

    echo ""

    # -----------------------------------------------------------------------
    # Section 2: Locale and Keymap
    # -----------------------------------------------------------------------
    echo "--- Locale and Keymap ---"

    if [[ -f /etc/locale.conf ]]; then
        _check_contains "locale.conf exists" "LANG=" cat /etc/locale.conf
    else
        echo "  [FAIL] /etc/locale.conf does not exist"
        ((FAILED++)) || true
        ((TOTAL++)) || true
    fi

    if [[ -f /etc/vconsole.conf ]]; then
        _check_contains "vconsole.conf exists" "KEYMAP=" cat /etc/vconsole.conf
    else
        echo "  [FAIL] /etc/vconsole.conf does not exist"
        ((FAILED++)) || true
        ((TOTAL++)) || true
    fi

    echo ""

    # -----------------------------------------------------------------------
    # Section 2b: Timezone
    # -----------------------------------------------------------------------
    echo "--- Timezone ---"
    local tz_target=""
    if [[ -e /etc/localtime ]]; then
        tz_target=$(readlink /etc/localtime 2>/dev/null)
        [[ -z "${tz_target}" ]] && tz_target="(not a symlink)"
        if [[ -n "${TIMEZONE_EXPECTED:-}" ]]; then
            if [[ "${tz_target}" == *"${TIMEZONE_EXPECTED}" ]]; then
                echo "  [PASS] /etc/localtime -> ${tz_target} (matches expected ${TIMEZONE_EXPECTED})"
                ((PASSED++)) || true
            else
                echo "  [FAIL] /etc/localtime -> ${tz_target} (expected a target ending in ${TIMEZONE_EXPECTED})"
                ((FAILED++)) || true
            fi
        else
            echo "  [PASS] /etc/localtime exists (target: ${tz_target})"
            ((PASSED++)) || true
        fi
        ((TOTAL++)) || true
    else
        echo "  [FAIL] /etc/localtime does not exist"
        ((FAILED++)) || true
        ((TOTAL++)) || true
    fi

    echo ""

    # -----------------------------------------------------------------------
    # Section 3: User Account
    # -----------------------------------------------------------------------
    echo "--- Regular User Account ---"

    # Check that a non-root, non-system user exists
    local user_count
    user_count=$(awk -F: '$3 >= 1000 && $1 != "nobody" && $1 != "daemon" { count++ } END { print count+0 }' /etc/passwd)

    if [[ "${user_count}" -gt 0 ]]; then
        echo "  [PASS] ${user_count} regular user(s) found"
        # List the users
        awk -F: '$3 >= 1000 && $1 != "nobody" && $1 != "daemon" { print "       - " $1 " (UID " $3 ")" }' /etc/passwd
        ((PASSED++)) || true
    else
        echo "  [FAIL] No regular user accounts found"
        ((FAILED++)) || true
    fi
    ((TOTAL++)) || true

    # Check wheel group for sudo access
    if getent group wheel &>/dev/null; then
        local wheel_members
        wheel_members=$(getent group wheel 2>/dev/null | cut -d: -f4)
        if [[ -n "${wheel_members}" ]]; then
            echo "  [PASS] wheel group exists with members: ${wheel_members}"
            ((PASSED++)) || true
        else
            echo "  [WARN] wheel group exists but has no members"
            ((WARNINGS++)) || true
        fi
        ((TOTAL++)) || true
    else
        echo "  [FAIL] wheel group does not exist"
        ((FAILED++)) || true
        ((TOTAL++)) || true
    fi

    # Check sudoers.d/wheel
    if [[ -f /etc/sudoers.d/wheel ]]; then
        _check "sudoers.d/wheel exists" test -f /etc/sudoers.d/wheel
    else
        echo "  [FAIL] /etc/sudoers.d/wheel does not exist"
        ((FAILED++)) || true
        ((TOTAL++)) || true
    fi

    # Check user home directory
    local home_users
    home_users=$(awk -F: '$3 >= 1000 { print $6 }' /etc/passwd 2>/dev/null)
    if [[ -n "${home_users}" ]]; then
        while IFS= read -r home_dir; do
            if [[ -d "${home_dir}" ]]; then
                echo "  [PASS] Home directory exists: ${home_dir}"
                ((PASSED++)) || true
            else
                echo "  [FAIL] Home directory missing: ${home_dir}"
                ((FAILED++)) || true
            fi
            ((TOTAL++)) || true
        done <<< "${home_users}"
    fi

    echo ""

    # -----------------------------------------------------------------------
    # Section 4: Live User Removal
    # -----------------------------------------------------------------------
    echo "--- Live User Removal ---"

    if grep -q "^anon:" /etc/passwd 2>/dev/null; then
        echo "  [FAIL] Live user 'anon' still exists in /etc/passwd"
        ((FAILED++)) || true
    else
        echo "  [PASS] Live user 'anon' has been removed"
        ((PASSED++)) || true
    fi
    ((TOTAL++)) || true

    if [[ -f /etc/sudoers.d/live ]]; then
        echo "  [FAIL] Live sudoers override still exists: /etc/sudoers.d/live"
        ((FAILED++)) || true
    else
        echo "  [PASS] Live sudoers override removed"
        ((PASSED++)) || true
    fi
    ((TOTAL++)) || true

    if [[ -f /usr/bin/void-installer ]]; then
        echo "  [FAIL] void-installer binary still present"
        ((FAILED++)) || true
    else
        echo "  [PASS] void-installer binary removed"
        ((PASSED++)) || true
    fi
    ((TOTAL++)) || true

    echo ""

    # -----------------------------------------------------------------------
    # Section 5: Package Cleanup
    # -----------------------------------------------------------------------
    echo "--- Package Cleanup ---"

    # Check that unnecessary packages are removed (installed DB, not repo metadata)
    for pkg in dialog xtools-minimal xmirror; do
        if xbps-query -l 2>/dev/null | awk '{print $2}' | grep -q "^${pkg}-"; then
            echo "  [FAIL] Unnecessary package still installed: ${pkg}"
            ((FAILED++)) || true
        else
            echo "  [PASS] Unnecessary package removed: ${pkg}"
            ((PASSED++)) || true
        fi
        ((TOTAL++)) || true
    done

    # Check that essential packages are preserved
    for pkg in dracut cryptsetup runit bash grub; do
        if xbps-query -s "^${pkg}$" &>/dev/null; then
            echo "  [PASS] Essential package preserved: ${pkg}"
            ((PASSED++)) || true
        else
            echo "  [FAIL] Essential package missing: ${pkg}"
            ((FAILED++)) || true
        fi
        ((TOTAL++)) || true
    done

    echo ""

    # -----------------------------------------------------------------------
    # Section 6: SSH Host Keys
    # -----------------------------------------------------------------------
    echo "--- SSH Host Keys ---"

    # SSH host keys should be regenerated on first boot or removed
    if [[ -d /etc/ssh ]]; then
        local ssh_keys
        ssh_keys=$(find /etc/ssh -maxdepth 1 -name 'ssh_host_*_key' -type f 2>/dev/null | wc -l)
        if [[ "${ssh_keys}" -eq 0 ]]; then
            echo "  [PASS] No SSH host private keys present (will be regenerated on first boot)"
            ((PASSED++)) || true
        else
            echo "  [WARN] ${ssh_keys} SSH host key(s) found — should be regenerated on first boot"
            ((WARNINGS++)) || true
        fi
        ((TOTAL++)) || true
    else
        echo "  [PASS] /etc/ssh not present (SSH not installed)"
        ((PASSED++)) || true
        ((TOTAL++)) || true
    fi

    echo ""

    # -----------------------------------------------------------------------
    # Section 7: Filesystem Layout (Btrfs subvolumes)
    # -----------------------------------------------------------------------
    echo "--- Filesystem Layout ---"

    # Check /etc/fstab
    if [[ -f /etc/fstab ]]; then
        echo "  [PASS] /etc/fstab exists"
        ((PASSED++)) || true
        ((TOTAL++)) || true

        # Check that fstab uses UUIDs
        if grep -q "^UUID=" /etc/fstab; then
            echo "  [PASS] /etc/fstab uses UUID-based entries"
            ((PASSED++)) || true
        else
            echo "  [FAIL] /etc/fstab does not use UUID-based entries"
            ((FAILED++)) || true
        fi
        ((TOTAL++)) || true

        # Show fstab contents
        echo "  --- /etc/fstab contents ---"
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" == \#* ]] && continue
            echo "       ${line}"
        done < /etc/fstab
        echo ""

        # Check for common mount points
        for mount_pt in / /home /var; do
            if grep -qE "^[^#].*${mount_pt} " /etc/fstab; then
                echo "  [PASS] Mount point ${mount_pt} found in fstab"
                ((PASSED++)) || true
            else
                echo "  [INFO] Mount point ${mount_pt} not in fstab (may use default)"
            fi
            ((TOTAL++)) || true
        done
    else
        echo "  [FAIL] /etc/fstab does not exist"
        ((FAILED++)) || true
        ((TOTAL++)) || true
    fi

    # Check EFI partition
    if mountpoint -q /boot/efi 2>/dev/null; then
        echo "  [PASS] EFI partition mounted at /boot/efi"
        ((PASSED++)) || true
        local efi_fs
        efi_fs=$(findmnt -n -o FSTYPE /boot/efi 2>/dev/null)
        if [[ "${efi_fs}" == "vfat" ]]; then
            echo "  [PASS] EFI partition is vfat"
            ((PASSED++)) || true
        else
            echo "  [FAIL] EFI partition is ${efi_fs}, expected vfat"
            ((FAILED++)) || true
        fi
        ((TOTAL++)) || true
    elif mountpoint -q /boot/efi 2>/dev/null; then
        echo "  [PASS] /boot/efi is a mount point"
        ((PASSED++)) || true
        ((TOTAL++)) || true
    else
        # Not UEFI — EFI partition not expected
        if [[ ! -d /sys/firmware/efi ]]; then
            echo "  [INFO] BIOS mode — no EFI partition expected"
        else
            echo "  [WARN] UEFI detected but /boot/efi not mounted"
        fi
        ((TOTAL++)) || true
    fi

    # Check Btrfs subvolumes (if btrfs is in use)
    if xbps-query -s "^btrfs-progs$" &>/dev/null; then
        local root_fs
        root_fs=$(findmnt -n -o FSTYPE / 2>/dev/null) || root_fs=""
        if [[ "${root_fs}" == "btrfs" ]]; then
            echo "  [INFO] Root filesystem is btrfs — checking subvolumes..."
            local subvols
            subvols=$(btrfs subvolume list / 2>/dev/null | awk '{print $5}' | sort)
            if [[ -n "${subvols}" ]]; then
                echo "  [PASS] Btrfs subvolumes detected:"
                while IFS= read -r sv; do
                    echo "       - ${sv}"
                done <<< "${subvols}"
                ((PASSED++)) || true
            else
                echo "  [WARN] No btrfs subvolumes found on root"
                ((WARNINGS++)) || true
            fi
            ((TOTAL++)) || true

            # Check that @ subvolume is mounted as root
            if findmnt -n -o SUBVOL / 2>/dev/null | grep -q "@"; then
                echo "  [PASS] Root mounted on @ subvolume"
                ((PASSED++)) || true
            else
                echo "  [INFO] Root may not be on a named subvolume (default subvol)"
            fi
            ((TOTAL++)) || true
        else
            echo "  [INFO] Root filesystem is ${root_fs} (not btrfs)"
            ((TOTAL++)) || true
        fi
    else
        echo "  [INFO] btrfs-progs not installed — skipping subvolume checks"
        ((TOTAL++)) || true
    fi

    echo ""

    # -----------------------------------------------------------------------
    # Section 8: Bootloader
    # -----------------------------------------------------------------------
    echo "--- Bootloader ---"

    if [[ -d /boot/grub ]]; then
        echo "  [PASS] GRUB directory exists: /boot/grub"
        ((PASSED++)) || true
        ((TOTAL++)) || true

        if [[ -f /boot/grub/grub.cfg ]]; then
            echo "  [PASS] GRUB config exists: /boot/grub/grub.cfg"
            ((PASSED++)) || true
        else
            echo "  [FAIL] GRUB config missing: /boot/grub/grub.cfg"
            ((FAILED++)) || true
        fi
        ((TOTAL++)) || true

        if [[ -f /etc/default/grub ]]; then
            echo "  [PASS] GRUB defaults exist: /etc/default/grub"
            ((PASSED++)) || true
        else
            echo "  [WARN] GRUB defaults missing: /etc/default/grub"
            ((WARNINGS++)) || true
        fi
        ((TOTAL++)) || true
    else
        echo "  [FAIL] GRUB directory missing: /boot/grub"
        ((FAILED++)) || true
        ((TOTAL++)) || true
    fi

    # Check EFI boot entry (UEFI only)
    if [[ -d /sys/firmware/efi ]]; then
        if [[ -d /boot/efi/EFI/void_grub ]]; then
            echo "  [PASS] UEFI boot entry exists: /boot/efi/EFI/void_grub/"
            ((PASSED++)) || true
        elif [[ -d /boot/efi/EFI/VoidLinux ]]; then
            echo "  [PASS] UEFI boot entry exists: /boot/efi/EFI/VoidLinux/"
            ((PASSED++)) || true
        elif [[ -d /boot/efi/EFI/boot ]]; then
            echo "  [INFO] Fallback UEFI boot entry: /boot/efi/EFI/boot/"
            ((PASSED++)) || true
        else
            echo "  [FAIL] No UEFI boot entry found in /boot/efi/EFI/"
            ((FAILED++)) || true
        fi
        ((TOTAL++)) || true
    fi

    # Check initramfs
    local initramfs_files
    initramfs_files=$(find /boot -maxdepth 1 -name 'initramfs-*' -type f 2>/dev/null | wc -l)
    if [[ "${initramfs_files}" -gt 0 ]]; then
        echo "  [PASS] initramfs image(s) present: ${initramfs_files}"
        ((PASSED++)) || true
    else
        echo "  [WARN] No initramfs images found in /boot/"
        ((WARNINGS++)) || true
    fi
    ((TOTAL++)) || true

    echo ""

    # -----------------------------------------------------------------------
    # Section 9: System Services (runit)
    # -----------------------------------------------------------------------
    echo "--- System Services ---"

    if [[ -d /var/service ]]; then
        local services
        services=$(ls /var/service/ 2>/dev/null)
        if [[ -n "${services}" ]]; then
            echo "  [INFO] Enabled runit services:"
            while IFS= read -r svc; do
                echo "       - ${svc}"
            done <<< "${services}"
        else
            echo "  [INFO] No runit services enabled"
        fi
        ((TOTAL++)) || true
    else
        echo "  [INFO] /var/service not present (runtinit may not be active)"
        ((TOTAL++)) || true
    fi

    echo ""

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------
    echo ""
    log_info "============================================="
    log_info " Verification Summary"
    log_info "============================================="
    log_info "  Total checks:  ${TOTAL}"
    log_info "  Passed:        ${PASSED}"
    log_info "  Failed:        ${FAILED}"
    log_info "  Warnings:      ${WARNINGS}"
    log_info "============================================="

    if [[ ${FAILED} -gt 0 ]]; then
        log_error "RESULT: FAILED (${FAILED} check(s) failed)"
        exit 1
    else
        log_success "RESULT: PASSED (all checks passed)"
        exit 0
    fi
}

main "$@"
