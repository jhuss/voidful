# Voidful Project Overview

This repository contains an automated, unattended offline installer for Void Linux. The system is designed to perform a complete bare-metal installation directly from a live Void Linux ISO without requiring an active internet connection.

All AI coding assistants (Agents) working on this repository must strictly adhere to the constraints, coding standards, and architectural conventions outlined below.

## Core Constraints & Safety Rules

1. **Strictly Pure Bash**: 
   - The core installer and all modules MUST be written in pure `bash` (version 4.0+).
   - Do NOT introduce external language dependencies (e.g., Python, Perl, Ruby, Node, Go, Rust).

2. **Zero Internet Dependency (ISO Offline Only)**:
   - All package installations must source exclusively from local binary package repositories present on the ISO (e.g., `/nouveau/binpkgs`, `/hostbuf`, or ISO-mounted paths).
   - Use `xbps-install` with local repository paths (`-R /path/to/local/repo`) and root target directories (`-r /mnt`).
   - Never assume network availability (`ping`, `curl`, `wget`, or remote `xbps` sync are prohibited in execution paths).

3. **Available Tooling Strict Bounds**:
   - Rely strictly on binaries pre-packaged in the official Void Linux Live ISO environment:
     - Disk & Filesystem: `sfdisk`, `fdisk`, `cfdisk`, `lsblk`, `blkid`, `mkfs.ext4`, `mkfs.vfat`, `mkfs.btrfs`, `btrfs`, `swaplabel`
     - Void Specifics: `xbps-install`, `xbps-reconfigure`, `xbps-query`, `xchroot`
     - Core Utils & Boot: `mount`, `umount`, `chroot`, `efibootmgr`, `grub-install`, `udevadm`, `sed`, `awk`, `grep`

4. **Host Safety First**:
   - Never run destructive commands (`dd`, `mkfs`, `sfdisk`, `wipefs`) without checking if the target disk matches the intended installation target variable.
   - Include strict sanity guards that prevent execution on the host machine running the development tool.

## Repository Structure

```text
.
├── AGENTS.md                  # Instructions for AI Agents (this file)
├── install.sh                 # Main entrypoint script (orchestrator)
├── config.default.conf        # Default unattended configuration parameters
├── lib/
│   ├── logging.sh             # Terminal output and logging utilities
│   ├── hardware.sh            # UEFI/BIOS, CPU, and disk discovery helpers
│   ├── partitioning.sh        # sfdisk layout generators and formatting routines
│   ├── xbps.sh                # XBPS local repository installation wrappers
│   └── chroot_tasks.sh        # Post-install configuration inside xchroot
└── tests/
    └── syntax_check.sh        # Shellcheck and static analysis wrapper
```

## Code Style & Implementation Guidelines

### Shell Script Hygiene

Every script file MUST begin with:
```bash
#!/usr/bin/env bash
set -euo pipefail
```

### Variables & Naming

- **Global / Environment variables**: `UPPER_CASE` (e.g., `TARGET_DISK`, `TARGET_MOUNT`, `LOCAL_REPO_PATH`).
- **Local function variables**: Always use `local` keyword with `lower_case` or `snake_case` (e.g., `local drive_size`, `local subvol`).
- **Quoting**: Always quote variable expansions to avoid word splitting: `"${TARGET_MOUNT}"`.

### Error Handling & Cleanup Hooks

- Use `trap` routines to ensure clean unmounting (`umount -R "${TARGET_MOUNT}"`) on script interruption or exit.
- Provide clear exit codes (`exit 1` for validation failure, `exit 0` on success).

### Logging Standard

All output must pass through standard log functions in `lib/logging.sh`:
- `log_info "Message"`
- `log_warn "Message"`
- `log_error "Message"`

## Installation Pipeline Workflow

When implementing or modifying installer features, ensure changes align with the execution stages:

1. **Pre-flight Check**: Detect Boot Mode (UEFI vs Legacy BIOS), verify root privileges, find ISO local package cache directory.
2. **Configuration Loading**: Read `config.default.conf` and parse auto-unattended overrides.
3. **Partition & Format**: Generate partition table using `sfdisk`, format target partitions, setup mount points under `/mnt`.
4. **Base System Bootstrap**: Execute `xbps-install -Sy -R "${LOCAL_REPO}" -r /mnt base-system [extra-packages]`.
5. **Target Configuration (`xchroot`)**:
   - Generate `/etc/fstab` using `blkid` UUIDs.
   - Set hostname, locale, keymap, and root password.
   - Configure `runit` services (e.g., enable `dhcpcd`, `dbus`, `udevd`).
   - Install bootloader (`grub-install` or `efibootmgr` execution).
   - Reconfigure packages inside target (`xbps-reconfigure -fa`).
6. **Teardown**: Sync filesystem buffers and safely unmount `/mnt`.

## AI Agent Development Workflow

When modifying code in this repository, follow this workflow:

1. **Syntax Validation**: Run static analysis before declaring task completion:
   ```bash
   shellcheck install.sh lib/*.sh
   ```
2. **Offline Logic Validation**: Ensure no external network calls (`xbps-install -S` without explicit `-R <local_path>`) are added.
3. **Idempotency & Clean Code**: Keep shell functions short, focused on a single responsibility, and clearly documented.
```

