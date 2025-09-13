_This document explains how the installer handles systemd unit files, where to place them in your project, and recommended patterns for writing units that work well with the installer._

## Overview

This installer provides additional support for automatically installing systemd units, including services, timers etc.
All you have to do is define your systemd units and put them in one of the following directories:


* System (machine-wide) units: `deployment/systemd_units/system/`
* User (per-user) units: `deployment/systemd_units/user/`

### Supported Units

- service
- timer
- socket
- target
- mount
- automount
- path
- device
- swap
- slice
- scope


---

## What the installer does with unit files

1. For each unit file in `deployment/systemd_units/system/`, the installer runs

   ```sh
   sudo cp "$unit" /etc/systemd/system/
   ```
2. For each unit file in `deployment/systemd_units/user/`, the installer runs

   ```sh
   mkdir -p "$HOME/.config/systemd/user"
   cp "$unit" "$HOME/.config/systemd/user/"
   ```

   (No `sudo` is used for user units.)
3. The installer calls `sudo systemctl daemon-reload` once after copying.
4. If `--enable-units` is true, the installer enables and starts `.service` and `.timer` units with:

   * system scope: `sudo systemctl enable --now <unit-file-name>`
   * user scope: `systemctl --user enable --now <unit-file-name>`
5. Finally, post-systemd hooks are executed.

---

## Important notes & caveats

* **User vs system contexts and `HOME`**: The installer installs user units to `$HOME/.config/systemd/user`. If you run `install.sh` with `sudo`, `$HOME` will be `root` and user units will end up in root's user configuration — probably not what you want. **Run the installer as the intended non-root user** and let the installer call `sudo` for root tasks.
* **Daemon reload for user units:** the script calls `sudo systemctl daemon-reload` (system daemon). The installer does **not** call `systemctl --user daemon-reload`. On most systems `systemctl --user enable --now` will trigger the user manager to notice new units, but if you see issues with user units not being recognized, add a `systemctl --user daemon-reload` step in a `post_systemd.d` hook or in `post_systemd.sh`.
* **Enabling & starting units can fail**: `systemctl enable --now` or `systemctl --user enable --now` may fail if the unit file is invalid or a required dependency is missing. Because the installer uses `set -e`, such failure will abort the installer. Use `--no-enable-units` to install units but not start them.
* **Timers** are handled along with services (both copied and optionally enabled/started). Ensure your `.timer` unit pairs have a corresponding `.service` unit.
* **Cleanup:** the installer copies units but does not automatically remove older unit files from `/etc/systemd/system/` if you later delete them from the repo. To remove a unit you must `sudo systemctl disable --now <unit>`, delete the unit file, and run `sudo systemctl daemon-reload`.

---

## Writing unit files that work well with the installer

* Use **absolute paths** in `ExecStart=` pointing into the final `$INSTALL_DIR` (for example `/opt/MyProject/bin/serve`). The installer does not rewrite unit files.
* Avoid assuming `ExecStart` will be run as a certain user — set `User=` in the `[Service]` block if you need a system unit to run as a specific user.
* For user units, do not set `User=` — they run as the owning user.
* For services that must start at boot, include the appropriate `WantedBy=` (for example `WantedBy=multi-user.target`) in the `[Install]` section.

**Example system unit** (`deployment/systemd_units/system/myproject.service`):

```ini
[Unit]
Description=MyProject service
After=network.target

[Service]
Type=simple
User=myappuser
WorkingDirectory=/opt/MyProject
ExecStart=/opt/MyProject/bin/myproject serve
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

**Example user unit** (`deployment/systemd_units/user/myproject.service`):

```ini
[Unit]
Description=MyProject user service

[Service]
Type=simple
WorkingDirectory=%h/.local/myproject
ExecStart=%h/.local/myproject/venv/bin/myproject serve
Restart=on-failure

[Install]
WantedBy=default.target
```

---

## Recommended post-systemd hook examples

If you need to ensure the user manager sees new user units, or to wait until a service is healthy before proceeding, add a `post_systemd.d` hook.

**Force user daemon reload and wait for service**

```sh
#!/usr/bin/env bash
set -euo pipefail
# force the user manager to reload unit files
systemctl --user daemon-reload
# wait until the service reports ready
for i in {1..20}; do
  if systemctl --user is-active --quiet myproject.service; then
    break
  fi
  sleep 1
done
```

---

## Rollback & clean removal of installed units

To remove units installed by this installer:

1. Stop and disable the units:

   ```sh
   sudo systemctl disable --now myproject.service myproject.timer
   systemctl --user disable --now myproject.service
   ```
2. Remove the unit file(s) from `/etc/systemd/system/` or `~/.config/systemd/user/`.
3. Run `sudo systemctl daemon-reload` (and `systemctl --user daemon-reload` for user units).

