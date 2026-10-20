#!/bin/bash
#
# Runs a command from this checkout in an Arch container, as upstream's unit-test workflow runs
# test/all: on Arch, the same as the live ISO, with systemd booted (the keyboard tests ask the
# real localectl) and the tools the checks need, so a build box on another distribution (the dev
# box is Debian: no jq, no bsdtar, and its python3 ships a stdlib "test" package that shadows the
# repo's) needs only docker. The checkout is copied in (it stays as it is); OUT is the container's
# /out, handed back owned by the caller.
#
# Usage: in-arch.sh [-u USER] OUT COMMAND [ARG...]
#   -u  tester (default: an ordinary user, as test/all wants) or root (the build's dry run, whose
#       sandbox maps root)
#   COMMAND runs in the copy's top directory; OMABOOT_* and PYTHONDONTWRITEBYTECODE pass through.
# Exit: the command's.

set -euo pipefail
user=tester
while getopts u: opt; do
  case $opt in
    u) user=$OPTARG ;;
    *) sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit/p' "$0" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
(($# >= 2)) || { sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit/p' "$0" >&2; exit 2; }
out=$1
shift
mkdir -p "$out"
out=$(realpath "$out")
top=$(git rev-parse --show-toplevel)
docker=(docker)
docker version >/dev/null 2>&1 || docker=(sudo -n docker)
name=omaboot-in-arch-$$
env_args=()
while IFS= read -r kv; do env_args+=(-e "$kv"); done < <(env | grep -E '^(OMABOOT_[A-Z_]*|PYTHONDONTWRITEBYTECODE|LC_ALL)=' || true)

"${docker[@]}" run -d --name "$name" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp:exec \
  -v "$top:/src:ro" -v "$out:/out" ghcr.io/archlinux/archlinux:latest bash -c '
    systemctl mask getty.target console-getty.service systemd-udev-trigger.service \
      systemd-udevd.service systemd-vconsole-setup.service >/dev/null 2>&1
    exec /usr/lib/systemd/systemd' >/dev/null
trap '"${docker[@]}" rm -f "$name" >/dev/null 2>&1 || true' EXIT
set +e
"${docker[@]}" exec "${env_args[@]}" -e "RUN_AS=$user" -e "HOST_IDS=$(id -u):$(id -g)" "$name" bash -euo pipefail -c '
  for i in $(seq 1 60); do
    state=$(systemctl is-system-running 2>/dev/null || true)
    case $state in running | degraded) break ;; esac
    sleep 1
  done
  # Omarchy'"'"'s own Arch mirror first, and three tries, as upstream'"'"'s workflow has it
  sed -i "1i Server = https://mirror.omarchy.org/\$repo/os/\$arch" /etc/pacman.d/mirrorlist
  for attempt in 1 2 3; do
    pacman -Syu --noconfirm --needed python parted diffutils jq zip unzip openssh patch git \
      bubblewrap libarchive squashfs-tools mtools >/dev/null && break
    [ "$attempt" -lt 3 ] || { echo "in-arch: the container could not install its tools" >&2; exit 1; }
    sleep 15
  done
  useradd -m -d /work tester && chmod 755 /work # (readable by all: the dry run sandbox maps root only)
  cp -r /src /work/src
  chown -R tester /work/src /out
  cd /work/src
  status=0
  if [ "$RUN_AS" = root ]; then
    git config --global --add safe.directory /work/src
    "$@" || status=$?
  else
    setpriv --reuid=tester --regid=tester --init-groups env HOME=/work "$@" || status=$?
  fi
  chown -R "$HOST_IDS" /out
  exit $status' in-arch "$@"
status=$?
set -e
exit "$status"
