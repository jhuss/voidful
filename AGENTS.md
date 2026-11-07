# Voidful Project Overview

This repository contains an automated, unattended offline installer for Void Linux. The system is designed to perform a complete bare-metal installation directly from a live Void Linux ISO without requiring an active internet connection.

All AI coding assistants (Agents) working on this repository must strictly adhere to the constraints, coding standards, and architectural conventions outlined below.

## Core Constraints & Safety Rules

1. **Strictly Pure Bash**: 
   - The core installer and all modules MUST be written in pure `bash` (version 4.0+).
   - Do NOT introduce external language dependencies (e.g., Python, Perl, Ruby, Node, Go, Rust).

2. **Zero Internet Dependency (ISO Offline Only)**: 
   - The installer uses a **system clone approach** (similar to `void-installer --source=local`): it copies the entire live system rootfs to the target disk via `tar --one-file-system`, then removes unnecessary packages.
   - The official Void Linux live ISO does **NOT** contain binary packages (`.tar.xz` files). It only contains:
     - The live system rootfs (squashfs image, ~837MB)
     - Repository metadata (repodata indexes in `/var/db/xbps/`)
     - Installation tools
   - Never assume network availability (`ping`, `curl`, `wget`, or remote `xbps` sync are prohibited in execution paths).
   - See `docs/limitations.md` for unsupported features and known constraints.

3. **Available Tooling Strict Bounds**:
   - Rely strictly on binaries pre-packaged in the official Void Linux Live ISO environment:
      - Disk & Filesystem: `sfdisk`, `fdisk`, `cfdisk`, `lsblk`, `blkid`, `wipefs`, `partx`, `mkfs.ext4` (symlink to mke2fs), `mkfs.vfat`, `mkfs.btrfs`, `btrfs`, `swaplabel`, `cryptsetup`, `mkswap`, `swapon`, `fallocate`, `truncate`, `chattr`, `blockdev`
      - Void Specifics: `xbps-install`, `xbps-reconfigure`, `xbps-query`, `xbps-remove`, `xbps-uhelper`, `xchroot` (part of xtools-minimal package — used during installation, removed in post-clone cleanup)
      - Core Utils & Boot: `mount`, `umount`, `chroot`, `grub-install`, `poweroff`, `reboot`, `udevadm` (eudev/mdev tool, NOT systemd), `sed`, `awk`, `grep`, `tar`, `visudo`, `findmnt`
      - Archive/Clone: `tar` (create side: `--one-file-system`, `--xattrs`, `--exclude=./var/log`, `--exclude=./etc/machine-id`; extract side: `--xattrs`, `--xattrs-include='*'`, `--preserve-permissions`)

4. **Host Safety First**:
   - Never run destructive commands (`dd`, `mkfs`, `sfdisk`, `wipefs`) without checking if the target disk matches the intended installation target variable.
   - Include strict sanity guards that prevent execution on the host machine running the development tool.

### Architecture Awareness

- **musl vs glibc**: The installer detects `ARCH` via `xbps-uhelper arch` in pre-flight and logs it for information only. The offline system-clone approach installs no packages from a repository, so the architecture does not drive repository, locale, or bootloader package selection.
- **Partition separators**: Disks using `mmc` or `nvme` naming use a `p` prefix for partitions. See `docs/hardware.md` for the full device type to prefix mapping.
- **UEFI vs BIOS detection**: Check for `/sys/firmware/efi/systab` file to determine boot mode. UEFI requires an EFI System Partition (vfat, 100M+), BIOS does not. Use `grub-install` for bootloader installation (works on both UEFI and BIOS).
### Init System: runit (NOT systemd)

Void Linux uses **runit** as its init system. **systemd is NOT available and MUST NOT be used.** This is a critical architectural constraint that affects every aspect of the installer and the installed system.

**NEVER use any of these in code or documentation:**
- `systemctl` — does not exist in Void Linux
- `systemd`, `systemd-tmpfiles`, `systemd-journald` — not present
- `.service` / `.target` / `.scope` units — runit uses `/etc/sv/` directories
- `journalctl` — Void uses `/var/log/` files
- `dbus` — not installed by default
- `udev` — Void uses `eudev` or `mdev`, not `systemd-udev`
- `logind` — not present

**DO use these for runit:**
- Service enable: `ln -s /etc/sv/<service> /var/service/<service>`
- Service disable: `rm /var/service/<service>`
- Service directory: `/etc/sv/<service>/` (must contain a `run` script)
- Service config: `/etc/sv/<service>/conf`
- List running: `sv status /var/service/*`
- List available: `ls /etc/sv/`

**Validation rule**: If any code references `systemctl`, `systemd`, `.service`, or `journalctl`, it is a bug. Void Linux uses runit exclusively. The installer and the installed system MUST use runit for all service management.

## Repository Structure

```text
.
├── AGENTS.md                  # Instructions for AI Agents (this file)
├── README.md                  # Project overview and quick start
├── .agents/                   # Agent proposals and plans (see "Agent Proposal & Planning Rules")
├── install.sh                 # Main entrypoint script (orchestrator)
├── lib/
│   ├── logging.sh             # Terminal output and logging utilities
│   ├── hardware.sh            # UEFI/BIOS, CPU, and disk discovery helpers
│   ├── config.sh              # define_partition() and validate_config()
│   ├── partitioning.sh        # sfdisk layout generators and formatting routines
│   ├── clone.sh               # System clone operations (tar-based rootfs copy)
│   ├── cleanup.sh             # Post-clone package removal and system cleanup
│   └── chroot_tasks.sh        # Post-install chroot configuration (hostname, locale, users, bootloader)
├── configs/
│   ├── example-uefi.conf      # UEFI + ext4 example configuration
│   ├── example-bios-ext4.conf # BIOS + ext4 example configuration
│   ├── example-btrfs.conf     # Btrfs subvolumes example configuration
│   ├── example-encrypted.conf # UEFI + LUKS + ext4 example configuration
│   ├── example-encrypted-btrfs.conf # UEFI + dual LUKS + Btrfs subvolumes example
│   └── example-minimal.conf   # Minimal install example configuration
├── docs/
│   ├── GLOSSARY.md            # Project domain terminology
│   ├── configuration.md       # Configuration pattern, validation rules, examples
│   ├── e2e_boot_test.md       # QEMU/libvirt end-to-end boot test harness
│   ├── end_actions.md         # End-action hooks specification and implementation
│   ├── luks.md                # LUKS implementation details, cryptsetup flow, initramfs
│   ├── partitioning.md        # Partitioning strategies, layouts, filesystem mounting
│   ├── user_config.md         # User and system configuration inside chroot, bootloader
│   ├── clone_mode.md          # System clone approach, cleanup process, and teardown
│   ├── live_iso_validation.md # Live ISO validation workflow and example commands
│   ├── logging.md             # Logging module API (lib/logging.sh)
│   ├── hardware.md            # Hardware detection module (lib/hardware.sh)
│   ├── signal_handling.md     # Trap/cleanup pattern for interruptions
│   ├── progress.md            # Progress display system
│   ├── cli_interface.md       # CLI argument specification and override priority
│   ├── exit_codes.md          # Standardized exit code reference
│   ├── limitations.md         # Known limitations and unsupported features
│   └── agents/                # Agent skill conventions (domain.md, issue-tracker.md)
└── tests/
    ├── syntax_check.sh        # Shellcheck and static analysis wrapper
    ├── qemu_boot_test.sh      # End-to-end QEMU/libvirt boot test harness
    └── verify_installed_system.sh # Post-install system verification checklist
```

## Code Style & Implementation Guidelines

### Shell Script Hygiene

Every script file MUST begin with:
```bash
#!/usr/bin/env bash
set -euo pipefail
```

### Variables & Naming

- **Global / Environment variables**: `UPPER_CASE` (e.g., `TARGET_DISK`, `TARGET_DIR`, `LOCAL_REPO_PATH`).
- **Local function variables**: Always use `local` keyword with `lower_case` or `snake_case` (e.g., `local drive_size`, `local subvol`).
- **Quoting**: Always quote variable expansions to avoid word splitting: `"${TARGET_DIR}"`.

### Error Handling & Cleanup Hooks

- Use `trap` routines to ensure clean unmounting (`umount -R "${TARGET_DIR}"`) on script interruption or exit.
- Provide clear exit codes (`exit 1` for validation failure, `exit 0` on success). See `docs/exit_codes.md` for the complete reference.
- **PIPE signal**: Add `PIPE` to the signal trap to prevent pipeline interruptions from bypassing cleanup routines. See `docs/signal_handling.md`.

### Logging Standard

All output must pass through the logging module. See `docs/logging.md` for the complete API, log levels, and color coding.

### Progress Display

Installers MUST show step progress and sub-step feedback during long operations. See `docs/progress.md` for the `log_info "Stage N: …"` pattern and the background `_progress_indicator` sub-step pattern.

## Configuration Pattern

Configuration files are shell-sourceable and use a function-based approach for partition definitions. Each partition is defined via `define_partition` with explicit named parameters (`--mount`, `--size`, `--fs`, `--luks`, `--subvol`). When `--luks "yes"`, credentials are read from environment variables: `LUKS_PASSPHRASE` and/or `LUKS_KEYFILE` (at least one required; both can be set for passphrase + keyfile fallback). See `docs/configuration.md` for the full specification, validation rules, and `define_partition` implementation details.

## Optional Configuration

Beyond the core partition definitions, the installer supports optional configuration:

- **System configuration**: `TIMEZONE` (zone name under `/usr/share/zoneinfo`), `ISSUE_MESSAGE` (custom `/etc/issue`), `TEXTCONSOLE` (text-mode GRUB boot menu)
- **User account**: `ROOT_PASS`, `CREATE_USER`, `USER_LOGIN`, `USERNAME`, `USER_PASS`, `USER_SHELL`, `USER_GROUPS` (passwords may come from `ROOT_PASS`/`USER_PASS` env vars)
- **Network configuration**: `NETWORK_DEVICE`, `NETWORK_MODE`, `NETWORK_IP`, `NETWORK_GATEWAY`, `DNS_SERVERS` — wired (DHCP/static) and wireless (wpa_supplicant)
- **Service management**: `ENABLED_SERVICES` — comma-separated list of runit services to enable
- **LUKS credentials**: `LUKS_PASSPHRASE` (plaintext passphrase) and/or `LUKS_KEYFILE` (file path on live ISO) — at least one required when any partition has `--luks "yes"`; both can be set for passphrase + keyfile fallback (see `docs/luks.md`)

See `docs/configuration.md` for the complete list of optional variables and their validation rules.

## Installation Pipeline Workflow

> **Note:** When `--dry-run` is specified (see `docs/cli_interface.md`), the installer validates configuration and exits without executing the pipeline steps below.

The installer executes the following stages sequentially. Each step delegates to a dedicated module with full implementation details documented in `docs/`.

1. **Pre-flight Check**: Detect boot mode (UEFI/BIOS) from hardware, verify root privileges, and validate target disk availability. See `docs/hardware.md`.
2. **Configuration Loading**: Source config files, execute `define_partition()` calls, and run `validate_config()` with cross-validation rules. See `docs/configuration.md`.
3. **Partition & Format**: Generate GPT partition table via `sfdisk`, format filesystems, setup LUKS encryption, configure swap, and mount target filesystems. Boot-mode-reconciliation (`_reconcile_partitions_for_boot_mode`) drops firmware-incompatible partitions (e.g. `/boot/efi` on BIOS) before layout generation. See `docs/partitioning.md` and `docs/hardware.md#boot-mode-partition-reconciliation`.
4. **System Clone**: Clone the live system rootfs to the target disk. Shows step progress and sub-step feedback during the operation. See `docs/clone_mode.md` and `docs/progress.md`.
5. **Post-Clone Operations** (all on mounted `${TARGET_DIR}`):
   - **5a. Cleanup**: Remove live environment files, remove live user account, and remove unnecessary packages. See `docs/clone_mode.md`.
   - **5b. Chroot Configuration**: Mount bind filesystems, then execute the 20-step sequence: hostname/locale/keymap/timezone, passwords, user creation, sudo, network, services, LUKS keyfile + crypttab, initramfs rebuild, bootloader, swap file, btrfs default subvolume, and fstab generation. See `docs/user_config.md`.
6. **Teardown**: Unmount filesystems, close LUKS mapper devices, and sync. See `docs/clone_mode.md`.
7. **End-Action**: Execute the configured post-install action (shutdown, reboot, script, or func). Note: Teardown (step 6) handles all unmounting and syncing before this step runs. See `docs/end_actions.md`.

## Testing: QEMU Boot Harness (`tests/qemu_boot_test.sh`)

The only way to validate end-to-end behavior is a full VM boot + install in QEMU via libvirt. Do **not** hand-edit disks or run raw `virsh` teardown commands against the test VM — see the safety rules below.

### When to use it

Run this harness whenever you change anything that affects the installed system, partitioning, cloning, bootloader, or boot flow (i.e. almost every installer change). Static checks (`shellcheck`) are necessary but not sufficient; a live boot confirms the modules actually work inside the chroot.

### Options

```bash
./tests/qemu_boot_test.sh [OPTIONS]

Required:
  --iso FILE               Path to Void Linux live ISO (skip if --reinstall)

Options:
  --config FILE            Config template (default: configs/example-uefi.conf)
  --reinstall              Skip VM setup, re-run install on the existing VM (passes --reinstall to installer)
  --destroy-vm             Tear down the VM + root disk at the END, but ONLY if the install succeeded
  --cpu-arch ARCH          x86_64 (default) or i686
  --firmware FW            uefi (default) or bios
  --display TYPE          VM display: none (default), vnc, spice, or sdl
  --luks-passphrase PASS  LUKS passphrase (or set LUKS_PASSPHRASE env var)
  --skip-verify-boot      Skip boot verification (reboot + reachability check after install)
```

> **`--keep-vm` was removed.** VMs are never auto-destroyed except via `--destroy-vm`. After every run the VM is left running for log inspection; a broken VM from a failed run is cleaned up automatically by the next run's startup teardown. Do not re-add it.

### Workflow (what happens internally)

1. **Startup (full mode)**: `destroy_vm()` unconditionally powers off and undefines any leftover test VM, then `setup_disk()` removes and recreates a fresh root disk image (`${DISK_FILE}`, a qcow2). The live ISO is a separate cdrom device and is never touched here.
2. **Boot**: `create_vm()` boots the live ISO from the cdrom (boot order = disk first, then cdrom) so installation runs from the ISO.
3. **Install**: the installer runs inside the VM against `${TARGET_DISK}` (the fresh disk). Logs land in `/var/log/voidful.log` on the guest.
4. **Boot verification** (on by default, skip with `--skip-verify-boot`): `verify_boot()` powers off the live-ISO session, then reboots the **installed system** and confirms it is reachable over SSH (using the credentials from the generated config); IP detection requires a **live ARP response** (`virsh domifaddr` entry with a non-empty MAC column) — the lease-table fallback would return the pre-restart lease (the domain is recreated reusing the same MAC), which a leftover VM from a previous run may still hold, and its sshd rejects the installed-system credentials. Then it runs `tests/verify_installed_system.sh`. For **BIOS** firmware the VM domain is *recreated* (undefine without `--remove-all-storage` + fresh `virsh define` + start): the recreated XML must declare the disk format explicitly (`<driver type='qcow2'/>`) — without it, QEMU reads the `.qcow2` file as a raw image, SeaBIOS reads the qcow2 container header instead of the MBR and reports "not a bootable disk" (the guest idles with zero disk IO; no OS is ever loaded, so runit stage 2 / dhcpcd never runs and no DHCP lease appears). The fresh domain has no ISO cdrom and disk-first boot. For **UEFI** firmware the existing domain is reused (OVMF NVRAM remembers the boot entry). A failure does not destroy the VM — it is left running for inspection. The ISO (file) is never touched.
5. **End-of-install teardown**:
   - If `--destroy-vm` was passed **and** the install succeeded → destroy the VM and remove the root disk image (`${DISK_FILE}`).
   - Otherwise → leave the VM running for inspection. Reinstall mode leaves the VM running regardless (it reuses the existing VM).

### Safety rules — do not break the ISO again

The live ISO file is a **separate cdrom device** in the VM, distinct from the root qcow2 disk. The teardown logic was historically broken by raw libvirt commands that deleted it:

- **NEVER** run `virsh undefine <vm> --remove-all-storage` (or any `--remove-*`) against the test VM — this deletes the cdrom/ISO backing file.
- **NEVER** manually `rm` or delete the ISO path, nor run raw `sfdisk`/`mkfs` on the target disk without matching `${TARGET_DISK}` first.
- Use the harness's `destroy_vm()` instead of ad-hoc `virsh` commands. It only powers off + undefines the VM and, when `--destroy-vm` is set, removes **only** the root disk image (`${DISK_FILE}`). The ISO is always preserved.
- After a run, inspect the guest over SSH (credentials below) rather than guessing at commands. Prefer re-running the harness to iterate.

### Running it

```bash
# BIOS + encrypted install example (typical for this project)
LUKS_PASSPHRASE="voidful" ./tests/qemu_boot_test.sh --iso /mnt/iso/void-live-x86_64-20250202-base.iso \
    --config configs/example-encrypted.conf --firmware bios

# Tear down the VM + disk after a successful run (keeps logs until next run)
./tests/qemu_boot_test.sh --iso <iso> --config configs/example-encrypted.conf --firmware bios --destroy-vm

# Re-run the install on an already-installed test VM (no fresh boot)
./tests/qemu_boot_test.sh --reinstall
```

### Validation environment

Requires libvirt (`virsh`, `virt-install`), QEMU/KVM, and `sshpass` on the **host**. Guest credentials: user `anon`, password `voidlinux`, private network `192.168.122.0/24`. The VM is defined as `voidful-test`; its root disk is `.voidful-test-disk.qcow2` in the repo root and the ISO is passed separately via `--iso`.

> **Note:** This harness deliberately runs a real install, which touches the target disk. It is for validation only — never run it against production disks or without an explicit `--iso`.

## Chroot Best Practices

When preparing and operating inside the chroot environment:

- Mount required filesystems before entering chroot (`proc`, `dev`, `devpts`, `sys`, `efivarfs` for UEFI). See `docs/user_config.md` for the complete ordered preparation steps.
- **Btrfs with subvolumes**: Mount the root subvolume `@` at `${TARGET_DIR}` using `-o subvol=@` **before** any clone operation.
- For LUKS partitions: ensure `/dev/mapper/luks-<name>` is mounted before generating fstab and entering chroot. See `docs/luks.md` for LUKS mount order.
- Initramfs rebuild (dracut) is covered in `docs/user_config.md` (step 16 of chroot sequence).

See `docs/user_config.md` for the complete 20-step chroot configuration sequence and `docs/clone_mode.md` for clone-specific operations.

## End-Action Hooks

After installation completes, support configurable post-install behavior via the `END_ACTION` variable. See `docs/end_actions.md` for the full specification, implementation pattern, and safety notes.

## Implementation Phase

**This repository is in active implementation.** The core installer modules are implemented in `lib/` and orchestrated by `install.sh`. All documentation describes the actual implementation, not future plans.

### Agent Scope

Agents MAY create, modify, and implement code files in `lib/`, `install.sh`, `configs/`, and `docs/`. All changes must follow the coding standards and constraints defined in this document.

### Code Implementation Guidelines

- **Follow the specs**: Implementation in `lib/*.sh` must match the behavior documented in `docs/`. When there's a discrepancy, the code is the source of truth — update the docs to match.
- **Test before declaring complete**: Run `shellcheck install.sh lib/*.sh` and validate on a live ISO when possible (see `docs/live_iso_validation.md`).
- **Preserve existing behavior**: When modifying code, ensure existing functionality is not broken. Update tests and documentation accordingly.
- **No new modules without approval**: Adding new files to `lib/` or changing the repository structure requires user approval. Discuss in `.agents/` first.
- **Documentation follows code**: When implementing or modifying code, update the corresponding `docs/*.md` files to reflect the actual behavior.

### Documentation Guidelines

- **Accuracy over completeness**: Documentation must accurately describe what the code actually does, not what it's supposed to do.
- **Update on change**: Any code change that affects behavior must be accompanied by a documentation update in the relevant `docs/*.md` file.
- **Examples must be valid**: Configuration examples in `configs/` and `docs/` must be syntactically valid and represent actually working configurations.

### The `lib/` Directory

The `lib/` directory contains the actual implementation:

| File | Purpose | Docs |
|------|---------|------|
| `logging.sh` | Terminal output and logging utilities | `docs/logging.md` |
| `hardware.sh` | UEFI/BIOS, CPU, and disk discovery | `docs/hardware.md` |
| `config.sh` | Partition definition and config validation | `docs/configuration.md` |
| `partitioning.sh` | sfdisk layout, formatting, LUKS, mounting | `docs/partitioning.md` |
| `clone.sh` | System clone operations (tar-based) | `docs/clone_mode.md` |
| `cleanup.sh` | Post-clone package removal and cleanup | `docs/clone_mode.md` |
| `chroot_tasks.sh` | Chroot configuration (hostname, users, bootloader) | `docs/user_config.md` |

Each module's documentation describes the actual implementation, not a future spec.

## Agent Proposal & Planning Rules

When identifying gaps, ambiguities, or improvements, agents must follow these rules:

1. **Proposal files go in `.agents/`**: Any analysis, proposal, or plan document that does not have an explicitly defined location in the repository structure MUST be created inside the `.agents/` directory. This includes gap analyses, design proposals, architecture decisions, and implementation plans.

2. **Never create orphan documents**: Before creating a new `.md` file outside of `.agents/`, verify it has a clear home in the documented repository structure. If no home exists, place it in `.agents/` instead.

3. **Reference proposals by relative path**: When referencing a proposal in other documents or code, use the relative path `.agents/<filename>.md`.

4. **Promote approved proposals**: Once a proposal in `.agents/` is approved and assigned a permanent location, move it to its final destination (e.g., `docs/`, `configs/`, or `lib/`) and update the reference.

Example:
```text
# Proposal with no explicit home → .agents/
.agents/gaps_proposals.md          ← gap analysis document
.agents/architecture-decision.md   ← design proposal

# Proposal with explicit home → final location
docs/logging.md                    ← logging module docs (already defined in structure)
lib/cleanup.sh                     ← cleanup module (already defined in structure)
```

## AI Agent Development Workflow

When modifying code in this repository, follow this workflow:

1. **Syntax Validation**: Run static analysis before declaring task completion:
   ```bash
   shellcheck install.sh lib/*.sh
   ```
2. **Offline Logic Validation**: Ensure no external network calls are introduced. The installer operates entirely offline using the system clone approach.
3. **Clone Flow Validation**: Ensure the clone operation uses the real pipeline — create side `tar --one-file-system --xattrs --exclude=./var/log --exclude=./etc/machine-id`, extract side `tar --xattrs --xattrs-include='*' --preserve-permissions` — and that cleanup removes the correct live system packages.
4. **Idempotency & Clean Code**: Keep shell functions short, focused on a single responsibility, and clearly documented.

### Live ISO Validation (RECOMMENDED)

**Before declaring any task complete, request SSH access to a Void Linux live CD instance** to validate your implementation.

See `docs/live_iso_validation.md` for the complete validation workflow, example commands, and revalidation guidelines.

## Agent skills

### Issue tracker

Issues tracked as local markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context layout: `docs/GLOSSARY.md`. See `docs/agents/domain.md`.

