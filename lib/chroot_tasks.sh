#!/usr/bin/env bash
set -euo pipefail

# chroot_tasks.sh — Post-install chroot configuration for the voidful installer.
#
# configure_chroot() runs (after mounting bind filesystems) this 20-step
# configuration sequence, then unmounts the bind filesystems:
#   1.  Fix root ownership
#   2.  Copy /etc/skel files to root home
#   3.  Set hostname
#   4.  Configure locale
#   5.  Configure keymap
#   6.  Configure timezone
#   7.  Set issue file
#   8.  Set root password
#   9.  Create regular user
#   10. Set user password
#   11. Configure sudo
#   12. Configure network
#   13. Enable runit services
#   14. Copy LUKS keyfile
#   15. Configure crypttab
#   16. Rebuild initramfs
#   17. Install GRUB + configure terminal
#   18. Create swap file (if SWAP_TYPE="file")
#   19. Set btrfs default subvolume (btrfs root defined with --subvol)
#   20. Generate fstab
#
# Expected globals (set by install.sh before sourcing this module):
#   CHROOT_TARGET_DIR, CHROOT_HOSTNAME, CHROOT_LOCALE, CHROOT_KEYMAP,
#   CHROOT_TIMEZONE (optional),
#   CHROOT_ROOT_PASSWORD, CHROOT_USERNAME, CHROOT_USER_PASSWORD,
#   CHROOT_ENABLED_SERVICES, CHROOT_NETWORK_MODE, CHROOT_NETWORK_DEVICE,
#   CHROOT_NETWORK_IP, CHROOT_NETWORK_GATEWAY, CHROOT_BOOT_MODE,
#   CHROOT_BOOTLOADER
#   PARTITION_PREFIX, TARGET_DISK, PART_MOUNTS[], PART_FS[], PART_LUKS[],
#   SWAP_UUID, LUKS_KEYFILE (optional — path to keyfile on live ISO)
#
# See ADR-009 for the sourced-module variable passing pattern.

# ---------------------------------------------------------------------------
# Source dependencies
# ---------------------------------------------------------------------------
# shellcheck source=lib/logging.sh
source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
# shellcheck source=lib/hardware.sh
source "$(dirname "${BASH_SOURCE[0]}")/hardware.sh"
# NOTE: _luks_name_from_mount() is provided by lib/partitioning.sh (sourced
# before this module by install.sh). The former lib/luks.sh was dead shadowing
# code (its format_luks/open_luks/setup_crypttab/etc. were re-defined after the
# partitioning.sh versions had already run) and was removed.

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# _chroot_run()
#
# Run a command inside the chroot environment.
# Args: $1 = command string, $2 = optional description (defaults to "command")
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
_chroot_run() {
    local cmd="${1}"
    local description="${2:-command}"
    log_info "Running in chroot: ${description}"
    if ! chroot "${CHROOT_TARGET_DIR}" bash -c "${cmd}"; then
        log_error "Chroot command failed: ${description}"
        return 1
    fi
}

# _has_luks_partitions()
#
# Check if any partition has LUKS encryption enabled.
# Returns: 0 (true) if any LUKS partition found, 1 (false) otherwise
# ---------------------------------------------------------------------------
_has_luks_partitions() {
    local luks_flag
    for luks_flag in "${PART_LUKS[@]}"; do
        if [[ "${luks_flag}" == "yes" ]]; then
            return 0
        fi
    done
    return 1
}

# _copy_luks_keyfile()
#
# Copy LUKS keyfile from the live ISO to /etc/cryptsetup-keys/ in the target.
# Must be called BEFORE _setup_crypttab() and _rebuild_initramfs().
# ---------------------------------------------------------------------------
_copy_luks_keyfile() {
    if [[ -n "${LUKS_KEYFILE:-}" && -f "${LUKS_KEYFILE}" ]]; then
        local keyfile_basename
        keyfile_basename=$(basename "${LUKS_KEYFILE}")
        local keyfile_dest="${CHROOT_TARGET_DIR}/etc/cryptsetup-keys/${keyfile_basename}"

        mkdir -p "${CHROOT_TARGET_DIR}/etc/cryptsetup-keys"
        cp "${LUKS_KEYFILE}" "${keyfile_dest}"
        chmod 0400 "${keyfile_dest}"
        log_info "Copied LUKS keyfile: ${keyfile_basename} → /etc/cryptsetup-keys/${keyfile_basename}"
    fi
}

# _luks_root_uuid()
#
# Get the UUID of the LUKS-encrypted root partition's raw device.
# Used for the cryptdevice kernel parameter.
# Returns: UUID on stdout, empty string if no LUKS root
# ---------------------------------------------------------------------------
_luks_root_uuid() {
    local num_partitions="${#PART_MOUNTS[@]}"
    local i mount_point luks
    local disk_base="${TARGET_DISK%/}"
    local part_prefix="${PARTITION_PREFIX:-}"

    for ((i = 0; i < num_partitions; i++)); do
        mount_point="${PART_MOUNTS[$i]}"
        luks="${PART_LUKS[$i]}"
        [[ "${luks}" != "yes" ]] && continue
        [[ "${mount_point}" != "/" ]] && continue

        local device="${disk_base}${part_prefix}$((i + 1))"
        blkid -s UUID -o value "${device}" 2>/dev/null || echo ""
        return
    done

    echo ""
}

# _agetty_escape()
#
# Escape a message for agetty's /etc/issue interpretation. agetty interprets
# backslash escapes (\b=baud, \e=color, \S=os-release, \n=hostname,
# \r=kernel release, \m=machine, ...); unknown sequences drop the backslash.
# Double literal backslashes (ASCII art) so they survive rendering, but keep
# agetty escape sequences intact.
#
# $1 = message
# Result in AGERTY_ESCAPED. (No command substitution: $(...) would strip
# trailing newlines.)
# ---------------------------------------------------------------------------
_agetty_escape() {
    local msg="$1"
    local out="" c next
    local i=0 len="${#msg}"
    while (( i < len )); do
        c="${msg:i:1}"
        if [[ "$c" == "\\" ]]; then
            next="${msg:i+1:1}"
            if [[ "$next" =~ [esnrvmoOdtlbuU46aAS] ]]; then
                out+="${c}${next}"
                (( i += 2 ))
            else
                out+="\\\\"
                (( i += 1 ))
            fi
        else
            out+="$c"
            (( i += 1 ))
        fi
    done
    AGERTY_ESCAPED="$out"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# configure_chroot()
#
# Execute the full 20-step chroot configuration sequence.
# ---------------------------------------------------------------------------
configure_chroot() {
    # Validate required globals are set by the caller (install.sh).
    # This fails fast if the sourced-module contract is broken.
    local _missing_vars=()
    for _var in CHROOT_TARGET_DIR CHROOT_HOSTNAME CHROOT_LOCALE CHROOT_KEYMAP \
                CHROOT_BOOT_MODE CHROOT_BOOTLOADER; do
        if [[ -z "${!_var:-}" ]]; then
            _missing_vars+=("${_var}")
        fi
    done
    if [[ ${#_missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required globals: ${_missing_vars[*]}"
        log_error "These must be set by install.sh before sourcing this module."
        return 1
    fi

    local target_dir="${CHROOT_TARGET_DIR}"

    log_info "Starting chroot configuration in ${target_dir}"

    # Step 0: Chroot preparation — mount bind filesystems
    _mount_bind_filesystems

    # Step 1: Fix root ownership
    _fix_root_ownership

    # Step 2: Copy /etc/skel files to root home
    _copy_skelfiles

    # Step 3: Set hostname
    _set_hostname

    # Step 4: Set locale
    _set_locale

    # Step 5: Set keymap
    _set_keymap

    # Step 6: Configure timezone
    _set_timezone

    # Step 7: Set issue file
    _set_issue

    # Step 8: Set root password
    _set_root_password

    # Step 9: Create regular user
    _create_user

    # Step 10: Set user password
    _set_user_password

    # Step 11: Configure sudo access
    _configure_sudo

    # Step 12: Configure network (before services so dhcpcd can be auto-enabled)
    _configure_network

    # Step 13: Enable runit services
    _enable_services


    # Step 14: Copy LUKS keyfile to target (must be before crypttab and initramfs)
    _copy_luks_keyfile

    # Step 15: Configure crypttab for LUKS
    _setup_crypttab

    # Step 16: Rebuild initramfs
    _rebuild_initramfs

    # Step 17: Configure GRUB terminal
    # NOTE: _install_grub MUST run BEFORE _configure_grub_terminal.
    # grub-install probes the disk and fails if cryptdevice/cryptouuid
    # parameters are present in /etc/default/grub (LUKS disks can't be probed).
    if [[ "${CHROOT_BOOTLOADER}" == "grub" ]]; then
        _install_grub
        _configure_grub_terminal
    else
        log_info "Step 16: Skipping GRUB installation (bootloader=${CHROOT_BOOTLOADER})"
    fi

    # Activate swap file (if configured)

    if [[ "${SWAP_TYPE:-}" == "file" ]]; then
        _create_swap_file "${CHROOT_TARGET_DIR}"
    fi

    # Set the btrfs default subvolume (btrfs root defined with --subvol, LUKS
    # or not) so the kernel mounts the rootfs subvolume and post-boot btrfs
    # operations land on the right subvolume.
    _set_btrfs_default_subvol

    # Generate fstab with UUIDs
    _generate_fstab

    # Unmount bind filesystems
    _unmount_bind_filesystems

    log_success "Chroot configuration completed successfully"
}
_mount_bind_filesystems() {
    local _mount_failed=0
    for _pair in "/dev:dev" "/dev/pts:dev/pts" "/sys:sys" "/proc:proc"; do
        local _src _dst
        _src="${_pair%%:*}"; _dst="${_pair##*:}"
        if ! mount --bind "${_src}" "${target_dir}/$_dst"; then
            log_error "Failed to bind-mount ${_src} -> ${target_dir}/$_dst"
            _mount_failed=1
        fi
    done
    mount -t efivarfs efivarfs "${target_dir}/sys/firmware/efi/efivars" 2>/dev/null || true

    if [[ ${_mount_failed} -ne 0 ]]; then
        log_error "One or more chroot bind mounts failed; aborting chroot preparation"
        return 1
    fi

    # Copy resolv.conf for network access inside chroot
    if [[ -f /etc/resolv.conf ]]; then
        cp /etc/resolv.conf "${target_dir}/etc/resolv.conf"
    fi

    # Copy XBPS signing keys
    if [[ -d /etc/xbps.d ]]; then
        cp -a /etc/xbps.d "${target_dir}/etc/xbps.d" 2>/dev/null || true
    fi
}

# _unmount_bind_filesystems()
#
# Unmount bind filesystems after chroot configuration.
# ---------------------------------------------------------------------------
_unmount_bind_filesystems() {
    local target_dir="${CHROOT_TARGET_DIR}"

    log_info "Unmounting bind filesystems"

    rm -f "${target_dir}/etc/resolv.conf" 2>/dev/null || true
    umount "${target_dir}/sys/firmware/efi/efivars" 2>/dev/null || true
    umount "${target_dir}/sys" 2>/dev/null || true
    umount "${target_dir}/dev/pts" 2>/dev/null || true
    umount "${target_dir}/dev" 2>/dev/null || true
    umount "${target_dir}/proc" 2>/dev/null || true
}

# _fix_root_ownership()
# ---------------------------------------------------------------------------
_fix_root_ownership() {
    log_info "Step 1: Fixing root ownership"

    chroot "${CHROOT_TARGET_DIR}" chown root:root /
    chroot "${CHROOT_TARGET_DIR}" chmod 755 /
}

# _copy_skelfiles()
#
# Copy /etc/skel dotfiles to root's home.
# Uses the same glob pattern as void-installer: .[bix]* matches
# .bashrc, .bash_logout, .ICEauthority, .xinitrc, etc.
# ---------------------------------------------------------------------------
_copy_skelfiles() {
    log_info "Step 2: Copying /etc/skel files"

    chroot "${CHROOT_TARGET_DIR}" bash -c '
        if [[ -d /etc/skel ]]; then
            cp -a /etc/skel/.[bix]* /root/ 2>/dev/null || true
        fi
    ' || true
}

# _set_hostname()
# ---------------------------------------------------------------------------
_set_hostname() {
    log_info "Step 3: Setting hostname to '${CHROOT_HOSTNAME}'"

    echo "${CHROOT_HOSTNAME}" > "${CHROOT_TARGET_DIR}/etc/hostname"
}

# _set_locale()
# ---------------------------------------------------------------------------
_set_locale() {
    log_info "Step 4: Setting locale to '${CHROOT_LOCALE}'"

    echo "KEYMAP=${CHROOT_KEYMAP}" > "${CHROOT_TARGET_DIR}/etc/vconsole.conf"
    echo "LANG=${CHROOT_LOCALE}" > "${CHROOT_TARGET_DIR}/etc/locale.conf"
}

# _set_keymap()
# ---------------------------------------------------------------------------
_set_keymap() {
    log_info "Step 5: Setting keymap to '${CHROOT_KEYMAP}'"

    chroot "${CHROOT_TARGET_DIR}" loadkeys "${CHROOT_KEYMAP}" || true
}

# _set_timezone()
# ---------------------------------------------------------------------------
_set_timezone() {
    if [[ -z "${CHROOT_TIMEZONE:-}" ]]; then
        log_info "Timezone: not set — keeping system default (UTC)"
        return 0
    fi
    log_info "Timezone: setting /etc/localtime -> /usr/share/zoneinfo/${CHROOT_TIMEZONE}"
    ln -sf "/usr/share/zoneinfo/${CHROOT_TIMEZONE}" "${CHROOT_TARGET_DIR}/etc/localtime"
}

# _set_root_password()

# _set_issue()
#
# Sets the /etc/issue file with content from CHROOT_ISSUE_MESSAGE
# or falls back to the built-in ASCII art.
# ---------------------------------------------------------------------------
_set_issue() {
    # $(...) strips trailing newlines; capture line by line so trailing
    # blank lines survive.
    local art="" _line
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        art+="${_line}"$'\n'
    done <<'EOT'
         ...............             _   _         _      _   _      _
       .....................        | | | |       (_)    | | | |    (_)
   #     .....      ..........      | | | |  ___   _   __| | | |     _  _ __   _   _ __  __
 #####                  ........    | | | | / _ \ | | / _` | | |    | || '_ \ | | | |\ \/ /
#######       .....       .......   \ \_/ /| (_) || || (_| | | |____| || | | || |_| | >  <
######     ...........     ......    \___/  \___/ |_| \__,_| \_____/|_||_| |_| \__,_|/_/\_\
######     ...........     ......
######     ...........     ......   TTY:      \l
#######       .....       .......   Kernel:   \r
 ########                  .....    Arch:     \m
   ##########       ####     .      Hostname: \n
     #####################          Date:     \d - \t
         ###############

EOT

    log_info "Step 6: Setting issue file"
    local issue_msg="${CHROOT_ISSUE_MESSAGE:-${art}}"
    # agetty interprets backslash escapes in /etc/issue (\b=baud, \e=color,
    # \S=os-release, ...); unknown sequences drop the backslash. Double
    # literal backslashes so the art survives, keep agetty escapes (\r, \m,
    # \n, ...) intact.
    _agetty_escape "${issue_msg}"
    issue_msg="${AGERTY_ESCAPED}"
    chroot "${CHROOT_TARGET_DIR}" bash -c '
        printf "%s" "$1" > /etc/issue' _ "${issue_msg}"
}

_set_root_password() {
    if [[ -n "${CHROOT_ROOT_PASSWORD}" ]]; then
        log_info "Step 7: Setting root password"
        echo "root:${CHROOT_ROOT_PASSWORD}" | chroot "${CHROOT_TARGET_DIR}" chpasswd -c SHA512
    else
        log_info "Step 7: Skipping root password (not set)"
    fi
}

# _create_user()
#
# Creates a regular user account when CREATE_USER is "yes" and a login name is
# set (CHROOT_USERNAME).
# ───────────────────────────────────────────────────────────────────
_create_user() {
    if [[ "${CHROOT_CREATE_USER:-no}" == "yes" && -n "${CHROOT_USERNAME}" ]]; then
        # Validate username format (lowercase alphanumeric + underscores/dashes)
        if [[ ! "${CHROOT_USERNAME}" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
            log_error "Invalid username format: ${CHROOT_USERNAME}"
            return 1
        fi

        # Build groups list (default: wheel)
        local groups="${CHROOT_USER_GROUPS:-wheel}"

        # Build useradd command as an array to preserve quoted arguments.
        # Mirrors void-installer's set_useraccount():
        #   useradd -m -G <groups> -c <fullname> <login>
        local -a useradd_arr=(useradd -m -g users -G "${groups}" -s "${CHROOT_USER_SHELL:-/bin/bash}" "${CHROOT_USERNAME}")
        useradd_arr+=(-c "${CHROOT_USER_FULLNAME}")

        chroot "${CHROOT_TARGET_DIR}" "${useradd_arr[@]}" 2>&1 || true
        # Primary group is 'users' (set by -g users in useradd),
        # so only set owner, not group.
        chroot "${CHROOT_TARGET_DIR}" chown -R "${CHROOT_USERNAME}:" "/home/${CHROOT_USERNAME}" || true
    else
        log_info "Step 7: Skipping user creation (CREATE_USER != 'yes' or no USER_LOGIN)"
    fi
}


# _set_user_password()
# ---------------------------------------------------------------------------
_set_user_password() {
    if [[ "${CHROOT_CREATE_USER:-no}" == "yes" && -n "${CHROOT_USERNAME}" && -n "${CHROOT_USER_PASSWORD}" ]]; then
        log_info "Step 8: Setting password for user '${CHROOT_USERNAME}'"

        echo "${CHROOT_USERNAME}:${CHROOT_USER_PASSWORD}" | chroot "${CHROOT_TARGET_DIR}" chpasswd -c SHA512
    else
        log_info "Step 8: Skipping user password (not set)"
    fi
}

# _configure_sudo()
# ---------------------------------------------------------------------------
_configure_sudo() {
    log_info "Step 9: Configuring sudo access"

    # Enable wheel group sudo access
    echo "%wheel ALL=(ALL) SETENV: ALL" > "${CHROOT_TARGET_DIR}/etc/sudoers.d/wheel"
    chmod 0440 "${CHROOT_TARGET_DIR}/etc/sudoers.d/wheel"
}

# _enable_services()
# ---------------------------------------------------------------------------
_enable_services() {
    if [[ -n "${CHROOT_ENABLED_SERVICES}" ]]; then
        log_info "Step 10: Enabling services: ${CHROOT_ENABLED_SERVICES}"

        # Ensure the runit running-services directory exists in the chroot
        # before creating service symlinks. In the cloned rootfs it may be
        # absent or a dangling symlink, which makes `ln -s ... /var/service/<svc>`
        # fail with "No such file or directory".
        chroot "${CHROOT_TARGET_DIR}" bash -c '
            if [ -L /var/service ] && [ ! -e /var/service ]; then
                rm -f /var/service
            fi
            mkdir -p /var/service
        '

        local IFS=','
        for service in ${CHROOT_ENABLED_SERVICES}; do
            service=$(echo "${service}" | xargs)  # trim whitespace
            if chroot "${CHROOT_TARGET_DIR}" ln -s "/etc/sv/${service}" "/var/service/${service}"; then
                log_info "Enabled service: ${service}"
            else
                log_warn "Failed to enable service: ${service}"
            fi
        done
    else
        log_info "Step 10: No services to enable"
    fi
}

# _configure_network()
# ---------------------------------------------------------------------------
_configure_network() {
    log_info "Step 11: Configuring network (mode: ${CHROOT_NETWORK_MODE})"

    if [[ "${CHROOT_NETWORK_MODE}" == "dhcp" ]]; then
        # DHCP configuration — dhcpcd service enabled
        if [[ -n "${CHROOT_NETWORK_DEVICE}" ]]; then
            cat > "${CHROOT_TARGET_DIR}/etc/dhcpcd.conf" <<EOF
interface ${CHROOT_NETWORK_DEVICE}
EOF
        fi
        log_info "Configured DHCP for device: ${CHROOT_NETWORK_DEVICE:-auto}"
        # Auto-enable dhcpcd if not already in ENABLED_SERVICES
        if [[ -z "${CHROOT_ENABLED_SERVICES}" ]] || ! echo "${CHROOT_ENABLED_SERVICES}" | grep -q "dhcpcd"; then
            CHROOT_ENABLED_SERVICES="${CHROOT_ENABLED_SERVICES:+${CHROOT_ENABLED_SERVICES},}dhcpcd"
            log_info "Auto-enabled dhcpcd service"
        fi
    elif [[ "${CHROOT_NETWORK_MODE}" == "static" ]]; then
        # Static IP configuration
        if [[ -n "${CHROOT_NETWORK_DEVICE}" && -n "${CHROOT_NETWORK_IP}" ]]; then
            # DNS servers: honour DNS_SERVERS when set (a comma-separated list is
            # converted to the space-separated form dhcpcd expects); when unset,
            # omit the line so DNS is obtained via DHCP.
            local dns_servers_line=""
            if [[ -n "${DNS_SERVERS:-}" ]]; then
                dns_servers_line="static domain_name_servers=${DNS_SERVERS//,/ }"
            fi
            {
                echo "interface ${CHROOT_NETWORK_DEVICE}"
                echo "static ip_address=${CHROOT_NETWORK_IP}"
                echo "static routers=${CHROOT_NETWORK_GATEWAY}"
                if [[ -n "${dns_servers_line}" ]]; then
                    echo "${dns_servers_line}"
                fi
            } > "${CHROOT_TARGET_DIR}/etc/dhcpcd.conf"
            log_info "Configured static IP: ${CHROOT_NETWORK_IP} on ${CHROOT_NETWORK_DEVICE}"
            # Auto-enable dhcpcd if not already in ENABLED_SERVICES
            if [[ -z "${CHROOT_ENABLED_SERVICES}" ]] || ! echo "${CHROOT_ENABLED_SERVICES}" | grep -q "dhcpcd"; then
                CHROOT_ENABLED_SERVICES="${CHROOT_ENABLED_SERVICES:+${CHROOT_ENABLED_SERVICES},}dhcpcd"
                log_info "Auto-enabled dhcpcd service"
            fi
        else
            log_warn "Static network configured but missing device/IP"
        fi
    fi
}

# _setup_crypttab()
# ---------------------------------------------------------------------------
_setup_crypttab() {
    log_info "Step 14: Configuring crypttab for LUKS partitions"

    local num_partitions="${#PART_MOUNTS[@]}"
    local i mount_point luks device uuid luks_name keyfile_entry
    local disk_base="${TARGET_DISK%/}"
    local part_prefix="${PARTITION_PREFIX:-}"

    # Determine keyfile path for crypttab (if configured)
    if [[ -n "${LUKS_KEYFILE:-}" ]]; then
        local keyfile_basename
        keyfile_basename=$(basename "${LUKS_KEYFILE}")
        keyfile_entry="/etc/cryptsetup-keys/${keyfile_basename}"
        log_info "LUKS_KEYFILE configured: ${keyfile_basename} → /etc/cryptsetup-keys/${keyfile_basename}"
    else
        keyfile_entry="none"
        log_info "LUKS mode: passphrase only (no keyfile)"
    fi

    # Collect entries into an array (the installer runs as root on the mounted
    # target, so we write directly — no sudo needed)
    local -a crypttab_entries=()

    for ((i = 0; i < num_partitions; i++)); do
        mount_point="${PART_MOUNTS[$i]}"
        luks="${PART_LUKS[$i]}"
        [[ "${luks}" != "yes" ]] && continue

        # Construct device name from TARGET_DISK and partition index
        device="${disk_base}${part_prefix}$((i + 1))"
        luks_name=$(_luks_name_from_mount "${mount_point}")
        uuid=$(blkid -s UUID -o value "${device}" 2>/dev/null || echo "")

        if [[ -z "${uuid}" ]]; then
            log_warn "_setup_crypttab: Could not get UUID for ${device}, skipping"
            continue
        fi

        # Build crypttab entry based on credential mode
        # passphrase only:  luks-name UUID=xxx none luks
        # keyfile only:     luks-name UUID=xxx /etc/cryptsetup-keys/xxx.key luks
        # both:             luks-name UUID=xxx /etc/cryptsetup-keys/xxx.key luks
        #                   (cryptsetup tries keyfile first, falls back to passphrase)
        crypttab_entries+=("luks-${luks_name} UUID=${uuid} ${keyfile_entry} luks")
        log_success "crypttab entry added: luks-${luks_name} (UUID=${uuid}, keyfile=${keyfile_entry})"
    done

    # Write entries (running as root on the mounted target — no sudo needed).
    # Idempotent across reinstall runs: if a line for the same LUKS name already
    # exists, replace it (the UUID can change on re-encryption) instead of
    # appending a duplicate.
    if [[ ${#crypttab_entries[@]} -gt 0 ]]; then
        local entry name tmp
        for entry in "${crypttab_entries[@]}"; do
            name="${entry%% *}"   # first field = luks-<name>
            if grep -q "^${name} " "${CHROOT_TARGET_DIR}/etc/crypttab" 2>/dev/null; then
                # Drop the stale line, then the append below reinstates it.
                tmp=$(mktemp)
                grep -v "^${name} " "${CHROOT_TARGET_DIR}/etc/crypttab" > "${tmp}" || true
                cat "${tmp}" > "${CHROOT_TARGET_DIR}/etc/crypttab"
                rm -f "${tmp}"
            fi
            printf '%s\n' "${entry}" >> "${CHROOT_TARGET_DIR}/etc/crypttab"
        done
    fi

    # Set correct permissions (we are already root; no sudo needed)
    chmod 0644 "${CHROOT_TARGET_DIR}/etc/crypttab"
    log_info "crypttab configured"
}

# _set_btrfs_default_subvol()
# ---------------------------------------------------------------------------
# For a btrfs root defined with --subvol, set the named subvolume as the default
# (btrfs subvolume set-default). Belt-and-suspenders with rootflags=subvol=<subvol>:
# it guarantees the kernel mounts the rootfs subvolume (not the empty top-level
# subvolume) and makes post-boot btrfs operations (a bare mount) land on the right
# subvolume. Applies whether or not the root is LUKS-encrypted.
# ---------------------------------------------------------------------------
_set_btrfs_default_subvol() {
    local num_partitions="${#PART_MOUNTS[@]}"
    local i subvol subvol_id
    for ((i = 0; i < num_partitions; i++)); do
        [[ "${PART_MOUNTS[$i]}" == "/" ]] || continue
        if [[ "${PART_FS[$i]}" == "btrfs" && -n "${PART_SUBVOLS[$i]:-}" ]]; then
            subvol="${PART_SUBVOLS[$i]}"
            # btrfs subvolume set-default requires a NUMERIC subvolume ID, not the
            # name. Resolve the named subvolume's numeric ID from
            # 'btrfs subvolume list /' (the path is the last field, matched exactly).
            subvol_id="$(chroot "${CHROOT_TARGET_DIR}" btrfs subvolume list / 2>/dev/null | awk -v n="${subvol}" '$NF == n { print $2; exit }')"
            if [[ -n "${subvol_id}" ]]; then
                log_info "Setting default btrfs subvolume: ${subvol} (id ${subvol_id})"
                if ! chroot "${CHROOT_TARGET_DIR}" bash -c "btrfs subvolume set-default \"\$1\" /" _ "${subvol_id}"; then
                    log_warn "Failed to set default btrfs subvolume (id ${subvol_id}): ${subvol}"
                fi
            else
                log_warn "Could not resolve numeric ID for btrfs subvolume: ${subvol} — default subvolume not set (system still boots via kernel cmdline subvol=${subvol})"
            fi
        fi
    done
}

# _build_luks_cmdline()
# ---------------------------------------------------------------------------
# Build the LUKS kernel command line, shared by the initramfs (--kernel-cmdline)
# and GRUB (GRUB_CMDLINE_LINUX). Echoes the cmdline string; returns 1 if no LUKS
# UUIDs were found.
#
#   - cryptdevice=UUID=<uuid>:luks-<name> for EVERY LUKS partition. dracut's
#     parse-crypt hook creates one udev rule per cryptdevice/rd.luks.uuid value,
#     so a LUKS partition without a cryptdevice param is never decrypted at boot.
#   - root=/dev/mapper/luks-root: required for a LUKS root partition (BIOS boot
#     fails with "root device not found" without it).
#   - rootflags=subvol=<subvol>: for a btrfs root with a subvolume (the kernel
#     otherwise mounts the empty top-level subvolume).
# ---------------------------------------------------------------------------
_build_luks_cmdline() {
    local num_partitions="${#PART_MOUNTS[@]}"
    local disk_base="${TARGET_DISK%/}"
    local part_prefix="${PARTITION_PREFIX:-}"
    local luks_name luks_uuid i
    local luks_cmdline=""

    for ((i = 0; i < num_partitions; i++)); do
        [[ "${PART_LUKS[$i]}" == "yes" ]] || continue
        luks_name=$(_luks_name_from_mount "${PART_MOUNTS[$i]}")
        luks_uuid=$(blkid -s UUID -o value "${disk_base}${part_prefix}$((i + 1))" 2>/dev/null || echo "")
        if [[ -n "${luks_uuid}" ]]; then
            luks_cmdline+="cryptdevice=UUID=${luks_uuid}:luks-${luks_name} "
        else
            log_warn "Could not find LUKS UUID for ${PART_MOUNTS[$i]}"
        fi
    done

    local luks_root_uuid
    luks_root_uuid=$(_luks_root_uuid)
    if [[ -n "${luks_root_uuid}" ]]; then
        luks_cmdline+="root=/dev/mapper/luks-root"
    fi

    # Btrfs root with a subvolume: mount the named subvolume at boot.
    local root_idx=""
    for ((i = 0; i < num_partitions; i++)); do
        if [[ "${PART_MOUNTS[$i]}" == "/" ]]; then
            root_idx="${i}"
            break
        fi
    done
    if [[ -n "${root_idx}" && "${PART_FS[$root_idx]}" == "btrfs" && -n "${PART_SUBVOLS[$root_idx]:-}" ]]; then
        luks_cmdline+=" rootflags=subvol=${PART_SUBVOLS[$root_idx]}"
    fi

    if [[ -z "${luks_cmdline}" ]]; then
        log_warn "LUKS partitions detected but no LUKS UUIDs could be found for cryptdevice parameters"
        return 1
    fi
    printf '%s' "${luks_cmdline}"
    return 0
}

# _rebuild_initramfs()
# ---------------------------------------------------------------------------
# Rebuilds the initramfs. For LUKS systems, the cryptdevice/root/rootflags
# params are baked in via --kernel-cmdline (computed BEFORE dracut): without it,
# dracut's crypt hook only generates udev rules for rd.luks.uuid/PARTUUID/SERIAL,
# so the initramfs would be missing the decrypt params at boot. The same cmdline
# is then written to GRUB (GRUB_CMDLINE_LINUX).
# ---------------------------------------------------------------------------
_rebuild_initramfs() {
    log_info "Step 12: Rebuilding initramfs"

    local luks_cmdline=""
    if _has_luks_partitions; then
        if luks_cmdline=$(_build_luks_cmdline); then
            log_info "LUKS kernel cmdline: ${luks_cmdline}"
        else
            log_warn "Could not build the full LUKS cmdline; the initramfs may be missing decrypt params"
            luks_cmdline=""
        fi

        # LUKS: include the crypt module (Void dracut), hostonly mode, the ahci
        # driver for disk detection, and the cryptdevice/root/rootflags cmdline.
        if ! chroot "${CHROOT_TARGET_DIR}" bash -c '
            mkdir -p /etc/dracut.conf.d
            echo "hostonly=yes" > /etc/dracut.conf.d/hostonly.conf
            dracut --force --add crypt --add-drivers ahci --kernel-cmdline "$1"
        ' _ "${luks_cmdline}"; then
            log_error "Failed to rebuild initramfs with LUKS support"
            log_error "Check chroot for dracut errors"
            return 1
        fi
    else
        if ! chroot "${CHROOT_TARGET_DIR}" bash -c 'dracut --no-hostonly --force'; then
            log_error "Failed to rebuild initramfs"
            log_error "Check chroot for dracut errors"
            return 1
        fi
        log_info "Initramfs rebuilt (no LUKS)"
    fi

    log_info "Step 14: Configuring GRUB"
    local grub_cfg="${CHROOT_TARGET_DIR}/etc/default/grub"

    # For LUKS systems, write cryptdevice + root=/dev/mapper/<name> to
    # GRUB_CMDLINE_LINUX (GRUB appends it to every linux/initrd line, BIOS and
    # EFI alike).
    if _has_luks_partitions && [[ -n "${luks_cmdline}" ]]; then
        # Exact match on ^GRUB_CMDLINE_LINUX= (with the = sign, no _DEFAULT
        # suffix). Void's default config has GRUB_CMDLINE_LINUX_DEFAULT but not
        # GRUB_CMDLINE_LINUX, so we create the latter with the LUKS params.
        if grep -q "^GRUB_CMDLINE_LINUX=" "${grub_cfg}" 2>/dev/null; then
            local existing_cmdline
            existing_cmdline=$(grep "^GRUB_CMDLINE_LINUX=" "${grub_cfg}" | sed 's|^GRUB_CMDLINE_LINUX="||;s|"$||')
            # Append the LUKS params if cryptdevice is not already present.
            if ! echo "${existing_cmdline}" | grep -q "cryptdevice"; then
                existing_cmdline="${existing_cmdline} ${luks_cmdline}"
            fi
            sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${existing_cmdline}\"|" "${grub_cfg}"
        else
            echo "GRUB_CMDLINE_LINUX=\"${luks_cmdline}\"" >> "${grub_cfg}"
        fi
        log_info "GRUB cmdline: ${luks_cmdline}"
    fi
}

# _install_grub()
#
# Install GRUB bootloader based on boot mode (UEFI vs BIOS).
# Mirrors void-installer's set_bootloader() approach:
#   - UEFI: grub-install --target=<arch>-efi --efi-directory=/boot/efi
#   - BIOS: grub-install /dev/sdX (no --target needed)
# ---------------------------------------------------------------------------
_install_grub() {
    log_info "Step 13: Installing GRUB bootloader"

    if [[ "${CHROOT_BOOT_MODE}" == "uefi" ]]; then
        # Detect EFI architecture (32-bit vs 64-bit) matching void-installer
        local efi_bits
        efi_bits=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || echo "64")
        local efi_target="x86_64-efi"
        [[ "${efi_bits}" == "32" ]] && efi_target="i386-efi"

        if ! chroot "${CHROOT_TARGET_DIR}" grub-install \
            --target="${efi_target}" \
            --efi-directory=/boot/efi \
            --bootloader-id=void_grub \
            --recheck; then
            log_error "grub-install failed for UEFI on ${CHROOT_TARGET_DIR}"
            return 1
        fi
        log_info "GRUB installed for UEFI (${efi_target})"
    else
        # BIOS: install GRUB to the MBR of the target disk via GRUB's biosdisk
        # module. On real hardware (SATA/NVMe) biosdisk resolves the block
        # device immediately, so this succeeds on the first attempt.
        #
        # Under virtualised environments (QEMU/SeaBIOS) firmware does not finish
        # enumerating its boot devices until POST is well underway: the guest's
        # /sys/dev/block/<dev> view stays empty and the ACPI RSDTR boot-order
        # table is written late, so `grub-install /dev/sdX` fails with
        # "cannot find a GRUB drive" when it runs at the bootloader step. We
        # therefore retry with a bounded backoff until the disk is enumerated.
        # On real hardware this resolves on attempt 1; under QEMU it simply
        # waits for SeaBIOS to finish its POST — deterministic across both.
        local disk_base grub_device rc attempt max_attempts=40 backoff=10
        disk_base=$(basename "${TARGET_DISK:-/dev/sda}")
        
        # If the device is a partition, find its parent disk.
        # lsblk -no PKNAME returns the parent name (e.g., 'sda' for '/dev/sda1').
        # If it's already a disk, it returns the same name or an empty string.
        local parent_name
        if command -v lsblk >/dev/null 2>&1; then
            parent_name=$(lsblk -no PKNAME "${TARGET_DISK}" 2>/dev/null | head -n 1 | tr -d '\n')
        fi
        
        if [[ -n "${parent_name}" ]]; then
            grub_device="/dev/${parent_name}"
        else
            grub_device="/dev/${disk_base}"
        fi
        log_info "BIOS: installing GRUB (i386-pc) on ${grub_device}"
        if ! chroot "${CHROOT_TARGET_DIR}" grub-install --no-floppy --recheck --force --skip-fs-probe "${grub_device}" >>"${GRUB_LOG:-/dev/null}" 2>&1; then
            log_error "grub-install failed for BIOS on ${grub_device}"
            return 1
        fi

        if grep -q "cannot find a GRUB drive" "${GRUB_LOG:-/dev/null}"; then
            log_error "grub-install failed for BIOS: could not find GRUB drive for ${grub_device} (likely due to LUKS+Chroot environment)"
            return 1
        fi

        log_success "GRUB installed for BIOS on ${grub_device}"
    fi

    # Ensure /boot/grub/ directory exists before generating config
    mkdir -p "${CHROOT_TARGET_DIR}/boot/grub"

    # Generate GRUB config. On encrypted systems grub-probe warns that the
    # cryptdevice mapper is not active yet; this is expected and tolerated, but
    # we still gate on the output file actually being written (non-empty).
    if ! chroot "${CHROOT_TARGET_DIR}" grub-mkconfig -o /boot/grub/grub.cfg; then
        log_error "grub-mkconfig failed"
        return 1
    fi
    log_info "Step 13: GRUB configuration generated at /boot/grub/grub.cfg"

    # Verify the config file was actually written and report its size.
    local grub_cfg_path="/boot/grub/grub.cfg"
    local grub_cfg_size
    if [ -s "${CHROOT_TARGET_DIR}/${grub_cfg_path}" ]; then
        grub_cfg_size=$(wc -c < "${CHROOT_TARGET_DIR}/${grub_cfg_path}")
        log_success "GRUB config generated: ${grub_cfg_path} (${grub_cfg_size} bytes)"
    else
        log_error "GRUB config NOT generated or empty: ${grub_cfg_path}"
        return 1
    fi
}

# _configure_grub_terminal()
#
# Configure GRUB terminal output in /etc/default/grub.
# When TEXTCONSOLE is truthy, force text-mode console (GRUB_TERMINAL_OUTPUT=console).
# Otherwise leave GRUB_TERMINAL_OUTPUT at its default (text + console combined).
# ───────────────────────────────────────────────────────────────────
_configure_grub_terminal() {
    local grub_cfg="${CHROOT_TARGET_DIR}/etc/default/grub"

    if [[ ! -f "${grub_cfg}" ]]; then
        log_warn "GRUB config not found at ${grub_cfg}, skipping terminal configuration"
        return 0
    fi

    local textconsole="${TEXTCONSOLE:-no}"
    textconsole="${textconsole,,}"   # lowercase for robust matching

    if [[ ! "${textconsole}" =~ ^(yes|1|true|on)$ ]]; then
        log_info "GRUB terminal: leaving default (text + console)"
        return 0
    fi

    # Force text-mode console
    if grep -q "^#*GRUB_TERMINAL_OUTPUT=" "${grub_cfg}" 2>/dev/null; then
        sed -i 's|^#*GRUB_TERMINAL_OUTPUT=.*|GRUB_TERMINAL_OUTPUT=console|' "${grub_cfg}"
    else
        echo "GRUB_TERMINAL_OUTPUT=console" >> "${grub_cfg}"
    fi

    log_info "GRUB terminal configured: console (TEXTCONSOLE=${textconsole})"
}

# _generate_fstab()
#
# Generate /etc/fstab using UUIDs instead of device paths.
# ---------------------------------------------------------------------------
# _create_swap_file()
#
# Create and activate a swap file in the target root filesystem.
# Uses fallocate for all filesystems (allocates blocks).
# For btrfs: disables CoW on just the swap file via chattr +C (the rest of
# the root keeps CoW). The no-COW attribute persists in the file's inode.
# Must be called AFTER mount_filesystems() and BEFORE _generate_fstab().
#
# Arguments:
#   $1 - target_dir (mounted root filesystem)
#
# Returns:
#   0 on success
#   1 on failure
# ---------------------------------------------------------------------------
_create_swap_file() {
    local target_dir="$1"
    local swap_size="${SWAP_SIZE:-1G}"
    local swap_file="${target_dir}/swapfile"
    local fs_type

    log_info "Creating swap file: ${swap_file} (${swap_size})..."

    # Detect filesystem type of the target directory
    fs_type=$(findmnt -n -o FSTYPE "${target_dir}" 2>/dev/null || echo "unknown")

    # 1. For btrfs: set the no-COW attribute (chattr +C) on an EMPTY file,
    #    BEFORE allocating. chattr +C on a fallocated file silently no-ops
    #    (returns 0 but does NOT set the COW attribute), leaving the file COW
    #    and swapon failing with EINVAL. So: create empty, set no-COW, THEN
    #    allocate — fallocate respects the no-COW attribute and allocates
    #    no-COW blocks (verified on a live btrfs). This replaces the
    #    whole-root nodatacow remount (which disabled CoW across all of /)
    #    with a per-file attribute, leaving the rest of the root with CoW.
    if [[ "${fs_type}" == "btrfs" ]]; then
        : > "${swap_file}"
        if chattr +C "${swap_file}" 2>/dev/null; then
            log_info "CoW disabled on swap file via chattr +C"
        else
            log_warn "chattr +C failed on swap file — CoW remains enabled on it (swap corruption risk)"
        fi
    fi

    # 2. Create file / allocate blocks (fallocate allocates; for btrfs the file
    #    was pre-created empty in step 1, so fallocate allocates no-COW blocks).
    #    swapon requires all blocks to be allocated (not sparse).
    if ! fallocate -l "${swap_size}" "${swap_file}"; then
        log_warn "fallocate failed, falling back to truncate..."
        truncate -s "${swap_size}" "${swap_file}"
    fi

    # 3. Set permissions (swap files must be 600)
    chmod 600 "${swap_file}"

    # 4. Format as swap
    if ! mkswap "${swap_file}"; then
        log_error "_create_swap_file: Failed to mkswap ${swap_file}"
        return 1
    fi

    # 5. Activate swap
    if ! swapon "${swap_file}"; then
        log_error "_create_swap_file: Failed to swapon ${swap_file}"
        return 1
    fi

    log_success "Swap file activated: ${swap_file}"
    return 0
}
_generate_fstab() {
    log_info "Generating /etc/fstab with UUIDs"


    local target_dir="${CHROOT_TARGET_DIR}"
    local fstab_content=""
    local i entry _depth idx

    # Get partition count
    local num_partitions="${#PART_MOUNTS[@]}"

    # Order entries shallowest-first (parent before child) so that at boot
    # `mount -a` mounts a parent partition (e.g. /boot) before a nested mount
    # point (e.g. /boot/efi). The nested directory lives on the parent
    # partition, so it only exists once the parent is mounted; if the child
    # were listed first, `mount -a` would fail with "mount point does not
    # exist".
    local -a depth_idx=() mp slashes key
    for ((i = 0; i < num_partitions; i++)); do
        mp="${PART_MOUNTS[$i]}"
        if [[ "${mp}" == "/" ]]; then
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

    for i in "${ordered_idx[@]}"; do
        local mount_point="${PART_MOUNTS[$i]}"
        local fs_type="${PART_FS[$i]}"
        local luks="${PART_LUKS[$i]}"

        # Skip swap partitions — handled in the swap section below
        if [[ "${mount_point}" == "/swap" ]]; then
            continue
        fi

        # Get UUID for the partition
        local device_path="${TARGET_DISK:-/dev/sda}"
        local prefix="${PARTITION_PREFIX:-}"
        local part_num=$((i + 1))
        local device="${device_path}${prefix}${part_num}"

        # If LUKS, use the mapper device
        if [[ "${luks}" == "yes" ]]; then
            local luks_name
            luks_name=$(_luks_name_from_mount "${mount_point}")
            device="/dev/mapper/luks-${luks_name}"
        fi

        local uuid
        uuid=$(blkid -s UUID -o value "${device}" 2>/dev/null || echo "")
        if [[ -n "${uuid}" ]]; then
            local mount_opts="defaults"
            # Swap file on ext4: noatime reduces metadata writes. btrfs needs
            # no special mount option — the swap file itself carries chattr +C
            # (no-COW), so the root keeps CoW.
            if [[ "${SWAP_TYPE:-}" == "file" && "${mount_point}" == "/" ]]; then
                case "${fs_type}" in
                    ext4)
                        mount_opts="defaults,noatime"
                        log_info "Root mount options for swap file: ${mount_opts}"
                        ;;
                    *)
                        log_info "Root mount options for swap file: ${mount_opts} (no special options for ${fs_type})"
                        ;;
                esac
            fi
            # Btrfs subvolume: mount the named subvolume instead of the
            # default (top-level) subvolume, which does not contain it.
            if [[ -n "${PART_SUBVOLS[$i]:-}" ]]; then
                mount_opts="${mount_opts},subvol=${PART_SUBVOLS[$i]}"
            fi
            fstab_content+="UUID=${uuid} ${mount_point} ${fs_type} ${mount_opts} 0 2\n"
        fi
    done

    # Add swap if configured
    case "${SWAP_TYPE:-none}" in
        partition)
            if [[ -n "${SWAP_UUID:-}" ]]; then
                fstab_content+="UUID=${SWAP_UUID} none swap sw 0 0\n"
            fi
            ;;
        file)
            fstab_content+="/swapfile none swap sw 0 0\n"
            ;;
        none)
            # No swap entry
            ;;
    esac

    # Write fstab
    echo -e "${fstab_content}" > "${target_dir}/etc/fstab"
    log_info "fstab generated with ${num_partitions} entries"
}
