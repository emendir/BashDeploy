#!/usr/bin/env bash
set -euo pipefail

IMAGE="installer-test:latest"
PROJECT_NAME="demo_project"
CONTAINER_NAME="ProjectInstallerTest"

# Ensure docker image exists
echo "[+] Building test image..."
docker build -t $IMAGE - <<'EOF'
FROM ubuntu:24.04
# install prerequisite packages
RUN apt update && apt install -y wget systemctl
RUN  DEBIAN_FRONTEND=noninteractive apt install -y rsync sudo openssh-server

# install systemd
RUN echo 'root:password' | chpasswd
RUN printf '#!/bin/sh\nexit 0' > /usr/sbin/policy-rc.d
RUN apt -y install systemd systemd-sysv dbus dbus-user-session 
RUN printf "systemctl start systemd-logind" >> /etc/profile
ENTRYPOINT ["/sbin/init"]


RUN echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/root_login.conf
EOF


# Utility: create fake project directory with optional hooks/systemd
make_project() {
  local dir="$1"
  shift
  mkdir -p "$dir/deployment/hooks" "$dir/deployment/systemd_units/system" "$dir/deployment/systemd_units/user"

  # Copy installer under test
  cp install.sh "$dir/install.sh"

  # Always include some project files
  echo "echo Hello World" > "$dir/hello.sh"
  echo "SAMPLE DATA" > "$dir/data.txt"

  # Hooks / systemd depending on args
  for f in "$@"; do
    case $f in
      pre-copy)
        echo 'touch "$PROJECT_ROOT_DIR/.hook_pre_copy"' > "$dir/deployment/hooks/pre_copy.sh"
        chmod +x "$dir/deployment/hooks/pre_copy.sh"
        ;;
      pre-copy-d)
        mkdir -p "$dir/deployment/hooks/pre_copy.d"
        echo 'touch "$PROJECT_ROOT_DIR/.hook_pre_copy_d"' > "$dir/deployment/hooks/pre_copy.d/10_test.sh"
        chmod +x "$dir/deployment/hooks/pre_copy.d/10_test.sh"
        ;;
      post-copy)
        echo "touch /opt/$PROJECT_NAME/.hook_post_copy" > "$dir/deployment/hooks/post_copy.sh"
        chmod +x "$dir/deployment/hooks/post_copy.sh"
        ;;
      post-systemd)
        echo "touch /opt/$PROJECT_NAME/.hook_post_systemd" > "$dir/deployment/hooks/post_systemd.sh"
        chmod +x "$dir/deployment/hooks/post_systemd.sh"
        ;;
      post-copy-d)
        mkdir -p "$dir/deployment/hooks/post_copy.d"
        echo "touch /opt/$PROJECT_NAME/.hook_post_copy_d" > "$dir/deployment/hooks/post_copy.d/10_test.sh"
        chmod +x "$dir/deployment/hooks/post_copy.d/10_test.sh"
        ;;
      post-systemd-d)
        mkdir -p "$dir/deployment/hooks/post_systemd.d"
        echo "touch /opt/$PROJECT_NAME/.hook_post_systemd_d" > "$dir/deployment/hooks/post_systemd.d/10_test.sh"
        chmod +x "$dir/deployment/hooks/post_systemd.d/10_test.sh"
        ;;
      env-marker)
        mkdir -p "$dir/deployment/hooks/post_copy.d"
        cat > "$dir/deployment/hooks/post_copy.d/20-env-marker.sh" <<MARKER
printf '%s' "\$DEPLOY_ENV" > "/opt/$PROJECT_NAME/.env_deploy"
printf '%s' "\$API_KEY"   > "/opt/$PROJECT_NAME/.env_api_key"
printf '%s' "\$FOO"       > "/opt/$PROJECT_NAME/.env_foo"
MARKER
        chmod +x "$dir/deployment/hooks/post_copy.d/20-env-marker.sh"
        ;;
      user-env-config)
        cat > "$dir/installer.conf" <<'CONF'
USER_ENV=("DEPLOY_ENV=should_be_overridden" "FOO=from_config")
CONF
        ;;
      user-unit)
        echo -e "[Unit]\nDescription=Demo user service\n[Service]\nExecStart=/bin/sh -c 'echo USER_SERVICE > /opt/$PROJECT_NAME/.user_service'\n[Install]\nWantedBy=default.target" > "$dir/deployment/systemd_units/user/demo-user.service"
        ;;
      system-unit)
        echo -e "[Unit]\nDescription=Demo system service\n[Service]\nExecStart=/bin/sh -c 'echo SYSTEM_SERVICE > /opt/$PROJECT_NAME/.system_service'\n[Install]\nWantedBy=multi-user.target" > "$dir/deployment/systemd_units/system/demo-system.service"
        ;;
    esac
  done
}

run_test() {
  local name="$1"
  shift
  echo "[+] Running test: $name"

  local tmpdir
  tmpdir=$(mktemp -d)
  make_project "$tmpdir" "$@"

  cid=$(docker run -d --privileged --name $CONTAINER_NAME $IMAGE)
  docker cp "$tmpdir" "$cid:/root/$PROJECT_NAME"

  # shellcheck disable=SC2086
  docker exec "$cid" bash /root/$PROJECT_NAME/install.sh --dir /opt/$PROJECT_NAME --no-enable-units ${EXTRA_INSTALL_ARGS:-} || { echo "Test $name FAILED (install error)"; docker rm -f $cid; return 1; }

  # Basic check: project files copied
  docker exec "$cid" test -f /opt/$PROJECT_NAME/hello.sh
  docker exec "$cid" test -f /opt/$PROJECT_NAME/data.txt

  # Hook checks
  [[ "$*" == *"pre-copy"* ]] && docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_pre_copy
  [[ "$*" == *"pre-copy-d"* ]] && docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_pre_copy_d
  [[ "$*" == *"post-copy"* ]] && docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_post_copy
  [[ "$*" == *"post-systemd"* ]] && docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_post_systemd
  [[ "$*" == *"post-copy-d"* ]] && docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_post_copy_d
  [[ "$*" == *"post-systemd-d"* ]] && docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_post_systemd_d

  # Env-forwarding checks
  if [[ -n "${EXPECT_DEPLOY_ENV:-}" ]]; then
    got=$(docker exec "$cid" cat /opt/$PROJECT_NAME/.env_deploy)
    [[ "$got" == "$EXPECT_DEPLOY_ENV" ]] || { echo "Test $name FAILED: DEPLOY_ENV='$got' != '$EXPECT_DEPLOY_ENV'"; docker rm -f $cid; return 1; }
  fi
  if [[ -n "${EXPECT_FOO:-}" ]]; then
    got=$(docker exec "$cid" cat /opt/$PROJECT_NAME/.env_foo)
    [[ "$got" == "$EXPECT_FOO" ]] || { echo "Test $name FAILED: FOO='$got' != '$EXPECT_FOO'"; docker rm -f $cid; return 1; }
  fi

  # Systemd checks
  if [[ "$*" == *"system-unit"* ]]; then
    docker exec "$cid" systemctl list-unit-files | grep demo-system.service
  fi
  if [[ "$*" == *"user-unit"* ]]; then
    docker exec "$cid" systemctl --user list-unit-files | grep demo-user.service || true # user services may need session
  fi

  docker rm -f "$cid"
  echo "[+] Test $name PASSED"
}
docker rm -f $CONTAINER_NAME >/dev/null 2>&1 || true

run_remote_test() {
  echo "[+] Running test: remote install"
  local tmpdir
  tmpdir=$(mktemp -d)
  echo $tmpdir
  make_project "$tmpdir" "pre-copy" "post-copy" "env-marker" "user-env-config"

  cid=$(docker run -d --privileged --name $CONTAINER_NAME $IMAGE)
  sleep 1
  #
  # Install local public key into container root
  local pubkey
    pubkey=""

      # Try to find any public key in ~/.ssh
      pubkey_file=$(find ~/.ssh/ -type f -name *.pub 2>/dev/null | tail -n 1 || true)
  # Exit if no key is found
  [ -z "$pubkey_file" ] && { echo "No SSH public key found"; exit 1; }

  pubkey=$(cat $pubkey_file)
  privkey_file="${pubkey_file%.pub}"
  echo $pubkey_file
  mkdir -p "$tmpdir/.ssh"
  echo "$pubkey" > "$tmpdir/.ssh/authorized_keys"
  docker cp "$tmpdir/.ssh/authorized_keys" "$cid:/root/.ssh/authorized_keys"
  docker exec "$cid" chmod 600 /root/.ssh/authorized_keys
  docker exec "$cid" chown root:root /root/.ssh/authorized_keys

  # Start sshd in container
  docker exec "$cid" service ssh start

  # Get container IP
  ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid")

  # Run remote install (password auth)
  # --env DEPLOY_ENV overrides USER_ENV from installer.conf (CLI wins);
  # --env API_KEY exercises shell-special characters surviving the SSH round-trip.
  (cd "$tmpdir" && SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $privkey_file" bash install.sh --remote root@$ip --dir /opt/$PROJECT_NAME --env DEPLOY_ENV=production --env "API_KEY=has spaces & \$pecial")

  # Verify inside container
  docker exec "$cid" test -f /opt/$PROJECT_NAME/hello.sh

  docker exec "$cid" test -f /opt/$PROJECT_NAME/data.txt
  docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_post_copy
  # pre-copy ran on the source machine and the artifact was rsynced over
  docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_pre_copy
  # cleanup pre-copy artifact left behind on the source machine
  rm -f "$tmpdir/.hook_pre_copy"

  # CLI --env overrode installer.conf's USER_ENV for DEPLOY_ENV
  got=$(docker exec "$cid" cat /opt/$PROJECT_NAME/.env_deploy)
  [[ "$got" == "production" ]] || { echo "Remote test FAILED: DEPLOY_ENV='$got' != 'production'"; docker rm -f $cid; return 1; }
  # FOO came only from the (forwarded) installer.conf USER_ENV
  got=$(docker exec "$cid" cat /opt/$PROJECT_NAME/.env_foo)
  [[ "$got" == "from_config" ]] || { echo "Remote test FAILED: FOO='$got' != 'from_config'"; docker rm -f $cid; return 1; }
  # API_KEY survived quoting through the SSH boundary
  got=$(docker exec "$cid" cat /opt/$PROJECT_NAME/.env_api_key)
  [[ "$got" == 'has spaces & $pecial' ]] || { echo "Remote test FAILED: API_KEY='$got'"; docker rm -f $cid; return 1; }

  docker rm -f "$cid"
  echo "[+] Remote install test PASSED"
}

### RUN ALL TESTS
run_test "no hooks or units"
run_test "default hooks" pre-copy post-copy post-systemd
run_test "hook directories" pre-copy pre-copy-d post-copy post-systemd  post-copy-d post-systemd-d
run_test "user and system units" user-unit system-unit
# Local install: --env on the CLI overrides USER_ENV from installer.conf,
# and config-only keys (FOO) flow through unchanged.
EXTRA_INSTALL_ARGS='--env DEPLOY_ENV=from_cli' \
EXPECT_DEPLOY_ENV='from_cli' EXPECT_FOO='from_config' \
  run_test "user env vars (config + CLI override)" env-marker user-env-config
run_remote_test

echo "[+] All tests finished"
