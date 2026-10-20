#!/bin/bash
# OmaBoot? build dry run, inside the sandbox (dry-run.sh): runs builder/build-iso.sh with the
# stand-ins first on PATH, then keeps what the build left behind in /harness-state.
set -uo pipefail
state=/harness-state
cp /harness/fixtures/mkarchiso /usr/bin/mkarchiso
chmod 755 /usr/bin/mkarchiso
# the runtime package fixture (dry-run.sh), packed here where bsdtar is sure to be
bsdtar --zstd --uid 0 --gid 0 --uname root --gname root -cf /tmp/dry-run-runtime.pkg.tar.zst -C /harness/fixtures/runtime usr
: >"$state/calls.log"

/builder/build-iso.sh >"$state/build.log" 2>&1
echo $? >"$state/exit"

cp /etc/pacman.conf "$state/pacman.conf.after"
cp /etc/pacman.d/mirrorlist "$state/mirrorlist.after"
cache=/var/cache/airootfs/var/cache/omarchy/mirror/offline
[[ -d $cache ]] && find "$cache" -maxdepth 1 -mindepth 1 -printf '%f %y\n' | sort >"$state/mirror.txt"
if [[ -L /var/cache/omarchy/mirror/offline ]]; then
  repo=$(readlink /var/cache/omarchy/mirror/offline)
  {
    echo "/var/cache/omarchy/mirror/offline -> $repo"
    find "$repo/" -maxdepth 1 -mindepth 1 -printf '%f %y %l\n' | sort
  } >"$state/repo.txt"
fi
find /out -mindepth 1 -printf '%P %y\n' | sort >"$state/out.txt"
if [[ -n ${HOST_STATE_OWNER:-} ]]; then
  chown -R "$HOST_STATE_OWNER" "$state" /out
fi
exit 0
