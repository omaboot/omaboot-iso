# shellcheck shell=bash disable=SC2034,SC2154 # omarchy-iso-make's variables, read and set here
#
# OmaBoot? additions to upstream's bin/omarchy-iso-make, sourced there (the line marked
# "# omaboot hook") after its docker arguments are set up and before the build cache is mounted.
# Reads and extends its DOCKER_ARGS; sets OMABOOT_CACHE_CHANNEL, the package cache the build
# mounts.

# The build's environment (builder/omaboot/build-hooks.sh reads it)
DOCKER_ARGS+=(
  -e "OMABOOT_FLAVOUR=${OMABOOT_FLAVOUR:-omarchy}"
  -e "OMABOOT_SIGNERS=${OMABOOT_SIGNERS:-dev}"
  -e "OMABOOT_COMMIT=${OMABOOT_COMMIT:-}"
  -e "OMABOOT_RELEASE=${OMABOOT_RELEASE:-}"
  -e "OMABOOT_PIN=${OMABOOT_PIN:-}"
  -e "OMABOOT_TAG=${OMABOOT_TAG:-}"
)

# OmaBoot? release builds (builder/omaboot/release/build.sh sets these): the pinned [omarchy] and
# [arch-mact2] repos made from the official ISO, a fixed build date, and a package cache of their own,
# so no package from a dev build's channel can stand in for a pinned one. (The build container's
# image: OMABOOT_BUILD_IMAGE, at the docker run line.)
OMABOOT_CACHE_CHANNEL=$OMARCHY_MIRROR
# Pinned dev builds (OMABOOT_PIN) take the same pinned repos and cache, and keep the module cache.
OMABOOT_PIN=${OMABOOT_RELEASE:-${OMABOOT_PIN:-}}
if [[ -n $OMABOOT_PIN ]]; then
  [[ -d ${OMABOOT_PINNED_REPOS:-} ]] || { echo "Error: pinned builds need OMABOOT_PINNED_REPOS (the pinned repos)" >&2; exit 1; }
  DOCKER_ARGS+=(-v "$(realpath "$OMABOOT_PINNED_REPOS"):/pinned:ro")
  [[ -n ${SOURCE_DATE_EPOCH:-} ]] && DOCKER_ARGS+=(-e "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH")
  OMABOOT_CACHE_CHANNEL=release-$OMABOOT_PIN
fi

# The patched kernel modules, kept between builds (builder/omaboot/build-modules.sh), when the
# build cache is. Not for releases: their build log has to show the stock rebuilds matching the
# shipped modules.
if [[ -z $NO_CACHE && -z ${OMABOOT_RELEASE:-} ]]; then
  OMABOOT_MODULES_CACHE_DIR="$HOME/.cache/omaboot/modules"
  mkdir -p "$OMABOOT_MODULES_CACHE_DIR"
  DOCKER_ARGS+=(-v "$OMABOOT_MODULES_CACHE_DIR:/var/cache/omaboot-modules")
fi

# The build container's own packages (archiso, git and the rest it installs before it builds),
# kept between builds on a host with no /var/cache/pacman/pkg for omarchy-iso-make to share (a
# Debian runner): the Arch archive the build date pins them to can be slow enough to fail a download, and
# a file kept once never needs it again. pacman checks each kept file against the repo's database
# as it would a downloaded one. Not for releases (they start clean), nor with --no-cache.
if [[ -z $NO_CACHE && -z ${OMABOOT_RELEASE:-} && $OMARCHY_ARCH == x86_64 && ! -d /var/cache/pacman/pkg ]]; then
  OMABOOT_TOOLS_CACHE_DIR="$HOME/.cache/omaboot/pacman-pkg"
  mkdir -p "$OMABOOT_TOOLS_CACHE_DIR"
  DOCKER_ARGS+=(-v "$OMABOOT_TOOLS_CACHE_DIR:/var/cache/pacman/pkg")
fi
