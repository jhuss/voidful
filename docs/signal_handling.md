# Signal Handling and Cleanup

The installer uses `trap` to ensure clean unmounting and resource cleanup on interruption or failure.

## Trap Pattern

The installer uses a **two-trap pattern**: one for `EXIT` (always runs, performs cleanup) and separate handlers for `INT`/`TERM`/`HUP` (cleanup + explicit exit code).

> **Cleanup guard (`INSTALL_STARTED`):** The traps are installed at script startup, *before* argument parsing. To prevent early exits (`--help`, `--version`, `--dry-run`, `--test-mode`, config/preflight errors) from running teardown, `trap_cleanup` only performs cleanup once the installation pipeline has started creating state (partitions/mounts) — i.e. after `INSTALL_STARTED=true` is set in `main` just before `stage_partition`. Before that point, `trap_cleanup` returns without unmounting or logging an interruption, so `--help`/`--version`/`--dry-run`/`--test-mode` exit cleanly with no side effects.

## Why Two Traps?

| Trap | Purpose | Exit Code |
|------|---------|-----------|
| `EXIT` | Always runs — cleanup on normal exit, error exit, or signal | Preserves existing exit code |
| `INT`/`TERM`/`HUP` | Signal interruption — cleanup + explicit exit code 8 | Always exit 8 |

**Why not trust `$?` in signal handlers?**
- When a signal interrupts a command, `$?` may not reliably reflect the exit code of the interrupted command
- For signal interruptions, always use exit code 8 (user interruption)
- For normal errors, let the `EXIT` trap preserve the exit code from the failing command

## Variable Safety with `set -u`

With `set -u` (treat unset variables as errors), all variable references inside traps must use the `${VAR:-}` default syntax.

## Signals Trapped

| Signal | Action | Exit Code |
|--------|--------|-----------|
| `EXIT` | Always run — cleanup (unmount, close LUKS, sync) | Preserves existing code |
| `INT` (Ctrl+C) | Cleanup + exit 8 | `8` |
| `TERM` | Cleanup + exit 8 | `8` |
| `HUP` | Cleanup + exit 8 | `8` |
| `PIPE` | Cleanup + exit 8 | `8` |

> **Note:** Add `PIPE` to the signal trap to prevent pipeline interruptions (e.g., `tar | tar`) from bypassing cleanup routines. Without `PIPE`, a broken pipe can cause the installer to exit without unmounting the target filesystem.

## Cleanup Order

1. Unmount `${TARGET_DIR:-}` recursively (`umount -R`)
2. Close LUKS mapper devices (if open)
3. Sync filesystem buffers
4. Exit with appropriate code

## Double Unmount Handling

Both the signal path and the Teardown step (step 7 in the pipeline, `stage_teardown`) call `umount` on the same mount points. The `|| true` guards ensure that any double-unmount attempts fail silently.

> **Note:** The `stage_end_action()` function does **NOT** call `umount -R`. It only executes the configured post-install action (shutdown, reboot, script, func, or none) after the Teardown step has already unmounted the filesystem. See `docs/end_actions.md` for details.

## Exit Code Handling

The installer uses standardized exit codes (see `docs/exit_codes.md`). Signal handlers always exit with code 8. The `EXIT` trap preserves the exit code from the failing command (module failures uniformly exit `1`; see `docs/exit_codes.md`).

## PIPE Signal Handling

With `set -o pipefail`, a broken pipe in `tar | tar` (used during system cloning) will cause the pipeline to fail. The `PIPE` trap ensures cleanup runs before the script exits.

> **Note:** All four signals are trapped by the same inline trap command — `trap 'trap_cleanup; exit 8' INT TERM HUP PIPE` (no named handler function). This is intentional — all signals should perform the same cleanup and exit with code 8.
>
> **Interaction with `set -o pipefail`:** When a broken pipe occurs, `pipefail` causes the pipeline to return a non-zero exit code. The `PIPE` trap fires and runs `trap_cleanup`, which performs unmounting with `|| true` guards for idempotency. The `exit 8` then causes the script to exit, which also triggers the `EXIT` trap. Since cleanup already ran, the `EXIT` trap's unmount calls are no-ops (protected by `|| true`). This ensures cleanup runs exactly once even when multiple signals fire in quick succession.

## TARGET_DIR Cleanup Policy

The installer follows a strict policy for `${TARGET_DIR}` (the mount point for the target system):

| Scenario | Action |
|----------|--------|
| **Installation fails** | `${TARGET_DIR}` is **NOT** deleted. The filesystem is unmounted, but the directory and its contents remain for user inspection. |
| **Installation succeeds** | `${TARGET_DIR}` is **NOT** deleted. The `END_ACTION` (shutdown/reboot) handles the final state. |
| **Signal interruption** (Ctrl+C) | `${TARGET_DIR}` is **NOT** deleted. Only unmount is performed. |

**Rationale:** The target directory contains the partially or fully installed system. Deleting it would destroy the user's work and make debugging impossible.
