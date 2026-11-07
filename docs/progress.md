# Progress Display System

The installer shows real-time progress to the user during installation. Two levels of progress are supported:

1. **Step progress** — Major installation stages, one `log_info` line per stage: `Stage 1: Pre-flight Check` … `Stage 8: End-Action` (there is no `[N/total]` counter and no `print_step()` function; the stage number is hardcoded in each `stage_*()` function in `install.sh`).
2. **Sub-step progress** — Periodic status messages during long-running operations (e.g., "still cloning..." every 30 seconds) via the `_progress_indicator()` background helper in `lib/clone.sh`.

## Sub-step Progress for Long Operations

Some operations (clone, package removal, dracut rebuild) take 5-15 minutes. To keep the user informed, a background progress indicator is started before the long operation and cleaned up (`kill` + `wait`) after it completes.

### Pattern: Periodic Status Messages

`_progress_indicator <interval>` (in `lib/clone.sh`) loops `sleep <interval>` → `log_info "still cloning..."` in the background. The caller keeps the PID, runs the operation, then kills and waits on the PID.

#### Implementation Example (system clone, `lib/clone.sh`)

```bash
# Start the background progress indicator (30s interval)
_progress_indicator 30 &
PROGRESS_PID=$!

# Perform the long-running operation (pipefail suspended around the pipeline
# so a failing create side is reported via PIPESTATUS instead of aborting)
set +o pipefail
if tar --create --one-file-system --xattrs -f - \
       --exclude=./var/log \
       --exclude=./etc/machine-id \
       "${source_root}" 2>"${create_err}" | \
   tar --extract --xattrs --xattrs-include='*' --preserve-permissions -f - \
       -C "${target_dir}" 2>"${extract_err}"; then
    read -r create_status extract_status <<< "${PIPESTATUS[@]}"
else
    read -r create_status extract_status <<< "${PIPESTATUS[@]}"
fi
set -o pipefail

# Clean up the background progress indicator
kill "${PROGRESS_PID}" 2>/dev/null || true
wait "${PROGRESS_PID}" 2>/dev/null || true
```

**Key points:**
- Sub-step messages are `log_info` with no prefix; the stage banner (`Stage 4: System Clone`) is the major step
- Always `kill` and `wait` the background process after the operation (both on success and on the failure path)
- Use `|| true` guards so a late-arriving kill/wait cannot trigger `set -e`

## Clone tar flags

- **Create side**: `--create --one-file-system --xattrs -f - --exclude=./var/log --exclude=./etc/machine-id "${source_root}"` — `--one-file-system` stops at filesystem boundaries (skips `/proc`, `/sys`, the live ISO's squashfs, etc.); the two excludes keep volatile per-boot state out of the clone.
- **Extract side**: `--extract --xattrs --xattrs-include='*' --preserve-permissions -f - -C "${target_dir}"` — there is **no** `--no-overwrite-dir` (destination directories are overwritten so the target rootfs matches the source).
- `pipefail` is disabled around the pipeline and both statuses are read from `PIPESTATUS`; `create_status == 1` ("file changed as we read it") is treated as a harmless warning, any other failure exits `1`.

## Best Practices

- Announce each major pipeline stage with `log_info "Stage N: <name>"` at the beginning of the stage
- For operations longer than 30 seconds, run `_progress_indicator <interval> &` before the operation and `kill`/`wait` the PID after
- Use `log_info` for sub-step messages to differentiate them from errors/warnings
- Always clean up background processes (kill/wait) after long operations, on both success and failure paths
