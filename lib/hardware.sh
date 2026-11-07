#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034
# hardware.sh — Hardware detection module for voidful installer
#
# Detects boot mode (UEFI/BIOS), available block devices, system architecture,
# and partition naming conventions.

# ---------------------------------------------------------------------------
# Source dependencies
# ---------------------------------------------------------------------------
# shellcheck source=lib/logging.sh
source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"

# ---------------------------------------------------------------------------
# detect_boot_mode()
#
# Returns: prints "uefi" or "bios" to stdout
# Exit code: 0 on success
# ---------------------------------------------------------------------------
detect_boot_mode() {
    # Match void-installer's detection: check /sys/firmware/efi/systab
    # (a file, not just a directory) for reliable UEFI detection.
    if [ -e /sys/firmware/efi/systab ]; then
        log_info "Detected boot mode: UEFI"
        echo "uefi"
    else
        log_info "Detected boot mode: BIOS"
        echo "bios"
    fi
}

# ---------------------------------------------------------------------------
# get_disks()
#
# Lists available block devices using lsblk.
# Returns: prints disk names (one per line) to stdout
# Exit code: 0 on success
# ---------------------------------------------------------------------------
get_disks() {
    local disk_names
    disk_names=$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }')

    if [ -z "${disk_names}" ]; then
        log_error "No block devices found"
        return 1
    fi

    log_info "Available block devices:"
    while IFS= read -r disk; do
        log_info "  - ${disk}"
    done <<< "${disk_names}"

    echo "${disk_names}"
}

# ---------------------------------------------------------------------------
# validate_disk()
#
# Validates that a disk name refers to a valid block device (not sr0/ISO).
#
# Args: $1 = disk name (e.g., "sda")
# Returns: 0 if valid, 1 if invalid
# ---------------------------------------------------------------------------
validate_disk() {
    local disk="${1:-}"

    if [ -z "${disk}" ]; then
        log_error "validate_disk: No disk name provided"
        return 1
    fi

    # Check if /dev/${disk} exists
    if [ ! -e "/dev/${disk}" ]; then
        log_error "validate_disk: Device /dev/${disk} does not exist"
        return 1
    fi

    # Check if it's a block device
    if [ ! -b "/dev/${disk}" ]; then
        log_error "validate_disk: /dev/${disk} is not a block device"
        return 1
    fi

    # Reject the live ISO drive (sr0)
    if [ "${disk}" = "sr0" ]; then
        log_error "validate_disk: /dev/${disk} is the CD-ROM drive, not a target disk"
        return 1
    fi

    log_info "Disk /dev/${disk} validated successfully"
    return 0
}

# ---------------------------------------------------------------------------
# detect_arch()
#
# Queries the system architecture via xbps-uhelper.
# Returns: prints architecture string to stdout (e.g., "x86_64", "x86_64-musl")
# Exit code: 0 on success
# ---------------------------------------------------------------------------
detect_arch() {
    local arch
    arch=$(xbps-uhelper arch 2>/dev/null)

    if [ -z "${arch}" ]; then
        log_error "detect_arch: Failed to detect architecture (xbps-uhelper arch returned empty)"
        return 1
    fi

    log_info "Detected architecture: ${arch}"
    echo "${arch}"
}

# ---------------------------------------------------------------------------
# get_partition_prefix()
#
# Returns the partition name prefix for a given disk.
# - "p" for NVMe devices (names starting with "nvme")
# - "p" for MMC devices (names starting with "mmc")
# - "" (empty) for SATA/SCSI devices (sda, vda, etc.)
#
# Args: $1 = disk name (e.g., "sda", "nvme0n1", "mmcblk0")
# Returns: 0 on success, prints prefix to stdout
# ---------------------------------------------------------------------------
get_partition_prefix() {
    local disk="${1:-}"

    if [ -z "${disk}" ]; then
        log_error "get_partition_prefix: No disk name provided"
        return 1
    fi

    local prefix=""

    if [[ "${disk}" == nvme* ]] || [[ "${disk}" == mmc* ]]; then
        prefix="p"
        log_info "Partition prefix for ${disk}: ${prefix}"
    else
        log_info "Partition prefix for ${disk}: (none — uses bare numbers)"
    fi

    echo "${prefix}"
}

# ---------------------------------------------------------------------------
# Self-test when run directly
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    echo "=== Hardware Detection Self-Test ==="
    echo

    echo "--- Boot Mode ---"
    detect_boot_mode
    echo

    echo "--- Architecture ---"
    detect_arch
    echo

    echo "--- Available Disks ---"
    get_disks
    echo

    echo "--- Partition Prefix Tests ---"
    for test_disk in sda nvme0n1 vda mmcblk0; do
        prefix=$(get_partition_prefix "${test_disk}")
        echo "  ${test_disk} -> prefix='${prefix}'"
    done
    echo

    echo "--- Disk Validation Tests ---"
    # Test with real disk if available
    if lsblk -dn -o NAME,TYPE 2>/dev/null | grep -q "disk"; then
        real_disk=$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1; exit }')
        echo "  Validating real disk '${real_disk}'..."
        validate_disk "${real_disk}"
    fi
    echo "  Validating 'sr0' (should fail)..."
    validate_disk "sr0" || true
    echo "  Validating 'nonexistent' (should fail)..."
    validate_disk "nonexistent" || true
    echo

    echo "=== Self-Test Complete ==="
fi
