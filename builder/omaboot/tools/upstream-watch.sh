#!/bin/bash
#
# Upstream watch: would our changes still go onto a newer upstream omarchy-iso? Tries them two
# ways on UPSTREAM (a commit already fetched; this script fetches nothing):
#
#  1. the squash: all our changes at once, as the public branch carries them (a three-way merge
#     of HEAD and UPSTREAM over their merge base, git merge-tree): clean, or the files that
#     conflict and our commits that touch them;
#  2. the replay: our commits one by one, in order (first-parent history from the merge base, so
#     a merge counts as one step; commits that change nothing are skipped), cherry-picked onto
#     UPSTREAM in a throwaway worktree: which ones conflict, on which files. A conflict is settled
#     by taking our commit's side, so the replay goes on; conflicts after that one may follow from
#     it. (git rerere is off here: those settlements aren't resolutions to remember.)
#
# When the squash is clean, its result is checked: test/all, and the build's dry run
# (builder/omaboot/tools/dry-run) for each image type, compared with the same dry run of HEAD.
# A full ISO build isn't part of it.
#
# Usage: upstream-watch.sh [-a] [-b bwrap|docker] UPSTREAM OUT
#   UPSTREAM  the upstream commit (e.g. refs/remotes/upstream/quattro)
#   OUT       a new directory: summary.txt (the short report), watch.log, the worktree, dry runs
#   -a        test/all in an Arch container (in-arch.sh), as upstream runs it: for a box on
#             another distribution
#   -b        the dry run's sandbox (default: bwrap when installed, else docker)
# Run it in a clone whose HEAD is our branch; HEAD and its branch are left as they are (the
# replay's commits live only in the worktree's detached HEAD; remove the worktree with
# git worktree remove when done). Exit: 0 when the squash applies and its checks pass, 1 when
# not, 2 usage. The replay's conflicts are reported, not counted: the public branch carries our
# changes as a short series made for it, not this history.

set -euo pipefail

backend= in_arch=
while getopts b:a opt; do
  case $opt in
    b) backend=$OPTARG ;;
    a) in_arch=1 ;;
    *) sed -n 's/^# \{0,1\}//; /^Usage:/,/^$/p' "$0" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
(( $# == 2 )) || { sed -n 's/^# \{0,1\}//; /^Usage:/,/^$/p' "$0" >&2; exit 2; }
upstream=$1
out=$2
[[ ! -e $out ]] || { echo "upstream watch: $out exists; give a new directory" >&2; exit 2; }
mkdir -p "$out"
out=$(realpath "$out")
here=$(cd "$(dirname "$0")" && pwd)
top=$(git rev-parse --show-toplevel)
cd "$top"

summary=$out/summary.txt
log=$out/watch.log
say() { printf '%s\n' "$*" | tee -a "$summary"; }
note() { printf '%s\n' "$*" >>"$log"; }
# throwaway commits: no signing, a neutral committer (authors stay as they were)
g() { git -c commit.gpgsign=false -c rerere.enabled=false -c user.name='upstream watch' -c user.email=upstream-watch@localhost "$@"; }

up=$(git rev-parse --verify "$upstream^{commit}")
base=$(git merge-base HEAD "$up") || { echo "upstream watch: HEAD and $upstream share no history" >&2; exit 2; }
status=0

say "upstream watch, $(date -u +%FT%TZ)"
say "upstream: $(git log -1 --format='%h %cs %s' "$up") ($(git rev-list --count "$base..$up") commits since our base $(git log -1 --format='%h %cs' "$base"))"
say "ours:     $(git log -1 --format='%h %cs %s' HEAD)"
if [[ $up == "$base" ]]; then
  say "upstream has nothing new since our base: nothing to try"
  exit 0
fi

# 1. The squash
say ""
merge_out=$(git merge-tree --write-tree --name-only --no-messages --merge-base="$base" HEAD "$up") && squash_ok=1 || squash_ok=
squash_tree=$(head -n1 <<<"$merge_out")
if [[ -n $squash_ok ]]; then
  say "squash (all our changes at once, as the public branch has them): applies cleanly"
else
  status=1
  say "squash (all our changes at once, as the public branch has them): CONFLICTS in"
  while read -r file; do
    [[ -n $file ]] || continue
    say "  $file  (ours: $(git log --no-merges --format=%h "$base..HEAD" -- "$file" | tr '\n' ' ' | sed 's/ $//'))"
  done < <(tail -n +2 <<<"$merge_out")
fi

# Our boot menu replaces two parts of upstream's grub.cfg (grub-splice.sh): have they changed?
if git show "$up:configs/grub/grub.cfg" >"$out/upstream-grub.cfg" 2>/dev/null; then
  if bash "$here/grub-splice.sh" "$out/upstream-grub.cfg" live >/dev/null 2>"$out/grub-splice.txt"; then
    say "boot menu: the parts of upstream's grub.cfg we replace are as our files were made from"
  else
    status=1
    say "boot menu: $(head -n1 "$out/grub-splice.txt" | sed 's/^grub-splice: //') (grub-splice.txt)"
  fi
fi

# 2. The replay
wt=$out/worktree
git worktree add -q --detach "$wt" "$up"
mapfile -t steps < <(git rev-list --reverse --first-parent "$base..HEAD")
applied=0 skipped=0 empty=0 conflicted=0 forced=
conflicts=()
for c in "${steps[@]}"; do
  subject=$(git log -1 --format=%s "$c")
  if [[ $(git rev-parse "$c^{tree}") == "$(git rev-parse "$c^1^{tree}")" ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  pick=(cherry-pick --empty=drop)
  [[ $(git rev-list --parents -n1 "$c" | wc -w) -gt 2 ]] && pick+=(-m 1)
  before=$(git -C "$wt" rev-parse HEAD)
  if g -C "$wt" "${pick[@]}" "$c" >>"$log" 2>&1; then
    if [[ $(git -C "$wt" rev-parse HEAD) == "$before" ]]; then
      empty=$((empty + 1))
      note "already upstream: $c $subject"
    else
      applied=$((applied + 1))
    fi
    continue
  fi
  mapfile -t unmerged < <(git -C "$wt" diff --name-only --diff-filter=U)
  if ((${#unmerged[@]} == 0)); then
    if git -C "$wt" diff --cached --quiet; then
      # nothing left to commit: the change is upstream's already
      g -C "$wt" cherry-pick --skip >>"$log" 2>&1
      empty=$((empty + 1))
      note "already upstream: $c $subject"
      continue
    fi
    g -C "$wt" cherry-pick --abort >>"$log" 2>&1 || true
    status=1
    say "replay: stopped at $c: cherry-pick failed without a conflict (see watch.log)"
    break
  fi
  conflicted=$((conflicted + 1))
  conflicts+=("$(git log -1 --format=%h "$c") $subject${forced:+ [after a forced resolution]}: ${unmerged[*]}")
  note "conflict: $c $subject: ${unmerged[*]}"
  # go on with our commit's side of each conflicting file
  for f in "${unmerged[@]}"; do
    if git cat-file -e "$c:$f" 2>/dev/null; then
      git -C "$wt" checkout -q --theirs -- "$f"
      git -C "$wt" add -- "$f"
    else
      git -C "$wt" rm -q -- "$f"
    fi
  done
  forced=1
  if ! g -C "$wt" -c core.editor=true cherry-pick --continue >>"$log" 2>&1; then
    g -C "$wt" cherry-pick --abort >>"$log" 2>&1 || true
    say "replay: stopped at $c: cherry-pick couldn't go on (see watch.log)"
    break
  fi
done
say ""
say "replay (our $((${#steps[@]} - skipped)) commits one by one; $skipped that change nothing skipped): $applied applied cleanly, $empty already upstream, $conflicted conflicted"
for line in "${conflicts[@]}"; do say "  $line"; done

# 3. Checks on the squash's result
say ""
if [[ -z $squash_ok ]]; then
  say "checks: skipped (the squash conflicts)"
  exit "$status"
fi
git -C "$wt" read-tree --reset -u "$squash_tree"
if [[ -z $forced ]] && [[ $(git -C "$wt" rev-parse 'HEAD^{tree}') != "$squash_tree" ]]; then
  note "the replay's result differs from the squash's (the squash is checked):"
  git -C "$wt" diff --stat HEAD >>"$log" 2>&1 || true
fi
# (the scrub check's generic part looks at what we change, so from the upstream commit we sit on)
if [[ -n $in_arch ]]; then
  # in an Arch container (in-arch.sh), from a clone of the squash: a worktree's .git points out of it
  squash=$(g commit-tree "$squash_tree" -p HEAD -p "$up" -m "upstream watch: the squash")
  git clone -q --no-checkout "$top" "$out/squash" && git -C "$out/squash" checkout -q "$squash"
  run_test_all() { (cd "$out/squash" && OMABOOT_UPSTREAM_BASE=$up LC_ALL=C PYTHONDONTWRITEBYTECODE=1 bash "$here/in-arch.sh" "$out/arch" test/all); }
else
  run_test_all() { (cd "$wt" && OMABOOT_UPSTREAM_BASE=$up PYTHONDONTWRITEBYTECODE=1 test/all); }
fi
if run_test_all >"$out/test-all.log" 2>&1; then
  say "test/all: pass"
else
  status=1
  say "test/all: FAIL (test-all.log)"
fi

if [[ -z $backend ]]; then
  if command -v bwrap >/dev/null; then backend=bwrap; else backend=docker; fi
fi
if [[ $backend == docker ]]; then
  docker=(docker)
  docker version >/dev/null 2>&1 || docker=(sudo -n docker)
  if ! "${docker[@]}" image inspect ghcr.io/archlinux/archlinux:latest >/dev/null 2>&1 &&
    ! "${docker[@]}" image inspect archlinux/archlinux:latest >/dev/null 2>&1; then
    say "dry run: skipped (no cached archlinux:latest image; the watch doesn't pull one)"
    exit "$status"
  fi
fi
# The archiso checkout the build seeds its profile from: HEAD's submodule, for both sides (a
# worktree doesn't check submodules out).
if [[ ! -d $top/archiso/configs/releng ]]; then
  say "dry run: skipped (the archiso submodule isn't checked out: git submodule update --init)"
  exit "$status"
fi
up_archiso=$(git ls-tree "$up" archiso | awk '{print $3}')
our_archiso=$(git ls-tree HEAD archiso | awk '{print $3}')
[[ $up_archiso == "$our_archiso" ]] || say "note: upstream moved its archiso submodule to ${up_archiso:0:12}; the dry runs use ours (${our_archiso:0:12})"
envbase=(OMARCHY_ISO_REF=quattro OMARCHY_MIRROR=stable OMARCHY_INSTALL_DEBUG= OMABOOT_SIGNERS=dev
  OMABOOT_COMMIT=watch OMABOOT_RELEASE= OMABOOT_PIN= OMABOOT_TAG=)
pin=$(sed -n 's/^OMABOOT_RELEASE=//p' builder/omaboot/release/release.env 2>/dev/null || true)
runs=("live:OMABOOT_FLAVOUR=live" "omarchy:OMABOOT_FLAVOUR=omarchy" "omarchy-lite:OMABOOT_FLAVOUR=omarchy-lite")
[[ -n $pin ]] && runs+=("live-pinned:OMABOOT_FLAVOUR=live OMABOOT_PIN=$pin")
mkdir -p "$out/dry-run"
for run in "${runs[@]}"; do
  name=${run%%:*}
  read -ra vars <<<"${run#*:}"
  result=
  for side in upstream ours; do
    tree=$wt
    [[ $side == ours ]] && tree=$top
    if bash "$here/dry-run/dry-run.sh" -b "$backend" -t -a "$top/archiso" "$tree" "$out/dry-run/$name-$side" "${envbase[@]}" "${vars[@]}" >>"$log" 2>&1; then
      result+=" $side:pass"
    else
      result+=" $side:FAIL"
      [[ $side == upstream ]] && status=1
    fi
  done
  changed=$(diff -rq --no-dereference "$out/dry-run/$name-ours/state/profile" "$out/dry-run/$name-upstream/state/profile" 2>/dev/null | wc -l || true)
  calls=$(diff "$out/dry-run/$name-ours/state/calls.log" "$out/dry-run/$name-upstream/state/calls.log" 2>/dev/null | grep -c '^>' || true)
  say "dry run $name:$result; on upstream vs today: $changed profile files differ, $calls build calls differ (dry-run/$name-*)"
done
exit "$status"
