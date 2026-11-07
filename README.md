# voidful

**voidful** is an unattended, fully offline installer for Void Linux. It runs from the official Void Linux live ISO and performs a complete bare-metal installation — partitioning, optional LUKS encryption, system clone, post-install configuration, and GRUB bootloader installation — with **zero internet connection**.

Version: `0.1.0` · License: [MIT](LICENSE)

## How it works

voidful uses a **system clone** approach (similar to `void-installer --source=local`):

1. **Pre-flight** — detect boot mode (UEFI/BIOS), verify root privileges, validate the target disk.
2. **Configuration** — load a shell-sourceable config file, execute `define_partition()` calls, run cross-validation.
3. **Partition & format** — write the partition table via `sfdisk` (GPT for UEFI, MBR/DOS for BIOS), format filesystems (`ext4`, `btrfs`, `vfat`, `xfs`), set up LUKS containers, mount everything.
4. **System clone** — copy the entire live rootfs to the target disk with `tar --one-file-system --xattrs` (extract restores xattrs via `--xattrs-include='*'`).
5. **Post-clone cleanup** — remove live-environment files, the live user account, and unnecessary packages.
6. **Chroot configuration** — 20-step sequence: hostname, locale, keymap, timezone, issue, passwords, user + sudo, runit services, network, LUKS keyfile + crypttab, initramfs rebuild (dracut), GRUB installation, swap file, btrfs default subvolume, fstab generation.
7. **Teardown** — unmount filesystems, close LUKS mappers, sync.
8. **End-action** — `shutdown`, `reboot`, `script`, `func`, or `none`.

No network access is needed at any point: the installed system is the live ISO's own rootfs — no packages are ever downloaded (the ISO only carries repodata metadata, which is never used for installation), and cleanup only *removes* unnecessary live-environment packages.

## Requirements

- Official Void Linux **live ISO** (x86_64 tested; other architectures untested)
- Target disk with at least **8 GB** (GPT or MBR partition table)
- **root** access inside the live session
- bash 4.0+

The installer only uses binaries pre-packaged in the live ISO (`sfdisk`, `mkfs.*`, `cryptsetup`, `tar`, `grub-install`, `xbps-*`, `dracut`, …). No additional tools are required.

## Quick start

1. **Boot the live ISO** on the target machine.
2. **Copy the installer** into the live session (e.g., from another host):
   ```bash
   scp -r voidful anon@<live-iso-ip>:/home/anon/
   ```
3. **Verify the target disk** — double-check the device name before running anything:
   ```bash
   lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
   ```
4. **Validate the configuration** (no disk operations):
   ```bash
   cd /home/anon/voidful
   sudo ./install.sh --config configs/example-uefi.conf --target-disk /dev/sda --dry-run
   ```
5. **Run the install**:
   ```bash
   sudo ./install.sh --config configs/example-uefi.conf --target-disk /dev/sda
   ```
   The installer wipes the target disk, installs, and by default powers the machine off. Use `--end-action reboot` to reboot instead.

A full log of the run is written to `/var/log/voidful.log` on the live system.

### Safety

- The installer **destroys all data on `TARGET_DISK`**. Verify the device with `lsblk` before running.
- Pre-flight checks confirm you are root and that the target disk is a valid block device (and not the CD-ROM drive `sr0`).
- Interrupting the installer (Ctrl-C / SIGTERM) triggers clean unmount + LUKS close and exits with code `8`.

## Configuration

### Config file discovery

In this order:

1. `--config FILE` (explicit path)
2. `$CONFIG_FILE` environment variable
3. `configs/example-uefi.conf` (default)
4. First `configs/*.conf` in alphabetical order

### Example config files

| File | Layout |
|---|---|
| `configs/example-uefi.conf` | UEFI + ext4: EFI partition + root |
| `configs/example-bios-ext4.conf` | Legacy BIOS + ext4: single root partition |
| `configs/example-btrfs.conf` | UEFI + Btrfs with subvolumes |
| `configs/example-encrypted.conf` | UEFI + LUKS: encrypted root, unencrypted `/boot` + `/boot/efi` |
| `configs/example-encrypted-btrfs.conf` | UEFI + dual LUKS Btrfs: encrypted `/` and `/home` |
| `configs/example-minimal.conf` | Root partition + swap, no regular user |

### Global settings

| Variable | Default | Description |
|---|---|---|
| `TARGET_DISK` | — | Target disk (e.g., `/dev/sda`) |
| `TARGET_DIR` | `/mnt` | Mount point for the root partition |
| `END_ACTION` | `shutdown` | `shutdown`, `reboot`, `script`, `func`, `none` |
| `BOOTLOADER` | `grub` | `grub` or `none` |
| `SWAP_TYPE` | — | `partition`, `file`, or `none` |
| `SWAP_SIZE` | — | Absolute size, e.g. `4G` (no `+` prefix, no `T` suffix) |
| `HOSTNAME` | `voidful` | System hostname |
| `LOCALE` | `en_US.UTF-8` | System locale |
| `KEYMAP` | `us` | Console keymap |
| `TIMEZONE` | `""` (system default) | Timezone name under `/usr/share/zoneinfo` (e.g., `America/Argentina/Buenos_Aires`) |
| `ROOT_PASS` | — | Root password |
| `CREATE_USER` | `no` | `yes`/`no` — create a regular user |
| `USER_LOGIN` | — | Login name (required when `CREATE_USER="yes"`) |
| `USERNAME` | `${USER_LOGIN}` | Display name (GECOS comment) |
| `USER_PASS` | — | Regular user password |
| `USER_SHELL` | `/bin/bash` | Login shell |
| `USER_GROUPS` | `wheel` | Comma-separated supplementary groups |
| `TEXTCONSOLE` | `0` | `1` forces text-mode GRUB menu |
| `ENABLED_SERVICES` | — | Comma-separated runit services to enable |
| `NETWORK_MODE` | `dhcp` | `dhcp` or `static` |
| `NETWORK_DEVICE` | — | Interface name (e.g., `eth0`) |
| `NETWORK_IP` | — | Static IP address |
| `NETWORK_GATEWAY` | — | Default gateway |
| `DNS_SERVERS` | — | Comma-separated DNS servers (static mode only; empty = via DHCP) |
| `ISSUE_MESSAGE` | — | Custom `/etc/issue` content (optional) |

### Partition definitions

Each partition is declared with `define_partition`:

```bash
define_partition \
  --mount "/boot/efi" \
  --size "+100M" \
  --fs "vfat" \
  --luks "no"
```

| Parameter | Required | Notes |
|---|---|---|
| `--mount` | yes | Mount point (`/`, `/home`, `/boot/efi`, `/boot`) |
| `--size` | no | `+100M`, `4G`, `1T`, or empty = remaining space (last partition only) |
| `--fs` | yes | `ext4`, `btrfs`, `vfat`, `xfs` |
| `--luks` | no | `yes`/`no` (default `no`) |
| `--subvol` | no | Btrfs subvolume (e.g., `@`, `@home`) |

Layout rules enforced by validation:

- At least one partition must be mounted at `/`.
- UEFI systems require an unencrypted `vfat` partition at `/boot/efi`.
- LUKS requires an **unencrypted `/boot` partition** (kernel + initramfs); on UEFI, `/boot/efi` as well.
- Only the last partition may leave `--size` empty.
- All partitions are contiguous on the target disk.

### Secrets: environment variables

Passwords and LUKS credentials should be passed via environment variables, not stored in the config file:

```bash
export ROOT_PASS="strong-root-password"
export USER_PASS="strong-user-password"
export LUKS_PASSPHRASE="strong-luks-passphrase"   # and/or
export LUKS_KEYFILE="/root/luks.key"
```

- If any partition has `--luks "yes"`, at least one of `LUKS_PASSPHRASE` / `LUKS_KEYFILE` is required. Both can be set: the keyfile enables automated boot, the passphrase is the interactive fallback.
- Config file values take precedence over environment variables when both are set. The recommended pattern is to leave `ROOT_PASS` / `USER_PASS` unset in the config file and export them in the environment.
- If `ROOT_PASS` / `USER_PASS` are not set anywhere, the corresponding password is **not set** on the installed system — there is no interactive prompt. Always set them.

### Override priority

1. **CLI arguments** (`--target-disk`, `--end-action`, …)
2. **Config file** values
3. **Hardcoded defaults**

Environment variables act as a fallback for values the config file does not set.

## CLI options

| Option | Description |
|---|---|
| `--config FILE` | Path to configuration file |
| `--target-disk DISK` | Target disk device (e.g., `/dev/sda`; `/dev/` prefix optional) |
| `--target-dir DIR` | Mount point for root partition (default `/mnt`) |
| `--end-action ACTION` | `shutdown` (default), `reboot`, `script`, `func`, `none` |
| `--bootloader LOADER` | `grub` (default) or `none` |
| `--dry-run` | Validate configuration and exit without touching the disk |
| `--test-mode` | Print the full operational plan (sfdisk layout, mounts, tar command, chroot steps) without performing any operation |
| `--reinstall` | Reinstall over an existing installation (unmounts partitions and closes LUKS mappers first) |
| `--verbose` | Debug-level logging |
| `--help` / `--version` | Help / version |

### End actions

All end actions run **after** teardown (unmount + LUKS close + sync):

- `shutdown` — power off (default)
- `reboot` — reboot
- `script` — run `END_ACTION_SCRIPT` (path to an executable script, run outside the chroot)
- `func` — call a bash function whose name matches `END_ACTION_FUNC`; the function must be defined in the parent shell and exported with `export -f`
- `none` — leave the system running

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Error: config validation failure, missing config file, or failure of any pipeline stage (partitioning, LUKS, clone, cleanup, chroot configuration, bootloader, mounting) |
| `2` | Disk error (target disk not found / not a block device) |
| `3` | Permission error (not root) |
| `8` | User interruption (SIGINT/SIGTERM/SIGHUP, or a broken pipe) |
| `9` | Unknown `END_ACTION` value (any non-zero exit of a `script`/`func` end-action propagates that code instead) |

## Testing

- **Static analysis:** `shellcheck install.sh lib/*.sh`
- **End-to-end QEMU boot test:** `tests/qemu_boot_test.sh` boots the live ISO in a QEMU/libvirt VM, runs the installer on a fresh qcow2 disk, and verifies the installed system boots. See `docs/e2e_boot_test.md` for options and safety rules.
- **Installed-system verification:** `tests/verify_installed_system.sh` runs inside the installed system and checks hostname, locale, keymap, timezone, user/sudo, package cleanup, fstab, GRUB, and runit services.

## Repository structure

```text
install.sh            Main orchestrator (pipeline stages, CLI, signal handling)
lib/
  logging.sh          Terminal output + /var/log/voidful.log
  hardware.sh         UEFI/BIOS detection, disk discovery
  config.sh           define_partition() + validate_config()
  partitioning.sh     sfdisk layout, formatting, LUKS, mounting
  clone.sh            tar-based rootfs clone
  cleanup.sh          Post-clone package/file removal
  chroot_tasks.sh     Chroot configuration (20 steps)
configs/              Example configuration files
docs/                 Module documentation + GLOSSARY
tests/                QEMU boot harness + installed-system verification
```

## Documentation

- `docs/configuration.md` — full configuration reference
- `docs/cli_interface.md` — CLI specification
- `docs/partitioning.md`, `docs/luks.md`, `docs/clone_mode.md`, `docs/user_config.md` — module internals
- `docs/end_actions.md`, `docs/exit_codes.md`, `docs/signal_handling.md`, `docs/progress.md`
- `docs/limitations.md` — known limitations
- `docs/e2e_boot_test.md` — testing
- `docs/GLOSSARY.md` — project domain terminology
- `AGENTS.md` — development conventions

## Limitations

- **Offline only** — no network installation, no custom package repositories.
- **LVM / RAID** — not supported. The partition table follows the boot mode: GPT (UEFI) or MBR/DOS (BIOS); partitions must be contiguous.
- **GRUB only** — no systemd-boot.
- **One regular user** — multiple users are not supported.
- **Wired networks only** — `dhcp` and `static`; wireless requires manual `wpa_supplicant` configuration.
- **x86_64 tested** — aarch64/riscv64 untested.

See `docs/limitations.md` for details.

