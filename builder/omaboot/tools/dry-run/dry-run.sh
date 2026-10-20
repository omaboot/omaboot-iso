#!/bin/bash
#
# OmaBoot? build dry run: runs builder/build-iso.sh the way bin/omarchy-iso-make does, in a sandbox
# with no network, where the package and download tools are stand-ins (stand-in.sh) and mkarchiso
# only keeps what it was handed. What comes out is everything the build decides before mkarchiso:
# the archiso profile (grub.cfg, profiledef.sh, the airootfs additions), the patched mkarchiso, the
# pacman configs, every package list the build asks for, the mirror it indexes, and the checks it
# runs after mkarchiso. Two runs on two trees, compared, show whether a change to the build keeps
# the image the same; the weekly upstream watch runs it on upstream plus our changes.
#
# What it can't show: anything the real packages, archiso or the kernel modules decide (no
# packages are downloaded, build-modules.sh and check-live-image.sh are stand-ins, mkarchiso is a
# stand-in holding only the lines build-iso.sh patches after). A real build covers those.
#
# Usage: dry-run.sh [-b bwrap|docker] [-t] [-a ARCHISO] TREE OUT [VAR=VALUE...]
#   -b       the sandbox: bwrap (default when installed) or docker (the cached build image,
#            ghcr.io's or Docker Hub's archlinux:latest, never pulled; needs docker or sudo docker)
#   -t       put a stand-in boot-live in builder/omaboot/bootlive, as the dev workflow does
#   -a       the archiso checkout the build seeds its profile from (default: TREE/archiso, the
#            submodule; it must be checked out)
#   TREE     the omarchy-iso checkout to run (builder/, configs/, archiso/ are read from it)
#   OUT      a new directory for the results
#   VAR=VALUE  the build's environment, as omarchy-iso-make passes it (OMABOOT_FLAVOUR=live,
#            OMABOOT_PIN=4.0.4, OMARCHY_MIRROR=edge, ...)
#
# Results in OUT/state: exit (the build script's status), build.log, calls.log (each stand-in
# call), profile/ (the archiso profile mkarchiso got, without its package mirror), profile.txt
# (profiledef.sh's settings, sorted), mkarchiso (as patched), pacman.conf and mirrorlist (the
# build container's), confs/ (each pacman config a call used, by checksum), mirror.txt (the
# offline mirror cache after the build), repo.txt (the repo mkarchiso installs from), out/.
# Exits with the build script's status.

set -euo pipefail

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/^$/p' "$0" >&2
  exit 2
}

backend=
bootlive=
archiso=
while getopts b:ta: opt; do
  case $opt in
    b) backend=$OPTARG ;;
    t) bootlive=1 ;;
    a) archiso=$OPTARG ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
(( $# >= 2 )) || usage
tree=$(realpath "$1")
out=$2
shift 2
archiso=$(realpath "${archiso:-$tree/archiso}")
[[ -d $archiso/configs/releng ]] || { echo "dry run: no archiso checkout at $archiso (git submodule update --init)" >&2; exit 2; }
[[ ! -e $out ]] || { echo "dry run: $out exists; give a new directory" >&2; exit 2; }
for kv in "$@"; do
  [[ $kv == [A-Z_]*=* ]] || { echo "dry run: not VAR=VALUE: $kv" >&2; exit 2; }
done
if [[ -z $backend ]]; then
  if command -v bwrap >/dev/null; then backend=bwrap; else backend=docker; fi
fi

here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
out=$(realpath "$out")
stage=$out/stage
state=$out/state
mkdir -p "$stage/stubs" "$stage/fixtures" "$stage/pinned/omarchy" "$stage/pinned/arch-mact2" "$stage/pinned/arch-held" \
  "$state/confs" "$state/out" "$state/tmp" "$state/var-cache"

# The tree's build files, as the container sees them (read-only there), with the stand-ins for the
# steps that need real packages. builder/omaboot/bootlive (the workflow's copy of the tester) is
# left out: -t puts a stand-in there.
tar -C "$tree" --exclude=./builder/omaboot/bootlive -cf - ./builder ./configs | tar -C "$stage" -xf -
install -m 755 "$here/stand-in.sh" "$stage/stubs/stand-in"
for tool in pacman pacman-key curl repo-add grub-mkfont cc mkarchiso date; do
  ln -s stand-in "$stage/stubs/$tool"
done
install -m 755 "$here/stand-in.sh" "$stage/builder/omaboot/build-modules.sh"
install -m 755 "$here/stand-in.sh" "$stage/builder/omaboot/live/check-live-image.sh"
install -m 755 "$here/entry.sh" "$stage/entry.sh"
if [[ -n $bootlive ]]; then
  mkdir -p "$stage/builder/omaboot/bootlive/fonts"
  printf '#!/bin/sh\necho "boot-live 0.0.0 dry run"\n' >"$stage/builder/omaboot/bootlive/boot-live"
  chmod 755 "$stage/builder/omaboot/bootlive/boot-live"
  echo font | gzip -n >"$stage/builder/omaboot/bootlive/fonts/omaboot-dry-run.psf.gz"
  echo 'target=dry-run' >"$stage/builder/omaboot/bootlive/target.conf"
  echo 'int main(void) { return 0; }' >"$stage/builder/omaboot/bootlive/egl-probe.c"
fi

# mkarchiso's lines that build-iso.sh patches after (the real one comes with archiso in the container)
cat >"$stage/fixtures/mkarchiso" <<'EOF'
#!/bin/bash
# dry run: the lines of archiso's mkarchiso that builder/build-iso.sh patches after
_make_efibootimg() {
    mcopy -s -i "${efibootimg}" "${efiboot_files[@]}" '::/'
}
_prepare_airootfs_image() {
    _mkchecksum
}
EOF
# A runtime package with the package lists and setup form the build reads out of it: enough names
# that the install count lands in its expected range, and the renamed packages it maps.
fixture_pkg=$stage/fixtures/runtime
mkdir -p "$fixture_pkg/usr/share/omarchy/install/provisioning"
{
  echo '# dry run'
  for i in $(seq -w 1 640); do echo "dry-run-base-$i"; done
  echo git
} >"$fixture_pkg/usr/share/omarchy/install/omarchy-base.packages"
printf '%s\n' '# dry run' broadcom-wl apple-bcm-firmware dry-run-other >"$fixture_pkg/usr/share/omarchy/install/omarchy-other.packages"
echo '# dry run setup form' >"$fixture_pkg/usr/share/omarchy/install/provisioning/setup-form.sh"
find "$fixture_pkg" -exec touch -h -d '2026-01-01 00:00:00 UTC' {} +
# (packed into a package inside the sandbox, entry.sh: the host may have no bsdtar)
# A clean container's pacman.conf and mirrorlist (no [omarchy] repo yet)
printf '[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n' >"$state/pacman.conf"
# shellcheck disable=SC2016 # pacman's variables
printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' >"$state/mirrorlist"
# pinned builds only check the pinned repos are there
for repo in omarchy arch-mact2 arch-held; do
  echo "dry run" >"$stage/pinned/$repo/$repo.db.tar.gz"
done

env_args=()
case $backend in
  bwrap)
    # /usr/bin as links to the host's, so the build can install its patched mkarchiso there
    mkdir -p "$stage/usr-bin"
    for f in /usr/bin/*; do ln -s "/host-usr-bin/${f##*/}" "$stage/usr-bin/${f##*/}"; done
    for kv in "$@"; do env_args+=(--setenv "${kv%%=*}" "${kv#*=}"); done
    # the host's /etc, but for pacman's config: files of the sandbox's own, which the build may
    # replace (not mount points)
    etc_args=()
    for f in /etc/*; do
      case ${f##*/} in pacman.conf | pacman.d) continue ;; esac
      etc_args+=(--ro-bind-try "$f" "$f")
    done
    set +e
    # (fd 5: the kernel's security modules as a build box has them; upstream's build looks for
    # Landlock there, and without it writes a pacman wrapper to /usr/local/bin)
    bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --cap-add CAP_SYS_ADMIN \
      --ro-bind /usr /usr --ro-bind /usr/bin /host-usr-bin --bind "$stage/usr-bin" /usr/bin \
      --symlink usr/bin /bin --symlink usr/bin /sbin --symlink usr/lib /lib --symlink usr/lib /lib64 \
      --tmpfs /etc "${etc_args[@]}" --dir /etc/pacman.d \
      --file 3 /etc/pacman.conf --file 4 /etc/pacman.d/mirrorlist \
      --file 5 /sys/kernel/security/lsm \
      --proc /proc --dev /dev --dir /root \
      --bind "$state/tmp" /tmp --bind "$state/var-cache" /var/cache --bind "$state/out" /out \
      --ro-bind "$stage/builder" /builder --ro-bind "$stage/configs" /configs \
      --ro-bind "$archiso" /archiso --ro-bind "$stage/pinned" /pinned \
      --ro-bind "$stage" /harness --bind "$state" /harness-state \
      --clearenv --setenv PATH /harness/stubs:/usr/bin --setenv HOME /root --setenv LANG C.UTF-8 \
      "${env_args[@]}" /usr/bin/bash /harness/entry.sh 3<"$state/pacman.conf" 4<"$state/mirrorlist" 5<<<"landlock"
    rc=$?
    set -e
    ;;
  docker)
    docker=(docker)
    docker version >/dev/null 2>&1 || docker=(sudo docker)
    for kv in "$@"; do env_args+=(-e "$kv"); done
    # the build's own Arch image, as cached (upstream's builds pull it from ghcr.io since 4.0.6)
    image=
    for i in ghcr.io/archlinux/archlinux:latest archlinux/archlinux:latest; do
      if "${docker[@]}" image inspect "$i" >/dev/null 2>&1; then image=$i && break; fi
    done
    [[ -n $image ]] || { echo "dry run: no cached Arch image (ghcr.io/archlinux/archlinux:latest); it's never pulled" >&2; exit 125; }
    # The container gets its own pacman.conf and mirrorlist from the image; ours stay unused.
    set +e
    "${docker[@]}" run --rm --privileged --network none --pull never \
      -e PATH=/harness/stubs:/usr/bin -e HOST_STATE_OWNER="$(id -u):$(id -g)" "${env_args[@]}" \
      -v "$state/out:/out" -v "$stage/builder:/builder:ro" -v "$stage/configs:/configs:ro" \
      -v "$archiso:/archiso:ro" -v "$stage/pinned:/pinned:ro" \
      -v "$stage:/harness:ro" -v "$state:/harness-state" \
      "$image" /usr/bin/bash /harness/entry.sh
    rc=$?
    set -e
    ;;
  *) usage ;;
esac
echo "dry run: build script exit $(cat "$state/exit" 2>/dev/null || echo "? (sandbox exit $rc)"); results in $state"
exit "$(cat "$state/exit" 2>/dev/null || echo 125)"
