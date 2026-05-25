# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-file Bash installer (`install.sh`) that consumers drop into the root of their own project. It rsyncs the project to a deployment directory (locally or over SSH), installs systemd units, and runs user-defined hook scripts. There is no build step and no runtime dependency beyond `bash`, `rsync`, `ssh`, and `sudo`.

The shipped artifact is literally `install.sh`. Everything else in this repo is documentation (`docs/`, `README.md`) or test scaffolding (`test.sh`).

## Running the test suite

`./test.sh` is the only test runner. It builds an Ubuntu 24.04 Docker image with systemd, then runs five integration scenarios that copy `install.sh` into a container and exercise each combination of hooks and unit files. The remote-install test uses `docker exec ... service ssh start` and the user's first `~/.ssh/*.pub` key, so the host needs an SSH keypair.

Requirements to run tests: Docker daemon, `--privileged` permission, and an SSH public key in `~/.ssh/`. There is no way to run an individual case without editing the bottom of `test.sh` — the five `run_test`/`run_remote_test` invocations are hardcoded.

## Installer architecture

The script has five sequential phases, all in one file:

1. **Config resolution** (top of `install.sh`). `installer.conf` next to the script is `source`d if present; then each setting falls back to a built-in default via `${VAR:-...}`. Then CLI args are parsed and override everything else. Effective precedence: **CLI args > `installer.conf` > environment variables > built-in defaults** — note the config file wins over env vars because `source` runs before the `${VAR:-...}` defaults. All resolved settings are then `export`ed for hooks.

2. **Pre-copy hooks** (source machine only). `run_hook_dir "$HOOKS_DIR/pre_copy.d"` followed by `pre_copy.sh` (only if executable). This runs *before* the remote-dispatch rsync and before the local rsync. The internal env var `BASHDEPLOY_SKIP_PRE_COPY=true` is set by the remote dispatch when it re-executes the installer on the target, so pre-copy hooks never run twice for a remote install.

3. **Remote dispatch** (if `--remote` / `SSH_ADDRESS` set). The script `ssh`s in, ensures `$INSTALL_DIR` exists, `rsync`s the tree across, then re-executes itself remotely with the same flags plus `BASHDEPLOY_SKIP_PRE_COPY=true`. The remote run takes the *local* branch (no `SSH_ADDRESS`) and behaves as a normal local install with pre-copy suppressed. After dispatching it `exit`s — phases 4–5 only run in the local branch.

4. **Copy + post-copy hooks**. `sudo rsync -a --delete --exclude-from=$EXCLUDE_FILE` from `$PROJECT_ROOT_DIR` to `$INSTALL_DIR`, then `run_hook_dir "$HOOKS_DIR/post_copy.d"` followed by `post_copy.sh` (only if executable).

5. **Systemd + post-systemd hooks**. Iterates `system/` and `user/` subdirs of `$SYSTEMD_DIR`, copies each known unit type (the literal glob `*.{service,timer,socket,target,mount,automount,path,device,swap,slice,scope}` in `install.sh:220`), runs `sudo systemctl daemon-reload`, optionally enables/starts `.service` and `.timer` units, then runs post-systemd hooks.

### Things that bite

- `rsync --delete` deletes files in the target that aren't in the source. Changing `INSTALL_DIR` to a directory with unrelated contents will wipe them.
- The script runs the *local user's* installer, not `sudo install.sh`. It `sudo`s for the specific commands that need root. Running the whole script under `sudo` causes user systemd units to land in `/root/.config/systemd/user`.
- `set -euo pipefail` is on, so a single failed `systemctl enable --now` aborts the install. Use `--no-enable-units` to install units without starting them.
- Hooks in `*.d/` are launched via `bash "$script"` regardless of the executable bit; the single-file `post_copy.sh` / `post_systemd.sh` wrappers are only run if `-x`. (Documented in `docs/Hooks.md`.)
- Files in `*.d/` are executed in glob/alphabetical order — convention is `00-`, `10-`, `50-` prefixes.

### Variables hooks can rely on

All hooks run as subshells with these exported: `PROJECT_NAME`, `PROJECT_ROOT_DIR`, `INSTALL_DIR`, `DEPLOY_DIR`, `HOOKS_DIR`, `SYSTEMD_DIR`, `WITH_SYSTEMD`, `ENABLE_UNITS`, `SSH_ADDRESS`, `SSH_OPTS`, `RSYNC_OPTS`, `COPY_ONLY`, `EXCLUDE_FILE`. `PROJECT_ROOT_DIR` is always absolute.

## Editing rules

- `install.sh` ships as-is to downstream projects — keep it self-contained, no sourcing of repo-local helpers.
- Treat `installer.conf` and hook files as untrusted shell code in documentation and design: they execute with the user's privileges and can `sudo`.
- When adding a new CLI flag, update: the `usage()` heredoc, the `case` block, `docs/Parameters.md`, and the option summary in `README.md`.
- When adding a new configurable variable, add it to the export block (so hooks see it) and document it in `docs/Configuration.md`.
