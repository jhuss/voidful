# Logging Module

The logging module (`lib/logging.sh`) provides standardized terminal output and log file writing.

## Requirements

The installer must be run as **root** (verified by pre-flight checks). The default log file path (`/var/log/voidful.log`) requires root privileges.

## Functions

| Function | Description |
|----------|-------------|
| `log_info "message"` | Informational message, prefixed with `[INFO]` |
| `log_warn "message"` | Warning message, prefixed with `[WARN]`, output to stderr |
| `log_error "message"` | Error message, prefixed with `[ERROR]`, output to stderr |
| `log_success "message"` | Success message, prefixed with `[OK]` |



## Log Level

The `LOG_LEVEL` variable controls the minimum severity level for terminal output (log file always receives all levels):

| Level | Value | Description |
|-------|-------|-------------|
| `error` | `0` | Errors only |
| `warn` | `1` | Errors + warnings |
| `info` | `2` | Errors + warnings + info (default) |
| `debug` | `3` | All messages including debug |

**Setting LOG_LEVEL:**

| Method | Value |
|---|---|
| Environment variable | `export LOG_LEVEL="debug"` |
| CLI argument | `./install.sh --verbose` → `LOG_LEVEL=debug` |
| Default | `info` |

**CLI flag mapping:**
- `--verbose` → `LOG_LEVEL=debug`
- No flag → `LOG_LEVEL=info` (default)

> **Note:** The log file (`${LOG_FILE}`) always receives all messages regardless of `LOG_LEVEL`. The level only affects terminal output.

## Log File

All messages are written to `${LOG_FILE}`. This variable is configurable via environment variable (default: `/var/log/voidful.log`). The path requires root privileges.

> **Note:** Log file write errors are suppressed by `_log_write_file`. If the log file is not writable (e.g. running `--help`/`--dry-run`/`--test-mode` as non-root), the write is silently skipped and no `Permission denied` error is printed to the terminal. Terminal output is unaffected.

> **Note:** Logging is strictly append-only — there is no rotation, size cap, or truncation. The stage 4 system clone snapshots `${LOG_FILE}` at clone time, so the copy on the installed system initially ends at "Starting system clone"; `_teardown()` in `install.sh` flushes the complete log to `${TARGET_DIR}/var/log/voidful.log` before unmounting, so the installed system's log contains the full install (stages 1-7) (see `docs/clone_mode.md`, Phase 4: Teardown).



## Color Output

Messages are color-coded when stdout is a TTY:
- `[INFO]` — cyan
- `[WARN]` — yellow
- `[ERROR]` — red
- `[OK]` — green


