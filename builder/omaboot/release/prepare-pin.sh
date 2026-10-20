#!/bin/bash
# The official Omarchy ISO of a release pin, downloaded at most once into CACHE and checked against
# the pin, and what's made from it once per pin and tool version: the pinned [omarchy] and
# [arch-mact2] repos, its inventory (for the difference report) and its signature check. Prints the
# folder that holds them (pinned/, inventory/, signature.txt) on its last line; progress goes to
# stderr. Release builds (build.sh) and pinned dev builds (.forgejo/workflows/build-iso.yml) use it.
#
#   builder/omaboot/release/prepare-pin.sh VERSION CACHE      e.g. 4.0.4 /somewhere/official
set -euo pipefail
version=${1:?usage: prepare-pin.sh VERSION CACHE} cache=${2:?usage: prepare-pin.sh VERSION CACHE}
root=$(cd "$(dirname "$0")/../../.." && pwd)
rel=$root/builder/omaboot/release
pin=$rel/pins/$version
[[ -f $pin/pin.env ]] || { echo "prepare-pin: no pin for Omarchy $version ($pin)" >&2; exit 1; }
# shellcheck disable=SC1091
source "$pin/pin.env"
step() { echo >&2; echo "== $(date -u +%T) $*" >&2; }
DOCKER=(docker)
docker version &>/dev/null || DOCKER=(sudo docker)
tools_setup='echo "Server = https://archive.archlinux.org/repos/'"$BUILD_ARCHIVE_DATE"'/\$repo/os/\$arch" >/etc/pacman.d/mirrorlist &&
  pacman-key --init >/dev/null 2>&1 && pacman-key --populate archlinux >/dev/null 2>&1 &&
  pacman --noconfirm -Syyuu --needed python squashfs-tools mtools gnupg >/dev/null'
tools() { "${DOCKER[@]}" run --rm -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" "$@"; }
{
# 1. The official ISO, downloaded at most once into the cache and checked against the pin.
official_name=${OFFICIAL_ISO_URL##*/}
official=$cache/$official_name
mkdir -p "$cache"
if [[ ! -f $official ]]; then
  step "downloading the official ISO (once; kept in $cache)"
  curl -fL --retry 3 --retry-delay 10 -C - -o "$official.part" "$OFFICIAL_ISO_URL"
  echo "$OFFICIAL_ISO_SHA256  $official.part" | sha256sum -c -
  mv "$official.part" "$official"
fi
[[ -f $official.sig ]] || curl -fsS -o "$official.sig" "$OFFICIAL_ISO_URL.sig" || echo "no signature published for the official ISO"
step "checking the official ISO"
echo "$OFFICIAL_ISO_SHA256  $official" | sha256sum -c -

# 2. From it, once per pin and tool version: the pinned [omarchy] and [arch-mact2] repos, its
# inventory (for the difference report), and its signature check.
key=$(cat "$rel/omaboot_release.py" "$pin/official-packages.tsv" | sha256sum | cut -c1-12)
prep_name=$OMARCHY_VERSION-$key
prep=$cache/$prep_name
if [[ -f $prep/done ]]; then
  step "pinned repos and official inventory: cached ($prep)"
else
  step "pinned repos and official inventory from the official ISO"
  tmp_name=$prep_name.tmp-$(date +%s)
  tools -v "$cache:/cache" -v "$root/builder:/builder:ro" "$BUILD_IMAGE" bash -c "set -euo pipefail; $tools_setup
    python3 -I /builder/omaboot/release/omaboot_release.py pinned-repo /cache/$official_name /builder/omaboot/release/pins/$version /cache/$tmp_name/pinned
    python3 -I /builder/omaboot/release/omaboot_release.py inventory /cache/$official_name /cache/$tmp_name/inventory
    export GNUPGHOME=/tmp/gnupg && mkdir -m 700 \$GNUPGHOME && gpg --batch -q --import /builder/omarchy.gpg
    if [ -f /cache/$official_name.sig ]; then
      if out=\$(gpg --batch --status-fd 1 --verify /cache/$official_name.sig /cache/$official_name 2>/dev/null); then
        echo \"good signature by \$(echo \"\$out\" | awk '/GOODSIG/ { \$1 = \$2 = \"\"; sub(/^ +/, \"\"); print; exit }') (key \$(echo \"\$out\" | awk '/VALIDSIG/ { print \$3; exit }'))\" >/cache/$tmp_name/signature.txt
      else
        echo \"not verified: \$(echo \"\$out\" | awk '/ERRSIG|BADSIG|NO_PUBKEY/ { print; exit }')\" >/cache/$tmp_name/signature.txt
      fi
    else
      echo 'no signature published' >/cache/$tmp_name/signature.txt
    fi
    chown -R \$HOST_UID:\$HOST_GID /cache/$tmp_name 2>/dev/null || true"
  touch "$cache/$tmp_name/done"
  mv "$cache/$tmp_name" "$prep"
fi
} >&2
echo "$prep"
