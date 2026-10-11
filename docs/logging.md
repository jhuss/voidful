# Logging Module

The logging module (`lib/logging.sh`) provides standardized terminal output and log file writing.

## Requirements

The installer must be run as **root** (verified by pre-flight checks). The default log file path (`/var/log/voidful-install.log`) requires root privileges.

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

All messages are written to `${LOG_FILE}`. This variable is configurable via environment variable (default: `/var/log/voidful-install.log`). The path requires root privileges.



## Color Output

Messages are color-coded when stdout is a TTY:
- `[INFO]` — cyan
- `[WARN]` — yellow
- `[ERROR]` — red
- `[OK]` — green


