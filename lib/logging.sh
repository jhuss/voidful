#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034
# logging.sh — Color-coded logging module for voidful installer
#
# All messages go to the log file. Terminal output is filtered by LOG_LEVEL.
# Colors are applied only when stdout is a TTY.

# ---------------------------------------------------------------------------
# Guard against multiple sourcing
# ---------------------------------------------------------------------------
if [[ -n "${_LOGGING_SH_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi
readonly _LOGGING_SH_LOADED=1

# ---------------------------------------------------------------------------
# Configuration (can be overridden via environment before sourcing)
# ---------------------------------------------------------------------------

: "${LOG_LEVEL:=info}"
: "${LOG_FILE:=/var/log/voidful.log}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Map LOG_LEVEL string to numeric priority
#   error=0, warn=1, info=2, debug=3
_log_level_to_num() {
    local level="${1:-info}"
    case "${level}" in
        error) echo 0 ;;
        warn)  echo 1 ;;
        info)  echo 2 ;;
        debug) echo 3 ;;
        *)     echo 2 ;;
    esac
}

# Check if a message at the given level should appear on the terminal
# Args: $1 = message level name (ERROR/WARN/INFO/OK)
# Returns: 0 if should show, 1 otherwise
_log_should_show() {
    local level_name="${1}"
    local msg_level
    msg_level=$(_log_level_to_num "${level_name}")
    local threshold
    threshold=$(_log_level_to_num "${LOG_LEVEL}")

    if [ "${msg_level}" -le "${threshold}" ]; then
        return 0
    else
        return 1
    fi
}

# Write a line to the log file, suppressing any write error (e.g. when
# running --help/--dry-run as non-root and /var/log/voidful.log is not
# writable). The group form redirects the whole command's stderr so a
# failed redirection does not leak "Permission denied" to the terminal.
_log_write_file() {
    local line="${1}"
    { echo "${line}" >> "${LOG_FILE}" || true; } 2>/dev/null
}

# Emit a log line to both stdout/stderr and the log file
# Args: $1 = output stream (stdout|stderr), $2 = level tag (INFO/WARN/ERROR/OK),
#       $3 = color code (ANSI), $4 = message
_log_emit() {
    local stream="${1}"
    local level_tag="${2}"
    local color_code="${3}"
    local message="${4}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${level_tag}] ${timestamp}: ${message}"

    # Always write to log file
    _log_write_file "${line}"

    # Write to terminal (stdout or stderr)
    if [ -t 1 ]; then
        if [ "${stream}" = "stdout" ]; then
            printf "%b%s%s\n" "${color_code}" "${line}" "${NC}"
        else
            printf "%b%s%s\n" "${color_code}" "${line}" "${NC}" >&2
        fi
    else
        # When not on TTY, always output to stderr to avoid polluting
        # command substitution output (e.g., JSON generation)
        printf "%s\n" "${line}" >&2
    fi
}

# ---------------------------------------------------------------------------
# Color codes (ANSI)
# ---------------------------------------------------------------------------

readonly NC=$'\033[0m'   # No Color
readonly CYAN=$'\033[0;36m'
readonly YELLOW=$'\033[0;33m'
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# --- log_info ---
# Usage: log_info "message"
# Description: Informational message (cyan on TTY, stdout)
log_info() {
    local message="${1:-}"
    if _log_should_show "info"; then
        _log_emit stdout "INFO" "${CYAN}" "${message}"
    else
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        _log_write_file "[INFO] ${timestamp}: ${message}"
    fi
}

# --- log_warn ---
# Usage: log_warn "message"
# Description: Warning message (yellow on TTY, stderr)
log_warn() {
    local message="${1:-}"
    if _log_should_show "warn"; then
        _log_emit stderr "WARN" "${YELLOW}" "${message}"
    else
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        _log_write_file "[WARN] ${timestamp}: ${message}"
    fi
}

# --- log_error ---
# Usage: log_error "message"
# Description: Error message (red on TTY, stderr)
log_error() {
    local message="${1:-}"
    if _log_should_show "error"; then
        _log_emit stderr "ERROR" "${RED}" "${message}"
    else
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        _log_write_file "[ERROR] ${timestamp}: ${message}"
    fi
}

# --- log_success ---
# Usage: log_success "message"
# Description: Success message (green on TTY, stdout)
log_success() {
    local message="${1:-}"
    if _log_should_show "info"; then
        _log_emit stdout "OK" "${GREEN}" "${message}"
    else
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        _log_write_file "[OK] ${timestamp}: ${message}"
    fi
}
