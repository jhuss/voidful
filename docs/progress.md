# Progress Display System

The installer shows real-time progress to the user during installation. Two levels of progress are supported:

1. **Step progress** — Major installation stages (e.g., "Partitioning disk", "Cloning system")
2. **Sub-step progress** — Detailed feedback within long-running operations (e.g., periodic "still cloning..." messages)

## Variables

| Variable | Description |
|----------|-------------|
| `CURRENT_STEP` | Current step number (starts at 0, **reserved** — first `print_step` call shows `[1/N]`) |
| `STEP_COUNT` | Total number of steps |

## Functions

| Function | Description |
|----------|-------------|
| `print_step "message"` | Increments `CURRENT_STEP` and displays progress via `log_info()` |

> **Note:** `CURRENT_STEP=0` is reserved; the first `print_step` call displays `[1/N]`.





## Sub-step Progress for Long Operations

Some operations (clone, package removal, dracut rebuild) take 5-15 minutes. To keep the user informed, use sub-step progress.

### Pattern: Periodic Status Messages (Recommended)

For all long-running operations, use periodic status messages. This pattern is simple, reliable, and avoids race conditions.

Display the major step, then start a background progress updater that shows a message every 30 seconds. After the operation completes, clean up the background process with `kill` and `wait`.

#### Implementation Example

```bash
# Display the major step
print_step "Cloning system to target disk"

# Start background progress updater
(
    while true; do
        log_info "  [clone progress] Still cloning... please wait"
        sleep 30
    done
) &
local clone_bg=$!

# Perform the long-running operation
tar --create \
    --one-file-system \
    --xattrs \
    --xattrs-include='*' \
    --directory=/ \
    -f - | \
tar --extract \
    --xattrs \
    --xattrs-include='*' \
    --directory="${TARGET_DIR}" \
    --no-overwrite-dir \
    --preserve-permissions

# Clean up background progress updater
kill ${clone_bg} 2>/dev/null || true
wait ${clone_bg} 2>/dev/null || true

log_info "  [clone progress] Clone complete"
```

**Key points:**
- Use `log_info` with 2-space indentation for sub-step messages
- Always `kill` and `wait` the background process after the operation
- Use `|| true` guards to prevent errors if the process already exited



## Best Practices

- Set `STEP_COUNT` to the actual number of major steps before the loop
- Call `print_step` at the beginning of each major pipeline stage
- Use descriptive step names that explain what is happening
- The progress is displayed via `log_info`, which handles color coding and log file writing
- For operations longer than 30 seconds, show sub-step progress
- Always clean up background processes (kill/wait) after long operations
- Use `log_info` for sub-step messages (indented with 2 spaces) to differentiate from major steps
