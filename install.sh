#!/usr/bin/env bash
set -euo pipefail

# install.sh — Main orchestrator for the voidful installer.
#
# Wires all modules together and executes the installation pipeline:
#   1. Pre-flight Check
#   2. Configuration Loading
#   3. Partition & Format
#   4. System Clone
#   5. Post-Clone Cleanup
#   6. Chroot Configuration
#   7. Teardown
#   8. End-Action

VERSION="0.1.0"

# ---------------------------------------------------------------------------
# Base directory — resolve once, used by all modules for relative sourcing
# ---------------------------------------------------------------------------
: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ---------------------------------------------------------------------------
# Source dependencies (in dependency order)
# ---------------------------------------------------------------------------
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"

# shellcheck source=lib/hardware.sh
source "${SCRIPT_DIR}/lib/hardware.sh"

# ---------------------------------------------------------------------------
# Export SCRIPT_DIR for child modules (lib/*.sh)
# ---------------------------------------------------------------------------
export SCRIPT_DIR

# ---------------------------------------------------------------------------
# Default configuration
# ---------------------------------------------------------------------------
TARGET_DISK=""
TARGET_DIR="/mnt"
CONFIG_FILE=""
END_ACTION="shutdown"
BOOTLOADER="grub"
DRY_RUN=false
TEST_MODE=false
REINSTALL=false

# ---------------------------------------------------------------------------
# Global cleanup state
# ---------------------------------------------------------------------------
MOUNTS_UNMOUNTED=false
# Set to true once the pipeline has started creating state (partitions/mounts).
# Early exits (--help, --version, --dry-run, --test-mode, config/preflight
# errors) must NOT run teardown or report an interrupted installation.
INSTALL_STARTED=false

# ---------------------------------------------------------------------------
# Signal handling (ADR-005: Two-Trap Signal Handling Pattern)
# ---------------------------------------------------------------------------
trap_cleanup() {
    local exit_code=$?

    # Only warn/clean up if the installation pipeline actually started
    # creating state. Early exits (--help, --version, --dry-run,
    # --test-mode, config/preflight errors) must not run teardown or
    # report an interrupted installation.
    if [[ "${INSTALL_STARTED}" != "true" ]]; then
        return 0
    fi

    if [[ ${exit_code} -ne 0 ]]; then
        log_warn "Installation interrupted (exit code: ${exit_code})"
    fi

    # Unmount filesystems if not already done
    if [[ "${MOUNTS_UNMOUNTED}" == "false" ]]; then
        _teardown
    fi
}

# Two-trap pattern: EXIT preserves exit code, signal traps force code 8
trap trap_cleanup EXIT
trap 'trap_cleanup; exit 8' INT TERM HUP PIPE

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --help)
                print_help
                exit 0
                ;;
            --version)
                echo "${VERSION}"
                exit 0
                ;;
            --verbose)
                LOG_LEVEL="debug"
                shift
                ;;
            --config)
                CONFIG_FILE="${2:?--config requires a file path}"
                shift 2
                ;;
            --target-disk)
                _CLI_TARGET_DISK="${2:?--target-disk requires a disk device}"
                TARGET_DISK="${_CLI_TARGET_DISK}"
                shift 2
                ;;
            --target-dir)
                _CLI_TARGET_DIR="${2:?--target-dir requires a directory path}"
                TARGET_DIR="${_CLI_TARGET_DIR}"
                shift 2
                ;;
            --end-action)
                _CLI_END_ACTION="${2:?--end-action requires an action: shutdown, reboot, script, func}"
                END_ACTION="${_CLI_END_ACTION}"
                shift 2
                ;;
            --bootloader)
                _CLI_BOOTLOADER="${2:?--bootloader requires a value (grub or none)}"
                BOOTLOADER="${_CLI_BOOTLOADER}"
                if [[ "${BOOTLOADER}" != "grub" && "${BOOTLOADER}" != "none" ]]; then
                    log_error "Invalid bootloader: ${BOOTLOADER}. Must be 'grub' or 'none'."
                    exit 1
                fi
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --test-mode)
                TEST_MODE=true
                shift
                ;;
            --reinstall)
                REINSTALL=true
                shift
                ;;
            *)
                log_error "Unknown option: ${1}"
                print_help
                exit 1
                ;;
        esac
    done
}

print_help() {
    cat <<EOF
voidful ${VERSION} — Offline Void Linux Installer

Usage: install.sh [OPTIONS]

Options:
  --config FILE          Path to configuration file
  --target-disk DISK     Target disk device (e.g., /dev/sda)
  --target-dir DIR       Mount point for root partition (default: /mnt)
  --end-action ACTION    Post-install action: shutdown (default), reboot, script, func, none
  --bootloader LOADER    Bootloader: grub (default) or none
  --dry-run              Validate config and exit without installing
  --test-mode            Generate full operational plan without performing operations
  --reinstall            Reinstall over existing installation (unmounts partitions first)
  --verbose              Enable debug-level logging
  --help                 Show this help message
  --version              Show version

Environment Variables:
  LUKS_PASSPHRASE        LUKS passphrase (at least one of this or LUKS_KEYFILE required)
  LUKS_KEYFILE           Path to LUKS keyfile on live ISO
  HOSTNAME               System hostname
  LOCALE                 System locale (e.g., en_US.UTF-8)
  KEYMAP                 Keyboard layout (e.g., us)
  TIMEZONE               Timezone name (e.g., America/Argentina/Buenos_Aires)
  USER_LOGIN             Actual login username (e.g. "user")
  USERNAME               Full display name for the user (e.g. "Void User")
  USER_GROUPS            Comma-separated supplementary groups (default: wheel)
  USER_PASS              Password for regular user
  ROOT_PASS              Password for root user
  ENABLED_SERVICES       Comma-separated list of runit services to enable
  NETWORK_MODE           Network mode: dhcp or static
  NETWORK_DEVICE         Network device name
  NETWORK_IP             Static IP address
  NETWORK_GATEWAY        Default gateway
EOF
}

# ---------------------------------------------------------------------------
# Pipeline stages
# ---------------------------------------------------------------------------

# Stage 1: Pre-flight Check
stage_preflight() {
    log_info "Stage 1: Pre-flight Check"

    # Verify root privileges
    if [[ $(id -u) -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 3
    fi

    # Detect boot mode from hardware.
    BOOT_MODE=$(detect_boot_mode)
    log_info "Boot mode (from hardware): ${BOOT_MODE}"

    # Hardware detection prevails over config. detect_boot_mode above always
    # returns a definitive value (uefi/bios) and overrides any boot mode the
    # config or environment implied (e.g. a UEFI config template run on BIOS
    # hardware). This guarantees we never install a bootloader or partition
    # layout the firmware cannot use. stage_partition will discard any
    # boot-mode-incompatible partitions (see _reconcile_partitions_for_boot_mode).
    if [[ "${BOOT_MODE}" != "uefi" && "${BOOT_MODE}" != "bios" ]]; then
        log_warn "Unexpected boot mode value '${BOOT_MODE}'; forcing 'bios'"
        BOOT_MODE="bios"
    fi
    log_info "Boot mode (authoritative): ${BOOT_MODE}"

    # Validate target disk
    if [[ -z "${TARGET_DISK}" ]]; then
        log_error "Target disk not specified. Use --target-disk /dev/sdX"
        exit 1
    fi

    local disk_base
    disk_base=$(basename "${TARGET_DISK}")
    if ! validate_disk "${disk_base}"; then
        log_error "Invalid target disk: ${TARGET_DISK}"
        exit 2
    fi

    # Detect architecture
    ARCH=$(detect_arch)
    log_info "Architecture: ${ARCH}"

    # Set partition prefix
    PARTITION_PREFIX=$(get_partition_prefix "${disk_base}")
    log_info "Partition prefix: ${PARTITION_PREFIX}"

    log_success "Pre-flight check passed"
}

# Stage 2: Configuration Loading
stage_config() {
    log_info "Stage 2: Configuration Loading"

    # Source config module first (defines define_partition, validate_config)
    # shellcheck source=lib/config.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

    # Source config file (calls define_partition())
    # Fallback: if no --config specified, use the bundled UEFI example. Resolve
    # relative to the script directory (not the CWD) so the installer works
    # when invoked from any working directory.
    if [[ -z "${CONFIG_FILE}" ]]; then
        if [[ -f "${SCRIPT_DIR}/configs/example-uefi.conf" ]]; then
            CONFIG_FILE="${SCRIPT_DIR}/configs/example-uefi.conf"
            log_info "No --config specified, using default: ${CONFIG_FILE}"
        else
            log_error "No configuration file found. Specify one with --config."
            exit 1
        fi
    fi

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_error "Configuration file not found: ${CONFIG_FILE}"
        exit 1
    fi
    log_info "Loading configuration from ${CONFIG_FILE}"
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"

    # CLI arguments always override config file values
    [[ -n "${_CLI_TARGET_DISK:-}" ]] && TARGET_DISK="${_CLI_TARGET_DISK}"
    [[ -n "${_CLI_TARGET_DIR:-}" ]] && TARGET_DIR="${_CLI_TARGET_DIR}"
    [[ -n "${_CLI_END_ACTION:-}" ]] && END_ACTION="${_CLI_END_ACTION}"
    [[ -n "${_CLI_BOOTLOADER:-}" ]] && BOOTLOADER="${_CLI_BOOTLOADER}"

    # Validate configuration
    if ! validate_config; then
        log_error "Configuration validation failed"
        exit 1
    fi

    log_success "Configuration loaded and validated"
}

# _pre_install_unmount()
#
# Pre-install safety for --reinstall: unmount existing partitions and
# close LUKS mappers on the target disk before partitioning.
# This ensures wipe_and_partition() can operate on a disk that may
# already have an existing installation mounted.
#
# Args: $1 = disk device (e.g., /dev/sda)
# ---------------------------------------------------------------------------
_pre_install_unmount() {
    local disk="${1:?_pre_install_unmount: disk device required}"
    local part dev_src

    # Step 1: Detect and unmount any existing partitions on this disk
    local parts_to_unmount
    parts_to_unmount=$(mount | grep "^${disk}" | awk '{print $1}' || true)

    if [[ -n "${parts_to_unmount}" ]]; then
        log_warn "Found existing partitions on ${disk}, unmounting..."
        for part in ${parts_to_unmount}; do
            log_info "  Unmounting ${part}..."
            if ! umount -f "${part}" 2>/dev/null; then
                log_warn "  Failed to unmount ${part} (may not be mounted)"
            fi
        done
    fi

    # Step 2: Close any existing LUKS mappers for this disk
    local mapper_dir="/dev/mapper"
    if [[ -d "${mapper_dir}" ]]; then
        for mapper in "${mapper_dir}"/luks-*; do
            [[ -e "${mapper}" ]] || continue
            dev_src=$(readlink -f "${mapper}" 2>/dev/null || true)
            if [[ -n "${dev_src}" && "${dev_src}" == "${disk}"* ]]; then
                log_warn "  Closing existing LUKS mapper: $(basename "${mapper}")"
                cryptsetup close "$(basename "${mapper}")" 2>/dev/null || true
            fi
        done
    fi

    # Step 3: Deactivate any swap partitions on this disk
    local swap_parts
    swap_parts=$(swapon --show name | grep "^${disk}" | awk '{print $1}' || true)
    if [[ -n "${swap_parts}" ]]; then
        log_warn "Found active swap on ${disk}, deactivating..."
        for part in ${swap_parts}; do
            log_info "  swapoff ${part}..."
            if ! swapoff "${part}" 2>/dev/null; then
                log_warn "  Failed to deactivate swap ${part}"
            fi
        done
    fi

    log_info "Pre-install unmount complete for ${disk}"
}

# Stage 3: Partition & Format
stage_partition() {
    log_info "Stage 3: Partition & Format"

    # Source partitioning module
    # shellcheck source=lib/partitioning.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/partitioning.sh"

    # Reinstall mode: unmount existing partitions before partitioning
    if [[ "${REINSTALL}" == "true" ]]; then
        log_warn "Reinstall mode: unmounting existing partitions on ${TARGET_DISK}..."
        _pre_install_unmount "${TARGET_DISK}"
    fi

    # Reconcile the partition layout with the hardware-detected boot mode.
    # Hardware detection prevails over config: drop partitions the firmware
    # cannot use (e.g. an EFI System Partition on BIOS hardware).
    _reconcile_partitions_for_boot_mode

    # Adjust partition sizes for swap (root partition may need explicit size)
    _adjust_partition_sizes_for_swap

    # Build sfdisk input (no subshell — sets PARTITION_LAYOUT_TEXT directly)
    build_sfdisk_input
    log_info "Generated partition layout:"
    echo "${PARTITION_LAYOUT_TEXT}" | while IFS= read -r line; do
        log_info "  ${line}"
    done

    # Wipe and partition
    wipe_and_partition "${TARGET_DISK}"

    # Format LUKS partitions (creates LUKS header)
    format_luks_partitions

    # Open LUKS partitions (creates mapper devices)
    open_luks_partitions

    # Format partitions (including LUKS mappers as ext4/vfat/etc.)
    format_partitions
    # Format swap partitions (sets SWAP_UUID for fstab)
    format_swap_partitions

    # Mount filesystems
    mount_filesystems

    # Activate swap partitions (must be after mount_filesystems)
    mount_swap_partitions

    log_success "Partitioning and formatting complete"
}

# Stage 4: System Clone
stage_clone() {
    log_info "Stage 4: System Clone"

    # Source clone module
    # shellcheck source=lib/clone.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/clone.sh"

    # Clone the system
    clone_system

    log_success "System clone complete"
}

# Stage 5: Post-Clone Cleanup
stage_cleanup() {
    log_info "Stage 5: Post-Clone Cleanup"

    # Source cleanup module
    # shellcheck source=lib/cleanup.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/cleanup.sh"

    # Run cleanup functions
    remove_live_files "${TARGET_DIR}"
    remove_live_user "${TARGET_DIR}"
    cleanup_packages "${TARGET_DIR}" "${BOOTLOADER}"

    log_success "Post-clone cleanup complete"
}

# Stage 6: Chroot Configuration
stage_chroot() {
    log_info "Stage 6: Chroot Configuration"

    # Source chroot module
    # shellcheck source=lib/chroot_tasks.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/chroot_tasks.sh"

    # Variables shared with sourced module (lib/chroot_tasks.sh).
    # These are read by chroot_tasks.sh when sourced — they share the
    # same process scope, so no explicit parameter passing is needed.
    # shellcheck disable=SC2034
    CHROOT_TARGET_DIR="${TARGET_DIR}"
    # shellcheck disable=SC2034
    CHROOT_HOSTNAME="${HOSTNAME:-voidful}"
    # shellcheck disable=SC2034
    CHROOT_LOCALE="${LOCALE:-en_US.UTF-8}"
    # shellcheck disable=SC2034
    CHROOT_KEYMAP="${KEYMAP:-us}"
    # shellcheck disable=SC2034
    CHROOT_TIMEZONE="${TIMEZONE:-}"
    CHROOT_ISSUE_MESSAGE="${ISSUE_MESSAGE:-}"
    CHROOT_ROOT_PASSWORD="${ROOT_PASS:-}"
    # USER_LOGIN = actual login name (valid username), USERNAME = display/full name
    # Mirrors void-installer's separation of USERLOGIN (login) vs USERNAME (comment)
    CHROOT_USERNAME="${USER_LOGIN:-}"
    CHROOT_USER_FULLNAME="${USERNAME:-}"
    CHROOT_USER_GROUPS="${USER_GROUPS:-wheel}"
    # Create a regular user only when explicitly opted in AND a login name is set.
    CHROOT_CREATE_USER="${CREATE_USER:-no}"
    CHROOT_USER_SHELL="${USER_SHELL:-/bin/bash}"
    # shellcheck disable=SC2034
    CHROOT_USER_PASSWORD="${USER_PASS:-}"
    # shellcheck disable=SC2034
    CHROOT_ENABLED_SERVICES="${ENABLED_SERVICES:-}"
    # shellcheck disable=SC2034
    CHROOT_NETWORK_MODE="${NETWORK_MODE:-dhcp}"
    # shellcheck disable=SC2034
    CHROOT_NETWORK_DEVICE="${NETWORK_DEVICE:-}"
    # shellcheck disable=SC2034
    CHROOT_NETWORK_IP="${NETWORK_IP:-}"
    # shellcheck disable=SC2034
    CHROOT_NETWORK_GATEWAY="${NETWORK_GATEWAY:-}"

    # Shared globals also used by chroot_tasks.sh
    # shellcheck disable=SC2034
    PARTITION_PREFIX="${PARTITION_PREFIX:-}"

    # Run chroot configuration
    configure_chroot

    log_success "Chroot configuration complete"
}

# Stage 7: Teardown
stage_teardown() {
    log_info "Stage 7: Teardown"

    _teardown
    MOUNTS_UNMOUNTED=true

    log_success "Teardown complete"
}

# _teardown()
#
# Unmount filesystems, close LUKS mappers, sync.
# ---------------------------------------------------------------------------
_teardown() {
    # Flush the complete installer log to the target before unmounting.
    # The stage 4 clone only snapshotted the log at clone start; lines from
    # stages 5-6 (cleanup, chroot configuration) were appended to the live log
    # and would otherwise be lost when the system reboots from disk. The
    # target copy from the clone is a strict prefix of the live log, so the
    # replacement loses nothing. The findmnt guard skips the flush on the
    # interruption path when the target was never mounted (avoid writing to a
    # plain host directory).
    if [[ -f "${LOG_FILE}" ]] && findmnt -n -o TARGET "${TARGET_DIR}" >/dev/null 2>&1; then
        if cp "${LOG_FILE}" "${TARGET_DIR}/var/log/voidful.log" 2>/dev/null; then
            log_info "Installer log flushed to target"
        else
            log_warn "Could not copy installer log to target"
        fi
    fi

    log_info "Unmounting filesystems..."
    # Deactivate the swapfile before unmounting/closing LUKS. The swapfile
    # lives on the (LUKS-backed) root filesystem; an active swap holds the
    # LUKS mapper open, so closing it would fail with "still in use".
    if [[ -f "${TARGET_DIR}/swapfile" ]]; then
        swapoff "${TARGET_DIR}/swapfile" 2>/dev/null || true
    fi

    # Unmount nested mount points (children) BEFORE the root. A parent like
    # /mnt must never be unmounted while a sub-mount such as /mnt/boot is
    # still attached, otherwise umount fails with "target is busy".
    # Read /proc/mounts and keep only the mount points that live strictly
    # under ${TARGET_DIR} (i.e. start with ${TARGET_DIR}/). sort -r (reverse
    # lexicographic) puts the deepest mount points first: a nested path is
    # always lexicographically greater than its parent prefix, so a child is
    # always unmounted before its parent.
    local mp
    while read -r mp; do
        [[ -n "$mp" ]] && umount "$mp" 2>/dev/null || true
    done < <(awk -v t="${TARGET_DIR}/" 'index($2, t) == 1 {print $2}' /proc/mounts 2>/dev/null | sort -r)

    # Finally unmount the root mount itself.
    umount "${TARGET_DIR}" 2>/dev/null || true

    # Close LUKS mappers — only those whose backing device is on the target disk.
    # Matches the filter in wipe_and_partition: closing a mapper whose backing
    # device is NOT the target disk would tear down unrelated state on other
    # disks (host-safety guard).
    local mapper_dir="/dev/mapper"
    if [[ -d "${mapper_dir}" ]]; then
        local mapper name dev_src
        for mapper in "${mapper_dir}"/luks-*; do
            [[ -e "${mapper}" ]] || continue
            name=$(basename "${mapper}")
            dev_src=$(readlink -f "${mapper}" 2>/dev/null || true)
            if [[ -n "${dev_src}" && "${dev_src}" == "${TARGET_DISK}"* ]]; then
                cryptsetup close "${name}" 2>/dev/null || true
                log_info "Closed LUKS mapper: ${name}"
            else
                log_info "Skipping LUKS mapper on non-target disk: ${name} (${dev_src:-?})"
            fi
        done
    fi

    # Sync
    sync

    log_info "Teardown complete"
}

# Stage 8: End-Action
stage_end_action() {
    log_info "Stage 8: End-Action (${END_ACTION})"

    case "${END_ACTION}" in
        none)
            log_info "No end-action specified — system left running"
            return 0
            ;;
        shutdown)
            log_info "Shutting down system..."
            # Foreground (not `&`): a backgrounded poweroff lets the installer
            # exit and orphan the shutdown, so the system may never actually
            # power off. poweroff does not return on success.
            poweroff
            ;;
        reboot)
            log_info "Rebooting system..."
            # Foreground (not `&`): same reasoning as shutdown; reboot does not
            # return on success.
            reboot
            ;;
        script)
            if [[ -n "${END_ACTION_SCRIPT:-}" ]]; then
                log_info "Executing end-action script: ${END_ACTION_SCRIPT}"
                bash "${END_ACTION_SCRIPT}"
            else
                log_warn "END_ACTION=script but no script path configured"
            fi
            ;;
        func)
            if declare -f "${END_ACTION_FUNC:-}" &>/dev/null; then
                log_info "Executing end-action function: ${END_ACTION_FUNC}"
                "${END_ACTION_FUNC}"
            else
                log_warn "END_ACTION=func but no function name configured"
            fi
            ;;
        *)
            log_error "Unknown end-action: ${END_ACTION}"
            exit 9
            ;;
    esac

    log_success "End-action triggered: ${END_ACTION}"
}

# ---------------------------------------------------------------------------
# Test mode
# ---------------------------------------------------------------------------
run_test_mode() {
    log_info "=== TEST MODE ==="
    log_info "Generating installation plan without performing any operations..."
    echo ""

    # Source hardware module for boot mode detection
    # shellcheck source=lib/hardware.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/hardware.sh"

    # Show boot mode
    local boot_mode="unknown"
    if [ -d /sys/firmware/efi ]; then
        boot_mode="uefi"
    else
        boot_mode="bios"
    fi
    log_info "Boot mode: ${boot_mode}"

    # Show target disk
    log_info "Target disk: ${TARGET_DISK}"

    # Show config
    if [[ -n "${CONFIG_FILE}" ]]; then
        log_info "Config file: ${CONFIG_FILE}"
    fi

    # Source config module first (defines define_partition, validate_config)
    # shellcheck source=lib/config.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

    # Show partition layout
    if [[ -n "${CONFIG_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
    fi

    # shellcheck source=lib/partitioning.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/partitioning.sh"

    PARTITION_PREFIX="${PARTITION_PREFIX:-}"

    # Mirror the real pipeline (stage_partition): reconcile the layout with the
    # detected boot mode (drop firmware-incompatible partitions, e.g. /boot/efi
    # on BIOS) and adjust sizes for swap, so the plan reflects what will
    # actually be partitioned.
    BOOT_MODE="${boot_mode}"
    _reconcile_partitions_for_boot_mode
    _adjust_partition_sizes_for_swap

    local layout
    layout=$(build_sfdisk_input 2>/dev/null || echo "  [config not loaded]")
    echo "Partition layout:"
    echo "${layout}"
    echo ""

    # Show mount plan
    log_info "Mount plan:"
    local num_partitions="${#PART_MOUNTS[@]}"
    for ((i = 0; i < num_partitions; i++)); do
        log_info "  ${PART_MOUNTS[$i]} -> ${PART_FS[$i]}"
        if [[ "${PART_LUKS[$i]}" == "yes" ]]; then
            log_info "    [LUKS encrypted]"
        fi
    done
    echo ""

    # Show clone command
    log_info "Clone command: tar --one-file-system --xattrs --xattrs-include='*' / -> ${TARGET_DIR}"
    echo ""

    # Show chroot commands
    log_info "Chroot commands:"
    log_info "  chroot ${TARGET_DIR} chown root:root /"
    log_info "  chroot ${TARGET_DIR} chpasswd -c SHA512"
    log_info "  chroot ${TARGET_DIR} dracut --force"
    if [[ "${BOOTLOADER:-grub}" == "grub" ]]; then
        log_info "  chroot ${TARGET_DIR} grub-install"
    else
        log_info "  [bootloader: none - skipping grub-install]"
    fi
    echo ""

    log_success "Test mode complete — no operations were performed"
    exit 0
}

# ---------------------------------------------------------------------------
# Dry-run mode
# ---------------------------------------------------------------------------
run_dry_run() {
    log_info "=== DRY RUN ==="
    log_info "Validating configuration only..."

    # Source config module first (defines define_partition, validate_config)
    # shellcheck source=lib/config.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

    # Source config file (calls define_partition())
    if [[ -n "${CONFIG_FILE}" ]]; then
        if [[ ! -f "${CONFIG_FILE}" ]]; then
            log_error "Configuration file not found: ${CONFIG_FILE}"
            exit 1
        fi
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
    fi

    # CLI arguments always override config file values
    [[ -n "${_CLI_TARGET_DISK:-}" ]] && TARGET_DISK="${_CLI_TARGET_DISK}"
    [[ -n "${_CLI_TARGET_DIR:-}" ]] && TARGET_DIR="${_CLI_TARGET_DIR}"
    [[ -n "${_CLI_END_ACTION:-}" ]] && END_ACTION="${_CLI_END_ACTION}"
    [[ -n "${_CLI_BOOTLOADER:-}" ]] && BOOTLOADER="${_CLI_BOOTLOADER}"

    # Validate
    if validate_config; then
        log_success "Configuration is valid"
        exit 0
    else
        log_error "Configuration validation failed"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    # ---------------------------------------------------------------------------
    # Argument parsing
    # ---------------------------------------------------------------------------
    parse_args "$@"
    # Detect boot mode early so validate_config() has it available.
    # stage_preflight() will re-detect and override if needed.
    if [[ -z "${BOOT_MODE:-}" ]]; then
        BOOT_MODE=$(detect_boot_mode 2>/dev/null || echo "bios")
    fi

    # Log a summary of the finalized configuration for troubleshooting purposes.
    # This helps replicate the command if the installation fails.
    log_info "========================================="
    log_info " INSTALLATION SUMMARY"
    log_info "========================================="
    log_info " Config file:      ${CONFIG_FILE:-Not set}"
    log_info " Target disk:      ${TARGET_DISK:-Not set}"
    log_info " Target directory: ${TARGET_DIR:-Not set}"
    log_info " Bootloader:       ${BOOTLOADER:-Not set}"
    log_info " End action:       ${END_ACTION:-Not set}"
    log_info " Reinstall mode:   ${REINSTALL}"
    log_info " Dry run:          ${DRY_RUN}"
    log_info "========================================="
    log_info ""

    # Test mode: generate plan and exit
    if [[ "${TEST_MODE}" == "true" ]]; then
        run_test_mode
    fi

    # Dry-run mode: validate config and exit
    if [[ "${DRY_RUN}" == "true" ]]; then
        run_dry_run
    fi

    # Full installation pipeline
    log_info "=== voidful ${VERSION} ==="
    log_info "Starting installation..."

    stage_config
    stage_preflight
    # Inject swap partition if configured
    if [[ "${SWAP_TYPE:-}" == "partition" && -n "${SWAP_SIZE:-}" ]]; then
        PART_MOUNTS+=("/swap")
        PART_SIZES+=("${SWAP_SIZE}")
        PART_FS+=("linux-swap")
        PART_LUKS+=("no")
        PART_SUBVOLS+=("")
        log_info "Swap partition: ${SWAP_SIZE} (type=linux-swap)"
    fi

    # The pipeline is about to start creating state (partitions/mounts).
    # From here on, the EXIT/signal traps must run teardown on exit.
    INSTALL_STARTED=true

    stage_partition
    stage_clone
    stage_cleanup
    # Prepare chroot environment variables
    # shellcheck disable=SC2034
    CHROOT_NETWORK_IP="${NETWORK_IP:-}"
    # shellcheck disable=SC2034
    CHROOT_NETWORK_GATEWAY="${NETWORK_GATEWAY:-}"
    # shellcheck disable=SC2034
    CHROOT_BOOT_MODE="${BOOT_MODE:-uefi}"
    # shellcheck disable=SC2034
    CHROOT_BOOTLOADER="${BOOTLOADER:-grub}"

    stage_chroot
    stage_teardown
    stage_end_action

    log_success "Installation complete!"
}

main "$@"
