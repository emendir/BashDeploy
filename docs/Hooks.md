_How to add custom installation scripts._

## Overview

Hooks are the primary extension mechanism provided by the installer. Hooks let your project run arbitrary shell code at two lifecycle points:

* **after the project files are copied** (post-copy hooks), and
* **after systemd units have been installed and optionally enabled** (post-systemd hooks).

Hook files live under `deployment/hooks/` in the project tree.

---

## Hook locations and execution order

* `deployment/hooks/post_copy.d/*.sh` — run first (alphabetical order according to glob expansion). Each file is executed with `bash "<script>"`.

* `deployment/hooks/post_copy.sh` — executed after the `post_copy.d` directory scripts **but only if it is executable** (checked with `[[ -x ".../post_copy.sh" ]]`). It is executed with `bash ".../post_copy.sh"`.

* `deployment/hooks/post_systemd.d/*.sh` — run after systemd units were copied and `systemctl daemon-reload` was called (alphabetical order).

* `deployment/hooks/post_systemd.sh` — executed after `post_systemd.d` scripts if the file is executable.

**Important differences:** files in `*.d/*.sh` are invoked by `bash "$script"` whether or not they have the executable bit set, because they are launched directly with `bash`. In contrast the single `post_* .sh` wrapper is run only if it is executable (the script checks `-x` before running it).

### Ordering example (the actual execution order)

1. `deployment/hooks/post_copy.d/00-setup.sh`
2. `deployment/hooks/post_copy.d/10-chown.sh`
3. `deployment/hooks/post_copy.sh` (if executable)
4. (systemd units copied, daemon reload, units enabled/started if requested)
5. `deployment/hooks/post_systemd.d/00-wait-for-service.sh`
6. `deployment/hooks/post_systemd.d/10-db-migrate.sh`
7. `deployment/hooks/post_systemd.sh` (if executable)

---

## What hooks should do — recommended responsibilities

**Post-copy hooks** typically perform tasks that prepare the freshly copied project for runtime, for example:

* create virtual environments and install Python packages
* `pip install -e .` or compile assets (webpack, etc.)
* set file permissions and ownership in `$INSTALL_DIR`
* create directories, sockets, or persistent data locations
* write configuration files that embed the final `$INSTALL_DIR` path

**Post-systemd hooks** usually perform actions that depend on services having been registered or started, for example:

* apply database migrations after the service has started
* run health checks, smoke tests, or API initialisation
* register the instance with service discovery
* notify external systems that the service is available

---

## Environment available to hooks

* Hooks are executed in a subshell invoked by the installer. **Only exported environment variables are visible to those subshells.**
* The installer, as shipped, does **not** export internal variables like `INSTALL_DIR` or `PROJ_NAME`. If your hook scripts rely on these values, you must either:

  1. **export them from `installer.conf`** (recommended), or
  2. export them earlier in the installer script (if you control the script), or
  3. compute them from known constants in the hook itself.

**Recommended `installer.conf` snippet to export useful variables**:

```sh
# installer.conf (example)
DEF_INSTALL_DIR="/opt/MyProject"
DEF_WITH_SYSTEMD=true
DEF_ENABLE_UNITS=true
# export runtime variables for hooks
export INSTALL_DIR="$DEF_INSTALL_DIR"
export PROJ_NAME="MyProject"
export SCRIPT_DIR="$(pwd)"
export HOOKS_DIR="$SCRIPT_DIR/deployment/hooks"
export SYSTEMD_DIR="$SCRIPT_DIR/deployment/systemd_units"
```

If you do not export useful variables, hooks must assume paths (for example `/opt/MyProject`) or query the environment at runtime.

---

## Hook writing guidelines (best practices)

* Make hooks small and idempotent. They will be re-run on subsequent installs.
* At top of each hook add safety options:

  ```sh
  #!/usr/bin/env bash
  set -euo pipefail
  ```
* Log clearly and exit non‑zero on fatal errors.
* Avoid assuming a particular `cwd`; use absolute paths (for example `"$INSTALL_DIR/bin/…"`) or compute `INSTALL_DIR` reliably.
* If a hook needs root privileges, it should call `sudo` for the specific command(s) it requires (the installer itself does not run hooks under `sudo`).
* Use numeric prefixes for ordering: `00-`, `10-`, `50-` etc.

---

## Example hooks

**`deployment/hooks/post_copy.d/10-chown.sh`**

```sh
#!/usr/bin/env bash
set -euo pipefail
# assume INSTALL_DIR is exported in installer.conf
if [[ -z "${INSTALL_DIR:-}" ]]; then
  echo "INSTALL_DIR not set; aborting"
  exit 1
fi
# make sure the run user owns files
sudo chown -R myuser:myuser "$INSTALL_DIR"
```

**`deployment/hooks/post_systemd.d/20-wait-and-migrate.sh`**

```sh
#!/usr/bin/env bash
set -euo pipefail
# Wait for service to become available then run DB migration
# (sleep loop is simple but replace with proper health check for production)
for i in {1..20}; do
  if curl --silent --fail http://localhost:8080/health; then
    echo "service ready — running DB migrations"
    "$INSTALL_DIR/bin/myproject" migrate
    exit 0
  fi
  sleep 1
done
echo "service never became ready, skipping migrations" >&2
exit 1
```

---

## Security & safety

* Hooks (and `installer.conf`) are executed as code. **Treat them as executable code.**
* Review hooks and unit files before running the installer in production. A malicious hook can run arbitrary commands with the privileges of the user running the installer or via `sudo` escalate privileges.


