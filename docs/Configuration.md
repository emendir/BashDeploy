`installer.conf` allows you to configure the installer's defaults on a per-project basis. The file, if present, is sourced by `install.sh` early in execution, so it can set variables or export environment for hooks.

**Important security note:** `installer.conf` is *sourced as shell code*. Treat it as executable code: review it before running the installer on untrusted repositories.

---

## Where to place it

Add `installer.conf` to your project root, next to `install.sh`. The installer will load it automatically if the file exists.

---

## Variables the installer checks (and how to override them)

The installer defines defaults in the script as `DEF_<NAME>` and then reads (sources) `installer.conf`. The following `DEF_*` variables are used by the shipped script and are safe to override in `installer.conf`:

* `DEF_INSTALL_DIR` — default installation directory (default: `/opt/<project>`)
* `DEF_SSH_ADDRESS` — default remote SSH address (default: empty)
* `DEF_EXCLUDE_FILE` — default file containing patterns to ignore when copying files to installation directory (default: `.gitignore`)
* `DEF_WITH_SYSTEMD` — whether to install systemd units by default (`true` or `false`)
* `DEF_ENABLE_UNITS` — whether to enable & start units by default (`true` or `false`)

Other useful variables that the script respects or that you may want to export for hooks:

* `SSH_OPTS` — extra options passed to `ssh`/`rsync` (export or set before invoking the installer; the script reads `SSH_OPTS` via parameter expansion)

**Example `installer.conf`:**

```sh
## change the default installation dir
#DEF_INSTALL_DIR="/srv/myproject"
## change the default file with the patterns for files to be excluded when copying for installation
#DEF_EXCLUDE_FILE="deployment/ignore"
## disable automatic systemd installation by default
#DEF_WITH_SYSTEMD=false
## keep units from being enabled automatically
#DEF_ENABLE_UNITS=false
## optionally set common SSH options for remote installs
#SSH_OPTS='-i ~/.ssh/deploy_key -o StrictHostKeyChecking=no'

```

> Tip: keep `installer.conf` small and declarative — set defaults and `export` values that hooks will need. Because it is sourced, any shell code is allowed but that also makes it a potential attack vector.

## Security checklist for configuration

* Confirm `installer.conf` and all hook scripts are audited before running installer.
* Avoid embedding secrets inside `installer.conf` (or ensure `installer.conf` is stored & distributed securely). Prefer to read sensitive values from a secrets manager in hooks.
