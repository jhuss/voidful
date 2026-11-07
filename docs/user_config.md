# User & System Configuration

This document covers user creation, password management, hostname, locale, and keymap configuration inside the target chroot environment.


In clone mode, the target system already contains a fully functional Void Linux installation copied from the live environment. The chroot configuration steps below **override** the live system settings with the user's custom configuration:

- Hostname, locale, keymap, and passwords are overwritten
- User accounts from the live environment are removed (see `docs/clone_mode.md`)
- New user accounts are created based on configuration
- The cloned system retains all live system packages until cleanup removes them

## System Configuration

The installer configures system-wide settings inside the chroot:

### Hostname

Written to `/etc/hostname` inside the target. The actual hostname is applied at boot by the `hostname` service (enabled by default in Void Linux).

### Locale

Set inside the target by writing `LANG=${LOCALE}` to `/etc/locale.conf` (no generation or availability check is performed). The default locale is `en_US.UTF-8` when `${LOCALE}` is unset.

### Keymap

Set inside the target using `loadkeys` (run with `|| true` inside the chroot; failure is non-fatal). Persistence across reboots is the write of `KEYMAP=${KEYMAP}` to `/etc/vconsole.conf` (Void Linux does use `/etc/vconsole.conf`; no runit service or `/etc/profile.d/` entry is created).

### Timezone

When `TIMEZONE` is set, the installer validates in stage 2 (before any disk operation) that `/usr/share/zoneinfo/${TIMEZONE}` exists as a regular file, then sets inside the chroot:

```bash
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
```

When unset or empty, the target keeps the cloned live system's default timezone (UTC on the stock live ISO).

## Root Password

The root password is set using `chpasswd -c SHA512` (consistent with void-installer):

### Environment Variable

Set via `chroot "${TARGET_DIR}" sh -c "printf '%s\n' 'root:${ROOT_PASS}' | chpasswd -c SHA512"`. `printf` is used instead of `echo` to avoid exposing the password in the process list.

### When Unset

If `ROOT_PASS` is empty, the root password is **skipped** (a `log_info` message is emitted; no interactive prompt is shown and no password is set on the target).

## Regular User Creation

### Flow

When `CREATE_USER="yes"`, the installer executes the following steps inside chroot:

1. **Validate username**: Check against `^[a-z][a-z0-9_-]{0,31}$` (chroot stage)
2. **Create user**: Single `useradd` command with primary group, groups and comment
3. **Set password**: Via `chpasswd -c SHA512` (skipped with a log message when `USER_PASS` is unset)
4. **Set home ownership**: `chown -R ${USER_LOGIN}:` on `/home/${USER_LOGIN}` (no `chmod 700` is applied)

### Example

```bash
chroot "${TARGET_DIR}" useradd -m -g users -G "wheel" -s "/bin/bash" -c "Juan Perez" "juan"
chroot "${TARGET_DIR}" sh -c "printf '%s\n' 'juan:${USER_PASS}' | chpasswd -c SHA512"
chown -R juan: "${TARGET_DIR}/home/juan"
```

## Sudo Configuration

The installer configures sudo access for the `wheel` group inside chroot. The configuration is **unconditional** — it does not depend on whether the user is a member of `wheel`:

- `/etc/sudoers.d/wheel` is always written with `%wheel ALL=(ALL) SETENV: ALL` and `chmod 0440` applied.
- No per-user sudoers file is created and no `visudo -c` validation is run.
- Users created with `USER_GROUPS` containing `wheel` (the default) gain sudo access through the group rule.


## Password Handling

### Resolution

1. **Value set** (config file or environment variable, config wins): hashed with `chpasswd -c SHA512` via `printf` (no password in the process list)
2. **Value unset**: the password step is **skipped** with a `log_info` message — no interactive prompt, no TTY requirement, no error

### Security Notes

- Passwords must never be committed to version control
- Use `ROOT_PASS` and `USER_PASS` (env var or config) in CI/CD or automated environments
- No minimum password length is enforced
- `chpasswd -c SHA512` is used consistently for both root and user passwords

## Validation Rules

| Rule | Check | Error |
|---|---|---|
| Username format | `^[a-z][a-z0-9_-]{0,31}$` (chroot stage) | "Invalid username format" |
| `USER_LOGIN` set when `CREATE_USER="yes"` | Required for user creation; when unset, user creation is **silently skipped** with a log message (no error) | — |
| `USER_GROUPS` validation | **Not performed** — `useradd -G` failures are logged but non-fatal | — |
| Password | `USER_PASS`/`ROOT_PASS` used as-is when set; no length check; skipped when unset | — |

## Chroot Preparation (Ordered Steps)

Execute these steps **in order** before entering chroot:

### Step 1: Mount Bind Filesystems

Mount bind filesystems:
- `proc`: `mount --rbind /proc ${TARGET_DIR}/proc`
- `dev`: `mount --rbind /dev ${TARGET_DIR}/dev`
- `devpts`: `mount -t devpts devpts ${TARGET_DIR}/dev/pts`
- `sys`: `mount --rbind --read-only /sys ${TARGET_DIR}/sys`

**Note:** Only `sys` is mounted read-only. `proc` and `dev` require read-write access.

### Step 2: Mount efivarfs (UEFI Only)

Mount `efivarfs` at `${TARGET_DIR}/sys/firmware/efi/efivars`.

### Step 3: Copy XBPS Signing Keys

Copy XBPS signing keys from `/etc/xbps.d` to `${TARGET_DIR}/etc/xbps.d` before any package operation or validation.

### Step 4: Copy Network Configuration

Copy `/etc/resolv.conf` from the live ISO before any package operations inside chroot. This file is removed by `_unmount_bind_filesystems()` at the end of the chroot stage (not during Teardown) to prevent host network configuration from persisting on the target system. See `docs/clone_mode.md`.


## Initramfs / dracut Rebuild

This step runs **inside the chroot**, after all system configuration is complete but before bootloader installation. It rebuilds the initramfs with appropriate flags depending on whether LUKS encryption is used.

### When it runs

It is **step 16** in the chroot configuration sequence (see table above). It executes after:
- Fix root ownership (step 1)
- Copy /etc/skel files (step 2)
- Set hostname, locale, keymap (steps 3–5)
- Set passwords (steps 8–10)
- Create user and configure sudo (steps 9–11)
- Enable runit services (step 13)
- Configure network (step 12)

It executes **before**:
- Configure GRUB terminal (step 17)
- Create swap file (step 18)

### Chroot preparation vs. dracut execution

Chroot preparation (bind mounts, efivarfs, XBPS keys, resolv.conf) happens **outside the chroot** before entering it. The dracut command itself runs **inside the chroot** after all configuration steps are done.

### Configuration details

For detailed dracut initramfs rebuild instructions (both LUKS and non-LUKS), see `docs/luks.md`.

## Chroot Configuration Steps

After chroot preparation, execute the following configuration steps in order.

### Complete Chroot Configuration Sequence

All configuration steps inside the chroot environment, in order:

| # | Step | Description |
|---|------|-------------|
| 1 | Fix root ownership | `chown root:root /` and `chmod 755 /` |
| 2 | Copy /etc/skel files | Copy dotfiles and non-dotfiles to root home |
| 3 | Set hostname | Write to `/etc/hostname` |
| 4 | Configure locale | Generate and set locale via `/etc/locale.conf` |
| 5 | Configure keymap | Set via `loadkeys` and persist |
| 6 | Configure timezone | `ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime` (only when TIMEZONE is set) |
| 7 | Set issue file | Write custom `/etc/issue` content |
| 8 | Set root password | Via `chpasswd -c SHA512` (skipped with a log message when `ROOT_PASS` is unset) |
| 9 | Create regular user | `useradd` with primary group, groups and comment |
| 10 | Set user password | Via `chpasswd -c SHA512` (skipped with a log message when `USER_PASS` is unset) |
| 11 | Configure sudo | Always `/etc/sudoers.d/wheel` (`%wheel ALL=(ALL) SETENV: ALL`) |
| 12 | Configure network | DHCP or static setup |
| 13 | Enable runit services | Ensure `/var/service` exists (create it if absent or a dangling symlink), then `ln -s /etc/sv/<svc> /var/service/<svc>` for each service |
| 14 | Copy LUKS keyfile | Copy keyfile to `/etc/cryptsetup-keys/` (LUKS only) |
| 15 | Configure crypttab | Write `/etc/crypttab` entries for LUKS partitions |
| 16 | Rebuild initramfs | dracut with appropriate flags (LUKS or non-LUKS) |
| 17 | Install GRUB + Configure terminal | `grub-install` + `grub-mkconfig` + terminal settings |
| 18 | Create swap file | `fallocate` + `mkswap` + `swapon` (if `SWAP_TYPE="file"`) |
| 19 | Set btrfs default subvolume | Resolve the named subvolume's numeric ID via `btrfs subvolume list /`, then `btrfs subvolume set-default <numeric-id> /` (for a btrfs root defined with `--subvol`, LUKS or not). `set-default` requires the numeric ID, not the name. |
| 20 | Generate fstab | Write `/etc/fstab` with UUIDs and mount options |

### Error Handling Pattern for Chroot Commands

Under `set -e`, any chroot command failure will cause the script to exit immediately. Wrap chroot commands with error handling to provide clear error messages. Chroot configuration failures exit with code `1` (consistent with `docs/exit_codes.md`).

### Step 1: Fix Root Ownership

Set root ownership and permissions: `chroot "${TARGET_DIR}" chown root:root /` and `chroot "${TARGET_DIR}" chmod 755 /`.

### Step 2: Copy /etc/skel Files to Root

Copy default shell configuration files from `/etc/skel` to the root home directory using `find` to copy only regular files (not subdirectories):

```bash
find "${TARGET_DIR}/etc/skel" -maxdepth 1 -type f -exec cp {} "${TARGET_DIR}/root/" \;
```

### Step 6: Set Issue File

Write `/etc/issue` from `CHROOT_ISSUE_MESSAGE` (config `ISSUE_MESSAGE`), falling back to the built-in ASCII art. The content is escaped for agetty's interpretation before being written: literal backslashes are doubled so they survive rendering, while agetty escape sequences are preserved and evaluated at login time (`\r` kernel release, `\m` machine, `\n` hostname, `\e` color, `\S` os-release, `\d`/`\t` date/time).

### Step 17: GRUB Terminal and Kernel Cmdline

The installer preserves all existing settings in `/etc/default/grub` and only updates what's needed:

- **`GRUB_TERMINAL_OUTPUT`**: Set to `console` only when `TEXTCONSOLE` is a truthy value (`1`/`yes`/`true`/`on`); otherwise left at its default (text + console combined)
- **`GRUB_CMDLINE_LINUX`**: For LUKS systems, set to one `cryptdevice=UUID=<uuid>:luks-<name>` parameter per LUKS partition, plus `root=/dev/mapper/luks-root` when the root partition is LUKS, plus `rootflags=subvol=<subvol>` when the root is a btrfs subvolume (without it the kernel mounts the empty top-level subvolume) (preserves any existing args like `quiet`). Every LUKS partition needs its own `cryptdevice` parameter — the initramfs only decrypts partitions listed there.

`GRUB_TERMINAL_OUTPUT` is forced to `console` (text-mode) only when `TEXTCONSOLE` is a truthy value (`1`, `yes`, `true`, or `on`); otherwise it is left at its default (text + console combined):

```bash
# Force text-mode console only when TEXTCONSOLE is truthy
if [[ "${TEXTCONSOLE:-no}" =~ ^(yes|1|true|on)$ ]]; then
    if grep -q "^#*GRUB_TERMINAL_OUTPUT=" /etc/default/grub; then
        sed -i 's|^#*GRUB_TERMINAL_OUTPUT=.*|GRUB_TERMINAL_OUTPUT=console|' /etc/default/grub
    else
        echo "GRUB_TERMINAL_OUTPUT=console" >> /etc/default/grub
    fi
fi

# For LUKS systems, add cryptdevice (one per LUKS partition) + root=/dev/mapper/luks-root to kernel cmdline
if _has_luks_partitions; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=xxx:luks-root cryptdevice=UUID=yyy:luks-home root=/dev/mapper/luks-root\"|" /etc/default/grub
fi
```

### Step 19: Set Btrfs Default Subvolume

When the root is a btrfs partition defined with `--subvol`, the installer sets the named subvolume as the default (inside the chroot, while the root is mounted). `btrfs subvolume set-default` requires the **numeric** subvolume ID, not the name — so the installer first resolves the named subvolume's numeric ID via `btrfs subvolume list /` (the path is the last field, matched exactly), then runs `btrfs subvolume set-default <numeric-id> /`. This is belt-and-suspenders with the `rootflags=subvol=<subvol>` kernel parameter: it guarantees the kernel mounts the rootfs subvolume (not the empty top-level subvolume) and makes post-boot btrfs operations (a bare mount) land on the right subvolume. It applies whether or not the root is LUKS-encrypted. The subvolume is created earlier, during partitioning (see `docs/luks.md` / `docs/partitioning.md`).

```bash
# For a btrfs root defined with --subvol (LUKS or not)
# 1. Resolve the named subvolume's numeric ID (the path is the last field)
subvol_id=$(btrfs subvolume list / | awk -v n='@' '$NF == n { print $2; exit }')
# 2. Set the numeric ID as the default subvolume
btrfs subvolume set-default "${subvol_id}" /
```

## Example Config

```bash
HOSTNAME="void-desktop"
LOCALE="en_US.UTF-8"
KEYMAP="us"
ROOT_PASS="SecureRoot123"
CREATE_USER="yes"
USER_LOGIN="juan"
USER_PASS="SecureJuan123"
USER_SHELL="/bin/bash"
USER_GROUPS="wheel"
```


