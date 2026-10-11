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
      - Disk & Filesystem: `sfdisk`, `fdisk`, `cfdisk`, `lsblk`, `blkid`, `wipefs`, `partx`, `mkfs.ext4` (symlink to mke2fs), `mkfs.vfat`, `mkfs.btrfs`, `btrfs`, `swaplabel`, `cryptsetup`, `mkswap`, `swapon`
      - Void Specifics: `xbps-install`, `xbps-reconfigure`, `xbps-query`, `xbps-remove`, `xbps-uhelper`, `xchroot` (part of xtools-minimal package — used during installation, removed in post-clone cleanup)
      - Core Utils & Boot: `mount`, `umount`, `chroot`, `grub-install`, `udevadm`, `sed`, `awk`, `grep`, `tar`, `visudo`
      - Archive/Clone: `tar` (with `--one-file-system`, `--xattrs`, `--xattrs-include='*'` flags for system cloning)

4. **Host Safety First**:
   - Never run destructive commands (`dd`, `mkfs`, `sfdisk`, `wipefs`) without checking if the target disk matches the intended installation target variable.
   - Include strict sanity guards that prevent execution on the host machine running the development tool.

### Architecture Awareness

- **musl vs glibc**: Detect `XBPS_ARCH` and adjust repositories, locales, and package choices accordingly. Use `xbps-uhelper arch` to query the architecture.
- **Partition separators**: Disks using `mmc` or `nvme` naming use a `p` prefix for partitions. See `docs/hardware.md` for the full device type to prefix mapping.
- **UEFI vs BIOS detection**: Check for `/sys/firmware/efi` directory to determine boot mode. UEFI requires an EFI System Partition (vfat, 100M+), BIOS does not. Use `grub-install` for bootloader installation (works on both UEFI and BIOS).

## Repository Structure

```text
.
├── AGENTS.md                  # Instructions for AI Agents (this file)
├── install.sh                 # Main entrypoint script (orchestrator)
├── lib/
│   ├── logging.sh             # Terminal output and logging utilities
│   ├── hardware.sh            # UEFI/BIOS, CPU, and disk discovery helpers
│   ├── partitioning.sh        # sfdisk layout generators and formatting routines
│   ├── luks.sh                # LUKS encryption operations (spec: docs/luks.md)
│   ├── clone.sh               # System clone operations (tar-based rootfs copy)
│   ├── cleanup.sh             # Post-clone package removal and system cleanup
│   └── chroot_tasks.sh        # Post-install chroot configuration (hostname, locale, users, bootloader)
├── configs/
│   ├── example-uefi.conf      # UEFI + ext4 example configuration
│   ├── example-btrfs.conf     # Btrfs subvolumes example configuration
│   ├── example-minimal.conf   # Minimal install example configuration
│   └── example-encrypted.conf # UEFI + LUKS + ext4 example configuration
├── docs/
│   ├── configuration.md       # Configuration pattern, validation rules, examples
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
│   └── limitations.md         # Known limitations and unsupported features
└── tests/
    └── syntax_check.sh        # Shellcheck and static analysis wrapper (pending creation)
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

Installers MUST show step progress and sub-step feedback during long operations. See `docs/progress.md` for the `print_step()` API and sub-step patterns.

## Configuration Pattern

Configuration files are shell-sourceable and use a function-based approach for partition definitions. Each partition is defined via `define_partition` with explicit named parameters (`--mount`, `--size`, `--fs`, `--luks`). When `--luks "yes"`, credentials are read from environment variables: `LUKS_PASSPHRASE` and/or `LUKS_KEYFILE` (at least one required; both can be set for passphrase + keyfile fallback). See `docs/configuration.md` for the full specification, validation rules, and `define_partition` implementation details.

## Optional Configuration

Beyond the core partition definitions, the installer supports optional configuration:

- **Package installation**: `INSTALL_PACKAGES` — space-separated list of additional packages to install post-clone
- **Network configuration**: `NETWORK_DEVICE`, `NETWORK_MODE`, `NETWORK_IP`, etc. — wired (DHCP/static) and wireless (wpa_supplicant)
- **Service management**: `ENABLED_SERVICES` — comma-separated list of runit services to enable
- **LUKS credentials**: `LUKS_PASSPHRASE` (plaintext passphrase) and/or `LUKS_KEYFILE` (file path on live ISO) — at least one required when any partition has `--luks "yes"`; both can be set for passphrase + keyfile fallback (see `docs/luks.md`)

See `docs/configuration.md` for the complete list of optional variables and their validation rules.

## Installation Pipeline Workflow

> **Note:** When `--dry-run` is specified (see `docs/cli_interface.md`), the installer validates configuration and exits without executing the pipeline steps below.

The installer executes the following stages sequentially. Each step delegates to a dedicated module with full implementation details documented in `docs/`.

1. **Pre-flight Check**: Detect boot mode (UEFI/BIOS), verify root privileges, and validate target disk availability. See `docs/hardware.md` and `docs/cli_interface.md`.
2. **Configuration Loading**: Source config files, execute `define_partition()` calls, and run `validate_config()` with cross-validation rules. See `docs/configuration.md`.
3. **Partition & Format**: Generate GPT partition table via `sfdisk`, format filesystems, setup LUKS encryption, configure swap, and mount target filesystems. See `docs/partitioning.md`.
4. **System Clone**: Clone the live system rootfs to the target disk. Shows step progress and sub-step feedback during the operation. See `docs/clone_mode.md` and `docs/progress.md`.
5. **Post-Clone Operations** (all on mounted `${TARGET_DIR}`):
   - **5a. Cleanup**: Remove live environment files, remove live user account, and remove unnecessary packages. See `docs/clone_mode.md`.
   - **5b. Chroot Configuration**: Mount bind filesystems, configure hostname/locale/keymap/passwords, create user, configure sudo, enable services, configure network, rebuild initramfs, and install bootloader. See `docs/user_config.md`.
6. **Teardown**: Unmount filesystems, close LUKS mapper devices, and sync. See `docs/clone_mode.md`.
7. **End-Action**: Execute the configured post-install action (shutdown, reboot, script, or func). Note: Teardown (step 6) handles all unmounting and syncing before this step runs. See `docs/end_actions.md`.

## Chroot Best Practices

When preparing and operating inside the chroot environment:

- Mount required filesystems before entering chroot (`proc`, `dev`, `devpts`, `sys`, `efivarfs` for UEFI). See `docs/user_config.md` for the complete ordered preparation steps.
- **Btrfs with subvolumes**: Mount the root subvolume `@` at `${TARGET_DIR}` using `-o subvol=@` **before** any clone operation.
- For LUKS partitions: ensure `/dev/mapper/luks-<name>` is mounted before generating fstab and entering chroot. See `docs/luks.md` for LUKS mount order.
- Initramfs rebuild (dracut) is covered in `docs/user_config.md` (step 12 of chroot sequence).

See `docs/user_config.md` for the complete 14-step chroot configuration sequence and `docs/clone_mode.md` for clone-specific operations.

## End-Action Hooks

After installation completes, support configurable post-install behavior via the `END_ACTION` variable. See `docs/end_actions.md` for the full specification, implementation pattern, and safety notes.

## Phase Constraint — Documentation Only (Default)

**By default, this repository is in a documentation-only phase.** Agents MUST NOT create or modify implementation code files unless the user explicitly instructs otherwise.

- **Default scope**: Agents MUST ONLY edit files in `docs/`, `configs/`, `AGENTS.md`, and `.agents/`.
- **No code creation by default**: Do NOT create, modify, or propose creation of any files in `lib/`, `install.sh`, or any other code location.
- **No code implementation by default**: Do NOT write bash code, function implementations, or shell scripts. The documentation describes the expected API and behavior for future implementation.
- **No new modules by default**: Do NOT add new modules, scripts, or code files to the repository structure. All architectural decisions must be reflected through documentation updates only.
- **Focus on documentation**: When reviewing or proposing fixes, focus on documentation clarity, consistency, and completeness — not on implementation code.
- **The `lib/` directory is empty by design**: Files like `lib/logging.sh`, `lib/hardware.sh`, etc., are documented in `docs/` as specifications for a future implementation phase.
- **Implementation requires explicit instruction**: If a task appears to require implementation, first confirm with the user. Only proceed with code changes when the user explicitly authorizes them.
- **User override**: The user can explicitly authorize code creation/modification at any time. When this happens, the constraint is lifted for the authorized scope.

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
3. **Clone Flow Validation**: Ensure the clone operation uses `tar --one-file-system --xattrs --xattrs-include='*'` and that cleanup removes the correct live system packages.
4. **Idempotency & Clean Code**: Keep shell functions short, focused on a single responsibility, and clearly documented.

### Live ISO Validation (RECOMMENDED)

**Before declaring any task complete, request SSH access to a Void Linux live CD instance** to validate your implementation.

See `docs/live_iso_validation.md` for the complete validation workflow, example commands, and revalidation guidelines.

