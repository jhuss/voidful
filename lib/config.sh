#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034
# config.sh — Configuration loading and validation for voidful installer
#
# Provides define_partition() for config files and validate_config() for
# checking partition layout consistency before any disk operations.

# ---------------------------------------------------------------------------
# Source logging module for log_error / log_warn / log_info
# ---------------------------------------------------------------------------
# shellcheck source=lib/logging.sh
source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
# ---------------------------------------------------------------------------
# Global partition arrays (populated by define_partition, read by validate_config)
# ---------------------------------------------------------------------------
if [[ ! -v PART_MOUNTS ]]; then
    # Use declare -g to ensure global scope even when sourced inside a function
    declare -g -a PART_MOUNTS=()
    declare -g -a PART_SIZES=()
    declare -g -a PART_FS=()
    declare -g -a PART_LUKS=()
    declare -g -a PART_SUBVOLS=()  # Btrfs subvolume name (e.g., @, @home), empty if not btrfs
fi

# ---------------------------------------------------------------------------
# define_partition()
# ---------------------------------------------------------------------------
# Appends a partition definition to the parallel arrays.
#
# Args (named parameters):
#   --mount <path>   Mount point (required, e.g., /, /home, /boot/efi)
#   --size <value>   Size with optional suffix M/G/T, or empty for remaining
#   --fs <type>      Filesystem type (required, e.g., ext4, btrfs, vfat)
#   --luks <yes|no>  Whether to encrypt with LUKS (default: no)
#   --subvol <name>  Btrfs subvolume name (e.g., @, @home) — only for btrfs
#
# Usage in config files:
#   define_partition --mount "/" --size "" --fs "ext4" --luks "no"
#   define_partition --mount "/boot/efi" --size "+100M" --fs "vfat" --luks "no"
#   define_partition --mount "/" --size "" --fs "btrfs" --luks "yes" --subvol "@"
#   define_partition --mount "/home" --size "" --fs "btrfs" --luks "yes" --subvol "@home"

define_partition() {
    local mount_point=""
    local size=""
    local fs_type=""
    local luks="no"
    local subvol=""
    local key

    while [ $# -gt 0 ]; do
        key="${1}"
        case "${key}" in
            --mount)
                if [ $# -lt 2 ]; then
                    log_error "define_partition: --mount requires a value"
                    return 1
                fi
                mount_point="${2}"
                shift 2
                ;;
            --size)
                if [ $# -lt 2 ]; then
                    log_error "define_partition: --size requires a value"
                    return 1
                fi
                size="${2}"
                shift 2
                ;;
            --fs)
                if [ $# -lt 2 ]; then
                    log_error "define_partition: --fs requires a value"
                    return 1
                fi
                fs_type="${2}"
                shift 2
                ;;
            --luks)
                if [ $# -lt 2 ]; then
                    log_error "define_partition: --luks requires a value"
                    return 1
                fi
                luks="${2}"
                shift 2
                ;;
            --subvol)
                if [ $# -lt 2 ]; then
                    log_error "define_partition: --subvol requires a value"
                    return 1
                fi
                subvol="${2}"
                shift 2
                ;;
            *)
                log_error "define_partition: unknown parameter '${key}'"
                return 1
                ;;
        esac
    done

    # Validate required parameters
    if [ -z "${mount_point}" ]; then
        log_error "define_partition: --mount is required"
        return 1
    fi

    if [ -z "${fs_type}" ]; then
        log_error "define_partition: --fs is required"
        return 1
    fi

    # Validate luks value
    if [ "${luks}" != "yes" ] && [ "${luks}" != "no" ]; then
        log_error "define_partition: --luks must be 'yes' or 'no', got '${luks}'"
        return 1
    fi

    # Append to parallel arrays
    PART_MOUNTS+=("${mount_point}")
    PART_SIZES+=("${size}")
    PART_FS+=("${fs_type}")
    PART_LUKS+=("${luks}")
    PART_SUBVOLS+=("${subvol}")
}

# ---------------------------------------------------------------------------
# validate_config()
# ---------------------------------------------------------------------------
# Validates the partition arrays and global configuration for consistency.
#
# Checks performed:
#   1. Array length consistency (all four arrays must be equal length)
#   2. Filesystem type validity (ext4, btrfs, vfat, xfs)
#   3. Partition size format (positive integer with optional + prefix and
#      M/G/T suffix, or empty for remaining)
#   4. Only the last partition may have empty size (remaining space)
#   5. LUKS credential presence (LUKS_PASSPHRASE or LUKS_KEYFILE if any
#      partition has --luks "yes")
#   6. Root partition exists (at least one --mount "/")
#   7. UEFI requires EFI System Partition (vfat at /boot/efi)
#   8. LUKS requires BOTH /boot/efi (UEFI) AND /boot (kernel/initramfs)
#      — GRUB must read kernel/initramfs from unencrypted /boot
#
# Returns:
#   0 on valid configuration
#   1 on invalid configuration (errors logged via log_error)

validate_config() {
    local error_count=0
    local i
    local array_len
    local mount_point
    local size
    local fs_type
    local luks
    local has_luks_partition="no"
    local has_root_partition="no"
    local has_efi_partition="no"
    local has_boot_partition="no"
    local zone_path

    # -----------------------------------------------------------------------
    # Check 1: Array length consistency
    # -----------------------------------------------------------------------
    array_len=${#PART_MOUNTS[@]}

    if [ "${#PART_SIZES[@]}" -ne "${array_len}" ]; then
        log_error "Partition arrays have inconsistent lengths: PART_MOUNTS(${array_len}), PART_SIZES(${#PART_SIZES[@]})"
        ((error_count++))
    fi

    if [ "${#PART_FS[@]}" -ne "${array_len}" ]; then
        log_error "Partition arrays have inconsistent lengths: PART_MOUNTS(${array_len}), PART_FS(${#PART_FS[@]})"
        ((error_count++))
    fi

    if [ "${#PART_LUKS[@]}" -ne "${array_len}" ]; then
        log_error "Partition arrays have inconsistent lengths: PART_MOUNTS(${array_len}), PART_LUKS(${#PART_LUKS[@]})"
        ((error_count++))
    fi

    # If arrays are inconsistent, we cannot proceed with further validation
    if [ "${error_count}" -gt 0 ]; then
        return 1
    fi

    # If no partitions defined at all, that's an error
    if [ "${array_len}" -eq 0 ]; then
        log_error "No partitions defined — at least one partition is required"
        return 1
    fi

    # -----------------------------------------------------------------------
    # Check 2-4: Iterate over partitions for fs, size, luks, root, efi checks
    # -----------------------------------------------------------------------
    for ((i = 0; i < array_len; i++)); do
        mount_point="${PART_MOUNTS[i]}"
        size="${PART_SIZES[i]}"
        fs_type="${PART_FS[i]}"
        luks="${PART_LUKS[i]}"

        # Check 2: Filesystem type validity
        case "${fs_type}" in
            ext4|btrfs|vfat|xfs)
                # Valid filesystem
                ;;
            "")
                log_error "Partition ${i} (mount: ${mount_point}): filesystem type (--fs) is required"
                ((error_count++))
                ;;
            *)
                log_error "Partition ${i} (mount: ${mount_point}): invalid filesystem type '${fs_type}' — must be ext4, btrfs, vfat, or xfs"
                ((error_count++))
                ;;
        esac

        # Check 3: Partition size format
        if [ -n "${size}" ]; then
            # Size must be: optional +, positive integer, optional M/G/T suffix
            if ! echo "${size}" | grep -qE '^\+[0-9]+[MGT]$|^[0-9]+[MGT]$'; then
                log_error "Partition ${i} (mount: ${mount_point}): invalid size '${size}' — must be a positive integer with optional + prefix and M/G/T suffix (e.g., 100M, +4G, 1T), or empty for remaining space"
                ((error_count++))
            fi
        else
            # Check 4: Only the last partition may have empty size
            if [ "${i}" -ne $((array_len - 1)) ]; then
                log_error "Partition ${i} (mount: ${mount_point}): only the last partition may have empty size (remaining space), but size is empty here"
                ((error_count++))
            fi
        fi

        # Check 5: Track if any partition needs LUKS credentials
        if [ "${luks}" = "yes" ]; then
            has_luks_partition="yes"
        fi

        # Check 6: Track root partition
        if [ "${mount_point}" = "/" ]; then
            has_root_partition="yes"
        fi

        # Check 7: Track EFI partition
        if [ "${mount_point}" = "/boot/efi" ] && [ "${fs_type}" = "vfat" ]; then
            has_efi_partition="yes"
        fi

        # Check 7b: Track unencrypted boot partition (/boot)
        # When LUKS is used, GRUB must read kernel/initramfs from
        # an unencrypted /boot partition. /boot/efi alone is NOT enough
        # because GRUB EFI binary lives in /boot/efi but kernel/initramfs
        # must be in a separate /boot partition.
        if [ "${luks}" = "no" ]; then
            case "${mount_point}" in
                /boot)
                    has_boot_partition="yes"
                    ;;
            esac
        fi
    done

    # -----------------------------------------------------------------------
    # Check 5: LUKS credential presence
    # -----------------------------------------------------------------------
    if [ "${has_luks_partition}" = "yes" ]; then
        if [ -z "${LUKS_PASSPHRASE:-}" ] && [ -z "${LUKS_KEYFILE:-}" ]; then
            log_error "LUKS partitions detected but no credentials set — set at least one of LUKS_PASSPHRASE or LUKS_KEYFILE"
            ((error_count++))
        fi
    fi

    # -----------------------------------------------------------------------
    # Check 6: Root partition must exist
    # -----------------------------------------------------------------------
    if [ "${has_root_partition}" = "no" ]; then
        log_error "No root partition defined — at least one partition must have --mount \"/\""
        ((error_count++))
    fi

    # -----------------------------------------------------------------------
    # Check 7: UEFI requires EFI System Partition
    # -----------------------------------------------------------------------
    if [ "${BOOT_MODE:-}" = "uefi" ]; then
        if [ "${has_efi_partition}" = "no" ]; then
            log_error "UEFI boot mode detected but no EFI System Partition found — add a vfat partition with --mount \"/boot/efi\""
            ((error_count++))
        fi
    fi

    # -----------------------------------------------------------------------
    # Check 8: LUKS requires BOTH /boot/efi (UEFI) AND /boot (kernel/initramfs)
    # -----------------------------------------------------------------------
    if [ "${has_luks_partition}" = "yes" ]; then
        # LUKS root requires GRUB to read kernel/initramfs from unencrypted /boot
        if [ "${has_boot_partition}" = "no" ]; then
            log_error "LUKS partitions detected but no unencrypted /boot partition found — LUKS root requires GRUB to read kernel/initramfs from an unencrypted partition. Add a partition with --mount \"/boot\" and --luks \"no\""
            ((error_count++))
        fi

        # UEFI requires EFI System Partition for GRUB EFI binary
        if [ "${BOOT_MODE:-}" = "uefi" ] && [ "${has_efi_partition}" = "no" ]; then
            log_error "LUKS + UEFI detected but no EFI System Partition found — add a vfat partition with --mount \"/boot/efi\" and --luks \"no\""
            ((error_count++))
        fi
    fi

    # -----------------------------------------------------------------------
    # Check 9: SWAP_TYPE and SWAP_SIZE validation
    # -----------------------------------------------------------------------
    if [[ -n "${SWAP_TYPE:-}" ]]; then
        case "${SWAP_TYPE}" in
            partition|file|none)
                # Valid swap type
                ;;
            "")
                log_error "SWAP_TYPE is set but empty — must be 'partition', 'file', or 'none'"
                ((error_count++))
                ;;
            *)
                log_error "SWAP_TYPE must be one of: partition, file, none — got '${SWAP_TYPE}'"
                ((error_count++))
                ;;
        esac

        # SWAP_SIZE validation: required when swap type is partition or file
        if [[ "${SWAP_TYPE}" != "none" ]]; then
            if [[ -z "${SWAP_SIZE:-}" ]]; then
                log_error "SWAP_TYPE is '${SWAP_TYPE}' but SWAP_SIZE is not set"
                ((error_count++))
            elif ! echo "${SWAP_SIZE}" | grep -qE '^[0-9]+[MG]$'; then
                log_error "SWAP_SIZE must match format <number><M|G> (e.g., 1G, 512M) — got '${SWAP_SIZE}'"
                ((error_count++))
            fi
        fi
    fi


    # -----------------------------------------------------------------------
    # Check 10: SWAP_TYPE="file" specific warnings
    # -----------------------------------------------------------------------
    if [[ "${SWAP_TYPE:-}" == "file" ]]; then
        # Check filesystem types for swap file compatibility
        local has_btrfs=0 has_ext4=0
        for ((i = 0; i < ${#PART_FS[@]}; i++)); do
            case "${PART_FS[$i]}" in
                btrfs) has_btrfs=1 ;;
                ext4) has_ext4=1 ;;
            esac
        done

        # Btrfs: warning — CoW can corrupt swap files
        if [[ "${has_btrfs}" -eq 1 ]]; then
            log_warn "SWAP_TYPE='file' with btrfs root: CoW can corrupt swap files"
            log_warn "The installer will try 'chattr +C' to disable CoW on the swap file"
            log_warn "If that fails, use SWAP_TYPE='partition' instead"
        fi

        # ext4: warning — data=journal mode can corrupt swap files
        if [[ "${has_ext4}" -eq 1 ]]; then
            log_warn "SWAP_TYPE='file' with ext4 root: data=journal mode can corrupt swap files"
            log_warn "Ensure root is mounted with data=ordered (default) or use noatime"
        fi

        # LUKS: info — swap file will be inside encrypted root
        local has_luks=0
        for ((i = 0; i < ${#PART_LUKS[@]}; i++)); do
            if [[ "${PART_LUKS[$i]}" == "yes" ]]; then
                has_luks=1
                break
            fi
        done

        if [[ "${has_luks}" -eq 1 ]]; then
            log_info "LUKS detected: swap file will be created inside encrypted root partition"
        fi
    fi

    # -----------------------------------------------------------------------
    # Check 11: TIMEZONE validation (full zoneinfo path must be valid)
    # -----------------------------------------------------------------------
    # Runs on the live ISO filesystem; the cloned rootfs carries the same
    # file to the target. validate_config() runs in stage 2, before any
    # disk operation (stage 3).
    if [[ -n "${TIMEZONE:-}" ]]; then
        if [[ "${TIMEZONE}" == /* || "${TIMEZONE}" == *".."* ]]; then
            log_error "TIMEZONE '${TIMEZONE}' is invalid — must be a zone name under /usr/share/zoneinfo (e.g., America/Argentina/Buenos_Aires), not an absolute or parent-relative path"
            ((error_count++))
        else
            zone_path="/usr/share/zoneinfo/${TIMEZONE}"
            if [[ ! -f "${zone_path}" ]]; then
                log_error "TIMEZONE '${TIMEZONE}' is invalid — ${zone_path} does not exist or is not a regular file"
                ((error_count++))
            fi
        fi
    fi
    # -----------------------------------------------------------------------
    # Final result
    # -----------------------------------------------------------------------
    if [ "${error_count}" -gt 0 ]; then
        log_error "Configuration validation failed with ${error_count} error(s)"
        return 1
    fi

    log_info "Configuration validation passed (${array_len} partition(s))"
    return 0
}
