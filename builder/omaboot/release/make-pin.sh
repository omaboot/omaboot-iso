#!/bin/bash
# A release pin for a new Omarchy release, on the build box (README "A new Omarchy release", steps
# 1 and 3): the official ISO, downloaded at most once into CACHE (kept there) and checked against
# its published .sha256 and its signature; the omarchy-iso commit it was built from (the last
# first-parent commit of UPSTREAM, already fetched, before the ISO's Last-Modified time); the Arch
# build image of that day (Docker Hub's newest archlinux base-* image published before it, by
# digest); then omaboot_release.py pin, run in that image, so the box needs nothing but docker.
# Writes OUT/pin.env and OUT/official-packages.tsv; progress goes to stderr, and the last line
# printed is the base commit. The release watch (builder/omaboot/tools/release-watch.sh) and the
# make-pin workflow (.forgejo/workflows/make-pin.yml) use it.
#
#   builder/omaboot/release/make-pin.sh VERSION CACHE UPSTREAM OUT
#     e.g. 4.0.7 ~/official-isos refs/remotes/upstream/quattro /tmp/pin-4.0.7
#
# Any of these, when set, is taken as it is instead of being worked out: OMABOOT_PIN_BASE (the
# commit), OMABOOT_PIN_IMAGE (archlinux/archlinux:base-…@sha256:…), OMABOOT_PIN_DATE (YYYY/MM/DD,
# the build container's archive day). Extra arguments for the pin (--repo NAME=REPO, for a package
# no repo serves any more) go in OMABOOT_PIN_ARGS.
set -euo pipefail
usage() { echo "usage: make-pin.sh VERSION CACHE UPSTREAM OUT" >&2; exit 2; }
(($# == 4)) || usage
version=$1 cache=$2 upstream=$3 out=$4
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "make-pin: '$version' isn't a release version (X.Y.Z)" >&2; exit 2; }
root=$(cd "$(dirname "$0")/../../.." && pwd)
step() { echo >&2; echo "== $(date -u +%T) $*" >&2; }
DOCKER=(docker)
docker version &>/dev/null || DOCKER=(sudo -n docker)

# 1. The official ISO: its checksum and publishing time from iso.omarchy.org, the file once.
name=omarchy-$version.iso
url=https://iso.omarchy.org/$name
sha=$(curl -fsS "$url.sha256" | awk '{ print $1 }')
[[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "make-pin: no checksum at $url.sha256" >&2; exit 1; }
modified=$(curl -fsSI "$url" | tr -d '\r' | awk 'tolower($1) == "last-modified:" { $1 = ""; sub(/^ /, ""); print }')
[[ -n $modified ]] || { echo "make-pin: $url has no Last-Modified time" >&2; exit 1; }
published=$(date -u -d "$modified" +%FT%TZ)
step "Omarchy $version: $url, published $published"
mkdir -p "$cache"
if [[ ! -f $cache/$name ]]; then
  step "downloading the official ISO (once; kept in $cache)"
  curl -fL --retry 3 --retry-delay 10 -C - -o "$cache/$name.part" "$url" >&2
  echo "$sha  $cache/$name.part" | sha256sum -c - >&2
  mv "$cache/$name.part" "$cache/$name"
fi
[[ -f $cache/$name.sig ]] || curl -fsS -o "$cache/$name.sig" "$url.sig"
echo "$sha  $cache/$name" | sha256sum -c - >&2

# 2. What it was built from: the omarchy-iso commit and the Arch image of its day.
base=${OMABOOT_PIN_BASE:-$(git -C "$root" log --first-parent -1 --format=%H --until="$published" "$upstream")}
[[ -n $base ]] || { echo "make-pin: no commit of $upstream before $published" >&2; exit 1; }
base=$(git -C "$root" rev-parse "$base^{commit}")
step "omarchy-iso commit: $(git -C "$root" log -1 --format='%h %cI %s' "$base")"
image=${OMABOOT_PIN_IMAGE:-}
if [[ -z $image ]]; then
  months="$(date -u -d "$published" +%Y%m) $(date -u -d "$(date -u -d "$published" +%Y-%m-01) -1 day" +%Y%m)"
  image=$(for m in $months; do
    curl -fsS "https://hub.docker.com/v2/repositories/archlinux/archlinux/tags?page_size=100&name=base-$m"
    echo
  done | python3 -I -c '
import json, sys
before = sys.argv[1]
tags = [t for line in sys.stdin if line.strip() for t in json.loads(line)["results"]]
tags = [t for t in tags if t["name"].startswith("base-2") and t.get("digest") and t["last_updated"][:19] <= before[:19]]
if tags:
    t = max(tags, key=lambda t: t["last_updated"])
    print("archlinux/archlinux:%s@%s" % (t["name"], t["digest"]))
' "$published")
  [[ -n $image ]] || { echo "make-pin: no archlinux base image published before $published" >&2; exit 1; }
fi
day=${OMABOOT_PIN_DATE:-$(date -u -d "$published" +%Y/%m/%d)}
step "build image: $image, archive day $day"

# 3. The pin, in that image: tools from its archive day, the ISO's signature checked first.
mkdir -p "$out" "$cache/pin-cache"
# shellcheck disable=SC2086 # OMABOOT_PIN_ARGS is a list of arguments
"${DOCKER[@]}" run --rm -e "HOST_IDS=$(id -u):$(id -g)" -v "$cache:/cache" -v "$root/builder:/builder:ro" -v "$out:/out" "$image" \
  bash -c 'set -euo pipefail
  echo "Server = https://archive.archlinux.org/repos/'"$day"'/\$repo/os/\$arch" >/etc/pacman.d/mirrorlist
  pacman-key --init >/dev/null 2>&1 && pacman-key --populate archlinux >/dev/null 2>&1
  pacman --noconfirm -Syyuu --needed python squashfs-tools mtools gnupg >/dev/null
  export GNUPGHOME=/tmp/gnupg && mkdir -m 700 $GNUPGHOME && gpg --batch -q --import /builder/omarchy.gpg
  gpg --batch --verify /cache/'"$name"'.sig /cache/'"$name"'
  python3 -I /builder/omaboot/release/omaboot_release.py pin /cache/'"$name"' --version '"$version"' \
    --iso-url '"$url"' --base-commit '"$base"' --build-image '"$image"' --build-date '"$day"' \
    --out /out --cache /cache/pin-cache '"${OMABOOT_PIN_ARGS:-}"'
  for d in /out /cache/pin-cache; do chown -R "$HOST_IDS" "$d" 2>/dev/null || true; done # (a share keeps its own owner)' >&2
echo "$base"
