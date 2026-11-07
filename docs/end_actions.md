# End-Action Hooks

After installation completes, support configurable post-install behavior via the `END_ACTION` variable:

- `shutdown` (default): run `poweroff` (unmount + sync already done by Teardown step)
- `reboot`: run `reboot` (unmount + sync already done by Teardown step)
- `script`: execute a user-provided script (passed via environment variables like `TARGET_DIR`)
- `func`: call a user-defined bash function
- `none`: do nothing — the system is left running with no action (the installer simply exits `0`)

## Mode Comparison

| Aspect | `script` | `func` |
|--------|----------|--------|
| **Execution context** | Subprocess (child shell) | Same shell (no subprocess) |
| **Can modify installer state** | ❌ No | ✅ Yes |
| **Can call installer functions** | ❌ No | ✅ Yes |
| **Environment variables** | ✅ Inherited | ✅ Inherited |
| **Error propagation** | A failing script terminates the installer under `set -e` (child's exit code propagates) | Exit code terminates installer immediately |
| **Setup required** | Script file path + `chmod +x` | Function definition + `export -f` |
| **Debugging** | Easier — separate file | Harder — same shell |
| **Use case** | Simple post-install tasks | Complex logic needing installer state |

## Implementation Pattern

The `stage_end_action()` function executes the configured post-install action based on `END_ACTION`. Unmounting and syncing are handled by the Teardown step (step 7 in the pipeline) before `stage_end_action()` is called.

### `script` Mode

Expects `END_ACTION_SCRIPT` env var pointing to script path. The script receives `TARGET_DIR` as an environment variable.

```bash
export END_ACTION="script"
export END_ACTION_SCRIPT="/path/to/post-install.sh"
```

The script runs **outside** the chroot, after teardown. It inherits all installer environment variables but cannot modify the installer's shell state.

### `func` Mode

Expects the user to define a custom function before running the installer. The function name **must match** the value of `END_ACTION_FUNC`.

> **⚠️ Important:** Bash functions do NOT export across shell boundaries by default. For `END_ACTION=func` to work, the function **MUST** be defined in the **parent shell** and **exported** via `export -f`. Without `export -f`, the function will not be found in the installer subprocess.

```bash
export END_ACTION="func"
export END_ACTION_FUNC="my_post_install"

my_post_install() {
  log_info "Running custom post-install function"
}
export -f my_post_install

./install.sh
```

### Safety Notes

- `stage_end_action()` is called after the Teardown step completes (unmount + sync already done)
- All modes only execute the configured action (shutdown, reboot, script, func, or none)
- `script` mode validates that `END_ACTION_SCRIPT` is set before proceeding
- `func` mode validates that `END_ACTION_FUNC` is set before proceeding
- Invalid `END_ACTION` values result in a `log_error` and exit code `9`

### Double Unmount Handling

The signal handler (`trap_cleanup`) calls `umount -R "${TARGET_DIR}"` on interruption. The Teardown step (step 7) also calls `umount -R` on normal completion. The `|| true` guard ensures that if `trap_cleanup` has already unmounted, the Teardown step will fail silently. `stage_end_action()` does **NOT** call unmount — it only executes the configured action. See `docs/signal_handling.md` for more details.
