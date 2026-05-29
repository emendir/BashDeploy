#!/usr/bin/env bash
## BashDeploy: Generic project installer
##
## Drop this script into the root of your project. Running it rsyncs the
## project into a deployment directory (locally or over SSH), installs any
## systemd units it finds, and runs your hook scripts.
##
## Quick start:
##   ./install.sh                       Install locally (default: /opt/<project>)
##   ./install.sh --remote user@host    Install on a remote machine via SSH
##   ./install.sh --dir /srv/myapp      Install to a custom directory
##   ./install.sh --help                List all options
##
## Optional layout (all paths configurable, see installer.conf):
##   deployment/hooks/         pre_copy / post_copy / post_systemd hook scripts
##   deployment/systemd_units/ system/ and user/ unit files to install
##   installer.conf            override defaults (INSTALL_DIR, hooks, etc.)
##
## More details: https://github.com/emendir/BashDeploy

set -euo pipefail

err() {
    echo -e "\033[0;31mERROR: $*\033[0m" >&2
    exit 1
}

##############################################
# CONFIGURATION
##############################################
BASHDEPLOY_SCRIPT_PATH=$(readlink -f "$0")
BASHDEPLOY_SCRIPT_DIR=$(dirname "$BASHDEPLOY_SCRIPT_PATH")


# Load config file if present
CONFIG_FILE="$BASHDEPLOY_SCRIPT_DIR/installer.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# Merge user-defined env vars from config (USER_ENV array) into an internal
# map. CLI --env flags below override config entries on duplicate keys.
declare -A _USER_ENV_MAP=()
if [[ -n "${USER_ENV+x}" ]]; then
  for _pair in "${USER_ENV[@]}"; do
    [[ "$_pair" == *"="* ]] || err "USER_ENV entry missing '=': $_pair"
    _USER_ENV_MAP["${_pair%%=*}"]="${_pair#*=}"
  done
fi

cd "$BASHDEPLOY_SCRIPT_DIR"
PROJECT_ROOT_DIR=${PROJECT_ROOT_DIR:-$BASHDEPLOY_SCRIPT_DIR}
PROJECT_ROOT_DIR=$(readlink -f "$PROJECT_ROOT_DIR") # ensure absolute path
if [ "${PROJECT_ROOT_DIR:?}" = "/" ];then
    echo "Error: PROJECT_ROOT_DIR is set to '$PROJECT_ROOT_DIR'"
    exit 1
fi
cd "$PROJECT_ROOT_DIR"

# Set configurations if not already defined in config file.
# Paths are relative to PROJECT_ROOT_DIR.
PROJECT_NAME=${PROJECT_NAME:-$(basename "$PROJECT_ROOT_DIR")}
INSTALL_DIR=${INSTALL_DIR:-"/opt/$PROJECT_NAME"}
DEPLOY_DIR=${DEPLOY_DIR:-"$PROJECT_ROOT_DIR/deployment"}
HOOKS_DIR=${HOOKS_DIR:-"$DEPLOY_DIR/hooks"}
SYSTEMD_DIR=${SYSTEMD_DIR:-"$DEPLOY_DIR/systemd_units"}
WITH_SYSTEMD=${WITH_SYSTEMD:-true}
ENABLE_UNITS=${ENABLE_UNITS:-true}

SSH_ADDRESS=${SSH_ADDRESS:-""}
SSH_OPTS="${SSH_OPTS:-}"
RSYNC_OPTS="${RSYNC_OPTS:-"-h --info=progress2"}"
COPY_ONLY="${COPY_ONLY:-}"
EXCLUDE_FILE=${EXCLUDE_FILE:-"$PROJECT_ROOT_DIR/.gitignore"}


# Path of this installer script relative to PROJECT_ROOT_DIR
INSTALLER_PATH=$(realpath --relative-to="$PROJECT_ROOT_DIR" "$BASHDEPLOY_SCRIPT_PATH")


##############################################
# ARGUMENT PARSING
##############################################

usage() {
cat <<EOF
BashDeploy

Usage: $0 [OPTIONS]

Options:
  --remote <user@host>   Install on remote machine via SSH
  --dir <path>           Installation directory (default: $INSTALL_DIR)
  --exclude-from <path>  Installation directory (default: $EXCLUDE_FILE)
  --with-systemd         Install systemd units (default: $WITH_SYSTEMD)
  --no-systemd           Skip systemd unit installation
  --enable-units         Enable and start systemd units (default: $ENABLE_UNITS)
  --no-enable-units      Do not enable/start units after install
  --only-copy            Only copy files to installation target, without running setup/installation scripts
  --env KEY=VALUE        Extra env var to export to hooks and forward to remote re-execution (repeatable)
  --help                 Show this help

Find out more at:
https://github.com/emendir/BashDeploy
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --remote)
      SSH_ADDRESS="$2"; shift 2;;
    --dir)
      INSTALL_DIR="$2"; shift 2;;
    --exclude-from)
      EXCLUDE_FILE="$2"; shift 2;;
    --with-systemd)
      WITH_SYSTEMD=true; shift;;
    --no-systemd)
      WITH_SYSTEMD=false; shift;;
    --enable-units)
      ENABLE_UNITS=true; shift;;
    --no-enable-units)
      ENABLE_UNITS=false; shift;;
    --copy-only)
      COPY_ONLY=true; shift;;
    --env)
      [[ "${2:-}" == *"="* ]] || err "--env requires KEY=VALUE form, got: ${2:-}"
      _USER_ENV_MAP["${2%%=*}"]="${2#*=}"
      shift 2;;
    --help)
      usage; exit 0;;
    *)
      err "Unknown option: $1";;
  esac
done

if ! [ -e "$EXCLUDE_FILE" ]; then
  touch "$EXCLUDE_FILE"
fi

# export for availability to hooks
export PROJECT_NAME
export PROJECT_ROOT_DIR
export INSTALL_DIR
export DEPLOY_DIR
export HOOKS_DIR
export SYSTEMD_DIR
export WITH_SYSTEMD
export ENABLE_UNITS

export SSH_ADDRESS
export SSH_OPTS
export RSYNC_OPTS
export COPY_ONLY
export EXCLUDE_FILE

# Export user-defined env vars so hooks (local and remote) see them
for _k in "${!_USER_ENV_MAP[@]}"; do
  export "$_k=${_USER_ENV_MAP[$_k]}"
done

##############################################
# HELPERS
##############################################
notify() {
    local message="$1"
    local def_color='\033[0;36m'
    local color="${2:-$def_color}"
    echo -e "${color}==> ${message}\033[0m"
}

warning() {
    local message="$1"
    local color="${2:-}\033[0;33m"
    echo -e "${color}==> ${message}\033[0m"
}

run_hook_dir() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    for script in "$dir"/*.sh; do
      [[ -e "$script" ]] || continue
      notify "Running hook: $(basename "$script")"
      bash "$script"
    done
  fi
}

assert_ssh_host_reachable() {
    local ssh_target="$1"
    local host

    # Extract host from:
    #   user@host
    #   host
    #   ssh://user@host:port
    #   [IPv6]
    #   user@[IPv6]
    if [[ "$ssh_target" =~ ^ssh:// ]]; then
        host="${ssh_target#ssh://}"
        host="${host#*@}"
        host="${host%%:*}"
    else
        host="${ssh_target#*@}"

        # IPv6 in brackets
        if [[ "$host" =~ ^\[.*\]$ ]]; then
            host="${host#[}"
            host="${host%]}"
        else
            # Strip :port for hostname / IPv4
            host="${host%%:*}"
        fi
    fi

    if [[ -z "$host" ]]; then
        printf 'ERROR: could not parse host from "%s"\n' "$ssh_target" >&2
        return 1
    fi

    # Check TCP reachability on SSH port without ping
    if ! timeout 5 bash -c "exec 3<>/dev/tcp/$host/22" 2>/dev/null; then
        printf 'ERROR: SSH host "%s" is unreachable on port 22\n' "$host" >&2
        return 1
    fi
}

##############################################
# PRE-FLIGHT CHECKS
##############################################
if [[ -n "$SSH_ADDRESS" ]]; then
  assert_ssh_host_reachable "$SSH_ADDRESS"
fi

##############################################
# PRE-COPY HOOKS (source machine only)
##############################################
# Pre-copy hooks always execute on the source machine, before any files are
# copied to the installation target. For remote installs they run locally,
# before the rsync over SSH; the remote re-execution sets
# BASHDEPLOY_SKIP_PRE_COPY=true to ensure they are not run again on the target.
if [[ "${BASHDEPLOY_SKIP_PRE_COPY:-}" != true ]]; then
  run_hook_dir "$HOOKS_DIR/pre_copy.d"
  [[ -x "$HOOKS_DIR/pre_copy.sh" ]] && bash "$HOOKS_DIR/pre_copy.sh"
fi

##############################################
# REMOTE INSTALL HANDLING
##############################################
if [[ -n "$SSH_ADDRESS" ]]; then
  notify "Installing remotely on $SSH_ADDRESS"

  # Ensure target directory exists and is owned by the remote user
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$SSH_ADDRESS" -t "sudo mkdir -p '$INSTALL_DIR' && sudo chown \$USER:\$USER '$INSTALL_DIR'"

  echo "Copying from $PROJECT_ROOT_DIR to $SSH_ADDRESS:$INSTALL_DIR"

  # Copy project files over
  # shellcheck disable=SC2086
  rsync -a --delete --exclude-from="$EXCLUDE_FILE" -e "ssh $SSH_OPTS" $RSYNC_OPTS "$PROJECT_ROOT_DIR/" "$SSH_ADDRESS:$INSTALL_DIR/"

  if [[ $COPY_ONLY != true ]];then
    # Forward user-defined env vars as --env KEY=VALUE args so the CLI-wins
    # precedence is preserved over any USER_ENV in the remote's installer.conf.
    USER_ENV_ARGS=""
    for _k in "${!_USER_ENV_MAP[@]}"; do
      USER_ENV_ARGS+=" --env $(printf '%q' "$_k=${_USER_ENV_MAP[$_k]}")"
    done

    # Re-run installer remotely
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$SSH_ADDRESS" -t "
      BASHDEPLOY_SKIP_PRE_COPY=true \
      PROJECT_NAME=$PROJECT_NAME \
      PROJECT_ROOT_DIR=$INSTALL_DIR \
      INSTALL_DIR=$INSTALL_DIR \
      DEPLOY_DIR=$DEPLOY_DIR \
      HOOKS_DIR=$HOOKS_DIR \
      SYSTEMD_DIR=$SYSTEMD_DIR \
      WITH_SYSTEMD=$WITH_SYSTEMD \
      ENABLE_UNITS=$ENABLE_UNITS \
      bash '$INSTALL_DIR/$INSTALLER_PATH' --dir '$INSTALL_DIR' \
      $([[ $WITH_SYSTEMD == true ]] && echo --with-systemd || echo --no-systemd) \
      $([[ $ENABLE_UNITS == true ]] && echo --enable-units || echo --no-enable-units) \
      $USER_ENV_ARGS \
      "
    exit 0
  else
    notify "Not installing on remote machine because --copy-only is set."
    exit 0
  fi
fi

##############################################
# LOCAL INSTALLATION
##############################################
notify "Installing to $INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR"
# shellcheck disable=SC2086

sudo rsync -a --delete --exclude-from=$EXCLUDE_FILE $RSYNC_OPTS "$PROJECT_ROOT_DIR/" "$INSTALL_DIR/"

# Run post-copy hooks
run_hook_dir "$HOOKS_DIR/post_copy.d"
[[ -x "$HOOKS_DIR/post_copy.sh" ]] && bash "$HOOKS_DIR/post_copy.sh"

##############################################
# SYSTEMD UNIT HANDLING
##############################################
if ! [ -e "$SYSTEMD_DIR" ]; then
    if [[ "$WITH_SYSTEMD" == true ]]; then
        warning "No systemd units folder found: $SYSTEMD_DIR"
    fi
  WITH_SYSTEMD=false
fi
if [[ "$WITH_SYSTEMD" == true ]]; then
  notify "Installing systemd units"

  for scope in system user; do
    UNIT_DIR="$SYSTEMD_DIR/$scope"
    [[ -d "$UNIT_DIR" ]] || continue

    for unit in "$UNIT_DIR"/*.{service,timer,socket,target,mount,automount,path,device,swap,slice,scope}; do
      [[ -e "$unit" ]] || continue

      notify "- $(basename "$unit")"
      if [[ $scope == system ]]; then
        sudo cp "$unit" /etc/systemd/system/
      else
        mkdir -p "$HOME/.config/systemd/user"
        cp "$unit" "$HOME/.config/systemd/user/"
      fi
    done
  done
  sudo systemctl daemon-reload
  if [[ "$ENABLE_UNITS" == true ]]; then
    notify "Enabling and starting units"
    for scope in system user; do
      UNIT_DIR="$SYSTEMD_DIR/$scope"
      [[ -d "$UNIT_DIR" ]] || continue
      for unit in "$UNIT_DIR"/*.{service,timer}; do
        [[ -e "$unit" ]] || continue
        if [[ $scope == system ]]; then
          sudo systemctl enable --now "$(basename "$unit")"
        else
          systemctl --user enable --now "$(basename "$unit")"
        fi
      done
    done
  fi

  # Run post-systemd hooks
  run_hook_dir "$HOOKS_DIR/post_systemd.d"
  [[ -x "$HOOKS_DIR/post_systemd.sh" ]] && bash "$HOOKS_DIR/post_systemd.sh"
fi

notify "Installation complete"

