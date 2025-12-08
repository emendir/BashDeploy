_This file documents every CLI option exposed by `install.sh`, explains defaults, environment switches and common usage patterns._


## Quick summary of options

```
--remote <user@host>   Install on remote machine via SSH
--dir <path>           Installation directory (default: /opt/<project>)
--exclude-from <path>  Installation directory (default: .gitignore)
--with-systemd         Install systemd units (default: true)
--no-systemd           Skip systemd unit installation
--enable-units         Enable and start systemd units (default: true)
--no-enable-units      Do not enable/start units after install
--help                 Show this help
```

### Behaviour notes

* Unknown options cause the installer to exit with an error.
* `set -euo pipefail` is used in the installer, so any command that exits non‑zero will abort the installation.
* The installer relies on `rsync`, `bash`, and (for remote installs) `ssh`.

---

## Option details

### `--remote <user@host>`

* **What it does:** Tells the installer to perform a remote install over SSH to the address you provide (for example `user@10.0.0.5`).
* **How it works:**

  1. The installer first ensures the remote `$INSTALL_DIR` exists by running `ssh $SSH_OPTS "$SSH_ADDRESS" "mkdir -p '$INSTALL_DIR'"`.
  2. It then uses `rsync -a $RSYNC_OPTS --delete -e "ssh $SSH_OPTS" "$SCRIPT_DIR/" "$SSH_ADDRESS:$INSTALL_DIR/"` to copy the project to the remote host.
  3. Finally it re‑executes the installer remotely by running `ssh $SSH_OPTS "$SSH_ADDRESS" "bash '$INSTALL_DIR/$(basename "$SCRIPT_PATH")' --dir '$INSTALL_DIR' [--with-systemd|--no-systemd] [--enable-units|--no-enable-units]"`.
* **Notes/Recommendations:**

  * The remote re-run executes on the remote host as the remote user. The remote run will invoke `sudo` when the installer needs system permissions, so the remote user needs `sudo` access (and may need passwordless sudo or an interactive password prompt depending on your SSH settings).
  * You can pass SSH options with the `SSH_OPTS` environment variable (see below).

### `--dir <path>`

* **What it does:** Sets the target installation directory (`INSTALL_DIR`).
* **Default:** `/opt/<project>` where `<project>` is the directory name that contains the installer script (value is computed as `PROJ_NAME=$(basename "$SCRIPT_DIR")` and `DEF_INSTALL_DIR="/opt/$PROJ_NAME"`).
* **Examples:** `--dir /opt/MyProject`, `--dir /srv/myproject`

### `--exclude-from <path>`

* **What it does:** Sets the file from which to load the patterns of files to be ignored when copying files to the installation directory.
* **Default:** `.gitignore` in your project's root
* **Examples:** `--exclude-from deployment/ignore`

### `--with-systemd` / `--no-systemd`

* **What they do:** Toggle whether systemd unit files in `deployment/systemd_units/` are installed to the system and user unit locations.
* **Default:** `--with-systemd` is the default behaviour (unless overridden via `installer.conf` by changing `DEF_WITH_SYSTEMD`).
* **Notes:** If you skip systemd installation you still get copy of project files and post-copy hooks.

### `--enable-units` / `--no-enable-units`

* **What they do:** If `WITH_SYSTEMD` is enabled, this controls whether the installer will run `systemctl enable --now` (system) and `systemctl --user enable --now` (user) for available `.service` and `.timer` units.
* **Default:** `--enable-units` (unless overridden via `installer.conf` by changing `DEF_ENABLE_UNITS`).
* **Notes:** Enabling and starting a unit that fails will cause the script to fail (because of `set -e`). If you want to install but not start services immediately, use `--no-enable-units`.

### `--help`

Displays usage and exits.

---

## Environment variables the installer reads (without modifying the script)

* **`SSH_OPTS`** — optional. Any additional options passed to `ssh`/`rsync -e` (for example `-i /path/to/key -p 2222 -o "StrictHostKeyChecking=no"`). The script reads `SSH_OPTS` and inserts it into `ssh` and `rsync` commands.
* **`RSYNC_OPTS`** — optional. Any additional options passed to `rsync` (for example `-L`). The script reads `RSYNC_OPTS` and inserts it into `rsync` commands.

> Important: other installer variables (for example `INSTALL_DIR`, `WITH_SYSTEMD`, etc.) are assigned inside the script from internal defaults (DEF\_\*). If you want to change those you should either set them in `installer.conf` (the file is sourced), or edit the script. The script does not accept arbitrary environment-variable overrides for every setting.

---

## Examples

Install locally into `/opt/MyProject` (default behaviour):

```bash
./install.sh --dir /opt/MyProject
```

Install to a remote machine using a custom SSH key and port:

```bash
SSH_OPTS='-i ~/.ssh/id_ed25519 -p 2222' ./install.sh --remote user@203.0.113.7 --dir /opt/MyProject
```

Install but do not enable or start services:

```bash
./install.sh --dir /opt/MyProject --no-enable-units
```

---

## Behaviour gotchas & tips

* The installer uses `rsync -a --delete` which will remove files in the target directory that are not present in the source. **Do not install into a directory that contains unrelated important files.**
* If you run the top‑level `install.sh` under `sudo`, note that `HOME`, `USER` and other environment variables will likely point to `root` — that changes where user units are installed (`$HOME/.config/systemd/user`) and which user `systemctl --user` will operate on. For most cases you should run `install.sh` as the intended user (not `sudo`), and allow the script to call `sudo` for the small actions that require it.
* The installer will abort on any command failure because `set -e` is used. If one of your hooks or `systemctl` actions fails, the whole install will stop.
