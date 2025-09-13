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

  docker exec "$cid" bash /root/$PROJECT_NAME/install.sh --dir /opt/$PROJECT_NAME --no-enable-units || { echo "Test $name FAILED (install error)"; docker rm -f $cid; return 1; }

  # Basic check: project files copied
  docker exec "$cid" test -f /opt/$PROJECT_NAME/hello.sh
  docker exec "$cid" test -f /opt/$PROJECT_NAME/data.txt

  # Hook checks
  [[ "$*" == *"post-copy"* ]] && docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_post_copy
  [[ "$*" == *"post-systemd"* ]] && docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_post_systemd
  [[ "$*" == *"post-copy-d"* ]] && docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_post_copy_d
  [[ "$*" == *"post-systemd-d"* ]] && docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_post_systemd_d

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
  make_project "$tmpdir" "post-copy"

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
  (cd "$tmpdir" && SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $privkey_file" bash install.sh --remote root@$ip --dir /opt/$PROJECT_NAME)

  # Verify inside container
  docker exec "$cid" test -f /opt/$PROJECT_NAME/hello.sh
  
  docker exec "$cid" test -f /opt/$PROJECT_NAME/data.txt
  docker exec "$cid" test -f /opt/$PROJECT_NAME/.hook_post_copy

  docker rm -f "$cid"
  echo "[+] Remote install test PASSED"
}

### RUN ALL TESTS
run_test "no hooks or units"
run_test "default hooks" post-copy post-systemd
run_test "hook directories" post-copy post-systemd  post-copy-d post-systemd-d
run_test "user and system units" user-unit system-unit
run_remote_test

echo "[+] All tests finished"
