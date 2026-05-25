## Configuration Methods

Parameters can be specified via variables in `installer.conf`, environment variables or (for some) via command line arguments.

### Precedence:

1. command-line arguments (see [Parameters](./Parameters.md))
2. environment variables (see [Parameters](./Parameters.md))
3. config-file variables

### Variables

The following variables can be defined as environment variables or in the config-file.
Config-File definitions take precedence over environment variables.

- `PROJECT_ROOT_DIR` — the root path of the project directory relative to the BashDeploy installer script
- `PROJECT_NAME` — project name, for computing default install directory (default: the project's root directory's name)
- `INSTALL_DIR` — installation directory (default: `/opt/<PROJECT_NAME>`)
- `DEPLOY_DIR` — directory to look for `hooks` and `systemd_units` folders (defail: `./deployment`)
- `HOOKS_DIR` — directory containing scripts to execute during installation (see [Hooks](./Hooks.md)) (default: `<DEPLOY_DIR>/hooks`)
- `SYSTEMD_DIR` — directory containing Systemd units (see [SystemdUnits](./SystemdUnits)) (default: `<DEPLOY_DIR>/systemd`)
- `SSH_ADDRESS` — default remote SSH address (default: empty)
- `EXCLUDE_FILE` — default file containing patterns to ignore when copying files to installation directory (default: `.gitignore`)
- `WITH_SYSTEMD` — whether to install systemd units by default (`true` or `false`)
- `ENABLE_UNITS` — whether to enable & start units by default (`true` or `false`)
- `SSH_OPTS` — extra options passed to `ssh`/`rsync` (default: empty)
- `RSYNC_OPTS` — extra options passed to `rsync`, in addition to `-a --delete --exclude-from=<EXCLUDE_FILE>` (default: `-h --info=progress2`)
- `USER_ENV` — bash array of `"KEY=VALUE"` entries that are `export`ed for hooks and forwarded to remote re-executions. Only meaningful in `installer.conf` (arrays don't survive environment-variable export). CLI `--env KEY=VALUE` flags override entries with the same key. Example: `USER_ENV=("DEPLOY_ENV=production" "FEATURE_X=1")`

### Installer Configuration File

`installer.conf` allows you to configure the installer's defaults on a per-project basis.
The file, if present, is sourced by `install.sh` early in execution, so it can set variables or export environment for hooks.

**WARNING:** Variables in the configuration file override environment variables!

**Important security note:** `installer.conf` is _sourced as shell code_. Treat it as executable code: review it before running the installer on untrusted repositories.

Add `installer.conf` to your project root, next to `install.sh`. The installer will load it automatically if the file exists.

**Example `installer.conf`:**

```sh
## change the default installation dir
#INSTALL_DIR="/srv/myproject"
## change the default file with the patterns for files to be excluded when copying for installation
#EXCLUDE_FILE="deployment/ignore"
## disable automatic systemd installation by default
#WITH_SYSTEMD=false
## keep units from being enabled automatically
#ENABLE_UNITS=false
## optionally set common SSH options for remote installs
#SSH_OPTS='-i ~/.ssh/deploy_key -o StrictHostKeyChecking=no'
## extra env vars exported for hooks and forwarded over SSH for remote installs
#USER_ENV=("DEPLOY_ENV=production" "FEATURE_X=1")

```

> Tip: keep `installer.conf` small and declarative — set defaults and `export` values that hooks will need. Because it is sourced, any shell code is allowed but that also makes it a potential attack vector.

## Security checklist for configuration

- Confirm `installer.conf` and all hook scripts are audited before running installer.
- Avoid embedding secrets inside `installer.conf` (or ensure `installer.conf` is stored & distributed securely). Prefer to read sensitive values from a secrets manager in hooks.
