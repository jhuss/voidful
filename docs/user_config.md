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

Generated and set inside the target. Void Linux uses `/etc/locale.conf` as the locale configuration file. The default locale is `C.UTF-8` if `${LOCALE}` is unset. If the specified locale is not available in `/etc/default/libc-locales`, the installer warns and falls back to `C.UTF-8`.

### Keymap

Set inside the target using `loadkeys` (Void Linux does not use `/etc/vconsole.conf`). To persist the keymap across reboots, create a runit service or add `loadkeys ${KEYMAP}` to `/etc/profile.d/`.

## Root Password

The root password is set using `chpasswd -c SHA512` (consistent with void-installer):

### Environment Variable

Set via `chroot "${TARGET_DIR}" sh -c "printf '%s\n' 'root:${ROOT_PASS}' | chpasswd -c SHA512"`. `printf` is used instead of `echo` to avoid exposing the password in the process list.

### Interactive Prompt

If `ROOT_PASS` is empty, the installer prompts for the root password twice using `chroot "${TARGET_DIR}" passwd root`.

## Regular User Creation

### Flow

When `CREATE_USER="yes"`, the installer executes the following steps inside chroot:

1. **Validate username**: Check against `^[a-z_][a-z0-9_-]*$`
2. **Create user**: Single `useradd` command with groups and comment
3. **Set password**: Via `chpasswd -c SHA512` or interactive prompt
4. **Verify home directory**: Ensure `/home/${USER_LOGIN}` exists with correct ownership

### Example

```bash
chroot "${TARGET_DIR}" useradd -m -s "/bin/bash" -G "wheel,audio,video" -c "Juan Perez" "juan"
chroot "${TARGET_DIR}" sh -c "printf '%s\n' 'juan:${USER_PASS}' | chpasswd -c SHA512"
chown -R juan:juan "${TARGET_DIR}/home/juan"
chmod 700 "${TARGET_DIR}/home/juan"
```

## Sudo Configuration

The installer configures sudo access for the `wheel` group inside chroot. The configuration follows void-installer logic:

### User in `wheel` Group

If the user is a member of `wheel`, configure group-based sudo access by creating `/etc/sudoers.d/wheel` with `%wheel ALL=(ALL:ALL) ALL`, then validate with `visudo -c`.

### User NOT in `wheel` Group

If the user is NOT in `wheel` but `CREATE_USER="yes"`, create a per-user sudoers file at `/etc/sudoers.d/${USER_LOGIN}`.


## Password Handling

### Priority Order

1. **Environment variable**: If `ROOT_PASS` or `USER_PASS` is set, use it directly
2. **Interactive prompt**: If unset, prompt the user twice for confirmation
3. **Error**: If running non-interactively (no TTY) and no env var is set, exit with error

### Security Notes

- Passwords must never be committed to version control
- Use `ROOT_PASS` and `USER_PASS` env vars in CI/CD or automated environments
- Interactive prompting is recommended for local installations
- Minimum password length: 8 characters (enforced when set via env var)
- `chpasswd -c SHA512` is used consistently for both root and user passwords

## Validation Rules

| Rule | Check | Error |
|---|---|---|
| Username format | `^[a-z_][a-z0-9_-]*$` | "Invalid username format" |
| Username uniqueness | Not already in `/etc/passwd` | "Username already exists" |
| Password length | `USER_PASS` >= 8 chars | "Password too short" |
| Group existence | Members of `USER_GROUPS` validated inside chroot (`/etc/group` on target); may not exist on live ISO | "Group not found: X" |
| CREATE_USER consistency | `USERNAME` set when `CREATE_USER="yes"` | "USERNAME required when CREATE_USER=yes" |
| User login field | `USER_LOGIN` is set (separate from display name) | "USER_LOGIN required" |

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

Copy signing keys from `/var/db/xbps/keys/` to `${TARGET_DIR}/var/db/xbps/keys/` before any package operation or validation.

### Step 4: Copy Network Configuration

Copy `/etc/resolv.conf` from the live ISO before any package operations inside chroot. This file is removed during Teardown (step 6 in the pipeline) to prevent host network configuration from persisting on the target system. See `docs/clone_mode.md`.

### Step 5: Validate Required Commands

Before entering chroot, validate that `visudo`, `chpasswd`, `useradd`, and `userdel` are available in the target.

**Commands validated:**
- `visudo` — Sudo configuration editor
- `chpasswd` — Batch password setting (used for root and user passwords)
- `useradd` — User account creation
- `userdel` — User account deletion

## Initramfs / dracut Rebuild

This step runs **inside the chroot**, after all system configuration is complete but before bootloader installation. It rebuilds the initramfs with appropriate flags depending on whether LUKS encryption is used.

### When it runs

It is **step 12** in the chroot configuration sequence (see table above). It executes after:
- Fix root ownership (step 1)
- Copy /etc/skel files (step 2)
- Set hostname, locale, keymap (steps 3–5)
- Set passwords (steps 6–8)
- Create user and configure sudo (steps 7–9)
- Enable runit services (step 10)
- Configure network (step 11)

It executes **before**:
- Configure GRUB terminal (step 13)
- Install bootloader (step 14)

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
| 6 | Set root password | Via `chpasswd -c SHA512` or interactive prompt |
| 7 | Create regular user | `useradd` with groups and comment |
| 8 | Set user password | Via `chpasswd -c SHA512` or interactive prompt |
| 9 | Configure sudo | `/etc/sudoers.d/wheel` or per-user file |
| 10 | Enable runit services | Parse `ENABLED_SERVICES` and enable each |
| 11 | Configure network | DHCP, static, or wireless setup |
| 12 | Rebuild initramfs | dracut with appropriate flags (LUKS or non-LUKS) |
| 13 | Configure GRUB terminal | TEXTCONSOLE option (if "1") |
| 14 | Install bootloader | `grub-install` (if `BOOTLOADER="grub"`) |

### Error Handling Pattern for Chroot Commands

Under `set -e`, any chroot command failure will cause the script to exit immediately. Wrap chroot commands with error handling to provide clear error messages. Use exit code 5 for chroot configuration failures (consistent with `docs/exit_codes.md`).

### Step 1: Fix Root Ownership

Set root ownership and permissions: `chroot "${TARGET_DIR}" chown root:root /` and `chroot "${TARGET_DIR}" chmod 755 /`.

### Step 2: Copy /etc/skel Files to Root

Copy default shell configuration files from `/etc/skel` to the root home directory using `find` to copy only regular files (not subdirectories):

```bash
find "${TARGET_DIR}/etc/skel" -maxdepth 1 -type f -exec cp {} "${TARGET_DIR}/root/" \;
```

### Step 3: Configure GRUB Terminal (TEXTCONSOLE)

If `TEXTCONSOLE="1"`, force console terminal in GRUB:

```bash
sed -i 's/^#GRUB_TERMINAL_INPUT.*/GRUB_TERMINAL_INPUT="console"/' "${TARGET_DIR}/etc/default/grub"
sed -i 's/^#GRUB_TERMINAL_OUTPUT.*/GRUB_TERMINAL_OUTPUT="console"/' "${TARGET_DIR}/etc/default/grub"
```

Default is `0` (graphical GRUB). Valid values: `0` or `1`.

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
USER_GROUPS="wheel,audio,video"
```


