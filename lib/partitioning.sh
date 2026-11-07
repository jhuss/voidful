#!/usr/bin/env bash
set -euo pipefail

# partitioning.sh — GPT partition table creation, filesystem formatting,
# LUKS container setup, and filesystem mounting for voidful installer.
#
# Provides functions for:
#   - Generating sfdisk-compatible JSON partition layouts
#   - Wiping existing signatures and creating GPT partition tables
#   - Formatting partitions with ext4, vfat, btrfs, or xfs
#   - Opening LUKS2 encrypted containers
#   - Mounting filesystems in correct order (LUKS → btrfs subvolumes → others)
#   - Unmounting filesystems in reverse order
#
# ---------------------------------------------------------------------------
# Source dependencies
# ---------------------------------------------------------------------------
# shellcheck source=lib/logging.sh
source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
# shellcheck source=lib/hardware.sh
source "$(dirname "${BASH_SOURCE[0]}")/hardware.sh"
# shellcheck source=lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

declare -a PART_DEVICES=()  # Populated by wipe_and_partition()
declare PARTITION_LABEL_TYPE=""  # Set by wipe_and_partition(), read by build_sfdisk_input()

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# _convert_size_to_sectors()
#
# Convert size string (e.g., "100M", "1G", "1T") to sector count.
# Handles optional leading + prefix from config format.
#
# Args: $1 = size string
# Returns: sector count to stdout
_convert_size_to_sectors() {
    local size_str="${1}"
    local number suffix sectors

    # Strip leading + (config format)
    size_str="${size_str#+}"

    # Extract number and suffix
    number="${size_str//[!0-9]/}"
    suffix="${size_str//[0-9]/}"

    case "${suffix}" in
        M|MB) sectors=$((number * 1024 * 1024 / 512)) ;;
        G|GB) sectors=$((number * 1024 * 1024 * 1024 / 512)) ;;
        T|TB) sectors=$((number * 1024 * 1024 * 1024 * 1024 / 512)) ;;
        *)    sectors=$((number * 1024 * 1024 / 512)) ;;  # Default to MB
    esac

    echo "${sectors}"
}

# _luks_name_from_mount()
#
# Derive LUKS mapper name from a partition's mount point.
#   /          -> root
#   /home      -> home
#   /var/log   -> var-log
#
# Args: $1 = mount point
# Returns: LUKS name to stdout
_luks_name_from_mount() {
    local mount_point="${1}"

    if [[ "${mount_point}" == "/" ]]; then
        echo "root"
    else
        # Remove leading / and replace remaining / with -
        local name="${mount_point#/}"
        name="${name//-/}"
        echo "${name}"
    fi
}

# ---------------------------------------------------------------------------
# build_sfdisk_input()
# ---------------------------------------------------------------------------
# Builds sfdisk-compatible text input from the partition arrays.
# Outputs to stdout AND sets PARTITION_LAYOUT_TEXT global.
#
# Supports both GPT (UEFI) and DOS/MBR (BIOS) partition tables.
# Uses sfdisk named-fields format (no device prefix).
#
# Requires: TARGET_DISK, PART_MOUNTS, PART_SIZES, PART_FS, PART_LUKS,
#           BOOT_MODE
# ---------------------------------------------------------------------------
build_sfdisk_input() {
    local num_partitions="${#PART_MOUNTS[@]}"
    local current_start=2048  # 1 MiB alignment (standard for both MBR and GPT)
    local i mount_point size fs_type luks
    local part_type sectors
    local bootable_flag=""
    local prefix="${PARTITION_PREFIX:-}"
    local disk_sectors

    # Get total disk size in sectors
    disk_sectors=$(blockdev --getsz "${TARGET_DISK}" 2>/dev/null || echo "0")

    # Validate inputs
    if [[ "${num_partitions}" -eq 0 ]]; then
        log_error "build_sfdisk_input: No partitions defined"
        return 1
    fi

    if [[ -z "${TARGET_DISK:-}" ]]; then
        log_error "build_sfdisk_input: TARGET_DISK is not set"
        return 1
    fi

    # Get partition prefix for this disk if not already set
    if [[ -z "${prefix}" ]]; then
        prefix=$(get_partition_prefix "${TARGET_DISK}")
    fi

    # Derive PARTITION_LABEL_TYPE from BOOT_MODE if not already set
    if [[ -z "${PARTITION_LABEL_TYPE:-}" ]]; then
        if [[ "${BOOT_MODE:-}" == "uefi" ]]; then
            PARTITION_LABEL_TYPE="gpt"
        else
            PARTITION_LABEL_TYPE="dos"
        fi
    fi

    # Build sfdisk text input (label type set by wipe_and_partition)
    local sfdisk_input="label: ${PARTITION_LABEL_TYPE}\n"
    sfdisk_input+="unit: sectors\n"

    for ((i = 0; i < num_partitions; i++)); do
        mount_point="${PART_MOUNTS[$i]}"
        size="${PART_SIZES[$i]}"
        fs_type="${PART_FS[$i]}"
        luks="${PART_LUKS[$i]}"

        # Determine partition type code.
        # sfdisk on this system requires full GPT GUIDs (shorthand like
        # ef00/8300 is not recognized in named-fields format).
        #   EFI System: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
        #   Linux FS:   0FC63DAF-8483-4772-8E79-3D69D8477DE4
        #   Linux Swap: 0657FD6D-A4AB-43C4-84E5-0933C84B4F42
        part_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
        if [[ "${mount_point}" == "/boot/efi" && "${BOOT_MODE:-}" == "uefi" ]]; then
            part_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
        fi

        # For BIOS installs, use numeric codes instead of GUIDs.
        # These are required when PARTITION_LABEL_TYPE is 'dos'.
        if [[ "${PARTITION_LABEL_TYPE}" == "dos" ]]; then
            case "${mount_point}" in
                */boot/efi|*/efi) part_type="0xef" ;;
                */swap)         part_type="82" ;;
                *)              part_type="83" ;;
            esac
        fi

        # For BIOS installs, mark the first partition as bootable so the
        # firmware/GRUB can locate it. Without this flag grub-probe cannot
        # resolve the boot partition and emits "cannot find a GRUB drive for
        # /dev/vda1". UEFI ignores boot flags (it uses the GPT EFI type GUID
        # set above), so this only applies to BIOS mode.
        # Per sfdisk(8): device prefix is optional and should NOT be used
        # unless you are sure. The named-fields format uses bare field
        # assignments without device/partition name prefix.
        #
        # BIOS (MBR/DOS): mark the first partition as bootable so the firmware
        # / GRUB (grub-probe) can locate the boot partition. UEFI ignores boot
        # flags (it uses the GPT EFI type GUID above), so this is DOS-only.
        bootable_flag=""
        if [[ "${PARTITION_LABEL_TYPE}" == "dos" && ${i} -eq 0 ]]; then
            bootable_flag=", bootable"
        fi

        # Size can be empty (use remaining space) or a value like 512M, 1G, etc.
        if [[ -n "${size}" ]]; then
            # Convert size to sectors for sfdisk
            sectors=$(_convert_size_to_sectors "${size}")
            sfdisk_input+="start=${current_start}, size=${sectors}, type=${part_type}${bootable_flag}\n"
            current_start=$((current_start + sectors))
        else
            # Last partition: use remaining space
            # GPT needs 33 sectors reserved for the backup partition table
            # MBR/DOS does not need this reservation
            local gpt_reserve=0
            [[ "${PARTITION_LABEL_TYPE}" == "gpt" ]] && gpt_reserve=33
            if [[ ${i} -eq $((num_partitions - 1)) && ${disk_sectors} -gt 0 ]]; then
                sectors=$((disk_sectors - current_start - gpt_reserve))
                sfdisk_input+="start=${current_start}, size=${sectors}, type=${part_type}${bootable_flag}\n"
            else
                sfdisk_input+="start=${current_start}, type=${part_type}${bootable_flag}\n"
            fi
        fi
    done

    # Set global variable and output to stdout
    PARTITION_LAYOUT_TEXT="${sfdisk_input}"
    printf "%b" "${sfdisk_input}"
}

# _reconcile_partitions_for_boot_mode()
#
# Discards partitions that the detected hardware cannot use, so we never
# carve space for a boot mode the firmware ignores. This is how "hardware
# detection prevails over config": an EFI System Partition (/boot/efi, vfat)
# is only meaningful on UEFI firmware. When the machine boots from BIOS we
# drop it (and any other UEFI-only mount) before building the layout.
#
# Requires: BOOT_MODE to be reconciled with hardware first (see
# stage_preflight in install.sh). Mutates the global PART_* arrays in place.
# ---------------------------------------------------------------------------
_reconcile_partitions_for_boot_mode() {
    local -a keep_mounts=()
    local -a keep_sizes=()
    local -a keep_fs=()
    local -a keep_luks=()
    local -a keep_subvols=()
    local i mount_point fs_type
    local num="${#PART_MOUNTS[@]}"

    if [[ "${BOOT_MODE:-}" == "bios" ]]; then
        # BIOS firmware has no EFI System Partition. Discard any partition
        # whose sole purpose is UEFI boot (currently: /boot/efi).
        for ((i = 0; i < num; i++)); do
            mount_point="${PART_MOUNTS[$i]}"
            fs_type="${PART_FS[$i]:-}"
            if [[ "${mount_point}" == "/boot/efi" ]]; then
                log_info "Discarding UEFI-only partition (${mount_point}) — hardware boots from BIOS"
                continue
            fi
            keep_mounts+=("${mount_point}")
            keep_sizes+=("${PART_SIZES[$i]:-}")
            keep_fs+=("${fs_type}")
            keep_luks+=("${PART_LUKS[$i]:-}")
            keep_subvols+=("${PART_SUBVOLS[$i]:-}")
        done
    else
        # UEFI (or any other mode): keep all partitions as-is
        for ((i = 0; i < num; i++)); do
            keep_mounts+=("${PART_MOUNTS[$i]}")
            keep_sizes+=("${PART_SIZES[$i]:-}")
            keep_fs+=("${PART_FS[$i]:-}")
            keep_luks+=("${PART_LUKS[$i]:-}")
            keep_subvols+=("${PART_SUBVOLS[$i]:-}")
        done
    fi
    if [[ "${#keep_mounts[@]}" -ne "${num}" ]]; then
        declare -g -a PART_MOUNTS=("${keep_mounts[@]}")
        declare -g -a PART_SIZES=("${keep_sizes[@]}")
        declare -g -a PART_FS=("${keep_fs[@]}")
        declare -g -a PART_LUKS=("${keep_luks[@]}")
        declare -g -a PART_SUBVOLS=("${keep_subvols[@]}")
        log_info "Reconciled partition layout for ${BOOT_MODE}: ${#PART_MOUNTS[@]} partition(s)"
    else
        log_info "Partition layout already consistent with ${BOOT_MODE}"
    fi
}

# ---------------------------------------------------------------------------
# wipe_and_partition()
# ---------------------------------------------------------------------------
# Wipes existing signatures and creates partition table (GPT or DOS/MBR).
#
# Args: $1 = disk device (e.g., /dev/sda)
#
# Populates PART_DEVICES array with device paths after partitioning.
# Sets TARGET_DISK and PARTITION_PREFIX globals.
# ---------------------------------------------------------------------------
wipe_and_partition() {
    local disk="${1:?wipe_and_partition: disk device required (e.g., /dev/sda)}"
    local disk_base
    local num_partitions="${#PART_MOUNTS[@]}"
    local json_file i
    # Use /var/tmp instead of /tmp — the live ISO tmpfs may be full
    json_file=$(TMPDIR=/var/tmp mktemp)

    # Derive disk base name (e.g., "sda" from "/dev/sda")
    disk_base=$(basename "${disk}")

    # Validate disk before proceeding
    if ! validate_disk "${disk_base}"; then
        log_error "wipe_and_partition: Disk validation failed, aborting"
        return 1
    fi

    # Set global variables for downstream use
    TARGET_DISK="${disk}"
    PARTITION_PREFIX=$(get_partition_prefix "${disk_base}")

    # Determine partition table type based on boot mode
    if [[ "${BOOT_MODE:-}" == "uefi" ]]; then
        PARTITION_LABEL_TYPE="gpt"
    else
        PARTITION_LABEL_TYPE="dos"
    fi

    log_info "Starting partitioning of ${disk} (${PARTITION_LABEL_TYPE}, ${PARTITION_PREFIX:+using 'p' prefix})"

    # Step 1: Wipe existing signatures
    log_info "Wiping existing filesystem signatures on ${disk}..."
    
    # Attempt to unmount any partitions on the disk to ensure wipefs can succeed.
    # This is critical during --reinstall if the previous install was active.
    log_info "Ensuring all partitions on ${disk} are unmounted..."
    # Find all partitions on the disk and try to unmount them.
    # Improved: Handles names with or without leading slashes.
    local parts
    parts=$(lsblk -ln -o NAME,TYPE "${disk}" | awk '$2=="part" {print "/dev/"$1}' || true)
    for p in $parts; do
        # Check if p is valid (not empty/double slash)
        if [[ "$p" != "" && "$p" != "/dev//"* ]]; then
            umount -l "$p" 2>/dev/null || true
        fi
    done

    # Close any lingering DM mappers associated with this disk
    for mapper in /dev/mapper/luks-*; do
        [[ -e "${mapper}" ]] || continue
        local dev_src
        dev_src=$(readlink -f "${mapper}" 2>/dev/null || true)
        if [[ -n "${dev_src}" && "${dev_src}" == "${disk}"* ]]; then
            cryptsetup close "$(basename "${mapper}")" 2>/dev/null || true
        fi
    done

    # Small grace period for kernel to release block locks
    sleep 1

    if ! wipefs -a "${disk}"; then
        log_error "wipe_and_partition: Failed to wipe signatures on ${disk}. Attempting forced wipe."
        # Fallback: Try to wipe even if some mounts persist (though umount -l should have helped)
        if ! wipefs -af "${disk}"; then
            log_error "wipe_and_partition: Failed to wipe signatures even with -f flag"
            log_error "Diagnostic info:"
            log_error "  - Disk: ${disk}"
            log_error "  - Partition siblings: ${parts:-None}"
            log_error "  - Possible culprits: Kernel locks, busy processes, or persistent DM devices."
            return 1
        fi
    fi
    log_success "Signatures wiped on ${disk}"
    # Give kernel time to release old references
    sleep 1

    # Step 2: Generate sfdisk input (json_file already created above)
    log_info "Generating partition layout..."
    if ! build_sfdisk_input > "${json_file}"; then
        log_error "wipe_and_partition: Failed to generate partition layout"
        rm -f "${json_file}"
        return 1
    fi

    # Step 3: Apply partition table
    log_info "Writing ${PARTITION_LABEL_TYPE} partition table to ${disk}..."
    if ! sfdisk "${disk}" < "${json_file}"; then
        log_error "wipe_and_partition: Failed to write partition table to ${disk}"
        rm -f "${json_file}"
        return 1
    fi
    log_success "Partition table written to ${disk}"

    # Clean up temp file
    rm -f "${json_file}"

    # Step 4: Rescan partitions
    log_info "Rescanning partition table..."
    partx -u "${disk}" 2>/dev/null || true

    # Give kernel time to recognize new partitions
    sleep 1

    # Step 5: Populate PART_DEVICES array
    PART_DEVICES=()
    for ((i = 0; i < num_partitions; i++)); do
        local part_num=$((i + 1))
        PART_DEVICES+=("${disk}${PARTITION_PREFIX}${part_num}")
    done

    log_info "Partition devices mapped:"
    for ((i = 0; i < num_partitions; i++)); do
        log_info "  ${PART_MOUNTS[$i]} -> ${PART_DEVICES[$i]}"
    done

    log_success "Partitioning complete on ${disk}"
    return 0
}

# ---------------------------------------------------------------------------
# format_partitions()
# ---------------------------------------------------------------------------
# Formats each partition with the appropriate filesystem.
#
# Maps filesystem types to mkfs commands:
#   ext4  -> mkfs.ext4 -F
#   vfat  -> mkfs.vfat -F 32
#   btrfs -> mkfs.btrfs -f
#   xfs   -> mkfs.xfs -f -i sparse=0
#
# For LUKS partitions, formats the mapper device (created by open_luks_partitions).
# ---------------------------------------------------------------------------
format_partitions() {
    local num_partitions="${#PART_MOUNTS[@]}"
    local i mount_point fs_type luks device luks_name

    if [[ "${#PART_DEVICES[@]}" -eq 0 ]]; then
        log_error "format_partitions: PART_DEVICES is empty — run wipe_and_partition first"
        return 1
    fi

    log_info "Formatting partitions..."

    for ((i = 0; i < num_partitions; i++)); do
        mount_point="${PART_MOUNTS[$i]}"
        fs_type="${PART_FS[$i]}"
        luks="${PART_LUKS[$i]}"
        device="${PART_DEVICES[$i]}"

        # For LUKS partitions, use the mapper device
        if [[ "${luks}" == "yes" ]]; then
            luks_name=$(_luks_name_from_mount "${mount_point}")
            device="/dev/mapper/luks-${luks_name}"

            if [[ ! -e "${device}" ]]; then
                log_error "format_partitions: LUKS mapper ${device} does not exist — run open_luks_partitions first"
                return 1
            fi

            log_info "Formatting LUKS partition ${mount_point} (${device}) as ${fs_type}..."
        else
            log_info "Formatting ${mount_point} (${device}) as ${fs_type}..."
        fi

        # Format based on filesystem type
        case "${fs_type}" in
            ext4)
                if ! mkfs.ext4 -F "${device}"; then
                    log_error "format_partitions: Failed to format ${mount_point} as ext4"
                    return 1
                fi
                ;;
            vfat)
                if ! mkfs.vfat -F 32 "${device}"; then
                    log_error "format_partitions: Failed to format ${mount_point} as vfat"
                    return 1
                fi
                ;;
            btrfs)
                if ! mkfs.btrfs -f "${device}"; then
                    log_error "format_partitions: Failed to format ${mount_point} as btrfs"
                    return 1
                fi
                ;;
            xfs)
                if ! mkfs.xfs -f -i sparse=0 "${device}"; then
                    log_error "format_partitions: Failed to format ${mount_point} as xfs"
                    return 1
                fi
                ;;
            linux-swap)
                # Swap partitions are formatted by format_swap_partitions()
                log_info "Skipping swap partition ${mount_point} (${device}) — formatted by format_swap_partitions"
                ;;
            *)
                log_error "format_partitions: Unknown filesystem type '${fs_type}' for ${mount_point}"
                return 1
                ;;
        esac

        log_success "Formatted ${mount_point} as ${fs_type}"
    done

    log_success "All partitions formatted"
    return 0
}
# ---------------------------------------------------------------------------
# format_swap_partitions()
# ---------------------------------------------------------------------------
# Formats swap partitions using mkswap.
# Sets the global SWAP_UUID variable to the UUID of the first swap partition.
# Must be called AFTER wipe_and_partition() (PART_DEVICES must be populated).
#
# Returns:
#   0 on success
#   1 if no swap partitions found or formatting fails
# ---------------------------------------------------------------------------
format_swap_partitions() {
    local num_partitions="${#PART_MOUNTS[@]}"
    local i mount_point fs_type device uuid

    if [[ "${#PART_DEVICES[@]}" -eq 0 ]]; then
        log_error "format_swap_partitions: PART_DEVICES is empty — run wipe_and_partition first"
        return 1
    fi

    SWAP_UUID=""
    local swap_found=0

    for ((i = 0; i < num_partitions; i++)); do
        mount_point="${PART_MOUNTS[$i]}"
        fs_type="${PART_FS[$i]}"
        device="${PART_DEVICES[$i]}"

        if [[ "${fs_type}" == "linux-swap" ]]; then
            log_info "Formatting swap partition ${mount_point} (${device})..."
            if ! mkswap -L swap "${device}"; then
                log_error "format_swap_partitions: Failed to format ${mount_point} as swap"
                return 1
            fi

            # Get UUID for fstab entry
            uuid=$(blkid -s UUID -o value "${device}" 2>/dev/null || echo "")
            if [[ -z "${SWAP_UUID}" && -n "${uuid}" ]]; then
                SWAP_UUID="${uuid}"
                swap_found=1
                log_info "Swap partition formatted: UUID=${SWAP_UUID}"
            fi
        fi
    done

    if [[ "${swap_found}" -eq 1 ]]; then
        log_success "Swap partition formatted (UUID=${SWAP_UUID})"
    else
        log_info "No swap partitions found (SWAP_TYPE may be 'none' or 'file')"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# _adjust_partition_sizes_for_swap()
# ---------------------------------------------------------------------------
# Adjusts partition sizes when swap is configured.
#
# Problem: The root partition may have empty size ("remaining space") but
# swap is now the last partition. This causes the root partition to consume
# all remaining disk space, leaving no room for swap.
#
# Solution: Calculate the root partition's size as:
#   disk_sectors - start_offset(2048) - pre-root partitions - swap - gpt_reserve (if GPT)
#
# Pre-root partitions (e.g. the EFI System Partition) are sized first, so their
# sectors must be subtracted; otherwise the root size overflows the disk and
# sfdisk fails.
#
# Must be called AFTER wipe_and_partition() (disk_sectors known)
# and BEFORE build_sfdisk_input().
# ---------------------------------------------------------------------------
_adjust_partition_sizes_for_swap() {
    local num_partitions="${#PART_MOUNTS[@]}"

    # Only adjust if swap is configured (partition or file)
    if [[ "${SWAP_TYPE:-}" == "none" || -z "${SWAP_SIZE:-}" ]]; then
        return 0
    fi

    # Find root partition index
    local root_idx=-1
    local i
    for ((i = 0; i < num_partitions; i++)); do
        if [[ "${PART_MOUNTS[$i]}" == "/" ]]; then
            root_idx=$i
            break
        fi
    done

    # No root partition or root is last partition — nothing to adjust
    if [[ ${root_idx} -lt 0 ]] || [[ ${root_idx} -eq $((num_partitions - 1)) ]]; then
        return 0
    fi

    # Check if root partition has empty size (needs adjustment)
    if [[ -n "${PART_SIZES[$root_idx]}" ]]; then
        # Root has explicit size — no adjustment needed
        return 0
    fi

    # Calculate disk size in sectors
    local disk_sectors
    disk_sectors=$(blockdev --getsz "${TARGET_DISK}" 2>/dev/null || echo "0")
    if [[ "${disk_sectors}" -eq 0 ]]; then
        log_warn "Cannot determine disk size, skipping swap size adjustment"
        return 0
    fi

    # Convert SWAP_SIZE to sectors (reuse logic from _convert_size_to_sectors)
    local swap_size_str="${SWAP_SIZE}"
    local swap_num swap_unit swap_sectors
    swap_num="${swap_size_str//[MG]/}"
    swap_unit="${swap_size_str//[0-9]/}"

    case "${swap_unit}" in
        M) swap_sectors=$((swap_num * 1024 * 1024 / 512)) ;;
        G) swap_sectors=$((swap_num * 1024 * 1024 * 1024 / 512)) ;;
        *)
            log_warn "Unknown swap size unit '${swap_unit}', skipping adjustment"
            return 0
            ;;
    esac

    # GPT reserve 33 sectors for backup partition table
    local gpt_reserve=0
    [[ "${PARTITION_LABEL_TYPE:-}" == "gpt" ]] && gpt_reserve=33

    # Sum the sizes of the partitions that come BEFORE root (e.g. the EFI System
    # Partition), so the computed root size does not overflow the disk.
    local sum_pre_root=0
    local pre_root_sectors
    for ((i = 0; i < root_idx; i++)); do
        if [[ -n "${PART_SIZES[$i]}" ]]; then
            pre_root_sectors=$(_convert_size_to_sectors "${PART_SIZES[$i]}")
            sum_pre_root=$((sum_pre_root + pre_root_sectors))
        fi
    done

    # Calculate root partition size:
    #   (disk - start_offset - pre-root partitions) - swap - reserve
    # Partitions start at sector 2048, so available = disk_sectors - 2048 - pre-root
    local start_offset=2048
    local available_sectors=$((disk_sectors - start_offset - sum_pre_root))
    local root_sectors=$((available_sectors - swap_sectors - gpt_reserve))

    if [[ ${root_sectors} -le 0 ]]; then
        log_error "Disk too small: ${SWAP_SIZE} swap leaves no room for root partition"
        return 1
    fi

    # Convert sectors back to human-readable size (prefer G, fallback to M)
    local root_gb=$((root_sectors * 512 / 1024 / 1024 / 1024))
    local root_mb=$((root_sectors * 512 / 1024 / 1024))

    # Round to nearest G, or use M if < 1G
    if [[ ${root_gb} -gt 0 ]]; then
        PART_SIZES[root_idx]="${root_gb}G"
    else
        PART_SIZES[root_idx]="${root_mb}M"
    fi

    log_info "Adjusted root partition size: ${PART_SIZES[$root_idx]} (disk=${disk_sectors} sectors, pre-root=${sum_pre_root}, swap=${swap_sectors} sectors)"
    return 0
}

# ---------------------------------------------------------------------------
# format_luks_partitions()
# ---------------------------------------------------------------------------
# Formats all LUKS partitions with LUKS2 header.
# Must be called BEFORE open_luks_partitions().
# ---------------------------------------------------------------------------
format_luks_partitions() {
    local num_partitions="${#PART_MOUNTS[@]}"
    local i mount_point luks device luks_name

    if [[ "${#PART_DEVICES[@]}" -eq 0 ]]; then
        log_error "format_luks_partitions: PART_DEVICES is empty — run wipe_and_partition first"
        return 1
    fi

    log_info "Formatting LUKS partitions..."

    for ((i = 0; i < num_partitions; i++)); do
        mount_point="${PART_MOUNTS[$i]}"
        luks="${PART_LUKS[$i]}"
        device="${PART_DEVICES[$i]}"

        if [[ "${luks}" == "yes" ]]; then
            luks_name=$(_luks_name_from_mount "${mount_point}")
            log_info "Formatting ${device} with LUKS2 (name: ${luks_name})..."

            # Slot 0 selection (see docs/luks.md "Slot semantics"):
            #   - passphrase (only or combined) -> slot 0 = passphrase
            #   - keyfile-only                -> slot 0 = raw keyfile
            if [[ -n "${LUKS_PASSPHRASE:-}" ]]; then
                # Passphrase as slot 0 (written to a temp file, no trailing newline).
                local keyfile
                keyfile=$(mktemp)
                chmod 600 "${keyfile}"
                printf '%s' "${LUKS_PASSPHRASE}" > "${keyfile}"
                cryptsetup luksFormat --batch-mode --type luks2 \
                    --cipher aes-xts-plain64 \
                    --key-size 512 \
                    --hash sha256 \
                    --iter-time 5000 \
                    --use-random \
                    --key-file "${keyfile}" \
                    "${device}" 2>/dev/null || {
                    log_error "format_luks_partitions: Failed to format ${device} with LUKS2 (passphrase)"
                    rm -f "${keyfile}"
                    return 1
                }
                rm -f "${keyfile}"
                log_info "LUKS2 formatted: ${device} (slot 0 = passphrase)"
            elif [[ -n "${LUKS_KEYFILE:-}" && -f "${LUKS_KEYFILE}" ]]; then
                # Keyfile as slot 0 (used raw, no read into memory, no trailing-newline
                # manipulation — the keyfile bytes are the key).
                cryptsetup luksFormat --batch-mode --type luks2 \
                    --cipher aes-xts-plain64 \
                    --key-size 512 \
                    --hash sha256 \
                    --iter-time 5000 \
                    --use-random \
                    --key-file "${LUKS_KEYFILE}" \
                    "${device}" 2>/dev/null || {
                    log_error "format_luks_partitions: Failed to format ${device} with LUKS2 (keyfile)"
                    return 1
                }
                log_info "LUKS2 formatted: ${device} (slot 0 = keyfile)"
            else
                log_error "format_luks_partitions: No LUKS credentials available (set LUKS_PASSPHRASE or LUKS_KEYFILE)"
                return 1
            fi
        fi
    done

    log_success "LUKS partitions formatted"
    return 0
}

# open_luks_partitions()
# ---------------------------------------------------------------------------
# Opens LUKS2 encrypted partitions and creates /dev/mapper/luks-<name> devices.
#
# For each LUKS partition:
#   1. Format with LUKS2 (cryptsetup luksFormat)
#   2. Add keyfile slot if LUKS_KEYFILE is configured
#   3. Open mapper device (cryptsetup open)
#
# LUKS name derivation: / -> root, /home -> home, /var/log -> var-log
# ---------------------------------------------------------------------------
open_luks_partitions() {
    local num_partitions="${#PART_MOUNTS[@]}"
    local i mount_point luks device luks_name

    if [[ "${#PART_DEVICES[@]}" -eq 0 ]]; then
        log_error "open_luks_partitions: PART_DEVICES is empty — run wipe_and_partition first"
        return 1
    fi

    # Check if any partition needs LUKS
    local has_luks="no"
    for ((i = 0; i < num_partitions; i++)); do
        if [[ "${PART_LUKS[$i]}" == "yes" ]]; then
            has_luks="yes"
            break
        fi
    done

    if [[ "${has_luks}" == "no" ]]; then
        log_info "No LUKS partitions found — skipping"
        return 0
    fi

    log_info "Opening LUKS partitions..."

    for ((i = 0; i < num_partitions; i++)); do
        luks="${PART_LUKS[$i]}"
        [[ "${luks}" != "yes" ]] && continue

        mount_point="${PART_MOUNTS[$i]}"
        device="${PART_DEVICES[$i]}"
        luks_name=$(_luks_name_from_mount "${mount_point}")

        log_info "Opening LUKS partition ${mount_point} (${device}) as luks-${luks_name}..."

        # Validate: need at least one credential (passphrase or keyfile)
        if [[ -z "${LUKS_PASSPHRASE:-}" && ( -z "${LUKS_KEYFILE:-}" || ! -f "${LUKS_KEYFILE}" ) ]]; then
            log_error "open_luks_partitions: No LUKS credentials available for ${mount_point}"
            return 1
        fi

        # Add the keyfile as slot 1 — combined mode only (passphrase + keyfile).
        # The passphrase (slot 0, via stdin) authenticates the add; the keyfile
        # is the new key. In keyfile-only mode the keyfile IS slot 0, so no
        # second slot is added (see docs/luks.md "Slot semantics").
        if [[ -n "${LUKS_PASSPHRASE:-}" && -n "${LUKS_KEYFILE:-}" && -f "${LUKS_KEYFILE}" ]]; then
            printf '%s' "${LUKS_PASSPHRASE}" | cryptsetup luksAddKey --batch-mode \
                --key-file - "${device}" "${LUKS_KEYFILE}" 2>/dev/null || {
                log_warn "Failed to add keyfile (slot 1) to LUKS partition ${device}; automated boot may be unavailable (interactive passphrase still works)"
            }
            log_info "Added keyfile (slot 1) to LUKS partition ${device}"
        fi

        # Open the mapper device. Use the passphrase if set (slot 0 for
        # passphrase-only and combined); otherwise use the raw keyfile (slot 0
        # for keyfile-only). Piping avoids process-substitution issues.
        if [[ -n "${LUKS_PASSPHRASE:-}" ]]; then
            printf '%s' "${LUKS_PASSPHRASE}" | cryptsetup --batch-mode open --type luks2 \
                --key-file - "${device}" "luks-${luks_name}" || {
                log_error "open_luks_partitions: Failed to open LUKS mapper for ${mount_point}"
                return 1
            }
        else
            cryptsetup --batch-mode open --type luks2 \
                --key-file "${LUKS_KEYFILE}" "${device}" "luks-${luks_name}" || {
                log_error "open_luks_partitions: Failed to open LUKS mapper for ${mount_point}"
                return 1
            }
        fi

        if [[ -e "/dev/mapper/luks-${luks_name}" ]]; then
            log_success "Opened LUKS partition ${mount_point} -> /dev/mapper/luks-${luks_name}"
        else
            log_error "open_luks_partitions: Failed to open LUKS mapper for ${mount_point}"
            return 1
        fi
    done

    log_success "All LUKS partitions opened"
    return 0
}

# mount_filesystems()
# ---------------------------------------------------------------------------
# Mounts all partitions in correct order:
#   1. Root partition FIRST (btrfs with subvolume, or plain)
#   2. Pre-create all remaining mount point directories inside the rootfs
#   3. Remaining partitions shallowest-first (btrfs with subvolumes,
#      others directly). EFI partition at TARGET_DIR/boot/efi (UEFI only)
#
# Mount point directories MUST exist inside the rootfs: at boot the kernel
# only mounts /, and `mount -a` then needs those directories in the rootfs
# (fstab references them by path). Creating them after the parent partition
# is mounted places them on the parent partition instead (e.g. /boot/efi on
# the /boot partition), which breaks boot-time mounting.
#
# Args: $1 = TARGET_DIR (optional, defaults to /mnt)
# ---------------------------------------------------------------------------
mount_filesystems() {
    local target_dir="${1:-/mnt}"
    local num_partitions="${#PART_MOUNTS[@]}"
    local i mount_point fs_type luks device luks_name

    log_info "Mounting filesystems to ${target_dir}..."

    # Order mount points shallowest-first so a parent/container directory
    # (e.g. / or /boot) is ALWAYS mounted before anything nested inside it
    # (e.g. /boot/efi). This keeps nested mounts valid and makes the clone's
    # tar extraction land on each partition's dedicated mount point.
    local -a depth_idx=() mp slashes key
    for ((i = 0; i < num_partitions; i++)); do
        mp="${PART_MOUNTS[$i]}"
        if [[ "${mp}" == "/" ]]; then
            # The root is ALWAYS mounted first.
            key="0 $i"
        else
            slashes="${mp//[!\/]/}"
            key="$(( ${#slashes} )) $i"
        fi
        depth_idx+=("$key")
    done
    local -a ordered_idx=()
    mapfile -t depth_idx < <(printf '%s\n' "${depth_idx[@]}" | sort -n)
    for entry in "${depth_idx[@]}"; do
        read -r _depth idx <<< "$entry"
        ordered_idx+=("$idx")
    done

    # Find the root partition index (always mounted first).
    local root_idx=""
    for i in "${ordered_idx[@]}"; do
        if [[ "${PART_MOUNTS[$i]}" == "/" ]]; then
            root_idx="${i}"
            break
        fi
    done
    if [[ -z "${root_idx}" ]]; then
        log_error "mount_filesystems: no root partition (/) defined"
        return 1
    fi

    # Mount every partition in shallowest-first order (root first). The mount
    # point directory is created right before each mount, so a nested mount
    # point (e.g. /boot/efi) is created on the already-mounted parent
    # partition (e.g. /boot), not in the rootfs. That is where it must live:
    # at boot the kernel mounts only /, and `mount -a` then mounts the fstab
    # entries in order — the parent (/boot) is listed before the child
    # (/boot/efi), so by the time /boot/efi is mounted it already exists on the
    # /boot partition.
    for i in "${ordered_idx[@]}"; do
        mount_point="${PART_MOUNTS[$i]}"
        fs_type="${PART_FS[$i]}"
        luks="${PART_LUKS[$i]}"
        device="${PART_DEVICES[$i]}"

        # Skip swap partitions (activated by mount_swap_partitions)
        [[ "${fs_type}" == "linux-swap" ]] && continue

        mkdir -p "${target_dir}${mount_point}"

        if [[ "${fs_type}" == "btrfs" ]]; then
            _mount_btrfs_partition "${i}" "${target_dir}"
            continue
        fi

        # For LUKS partitions, use mapper device
        if [[ "${luks}" == "yes" ]]; then
            luks_name=$(_luks_name_from_mount "${mount_point}")
            device="/dev/mapper/luks-${luks_name}"
        fi

        if [[ "${mount_point}" == "/boot/efi" ]]; then
            log_info "Mounting EFI partition (${device}) at ${target_dir}/boot/efi..."
        else
            log_info "Mounting ${mount_point} (${device}) at ${target_dir}${mount_point}..."
        fi

        if ! mount "${device}" "${target_dir}${mount_point}"; then
            log_error "mount_filesystems: Failed to mount ${mount_point}"
            return 1
        fi

        log_success "Mounted ${mount_point} at ${target_dir}${mount_point}"
    done

    log_success "All filesystems mounted"
    return 0
}

# ---------------------------------------------------------------------------
# mount_swap_partitions()
# ---------------------------------------------------------------------------
# Activates swap partitions using swapon.
# Must be called AFTER mount_filesystems() and format_swap_partitions().
#
# Returns:
#   0 on success (no swap partitions or all activated)
#   1 if any swap partition fails to activate
# ---------------------------------------------------------------------------
mount_swap_partitions() {
    local num_partitions="${#PART_MOUNTS[@]}"
    local i mount_point fs_type device
    local swap_found=0
    local failed=0

    for ((i = 0; i < num_partitions; i++)); do
        mount_point="${PART_MOUNTS[$i]}"
        fs_type="${PART_FS[$i]}"
        device="${PART_DEVICES[$i]}"

        if [[ "${fs_type}" == "linux-swap" ]]; then
            log_info "Activating swap partition ${mount_point} (${device})..."
            if ! swapon "${device}"; then
                log_error "mount_swap_partitions: Failed to activate swap ${mount_point}"
                failed=1
            else
                swap_found=1
                log_success "Swap activated: ${mount_point} (${device})"
            fi
        fi
    done

    if [[ "${swap_found}" -eq 1 && "${failed}" -eq 0 ]]; then
        log_success "All swap partitions activated"
    elif [[ "${swap_found}" -eq 0 ]]; then
        log_info "No swap partitions found (SWAP_TYPE may be 'none' or 'file')"
    fi

    return ${failed}
}

# _mount_btrfs_partition()
#
# Internal: mounts a single btrfs partition with its subvolume.
#
# For a btrfs partition:
#   1. Mount raw btrfs (or LUKS mapper) to tmp location
#   2. Create subvolume if PART_SUBVOLS is set
#   3. Unmount tmp
#   4. Mount subvolume at mount point
#
# The mount point directory is created by mount_filesystems() right before
# this call (shallowest-first order), so a nested mount point (e.g.
# /boot/efi) is created on the already-mounted parent partition (e.g. /boot).
#
# Args: $1 = partition index, $2 = TARGET_DIR
# ---------------------------------------------------------------------------
_mount_btrfs_partition() {
    local idx="${1}"
    local target_dir="${2}"
    local mount_point="${PART_MOUNTS[$idx]}"
    local luks="${PART_LUKS[$idx]}"
    local device="${PART_DEVICES[$idx]}"
    local subvol_name="${PART_SUBVOLS[$idx]:-}"
    local btrfs_tmp

    # For LUKS-encrypted btrfs, use the mapper device
    if [[ "${luks}" == "yes" ]]; then
        local luks_name
        luks_name=$(_luks_name_from_mount "${mount_point}")
        device="/dev/mapper/luks-${luks_name}"
    fi

    # Mount to tmp location for subvolume creation
    btrfs_tmp="${target_dir}/.btrfs_tmp_$$_${idx}"
    mkdir -p "${btrfs_tmp}"

    if [[ "${luks}" == "yes" ]]; then
        log_info "Mounting LUKS btrfs mapper ${device} to tmp for subvolume creation..."
    else
        log_info "Mounting btrfs partition ${device} to tmp for subvolume creation..."
    fi

    if ! mount "${device}" "${btrfs_tmp}"; then
        log_error "_mount_btrfs_partition: Failed to mount btrfs to tmp"
        rmdir "${btrfs_tmp}" 2>/dev/null || true
        return 1
    fi

    # Create subvolume if defined
    if [[ -n "${subvol_name}" ]]; then
        log_info "Creating btrfs subvolume ${subvol_name}..."
        btrfs subvolume create "${btrfs_tmp}/${subvol_name}" 2>/dev/null || true
        log_info "Created subvolume: ${subvol_name} -> ${mount_point}"
    fi

    # Unmount tmp and clean up
    umount "${btrfs_tmp}"
    rmdir "${btrfs_tmp}"

    # Mount subvolume at final mount point
    if [[ -n "${subvol_name}" ]]; then
        local mount_opts="subvol=${subvol_name}"
        log_info "Mounting btrfs ${mount_point} (${device}) with ${mount_opts} at ${target_dir}${mount_point}..."
        if ! mount -o "${mount_opts}" "${device}" "${target_dir}${mount_point}"; then
            log_error "_mount_btrfs_partition: Failed to mount ${mount_point} with subvol=${subvol_name}"
            return 1
        fi
    else
        log_info "Mounting btrfs ${mount_point} (${device}) at ${target_dir}${mount_point}..."
        if ! mount "${device}" "${target_dir}${mount_point}"; then
            log_error "_mount_btrfs_partition: Failed to mount ${mount_point}"
            return 1
        fi
    fi

    log_success "Mounted btrfs ${mount_point} at ${target_dir}${mount_point}"
    return 0
}

# NOTE: unmounting is handled by _teardown() in install.sh (children-before-
# parents via /proc/mounts) and _pre_install_unmount() for reinstall; the
# previous unmount_filesystems()/ _unmount_btrfs_partitions() helpers were dead
# code (never called) and were removed.

# ---------------------------------------------------------------------------
# Self-test when run directly
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    echo "=== Partitioning Module Self-Test ==="
    echo

    # Test with a sample configuration
    echo "--- Testing build_sfdisk_input() ---"
    BOOT_MODE="uefi"
    TARGET_DISK="/dev/sda"
    PARTITION_LABEL_TYPE=""

    # Reset arrays
    PART_MOUNTS=()
    PART_SIZES=()
    PART_FS=()
    PART_LUKS=()
    PART_SUBVOLS=()

    # Define test partitions (UEFI + ext4)
    define_partition --mount "/boot/efi" --size "+100M" --fs "vfat" --luks "no"
    define_partition --mount "/" --size "" --fs "ext4" --luks "no"

    echo "UEFI (GPT) layout:"
    PARTITION_LABEL_TYPE="gpt"
    build_sfdisk_input
    echo

    echo "BIOS (MBR) layout:"
    PARTITION_LABEL_TYPE="dos"
    build_sfdisk_input
    echo

    # Test with LUKS
    echo "--- Testing with LUKS ---"
    BOOT_MODE="uefi"
    PART_MOUNTS=()
    PART_SIZES=()
    PART_FS=()
    PART_LUKS=()

    define_partition --mount "/boot/efi" --size "+100M" --fs "vfat" --luks "no"
    define_partition --mount "/" --size "" --fs "ext4" --luks "yes"
    define_partition --mount "/home" --size "10G" --fs "ext4" --luks "yes"

    echo "UEFI + LUKS layout:"
    PARTITION_LABEL_TYPE="gpt"
    build_sfdisk_input
    echo

    # Test Btrfs
    echo "--- Testing Btrfs ---"
    PART_MOUNTS=()
    PART_SIZES=()
    PART_FS=()
    PART_LUKS=()
    PART_SUBVOLS=()

    define_partition --mount "/boot/efi" --size "+100M" --fs "vfat" --luks "no"
    define_partition --mount "/" --size "" --fs "btrfs" --luks "no"

    echo "UEFI + Btrfs layout:"
    PARTITION_LABEL_TYPE="gpt"
    build_sfdisk_input
    echo

    # Test Btrfs with subvolumes and LUKS
    echo "--- Testing Btrfs with subvolumes + LUKS ---"
    PART_MOUNTS=()
    PART_SIZES=()
    PART_FS=()
    PART_LUKS=()
    PART_SUBVOLS=()

    define_partition --mount "/boot/efi" --size "+100M" --fs "vfat" --luks "no"
    define_partition --mount "/" --size "+50G" --fs "btrfs" --luks "yes" --subvol "@"
    define_partition --mount "/home" --size "" --fs "btrfs" --luks "yes" --subvol "@home"

    echo "UEFI + LUKS + Btrfs subvolumes layout:"
    PARTITION_LABEL_TYPE="gpt"
    build_sfdisk_input
    echo

    echo "--- Testing _luks_name_from_mount() ---"
    for test_mount in "/" "/home" "/var/log" "/var"; do
        name=$(_luks_name_from_mount "${test_mount}")
        echo "  ${test_mount} -> ${name}"
    done
    echo

    echo "--- Testing size conversion ---"
    for test_size in "100M" "1G" "30G" "1T"; do
        sectors=$(_convert_size_to_sectors "${test_size}")
        echo "  ${test_size} -> ${sectors} sectors"
    done
    echo

    echo "=== Self-Test Complete ==="
fi
