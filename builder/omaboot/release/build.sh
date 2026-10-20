#!/bin/bash
# OmaBoot? release build: the live image pinned to the official Omarchy ISO of its release, the QEMU
# smoke tests (nothing is submitted anywhere), and the files a release ships next to the ISO. The
# same steps on GitHub (.github/workflows/release.yml) and on the private runner
# (.forgejo/workflows/release-dryrun.yml). See README.md next to this file.
#
#   OMABOOT_TAG=v4.0.4-1 OUT=/somewhere/empty OMABOOT_OFFICIAL_CACHE=/somewhere builder/omaboot/release/build.sh
#
# Environment:
#   OMABOOT_TAG             release name (the git tag; dry runs: dryrun-<n>)
#   OUT                     output folder (new or empty)
#   OMABOOT_OFFICIAL_CACHE  where the official ISO is downloaded to once and kept, with what's made from it
#   BOOT_LIVE_ALLOW_BRANCH  dry runs only (no report target): BOOT_LIVE_TAG may name a branch, and
#                           boot-live's version reads dryrun-<branch> (GitHub's dry run, before
#                           boot-live has a release tag)
#   BOOT_LIVE_TAG, BOOT_LIVE_REPO   override release.env (dry runs on the private runner); the repo
#                           may also be a local path, e.g. a git bundle of it
#   BOOT_LIVE_AUTH          token for cloning a private boot-live repo over HTTP (dry runs only)
#   OMABOOT_REPORT_URL, OMABOOT_REPORT_KEY   where the image sends reports (target.conf); both or neither.
#                           Neither: the image saves reports to the stick only.
#   OMABOOT_REQUIRE_TARGET=1  fail without them (real releases)
#   OMABOOT_WATCH_URL       the bootwatchd the Wi-Fi and Ethernet tests move their data through
#                           (target.conf watch=; default https://boot.watch, the production one)
#   OMABOOT_BUG_KEY         the bug report upload key (target.conf bugkey=; PF-13); without it the
#                           image keeps bug reports on the stick only
#   OMABOOT_BUG_URL         the bootwatchd bug reports go to (target.conf bugs=; default https://boot.watch)
#
# Writes to OUT: omaboot-live-<tag>.iso, packages.tsv, diff-report.md/.tsv.gz, smoke-summary.txt,
# boot-live.txt, build-info.json, build.log, SHA256SUMS (all of those), release-notes.md (the draft
# release's text); and, not published: smoke/ (screenshots, serial logs), inventory/.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
rel=$root/builder/omaboot/release
die() { echo "release build: $*" >&2; exit 1; }
: "${OMABOOT_TAG:?set OMABOOT_TAG}" "${OUT:?set OUT}" "${OMABOOT_OFFICIAL_CACHE:?set OMABOOT_OFFICIAL_CACHE}"
[[ $OMABOOT_TAG =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "OMABOOT_TAG '$OMABOOT_TAG': letters, digits, . _ - only"

# Everything below goes to OUT/build.log as well; the checksums are made once the log is complete.
if [[ -z ${_OMABOOT_RELEASE_LOGGED:-} ]]; then
  [[ ! -e $OUT || -z $(ls -A "$OUT") ]] || die "$OUT isn't empty"
  mkdir -p "$OUT"
  set +e
  _OMABOOT_RELEASE_LOGGED=1 "$0" "$@" 2>&1 | tee "$OUT/build.log"
  status=${PIPESTATUS[0]}
  set -e
  files=()
  for f in "$OUT"/omaboot-live-*.iso packages.tsv diff-report.md diff-report.tsv.gz smoke-summary.txt boot-live.txt build-info.json build.log; do
    f=${f##*/}
    [[ -f $OUT/$f ]] && files+=("$f")
  done
  (cd "$OUT" && sha256sum "${files[@]}" >SHA256SUMS)
  echo "SHA256SUMS: ${#files[@]} files"
  exit "$status"
fi

cd "$root"
override_tag=${BOOT_LIVE_TAG:-} override_repo=${BOOT_LIVE_REPO:-}
# shellcheck disable=SC1091
source "$rel/release.env"
BOOT_LIVE_TAG=${override_tag:-$BOOT_LIVE_TAG}
BOOT_LIVE_REPO=${override_repo:-$BOOT_LIVE_REPO}
pin=$rel/pins/$OMABOOT_RELEASE
[[ -f $pin/pin.env ]] || die "no pin for Omarchy $OMABOOT_RELEASE ($pin)"
# shellcheck disable=SC1091
source "$pin/pin.env"
git cat-file -e "$OFFICIAL_ISO_COMMIT^{commit}" 2>/dev/null ||
  die "the official ISO's omarchy-iso commit $OFFICIAL_ISO_COMMIT isn't in this checkout's history (fetch-depth: 0)"
git merge-base --is-ancestor "$OFFICIAL_ISO_COMMIT" HEAD || die "this commit isn't based on the official ISO's commit $OFFICIAL_ISO_COMMIT"
iso_name=omaboot-live-${OMABOOT_TAG#v}.iso
failures=()
started=$(date +%s)
step() { echo; echo "== $(date -u +%T) $*"; }

if [[ -n ${OMABOOT_REPORT_URL:-} || -n ${OMABOOT_REPORT_KEY:-} ]]; then
  [[ -n ${OMABOOT_REPORT_URL:-} && -n ${OMABOOT_REPORT_KEY:-} ]] || die "OMABOOT_REPORT_URL and OMABOOT_REPORT_KEY go together"
  target="${OMABOOT_REPORT_URL}"
elif [[ ${OMABOOT_REQUIRE_TARGET:-} == 1 ]]; then
  die "a release needs OMABOOT_REPORT_URL and OMABOOT_REPORT_KEY"
else
  target="none (dry run: the image saves reports to the stick only)"
fi

DOCKER=(docker)
docker version &>/dev/null || DOCKER=(sudo docker)
# Tools in the release's own build image, from the archive day of the official ISO's build: python,
# squashfs-tools, mtools, gnupg. Each call is a fresh container (its /tmp goes with it).
tools_setup='echo "Server = https://archive.archlinux.org/repos/'"$BUILD_ARCHIVE_DATE"'/\$repo/os/\$arch" >/etc/pacman.d/mirrorlist &&
  pacman-key --init >/dev/null 2>&1 && pacman-key --populate archlinux >/dev/null 2>&1 &&
  pacman --noconfirm -Syyuu --needed python squashfs-tools mtools gnupg >/dev/null'
tools() { "${DOCKER[@]}" run --rm -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" "$@"; }

step "OmaBoot? Live $OMABOOT_TAG: Omarchy $OMARCHY_VERSION, boot-live $BOOT_LIVE_TAG, fork $(git rev-parse --short=7 HEAD)"
echo "official ISO: $OFFICIAL_ISO_URL (omarchy-iso $OFFICIAL_ISO_COMMIT)"
echo "Arch packages: archive.archlinux.org/repos/$ARCH_ARCHIVE_DATE; build tools: $BUILD_ARCHIVE_DATE; image $BUILD_IMAGE"
echo "report target: $target"

# 1–2. The official ISO (downloaded at most once into the cache, checked against the pin) and, from it,
# the pinned [omarchy] and [arch-mact2] repos, its inventory and its signature check (prepare-pin.sh).
prep=$("$rel/prepare-pin.sh" "$OMABOOT_RELEASE" "$OMABOOT_OFFICIAL_CACHE")
official_signature=$(cat "$prep/signature.txt")
echo "official ISO signature: $official_signature"

# 3. boot-live from its tag, in a pinned Go image; target.conf from the environment.
step "boot-live $BOOT_LIVE_TAG from $BOOT_LIVE_REPO"
stage=$root/builder/omaboot/bootlive
[[ ! -e $stage ]] || die "$stage exists: release builds start from a clean checkout"
mkdir -p "$stage/fonts"
repo_mount=() bl_source=$BOOT_LIVE_REPO
if [[ -e $BOOT_LIVE_REPO ]]; then # a local clone or bundle
  repo_mount=(-v "$(realpath "$BOOT_LIVE_REPO"):/src-repo:ro")
  bl_source=/src-repo
fi
[[ -z ${BOOT_LIVE_ALLOW_BRANCH:-} || -z ${OMABOOT_REPORT_KEY:-} ]] || die "a build with a report target takes boot-live from a tag (BOOT_LIVE_ALLOW_BRANCH is for dry runs)"
BL_REPO=$BOOT_LIVE_REPO BL_SOURCE=$bl_source BL_TAG=$BOOT_LIVE_TAG BL_AUTH=${BOOT_LIVE_AUTH:-} BL_OMARCHY=$OMARCHY_VERSION BL_ALLOW_BRANCH=${BOOT_LIVE_ALLOW_BRANCH:-} \
  "${DOCKER[@]}" run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e GOTOOLCHAIN=local -e GOFLAGS=-mod=readonly \
  -e BL_REPO -e BL_SOURCE -e BL_TAG -e BL_AUTH -e BL_OMARCHY -e BL_ALLOW_BRANCH -e BL_IMAGE="$BOOT_LIVE_GO_IMAGE" \
  "${repo_mount[@]}" -v "$stage:/stage" -v "$OUT:/out" "$BOOT_LIVE_GO_IMAGE" bash -c '
  set -euo pipefail
  opts=(-c advice.detachedHead=false)
  [[ -n $BL_AUTH ]] && opts+=(-c "http.extraHeader=Authorization: token $BL_AUTH")
  depth=(--depth 1)
  [[ $BL_SOURCE == /src-repo ]] && depth=()
  git "${opts[@]}" clone -q "${depth[@]}" --branch "$BL_TAG" "$BL_SOURCE" /tmp/src
  cd /tmp/src
  version=${BL_TAG#v}
  if [[ $(git describe --tags --exact-match 2>/dev/null) != "$BL_TAG" ]]; then
    [[ -n $BL_ALLOW_BRANCH ]] || { echo "boot-live: $BL_TAG is not a tag" >&2; exit 1; }
    version=dryrun-$BL_TAG
  fi
  commit=$(git rev-parse HEAD)
  make -s build VERSION="$version" COMMIT="${commit:0:7}" OMARCHY="$BL_OMARCHY"
  cp dist/boot-live helpers/egl-probe/egl-probe.c /stage/
  cp assets/fonts/*.psf.gz /stage/fonts/
  { echo "repo=$BL_REPO"; echo "tag=$BL_TAG"; echo "commit=$commit"; echo "go_image=$BL_IMAGE"; echo "go=$(go version)"; } >/out/boot-live.txt'
# target.conf always names the bootwatchd (production unless OMABOOT_WATCH_URL says otherwise); the
# report target and its key only when given.
watch_url=${OMABOOT_WATCH_URL:-https://boot.watch}
[[ $watch_url =~ ^https?://[A-Za-z0-9.:-]+/?$ ]] || die "OMABOOT_WATCH_URL '$watch_url': a plain http(s)://host[:port]"
(
  umask 077
  if [[ -n ${OMABOOT_REPORT_URL:-} ]]; then
    printf 'url=%s\nkey=%s\n' "$OMABOOT_REPORT_URL" "$OMABOOT_REPORT_KEY"
  fi
  printf 'watch=%s\n' "$watch_url"
  if [[ -n ${OMABOOT_BUG_KEY:-} ]]; then
    printf 'bugs=%s\nbugkey=%s\n' "${OMABOOT_BUG_URL:-https://boot.watch}" "$OMABOOT_BUG_KEY"
  fi
) >"$stage/target.conf"
{
  echo "sha256=$(sha256sum "$stage/boot-live" | cut -d' ' -f1)"
  echo "version=$("$stage/boot-live" --version 2>&1 | head -n1)"
  echo "target=${OMABOOT_REPORT_URL:-none}"
  echo "watch=$watch_url"
  echo "bugs=${OMABOOT_BUG_KEY:+${OMABOOT_BUG_URL:-https://boot.watch}}"
} >>"$OUT/boot-live.txt"
cat "$OUT/boot-live.txt"

# 4. The image: live edition, release keys only, every package pinned (builder/build-iso.sh).
step "building the image"
[[ ! -e $root/release ]] || [[ -z $(ls -A "$root/release") ]] || die "$root/release isn't empty"
OMABOOT_FLAVOUR=$OMABOOT_FLAVOUR OMABOOT_SIGNERS=release OMABOOT_RELEASE=$OMABOOT_RELEASE OMABOOT_TAG=$OMABOOT_TAG \
  OMABOOT_BUILD_IMAGE=$BUILD_IMAGE OMABOOT_PINNED_REPOS=$prep/pinned OMABOOT_COMMIT=$(git rev-parse --short=7 HEAD) \
  SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) \
  bin/omarchy-iso-make --keep-pkg-cache --no-boot-offer
built=$(ls -t "$root"/release/*.iso | head -n1)
mv "$built" "$OUT/$iso_name"
mv "$root/release/packages.tsv" "$OUT/packages.tsv"
echo "$iso_name: $(stat -c %s "$OUT/$iso_name") bytes"
build_seconds=$(($(date +%s) - started))

# 5. QEMU smoke tests, side by side; none can submit (restricted network or none, and no key in dry runs).
step "smoke tests"
mkdir -p "$OUT/smoke"
smoke() {
  local name=$1
  shift
  env "$@" python3 "$root/builder/omaboot/qemu/smoke.py" "$OUT/$iso_name" "$OUT/smoke/$name" >"$OUT/smoke/$name.log" 2>&1
}
names=(refuse tester room) pids=()
# refuse: a payload signed with the dev key must not run; the built-in tester runs instead
smoke refuse OMABOOT_SMOKE_TOOL=1 OMABOOT_SMOKE_EXPECT_REFUSE=1 OMABOOT_SMOKE_NO_SUBMIT=1 & pids+=($!)
# tester: boot-live's unattended quick pass on a MacBookAir5,2's SMBIOS, saved to the BOOTLIVE drive
smoke tester OMABOOT_SMOKE_TOOL=1 OMABOOT_SMOKE_NO_SUBMIT=1 & pids+=($!)
# room: no BOOTLIVE drive, no network: the tester makes its OMABOOT partition on the stick itself
smoke room OMABOOT_SMOKE_TOOL=1 OMABOOT_SMOKE_ROOM=1 & pids+=($!)
: >"$OUT/smoke-summary.txt"
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then r=PASS; else r=FAIL; failures+=("smoke test ${names[$i]}"); fi
  { echo "== ${names[$i]}: $r"; cat "$OUT/smoke/${names[$i]}.log"; echo; } | tee -a "$OUT/smoke-summary.txt"
done

# 6. The difference report against the official ISO.
step "difference report against the official ISO"
fork_changes=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fork-changes.XXXXXX")
git diff --name-status "$OFFICIAL_ISO_COMMIT" HEAD -- configs | while read -r st path; do
  why="$( [[ $st == A ]] && echo added || echo changed) in the fork: $path ($(git rev-list --count "$OFFICIAL_ISO_COMMIT"..HEAD -- "$path") commits since ${OFFICIAL_ISO_COMMIT:0:7})"
  case $path in
    configs/airootfs/*) printf 'rootfs\t%s\t%s\n' "${path#configs/airootfs/}" "$why" ;;
    configs/grub/*) printf 'iso\tboot/grub/%s\t%s\n' "${path#configs/grub/}" "$why" ;;
    configs/syslinux/*) printf 'iso\tboot/syslinux/%s\t%s\n' "${path#configs/syslinux/}" "$why" ;;
  esac
done >"$fork_changes"
cat "$fork_changes"
set +e
tools -v "$OUT:/out" -v "$prep:/prep:ro" -v "$root/builder:/builder:ro" -v "$fork_changes:/fork-changes.tsv:ro" "$BUILD_IMAGE" bash -c "set -euo pipefail; $tools_setup
  python3 -I /builder/omaboot/release/omaboot_release.py inventory /out/$iso_name /out/inventory
  set +e
  python3 -I /builder/omaboot/release/omaboot_release.py diff /prep/inventory /out/inventory --strict \
    --rules /builder/omaboot/release/explain.tsv --fork-changes /fork-changes.tsv --out /out \
    --context tag=$OMABOOT_TAG --context omarchy=$OMARCHY_VERSION --context official_commit=${OFFICIAL_ISO_COMMIT:0:7} \
    --context fork_commit=$(git rev-parse --short=7 HEAD) --context 'official_signature=$official_signature'
  status=\$?
  chown -R \$HOST_UID:\$HOST_GID /out/inventory /out/diff-report.md /out/diff-report.tsv.gz 2>/dev/null
  exit \$status"
diff_status=$?
set -e
case $diff_status in
  0) ;;
  2) failures+=("difference report: unexplained differences (diff-report.md)") ;;
  *) failures+=("difference report failed ($diff_status)") ;;
esac

# 7. What the release says about itself.
step "build-info.json"
OMABOOT_TAG=$OMABOOT_TAG ISO_NAME=$iso_name OUT=$OUT TARGET=$target BUILD_SECONDS=$build_seconds \
  FORK_COMMIT=$(git rev-parse HEAD) OFFICIAL_SIGNATURE=$official_signature BOOT_LIVE_TAG=$BOOT_LIVE_TAG \
  OMABOOT_FLAVOUR=$OMABOOT_FLAVOUR SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) \
  python3 -I - "$pin/pin.env" "$OUT/boot-live.txt" <<'EOF'
import json, os, sys, time
env = os.environ
pin = dict(l.strip().split('=', 1) for l in open(sys.argv[1]) if '=' in l and not l.startswith('#'))
bl = dict(l.strip().split('=', 1) for l in open(sys.argv[2]) if '=' in l)
run = env.get('GITHUB_RUN_ID')
info = {
    'tag': env['OMABOOT_TAG'], 'edition': env['OMABOOT_FLAVOUR'], 'iso': env['ISO_NAME'],
    'iso_bytes': os.path.getsize(os.path.join(env['OUT'], env['ISO_NAME'])),
    'omarchy': pin['OMARCHY_VERSION'],
    'official_iso': {'url': pin['OFFICIAL_ISO_URL'], 'sha256': pin['OFFICIAL_ISO_SHA256'], 'omarchy_iso_commit': pin['OFFICIAL_ISO_COMMIT'],
                     'signature': env['OFFICIAL_SIGNATURE']},
    'fork_commit': env['FORK_COMMIT'],
    'packages': {'arch_archive_date': pin['ARCH_ARCHIVE_DATE'], 'pinned_repos': pin['PINNED_REPOS'].strip('"').split(),
                 'build_image': pin['BUILD_IMAGE'], 'build_archive_date': pin['BUILD_ARCHIVE_DATE']},
    'boot_live': bl, 'report_target': env['TARGET'], 'source_date_epoch': int(env['SOURCE_DATE_EPOCH']),
    'built_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'build_seconds': int(env['BUILD_SECONDS']),
    'ci': {'server': env.get('GITHUB_SERVER_URL'), 'repository': env.get('GITHUB_REPOSITORY'), 'run_id': run,
           'run_url': f"{env.get('GITHUB_SERVER_URL')}/{env.get('GITHUB_REPOSITORY')}/actions/runs/{run}" if run else None},
}
json.dump(info, open(os.path.join(env['OUT'], 'build-info.json'), 'w'), indent=2)
print(json.dumps(info, indent=2))
EOF

{
  echo "OmaBoot? Live $OMABOOT_TAG, pinned to the official Omarchy $OMARCHY_VERSION ISO."
  echo
  echo "- Download: from omaboot.live once published (the ISO isn't attached here: GitHub's 2 GiB limit)."
  echo "- Verify: \`ssh-keygen -Y verify -f allowed_signers -I omaboot -n omaboot-release -s SHA256SUMS.sig < SHA256SUMS\`, then \`sha256sum -c SHA256SUMS\` (builder/omaboot/release/README.md)."
  echo "- Packages: every package is the official ISO's own file (same SHA-256) or one the live edition adds; see packages.tsv."
  echo "- Differences from the official ISO, each explained: diff-report.md."
  echo "- Tester: boot-live $BOOT_LIVE_TAG; smoke tests: smoke-summary.txt."
  echo
  sed -n '/^## Summary/,/^## /p' "$OUT/diff-report.md" 2>/dev/null | sed '$d'
} >"$OUT/release-notes.md"

step "done in $(($(date +%s) - started)) s"
if ((${#failures[@]})); then
  printf 'FAILED: %s\n' "${failures[@]}"
  exit 1
fi
echo "PASS: $OUT"
