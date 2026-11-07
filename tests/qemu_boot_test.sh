#!/usr/bin/env bash
set -euo pipefail

# qemu_boot_test.sh — Automated end-to-end boot test using QEMU/libvirt.
#
# Usage: ./qemu_boot_test.sh --iso /path/to/void-live-*.iso [--config TEMPLATE]
#
# What it does:
#   1. Creates a VM from the live ISO + virtual disk
#   2. Waits for the VM to boot and get an IP
#   3. Waits for SSH to be available
#   4. Detects VM hardware (disk device, UEFI/BIOS)
#   5. Generates an adapted config file from a template
#   6. Copies install.sh, lib/, and the config into the VM
#   7. Runs the installer and monitors output
#   8. Boot verification: reboots the VM into the installed system (disk-first
#      boot) and confirms it is reachable over SSH (optionally runs
#      verify_installed_system.sh). Use --skip-verify-boot to skip this.
#   9. Leaves the VM running for log inspection (no auto-destroy)
#
# Prerequisites:
#   - libvirt (virsh, virt-install)
#   - sshpass
#   - A Void Linux live ISO

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_DIR}/lib/logging.sh"
LOG_FILE="/tmp/voidful-test.log"

# ---------------------------------------------------------------------------
# Hardcoded defaults
# ---------------------------------------------------------------------------
ISO=""
VM_NAME="voidful-test"
SERIAL_LOG="/tmp/voidful-serial-${VM_NAME}.log"
BOOT_VERIFY_FAILED=0
DISK_FILE="${PROJECT_DIR}/.voidful-test-disk.qcow2"
DISK_SIZE="15G"
MEMORY="4096"
VCPUS="4"
CPU_ARCH="x86_64"       # x86_64 or i686
FIRMWARE="uefi"         # bios or uefi
OVMF_PATH=""            # resolved OVMF firmware path (set during validation)
DISPLAY_TYPE="none"     # none, vnc, spice, or sdl
VM_GUEST_IP=""
SSH_USER="anon"
SSH_PASS="voidlinux"
SSH_TIMEOUT=5
# 1440s total: installed systems normally come up in ~190-300s (measured across
# BIOS and UEFI runs), but under host CPU contention (multiple QEMU instances)
# a fresh cold boot has been observed to exceed 360s, and one BIOS run on a
# recreated domain did not expose sshd for ~14 minutes after start (the guest
# kernel finished in seconds; the delay was in the post-recreation
# network/SSH visibility). 180s/360s/720s were all false-negative windows.
SSH_RETRIES=288
REINSTALL=false
NET_DOMAIN="default"
VIRSH_URI="qemu:///system"
CONFIG_TEMPLATE="${PROJECT_DIR}/configs/example-uefi.conf"
REMOTE_CONFIG_NAME="voidful.conf"
REMOTE_INSTALLER_DIR="/home/${SSH_USER}/voidful"
INSTALL_RUN_COUNT=0
DESTROY_ON_SUCCESS=false
VERIFY_BOOT=true
LUKS_PASSPHRASE="${LUKS_PASSPHRASE:-}"
BOOT_USER=""
BOOT_PASS=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --iso)
                ISO="${2:?--iso requires a path}"
                shift 2
                ;;
            --config)
                CONFIG_TEMPLATE="${2:?--config requires a path to template}"
                shift 2
                ;;
            --reinstall)
                REINSTALL=true
                shift
                ;;
            --destroy-vm)
                DESTROY_ON_SUCCESS=true
                shift
                ;;

            --skip-verify-boot)
                VERIFY_BOOT=false
                shift
                ;;
            --cpu-arch)
                CPU_ARCH="${2:?--cpu-arch requires x86_64 or i686}"
                if [[ "${CPU_ARCH}" != "x86_64" && "${CPU_ARCH}" != "i686" ]]; then
                    log_error "Invalid CPU arch: ${CPU_ARCH} (must be x86_64 or i686)"
                    exit 1
                fi
                shift 2
                ;;
            --firmware)
                FIRMWARE="${2:?--firmware requires bios or uefi}"
                if [[ "${FIRMWARE}" != "bios" && "${FIRMWARE}" != "uefi" ]]; then
                    log_error "Invalid firmware: ${FIRMWARE} (must be bios or uefi)"
                    exit 1
                fi
                shift 2
                ;;
            --display)
                DISPLAY_TYPE="${2:?--display requires a value (none, vnc, spice, sdl)}"
                if [[ "${DISPLAY_TYPE}" != "none" && "${DISPLAY_TYPE}" != "vnc" && "${DISPLAY_TYPE}" != "spice" && "${DISPLAY_TYPE}" != "sdl" ]]; then
                    log_error "Invalid display: ${DISPLAY_TYPE} (must be none, vnc, spice, or sdl)"
                    exit 1
                fi
                shift 2
                ;;

            --luks-passphrase)
                LUKS_PASSPHRASE="${2:?--luks-passphrase requires a value}"
                shift 2
                ;;

            --help)
                print_help
                exit 0
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
voidful QEMU Boot Test (libvirt)

Usage: $(basename "$0") [OPTIONS]

Required:
  --iso FILE               Path to Void Linux live ISO (skip if --reinstall)

Options:
  --config FILE            Config template (default: configs/example-uefi.conf)
  --reinstall              Skip VM setup, re-run install on existing VM (passes --reinstall to installer)
  --cpu-arch ARCH          CPU architecture: x86_64 (default) or i686
  --firmware FW            Firmware: uefi (default) or bios
  --destroy-vm            Destroy VM and disk only if installation succeeds
  --display TYPE         VM display: none (default), vnc, spice, or sdl
  --luks-passphrase PASS LUKS passphrase (or set LUKS_PASSPHRASE env var)
  --skip-verify-boot     Do not reboot the VM into the installed system after a
                        successful install (boot verification is on by default)

Example:
  ./qemu_boot_test.sh --iso /home/jhuss/Software/ISOs/void-live-x86_64-20250202-base.iso
  ./qemu_boot_test.sh --iso /path/to/iso --config configs/example-uefi.conf
  ./qemu_boot_test.sh --reinstall
  ./qemu_boot_test.sh --iso /path/to/iso --firmware uefi --cpu-arch x86_64
  ./qemu_boot_test.sh --iso /path/to/iso --destroy-vm
  ./qemu_boot_test.sh --iso /path/to/iso --display vnc

  ./qemu_boot_test.sh --iso /path/to/iso --cpu-arch i686 --firmware bios
EOF
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate_prerequisites() {
    if ! command -v virsh &>/dev/null; then
        log_error "virsh not found. Install libvirt."
        exit 1
    fi

    if ! command -v virt-install &>/dev/null; then
        log_error "virt-install not found. Install libvirt-install."
        exit 1
    fi

    if ! command -v sshpass &>/dev/null; then
        log_error "sshpass not found. Install with: xbps-install sshpass"
        exit 1
    fi

    if [[ "${REINSTALL}" != "true" ]]; then
        if [[ -z "${ISO}" ]]; then
            log_error "--iso is required (or use --reinstall to skip VM setup)"
            exit 1
        fi
        if [[ ! -f "${ISO}" ]]; then
            log_error "ISO not found: ${ISO}"
            exit 1
        fi
    fi

    if [[ ! -f "${CONFIG_TEMPLATE}" ]]; then
        log_error "Config template not found: ${CONFIG_TEMPLATE}"
        exit 1
    fi

    # UEFI requires OVMF firmware files
    if [[ "${FIRMWARE}" == "uefi" ]]; then
        local ovmf_path=""
        # Try common paths for OVMF firmware
        for candidate in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/edk2-x86_64-code.fd; do
            if [[ -f "${candidate}" ]]; then
                ovmf_path="${candidate}"
                break
            fi
        done
        if [[ -z "${ovmf_path}" ]]; then
            log_error "UEFI firmware not found"
            log_error "Install with: xbps-install edk2-ovmf (or edk2-x86_64-code.fd package)"
            exit 1
        fi
        # Store for create_vm to use
        OVMF_PATH="${ovmf_path}"
    fi

    # i686 CPU + UEFI is not a valid combination
    if [[ "${CPU_ARCH}" == "i686" && "${FIRMWARE}" == "uefi" ]]; then
        log_error "Cannot combine i686 CPU with UEFI firmware (UEFI requires x86_64)"
        exit 1
    fi
    # SDL display requires an X11 display on the host
    if [[ "${DISPLAY_TYPE}" == "sdl" && -z "${DISPLAY:-}" ]]; then
        log_error "SDL display requires an X11 display on the host (DISPLAY is not set)"
        exit 1
    fi

    log_success "Prerequisites validated"
}

# ---------------------------------------------------------------------------
# Disk setup
# ---------------------------------------------------------------------------
setup_disk() {
    if [[ -f "${DISK_FILE}" ]]; then
        log_warn "Existing disk found: ${DISK_FILE}"
        rm -f "${DISK_FILE}"
    fi

    log_info "Creating virtual disk: ${DISK_FILE} (${DISK_SIZE})"
    qemu-img create -f qcow2 "${DISK_FILE}" "${DISK_SIZE}"
    log_success "Virtual disk ready"
}

# ---------------------------------------------------------------------------
# VM management
# ---------------------------------------------------------------------------
# _ensure_serial_log
#
# Rewires the VM's serial console to a world-readable log file so the first
# boot of the installed system can be inspected without restarting the VM
# (a restart would destroy the first-boot evidence). No-op if the domain
# already has a file serial, has no pty serial, or the XML is unavailable.
# Safe: `virsh define` on a running domain only updates the persistent
# config; the rewire takes effect on the next `virsh start` (verify_boot).
_ensure_serial_log() {
    if virsh --connect "${VIRSH_URI}" domstate "${VM_NAME}" &>/dev/null 2>&1; then
        local serial_xml tmp_xml
        serial_xml=$(virsh --connect "${VIRSH_URI}" dumpxml "${VM_NAME}" 2>/dev/null) || return 0
        if printf '%s' "${serial_xml}" | grep -q "<serial type='file'"; then
            return 0
        fi
        if ! printf '%s' "${serial_xml}" | grep -q "<serial type='pty'>"; then
            return 0
        fi
        # Pre-create the serial file (world-readable) so QEMU reuses it on the
        # next start instead of creating a root-owned one.
        touch "${SERIAL_LOG}" 2>/dev/null || true
        chmod 666 "${SERIAL_LOG}" 2>/dev/null || true
        # libvirt dumpxml emits the pty serial/console as multi-line blocks
        # (e.g. <serial type='pty'> ... <source path='/dev/pts/N'/> ... </serial>),
        # so replace them line-by-line with a state machine: swap the pty serial
        # block for a single-line file serial, and drop the pty console block.
        tmp_xml="/tmp/vm-serial-xml.$$"
        printf '%s\n' "${serial_xml}" \
            | awk -v sp="${SERIAL_LOG}" '
                /<serial type=.pty./ {
                    print "    <serial type='"'"'file'"'"'><source path='"'"'" sp "'"'"'/></serial>"
                    in_serial = 1
                    next
                }
                in_serial { if (/<\/serial>/) in_serial = 0; next }
                /<console type=.pty./ { in_console = 1; next }
                in_console { if (/<\/console>/) in_console = 0; next }
                { print }
            ' > "${tmp_xml}"
        if grep -q "<domain" "${tmp_xml}" && grep -q "<serial type='file'" "${tmp_xml}"; then
            if virsh --connect "${VIRSH_URI}" define "${tmp_xml}" &>/dev/null; then
                log_info "Serial console rewired to ${SERIAL_LOG}"
            else
                log_warn "Serial rewire define failed; VM keeps its pty serial"
            fi
        fi
        rm -f "${tmp_xml}"
    fi
}

destroy_vm() {
    if virsh --connect "${VIRSH_URI}" domstate "${VM_NAME}" &>/dev/null 2>&1; then
        log_info "Destroying VM: ${VM_NAME}"
        virsh --connect "${VIRSH_URI}" destroy "${VM_NAME}" 2>/dev/null || true
        sleep 2
        virsh --connect "${VIRSH_URI}" undefine "${VM_NAME}" --nvram 2>/dev/null || true
        virsh --connect "${VIRSH_URI}" undefine "${VM_NAME}" 2>/dev/null || true
    fi
}

create_vm() {
    log_info "Booting live ISO from ${ISO} (firmware=${FIRMWARE}, cpu=${CPU_ARCH}, display=${DISPLAY_TYPE})..."
    local virt_install_output
    local -a extra_args=()

    # CPU model — host-passthrough for x86_64, core2duo for i686
    if [[ "${CPU_ARCH}" == "x86_64" ]]; then
        extra_args+=(--cpu host-passthrough)
    else
        extra_args+=(--cpu core2duo)
    fi

    # Boot: uefi needs q35 machine + uefi boot flag, bios uses default
    # shellcheck disable=SC2054
    if [[ "${FIRMWARE}" == "uefi" ]]; then
        extra_args+=(--machine q35 --boot uefi,menu=on)
    else
        extra_args+=(--boot cdrom)
    fi


    virt_install_output=$(virt-install --connect "${VIRSH_URI}" \
        --name "${VM_NAME}" \
        --memory "${MEMORY}" \
        --vcpus "${VCPUS}" \
        --disk "path=${DISK_FILE},format=qcow2,bus=virtio" \
        --disk "path=${ISO},device=cdrom" \
        --network "network=${NET_DOMAIN}" \
        --graphics "${DISPLAY_TYPE}" \
        --noautoconsole \
        --os-variant generic \
        "${extra_args[@]}" \
        --wait 0 \
        2>&1) || {
            log_error "VM creation failed: ${virt_install_output}"
            return 1
        }
    log_info "VM started: ${virt_install_output}"
}

get_vm_ip() {
    local retries=30
    local attempt=0

    while [[ ${attempt} -lt ${retries} ]]; do
        # Require a LIVE ARP response (non-empty MAC column). virsh domifaddr
        # falls back to the dnsmasq lease table when ARP fails; right after a
        # VM restart (verify_boot recreates the domain reusing the same MAC)
        # the lease table still holds the pre-restart lease, which may be
        # served to a different (leftover) VM. The stale IP would then make
        # the harness SSH to the wrong machine and its sshd rejects the
        # installed-system credentials. The lease entry shows a "-" MAC.
        VM_GUEST_IP=$(virsh --connect "${VIRSH_URI}" domifaddr "${VM_NAME}" 2>/dev/null \
            | awk 'NF == 4 && $3 == "ipv4" && $2 != "-" { split($4, _a, "/"); print _a[1]; exit }' || true)
        if [[ -n "${VM_GUEST_IP}" ]]; then
            log_success "VM IP detected: ${VM_GUEST_IP}"
            return 0
        fi
        attempt=$((attempt + 1))
        if (( attempt % 5 == 0 )); then
            log_info "Waiting for VM IP... (${attempt}/${retries})"
        fi
        sleep 5
    done

    log_error "Could not detect VM IP after ${retries} attempts"
    return 1
}

_wait_for_sshd_ready() {
    local ip="${1}"
    local max_wait=30
    local waited=0

    while [[ ${waited} -lt ${max_wait} ]]; do
        if bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

wait_for_ssh() {
    local attempt=0
    local total_wait=0

    log_info "Waiting for SSH on ${VM_GUEST_IP} (max: $((SSH_TIMEOUT * SSH_RETRIES))s)..."

    while [[ ${attempt} -lt ${SSH_RETRIES} ]]; do
        if sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 "${SSH_USER}@${VM_GUEST_IP}" "echo ok" 2>/dev/null; then
            log_success "SSH available on ${VM_GUEST_IP} after ${total_wait}s"
            return 0
        fi
        attempt=$((attempt + 1))
        total_wait=$((total_wait + SSH_TIMEOUT))
        if (( attempt % 6 == 0 )); then
            log_info "Still waiting for SSH... (${attempt}/${SSH_RETRIES}, ${total_wait}s elapsed)"
        fi
        sleep "${SSH_TIMEOUT}"
    done

    log_error "SSH not available after $((SSH_TIMEOUT * SSH_RETRIES))s (${SSH_RETRIES} retries)"
    return 1
}

# ---------------------------------------------------------------------------
# Copy installer files to VM
# ---------------------------------------------------------------------------
copy_files() {
    log_info "Copying installer files to VM..."

    # Create remote directory
    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${VM_GUEST_IP}" "mkdir -p '${REMOTE_INSTALLER_DIR}'" 2>/dev/null || {
        log_error "Failed to create remote directory"
        return 1
    }

    # Copy install.sh
    log_info "Copying install.sh..."
    sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no \
        "${PROJECT_DIR}/install.sh" "${SSH_USER}@${VM_GUEST_IP}:${REMOTE_INSTALLER_DIR}/" 2>/dev/null || {
        log_error "Failed to copy install.sh"
        return 1
    }

    # Copy lib/ directory
    log_info "Copying lib/ directory..."
    sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no -r \
        "${PROJECT_DIR}/lib/" "${SSH_USER}@${VM_GUEST_IP}:${REMOTE_INSTALLER_DIR}/" 2>/dev/null || {
        log_error "Failed to copy lib/"
        return 1
    }

    log_success "Core installer files copied to ${SSH_USER}@${VM_GUEST_IP}:${REMOTE_INSTALLER_DIR}/"
}

# ---------------------------------------------------------------------------
# Copy a single config file to VM
# ---------------------------------------------------------------------------
copy_config() {
    local config_src="${1}"
    local config_dest="${REMOTE_INSTALLER_DIR}/${REMOTE_CONFIG_NAME}"

    log_info "Copying config: ${config_src} -> ${config_dest}"
    sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no \
        "${config_src}" "${SSH_USER}@${VM_GUEST_IP}:${config_dest}" 2>/dev/null || {
        log_error "Failed to copy config file"
        return 1
    }

    log_success "Config copied: ${config_dest}"
}

# ---------------------------------------------------------------------------
# VM Hardware Detection
# ---------------------------------------------------------------------------
detect_vm_hardware() {
    log_info "Detecting VM hardware..."

    # Detect disk device via lsblk (filter for disk devices, get first)
    VM_DISK=$(sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${VM_GUEST_IP}" "lsblk -dn -o NAME,TYPE 2>/dev/null | grep disk | awk '{print \$1}' | head -1 | tr -d '\r\n'") || {
        log_error "Failed to detect disk device"
        return 1
    }

    # Full device path (e.g., /dev/vda)
    VM_DISK_PATH="/dev/${VM_DISK}"
    log_info "Detected disk device: ${VM_DISK_PATH}"

    # Detect boot mode (UEFI = /sys/firmware/efi exists)
    VM_BOOT_MODE=$(sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${VM_GUEST_IP}" "if [ -e /sys/firmware/efi/systab ]; then echo uefi; else echo bios; fi") || {
        log_error "Failed to detect boot mode"
        return 1
    }
    log_info "Detected boot mode: ${VM_BOOT_MODE}"

    # Detect architecture
    VM_ARCH=$(sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${VM_GUEST_IP}" "xbps-uhelper arch 2>/dev/null || uname -m") || {
        log_warn "Could not detect architecture, defaulting to x86_64"
        VM_ARCH="x86_64"
    }
    log_info "Detected architecture: ${VM_ARCH}"
}

# ---------------------------------------------------------------------------
# Sudo Verification
# ---------------------------------------------------------------------------
check_sudo() {
    log_info "Verifying sudo access..."
    if sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${VM_GUEST_IP}" "sudo echo sudo_ok" 2>/dev/null | grep -q "sudo_ok"; then
        log_success "Sudo access verified"
        return 0
    else
        log_error "Sudo access NOT available for user '${SSH_USER}'"
        log_error "The installer requires root privileges. Fix sudo config in the VM."
        return 1
    fi
}
# ---------------------------------------------------------------------------
# Display Info
# ---------------------------------------------------------------------------
print_display_info() {
    local display_info
    display_info=$(virsh --connect "${VIRSH_URI}" domdisplay "${VM_NAME}" 2>/dev/null | head -1 || true)
    if [[ -n "${display_info}" ]]; then
        log_success " Display     : ${display_info}"
    fi
}

# ---------------------------------------------------------------------------
# Config Adaptation
# ---------------------------------------------------------------------------
generate_config() {
    local template="${1}"
    local disk_path="${2}"
    local boot_mode="${3}"
    local output_path="${4}"

    log_info "Generating config from template: ${template}"
    log_info "  Disk: ${disk_path}, Boot mode: ${boot_mode}"

    # Start with a copy of the template
    cp "${template}" "${output_path}"

    log_info "Applying config adaptations: Disk=${disk_path}, Mode=${boot_mode}"

    # Replace TARGET_DISK definition ONLY if it's at the start of a line.
    # This prevents corrupting comments or other parameters containing 'TARGET_DISK'.
    if grep -q "^TARGET_DISK=" "${output_path}"; then
        sed -i "s|^TARGET_DISK=.*|TARGET_DISK=\"${disk_path}\"|g" "${output_path}"
    else
        # If not found at start of line, prepend it
        sed -i "1i TARGET_DISK=\"${disk_path}\"" "${output_path}"
    fi

    # If BIOS, remove EFI partition block (multi-line define_partition)
    if [[ "${boot_mode}" == "bios" ]]; then
        # Remove define_partition blocks containing /boot/efi (handles backslash continuations)
        local tmp_file="${output_path}.tmp"
        awk '
            BEGIN { skip = 0; buf = "" }
            /^define_partition/ {
                buf = $0
                while ($0 ~ /\\$/) {
                    getline
                    buf = buf "\n" $0
                }
                if (buf ~ /\/boot\/efi/) {
                    skip = 1
                } else {
                    if (!skip) print buf
                }
                skip = 0
                next
            }
            { if (!skip) print }
        ' "${output_path}" > "${tmp_file}" && mv "${tmp_file}" "${output_path}"

        # Also remove EFI-related comments
        sed -i '/EFI System Partition/d' "${output_path}"
        sed -i '/EFI Partition/d' "${output_path}"

        log_info "BIOS mode: EFI partition block removed from config"
    fi

    # Set END_ACTION to "none" so the VM stays running after install
    sed -i 's|^END_ACTION=.*|END_ACTION="none"|' "${output_path}"

    log_success "Config generated successfully: ${output_path}"
}

# ---------------------------------------------------------------------------
# Remote Log Management
# ---------------------------------------------------------------------------
clear_remote_logs() {
    log_info "Clearing remote log file..."
    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${VM_GUEST_IP}" "sudo rm -f /var/log/voidful.log 2>/dev/null; true" || true
    log_info "Remote log cleared"
}

# ---------------------------------------------------------------------------
# Installation Execution
# ---------------------------------------------------------------------------
run_installation() {
    local config_remote="${1}"
    INSTALL_RUN_COUNT=$((INSTALL_RUN_COUNT + 1))

    log_info "========================================="
    log_info " INSTALLATION RUN #${INSTALL_RUN_COUNT}"
    log_info "========================================="

    # Clear old logs before each run
    clear_remote_logs

    # Build the install command using bash -c with positional args for safe quoting.
    # Pattern: bash -c 'script' _ dir config → $0=_ $1=dir $2=config
    # This avoids the quoting trap of embedding variables inside single quotes
    # within a double-quoted string (single quotes become literal chars, not delimiters).
    local install_extra=""
    [[ "${REINSTALL}" == "true" ]] && install_extra=" --reinstall"

    # Write the LUKS passphrase to a keyfile on the VM, only when a passphrase
    # is provided. Use printf (NOT echo) so NO trailing newline is added: the
    # keyfile bytes must match exactly what the installer writes to LUKS slot 0
    # and what crypttab reads at boot. When no passphrase is set, do not inject
    # LUKS_KEYFILE (no LUKS / interactive mode).
    local install_prefix="sudo"
    if [[ -n "${LUKS_PASSPHRASE}" ]]; then
        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
            "${SSH_USER}@${VM_GUEST_IP}" \
            "printf '%s' '${LUKS_PASSPHRASE}' | sudo tee /tmp/.voidful-luks-key > /dev/null && sudo chmod 600 /tmp/.voidful-luks-key"
        install_prefix="sudo LUKS_KEYFILE=/tmp/.voidful-luks-key"
    fi

    local install_cmd="${install_prefix} bash -c 'chmod +x \"\$1\"/install.sh && cd \"\$1\" && bash install.sh --config \"\$2\" --end-action none${install_extra}' _ '${REMOTE_INSTALLER_DIR}' '${config_remote}' 2>&1"

    # Execute the installation
    log_info "Running installer on VM..."
    local install_output
    local install_exit_code=0
    set +e
    install_output=$(sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${VM_GUEST_IP}" "${install_cmd}") || install_exit_code=$?
    set -e

    if [[ ${install_exit_code} -ne 0 ]]; then
        log_error "Installer exited with code: ${install_exit_code}"
        echo "--- INSTALLER OUTPUT ---"
        echo "${install_output}"
        echo "--- END OUTPUT ---"
        return 1
    fi

    # Show the installer output
    echo "--- INSTALLER OUTPUT ---"
    echo "${install_output}"
    echo "--- END OUTPUT ---"

    # Check for success indicators in output
    if echo "${install_output}" | grep -q "Installation complete"; then
        log_success "Installation completed successfully (run #${INSTALL_RUN_COUNT})"
        return 0
    elif echo "${install_output}" | grep -q "Installation interrupted"; then
        log_error "Installation was interrupted (run #${INSTALL_RUN_COUNT})"
        return 1
    else
        log_warn "Could not determine installation status from output (run #${INSTALL_RUN_COUNT})"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Log Inspection
# ---------------------------------------------------------------------------
check_install_logs() {
    log_info "Inspecting remote logs..."

    # Check if log file exists
    local log_exists
    log_exists=$(sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${VM_GUEST_IP}" "test -f /var/log/voidful.log && echo yes || echo no" 2>/dev/null || echo "no")

    if [[ "${log_exists}" == "yes" ]]; then
        echo ""
        echo "--- LOG FILE: /var/log/voidful.log ---"
        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
            "${SSH_USER}@${VM_GUEST_IP}" "cat /var/log/voidful.log" || true
        echo "--- END LOG ---"
    else
        log_warn "Log file /var/log/voidful.log not found on VM"
    fi

    # Check if target disk was partitioned
    local disk_check
    disk_check=$(sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${VM_GUEST_IP}" "lsblk ${VM_DISK_PATH} 2>/dev/null || echo 'lsblk failed'" || true)
    echo ""
    echo "--- DISK LAYOUT (${VM_DISK_PATH}) ---"
    echo "${disk_check}"
    echo "--- END DISK LAYOUT ---"
}

# ---------------------------------------------------------------------------
# Boot Verification (reboot into the installed system)
# ---------------------------------------------------------------------------
# The live-ISO user (anon) is removed by the installer, so after reboot we must
# log in with the created user (or root). The harness does not set USER_PASS /
# ROOT_PASS env vars, so the values in the generated config are the real ones.
extract_install_credentials() {
    local config="${1}"
    BOOT_USER=$(awk -F'"' '/^USER_LOGIN=/{print $2; exit}' "${config}" 2>/dev/null || true)
    if [[ -n "${BOOT_USER}" ]]; then
        BOOT_PASS=$(awk -F'"' '/^USER_PASS=/{print $2; exit}' "${config}" 2>/dev/null || true)
    else
        BOOT_USER="root"
        BOOT_PASS=$(awk -F'"' '/^ROOT_PASS=/{print $2; exit}' "${config}" 2>/dev/null || true)
    fi
    if [[ -z "${BOOT_PASS}" ]]; then
        log_warn "Empty password for ${BOOT_USER}; defaulting to 'changeme'"
        BOOT_PASS="changeme"
    fi
    log_info "Installed-system login user: ${BOOT_USER}"
}

# Reboot the VM into the installed system and verify it comes up.
#
# SAFETY: only `virsh shutdown/destroy/start/define` are used. The ISO is a
# cdrom device and is never touched or deleted; the root qcow2 disk is the
# installed system.
verify_boot() {
    log_info "========================================="
    log_info " BOOT VERIFICATION (reboot into installed system)"
    log_info "========================================="

    # Power off the live-ISO session (graceful, fallback to force)
    virsh --connect "${VIRSH_URI}" shutdown "${VM_NAME}" 2>/dev/null || \
        virsh --connect "${VIRSH_URI}" destroy "${VM_NAME}" 2>/dev/null || true
    sleep 3

    local boot_xml boot_xml_file
    boot_xml=$(virsh --connect "${VIRSH_URI}" dumpxml "${VM_NAME}" 2>/dev/null) || \
        log_warn "Could not read domain XML before boot verification"

    # BIOS: RECREATE the domain (undefine + define + start) instead of a plain
    # shutdown + start. The recreated XML must declare the disk format
    # explicitly (<driver type='qcow2'/>): without it, libvirt/QEMU treats the
    # .qcow2 file as a RAW image, SeaBIOS reads the qcow2 container header
    # instead of the MBR and reports "not a bootable disk" (the installed
    # GRUB never loads). The undefine is done WITHOUT --remove-all-storage,
    # so the disk and ISO files are always preserved.
    # UEFI: keep the existing domain — OVMF NVRAM remembers the boot entry,
    # and the <boot> XML edit below is harmless (SeaBIOS-style no-op for OVMF).
    if [[ "${FIRMWARE}" != "uefi" ]]; then
        log_info "Recreating VM domain for BIOS boot verification..."
        local mac_addr fresh_xml_file
        mac_addr=$(grep -oP "mac address='\K[^']+" <<<"${boot_xml}" | head -1 || true)
        fresh_xml_file=$(mktemp)
        # shellcheck disable=SC2016
        printf '%s\n' \
            "<domain type='kvm'>" \
            "  <name>${VM_NAME}</name>" \
            "  <memory unit='MiB'>${MEMORY}</memory>" \
            "  <currentMemory unit='MiB'>${MEMORY}</currentMemory>" \
            "  <vcpu placement='static'>${VCPUS}</vcpu>" \
            "  <os>" \
            "    <type arch='${CPU_ARCH}' machine='pc'>hvm</type>" \
            "    <boot dev='hd'/>" \
            "  </os>" \
            "$( [[ "${CPU_ARCH}" == "x86_64" ]] \
                && printf "%s" "  <cpu mode='host-passthrough' check='none'/>" \
                || printf "%s\n" "  <cpu mode='custom' match='exact'>" "    <model fallback='forbid' id='core2duo'/>" "  </cpu>" )" \
            "  <devices>" \
            "    <disk type='file' device='disk'>" \
            "      <driver name='qemu' type='qcow2'/>" \
            "      <source file='${DISK_FILE}'/>" \
            "      <target dev='vda' bus='virtio'/>" \
            "    </disk>" \
            "    <controller type='pci' index='0' model='pci-root'/>" \
            "    <interface type='network'>" \
            "${mac_addr:+      <mac address='${mac_addr}'/>}" \
            "      <source network='${NET_DOMAIN}'/>" \
            "      <model type='virtio'/>" \
            "    </interface>" \
            "    <serial type='file'>" \
            "      <source path='${SERIAL_LOG}'/>" \
            "      <target port='0'/>" \
            "    </serial>" \
            "  </devices>" \
            "</domain>" >"${fresh_xml_file}"
        if ! virsh --connect "${VIRSH_URI}" undefine "${VM_NAME}" 2>/dev/null; then
            log_error "Boot verification: failed to undefine VM domain"
            rm -f "${fresh_xml_file}"
            return 1
        fi
        if ! virsh --connect "${VIRSH_URI}" define "${fresh_xml_file}" 2>/dev/null; then
            log_error "Boot verification: failed to define fresh VM domain"
            rm -f "${fresh_xml_file}"
            return 1
        fi
        rm -f "${fresh_xml_file}"
        log_info "VM domain recreated (fresh QEMU state, disk-first, no ISO cdrom)"
    else
        # UEFI: set disk-first in the domain XML (harmless for OVMF, whose
        # NVRAM remembers boot entries; kept for SeaBIOS-style tooling).
        if grep -q "<boot dev='hd'" <<<"${boot_xml}"; then
            log_info "Boot order already disk-first"
        elif grep -q "<boot dev='cdrom'" <<<"${boot_xml}"; then
            boot_xml_file=$(mktemp)
            # sed (not ${var/pat/repl}): the XML element contains '/', which the
            # expansion syntax cannot express without fragile escaping.
            # shellcheck disable=SC2001
            sed "s|<boot dev='cdrom'/>|<boot dev='hd'/>|" <<<"${boot_xml}" >"${boot_xml_file}"
            if virsh --connect "${VIRSH_URI}" define "${boot_xml_file}" >/dev/null; then
                log_info "Boot order set to disk-first"
            else
                log_warn "Could not set disk-first boot order; relying on NVRAM boot entries"
            fi
            rm -f "${boot_xml_file}"
        else
            log_warn "No <boot> element in domain XML; relying on NVRAM boot entries"
        fi
    fi

    # Boot the VM (disk-first)
    if ! virsh --connect "${VIRSH_URI}" start "${VM_NAME}" 2>/dev/null; then
        log_error "Boot verification: failed to start VM"
        return 1
    fi
    sleep 5

    # Re-detect the IP (it may change after reboot)
    if ! get_vm_ip; then
        log_error "Boot verification FAILED: VM did not get an IP after reboot"
        return 1
    fi

    # Wait for SSH with the installed-system credentials
    log_info "Waiting for SSH on installed system (${BOOT_USER}@${VM_GUEST_IP})..."
    local attempt=0
    local total_wait=0
    while [[ ${attempt} -lt ${SSH_RETRIES} ]]; do
        # Re-poll the IP each iteration: the first detection right after the
        # domain restart may be a stale dnsmasq lease (same MAC, live-ISO
        # phase); if the guest's actual lease differs, follow the new IP.
        local re_ip
        re_ip=$(virsh --connect "${VIRSH_URI}" domifaddr "${VM_NAME}" 2>/dev/null \
            | awk 'NF == 4 && $3 == "ipv4" && $2 != "-" { split($4, _a, "/"); print _a[1]; exit }' || true)
        if [[ -n "${re_ip}" && "${re_ip}" != "${VM_GUEST_IP}" ]]; then
            log_info "Guest IP changed: ${VM_GUEST_IP} -> ${re_ip}"
            VM_GUEST_IP="${re_ip}"
        fi
        if sshpass -p "${BOOT_PASS}" ssh -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 "${BOOT_USER}@${VM_GUEST_IP}" "echo ok" 2>/dev/null; then
            log_success "Installed system SSH available after ${total_wait}s"
            break
        fi
        attempt=$((attempt + 1))
        total_wait=$((total_wait + SSH_TIMEOUT))
        if (( attempt % 6 == 0 )); then
            log_info "Still waiting for installed-system SSH... (${attempt}/${SSH_RETRIES}, ${total_wait}s elapsed)"
        fi
        sleep "${SSH_TIMEOUT}"
    done

    if [[ ${attempt} -ge ${SSH_RETRIES} ]]; then
        log_error "Boot verification FAILED: installed system not reachable after $((SSH_TIMEOUT * SSH_RETRIES))s"
        return 1
    fi

    # Sanity check: a successful login as ${BOOT_USER} already proves the
    # installed system booted (the live-ISO 'anon' user no longer exists).
    log_info "Running post-boot sanity checks..."
    local sanity
    sanity=$(sshpass -p "${BOOT_PASS}" ssh -o StrictHostKeyChecking=no \
        "${BOOT_USER}@${VM_GUEST_IP}" \
        "findmnt -no TARGET / >/dev/null 2>&1 && echo 'rootfs:mounted'; echo \"hostname:$(hostname)\"; if [ -e /sys/firmware/efi/systab ]; then echo 'firmware:uefi'; else echo 'firmware:bios'; fi" 2>/dev/null || true)
    echo "--- POST-BOOT SANITY ---"
    echo "${sanity}"
    echo "--- END SANITY ---"

    # Extract TIMEZONE from the generated config (if the template set one)
    # so the checklist can verify /etc/localtime matches the installed value.
    local verify_tz=""
    verify_tz=$(sed -n 's/^TIMEZONE=//p' /tmp/voidful-vm-config.conf 2>/dev/null | head -1 | tr -d '"' || true)

    # Run verify_installed_system.sh (static checklist, root) if present.
    if [[ -f "${PROJECT_DIR}/tests/verify_installed_system.sh" ]]; then
        log_info "Running tests/verify_installed_system.sh inside the installed system..."
        # Deploy the script under /tmp/voidful-tests/ with lib/logging.sh at
        # /tmp/lib/: the script sources "$(dirname script)/../lib/logging.sh",
        # which resolves correctly only with that layout (a flat /tmp copy
        # resolves to /lib/logging.sh, which does not exist on the guest).
        sshpass -p "${BOOT_PASS}" ssh -o StrictHostKeyChecking=no \
            "${BOOT_USER}@${VM_GUEST_IP}" "mkdir -p /tmp/voidful-tests /tmp/lib" 2>/dev/null || true
        sshpass -p "${BOOT_PASS}" scp -o StrictHostKeyChecking=no \
            "${PROJECT_DIR}/lib/logging.sh" \
            "${BOOT_USER}@${VM_GUEST_IP}:/tmp/lib/logging.sh" 2>/dev/null || true
        sshpass -p "${BOOT_PASS}" scp -o StrictHostKeyChecking=no \
            "${PROJECT_DIR}/tests/verify_installed_system.sh" \
            "${BOOT_USER}@${VM_GUEST_IP}:/tmp/voidful-tests/verify_installed_system.sh" 2>/dev/null || \
            log_warn "Could not copy verify_installed_system.sh to the installed system"
        local verify_out
        local verify_rc=0
        verify_out=$(sshpass -p "${BOOT_PASS}" ssh -o StrictHostKeyChecking=no \
            "${BOOT_USER}@${VM_GUEST_IP}" \
            "echo '${BOOT_PASS}' | sudo -S TIMEZONE_EXPECTED='${verify_tz}' bash /tmp/voidful-tests/verify_installed_system.sh" 2>&1) || verify_rc=$?
        echo "--- VERIFY_INSTALLED_SYSTEM (rc=${verify_rc}) ---"
        echo "${verify_out}"
        echo "--- END VERIFY_INSTALLED_SYSTEM ---"
        if [[ ${verify_rc} -ne 0 ]]; then
            log_warn "verify_installed_system.sh exited ${verify_rc} (see output above)"
        fi
    fi

    log_success "Boot verification PASSED: installed system is up and reachable"
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    validate_prerequisites

    # ── Reinstall mode: skip VM setup, just re-run on existing VM ──
    if [[ "${REINSTALL}" == "true" ]]; then
        log_info "=== REINSTALL MODE — skipping VM setup ==="
        if [[ "${DISPLAY_TYPE}" != "none" ]]; then
            log_warn "--display only applies when creating the VM; ignoring in --reinstall mode"
        fi

        # Detect IP (use cached or detect from libvirt)
        if [[ -z "${VM_GUEST_IP}" ]]; then
            VM_GUEST_IP=$(virsh --connect "${VIRSH_URI}" domifaddr "${VM_NAME}" 2>/dev/null \
                | awk 'NF == 4 && $3 == "ipv4" && $2 != "-" { split($4, _a, "/"); print _a[1]; exit }' || true)
            if [[ -z "${VM_GUEST_IP}" ]]; then
                log_error "VM not running or no IP detected. Start it first: virsh start ${VM_NAME}"
                exit 1
            fi
            log_info "Reusing VM IP: ${VM_GUEST_IP}"
        fi

        # Verify SSH
        if ! wait_for_ssh; then
            log_error "SSH not available"
            exit 1
        fi

        # Verify sudo
        if ! check_sudo; then
            exit 1
        fi

        # Detect hardware (needed for config generation)
        if ! detect_vm_hardware; then
            log_error "Hardware detection failed"
            exit 1
        fi

        # Generate config
        local generated_config="/tmp/voidful-vm-config.conf"
        generate_config "${CONFIG_TEMPLATE}" "${VM_DISK_PATH}" "${VM_BOOT_MODE}" "${generated_config}"

        # Copy files + config
        copy_files
        if ! copy_config "${generated_config}"; then
            log_error "Config copy failed"
            exit 1
        fi

        # Run installation
        local remote_config="${REMOTE_INSTALLER_DIR}/${REMOTE_CONFIG_NAME}"
        if ! run_installation "${remote_config}"; then
            log_error "Installation failed"
            echo ""
            log_info "Inspecting logs for diagnostics..."
            check_install_logs
            echo ""
            log_error "Fix the issues, copy updated files via SSH, and re-run:"
            log_error "  sshpass -p '${SSH_PASS}' scp -r install.sh lib/ ${SSH_USER}@${VM_GUEST_IP}:${REMOTE_INSTALLER_DIR}/"
            log_error "  ./qemu_boot_test.sh --reinstall"
            exit 1
        fi

        # Final log inspection
        echo ""
        log_info "=== Final Diagnostics ==="
        check_install_logs

        # Boot verification (reboot into the installed system)
        if [[ "${VERIFY_BOOT}" == "true" ]]; then
            echo ""
            extract_install_credentials "${generated_config}"
            _ensure_serial_log
            verify_boot || { log_error "Boot verification FAILED (VM left running for inspection)"; BOOT_VERIFY_FAILED=1; }
        else
            log_info "Boot verification skipped (--skip-verify-boot)"
        fi

        echo ""
        log_success "============================================="
        log_success " REINSTALL COMPLETE"
        log_success "============================================="
        log_success " VM Name    : ${VM_NAME}"
        log_success " VM IP      : ${VM_GUEST_IP}"
        log_success " Disk       : ${VM_DISK_PATH}"
        log_success " Boot Mode  : ${VM_BOOT_MODE}"
        print_display_info
        log_success " Logs       : /var/log/voidful.log (on VM)"
        log_success "============================================="
        echo ""
        if [[ "${BOOT_VERIFY_FAILED}" == "1" ]]; then
            log_error "REINSTALL FAILED: boot verification failed (exit 1)"
            return 1
        fi
        if [[ "${VERIFY_BOOT}" == "true" ]]; then
            log_success "TEST PASSED (install + boot verification)"
        else
            log_success "TEST PASSED (install; boot verification skipped)"
        fi
        return 0
    fi

    # ── Full mode: create VM, install, leave running ──
    # Clean up any leftover test VM from the previous run
    if [[ "${REINSTALL}" != "true" ]]; then
        # Verify existence and clean up only if not in reinstall mode
        if virsh --connect "${VIRSH_URI}" domstate "${VM_NAME}" &>/dev/null; then
            log_info "Previous test VM found. Cleaning up..."
            destroy_vm
            rm -f "${DISK_FILE}"
            log_info "Waiting 3 seconds for resources to release..."
            sleep 3
        fi
    fi

    setup_disk

    # Phase 1: Boot and detect
    create_vm
    if ! get_vm_ip; then
        log_error "VM did not get an IP address"
        exit 1
    fi
    # Wait for sshd port to be reachable
    log_info "Waiting for sshd to be ready on ${VM_GUEST_IP}..."
    if ! _wait_for_sshd_ready "${VM_GUEST_IP}"; then
        log_error "sshd port not reachable on ${VM_GUEST_IP} after 30s"
        exit 1
    fi

    # Wait for SSH authentication
    if ! wait_for_ssh; then
        log_error "SSH not available after VM boot"
        exit 1
    fi

    # Verify sudo
    if ! check_sudo; then
        exit 1
    fi

    # Phase 2: Detect VM hardware
    if ! detect_vm_hardware; then
        log_error "Hardware detection failed"
        exit 1
    fi

    # Phase 3: Generate adapted config
    local generated_config="/tmp/voidful-vm-config.conf"
    generate_config "${CONFIG_TEMPLATE}" "${VM_DISK_PATH}" "${VM_BOOT_MODE}" "${generated_config}"

    # Phase 4: Copy files + config
    copy_files
    if ! copy_config "${generated_config}"; then
        log_error "Config copy failed"
        exit 1
    fi

    # Phase 5: Run installation
    local remote_config="${REMOTE_INSTALLER_DIR}/${REMOTE_CONFIG_NAME}"
    if ! run_installation "${remote_config}"; then
        log_error "Installation failed"
        echo ""
        log_info "Inspecting logs for diagnostics..."
        check_install_logs
        echo ""
        log_error "Fix the issues, copy updated files via SSH, and re-run:"
        log_error "  sshpass -p '${SSH_PASS}' scp -r install.sh lib/ ${SSH_USER}@${VM_GUEST_IP}:${REMOTE_INSTALLER_DIR}/"
        log_error "  ./qemu_boot_test.sh --reinstall"
        exit 1
    fi

    # Phase 6: Final log inspection (while the VM is still on the live ISO,
    # before the boot verification reboots it into the installed system)
    echo ""
    log_info "=== Final Diagnostics ==="
    check_install_logs

    # Phase 7: Boot verification (reboot into the installed system)
    if [[ "${VERIFY_BOOT}" == "true" ]]; then
        echo ""
        extract_install_credentials "${generated_config}"
        _ensure_serial_log
        verify_boot || { log_error "Boot verification FAILED (VM left running for inspection)"; BOOT_VERIFY_FAILED=1; }
    else
        log_info "Boot verification skipped (--skip-verify-boot)"
    fi

    echo ""
    log_success "============================================="
    if [[ "${DESTROY_ON_SUCCESS}" == "true" && "${BOOT_VERIFY_FAILED}" != "1" ]]; then
        log_info "User requested cleanup. Destroying..."
        destroy_vm
        rm -f "${DISK_FILE}"
        log_success "Resources destroyed."
    else
        log_success "INSTALLATION COMPLETE — VM LEFT RUNNING"
    fi
    log_success "============================================="
    log_success " VM Name    : ${VM_NAME}"
    log_success " VM IP      : ${VM_GUEST_IP}"
    log_success " SSH        : sshpass -p '${SSH_PASS}' ssh ${SSH_USER}@${VM_GUEST_IP}"
    log_success " Remote Dir : ${REMOTE_INSTALLER_DIR}/"
    log_success " Config     : ${remote_config}"
    log_success " Disk       : ${VM_DISK_PATH}"
    log_success " Boot Mode  : ${VM_BOOT_MODE}"
    print_display_info
    log_success " Logs       : /var/log/voidful.log (on VM)"
    log_success "============================================="
    echo ""
    log_info "To stop the VM manually:"
    log_info "  virsh destroy ${VM_NAME}"
    log_info "  virsh undefine ${VM_NAME}"
    echo ""
    if [[ "${BOOT_VERIFY_FAILED}" == "1" ]]; then
        log_error "TEST FAILED: boot verification failed (exit 1)"
        return 1
    fi
    if [[ "${VERIFY_BOOT}" == "true" ]]; then
        log_success "TEST PASSED (install + boot verification)"
    else
        log_success "TEST PASSED (install; boot verification skipped)"
    fi
    return 0
}

main "$@"
